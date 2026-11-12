-- Path of Building (Deathloom fork)
-- cspell:ignore Deathloom DZLD organisation
--
-- Module: Build Sync Auth (pure logic, no I/O)
-- GitHub App sign-in with the OAuth device flow: the app shows a code, the user approves it on
-- github.com/login/device. No client secret and no server are involved; the client ID is public.
-- User tokens expire after 8 hours and are renewed with the refresh token (valid about 6 months).
--
local M = { }

-- GitHub App "POE Builds sync", owned by the POE-Builds organisation. Public, not a secret.
M.clientId = "Iv23liBVqYBGxpDZLDSv"
M.deviceCodeUrl = "https://github.com/login/device/code"
M.tokenUrl = "https://github.com/login/oauth/access_token"
M.verifyUrl = "https://github.com/login/device"
M.deviceGrant = "urn:ietf:params:oauth:grant-type:device_code"

-- Renew this many seconds before the access token runs out
M.refreshMargin = 300

local function urlEncode(s)
	return (tostring(s):gsub("[^%w%-%._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

-- application/x-www-form-urlencoded body from a table (sorted keys, so it's stable for tests)
function M.formBody(fields)
	local keys = { }
	for k in pairs(fields) do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts = { }
	for _, k in ipairs(keys) do
		table.insert(parts, urlEncode(k).."="..urlEncode(fields[k]))
	end
	return table.concat(parts, "&")
end

function M.deviceCodeBody()
	return M.formBody({ client_id = M.clientId })
end

function M.pollBody(deviceCode)
	return M.formBody({ client_id = M.clientId, device_code = deviceCode, grant_type = M.deviceGrant })
end

function M.refreshBody(refreshToken)
	return M.formBody({ client_id = M.clientId, refresh_token = refreshToken, grant_type = "refresh_token" })
end

-- Turns a token response into a stored session with absolute expiry times (seconds since epoch).
-- Returns session, or nil + error text.
function M.sessionFromToken(resp, now, login)
	if type(resp) ~= "table" or type(resp.access_token) ~= "string" or resp.access_token == "" then
		return nil, M.describeError(resp)
	end
	local session = {
		access = resp.access_token,
		refresh = type(resp.refresh_token) == "string" and resp.refresh_token or nil,
		login = login,
	}
	if tonumber(resp.expires_in) then
		session.accessExp = now + tonumber(resp.expires_in)
	end
	if tonumber(resp.refresh_token_expires_in) then
		session.refreshExp = now + tonumber(resp.refresh_token_expires_in)
	end
	return session
end

-- "ok" (use as is), "refresh" (renew first), "expired" (sign in again)
function M.tokenStatus(session, now)
	if type(session) ~= "table" or not session.access then
		return "expired"
	end
	if not session.accessExp or now < session.accessExp - M.refreshMargin then
		return "ok"
	end
	if session.refresh and (not session.refreshExp or now < session.refreshExp - 60) then
		return "refresh"
	end
	return "expired"
end

-- Device flow poll result: "done", "pending", "slow_down", "denied", "expired" or "error"
function M.pollOutcome(resp)
	if type(resp) ~= "table" then
		return "error"
	end
	if type(resp.access_token) == "string" and resp.access_token ~= "" then
		return "done"
	end
	local e = resp.error
	if e == "authorization_pending" then
		return "pending"
	elseif e == "slow_down" then
		return "slow_down"
	elseif e == "access_denied" then
		return "denied"
	elseif e == "expired_token" or e == "token_expired" then
		return "expired"
	end
	return "error"
end

function M.describeError(resp)
	if type(resp) ~= "table" then
		return "Unexpected reply from GitHub"
	end
	local e = resp.error
	if e == "access_denied" then
		return "Sign-in was cancelled on GitHub."
	elseif e == "expired_token" or e == "token_expired" then
		return "The code expired before it was approved. Start the sign-in again."
	elseif e == "bad_refresh_token" then
		return "Your GitHub sign-in has run out. Sign in again."
	elseif e == "incorrect_client_credentials" or e == "unauthorized_client" then
		return "GitHub rejected this app (check that Device Flow is enabled on the GitHub App)."
	elseif e == "device_flow_disabled" then
		return "Device Flow is turned off on the GitHub App."
	end
	return tostring(resp.error_description or e or "Unexpected reply from GitHub")
end

-- Explains a failed repo check (GET /repos/owner/repo with the user's token)
function M.repoAccessHint(code, owner, repo)
	if code == 404 or code == 403 then
		return "Signed in, but this GitHub account can't see "..owner.."/"..repo..".\n"
			.."Ask the group owner to add you to the "..owner.." organisation on GitHub, accept the invite, then try again."
	elseif code == 401 then
		return "GitHub didn't accept the sign-in. Sign in again."
	end
	return "Couldn't check access to "..owner.."/"..repo.." (HTTP "..tostring(code)..")."
end

-- Auto push only for files inside the player's own folder below the build path.
-- fullPath and buildPath use either slash; comparison is case-insensitive (Windows paths).
function M.isOwnBuild(fullPath, buildPath, player)
	if type(fullPath) ~= "string" or type(buildPath) ~= "string" or type(player) ~= "string" or player == "" then
		return false
	end
	local function norm(p)
		return p:gsub("\\", "/"):lower()
	end
	local prefix = norm(buildPath)
	if prefix:sub(-1) ~= "/" then
		prefix = prefix.."/"
	end
	prefix = prefix..norm(player).."/"
	return norm(fullPath):sub(1, #prefix) == prefix
end

return M
