-- Path of Building (Deathloom fork): headless "build impact" server.
-- cspell:ignore Deathloom RRGGBB
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
--   {"id":2,"cmd":"load","path":"C:/.../MyBuild.xml"}      (or "xml":"<PathOfBuilding>...")
--   {"id":3,"cmd":"impact","item":"Item Class: Rings\nRarity: Rare\n..."}
--   {"id":4,"cmd":"info"}
--   {"id":5,"cmd":"equipped","items":[...],"passives":{...},"skills":true,"character":{...}}
--   {"id":6,"cmd":"clearEquipped"}
--   {"id":7,"cmd":"gear"}       (the build's items: slot, mods, game-format text)
--   {"id":8,"cmd":"loadouts"}   (trees, item sets, skill sets, PoB's named loadouts)
--   {"id":9,"cmd":"setLoadout","named":"..."} or {...,"spec":n,"itemSet":n,"skillSet":n}
--   {"id":10,"cmd":"gems"}      (socket groups of the build and the live character)
--   {"id":12,"cmd":"tree"}      (keystones / notables / masteries / ascendancy of build and character)
--   {"id":13,"cmd":"treeMap","haveVersion":"3_28"}  (whole passive tree layout + allocated node ids;
--                               layout left out when haveVersion matches)
--   {"id":11,"cmd":"quit"}
--
-- Replies: {"id":n,"ok":true,...} or {"id":n,"ok":false,"error":"..."}
--
-- Live character: "equipped" takes what the public Characters tab returns:
-- "items" (get-items), optionally "passives" (get-passive-skills: tree +
-- tree jewels) and "skills":true (use the gems socketed in those items). They
-- go into a hidden loadout (item set, skill set, tree spec, level). After that,
-- "impact" answers twice: vs the build ("compares") and vs the live character
-- ("equipped.compares"). The build's config (enemy, buffs, bandit, pantheon)
-- is used for both. Main skill on the character: the build's main skill if
-- the character has it, otherwise PoB's guess. "load" drops the live
-- loadout, so send "equipped" again after loading a build.

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
-- A loadout is everything that differs between the build and the live
-- character: item set, skill set, tree spec, main skill and level. Config
-- (enemy, buffs, bandit, pantheon) always stays the build's.
local buildLoadout = nil
local liveLoadout = nil
local activeLoadout = nil
local liveInfo = nil
local buildMainSkill = nil
local LIVE_PREFIX = "live:"
-- buildMode keeps its methods on the object itself, so keep the original
local origSyncLoadouts = build.SyncLoadouts

local function recalculate()
	build.buildFlag = true
	runCallback("OnFrame")
end

local function captureLoadout()
	return {
		itemSet = build.itemsTab.activeItemSetId,
		skillSet = build.skillsTab.activeSkillSetId,
		spec = build.treeTab.activeSpec,
		mainSocketGroup = build.mainSocketGroup,
		level = build.characterLevel,
	}
end

-- Switch to a loadout without recalculating. Returns true if anything changed.
local function applyLoadout(l)
	if activeLoadout == l then
		return false
	end
	if activeLoadout then
		-- Remember the main skill choice of the loadout we leave
		activeLoadout.mainSocketGroup = build.mainSocketGroup
	end
	if build.itemsTab.activeItemSetId ~= l.itemSet then
		build.itemsTab:SetActiveItemSet(l.itemSet)
	end
	if build.skillsTab.activeSkillSetId ~= l.skillSet then
		build.skillsTab:SetActiveSkillSet(l.skillSet)
	end
	if build.treeTab.activeSpec ~= l.spec then
		build.treeTab:SetActiveSpec(l.spec)
	end
	build.mainSocketGroup = l.mainSocketGroup
	build.characterLevel = l.level
	build.configTab:UpdateLevel()
	activeLoadout = l
	return true
end

local function useLoadout(l)
	if applyLoadout(l) then
		recalculate()
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

-- Build files are other players' data (friends' builds from sync). PoB's XML loader runs no code,
-- but a huge file could still hang the server, so cap the size.
local MAX_BUILD_BYTES = 32 * 1024 * 1024

local function readFile(path)
	local f, err = io.open(path, "rb")
	if not f then
		return nil, err
	end
	local size = f:seek("end")
	if size and size > MAX_BUILD_BYTES then
		f:close()
		return nil, "build file is bigger than 32 MB"
	end
	f:seek("set")
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
	if type(xml) ~= "string" then
		error("load needs 'path' or 'xml'")
	end
	if #xml > MAX_BUILD_BYTES then
		error("Build is bigger than 32 MB")
	end
	local name = req.name or (req.path and req.path:match("([^/\\]+)%.xml$")) or "Build"
	loaded = false
	liveLoadout = nil
	liveInfo = nil
	-- Normal loadout syncing while PoB loads the build (see below)
	build.SyncLoadouts = origSyncLoadouts
	loadBuildFromXML(xml, name)
	-- A couple of extra frames so deferred rebuilds (sockets, calcs) settle
	runCallback("OnFrame")
	if not build.calcsTab.mainOutput then
		error("PoB could not calculate this build")
	end
	-- PoB's loadout dropdown re-selects a matching loadout whenever a set
	-- changes, which would switch item sets in the middle of our swaps. It
	-- only drives the UI, so turn it off for this build object.
	build.SyncLoadouts = function() end
	buildLoadout = captureLoadout()
	activeLoadout = buildLoadout
	local info = buildInfo()
	buildMainSkill = info.mainSkill
	loaded = true
	return { build = info }
end

function handlers.info()
	if not loaded then
		error("No build loaded")
	end
	useLoadout(buildLoadout)
	return { build = buildInfo(), equipped = liveInfo }
end

-- Inventories we leave alone: tree jewels come with the passive tree (and are
-- only used when the tree is imported), the rest isn't gear PoB calculates.
local skipInventory = {
	PassiveJewels = true,
	MainInventory = true,
	ExpandedMainInventory = true,
	Cursor = true,
}

local function isLiveItem(item)
	return type(item.uniqueID) == "string" and item.uniqueID:sub(1, #LIVE_PREFIX) == LIVE_PREFIX
end

local function prepareLiveItem(itemData, index, keepGems)
	local copy = copyTable(itemData)
	-- Prefix IDs so PoB's importer never overwrites the build's own copy of the
	-- same game item (it matches items by ID).
	copy.id = LIVE_PREFIX .. tostring(itemData.id or index)
	if copy.socketedItems then
		local kept = { }
		for i, socketed in ipairs(copy.socketedItems) do
			if socketed.abyssJewel then
				socketed.id = LIVE_PREFIX .. tostring(socketed.id or (index .. "-" .. i))
				table.insert(kept, socketed)
			elseif keepGems then
				table.insert(kept, socketed)
			end
		end
		copy.socketedItems = kept
	end
	return copy
end

-- Remove everything the live loadout added. The build loadout must be active.
local function removeLive()
	local itemsTab, skillsTab, treeTab = build.itemsTab, build.skillsTab, build.treeTab
	if liveLoadout then
		if liveLoadout.spec ~= buildLoadout.spec and treeTab.specList[liveLoadout.spec] then
			table.remove(treeTab.specList, liveLoadout.spec)
		end
		if liveLoadout.skillSet ~= buildLoadout.skillSet then
			skillsTab.skillSets[liveLoadout.skillSet] = nil
		end
		if liveLoadout.itemSet ~= buildLoadout.itemSet then
			itemsTab.itemSets[liveLoadout.itemSet] = nil
		end
	end
	local old = { }
	for _, item in pairs(itemsTab.items) do
		if isLiveItem(item) then
			table.insert(old, item)
		end
	end
	for _, item in ipairs(old) do
		itemsTab:DeleteItem(item, true)
	end
	liveLoadout = nil
	liveInfo = nil
end

-- Same tree-version choice as PoB's character import
local function liveTreeVersion(className, league)
	local inLatest = false
	for _, class in pairs(main.tree[latestTreeVersion].classes) do
		if class.name == className then
			inLatest = true
		end
		for i = 0, #class.classes do
			if class.classes[i] and class.classes[i].name == className then
				inLatest = true
			end
		end
	end
	local ruthless = type(league) == "string" and league:match("Ruthless") and "_ruthless" or ""
	return latestTreeVersion .. ruthless .. (inLatest and "" or "_alternate")
end

-- Import the passive tree into a new spec (the live loadout's). Only the tree
-- and its jewels: unlike PoB's character import, config and level are not
-- touched here.
local function importTree(passives, character, index)
	local treeTab, importTab = build.treeTab, build.importTab
	local spec = new("PassiveSpec"):PassiveSpec(build, liveTreeVersion(character.class, character.league))
	spec.title = "Live character"
	table.insert(treeTab.specList, spec)
	local specIndex = #treeTab.specList
	treeTab:SetActiveSpec(specIndex)

	local masteries = { }
	for key, value in pairs(passives.mastery_effects or { }) do
		masteries[tonumber(key)] = value
	end
	spec.jewel_data = { }
	for key, value in pairs(passives.jewel_data or { }) do
		spec.jewel_data[tonumber(key)] = value
	end
	local overrides = { }
	for nodeId, override in pairs(passives.skill_overrides or { }) do
		local tattoo = spec.tree.tattoo and spec.tree.tattoo.nodes[override.name]
		if tattoo then
			spec:ReplaceNode(override, tattoo)
			override.id = tonumber(nodeId)
			overrides[tonumber(nodeId)] = override
		end
	end
	spec.extended_hashes = copyTable(passives.hashes_ex or { })
	-- Jewels first, so cluster jewel nodes can be allocated
	local jewels, skippedJewels = 0, { }
	for i, itemData in ipairs(passives.items or { }) do
		local ok, err = pcall(importTab.ImportItem, importTab, prepareLiveItem(itemData, "j" .. i, false))
		if ok then
			jewels = jewels + 1
		else
			logErr("Live jewel failed: " .. tostring(err))
			table.insert(skippedJewels, tostring(itemData.name ~= "" and itemData.name or itemData.typeLine))
		end
	end
	local alternate = passives.alternate_ascendancy or 0
	if type(alternate) == "string" then
		local bloodline = build.latestTree.secondaryAscendNameMap[alternate]
		alternate = bloodline and bloodline.ascendClassId or 0
	end
	spec.clusterHashFormatVersion = 2
	spec:ImportFromNodeList(character.class, nil, nil, alternate, passives.hashes or { }, overrides, masteries, spec.treeVersion)
	-- Re-select the spec so the socketed jewels are stored in it
	treeTab:SetActiveSpec(specIndex)
	spec:BuildClusterJewelGraphs()
	local nodes = 0
	for _ in pairs(spec.allocNodes) do nodes = nodes + 1 end
	return specIndex, nodes, jewels, skippedJewels
end

-- Pick the live character's main skill: the build's main skill if the
-- character has it, otherwise PoB's guess (the largest socket group).
local function chooseLiveMainSkill()
	local skillsTab = build.skillsTab
	skillsTab:UpdateSocketGroups()
	local found
	for index, group in ipairs(skillsTab.socketGroupList) do
		for _, gem in ipairs(group.gemList) do
			local effect = gem.grantedEffect or (gem.gemData and gem.gemData.grantedEffect)
			if effect and not effect.support and effect.name == buildMainSkill then
				found = index
				break
			end
		end
		if found then break end
	end
	build.mainSocketGroup = found or build.importTab:GuessMainSocketGroup()
	recalculate()
	-- Point the group at the right active skill (groups can hold several)
	local group = skillsTab.socketGroupList[build.mainSocketGroup]
	if found and group and group.displaySkillList then
		for i, skill in ipairs(group.displaySkillList) do
			if skill.activeEffect and skill.activeEffect.grantedEffect.name == buildMainSkill then
				if group.mainActiveSkill ~= i then
					group.mainActiveSkill = i
					recalculate()
				end
				break
			end
		end
	end
	local mainSkill = build.calcsTab.mainEnv and build.calcsTab.mainEnv.player.mainSkill
	return mainSkill and mainSkill.activeEffect and mainSkill.activeEffect.grantedEffect.name or nil, found ~= nil
end

local function importEquipped(req)
	if not loaded then
		error("No build loaded")
	end
	if type(req.items) ~= "table" then
		error("equipped needs 'items' (the character's equipped items)")
	end
	local itemsTab, skillsTab, importTab = build.itemsTab, build.skillsTab, build.importTab
	local character = type(req.character) == "table" and req.character or { }
	local passives = type(req.passives) == "table" and req.passives or nil
	local useTree = passives ~= nil and type(character.class) == "string"
	local useSkills = req.skills == true

	useLoadout(buildLoadout)
	removeLive()

	local live = {
		itemSet = itemsTab:NewItemSet().id,
		skillSet = buildLoadout.skillSet,
		spec = buildLoadout.spec,
		mainSocketGroup = buildLoadout.mainSocketGroup,
		level = buildLoadout.level,
	}
	itemsTab.itemSets[live.itemSet].title = "Live character"
	if useSkills then
		live.skillSet = skillsTab:NewSkillSet().id
		skillsTab.skillSets[live.skillSet].title = "Live character"
	end
	if tonumber(character.level) then
		live.level = tonumber(character.level)
	end
	liveLoadout = live
	-- Import with the live loadout active, so items, abyss jewels and gems land in it
	applyLoadout(live)

	local info = {
		character = character.name,
		class = character.class,
		level = character.level,
		league = character.league,
		tree = false,
		skills = useSkills,
	}
	if useTree then
		local specIndex, nodes, jewels, skippedJewels = importTree(passives, character, #req.items + 1)
		live.spec = specIndex
		info.tree = true
		info.nodes = nodes
		info.jewels = jewels
		info.skippedJewels = skippedJewels
	end

	local imported, skipped = 0, { }
	for index, itemData in ipairs(req.items) do
		if type(itemData) == "table" and not skipInventory[itemData.inventoryId] then
			local before = 0
			for _ in pairs(itemsTab.items) do before = before + 1 end
			local ok, err = pcall(importTab.ImportItem, importTab, prepareLiveItem(itemData, index, useSkills))
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
	info.items = imported
	info.skipped = skipped

	if useSkills then
		info.mainSkill, info.mainSkillMatched = chooseLiveMainSkill()
	else
		recalculate()
		info.mainSkill, info.mainSkillMatched = buildMainSkill, true
	end
	live.mainSocketGroup = build.mainSocketGroup
	local liveOutput = copyOutput(build.calcsTab.mainOutput)
	useLoadout(buildLoadout)
	-- How the live character compares to the build
	info.summary = summarise(build.calcsTab.mainOutput or { }, liveOutput)
	liveInfo = info
	return { equipped = info }
end

local function clearLive()
	if loaded then
		useLoadout(buildLoadout)
		removeLive()
		recalculate()
	end
	liveLoadout = nil
	liveInfo = nil
end

function handlers.equipped(req)
	local ok, result = pcall(importEquipped, req)
	if not ok then
		-- Never leave a half-imported loadout behind
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

	-- Compare against whichever loadout is active first, so each request costs
	-- at most one switch (and one recalculation).
	local sets = { { key = "build", loadout = buildLoadout } }
	if liveLoadout then
		local live = { key = "live", loadout = liveLoadout }
		if activeLoadout == liveLoadout then
			table.insert(sets, 1, live)
		else
			table.insert(sets, live)
		end
	end

	local reply = { }
	for _, set in ipairs(sets) do
		local ok, item, compares, extraLines = pcall(function()
			useLoadout(set.loadout)
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

-- Build gear panel: the build's own items (active item set), one entry per
-- filled slot, with the mod lines PoB shows and the item written out in the
-- game's Ctrl+C format so the overlay can price-check it or build a trade
-- search from it.

-- Game's "Rarity:" values; PoB calls foil uniques RELIC
local gameRarity = {
	NORMAL = "Normal",
	MAGIC = "Magic",
	RARE = "Rare",
	UNIQUE = "Unique",
	RELIC = "Unique",
}

-- Mod lines as PoB's tooltip shows them (ranges applied, variants honoured,
-- zero-value lines hidden). kind is used for the game-format suffix.
local function itemModLines(item)
	local out = { }
	local function add(list, kind)
		for _, modLine in ipairs(list or { }) do
			if item:GetModLineVariantCount(modLine) > 0 then
				local formatted = itemLib.formatModLine(modLine)
				if formatted then
					-- PoB wraps some long lines with \n; it reads them as one line (see getRangedModList)
					local text = stripColours(formatted):gsub("\n", " ")
					-- formatModLine may add "(Not supported in PoB yet)"; the game text must not have it
					local suffix = main.notSupportedTooltipText and stripColours(main.notSupportedTooltipText)
					if modLine.extra and suffix and suffix ~= "" and text:sub(-#suffix) == suffix then
						text = text:sub(1, -#suffix - 1)
					end
					table.insert(out, {
						text = text,
						kind = kind,
						crafted = modLine.crafted or nil,
						fractured = modLine.fractured or nil,
						prefix = modLine.prefix or nil,
						suffix = modLine.suffix or nil,
						unsupported = modLine.extra and true or nil,
					})
				end
			end
		end
	end
	add(item.enchantModLines, "enchant")
	add(item.scourgeModLines, "scourge")
	add(item.implicitModLines, "implicit")
	add(item.explicitModLines, "explicit")
	add(item.crucibleModLines, "crucible")
	return out
end

-- PoB tells some bases apart with a suffix the game doesn't use,
-- e.g. "Two-Toned Boots (Armour/Evasion)"
local function gameBaseName(item)
	return (item.baseName:gsub("%s+%b()$", ""))
end

-- The item in the game's Ctrl+C text format (what the overlay's parser and
-- PoB's own importer both read)
local function gameItemText(item, mods)
	local sections = { }
	local function section(lines)
		if #lines > 0 then
			table.insert(sections, table.concat(lines, "\n"))
		end
	end
	local rarity = gameRarity[item.rarity] or "Rare"
	local plate = { "Item Class: " .. tostring(item.base and item.base.type or item.type or ""), "Rarity: " .. rarity }
	if item.title and (rarity == "Rare" or rarity == "Unique") then
		table.insert(plate, item.title)
		table.insert(plate, gameBaseName(item))
	elseif rarity == "Magic" then
		table.insert(plate, (item.namePrefix or "") .. gameBaseName(item) .. (item.nameSuffix or ""))
	else
		table.insert(plate, gameBaseName(item))
	end
	section(plate)

	local props = { }
	if item.quality and item.quality > 0 then
		table.insert(props, "Quality: +" .. item.quality .. "% (augmented)")
	end
	-- Defences as the game shows them; PoB also uses them to tell Two-Toned Boots apart
	if item.armourData then
		for _, def in ipairs({ { "Armour", "Armour" }, { "Evasion", "Evasion Rating" }, { "EnergyShield", "Energy Shield" }, { "Ward", "Ward" } }) do
			local value = item.armourData[def[1]]
			if value and value > 0 then
				table.insert(props, def[2] .. ": " .. math.floor(value + 0.5))
			end
		end
	end
	section(props)
	if item.sockets and #item.sockets > 0 then
		local line = "Sockets: "
		for i, socket in ipairs(item.sockets) do
			line = line .. socket.color
			if item.sockets[i + 1] then
				line = line .. (socket.group == item.sockets[i + 1].group and "-" or " ")
			end
		end
		section({ line })
	end
	if item.itemLevel then
		section({ "Item Level: " .. item.itemLevel })
	end

	-- Advanced copy format (Ctrl+Alt+C): the overlay's parser needs a
	-- "{ ... }" header before each implicit/explicit, plain lines aren't read
	local byKind = { enchant = { }, scourge = { }, implicit = { }, explicit = { } }
	local isUnique = rarity == "Unique"
	for _, mod in ipairs(mods) do
		local list = byKind[mod.kind]
		if list then
			if mod.kind == "enchant" then
				table.insert(list, mod.text .. " (enchant)")
			elseif mod.kind == "scourge" then
				table.insert(list, mod.text .. " (scourge)")
			else
				local header
				if mod.kind == "implicit" then
					header = "Implicit Modifier"
				elseif mod.fractured then
					header = mod.suffix and "Fractured Suffix Modifier" or "Fractured Prefix Modifier"
				elseif mod.crafted then
					header = mod.suffix and "Master Crafted Suffix Modifier" or "Master Crafted Prefix Modifier"
				elseif isUnique then
					header = "Unique Modifier"
				elseif mod.prefix then
					header = "Prefix Modifier"
				elseif mod.suffix then
					header = "Suffix Modifier"
				else
					header = "Modifier"
				end
				table.insert(list, "{ " .. header .. " }")
				table.insert(list, mod.text)
			end
		end
	end
	section(byKind.enchant)
	section(byKind.scourge)
	section(byKind.implicit)
	section(byKind.explicit)

	local influences = { }
	for _, info in ipairs(itemLib.influenceInfo.all) do
		if item[info.key] then
			table.insert(influences, info.display .. " Item")
		end
	end
	section(influences)
	if item.split then
		section({ "Split" })
	end
	if item.mirrored then
		section({ "Mirrored" })
	end
	if item.corrupted or item.scourge then
		section({ "Corrupted" })
	end
	return table.concat(sections, "\n--------\n") .. "\n"
end

local function slotGroup(slot)
	if slot.nodeId then
		return "jewel"
	elseif slot.slotName:match("Abyssal") then
		return "abyss"
	elseif slot.slotName:match("^Flask") then
		return "flask"
	elseif slot.weaponSet == 2 then
		return "swap"
	end
	return "gear"
end

function handlers.gear()
	if not loaded then
		error("No build loaded")
	end
	-- The build's own item set, never the live character's
	useLoadout(buildLoadout)
	local itemsTab = build.itemsTab
	local itemSet = itemsTab.activeItemSet
	local spec = build.spec
	local out = { }
	for _, slot in ipairs(itemsTab.orderedSlots) do
		local itemId
		if slot.nodeId then
			if spec and spec.allocNodes[slot.nodeId] then
				itemId = spec.jewels[slot.nodeId]
			end
		elseif not slot.inactive and itemSet[slot.slotName] then
			itemId = itemSet[slot.slotName].selItemId
		end
		local item = itemId and itemId ~= 0 and itemsTab.items[itemId]
		if item and item.base then
			local mods = itemModLines(item)
			local rarity = gameRarity[item.rarity] or item.rarity
			local isUnique = rarity == "Unique"
			table.insert(out, {
				slot = slot.slotName,
				label = slot.nodeId and "Jewel" or slot.label,
				group = slotGroup(slot),
				active = (slot.slotName:match("^Flask") and itemSet[slot.slotName] and itemSet[slot.slotName].active) or nil,
				name = item.name,
				title = item.title,
				baseName = item.baseName,
				rarity = rarity,
				type = item.base.type,
				itemLevel = item.itemLevel,
				quality = item.quality,
				corrupted = item.corrupted or nil,
				mods = mods,
				-- What GGG's in-game market search box accepts: names and base types only
				searchText = (isUnique and item.title) or gameBaseName(item),
				text = gameItemText(item, mods),
			})
		end
	end
	return {
		build = buildInfo(),
		itemSet = itemSet.title or "Default",
		items = out,
	}
end

-- Loadouts: which tree / item set / skill set of the build the overlay
-- compares against. PoB's named loadouts (the dropdown at the top of the PoB
-- window) are offered too. The live character's hidden sets are never listed.

local noSync = function() end

-- PoB's own loadout list, computed the same way as its dropdown
local function namedLoadouts()
	local names = { }
	local control = build.controls and build.controls.buildLoadouts
	if not control then
		return names
	end
	build.SyncLoadouts = origSyncLoadouts
	local ok, err = pcall(origSyncLoadouts, build)
	build.SyncLoadouts = noSync
	if not ok then
		logErr("SyncLoadouts failed: " .. tostring(err))
		return names
	end
	for _, value in ipairs(control.list or { }) do
		-- PoB marks its own menu entries (New Loadout, Sync, ...) with ^7^7
		if type(value) == "string" and not value:match("^%^7%^7") and value ~= "Live character" then
			table.insert(names, value)
		end
	end
	return names
end

local function loadoutInfo()
	local treeTab, itemsTab, skillsTab = build.treeTab, build.itemsTab, build.skillsTab
	local live = liveLoadout or { }
	local trees, itemSets, skillSets = { }, { }, { }
	for index, spec in ipairs(treeTab.specList) do
		if index ~= live.spec or index == buildLoadout.spec then
			table.insert(trees, { id = index, title = spec.title or "Default" })
		end
	end
	for _, id in ipairs(itemsTab.itemSetOrderList) do
		if itemsTab.itemSets[id] and (id ~= live.itemSet or id == buildLoadout.itemSet) then
			table.insert(itemSets, { id = id, title = itemsTab.itemSets[id].title or "Default" })
		end
	end
	for _, id in ipairs(skillsTab.skillSetOrderList) do
		if skillsTab.skillSets[id] and (id ~= live.skillSet or id == buildLoadout.skillSet) then
			table.insert(skillSets, { id = id, title = skillsTab.skillSets[id].title or "Default" })
		end
	end
	local named = namedLoadouts()
	-- The named loadout that matches the active sets (PoB names loadouts after the tree)
	local treeTitle = treeTab.specList[buildLoadout.spec] and treeTab.specList[buildLoadout.spec].title or "Default"
	local activeNamed
	for _, name in ipairs(named) do
		if name == treeTitle or (name:match("%{(%w+)%}") and treeTitle:find("{" .. name:match("%{(%w+)%}"), 1, true)) then
			activeNamed = name
			break
		end
	end
	return {
		trees = trees,
		itemSets = itemSets,
		skillSets = skillSets,
		named = named,
		active = {
			spec = buildLoadout.spec,
			itemSet = buildLoadout.itemSet,
			skillSet = buildLoadout.skillSet,
			named = activeNamed,
		},
	}
end

function handlers.loadouts()
	if not loaded then
		error("No build loaded")
	end
	useLoadout(buildLoadout)
	return { loadouts = loadoutInfo(), build = buildInfo() }
end

-- {"cmd":"setLoadout","named":"Mapping"} or {"cmd":"setLoadout","spec":2,"itemSet":3,"skillSet":1}
-- Only for this PoB process: the build file is never written. Drops the live
-- character's loadout (its sets were made next to the old ones), so send
-- "equipped" again afterwards.
function handlers.setLoadout(req)
	if not loaded then
		error("No build loaded")
	end
	clearLive()
	useLoadout(buildLoadout)
	local treeTab, itemsTab, skillsTab = build.treeTab, build.itemsTab, build.skillsTab
	if type(req.named) == "string" and req.named ~= "" then
		local found = false
		for _, name in ipairs(namedLoadouts()) do
			if name == req.named then
				found = true
			end
		end
		if not found then
			error("Loadout not found in this build: " .. req.named)
		end
		local ok, err = pcall(build.controls.buildLoadouts.selFunc, 1, req.named)
		build.SyncLoadouts = noSync
		if not ok then
			error(err, 0)
		end
	else
		local spec, itemSet, skillSet = tonumber(req.spec), tonumber(req.itemSet), tonumber(req.skillSet)
		if spec and treeTab.specList[spec] and spec ~= treeTab.activeSpec then
			treeTab:SetActiveSpec(spec)
		end
		if itemSet and itemsTab.itemSets[itemSet] and itemSet ~= itemsTab.activeItemSetId then
			itemsTab:SetActiveItemSet(itemSet)
		end
		if skillSet and skillsTab.skillSets[skillSet] and skillSet ~= skillsTab.activeSkillSetId then
			skillsTab:SetActiveSkillSet(skillSet)
		end
	end
	build.SyncLoadouts = noSync
	recalculate()
	if build.mainSocketGroup > #skillsTab.socketGroupList then
		build.mainSocketGroup = build.importTab:GuessMainSocketGroup()
		recalculate()
	end
	buildLoadout = captureLoadout()
	activeLoadout = buildLoadout
	local info = buildInfo()
	buildMainSkill = info.mainSkill
	return { loadouts = loadoutInfo(), build = info }
end

-- Gems menu: the build's socket groups (gems, levels, quality) and, when the
-- live character was sent with skills, the character's socket groups too.
-- Comparing them is left to the overlay.
local function socketGroups(loadout)
	useLoadout(loadout)
	local out = { }
	for index, group in ipairs(build.skillsTab.socketGroupList) do
		local gems = { }
		for _, gem in ipairs(group.gemList or { }) do
			local data = gem.gemData
			local name = (data and data.name) or gem.nameSpec
			if name and name ~= "" then
				local effect = gem.grantedEffect or (data and data.grantedEffect)
				table.insert(gems, {
					name = name,
					level = gem.level,
					quality = gem.quality,
					enabled = gem.enabled ~= false,
					support = (effect and effect.support) and true or false,
					-- Gem tag colour: str / dex / int
					colour = data and data.grantedEffect and data.grantedEffect.color or nil,
				})
			end
		end
		if #gems > 0 then
			table.insert(out, {
				index = index,
				label = (group.label and group.label:match("%S")) and group.label or nil,
				slot = group.slot,
				-- Skills granted by items (e.g. a unique's skill) can't be socketed
				source = group.source,
				enabled = group.enabled ~= false,
				main = index == build.mainSocketGroup or nil,
				fullDPS = group.includeInFullDPS or nil,
				gems = gems,
			})
		end
	end
	return out
end

-- Gear in the loadout's item set (no flasks or jewels): slot, item name and sockets
-- in the game's notation ("R-G-B W": "-" = linked; "" = no sockets). Weapon swap included.
local function socketedItems(loadout)
	useLoadout(loadout)
	local itemsTab = build.itemsTab
	local itemSet = itemsTab.activeItemSet
	local out = { }
	for _, slot in ipairs(itemsTab.orderedSlots) do
		if not slot.nodeId and not slot.slotName:match("^Flask") and itemSet[slot.slotName] then
			local itemId = itemSet[slot.slotName].selItemId
			local item = itemId and itemId ~= 0 and itemsTab.items[itemId]
			if item and item.base then
				local parts = { }
				local sockets = item.sockets or { }
				for i, socket in ipairs(sockets) do
					parts[#parts + 1] = socket.color
					local nextSocket = sockets[i + 1]
					if nextSocket then
						parts[#parts + 1] = (nextSocket.group == socket.group) and "-" or " "
					end
				end
				table.insert(out, {
					slot = slot.slotName,
					name = (item.title and item.title ~= "" and item.title) or item.name or item.baseName,
					baseName = item.baseName,
					sockets = table.concat(parts),
				})
			end
		end
	end
	return out
end

-- Tree tab: the nodes that matter in the loadout's passive tree. Small passives
-- are only counted. Masteries carry the chosen effect.
local treeOrder = { Keystone = 1, Ascendancy = 2, Notable = 3, Mastery = 4, Socket = 5 }
local function treeSummary(loadout)
	useLoadout(loadout)
	local spec = build.spec
	local used, ascUsed = spec:CountAllocNodes()
	local nodes = { }
	for id, node in pairs(spec.allocNodes) do
		local t = node.type
		local kind
		if node.ascendancyName then
			kind = (t == "Notable") and "Ascendancy" or nil
		elseif t == "Keystone" or t == "Notable" or t == "Mastery" or t == "Socket" then
			kind = t
		end
		if kind then
			local entry = { id = id, name = node.dn, type = kind }
			if t == "Mastery" then
				local effectId = spec.masterySelections and spec.masterySelections[id]
				local effect = effectId and spec.tree.masteryEffects and spec.tree.masteryEffects[effectId]
				if effect and effect.sd then
					entry.effect = table.concat(effect.sd, " / ")
				end
			end
			-- Cluster jewel notables live on generated nodes
			if node.expansionJewel or (type(id) == "number" and id >= 65536) then
				entry.cluster = true
			end
			table.insert(nodes, entry)
		end
	end
	table.sort(nodes, function(a, b)
		if a.type ~= b.type then
			return (treeOrder[a.type] or 9) < (treeOrder[b.type] or 9)
		end
		return tostring(a.name) < tostring(b.name)
	end)
	return {
		points = used,
		ascendancyPoints = ascUsed,
		className = spec.curClassName,
		ascendancy = spec.curAscendClassName ~= "None" and spec.curAscendClassName or nil,
		nodes = nodes,
	}
end

function handlers.tree()
	if not loaded then
		error("No build loaded")
	end
	local reply = { build = buildInfo() }
	reply.tree = treeSummary(buildLoadout)
	if liveLoadout and liveInfo and liveInfo.tree then
		reply.live = treeSummary(liveLoadout)
		reply.live.level = liveInfo.level
		reply.character = liveInfo.character
	end
	useLoadout(buildLoadout)
	return reply
end

-- Tree map (Loot Goblin window): the whole passive tree as PoB lays it out,
-- plus which nodes the build's loadout and the live character allocate.
-- Layout per tree version (the overlay caches it); generated cluster jewel
-- nodes and proxy groups are left out.
local mapKind = { Normal = 0, Notable = 1, Keystone = 2, Mastery = 3, Socket = 4, ClassStart = 5, AscendClassStart = 6 }
local function treeLayout(tree)
	local nodes, groups, links = { }, { }, { }
	local usedGroups = { }
	for id, node in pairs(tree.nodes) do
		if type(id) == "number" and id < 65536 and node.group and node.x and not node.isProxy and not node.group.isProxy
			and not node.isBlighted then
			local stats = { }
			for _, line in ipairs(node.sd or { }) do
				table.insert(stats, line)
			end
			table.insert(nodes, {
				id, math.floor(node.x + 0.5), math.floor(node.y + 0.5),
				mapKind[node.type] or 0, node.g, node.o or 0,
				node.dn or "", node.ascendancyName or false, stats,
			})
			usedGroups[node.g] = node.group
		end
	end
	for g, group in pairs(usedGroups) do
		groups[tostring(g)] = { math.floor(group.x + 0.5), math.floor(group.y + 0.5) }
	end
	for id, node in pairs(tree.nodes) do
		if type(id) == "number" and id < 65536 and node.group and not node.isProxy and not node.group.isProxy then
			for _, otherId in pairs(node.out or { }) do
				otherId = tonumber(otherId)
				local other = otherId and tree.nodes[otherId]
				if other and other.group and not other.isProxy and not other.group.isProxy
					and node.type ~= "ClassStart" and other.type ~= "ClassStart"
					and node.type ~= "Mastery" and other.type ~= "Mastery"
					and node.ascendancyName == other.ascendancyName then
					table.insert(links, { id, otherId })
				end
			end
		end
	end
	local radii = { }
	for i, r in ipairs(tree.orbitRadii or { }) do
		radii[i] = r
	end
	return { nodes = nodes, groups = groups, links = links, orbitRadii = radii }
end

local function allocated(loadout)
	useLoadout(loadout)
	local spec = build.spec
	local ids, masteries = { }, { }
	local generated = 0
	for id, node in pairs(spec.allocNodes) do
		if type(id) == "number" and id < 65536 then
			table.insert(ids, id)
			if node.type == "Mastery" then
				local effectId = spec.masterySelections and spec.masterySelections[id]
				local effect = effectId and spec.tree.masteryEffects and spec.tree.masteryEffects[effectId]
				if effect and effect.sd then
					masteries[tostring(id)] = table.concat(effect.sd, " / ")
				end
			end
		else
			generated = generated + 1
		end
	end
	table.sort(ids)
	local used, ascUsed = spec:CountAllocNodes()
	return {
		ids = ids, masteries = masteries, clusterNodes = generated,
		points = used, ascendancyPoints = ascUsed,
		className = spec.curClassName,
		ascendancy = spec.curAscendClassName ~= "None" and spec.curAscendClassName or nil,
		treeVersion = spec.treeVersion,
	}
end

function handlers.treeMap(req)
	if not loaded then
		error("No build loaded")
	end
	local reply = { build = buildInfo() }
	reply.alloc = allocated(buildLoadout)
	local version = reply.alloc.treeVersion
	reply.version = version
	if req.haveVersion ~= version then
		reply.layout = treeLayout(build.spec.tree)
	end
	if liveLoadout and liveInfo and liveInfo.tree then
		reply.live = allocated(liveLoadout)
		reply.live.level = liveInfo.level
		reply.character = liveInfo.character
	end
	useLoadout(buildLoadout)
	return reply
end

function handlers.gems()
	if not loaded then
		error("No build loaded")
	end
	local reply = { build = buildInfo() }
	reply.groups = socketGroups(buildLoadout)
	reply.items = socketedItems(buildLoadout)
	if liveLoadout and liveInfo and liveInfo.skills then
		reply.live = socketGroups(liveLoadout)
		reply.liveItems = socketedItems(liveLoadout)
		reply.character = liveInfo.character
	end
	useLoadout(buildLoadout)
	return reply
end

-- Levelling planner (Loot Goblin window, "Next" tab). No live character data:
-- the overlay sends the character level (Client.txt "is now level N") and the
-- quest passive points so far (campaign guide). Trees whose names carry a level
-- ("Level 30", "lvl 30", "Lv. 30") are the levelling steps; the step for the
-- character is the first one at or above its level. The order to take nodes is
-- worked out from the previous step's tree (or the class start): nearest
-- notable / keystone / jewel socket first, with the small passives on the way.
local function titleLevel(title)
	local t = tostring(title or ""):lower()
	local n = t:match("level%s*(%d+)") or t:match("lvl%.?%s*(%d+)") or t:match("lv%.?%s*(%d+)")
	n = tonumber(n)
	if n and n >= 1 and n <= 100 then
		return n
	end
end

local planKindRank = { Keystone = 1, Notable = 2, Socket = 3 }

local function isTreePoint(node)
	return not node.ascendancyName and node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
end

-- Order to allocate the target spec's nodes, starting from haveIds (a set).
local function allocationOrder(spec, haveIds)
	local have, remaining = { }, { }
	local startId = spec.curClass and spec.curClass.startNodeId
	if startId then
		have[startId] = true
	end
	for id in pairs(haveIds) do
		if spec.allocNodes[id] then
			have[id] = true
		end
	end
	local masteries = { }
	local left = 0
	for id, node in pairs(spec.allocNodes) do
		if isTreePoint(node) and not have[id] then
			if node.type == "Mastery" then
				table.insert(masteries, node)
			else
				remaining[id] = node
				left = left + 1
			end
		end
	end
	local order = { }
	while left > 0 do
		-- BFS over the target tree from everything we have
		local dist, parent, queue, head = { }, { }, { }, 1
		for id in pairs(have) do
			dist[id] = 0
			table.insert(queue, id)
		end
		local best, bestScore
		while queue[head] do
			local id = queue[head]
			head = head + 1
			local node = spec.nodes[id] or spec.allocNodes[id]
			for _, other in ipairs(node and node.linked or { }) do
				local oid = other.id
				if remaining[oid] and dist[oid] == nil then
					dist[oid] = dist[id] + 1
					parent[oid] = id
					table.insert(queue, oid)
					local rank = planKindRank[other.type] or 9
					local score = dist[oid] * 10 + rank
					if rank < 9 and (not bestScore or score < bestScore) then
						best, bestScore = oid, score
					end
				end
			end
		end
		if not best then
			-- only small passives left: nearest first
			for id, d in pairs(dist) do
				if remaining[id] and (not bestScore or d < bestScore or (d == bestScore and id < best)) then
					best, bestScore = id, d
				end
			end
		end
		if not best then
			break -- the rest isn't connected (shouldn't happen in a valid tree)
		end
		local path = { }
		local id = best
		while id and not have[id] do
			table.insert(path, 1, id)
			id = parent[id]
		end
		for _, pid in ipairs(path) do
			have[pid] = true
			remaining[pid] = nil
			left = left - 1
			table.insert(order, spec.allocNodes[pid])
		end
	end
	-- unreachable leftovers keep a stable order
	local rest = { }
	for _, node in pairs(remaining) do
		table.insert(rest, node)
	end
	table.sort(rest, function(a, b) return a.id < b.id end)
	for _, node in ipairs(rest) do
		table.insert(order, node)
	end
	-- a mastery can be taken once a node of its group is allocated
	for _, mastery in ipairs(masteries) do
		local at = #order
		for id in pairs(haveIds) do
			local node = spec.allocNodes[id]
			if node and node.g == mastery.g and node.type ~= "Mastery" then
				at = 0
			end
		end
		for i, node in ipairs(at > 0 and order or { }) do
			if node.g == mastery.g then
				at = i
				break
			end
		end
		table.insert(order, at + 1, mastery)
	end
	return order
end

local function planNode(spec, node)
	local entry = { id = node.id, name = node.dn, type = node.type }
	if node.type == "Mastery" then
		local effectId = spec.masterySelections and spec.masterySelections[node.id]
		local effect = effectId and spec.tree.masteryEffects and spec.tree.masteryEffects[effectId]
		if effect and effect.sd then
			entry.effect = table.concat(effect.sd, " / ")
		end
	end
	if node.type == "Normal" or node.type == "Socket" then
		entry.stats = table.concat(node.sd or { }, " / ")
	end
	return entry
end

local function planGems(skillSet)
	local out = { }
	for _, group in ipairs(skillSet and skillSet.socketGroupList or { }) do
		if group.enabled ~= false and not group.source then
			for _, gem in ipairs(group.gemList or { }) do
				local data = gem.gemData
				local effect = gem.grantedEffect or (data and data.grantedEffect)
				local name = (data and data.name) or gem.nameSpec
				if name and name ~= "" and gem.enabled ~= false then
					local levels = effect and effect.levels
					table.insert(out, {
						name = name,
						reqLevel = (levels and levels[1] and levels[1].levelRequirement) or 1,
						support = (effect and effect.support) and true or false,
						colour = effect and effect.color or nil,
						group = (group.label and group.label:match("%S")) and group.label or nil,
						slot = group.slot,
					})
				end
			end
		end
	end
	return out
end

-- the skill set that goes with a tree: same title, else same level in the title
local function skillSetFor(title, level)
	local skillsTab = build.skillsTab
	local byLevel
	for _, id in ipairs(skillsTab.skillSetOrderList) do
		local set = skillsTab.skillSets[id]
		if set then
			if (set.title or "Default") == title then
				return set, id
			end
			if level and not byLevel and titleLevel(set.title) == level then
				byLevel = id
			end
		end
	end
	if byLevel then
		return skillsTab.skillSets[byLevel], byLevel
	end
end

-- {"cmd":"plan","level":24,"questPoints":5}
function handlers.plan(req)
	if not loaded then
		error("No build loaded")
	end
	useLoadout(buildLoadout)
	local treeTab = build.treeTab
	local level = math.max(1, math.min(100, math.floor(tonumber(req.level) or 1)))
	local questPoints = math.max(0, math.min(30, math.floor(tonumber(req.questPoints) or 0)))
	local phases = { }
	for index, spec in ipairs(treeTab.specList) do
		local l = titleLevel(spec.title)
		if l and (not liveLoadout or index ~= liveLoadout.spec) then
			table.insert(phases, { spec = index, level = l, title = spec.title or "Default" })
		end
	end
	table.sort(phases, function(a, b)
		if a.level ~= b.level then return a.level < b.level end
		return a.spec < b.spec
	end)
	-- the loadout picked in the overlay is the end goal when its tree has no level
	local selected = buildLoadout.spec
	if not titleLevel(treeTab.specList[selected] and treeTab.specList[selected].title) then
		table.insert(phases, { spec = selected, title = treeTab.specList[selected].title or "Default" })
	end
	local current = #phases
	for i, phase in ipairs(phases) do
		if not phase.level or phase.level >= level then
			current = i
			break
		end
	end
	local phase = phases[current]
	local spec = treeTab.specList[phase.spec]
	local previous = phases[current - 1]
	local base = { }
	local refund = { }
	if previous then
		local prevSpec = treeTab.specList[previous.spec]
		for id, node in pairs(prevSpec.allocNodes) do
			if isTreePoint(node) then
				if spec.allocNodes[id] then
					base[id] = true
				else
					table.insert(refund, planNode(prevSpec, node))
				end
			end
		end
	end
	local kept = 0
	local keptIds = { }
	for id in pairs(base) do
		kept = kept + 1
		table.insert(keptIds, id)
	end
	table.sort(keptIds)
	local order = allocationOrder(spec, base)
	local available = level - 1 + questPoints
	local taken = math.max(0, math.min(#order, available - kept))
	local nodes = { }
	for _, node in ipairs(order) do
		table.insert(nodes, planNode(spec, node))
	end
	-- ascendancy: what this tree adds over the previous one
	local ascendancy = { }
	local prevAsc = previous and treeTab.specList[previous.spec].allocNodes or { }
	for id, node in pairs(spec.allocNodes) do
		if node.ascendancyName and node.type == "Notable" and not node.isMultipleChoiceOption and not prevAsc[id] then
			table.insert(ascendancy, { id = id, name = node.dn })
		end
	end
	table.sort(ascendancy, function(a, b) return a.name < b.name end)
	local skillSet, skillSetId = skillSetFor(phase.title, phase.level)
	local prevSkillSet = previous and skillSetFor(previous.title, previous.level)
	local nextPhase = phases[current + 1]
	local nextSkillSet = nextPhase and skillSetFor(nextPhase.title, nextPhase.level)
	if not skillSet then
		skillSetId = buildLoadout.skillSet
		skillSet = build.skillsTab.skillSets[skillSetId]
	end
	local list = { }
	for _, p in ipairs(phases) do
		table.insert(list, { title = p.title, level = p.level })
	end
	return {
		build = buildInfo(),
		level = level,
		questPoints = questPoints,
		available = available,
		phases = list,
		phase = current,
		className = spec.curClassName,
		ascendancyClass = spec.curAscendClassName ~= "None" and spec.curAscendClassName or nil,
		kept = kept,
		keptIds = keptIds,
		taken = taken,
		order = nodes,
		refund = refund,
		ascendancy = ascendancy,
		skillSet = skillSet and (skillSet.title or "Default") or nil,
		gems = planGems(skillSet),
		previousGems = prevSkillSet and prevSkillSet ~= skillSet and planGems(prevSkillSet) or nil,
		-- gems of the next levelling step (swap them in when the character passes this step's level)
		nextGems = nextSkillSet and nextSkillSet ~= skillSet and planGems(nextSkillSet) or nil,
		nextSkillSet = nextSkillSet and nextSkillSet ~= skillSet and (nextSkillSet.title or "Default") or nil,
		-- Configuration tab: "None" (kill all), "Oak", "Kraityn", "Alira"
		bandit = build.configTab.input.bandit or "None",
	}
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
