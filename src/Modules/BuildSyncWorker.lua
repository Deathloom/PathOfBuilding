-- Path of Building (Deathloom fork)
-- cspell:ignore Deathloom rerr werr organisation
--
-- Module: Build Sync Worker
-- Runs in a background sub-script (LaunchSubScript). Does only the GitHub HTTP calls and file writes;
-- all decisions are made on the main thread by Modules/BuildSync.lua + Modules/BuildSyncCore.lua.
--
-- Args: mode ("tree" | "apply" | "deviceCode" | "devicePoll" | "refresh" | "whoami" | "api"), payloadJson, connectionProtocol, proxyURL, noSSL
-- Returns: resultJson, errMsg
--
local mode, payloadJson, connectionProtocol, proxyURL, noSSL = ...

local curl = require("lcurl.safe")
local dkjson = require("dkjson")
local base64 = require("base64")

local p = dkjson.decode(payloadJson)
local api = "https://api.github.com/repos/"..tostring(p.owner).."/"..tostring(p.repo)

local function encodePath(path)
	return (path:gsub("[^%w%-%._~/]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

-- opts.form: body is x-www-form-urlencoded and no token is sent (github.com OAuth endpoints)
local function request(method, url, accept, body, opts)
	opts = opts or { }
	local easy = curl.easy()
	local responseBody = { }
	easy:setopt_url(url)
	local headers = {
		"Accept: "..(accept or "application/vnd.github+json"),
		"Content-Type: "..(opts.form and "application/x-www-form-urlencoded" or "application/json"),
	}
	if not opts.form then
		table.insert(headers, "Authorization: Bearer "..tostring(p.token))
		table.insert(headers, "X-GitHub-Api-Version: 2022-11-28")
	end
	easy:setopt(curl.OPT_HTTPHEADER, headers)
	easy:setopt(curl.OPT_USERAGENT, p.userAgent or "Path of Building fork")
	easy:setopt(curl.OPT_ACCEPT_ENCODING, "")
	easy:setopt(curl.OPT_FOLLOWLOCATION, 1)
	easy:setopt(curl.OPT_CONNECTTIMEOUT, 15)
	easy:setopt(curl.OPT_TIMEOUT, 120)
	if method ~= "GET" then
		easy:setopt(curl.OPT_CUSTOMREQUEST, method)
	end
	if body then
		easy:setopt(curl.OPT_POSTFIELDS, body)
	end
	if connectionProtocol then
		easy:setopt(curl.OPT_IPRESOLVE, connectionProtocol)
	end
	if proxyURL then
		easy:setopt(curl.OPT_PROXY, proxyURL)
	end
	if noSSL then
		easy:setopt(curl.OPT_SSL_VERIFYPEER, 0)
		easy:setopt(curl.OPT_SSL_VERIFYHOST, 0)
	end
	easy:setopt_writefunction(function(data)
		table.insert(responseBody, data)
		return true
	end)
	local _, err = easy:perform()
	local code = easy:getinfo(curl.INFO_RESPONSE_CODE)
	easy:close()
	local text = table.concat(responseBody)
	if err then
		return nil, err:msg(), code
	end
	if code < 200 or code >= 300 then
		local msg = "HTTP "..tostring(code)
		local decoded = dkjson.decode(text)
		if type(decoded) == "table" and decoded.message then
			msg = msg..": "..decoded.message
		end
		if code == 401 then
			msg = msg.." (token missing, wrong or expired)"
		elseif code == 403 or code == 404 then
			msg = msg.." (check repo name, branch, and that the token has Contents access to it)"
		elseif code == 409 then
			msg = msg.." (remote changed during sync - Pull, then Push again)"
		end
		return nil, msg, code
	end
	return text, nil, code
end

local function makeDirs(dir)
	local path = ""
	for part in dir:gmatch("[^/\\]+") do
		path = path..part.."/"
		if not path:match("^%a:/$") then
			MakeDir(path)
		end
	end
end

local function writeFile(fullPath, content)
	makeDirs(fullPath:match("^(.*)[/\\]") or "")
	local f, err = io.open(fullPath, "wb")
	if not f then
		return nil, err
	end
	f:write(content)
	f:close()
	return true
end

local function readFile(fullPath)
	local f, err = io.open(fullPath, "rb")
	if not f then
		return nil, err
	end
	local content = f:read("*a")
	f:close()
	return content
end

-- github.com OAuth endpoints answer 200 with { error = ... } for most failures
local function oauthPost(url, body)
	local text, err, code = request("POST", url, "application/json", body, { form = true })
	if not text then
		return nil, err
	end
	local decoded = dkjson.decode(text)
	if type(decoded) ~= "table" then
		return nil, "Unexpected reply from GitHub (HTTP "..tostring(code)..")"
	end
	return dkjson.encode(decoded), nil
end

if mode == "deviceCode" or mode == "devicePoll" or mode == "refresh" then
	return oauthPost(p.url, p.body)

elseif mode == "whoami" then
	-- Who is signed in, and can they see the builds repo?
	local result = { }
	local text, err, code = request("GET", "https://api.github.com/user")
	if not text then
		return nil, err
	end
	local user = dkjson.decode(text)
	result.login = type(user) == "table" and user.login or nil
	local _, _, repoCode = request("GET", api)
	result.repoCode = repoCode
	return dkjson.encode(result), nil

elseif mode == "api" then
	-- One GitHub REST call (Loot Goblin's problem reports): returns { code, body } even for errors
	local text, err, code = request(p.method or "GET", "https://api.github.com"..tostring(p.path), nil, p.body)
	if not code or code == 0 then
		return nil, err or "No answer from GitHub"
	end
	return dkjson.encode({ code = code, body = text and dkjson.decode(text) or nil, error = err }), nil

elseif mode == "tree" then
	local text, err = request("GET", api.."/git/trees/"..encodePath(p.branch).."?recursive=1")
	if not text then
		if err and err:match("^HTTP 409") then
			-- Empty repository: no commits yet, so nothing to pull
			return dkjson.encode({ entries = { }, truncated = false }), nil
		end
		return nil, err
	end
	local tree = dkjson.decode(text)
	if type(tree) ~= "table" or type(tree.tree) ~= "table" then
		return nil, "Unexpected response from GitHub when listing files"
	end
	local entries = { }
	for _, item in ipairs(tree.tree) do
		if item.type == "blob" then
			table.insert(entries, { path = item.path, sha = item.sha })
		end
	end
	return dkjson.encode({ entries = entries, truncated = tree.truncated and true or false }), nil

elseif mode == "apply" then
	local results = { }
	for i, action in ipairs(p.actions) do
		BuildSyncProgress("%s %d of %d", action.op == "download" and "Pulling" or "Pushing", i, #p.actions)
		local result = { index = i }
		if action.op == "download" then
			local content, err = request("GET", api.."/git/blobs/"..action.sha, "application/vnd.github.raw+json")
			if content then
				local ok, werr = writeFile(p.buildPath..action.target, content)
				result.ok = ok and true or false
				result.err = werr
				result.sha = action.sha
			else
				result.err = err
			end
		elseif action.op == "upload" then
			local content, rerr = readFile(p.buildPath..action.rel)
			if content then
				local body = dkjson.encode({
					message = "PoB sync: "..action.remotePath,
					content = base64.encode(content),
					sha = action.remoteSha,
					branch = p.branch,
				})
				local text, err = request("PUT", api.."/contents/"..encodePath(action.remotePath), nil, body)
				if text then
					local decoded = dkjson.decode(text)
					result.ok = true
					result.sha = type(decoded) == "table" and decoded.content and decoded.content.sha
				else
					result.err = err
				end
			else
				result.err = rerr
			end
		end
		table.insert(results, result)
		if result.err and (result.err:match("^HTTP 401") or result.err:match("^HTTP 403")) then
			-- Auth problems won't fix themselves for the next file
			break
		end
	end
	return dkjson.encode({ results = results }), nil
end

return nil, "Unknown sync mode: "..tostring(mode)
