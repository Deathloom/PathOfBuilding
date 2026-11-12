-- Path of Building (Deathloom fork)
-- cspell:ignore Deathloom prefs organisation FFAA Syncable syncable normalise CREDENTIALW FILETIME advapi
--
-- Module: Build Sync
-- Push/Pull builds to a shared GitHub repo through the GitHub REST API.
--   Pull: download every build under the repo folder (all players) into the build save path.
--   Push: upload changed files from your own player folder only.
-- Sign-in: GitHub App device flow (Modules/BuildSyncAuth.lua). The user token + refresh token live in
-- Windows Credential Manager. A pasted fine-grained token still works as a fallback.
-- Nothing secret is ever written to Settings, BuildSync.json, the builds folder or the repo.
-- Auto sync (on by default once signed in): Pull when PoB starts, Push your own folder a few seconds
-- after a build is saved. Same conflict rules as manual Pull/Push.
--
local core = require("Modules.BuildSyncCore")
local auth = require("Modules.BuildSyncAuth")
local dkjson = require("dkjson")

local t_insert = table.insert

local sync = {
	credentialTarget = "PathOfBuilding-Fork/GitHubBuildSync",
	sessionTarget = "PathOfBuilding-Fork/GitHubApp",
	busy = false,
	prefs = {
		autoSync = true,     -- pull on start, push after save
		setupAsked = false,  -- first-run "share builds?" prompt shown
	},
	autoPushDelay = 8,       -- seconds after the last save
	status = nil,
	settings = {
		owner = "POE-Builds",
		repo = "poe-builds",
		branch = "main",
		root = "poe1",
		player = "",
	},
	stateByKey = { },
}

