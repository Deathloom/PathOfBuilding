-- Path of Building (Deathloom fork): headless "build impact" server.
--
-- Loads one build and answers "what happens if I equip this item?" questions
-- for the overlay. It reuses PoB's own item comparison code (the same code that
-- fills the item tooltip), so slot choice, jewels, flasks and tinctures behave
-- exactly as in the PoB window.
--
-- Run from the src folder:
--   Windows:  ..\runtime\PoBHeadless.exe ImpactServer.lua
--   Linux:    LUA_PATH="../runtime/lua/?.lua;../runtime/lua/?/init.lua;;" luajit ImpactServer.lua
--
-- Protocol: one JSON object per line on stdin, one JSON reply per line on stdout.
-- Every reply line starts with "@pob " so stray prints can never be mistaken
-- for replies. All logging goes to stderr.
--
--   {"id":1,"cmd":"ping"}
--   {"id":2,"cmd":"load","path":"D:/.../MyBuild.xml"}      (or "xml":"<PathOfBuilding>...")
--   {"id":3,"cmd":"impact","item":"Item Class: Rings\nRarity: Rare\n..."}
--   {"id":4,"cmd":"info"}
--   {"id":5,"cmd":"equipped","items":[...],"character":{...}}   (live gear, see below)
--   {"id":6,"cmd":"clearEquipped"}
--   {"id":7,"cmd":"quit"}
--
-- Replies: {"id":n,"ok":true,...} or {"id":n,"ok":false,"error":"..."}
--
-- Live gear: "equipped" takes the "items" array of the character's equipped
-- items (the JSON the public Characters tab returns) and puts them in a hidden
-- item set. After that, "impact" answers twice: vs the build's own gear
-- ("compares") and vs the equipped gear ("equipped.compares"). Only items are
-- swapped; the build's tree, skills and config stay as they are. "load" drops
-- the live set, so send "equipped" again after loading a build.

local realStdout = io.stdout
local function logErr(...)
	local parts = { }
	for i = 1, select("#", ...) do
		parts[i] = tostring(select(i, ...))
	end
	io.stderr:write(table.concat(parts, "\t"), "\n")
	io.stderr:flush()
end
-- Keep stdout clean for the protocol: PoB prints progress messages during startup.
print = logErr

dofile("HeadlessWrapper.lua")

local dkjson = require("dkjson")

local function send(tbl)
	realStdout:write("@pob ", dkjson.encode(tbl), "\n")
	realStdout:flush()
end

