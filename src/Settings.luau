--!strict
-- The plugin's own settings, saved with Studio (plugin:SetSetting), shared by every place.

export type Key =
	"Host"
	| "Port"
	| "AutoConnect"
	| "CheckSetup"
	| "Captures"
	-- how the widget and the playtest's capture agent talk (see CaptureAgent)
	| "CaptureRequest"
	| "CaptureResult"
	| "CaptureAgent"

local DEFAULTS: { [string]: any } = {
	Host = "127.0.0.1",
	Port = 8080,
	AutoConnect = false,
	CheckSetup = true,
	Captures = true,
}

local Settings = {}

local owner: Plugin? = nil
local changed = Instance.new("BindableEvent")
Settings.Changed = changed.Event

function Settings.init(plugin: Plugin)
	owner = plugin
end

function Settings.get(key: Key): any
	local value = (owner :: Plugin):GetSetting(key)
	if value == nil then
		return DEFAULTS[key]
	end
	return value
end

function Settings.set(key: Key, value: any)
	(owner :: Plugin):SetSetting(key, value)
	changed:Fire(key, value)
end

function Settings.bridgeUrl(path: string): string
	return `http://{Settings.get("Host")}:{Settings.get("Port")}{path}`
end

return Settings
