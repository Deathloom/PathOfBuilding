-- Path of Building (Deathloom fork)
--
-- Module: Build Sync
-- Push/Pull builds to a shared GitHub repo through the GitHub REST API.
--   Pull: download every build under the repo folder (all players) into the build save path.
--   Push: upload changed files from your own player folder only.
-- The token is a GitHub fine-grained personal access token stored in Windows Credential Manager
-- (never in Settings, the builds folder or the repo).
--
local core = require("Modules.BuildSyncCore")
local dkjson = require("dkjson")

local t_insert = table.insert

local sync = {
	credentialTarget = "PathOfBuilding-Fork/GitHubBuildSync",
	busy = false,
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

function sync:GetToken()
	return cred.read(self.credentialTarget)
end

function sync:HasToken()
	local token = self:GetToken()
	return token ~= nil and token ~= ""
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
	end
end

function sync:Save()
	local f = io.open(self:SettingsFile(), "wb")
	if not f then
		return
	end
	f:write(dkjson.encode({ settings = self.settings, state = self.stateByKey }, { indent = true }))
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

function sync:RunWorker(mode, payload, callback)
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
	payload.token = self:GetToken()
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

function sync:Begin(status)
	self.busy = true
	self.status = status
end

function sync:Finish(title, lines, onDone)
	self.busy = false
	self.status = nil
	self:Save()
	if onDone then
		onDone()
	end
	main:OpenMessagePopup(title, table.concat(lines, "\n"))
end

function sync:CheckReady(forPush)
	self:Load()
	local s = self.settings
	if s.owner == "" or s.repo == "" or s.branch == "" then
		return "Set the GitHub repo first (Sync settings)."
	end
	if not cred.available then
		return "Windows Credential Manager isn't available, so no token can be stored."
	end
	if not self:HasToken() then
		return "No GitHub token saved yet (Sync settings)."
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
function sync:Pull(onDone)
	if self.busy then return end
	local err = self:CheckReady(false)
	if err then
		main:OpenMessagePopup("Pull builds", err)
		return
	end
	local root = self.settings.root
	self:Begin("Listing files on GitHub...")
	self:RunWorker("tree", { }, function(tree, errMsg)
		if not tree then
			self:Finish("Pull builds", { "^1Pull failed:", "^7"..errMsg })
			return
		end
		local state = self:State()
		local plan = core.planPull(tree.entries, localSha, state, root)
		for path, sha in pairs(plan.newState) do
			state[path] = sha
		end
		if #plan.downloads == 0 then
			self:Finish("Pull builds", { "Everything is up to date ("..plan.upToDate.." files)." }, onDone)
			return
		end
		local actions = { }
		for _, d in ipairs(plan.downloads) do
			t_insert(actions, { op = "download", sha = d.sha, target = d.target, remotePath = d.remotePath })
		end
		self.status = "Pulling..."
		self:RunWorker("apply", { actions = actions }, function(res, errMsg)
			if not res then
				self:Finish("Pull builds", { "^1Pull failed:", "^7"..errMsg }, onDone)
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
			self:Finish("Pull builds", lines, onDone)
		end)
	end)
end

---------------------------------------------------------------------------
-- Push
---------------------------------------------------------------------------
function sync:Push(onDone)
	if self.busy then return end
	local err = self:CheckReady(true)
	if err then
		main:OpenMessagePopup("Push builds", err)
		return
	end
	local root, player = self.settings.root, self.settings.player
	self:Begin("Listing files on GitHub...")
	self:RunWorker("tree", { }, function(tree, errMsg)
		if not tree then
			self:Finish("Push builds", { "^1Push failed:", "^7"..errMsg })
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
			self:Finish("Push builds", lines, onDone)
			return
		end
		local actions = { }
		for _, u in ipairs(plan.uploads) do
			t_insert(actions, { op = "upload", rel = u.rel, remotePath = u.remotePath, remoteSha = u.remoteSha })
		end
		self.status = "Pushing..."
		self:RunWorker("apply", { actions = actions }, function(res, errMsg)
			if not res then
				self:Finish("Push builds", { "^1Push failed:", "^7"..errMsg }, onDone)
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
			self:Finish("Push builds", lines, onDone)
		end)
	end)
end

---------------------------------------------------------------------------
-- Settings popup
---------------------------------------------------------------------------
function sync:OpenSettingsPopup()
	self:Load()
	local s = self.settings
	local controls = { }
	local fields = {
		{ key = "owner",  label = "GitHub owner:",       tip = "The GitHub account or organisation that owns the builds repo." },
		{ key = "repo",   label = "Repository:",         tip = "Name of the private builds repo." },
		{ key = "branch", label = "Branch:",             tip = "Branch to sync with (usually main)." },
		{ key = "root",   label = "Folder in repo:",     tip = "Repo folder that maps to your build save path (poe1 for PoE1).\nYour build save path should point at this folder in your local copy." },
		{ key = "player", label = "Your player folder:", tip = "Your own folder inside it. Push only uploads this folder.\nLetters, numbers, _ - . only." },
	}
	local y = 20
	for _, field in ipairs(fields) do
		controls[field.key] = new("EditControl"):EditControl(nil, {70, y, 300, 20}, s[field.key], nil, "%c\\:%*%?\"<>|", 100)
		controls[field.key].tooltipText = field.tip
		controls[field.key.."Label"] = new("LabelControl"):LabelControl({"RIGHT", controls[field.key], "LEFT"}, {-6, 0, 0, 16}, "^7"..field.label)
		y = y + 26
	end
	local hasToken = self:HasToken()
	controls.token = new("EditControl"):EditControl(nil, {70, y, 300, 20}, "", nil, "%c%s", 255)
	controls.token:SetProtected(true)
	controls.token:SetPlaceholder(hasToken and "(saved - leave blank to keep)" or "paste token here")
	controls.token.tooltipText = "GitHub fine-grained personal access token.\nRepository access: only this repo. Permissions: Contents = Read and write.\nStored in Windows Credential Manager on this PC, never in a file."
	controls.tokenLabel = new("LabelControl"):LabelControl({"RIGHT", controls.token, "LEFT"}, {-6, 0, 0, 16}, "^7GitHub token:")
	y = y + 26
	controls.note = new("LabelControl"):LabelControl(nil, {0, y, 0, 14}, cred.available
		and "^8Token is kept in Windows Credential Manager ("..self.credentialTarget..")."
		or "^1Windows Credential Manager not available - tokens can't be stored.")
	y = y + 26
	controls.save = new("ButtonControl"):ButtonControl(nil, {-95, y, 80, 20}, "Save", function()
		for _, field in ipairs(fields) do
			local value = controls[field.key].buf:gsub("^%s+", ""):gsub("%s+$", "")
			s[field.key] = value
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
		self:Save()
		main:ClosePopup()
	end)
	controls.forget = new("ButtonControl"):ButtonControl(nil, {0, y, 100, 20}, "Forget token", function()
		cred.delete(self.credentialTarget)
		controls.token:SetPlaceholder("paste token here")
		controls.forget.enabled = false
	end)
	controls.forget.enabled = hasToken
	controls.cancel = new("ButtonControl"):ButtonControl(nil, {95, y, 80, 20}, "Cancel", function()
		main:ClosePopup()
	end)
	main:OpenPopup(560, y + 30, "Build sync settings (GitHub)", controls, "save", "owner", "cancel")
end

-- Exposed for tests
sync.core = core
sync.cred = cred

return sync
