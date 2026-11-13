-- Path of Building (Deathloom fork): headless build sync for Loot Goblin.
-- cspell:ignore Deathloom FINDDATAW mindepth maxdepth printf loadstring wfopen
--
-- Lets the overlay sign in to GitHub and Pull / Push builds without opening the
-- PoB window. It reuses PoB's own sync code (Modules/BuildSync*.lua), the same
-- BuildSync.json and the same Windows Credential Manager entries, so PoB and
-- Loot Goblin share one sign-in and one sync state. PoB itself is not loaded.
--
-- Run from the src folder:
--   ..\runtime\PoBHeadless.exe SyncServer.lua --documents "C:\Users\me\Documents"
-- Options:
--   --documents <dir>  Documents folder (needed for the copy bundled in Loot Goblin)
--   --user <dir>       PoB's user folder (where BuildSync.json lives); default: like PoB
--   --test-base <url>  tests only: send all GitHub requests to this server
--
-- Protocol (same as ImpactServer.lua): one JSON request per line on stdin, one
-- JSON reply per line on stdout, each prefixed "@pob ". Progress lines during
-- Pull/Push: {"event":"progress","id":n,"text":"..."}.
--
--   {"id":1,"cmd":"status"}
--   {"id":2,"cmd":"configure","player":"Me","autoSync":true}
--   {"id":3,"cmd":"signInStart"}                     -> userCode, verificationUri, deviceCode, interval, expiresIn
--   {"id":4,"cmd":"signInPoll","deviceCode":"..."}   -> state: pending | slow_down | done | error
--   {"id":5,"cmd":"signOut"}
--   {"id":6,"cmd":"pull"} / {"cmd":"push"} / {"cmd":"syncNow"} -> success, lines (+ status)
--   {"id":7,"cmd":"report","key":"...","title":"...","body":"...","seen":"..."}
--       Problem report as a GitHub issue in the builds repo (label auto-report), with the
--       user's own sign-in. Same key already open -> a comment ("seen") instead of a new issue.
--   {"id":8,"cmd":"quit"}

local realStdout = io.stdout
local function logErr(...)
	local parts = { }
	for i = 1, select("#", ...) do
		parts[i] = tostring(select(i, ...))
	end
	io.stderr:write(table.concat(parts, "\t"), "\n")
	io.stderr:flush()
end
print = logErr
ConPrintf = function(fmt, ...) logErr(string.format(fmt, ...)) end

local dkjson = require("dkjson")

local function send(tbl)
	realStdout:write("@pob ", dkjson.encode(tbl), "\n")
	realStdout:flush()
end

local opts = { }
do
	local i = 1
	while arg and arg[i] do
		local name = arg[i]:match("^%-%-(.+)$")
		if name and arg[i + 1] then
			opts[name] = arg[i + 1]
			i = i + 2
		else
			i = i + 1
		end
	end
end

---------------------------------------------------------------------------
-- File helpers PoB normally gets from its runtime (NewFileSearch, MakeDir)
---------------------------------------------------------------------------
local isWindows = package.config:sub(1, 1) == "\\"
local ffiOk, ffi = pcall(require, "ffi")