-- Strip PoB colour codes (^7, ^xRRGGBB) from tooltip text
local function stripColours(text)
	return (text:gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", ""))
end

-- Stats summarised for the compact panel. Values are deltas (new - current).
local summaryStats = {
	{ key = "FullDPS", label = "Full DPS" },
	{ key = "CombinedDPS", label = "Combined DPS" },
	{ key = "TotalEHP", label = "eHP" },
	{ key = "Life", label = "Life" },
	{ key = "EnergyShield", label = "Energy Shield" },
	{ key = "Mana", label = "Mana" },
	{ key = "FireResist", label = "Fire Res" },
	{ key = "ColdResist", label = "Cold Res" },
	{ key = "LightningResist", label = "Lightning Res" },
	{ key = "ChaosResist", label = "Chaos Res" },
	{ key = "Str", label = "Str" },
	{ key = "Dex", label = "Dex" },
	{ key = "Int", label = "Int" },
}

-- Minion builds: the main skill's minion DPS (CombinedDPS includes DoTs)
local function minionDPS(output)
	local minion = output and output.Minion
	if type(minion) ~= "table" then
		return nil
	end
	local value = minion.CombinedDPS or minion.TotalDPS
	return type(value) == "number" and value or nil
end

local function addSummaryEntry(out, key, label, old, new)
	if type(new) == "number" and type(old) == "number" and math.abs(new - old) > 0.001 then
		local entry = { stat = key, label = label, old = old, new = new, diff = new - old }
		if old ~= 0 then
			entry.pct = (new / old - 1) * 100
		end
		table.insert(out, entry)
	end
end

local function summarise(baseOutput, compareOutput)
	local out = { }
	-- Minion DPS first: for minion builds it's the number that matters
	addSummaryEntry(out, "MinionDPS", "Minion DPS", minionDPS(baseOutput), minionDPS(compareOutput))
	for _, stat in ipairs(summaryStats) do
		addSummaryEntry(out, stat.key, stat.label, baseOutput[stat.key], compareOutput[stat.key])
	end
	return out
end

local function buildInfo()
	local output = build.calcsTab.mainOutput or { }
	local mainSkill = build.calcsTab.mainEnv and build.calcsTab.mainEnv.player.mainSkill
	return {
		name = build.buildName,
		className = build.spec and build.spec.curClassName,
		ascendancy = build.spec and build.spec.curAscendClassName,
		level = build.characterLevel,
		mainSkill = mainSkill and mainSkill.activeEffect and mainSkill.activeEffect.grantedEffect.name or nil,
		stats = {
			FullDPS = output.FullDPS,
			CombinedDPS = output.CombinedDPS,
			MinionDPS = minionDPS(output),
			TotalEHP = output.TotalEHP,
			Life = output.Life,
			EnergyShield = output.EnergyShield,
		},
	}
end

local loaded = false
-- Item set the build was saved with, and the hidden set holding live gear
local buildSetId = nil
local liveSetId = nil
local liveInfo = nil
local LIVE_PREFIX = "live:"

local function recalc()
	build.buildFlag = true
	runCallback("OnFrame")
end

-- Make the given item set active and recalculate (only if it isn't already)
local function useItemSet(setId)
	local itemsTab = build.itemsTab
	if itemsTab.activeItemSetId ~= setId then
		itemsTab:SetActiveItemSet(setId)
		recalc()
	end
end

-- Snapshot of the numbers summarise() reads. (The output table has cycles,
-- so copyTable can't be used on it.)
local function copyOutput(output)
	local out = { }
	for key, value in pairs(output or { }) do
		if type(value) == "number" then
			out[key] = value
		end
	end
	local minion = output and output.Minion
	if type(minion) == "table" then
		out.Minion = { CombinedDPS = minion.CombinedDPS, TotalDPS = minion.TotalDPS }
	end
	return out
end

local function readFile(path)
	local f, err = io.open(path, "rb")
	if not f then
		return nil, err
	end
	local text = f:read("*a")
	f:close()
	return text
end

local handlers = { }

function handlers.ping()
	return { pong = true }
end

function handlers.load(req)
	local xml = req.xml
	if not xml and req.path then
		local err
		xml, err = readFile(req.path)
		if not xml then
			error("Can't read build file: " .. tostring(err))
		end
	end
	if not xml then
		error("load needs 'path' or 'xml'")
	end
	local name = req.name or (req.path and req.path:match("([^/\\]+)%.xml$")) or "Build"
	loaded = false
	liveSetId = nil
	liveInfo = nil
	loadBuildFromXML(xml, name)
	-- A couple of extra frames so deferred rebuilds (sockets, calcs) settle
	runCallback("OnFrame")
	if not build.calcsTab.mainOutput then
		error("PoB could not calculate this build")
	end
	buildSetId = build.itemsTab.activeItemSetId
	loaded = true
	return { build = buildInfo() }
end

function handlers.info()
	if not loaded then
		error("No build loaded")
	end
	useItemSet(buildSetId)
	return { build = buildInfo(), equipped = liveInfo }
end

-- Slots the character API uses that we leave alone: tree jewels belong to the
-- build's passive tree, the rest aren't gear PoB calculates.
local skipInventory = {
	PassiveJewels = true,
	MainInventory = true,
	ExpandedMainInventory = true,
	Cursor = true,
}

local function prepareLiveItem(itemData, index)
	local copy = copyTable(itemData)
	-- Prefix IDs so PoB's importer never overwrites the build's own copy of the
	-- same game item (it matches items by ID).
	copy.id = LIVE_PREFIX .. tostring(itemData.id or index)
	if copy.socketedItems then
		-- Keep abyss jewels; drop gems so the build's skills stay untouched
		local kept = { }
		for i, socketed in ipairs(copy.socketedItems) do
			if socketed.abyssJewel then
				socketed.id = LIVE_PREFIX .. tostring(socketed.id or (index .. "-" .. i))
				table.insert(kept, socketed)
			end
		end
		copy.socketedItems = kept
	end
	return copy
end

local function importEquipped(req)
	if not loaded then
		error("No build loaded")
	end
	if type(req.items) ~= "table" then
		error("equipped needs 'items' (the character's equipped items)")
	end
	local itemsTab = build.itemsTab
	local importTab = build.importTab

	-- Drop the previous live items, then (re)create the hidden set
	local old = { }
	for _, item in pairs(itemsTab.items) do
		if type(item.uniqueID) == "string" and item.uniqueID:sub(1, #LIVE_PREFIX) == LIVE_PREFIX then
			table.insert(old, item)
		end
	end
	for _, item in ipairs(old) do
		itemsTab:DeleteItem(item, true)
	end
	if not liveSetId or not itemsTab.itemSets[liveSetId] then
		local set = itemsTab:NewItemSet()
		set.title = "Equipped (live)"
		liveSetId = set.id
	end

	-- Import with the live set active, so abyss jewels land in it too
	if itemsTab.activeItemSetId ~= liveSetId then
		itemsTab:SetActiveItemSet(liveSetId)
	end
	local imported, skipped = 0, { }
	for index, itemData in ipairs(req.items) do
		if type(itemData) == "table" and not skipInventory[itemData.inventoryId] then
			local before = 0
			for _ in pairs(itemsTab.items) do before = before + 1 end
			local ok, err = pcall(importTab.ImportItem, importTab, prepareLiveItem(itemData, index))
			local after = 0
			for _ in pairs(itemsTab.items) do after = after + 1 end
			if ok and after > before then
				imported = imported + 1
			else
				local label = tostring(itemData.name ~= "" and itemData.name or itemData.typeLine)
				if not ok then
					logErr("Live item " .. label .. " failed: " .. tostring(err))
				end
				table.insert(skipped, label)
			end
		end
	end
	recalc()
	local liveOutput = copyOutput(build.calcsTab.mainOutput)
	useItemSet(buildSetId)
	local buildOutput = build.calcsTab.mainOutput or { }

	local character = type(req.character) == "table" and req.character or { }
	liveInfo = {
		character = character.name,
		class = character.class,
		level = character.level,
		league = character.league,
		items = imported,
		skipped = skipped,
		-- How the equipped gear compares to the build's gear
		summary = summarise(buildOutput, liveOutput),
	}
	return { equipped = liveInfo }
end

local function clearLive()
	if loaded and liveSetId then
		local itemsTab = build.itemsTab
		if itemsTab.activeItemSetId == liveSetId then
			itemsTab:SetActiveItemSet(buildSetId)
		end
		local old = { }
		for _, item in pairs(itemsTab.items) do
			if type(item.uniqueID) == "string" and item.uniqueID:sub(1, #LIVE_PREFIX) == LIVE_PREFIX then
				table.insert(old, item)
			end
		end
		for _, item in ipairs(old) do
			itemsTab:DeleteItem(item, true)
		end
		itemsTab.itemSets[liveSetId] = nil
		recalc()
	end
	liveSetId = nil
	liveInfo = nil
end

function handlers.equipped(req)
	local ok, result = pcall(importEquipped, req)
	if not ok then
		-- Never leave a half-imported set behind
		pcall(clearLive)
		error(result, 0)
	end
	return result
end

function handlers.clearEquipped()
	clearLive()
	return { cleared = true }
end

-- Parse the item text fresh for each comparison: anoints are copied from the
-- item currently equipped in the active set.
local function parseItem(itemText)
	local item = new("Item"):Item(itemText)
	if not item.base then
		error("PoB doesn't recognise this item's base type")
	end
	build.itemsTab:CopyAnointsAndEldritchImplicits(item, main.migrateEldritchImplicits, false)
	item:NormaliseQuality()
	item:BuildModList()
	return item
end

-- Compare the item against the active item set, the same way PoB's tooltip does
local function compareItem(itemText)
	local itemsTab = build.itemsTab
	local item = parseItem(itemText)

	-- Collect what PoB would show in the tooltip. Capture the raw outputs as
	-- well so the panel can show a compact numeric summary.
	local lines = { }
	local tooltip = {
		AddLine = function(_, _, text)
			table.insert(lines, text)
		end,
		AddSeparator = function() end,
	}
	local compares = { }
	local origAddCompares = build.AddStatComparesToTooltip
	build.AddStatComparesToTooltip = function(self, tt, baseOutput, compareOutput, header, ...)
		local firstLine = #lines + 1
		local count = origAddCompares(self, tt, baseOutput, compareOutput, header, ...)
		local entry = {
			header = stripColours(header):gsub("^%s+", ""):gsub("%s+$", ""),
			summary = summarise(baseOutput, compareOutput),
			lines = { },
		}
		for i = firstLine, #lines do
			local text = lines[i]
			local colour = text:match("^%^x(%x%x%x%x%x%x)")
			table.insert(entry.lines, {
				text = stripColours(text),
				positive = colour == colorCodes.POSITIVE:sub(3) or nil,
				negative = colour == colorCodes.NEGATIVE:sub(3) or nil,
			})
		end
		-- The header line itself is included in lines by PoB; drop it from the list
		if count > 0 and entry.lines[1] and not entry.lines[1].positive and not entry.lines[1].negative then
			table.remove(entry.lines, 1)
		end
		table.insert(compares, entry)
		return count
	end
	local ok, err = pcall(itemsTab.AddItemStatDifferences, itemsTab, tooltip, item, item.base)
	build.AddStatComparesToTooltip = origAddCompares
	if not ok then
		error(err)
	end

	-- Flasks don't go through AddStatComparesToTooltip; return their lines as-is
	local extraLines = { }
	if #compares == 0 then
		for _, text in ipairs(lines) do
			table.insert(extraLines, { text = stripColours(text) })
		end
	end

	return item, compares, extraLines
end

function handlers.impact(req)
	if not loaded then
		error("No build loaded")
	end
	if type(req.item) ~= "string" or req.item == "" then
		error("impact needs 'item' (the item text copied from the game)")
	end
	local itemText = req.item:gsub("\r\n", "\n")

	-- Compare against whichever set is active first, so each request costs at
	-- most one item-set switch (and one recalculation).
	local sets = { { key = "build", id = buildSetId } }
	if liveSetId then
		local live = { key = "live", id = liveSetId }
		if build.itemsTab.activeItemSetId == liveSetId then
			table.insert(sets, 1, live)
		else
			table.insert(sets, live)
		end
	end

	local reply = { }
	for _, set in ipairs(sets) do
		local ok, item, compares, extraLines = pcall(function()
			useItemSet(set.id)
			return compareItem(itemText)
		end)
		if set.key == "build" then
			if not ok then
				error(item, 0)
			end
			reply.item = {
				name = item.name,
				rarity = item.rarity,
				baseName = item.baseName,
				type = item.base.type,
			}
			reply.compares = compares
			reply.lines = extraLines
		elseif ok then
			reply.equipped = { compares = compares, lines = extraLines, info = liveInfo }
		else
			reply.equippedError = tostring(item)
		end
	end
	return reply
end

function handlers.quit()
	return { bye = true }
end

send({ id = 0, ok = true, ready = true, version = launch.versionNumber })

while true do
	local line = io.read("*l")
	if not line then
		break
	end
	if line:match("%S") then
		local req, _, decodeErr = dkjson.decode(line)
		if type(req) ~= "table" then
			send({ ok = false, error = "Bad JSON: " .. tostring(decodeErr) })
		else
			local handler = handlers[req.cmd]
			if not handler then
				send({ id = req.id, ok = false, error = "Unknown cmd: " .. tostring(req.cmd) })
			else
				local ok, result = pcall(handler, req)
				if ok then
					result.id = req.id
					result.ok = true
					send(result)
				else
					logErr("Error in " .. tostring(req.cmd) .. ": " .. tostring(result))
					send({ id = req.id, ok = false, error = tostring(result) })
				end
				if req.cmd == "quit" then
					break
				end
			end
		end
	end
end
