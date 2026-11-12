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