if isWindows and ffiOk then
	pcall(ffi.cdef, [[
		typedef struct {
			uint32_t dwFileAttributes;
			uint32_t times[6];
			uint32_t nFileSizeHigh, nFileSizeLow, dwReserved0, dwReserved1;
			uint16_t cFileName[260];
			uint16_t cAlternateFileName[14];
		} PoBSyncSrv_FINDDATAW;
		void* FindFirstFileW(const uint16_t* name, PoBSyncSrv_FINDDATAW* data);
		int FindNextFileW(void* handle, PoBSyncSrv_FINDDATAW* data);
		int FindClose(void* handle);
		int CreateDirectoryW(const uint16_t* path, void* security);
		int MultiByteToWideChar(uint32_t cp, uint32_t flags, const char* str, int len, uint16_t* out, int outLen);
		int WideCharToMultiByte(uint32_t cp, uint32_t flags, const uint16_t* str, int len, char* out, int outLen, const char* def, int* usedDef);
	]])
	local k32 = ffi.C
	local CP_UTF8 = 65001
	local FILE_ATTRIBUTE_DIRECTORY = 0x10
	local function wide(s)
		local n = k32.MultiByteToWideChar(CP_UTF8, 0, s, #s, nil, 0)
		local buf = ffi.new("uint16_t[?]", n + 1)
		k32.MultiByteToWideChar(CP_UTF8, 0, s, #s, buf, n)
		buf[n] = 0
		return buf
	end
	local function utf8(w)
		local n = k32.WideCharToMultiByte(CP_UTF8, 0, w, -1, nil, 0, nil, nil)
		local buf = ffi.new("char[?]", n)
		k32.WideCharToMultiByte(CP_UTF8, 0, w, -1, buf, n, nil, nil)
		return ffi.string(buf)
	end
	function NewFileSearch(spec, findDirectories)
		local data = ffi.new("PoBSyncSrv_FINDDATAW")
		local handle = k32.FindFirstFileW(wide(spec), data)
		if ffi.cast("intptr_t", handle) == -1 then
			return nil
		end
		local names = { }
		repeat
			local name = utf8(data.cFileName)
			local isDir = bit.band(data.dwFileAttributes, FILE_ATTRIBUTE_DIRECTORY) ~= 0
			if name ~= "." and name ~= ".." and isDir == (findDirectories == true) then
				names[#names + 1] = name
			end
		until k32.FindNextFileW(handle, data) == 0
		k32.FindClose(handle)
		if #names == 0 then
			return nil
		end
		local i = 1
		return {
			GetFileName = function() return names[i] end,
			NextFile = function()
				i = i + 1
				return names[i] ~= nil
			end,
		}
	end
	function MakeDir(path)
		k32.CreateDirectoryW(wide(path), nil)
		return true
	end
else
	-- Linux / tests
	local function shellQuote(s)
		return "'"..s:gsub("'", "'\\''").."'"
	end
	function NewFileSearch(spec, findDirectories)
		local dir = spec:match("^(.*)[/\\]%*$") or "."
		local p = io.popen("find "..shellQuote(dir).." -mindepth 1 -maxdepth 1 -type "..(findDirectories and "d" or "f").." -printf '%f\\n' 2>/dev/null")
		local names = { }
		for line in p:lines() do
			names[#names + 1] = line
		end
		p:close()
		table.sort(names)
		if #names == 0 then
			return nil
		end
		local i = 1
		return {
			GetFileName = function() return names[i] end,
			NextFile = function()
				i = i + 1
				return names[i] ~= nil
			end,
		}
	end
	function MakeDir(path)
		os.execute("mkdir -p "..shellQuote(path))
		return true
	end
end

---------------------------------------------------------------------------
-- The bits of PoB that BuildSync.lua uses
---------------------------------------------------------------------------
common = { sha1 = require("sha1") }
launch = { versionNumber = "?" }
main = { popups = { } }
do
	-- Loot Goblin's copy keeps it in src, a git clone in the repo root
	local f = io.open("manifest.xml", "rb") or io.open("../manifest.xml", "rb")
	if f then
		launch.versionNumber = f:read("*a"):match("<Version number=\"([^\"]+)\"") or "?"
		f:close()
	end
end

local function withSlash(path)
	return path:match("[\\/]$") and path or path.."/"
end

local function readAll(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	return text
end

local function xmlUnescape(s)
	return (s:gsub("&quot;", "\""):gsub("&apos;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
end

-- Same folders as PoB (Modules/Main.lua): bundled copy keeps its data in Documents\Loot Goblin,
-- a git clone (dev mode) in its src folder.
local bundled = readAll("bundled.cfg") ~= nil
local documents = opts.documents
local pathError
if opts.user then
	main.userPath = withSlash(opts.user)
elseif bundled then
	if documents then
		main.userPath = withSlash(documents).."Loot Goblin/PathOfBuilding/"
	else
		pathError = "SyncServer needs --documents for the bundled Path of Building"
	end
else
	main.userPath = "./"
end

-- Build save path: BuildSync.json remembers PoB's exact value; else Settings.xml; else PoB's default
local function resolveBuildPath()
	local data = dkjson.decode(readAll(main.userPath.."BuildSync.json") or "")
	if type(data) == "table" and type(data.buildPath) == "string" and data.buildPath ~= "" then
		return data.buildPath
	end
	local settings = readAll(main.userPath.."Settings.xml")
	local custom = settings and settings:match("buildPath=\"([^\"]*)\"")
	if custom and custom ~= "" then
		return xmlUnescape(custom)
	end
	local bundledBuilds = bundled and main.userPath:match("^(.*[\\/])PathOfBuilding[\\/]$")
	return bundledBuilds and bundledBuilds.."Builds/" or main.userPath.."Builds/"
end

local currentId
local function progress(fmt, ...)
	send({ event = "progress", id = currentId, text = string.format(fmt, ...) })
end

local sync
local function setup()
	if pathError then
		error(pathError)
	end
	if not sync then
		MakeDir(main.userPath)
		sync = require("Modules.BuildSync")
		-- BuildSync.lua sets its own (status line) version when it loads
		BuildSyncProgress = progress
		-- Run the worker in this process (no sub-scripts here); this process exists only to sync
		function sync:LaunchWorker(mode, payload, callback)
			local source = readAll("Modules/BuildSyncWorker.lua")
			if not source then
				callback(nil, "Couldn't find Modules/BuildSyncWorker.lua")
				return
			end
			if opts["test-base"] then
				source = source:gsub("https://api%.github%.com", opts["test-base"])
			end
			local chunk, loadErr = loadstring(source, "=BuildSyncWorker.lua")
			if not chunk then
				callback(nil, "Sync worker error: "..tostring(loadErr))
				return
			end
			local s = self.settings
			payload.owner, payload.repo, payload.branch = s.owner, s.repo, s.branch
			payload.buildPath = main.buildPath
			payload.userAgent = "Loot Goblin (Path of Building fork/"..tostring(launch.versionNumber)..")"
			local ok, res, err = pcall(chunk, mode, dkjson.encode(payload), nil, nil, false)
			if not ok then
				callback(nil, "Sync worker error: "..tostring(res))
			elseif not res then
				callback(nil, err or "Unknown error")
			else
				callback(dkjson.decode(res), nil)
			end
		end
		if opts["test-base"] then
			local base = opts["test-base"]
			sync.auth.deviceCodeUrl = base.."/login/device/code"
			sync.auth.tokenUrl = base.."/login/oauth/access_token"
		end
	end
	main.buildPath = resolveBuildPath()
	sync:Reload()
	return sync
end


local function stripColours(text)
	return (tostring(text):gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", ""))
end

local function status()
	local s = setup()
	local session = s:GetSession()
	return {
		credAvailable = s.cred.available == true,
		signedIn = session ~= nil,
		login = session and session.login or nil,
		usingToken = session == nil and s:HasToken(),
		settings = s.settings,
		prefs = s.prefs,
		buildPath = main.buildPath,
		userPath = main.userPath,
		bundled = bundled,
	}
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------
local handlers = { }

function handlers.status()
	return status()
end

function handlers.configure(req)
	local s = setup()
	if req.player ~= nil then
		local player = tostring(req.player):gsub("^%s+", ""):gsub("%s+$", "")
		if player ~= "" and not s.core.validPlayer(player) then
			error("Player folder can only use letters, numbers, _ - and .", 0)
		end
		s.settings.player = player
		if player ~= "" then
			MakeDir(main.buildPath..player)
		end
	end
	if type(req.autoSync) == "boolean" then
		s.prefs.autoSync = req.autoSync
	end
	s.prefs.setupAsked = true
	s:Save()
	return status()
end

function handlers.signInStart()
	local s = setup()
	if not s.cred.available then
		error("Windows Credential Manager isn't available, so the sign-in can't be stored.")
	end
	local reply
	s:LaunchWorker("deviceCode", { url = s.auth.deviceCodeUrl, body = s.auth.deviceCodeBody() }, function(resp, errMsg)
		if not resp or not resp.device_code then
			error("Couldn't start the sign-in: "..tostring(errMsg or s.auth.describeError(resp)), 0)
		end
		reply = {
			deviceCode = resp.device_code,
			userCode = resp.user_code,
			verificationUri = resp.verification_uri or s.auth.verifyUrl,
			interval = tonumber(resp.interval) or 5,
			expiresIn = tonumber(resp.expires_in) or 900,
		}
	end)
	return reply
end

function handlers.signInPoll(req)
	local s = setup()
	if type(req.deviceCode) ~= "string" or req.deviceCode == "" then
		error("deviceCode missing")
	end
	local reply
	s:LaunchWorker("devicePoll", { url = s.auth.tokenUrl, body = s.auth.pollBody(req.deviceCode) }, function(resp)
		local outcome = resp and s.auth.pollOutcome(resp) or "network"
		if outcome == "pending" or outcome == "network" then
			reply = { state = "pending" }
		elseif outcome == "slow_down" then
			reply = { state = "slow_down", interval = tonumber(resp.interval) }
		elseif outcome == "done" then
			local session = s.auth.sessionFromToken(resp, os.time())
			local who
			s:LaunchWorker("whoami", { token = session.access }, function(res)
				who = res
			end)
			session.login = who and who.login
			if not s:SaveSession(session) then
				reply = { state = "error", error = "Couldn't save the sign-in to Windows Credential Manager." }
				return
			end
			s.prefs.setupAsked = true
			if s.settings.player == "" and session.login and s.core.validPlayer(session.login) then
				s.settings.player = session.login
				MakeDir(main.buildPath..session.login)
			end
			s:Save()
			reply = { state = "done", login = session.login }
			if who and who.repoCode and who.repoCode ~= 200 then
				reply.hint = s.auth.repoAccessHint(who.repoCode, s.settings.owner, s.settings.repo)
			end
		else
			reply = { state = "error", error = s.auth.describeError(resp) }
		end
	end)
	return reply
end

function handlers.signOut()
	local s = setup()
	s:SignOut()
	return status()
end

local function runOps(ops)
	local s = setup()
	s.collected = { }
	local allOk = true
	local function step(i)
		local op = ops[i]
		if not op then
			return
		end
		s[op](s, function(ok)
			if ok == false then
				allOk = false
			end
			step(i + 1)
		end, "collect")
	end
	step(1)
	local lines = { }
	for _, line in ipairs(s.collected) do
		table.insert(lines, stripColours(line))
	end
	s.collected = nil
	local reply = status()
	reply.success = allOk
	reply.lines = lines
	return reply
end

function handlers.pull()
	return runOps({ "Pull" })
end

function handlers.push()
	return runOps({ "Push" })
end

function handlers.syncNow()
	return runOps({ "Pull", "Push" })
end

function handlers.report(req)
	local s = setup()
	if type(req.key) ~= "string" or not req.key:match("^[%w%-]+$") or type(req.title) ~= "string" or type(req.body) ~= "string" then
		error("report needs key, title and body", 0)
	end
	if not s:HasAuth() then
		return { sent = false, reason = "Not signed in to GitHub" }
	end
	local token, tokenErr
	s:EnsureToken(function(t, e) token, tokenErr = t, e end)
	if not token then
		return { sent = false, reason = tokenErr }
	end
	local repoPath = "/repos/"..s.core.encodePath(s.settings.owner).."/"..s.core.encodePath(s.settings.repo)
	local function api(method, path, body)
		local out
		s:LaunchWorker("api", { token = token, method = method, path = repoPath..path, body = body and dkjson.encode(body) }, function(res, err)
			out = res or { code = 0, error = err }
		end)
		return out
	end
	local marker = "<!-- loot-goblin-report:"..req.key.." -->"
	local list = api("GET", "/issues?state=open&labels=auto-report&per_page=100")
	if list.code ~= 200 then
		return { sent = false, reason = "GitHub HTTP "..tostring(list.code)..(list.error and (": "..list.error) or "") }
	end
	for _, issue in ipairs(type(list.body) == "table" and list.body or { }) do
		if type(issue) == "table" and type(issue.body) == "string" and issue.body:find(marker, 1, true) then
			local res = api("POST", "/issues/"..tostring(issue.number).."/comments", { body = tostring(req.seen or "Seen again.") })
			return { sent = res.code == 201, issue = issue.number, comment = true, reason = res.code ~= 201 and ("GitHub HTTP "..tostring(res.code)) or nil }
		end
	end
	local res = api("POST", "/issues", { title = req.title, body = req.body.."\n\n"..marker, labels = { "auto-report" } })
	local number = type(res.body) == "table" and res.body.number or nil
	return { sent = res.code == 201, issue = number, reason = res.code ~= 201 and ("GitHub HTTP "..tostring(res.code)..(res.error and (": "..res.error) or "")) or nil }
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
				currentId = req.id
				local ok, result = pcall(handler, req)
				if ok and type(result) == "table" then
					result.id = req.id
					result.ok = true
					send(result)
				else
					local msg = ok and "No reply" or tostring(result)
					logErr("Error in " .. tostring(req.cmd) .. ": " .. msg)
					send({ id = req.id, ok = false, error = msg })
				end
				if req.cmd == "quit" then
					break
				end
			end
		end
	end
end
