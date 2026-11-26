--!strict
-- Settings: "Global" (the plugin's, for every place) and "Place" (attributes on
-- this place's Tracy module, saved with the place).

local Settings = require(script.Parent.Parent.Settings)
local Setup = require(script.Parent.Parent.Setup)
local Theme = require(script.Parent.Theme)
local Ui = require(script.Parent.Ui)

type Palette = Theme.Palette

local SettingsWidget = {}

local function row(p: Palette, order: number, title: string, description: string, control: GuiObject): Frame
	control.AnchorPoint = Vector2.new(1, 0.5)
	control.Position = UDim2.fromScale(1, 0.5)
	return Ui.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Children = {
			Ui.new("Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.new(1, -120, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				Children = {
					Ui.list(2),
					Ui.label(p, title, { FontFace = Theme.FontBold, LayoutOrder = 1 }),
					Ui.label(p, description, { TextColor3 = p.DimText, TextSize = 14, LayoutOrder = 2 }),
				},
			}),
			control,
		},
	})
end

local function field(p: Palette, key: Settings.Key, parse: (string) -> any?): TextBox
	local box = Ui.textbox(p, tostring(Settings.get(key)), {
		Size = UDim2.fromOffset(110, 28),
		BackgroundTransparency = 0,
		BackgroundColor3 = p.Box,
		TextSize = 15,
	})
	for _, child: Instance in { Ui.corner(6), Ui.stroke(p), Ui.padding(0, 8) } do
		child.Parent = box
	end
	box.FocusLost:Connect(function()
		local value = parse(box.Text)
		if value ~= nil then
			Settings.set(key, value)
		end
		box.Text = tostring(Settings.get(key))
	end)
	return box
end

local function section(p: Palette, order: number, title: string, rows: { Instance }): Frame
	local body = Ui.column(2, rows, 12)
	local chevron = Ui.label(p, "⌃", {
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(20, 22),
		AutomaticSize = Enum.AutomaticSize.None,
	})
	local head = Ui.new("TextButton", {
		BackgroundTransparency = 1,
		Text = "",
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = 1,
		Children = {
			Ui.label(p, title, { FontFace = Theme.FontBold, TextSize = 18, AutomaticSize = Enum.AutomaticSize.None }),
			chevron,
		},
	})
	head.Activated:Connect(function()
		body.Visible = not body.Visible
		chevron.Text = if body.Visible then "⌃" else "⌄"
	end)
	return Ui.box(p, order, { Ui.list(12), head, body })
end

local function globalTab(p: Palette): { Instance }
	local function port(text: string): number?
		local n = tonumber(text)
		return if n and n >= 1 and n <= 65535 and n % 1 == 0 then n else nil
	end
	local function host(text: string): string?
		local value = string.gsub(text, "%s", "")
		return if value ~= "" then value else nil
	end
	local function toggle(key: Settings.Key): TextButton
		return Ui.toggle(p, Settings.get(key) == true, function(on)
			Settings.set(key, on)
		end)
	end
	return {
		section(p, 1, "1. Connection", {
			row(p, 1, "Bridge host", "Where tracy-roblox-bridge runs. Use 127.0.0.1.", field(p, "Host", host)),
			row(p, 2, "Bridge port", "The bridge's --port (default 8080).", field(p, "Port", port)),
			row(p, 3, "Connect automatically", "Connect when the plugin starts.", toggle("AutoConnect")),
		}),
		section(p, 2, "2. Place setup", {
			row(
				p,
				1,
				"Check the place",
				"When connecting, offer to insert or update Tracy and turn on HTTP requests.",
				toggle("CheckSetup")
			),
		}),
		section(p, 3, "3. Captures", {
			row(
				p,
				1,
				"Capture button",
				"Keep the MicroProfiler recording in playtests, for one-click captures. Needs LibMP in ReplicatedStorage or ServerStorage.",
				toggle("Captures")
			),
		}),
	}
end

local function placeTab(p: Palette): { Instance }
	if not Setup.module() then
		return {
			Ui.box(p, 1, {
				Ui.label(p, "Tracy isn't in this place yet. Connect to the bridge to insert it.", {
					TextColor3 = p.DimText,
				}),
			}),
		}
	end
	local function attributeToggle(name: string, default: boolean): TextButton
		local value = Setup.attribute(name)
		return Ui.toggle(p, if value == nil then default else value == true, function(on)
			Setup.setAttribute(name, on)
		end)
	end
	local mode = Setup.attribute("MicroProfiler")
	return {
		section(p, 1, "1. Tracy module", {
			row(p, 1, "Streaming", "Send playtests to Tracy.", attributeToggle("Enabled", true)),
			row(
				p,
				2,
				"MicroProfiler",
				"Live: zones go to the MicroProfiler in published games. Always: in playtests too. Off: never.",
				Ui.cycle(
					p,
					{ "Live", "Always", "Off" },
					if type(mode) == "string" then mode else "Live",
					function(value)
						Setup.setAttribute("MicroProfiler", value)
					end
				)
			),
			row(p, 3, "Built-in plots", "Lua heap, instance count and ping.", attributeToggle("BuiltinPlots", true)),
		}),
		Ui.label(p, "Saved with the place, as attributes on ReplicatedStorage.Tracy.", {
			TextColor3 = p.DimText,
			TextSize = 14,
			LayoutOrder = 2,
		}),
	}
end

function SettingsWidget.new(widget: DockWidgetPluginGui): () -> ()
	local tab = "Global"
	local page: ScrollingFrame? = nil
	local render: () -> ()

	local function tabs(p: Palette): Frame
		local buttons = {}
		for i, name in { "Global", "Place" } do
			local selected = name == tab
			local button = Ui.button(p, name, function()
				tab = name
				render()
			end, selected, i)
			button.AutomaticSize = Enum.AutomaticSize.None
			button.Size = UDim2.new(0.5, -4, 0, 32)
			table.insert(buttons, button)
		end
		table.insert(buttons, Ui.list(8, true) :: any)
		return Ui.new("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 32),
			LayoutOrder = 0,
			Children = buttons,
		})
	end

	render = function()
		if page then
			page:Destroy()
		end
		local p = Theme.palette()
		page = Ui.page(p, widget)
		tabs(p).Parent = page
		for _, child in if tab == "Global" then globalTab(p) else placeTab(p) do
			child.Parent = page
		end
	end

	render()
	local themeConnection = Theme.Changed:Connect(render)
	local enabledConnection = widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		if widget.Enabled then
			render()
		end
	end)
	return function()
		themeConnection:Disconnect()
		enabledConnection:Disconnect()
		if page then
			page:Destroy()
		end
	end
end

return SettingsWidget
