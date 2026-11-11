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
--   {"id":5,"cmd":"quit"}
--
-- Replies: {"id":n,"ok":true,...} or {"id":n,"ok":false,"error":"..."}

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

local function summarise(baseOutput, compareOutput)
	local out = { }
	for _, stat in ipairs(summaryStats) do
		local new = compareOutput[stat.key]
		local old = baseOutput[stat.key]
		if type(new) == "number" and type(old) == "number" and math.abs(new - old) > 0.001 then
			local entry = { stat = stat.key, label = stat.label, old = old, new = new, diff = new - old }
			if old ~= 0 then
				entry.pct = (new / old - 1) * 100
			end
			table.insert(out, entry)
		end
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
			TotalEHP = output.TotalEHP,
			Life = output.Life,
			EnergyShield = output.EnergyShield,
		},
	}
end

local loaded = false

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
	loadBuildFromXML(xml, name)
	-- A couple of extra frames so deferred rebuilds (sockets, calcs) settle
	runCallback("OnFrame")
	if not build.calcsTab.mainOutput then
		error("PoB could not calculate this build")
	end
	loaded = true
	return { build = buildInfo() }
end

function handlers.info()
	if not loaded then
		error("No build loaded")
	end
	return { build = buildInfo() }
end

function handlers.impact(req)
	if not loaded then
		error("No build loaded")
	end
	if type(req.item) ~= "string" or req.item == "" then
		error("impact needs 'item' (the item text copied from the game)")
	end
	local itemsTab = build.itemsTab
	local itemText = req.item:gsub("\r\n", "\n")
	local item = new("Item"):Item(itemText)
	if not item.base then
		error("PoB doesn't recognise this item's base type")
	end
	itemsTab:CopyAnointsAndEldritchImplicits(item, main.migrateEldritchImplicits, false)
	item:NormaliseQuality()
	item:BuildModList()

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

	return {
		item = {
			name = item.name,
			rarity = item.rarity,
			baseName = item.baseName,
			type = item.base.type,
		},
		compares = compares,
		lines = extraLines,
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
