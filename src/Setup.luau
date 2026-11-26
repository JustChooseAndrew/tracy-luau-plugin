--!strict
-- Installs and updates the Tracy module in the open place, and edits its settings.

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ScriptEditorService = game:GetService("ScriptEditorService")
local ServerStorage = game:GetService("ServerStorage")

local bundled = script.Parent.TracyModule

export type Check = {
	installed: boolean,
	version: string?,
	outdated: boolean,
	httpEnabled: boolean,
	libmp: boolean,
}

local Setup = {}

local function versionOf(module: ModuleScript): string?
	return string.match(module.Source, 'local VERSION = "([%d%.]+)"')
end

local function older(a: string, b: string): boolean
	local x, y = string.split(a, "."), string.split(b, ".")
	for i = 1, math.max(#x, #y) do
		local m, n = tonumber(x[i]) or 0, tonumber(y[i]) or 0
		if m ~= n then
			return m < n
		end
	end
	return false
end

local function recorded(name: string, change: () -> ())
	local id = ChangeHistoryService:TryBeginRecording("Tracy-Luau: " .. name)
	local ok, err = pcall(change)
	if id then
		ChangeHistoryService:FinishRecording(
			id,
			if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
	end
	if not ok then
		error(err, 0)
	end
end

Setup.bundledVersion = versionOf(bundled) or "?"

function Setup.module(): ModuleScript?
	local found = ReplicatedStorage:FindFirstChild("Tracy")
	return if found and found:IsA("ModuleScript") then found else nil
end

function Setup.libmp(): ModuleScript?
	for _, parent in { ReplicatedStorage, ServerStorage } do
		local found = parent:FindFirstChild("LibMP")
		if found and found:IsA("ModuleScript") then
			return found
		end
	end
	return nil
end

function Setup.check(): Check
	local module = Setup.module()
	local version = if module then versionOf(module) else nil
	return {
		installed = module ~= nil,
		version = version,
		outdated = version ~= nil and older(version, Setup.bundledVersion),
		httpEnabled = HttpService.HttpEnabled,
		libmp = Setup.libmp() ~= nil,
	}
end

function Setup.install()
	recorded("insert the Tracy module", function()
		local module = bundled:Clone()
		module.Name = "Tracy"
		module.Parent = ReplicatedStorage
	end)
end

-- Replaces the module's source (and its Capture child's), keeping the instance and
-- its attributes, so scripts that reference it keep working.
function Setup.update()
	local module = Setup.module()
	assert(module, "the Tracy module isn't in ReplicatedStorage")
	recorded("update the Tracy module", function()
		for _, source in { bundled, unpack(bundled:GetChildren()) } do
			local target = if source == bundled then module else module:FindFirstChild(source.Name)
			if target == nil then
				local copy = source:Clone()
				copy:ClearAllChildren()
				copy.Parent = module
			else
				local text = (source :: ModuleScript).Source
				ScriptEditorService:UpdateSourceAsync(target :: ModuleScript, function()
					return text
				end)
			end
		end
	end)
end

function Setup.enableHttp()
	recorded("allow HTTP requests", function()
		HttpService.HttpEnabled = true
	end)
end

function Setup.attribute(name: string): any
	local module = Setup.module()
	return if module then module:GetAttribute(name) else nil
end

function Setup.setAttribute(name: string, value: any)
	local module = Setup.module()
	assert(module, "the Tracy module isn't in ReplicatedStorage")
	recorded("set " .. name, function()
		module:SetAttribute(name, value)
	end)
end

return Setup
