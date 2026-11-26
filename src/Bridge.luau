--!strict
-- Reads tracy-roblox-bridge's GET /status.

local HttpService = game:GetService("HttpService")

export type Track = {
	label: string,
	source: number,
	session: string,
	active: boolean,
	batches: number,
	events: number,
	gaps: number,
}

export type Status = {
	version: string,
	tracy: string,
	viewerConnected: boolean,
	tracks: { Track },
}

local Bridge = {}

function Bridge.status(baseUrl: string): (boolean, Status | string)
	local ok, response = pcall(HttpService.RequestAsync, HttpService, {
		Url = baseUrl .. "/status",
		Method = "GET",
	})
	if not ok then
		return false, tostring(response)
	end
	if not response.Success then
		return false, `HTTP {response.StatusCode} {response.StatusMessage}`
	end
	local decoded, status = pcall(HttpService.JSONDecode, HttpService, response.Body)
	if not decoded or type(status) ~= "table" or status.name ~= "tracy-roblox-bridge" then
		return false, "something answered at that address, but it isn't tracy-roblox-bridge"
	end
	return true, status :: Status
end

-- True when a playtest's server session is streaming.
function Bridge.serverActive(status: Status): boolean
	for _, track in status.tracks do
		if track.source == 0 and track.active then
			return true
		end
	end
	return false
end

return Bridge
