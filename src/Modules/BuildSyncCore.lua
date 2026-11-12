-- Path of Building (Deathloom fork)
--
-- Module: Build Sync Core
-- Pure decision logic for the Push/Pull builds buttons (no I/O, no UI).
-- Kept separate so it can be unit-tested headless (spec/System/TestBuildSync_spec.lua).
--
-- Terms:
--   rel        path relative to main.buildPath, "/" separated (e.g. "PlayerOne/RF Jugg.xml")
--   remotePath path in the GitHub repo (e.g. "poe1/PlayerOne/RF Jugg.xml")
--   L / R / B  local sha, remote sha, base sha (remote sha at our last successful sync)
-- All shas are git blob shas, so a local file can be compared with the GitHub tree without downloading it.
--
local core = { }

core.copySuffix = " (GitHub copy)"

-- Git blob sha of a file's bytes: sha1("blob <len>\0<content>")
function core.blobSha(content, sha1fn)
	return sha1fn("blob "..#content.."\0"..content)
end

function core.normaliseRoot(root)
	root = (root or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
	return root
end

function core.toRemote(root, rel)
	root = core.normaliseRoot(root)
	if root == "" then
		return rel
	end
	return root.."/"..rel
end

-- Returns rel for a remote path inside root, or nil if it is outside root
function core.toRel(root, remotePath)
	root = core.normaliseRoot(root)
	if root == "" then
		return remotePath
	end
	local prefix = root.."/"
	if remotePath:sub(1, #prefix) == prefix then
		return remotePath:sub(#prefix + 1)
	end
end

-- "PlayerOne/RF Jugg.xml" -> "PlayerOne/RF Jugg (GitHub copy).xml"
function core.copyName(rel)
	local base, ext = rel:match("^(.*)(%.[^./]+)$")
	if not base then
		return rel..core.copySuffix
	end
	return base..core.copySuffix..ext
end

function core.isCopy(rel)
	return rel:find(core.copySuffix, 1, true) ~= nil
end

-- Files we never sync: dotfiles/dotfolders, conflict copies, temp files
function core.isSyncable(rel)
	if rel == "" or core.isCopy(rel) then
		return false
	end
	for part in rel:gmatch("[^/]+") do
		if part:sub(1, 1) == "." then
			return false
		end
	end
	if rel:match("~$") or rel:match("%.tmp$") then
		return false
	end
	return true
end

-- Player folder names become repo paths, so keep them simple
function core.validPlayer(player)
	return type(player) == "string" and player:match("^[%w_%-%.]+$") ~= nil and player:sub(1, 1) ~= "."
end

-- Plan a pull.
--   remoteEntries: list of { path = remotePath, sha = R }
--   getLocalSha(rel): returns L or nil if the file doesn't exist locally
--   state: { [remotePath] = B }
-- Returns { downloads = { {rel, remotePath, sha, target, conflict} }, upToDate = n }
-- Rules: local missing or unchanged since last sync -> overwrite with remote.
--        local changed AND remote differs -> keep local, save remote next to it as a "(GitHub copy)".
function core.planPull(remoteEntries, getLocalSha, state, root)
	local plan = { downloads = { }, upToDate = 0, newState = { } }
	for _, entry in ipairs(remoteEntries) do
		local rel = core.toRel(root, entry.path)
		if rel and core.isSyncable(rel) then
			local L = getLocalSha(rel)
			local R = entry.sha
			local B = state[entry.path]
			if L == R then
				plan.upToDate = plan.upToDate + 1
				plan.newState[entry.path] = R
			elseif L == nil or L == B then
				table.insert(plan.downloads, { rel = rel, remotePath = entry.path, sha = R, target = rel, conflict = false })
			elseif R == B then
				-- Only changed here (not pushed yet): nothing to pull
				plan.upToDate = plan.upToDate + 1
				plan.localAhead = (plan.localAhead or 0) + 1
			else
				table.insert(plan.downloads, { rel = rel, remotePath = entry.path, sha = R, target = core.copyName(rel), conflict = true })
			end
		end
	end
	return plan
end

-- Plan a push of the player's own folder.
--   localFiles: { [rel] = L } (already limited to the player's folder)
--   remoteMap:  { [remotePath] = R } (whole remote tree)
--   state:      { [remotePath] = B }
-- Returns { uploads = { {rel, remotePath, remoteSha} }, conflicts = { {rel, remotePath} }, upToDate = n, newState }
-- Rules: unchanged -> skip. Remote unchanged since last sync (or new file) -> upload.
--        Remote changed by someone else since last sync -> conflict, user must Pull first.
function core.planPush(localFiles, remoteMap, state, root, player)
	local plan = { uploads = { }, conflicts = { }, upToDate = 0, newState = { } }
	local prefix = player.."/"
	local rels = { }
	for rel in pairs(localFiles) do
		if rel:sub(1, #prefix) == prefix and core.isSyncable(rel) then
			table.insert(rels, rel)
		end
	end
	table.sort(rels)
	for _, rel in ipairs(rels) do
		local remotePath = core.toRemote(root, rel)
		local L = localFiles[rel]
		local R = remoteMap[remotePath]
		local B = state[remotePath]
		if L == R then
			plan.upToDate = plan.upToDate + 1
			plan.newState[remotePath] = R
		elseif R == nil or R == B then
			table.insert(plan.uploads, { rel = rel, remotePath = remotePath, remoteSha = R })
		else
			table.insert(plan.conflicts, { rel = rel, remotePath = remotePath })
		end
	end
	return plan
end

-- URL-encode each path segment for the GitHub contents API
function core.encodePath(path)
	return (path:gsub("[^%w%-%._~/]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

return core
