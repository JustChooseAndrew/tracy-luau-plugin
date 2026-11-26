--!strict
-- Starts the plugin in whichever DataModel it was loaded into: the windows in Edit,
-- the capture agent in a playtest's server, nothing elsewhere. Returns a stop function.

local RunService = game:GetService("RunService")

local CaptureAgent = require(script.Parent.CaptureAgent)
local HelpWidget = require(script.Parent.Ui.HelpWidget)
local MainWidget = require(script.Parent.Ui.MainWidget)
local Settings = require(script.Parent.Settings)
local SettingsWidget = require(script.Parent.Ui.SettingsWidget)

local Main = {}

Main.VERSION = "0.1.0"

function Main.start(plugin: Plugin, button: PluginToolbarButton?): () -> ()
	Settings.init(plugin)
	if not RunService:IsEdit() then
		if RunService:IsRunning() and RunService:IsServer() then
			return CaptureAgent.start()
		end
		return function() end
	end

	local function dock(id: string, title: string, width: number, height: number): DockWidgetPluginGui
		local info = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, false, width, height, 260, 140)
		local widget = plugin:CreateDockWidgetPluginGui(id, info)
		widget.Name = id
		widget.Title = title
		return widget
	end
	local main = dock("TracyLuau.Main", "Tracy-Luau", 300, 170)
	local settingsWindow = dock("TracyLuau.Settings", "Tracy-Luau - Settings", 360, 420)
	local helpWindow = dock("TracyLuau.Help", "Tracy-Luau - Help", 360, 420)

	local stops = {
		MainWidget.new({
			widget = main,
			version = Main.VERSION,
			openSettings = function()
				settingsWindow.Enabled = true
			end,
			openHelp = function()
				helpWindow.Enabled = true
			end,
		}),
		SettingsWidget.new(settingsWindow),
		HelpWidget.new(helpWindow),
	}

	local connections = {}
	if button then
		table.insert(
			connections,
			button.Click:Connect(function()
				main.Enabled = not main.Enabled
			end)
		)
		table.insert(
			connections,
			main:GetPropertyChangedSignal("Enabled"):Connect(function()
				button:SetActive(main.Enabled)
			end)
		)
		button:SetActive(main.Enabled)
	end

	return function()
		for _, connection in connections do
			connection:Disconnect()
		end
		for _, stop in stops do
			stop()
		end
		for _, widget in { main, settingsWindow, helpWindow } do
			widget:Destroy()
		end
	end
end

return Main