---------------------------------------------------------------------------
-- Windows Credential Manager (LuaJIT FFI, advapi32)
---------------------------------------------------------------------------
local cred = { }
do
	local ok, ffi = pcall(require, "ffi")
	if ok and ffi.os == "Windows" then
		pcall(ffi.cdef, [[
			typedef struct { uint32_t dwLowDateTime; uint32_t dwHighDateTime; } PoBSync_FILETIME;
			typedef struct {
				uint32_t Flags;
				uint32_t Type;
				uint16_t* TargetName;
				uint16_t* Comment;
				PoBSync_FILETIME LastWritten;
				uint32_t CredentialBlobSize;
				uint8_t* CredentialBlob;
				uint32_t Persist;
				uint32_t AttributeCount;
				void* Attributes;
				uint16_t* TargetAlias;
				uint16_t* UserName;
			} PoBSync_CREDENTIALW;
			int CredReadW(const uint16_t* TargetName, uint32_t Type, uint32_t Flags, PoBSync_CREDENTIALW** Credential);
			int CredWriteW(PoBSync_CREDENTIALW* Credential, uint32_t Flags);
			int CredDeleteW(const uint16_t* TargetName, uint32_t Type, uint32_t Flags);
			void CredFree(void* Buffer);
		]])
		local okLib, advapi = pcall(ffi.load, "advapi32")
		if okLib then
			local CRED_TYPE_GENERIC = 1
			local CRED_PERSIST_LOCAL_MACHINE = 2
			local function wide(s)
				local buf = ffi.new("uint16_t[?]", #s + 1)
				for i = 1, #s do
					buf[i - 1] = s:byte(i)
				end
				buf[#s] = 0
				return buf
			end
			cred.available = true
			function cred.read(target)
				local out = ffi.new("PoBSync_CREDENTIALW*[1]")
				if advapi.CredReadW(wide(target), CRED_TYPE_GENERIC, 0, out) == 0 then
					return nil
				end
				local c = out[0]
				local value = ffi.string(c.CredentialBlob, c.CredentialBlobSize)
				advapi.CredFree(c)
				return value
			end
			function cred.write(target, userName, secret)
				local c = ffi.new("PoBSync_CREDENTIALW")
				local targetW, userW = wide(target), wide(userName)
				local blob = ffi.new("uint8_t[?]", #secret)
				ffi.copy(blob, secret, #secret)
				c.Type = CRED_TYPE_GENERIC
				c.TargetName = targetW
				c.UserName = userW
				c.CredentialBlobSize = #secret
				c.CredentialBlob = blob
				c.Persist = CRED_PERSIST_LOCAL_MACHINE
				return advapi.CredWriteW(c, 0) ~= 0
			end
			function cred.delete(target)
				return advapi.CredDeleteW(wide(target), CRED_TYPE_GENERIC, 0) ~= 0
			end
		end
	end
	if not cred.available then
		function cred.read() return nil end
		function cred.write() return false end
		function cred.delete() return false end
	end
end

-- Fallback: pasted fine-grained token
function sync:GetToken()
	return cred.read(self.credentialTarget)
end

function sync:HasToken()
	local token = self:GetToken()
	return token ~= nil and token ~= ""
end

-- GitHub App sign-in: { access, accessExp, refresh, refreshExp, login }
function sync:GetSession()
	local text = cred.read(self.sessionTarget)
	if text and text ~= "" then
		local session = dkjson.decode(text)
		if type(session) == "table" and session.access then
			return session
		end
	end
end

function sync:SaveSession(session)
	return cred.write(self.sessionTarget, session.login or "github-app", dkjson.encode(session))
end

function sync:SignOut()
	cred.delete(self.sessionTarget)
end

function sync:SignedInAs()
	local session = self:GetSession()
	return session and (session.login or "GitHub user")
end

function sync:HasAuth()
	return self:GetSession() ~= nil or self:HasToken()
end

-- Calls callback(token) or callback(nil, err). Renews the app token first when it's about to expire.
function sync:EnsureToken(callback)
	local session = self:GetSession()
	local status = auth.tokenStatus(session, os.time())
	if session and status == "ok" then
		callback(session.access)
		return
	end
	local function fallback(err)
		if self:HasToken() then
			callback(self:GetToken())
		else
			callback(nil, err)
		end
	end
	if session and status == "refresh" then
		self.status = "Renewing GitHub sign-in..."
		self:LaunchWorker("refresh", { url = auth.tokenUrl, body = auth.refreshBody(session.refresh) }, function(resp, errMsg)
			if not resp then
				-- Network trouble: keep the session, try again next time
				fallback("Couldn't renew the GitHub sign-in: "..tostring(errMsg))
				return
			end
			local fresh, err = auth.sessionFromToken(resp, os.time(), session.login)
			if not fresh then
				self:SignOut()
				fallback(err.." (Sync...)")
				return
			end
			self:SaveSession(fresh)
			callback(fresh.access)
		end)
		return
	end
	if session then
		self:SignOut()
		fallback("Your GitHub sign-in has run out. Sign in again (Sync...).")
		return
	end
	fallback("Not signed in to GitHub yet (Sync...).")
end

---------------------------------------------------------------------------
-- Settings and sync state (BuildSync.json next to Settings.xml; no secrets in it)
---------------------------------------------------------------------------
function sync:SettingsFile()
	return main.userPath.."BuildSync.json"
end

function sync:Load()
	if self.loaded or not main.userPath then
		return
	end
	self.loaded = true
	local f = io.open(self:SettingsFile(), "rb")
	if not f then
		return
	end
	local data = dkjson.decode(f:read("*a"))
	f:close()
	if type(data) == "table" then
		if type(data.settings) == "table" then
			for k in pairs(self.settings) do
				if type(data.settings[k]) == "string" then
					self.settings[k] = data.settings[k]
				end
			end
		end
		if type(data.state) == "table" then
			self.stateByKey = data.state
		end
		if type(data.prefs) == "table" then
			for k in pairs(self.prefs) do
				if type(data.prefs[k]) == "boolean" then
					self.prefs[k] = data.prefs[k]
				end
			end
		end
	end
end

function sync:Save()
	local f = io.open(self:SettingsFile(), "wb")
	if not f then
		return
	end
	f:write(dkjson.encode({ settings = self.settings, prefs = self.prefs, state = self.stateByKey }, { indent = true }))
	f:close()
end

function sync:StateKey()
	local s = self.settings
	return s.owner.."/"..s.repo.."@"..s.branch..":"..core.normaliseRoot(s.root).."|"..main.buildPath
end

function sync:State()
	local key = self:StateKey()
	self.stateByKey[key] = self.stateByKey[key] or { }
	return self.stateByKey[key]
end

---------------------------------------------------------------------------
-- Local files
---------------------------------------------------------------------------
local function readFile(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

local function localSha(rel)
	local content = readFile(main.buildPath..rel)
	if content then
		return core.blobSha(content, common.sha1.sha1)
	end
end

-- { [rel] = sha } for every syncable file below main.buildPath..subPath
local function scanFolder(subPath, out)
	out = out or { }
	local handle = NewFileSearch(main.buildPath..subPath.."*")
	while handle do
		local rel = subPath..handle:GetFileName()
		if core.isSyncable(rel) then
			out[rel] = localSha(rel)
		end
		if not handle:NextFile() then break end
	end
	handle = NewFileSearch(main.buildPath..subPath.."*", true)
	local dirs = { }
	while handle do
		local name = handle:GetFileName()
		if name:sub(1, 1) ~= "." then
			t_insert(dirs, name)
		end
		if not handle:NextFile() then break end
	end
	for _, name in ipairs(dirs) do
		scanFolder(subPath..name.."/", out)
	end
	return out
end

---------------------------------------------------------------------------
-- Background worker
---------------------------------------------------------------------------
-- Called from the worker through the sub-script call list
function BuildSyncProgress(fmt, ...)
	sync.status = string.format(fmt, ...)
end

-- Repo operations: get a (fresh) token first
function sync:RunWorker(mode, payload, callback)
	self:EnsureToken(function(token, err)
		if not token then
			callback(nil, err)
			return
		end
		payload.token = token
		self:LaunchWorker(mode, payload, callback)
	end)
end

function sync:LaunchWorker(mode, payload, callback)
	local f = io.open("Modules/BuildSyncWorker.lua", "rb")
	if not f then
		callback(nil, "Couldn't find Modules/BuildSyncWorker.lua")
		return
	end
	-- Wrap the worker so a Lua error still reports back instead of leaving the buttons stuck on "busy"
	local script = "local __args = { ... }\nlocal __ok, __res, __err = pcall(function(...)\n"..f:read("*a").."\nend, unpack(__args))\n"
		.."if not __ok then return nil, 'Sync worker error: '..tostring(__res) end\nreturn __res, __err\n"
	f:close()
	local s = self.settings
	payload.owner, payload.repo, payload.branch = s.owner, s.repo, s.branch
	payload.buildPath = main.buildPath
	payload.userAgent = "Path of Building fork/"..tostring(launch.versionNumber)
	local id = LaunchSubScript(script, "MakeDir", "ConPrintf,BuildSyncProgress", mode, dkjson.encode(payload), launch.connectionProtocol, launch.proxyURL, launch.noSSL or false)
	if not id then
		callback(nil, "Couldn't start the background sync task")
		return
	end
	launch:RegisterSubScript(id, function(resultJson, errMsg)
		if not resultJson then
			callback(nil, errMsg or "Unknown error")
			return
		end
		callback(dkjson.decode(resultJson), nil)
	end)
end

-- out: "popup" (manual button), "quiet" (auto sync: toast only when something happened),
-- "collect" (Sync now: lines gathered, one popup at the end)
function sync:Begin(status, out)
	self.busy = true
	self.status = status
	self.out = out or "popup"
end

function sync:Finish(title, lines, onDone, notable, ok)
	self.busy = false
	self.status = nil
	self:Save()
	local out = self.out
	self.out = nil
	ok = ok ~= false
	if out == "collect" then
		self.collected = self.collected or { }
		t_insert(self.collected, "^7"..title..":")
		for _, line in ipairs(lines) do
			t_insert(self.collected, line)
		end
	elseif out == "quiet" then
		local summary = (not ok and lines[2]) and (lines[1].." "..lines[2]) or lines[1]
		self.lastResult = { time = os.time(), text = title..": "..summary:gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", ""), ok = ok }
		if notable or not ok then
			ToastNotification:Add(title.." (auto sync)\n"..table.concat(lines, "\n", 1, math.min(#lines, 6)))
		end
	else
		main:OpenMessagePopup(title, table.concat(lines, "\n"))
	end
	if onDone then
		onDone(ok)
	end
end

function sync:CheckReady(forPush)
	self:Load()
	local s = self.settings
	if s.owner == "" or s.repo == "" or s.branch == "" then
		return "Set the GitHub repo first (Sync settings)."
	end
	if not cred.available then
		return "Windows Credential Manager isn't available, so no sign-in can be stored."
	end
	if not self:HasAuth() then
		return "Not signed in to GitHub yet. Open Sync... and choose Sign in with GitHub."
	end
	if forPush and not core.validPlayer(s.player) then
		return "Set your player folder name first (Sync settings)."
	end
end

local function listLines(lines, header, items, max)
	if #items == 0 then
		return
	end
	t_insert(lines, header)
	for i, item in ipairs(items) do
		if i > max then
			t_insert(lines, "   ...and "..(#items - max).." more")
			break
		end
		t_insert(lines, "   "..item)
	end
end

---------------------------------------------------------------------------
-- Pull
---------------------------------------------------------------------------
function sync:Pull(onDone, out)
	if self.busy then return end
	local err = self:CheckReady(false)
	if err then
		self.out = out
		self:Finish("Pull builds", { err }, onDone, false, false)
		return
	end
	local root = self.settings.root
	self:Begin("Listing files on GitHub...", out)
	self:RunWorker("tree", { }, function(tree, errMsg)
		if not tree then
			self:Finish("Pull builds", { "^1Pull failed:", "^7"..tostring(errMsg) }, onDone, true, false)
			return
		end
		local state = self:State()
		local plan = core.planPull(tree.entries, localSha, state, root)
		for path, sha in pairs(plan.newState) do
			state[path] = sha
		end
		if #plan.downloads == 0 then
			self:Finish("Pull builds", { "Everything is up to date ("..plan.upToDate.." files)." }, onDone, false)
			return
		end
		local actions = { }
		for _, d in ipairs(plan.downloads) do
			t_insert(actions, { op = "download", sha = d.sha, target = d.target, remotePath = d.remotePath })
		end
		self.status = "Pulling..."
		self:RunWorker("apply", { actions = actions }, function(res, errMsg)
			if not res then
				self:Finish("Pull builds", { "^1Pull failed:", "^7"..tostring(errMsg) }, onDone, true, false)
				return
			end
			local pulled, copies, failed = { }, { }, { }
			for _, r in ipairs(res.results) do
				local d = plan.downloads[r.index]
				if r.ok then
					state[d.remotePath] = r.sha
					t_insert(d.conflict and copies or pulled, d.conflict and d.target or d.rel)
				else
					t_insert(failed, d.rel..": "..tostring(r.err))
				end
			end
			local lines = { string.format("Pulled %d, already up to date %d.", #pulled, plan.upToDate) }
			listLines(lines, "^7Updated:", pulled, 12)
			listLines(lines, "^xFFAA00Changed both here and on GitHub - kept yours, saved theirs as a copy:", copies, 8)
			listLines(lines, "^1Failed:", failed, 8)
			if tree.truncated then
				t_insert(lines, "^xFFAA00GitHub returned a truncated file list; some files may be missing.")
			end
			self:Finish("Pull builds", lines, onDone, true, #failed == 0)
		end)
	end)
end

---------------------------------------------------------------------------
-- Push
---------------------------------------------------------------------------
function sync:Push(onDone, out)
	if self.busy then return end
	local err = self:CheckReady(true)
	if err then
		self.out = out
		self:Finish("Push builds", { err }, onDone, false, false)
		return
	end
	local root, player = self.settings.root, self.settings.player
	self:Begin("Listing files on GitHub...", out)
	self:RunWorker("tree", { }, function(tree, errMsg)
		if not tree then
			self:Finish("Push builds", { "^1Push failed:", "^7"..tostring(errMsg) }, onDone, true, false)
			return
		end
		local remoteMap = { }
		for _, e in ipairs(tree.entries) do
			remoteMap[e.path] = e.sha
		end
		local localFiles = scanFolder(player.."/")
		local state = self:State()
		local plan = core.planPush(localFiles, remoteMap, state, root, player)
		for path, sha in pairs(plan.newState) do
			state[path] = sha
		end
		local conflicts = { }
		for _, c in ipairs(plan.conflicts) do
			t_insert(conflicts, c.rel)
		end
		if #plan.uploads == 0 then
			local lines = { #conflicts == 0 and "Nothing to push ("..plan.upToDate.." files up to date)." or "Nothing pushed." }
			listLines(lines, "^xFFAA00Changed on GitHub since your last sync - Pull first, then Push:", conflicts, 8)
			if not next(localFiles) then
				t_insert(lines, "^7No files found in your folder: "..main.buildPath..player.."/")
			end
			self:Finish("Push builds", lines, onDone, #conflicts > 0)
			return
		end
		local actions = { }
		for _, u in ipairs(plan.uploads) do
			t_insert(actions, { op = "upload", rel = u.rel, remotePath = u.remotePath, remoteSha = u.remoteSha })
		end
		self.status = "Pushing..."
		self:RunWorker("apply", { actions = actions }, function(res, errMsg)
			if not res then
				self:Finish("Push builds", { "^1Push failed:", "^7"..tostring(errMsg) }, onDone, true, false)
				return
			end
			local pushed, failed = { }, { }
			for _, r in ipairs(res.results) do
				local u = plan.uploads[r.index]
				if r.ok then
					state[u.remotePath] = r.sha or localFiles[u.rel]
					t_insert(pushed, u.rel)
				else
					t_insert(failed, u.rel..": "..tostring(r.err))
				end
			end
			local lines = { string.format("Pushed %d, already up to date %d.", #pushed, plan.upToDate) }
			listLines(lines, "^7Uploaded:", pushed, 12)
			listLines(lines, "^xFFAA00Changed on GitHub since your last sync - Pull first, then Push:", conflicts, 8)
			listLines(lines, "^1Failed:", failed, 8)
			self:Finish("Push builds", lines, onDone, true, #failed == 0)
		end)
	end)
end


---------------------------------------------------------------------------
-- Sync now (manual): Pull, then Push, one summary popup
---------------------------------------------------------------------------
function sync:SyncNow(onDone)
	if self.busy then return end
	self.collected = { }
	self:Pull(function()
		self:Push(function()
			local lines = self.collected
			self.collected = nil
			if onDone then
				onDone()
			end
			main:OpenMessagePopup("Sync builds", table.concat(lines, "\n"))
		end, "collect")
	end, "collect")
end

---------------------------------------------------------------------------
-- Auto sync
---------------------------------------------------------------------------
local function refreshBuildList()
	if main.mode == "LIST" and main.modes["LIST"] and main.modes["LIST"].BuildList then
		main.modes["LIST"]:BuildList()
	end
end

-- HeadlessWrapper.lua (tests, the overlay's impact server) defines __callbackTable__; never sync there
local function isHeadless()
	return rawget(_G, "__callbackTable__") ~= nil
end

function sync:AutoReady()
	if isHeadless() then
		return false
	end
	self:Load()
	return self.prefs.autoSync and cred.available and self:HasAuth() and self.settings.owner ~= "" and self.settings.repo ~= ""
end

-- Called by Build.lua after a build file is written
function sync:NotifySaved(fullPath)
	if not self:AutoReady() or not main.buildPath then
		return
	end
	if auth.isOwnBuild(fullPath, main.buildPath, self.settings.player) then
		self.pendingPushAt = os.time() + self.autoPushDelay
	end
end

-- Called every frame from main:OnFrame
function sync:OnFrame()
	if isHeadless() then
		return
	end
	local now = os.time()
	if self.device and not self.device.polling and not self.device.result and now >= self.device.nextPoll then
		self:PollDevice()
	end
	if self.busy or self.device or main.popups[1] then
		return
	end
	if not self.startupDone and main.mode == "LIST" and main.buildPath then
		self.startupDone = true
		self:Load()
		-- Signed in already (session shared via Credential Manager, e.g. the copy bundled in
		-- Loot Goblin starting with a fresh BuildSync.json): use the GitHub name as player folder
		local session = self:GetSession()
		if self.settings.player == "" and session and session.login and core.validPlayer(session.login) then
			self.settings.player = session.login
			self.prefs.setupAsked = true
			self:Save()
		end
		if not self.prefs.setupAsked and not self:HasAuth() then
			self:OpenWelcomePopup()
		elseif self:AutoReady() then
			self:Pull(refreshBuildList, "quiet")
		end
		return
	end
	if self.pendingPushAt and now >= self.pendingPushAt then
		self.pendingPushAt = nil
		if self:AutoReady() and core.validPlayer(self.settings.player) then
			self:Push(nil, "quiet")
		end
	end
end

-- One line for the build list
function sync:StatusText()
	if self.busy then
		return "^7"..(self.status or "Syncing...")
	end
	self:Load()
	local who = self:SignedInAs()
	if not who and not self:HasToken() then
		return "^8Not signed in"
	end
	local text = who and ("^8"..who) or "^8Token"
	if not self.prefs.autoSync then
		return text.." - auto sync off"
	end
	if self.lastResult then
		local mins = math.floor((os.time() - self.lastResult.time) / 60)
		local age = mins < 1 and "just now" or (mins.." min ago")
		return text.." - "..(self.lastResult.ok and "" or "^1")..self.lastResult.text.." ^8("..age..")"
	end
	return text.." - auto sync on"
end

---------------------------------------------------------------------------
-- GitHub sign-in (device flow)
---------------------------------------------------------------------------
local function addLines(controls, key, y, lines)
	for i, line in ipairs(lines) do
		controls[key..i] = new("LabelControl"):LabelControl(nil, {0, y, 0, 16}, line)
		y = y + 18
	end
	return y
end

-- onDone(login) after a successful sign-in
function sync:StartSignIn(onDone)
	if self.busy or self.device then return end
	self:Load()
	self:Begin("Contacting GitHub...")
	self:LaunchWorker("deviceCode", { url = auth.deviceCodeUrl, body = auth.deviceCodeBody() }, function(resp, errMsg)
		self.busy = false
		self.status = nil
		self.out = nil
		if not resp or not resp.device_code then
			main:OpenMessagePopup("Sign in with GitHub", "^1Couldn't start the sign-in:\n^7"..(errMsg or auth.describeError(resp)))
			return
		end
		local now = os.time()
		self.device = {
			code = resp.device_code,
			userCode = resp.user_code,
			uri = resp.verification_uri or auth.verifyUrl,
			interval = tonumber(resp.interval) or 5,
			expires = now + (tonumber(resp.expires_in) or 900),
			onDone = onDone,
		}
		self.device.nextPoll = now + self.device.interval
		Copy(self.device.userCode)
		self:OpenDevicePopup()
	end)
end

function sync:OpenDevicePopup()
	local d = self.device
	local controls = { }
	local y = addLines(controls, "intro", 20, {
		"^71. Open GitHub and sign in (if asked).",
		"^72. Enter this code (it's already copied, so you can just paste it):",
	})
	controls.code = new("LabelControl"):LabelControl(nil, {0, y + 4, 0, 28}, "^xFFFFFF"..d.userCode)
	y = y + 42
	y = addLines(controls, "intro2", y, {
		"^73. Approve \"POE Builds sync\". This window carries on by itself.",
	})
	controls.status = new("LabelControl"):LabelControl(nil, {0, y + 4, 0, 16}, function()
		local dev = self.device
		if not dev then
			return ""
		end
		if dev.result then
			return dev.result
		end
		local left = dev.expires - os.time()
		if left <= 0 then
			return "^1The code expired. Close and start again."
		end
		return string.format("^8Waiting for approval... (code valid for %d:%02d)", math.floor(left / 60), left % 60)
	end)
	y = y + 34
	controls.open = new("ButtonControl"):ButtonControl(nil, {-125, y, 110, 20}, "Open GitHub", function()
		OpenURL(d.uri)
	end)
	controls.copy = new("ButtonControl"):ButtonControl(nil, {0, y, 110, 20}, "Copy code", function()
		Copy(d.userCode)
	end)
	controls.cancel = new("ButtonControl"):ButtonControl(nil, {125, y, 110, 20}, "Cancel", function()
		self.device = nil
		main:ClosePopup()
	end)
	main:OpenPopup(520, y + 30, "Sign in with GitHub", controls, "open", nil, "cancel")
	OpenURL(d.uri)
end

function sync:PollDevice()
	local d = self.device
	if os.time() >= d.expires then
		d.result = "^1The code expired. Close and start again."
		return
	end
	d.polling = true
	self:LaunchWorker("devicePoll", { url = auth.tokenUrl, body = auth.pollBody(d.code) }, function(resp, errMsg)
		if self.device ~= d then
			return -- cancelled meanwhile
		end
		d.polling = false
		local outcome = resp and auth.pollOutcome(resp) or "network"
		if outcome == "pending" or outcome == "network" then
			d.nextPoll = os.time() + d.interval
		elseif outcome == "slow_down" then
			d.interval = tonumber(resp.interval) or (d.interval + 5)
			d.nextPoll = os.time() + d.interval
		elseif outcome == "done" then
			local session = auth.sessionFromToken(resp, os.time())
			d.result = "^7Approved. Checking your access..."
			self:LaunchWorker("whoami", { token = session.access }, function(who)
				session.login = who and who.login
				self.device = nil
				main:ClosePopup()
				if not self:SaveSession(session) then
					main:OpenMessagePopup("Sign in with GitHub", "^1Couldn't save the sign-in to Windows Credential Manager.")
					return
				end
				self.prefs.setupAsked = true
				if self.settings.player == "" and session.login and core.validPlayer(session.login) then
					self.settings.player = session.login
				end
				self:Save()
				if who and who.repoCode and who.repoCode ~= 200 then
					main:OpenMessagePopup("Sign in with GitHub", auth.repoAccessHint(who.repoCode, self.settings.owner, self.settings.repo))
				end
				if d.onDone then
					d.onDone(session.login)
				end
			end)
		else
			d.result = "^1"..auth.describeError(resp)
		end
	end)
end

---------------------------------------------------------------------------
-- First run
---------------------------------------------------------------------------
function sync:OpenWelcomePopup()
	local controls = { }
	local y = addLines(controls, "l", 20, {
		"^7Share builds with your group?",
		"",
		"^7Sign in with GitHub to keep your builds in sync with the POE Builds group:",
		"^7everyone's builds are downloaded when PoB starts, and yours are uploaded",
		"^7a few seconds after you save. You need to be a member of POE-Builds on GitHub.",
		"",
		"^8PoB works the same without signing in. You can do this later from Sync... in the build list.",
	})
	y = y + 10
	controls.signIn = new("ButtonControl"):ButtonControl(nil, {-90, y, 160, 20}, "Sign in with GitHub", function()
		main:ClosePopup()
		self.prefs.setupAsked = true
		self:Save()
		self:StartSignIn(function()
			self:OpenSetupPopup()
		end)
	end)
	controls.skip = new("ButtonControl"):ButtonControl(nil, {90, y, 160, 20}, "Not now", function()
		self.prefs.setupAsked = true
		self:Save()
		main:ClosePopup()
	end)
	main:OpenPopup(600, y + 30, "Path of Building - build sharing", controls, "signIn", nil, "skip")
end

-- After sign-in: confirm the player folder and auto sync, then pull everything
function sync:OpenSetupPopup()
	local s = self.settings
	local controls = { }
	local y = addLines(controls, "l", 20, {
		"^7Signed in as "..(self:SignedInAs() or "?")..".",
		"",
		"^7Your player folder holds the builds you share. Everyone's builds are pulled into:",
		"^8"..tostring(main.buildPath),
	})
	y = y + 8
	controls.player = new("EditControl"):EditControl(nil, {60, y, 220, 20}, s.player, nil, "%c\\:%*%?\"<>|", 100)
	controls.playerLabel = new("LabelControl"):LabelControl({"RIGHT", controls.player, "LEFT"}, {-6, 0, 0, 16}, "^7Your player folder:")
	y = y + 28
	controls.auto = new("CheckBoxControl"):CheckBoxControl(nil, {150, y, 20}, "^7Sync automatically (pull on start, push after save):", nil, nil, self.prefs.autoSync)
	y = y + 28
	y = addLines(controls, "m", y, {
		"^8Only files in your own folder are uploaded. Move builds you want to share into it.",
	})
	y = y + 10
	controls.finish = new("ButtonControl"):ButtonControl(nil, {-70, y, 120, 20}, "Finish + Pull", function()
		local player = controls.player.buf:gsub("^%s+", ""):gsub("%s+$", "")
		if not core.validPlayer(player) then
			main:OpenMessagePopup("Build sharing", "Player folder can only use letters, numbers, _ - and .")
			return
		end
		s.player = player
		self.prefs.autoSync = controls.auto.state
		self:Save()
		MakeDir(main.buildPath..player)
		main:ClosePopup()
		self:Pull(refreshBuildList)
	end)
	controls.later = new("ButtonControl"):ButtonControl(nil, {70, y, 120, 20}, "Close", function()
		main:ClosePopup()
	end)
	main:OpenPopup(620, y + 30, "Build sharing set-up", controls, "finish", "player", "later")
end

---------------------------------------------------------------------------
-- Sync... dialog
---------------------------------------------------------------------------
function sync:OpenSettingsPopup()
	self:Load()
	local s = self.settings
	local controls = { }
	local y = 20
	controls.who = new("LabelControl"):LabelControl(nil, {0, y, 0, 16}, function()
		local who = self:SignedInAs()
		if who then
			return "^7Signed in to GitHub as "..who
		end
		return self:HasToken() and "^7Using a pasted token (sign in for automatic renewal)" or "^7Not signed in"
	end)
	y = y + 24
	controls.signIn = new("ButtonControl"):ButtonControl(nil, {-75, y, 140, 20}, "Sign in with GitHub", function()
		self:StartSignIn()
	end)
	controls.signIn.enabled = function() return not self.busy and not self.device end
	controls.signOut = new("ButtonControl"):ButtonControl(nil, {75, y, 140, 20}, "Sign out", function()
		self:SignOut()
	end)
	controls.signOut.enabled = function() return self:GetSession() ~= nil end
	y = y + 30
	controls.auto = new("CheckBoxControl"):CheckBoxControl(nil, {150, y, 20}, "^7Sync automatically (pull on start, push after save):", nil,
		"Pull everyone's builds when PoB starts and upload your own folder a few seconds after you save a build.\nConflicts are handled like manual Pull/Push: nothing is overwritten.", self.prefs.autoSync)
	y = y + 30
	local fields = {
		{ key = "player", label = "Your player folder:", tip = "Your own folder inside the builds folder. Push only uploads this folder.\nLetters, numbers, _ - . only." },
		{ key = "owner",  label = "GitHub owner:",       tip = "The GitHub account or organisation that owns the builds repo." },
		{ key = "repo",   label = "Repository:",         tip = "Name of the private builds repo." },
		{ key = "branch", label = "Branch:",             tip = "Branch to sync with (usually main)." },
		{ key = "root",   label = "Folder in repo:",     tip = "Repo folder that maps to your build save path (poe1 for PoE1)." },
	}
	for _, field in ipairs(fields) do
		controls[field.key] = new("EditControl"):EditControl(nil, {70, y, 300, 20}, s[field.key], nil, "%c\\:%*%?\"<>|", 100)
		controls[field.key].tooltipText = field.tip
		controls[field.key.."Label"] = new("LabelControl"):LabelControl({"RIGHT", controls[field.key], "LEFT"}, {-6, 0, 0, 16}, "^7"..field.label)
		y = y + 26
	end
	local hasToken = self:HasToken()
	controls.token = new("EditControl"):EditControl(nil, {70, y, 300, 20}, "", nil, "%c%s", 255)
	controls.token:SetProtected(true)
	controls.token:SetPlaceholder(hasToken and "(saved - leave blank to keep)" or "optional, only if sign-in doesn't work")
	controls.token.tooltipText = "Fallback: GitHub fine-grained personal access token.\nResource owner: the organisation. Repository access: only this repo. Permissions: Contents = Read and write.\nUsed only when you're not signed in. Stored in Windows Credential Manager, never in a file."
	controls.tokenLabel = new("LabelControl"):LabelControl({"RIGHT", controls.token, "LEFT"}, {-6, 0, 0, 16}, "^7Token (fallback):")
	y = y + 26
	controls.note = new("LabelControl"):LabelControl(nil, {0, y, 0, 14}, cred.available
		and "^8Sign-in and token are kept in Windows Credential Manager, never in a file."
		or "^1Windows Credential Manager not available - sign-in can't be stored.")
	y = y + 26
	controls.save = new("ButtonControl"):ButtonControl(nil, {-145, y, 80, 20}, "Save", function()
		for _, field in ipairs(fields) do
			s[field.key] = controls[field.key].buf:gsub("^%s+", ""):gsub("%s+$", "")
		end
		s.root = core.normaliseRoot(s.root)
		if s.player ~= "" and not core.validPlayer(s.player) then
			main:OpenMessagePopup("Sync settings", "Player folder can only use letters, numbers, _ - and .")
			return
		end
		if controls.token.buf ~= "" then
			if not cred.write(self.credentialTarget, "github-token", controls.token.buf) then
				main:OpenMessagePopup("Sync settings", "Couldn't save the token to Windows Credential Manager.")
				return
			end
		end
		self.prefs.autoSync = controls.auto.state
		self.prefs.setupAsked = true
		self:Save()
		main:ClosePopup()
	end)
	controls.forget = new("ButtonControl"):ButtonControl(nil, {-45, y, 100, 20}, "Forget token", function()
		cred.delete(self.credentialTarget)
		controls.token:SetPlaceholder("optional, only if sign-in doesn't work")
		controls.forget.enabled = false
	end)
	controls.forget.enabled = hasToken
	controls.help = new("ButtonControl"):ButtonControl(nil, {55, y, 80, 20}, "Help", function()
		self:OpenHelpPopup()
	end)
	controls.cancel = new("ButtonControl"):ButtonControl(nil, {145, y, 80, 20}, "Cancel", function()
		main:ClosePopup()
	end)
	main:OpenPopup(580, y + 30, "Build sync (GitHub)", controls, "save", "player", "cancel")
end

function sync:OpenHelpPopup()
	main:OpenMessagePopup("Build sync - how it works", table.concat({
		"^7Setting up (once per PC):",
		"^8  1. Make a free GitHub account and ask the group owner to invite you to POE-Builds.",
		"^8  2. Accept the invite (email or github.com/orgs/POE-Builds/invitation).",
		"^8  3. Sync... > Sign in with GitHub, enter the code on github.com, approve.",
		"^8  4. Set your player folder (usually your GitHub name). Put builds you share in it.",
		"",
		"^7Day to day:",
		"^8  Auto sync pulls everyone's builds when PoB starts and uploads your folder after you save.",
		"^8  Sync now does both at once. Pull and Push still work by hand.",
		"^8  If a build changed both here and on GitHub, yours is kept and theirs is saved as \"(GitHub copy)\".",
		"^8  Deleting a build isn't synced yet: delete it on GitHub too, or it comes back on the next Pull.",
	}, "\n"))
end

-- Exposed for tests
sync.core = core
sync.auth = auth
sync.cred = cred

return sync
