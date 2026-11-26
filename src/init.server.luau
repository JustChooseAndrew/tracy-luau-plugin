--!strict
-- Tracy-Luau Studio plugin. https://github.com/JustChooseAndrew/tracy-luau-plugin

local RunService = game:GetService("RunService")

local Assets = require(script.Assets)
local Main = require(script.Main)

local button = nil
if RunService:IsEdit() then
	local toolbar = plugin:CreateToolbar("Tracy-Luau")
	button = toolbar:CreateButton("TracyLuau", "Show or hide Tracy-Luau", Assets.Icon, "Tracy-Luau")
	button.ClickableWhenViewportHidden = true
end

plugin.Unloading:Connect(Main.start(plugin, button))
