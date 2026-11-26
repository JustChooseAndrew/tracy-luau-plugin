--!strict
-- Help: getting from nothing to a live trace.

local Theme = require(script.Parent.Theme)
local Ui = require(script.Parent.Ui)

local DOCS = "https://github.com/JustChooseAndrew/tracy-luau"

local STEPS = {
	{
		"1. Get the bridge",
		"Download tracy-roblox-bridge from the Tracy-Luau releases. The Windows zip includes the Tracy viewer.",
	},
	{
		"2. Start it",
		"Run tracy-roblox-bridge, then open the Tracy viewer and connect to 127.0.0.1.",
	},
	{
		"3. Connect here",
		"Press Connect. The plugin offers to insert the Tracy module and turn on HTTP requests if the place needs them.",
	},
	{
		"4. Press Play",
		"Each playtest shows up in Tracy: the server and every client on one timeline. Add zones with Tracy.ZoneBegin and Tracy.ZoneEnd, or Tracy.Wrap.",
	},
	{
		"5. Capture",
		"With LibMP in the place, Capture saves the playtest's last frames of the MicroProfiler, engine work included, as a .tracy file next to the bridge.",
	},
}

local HelpWidget = {}

function HelpWidget.new(widget: DockWidgetPluginGui): () -> ()
	local holder: CanvasGroup? = nil

	local function render(fadeIn: boolean?)
		if holder then
			holder:Destroy()
		end
		local p = Theme.palette()
		local page
		page, holder = Ui.page(p, widget, fadeIn)
		Ui.label(p, "The docs, to learn more:", {
			FontFace = Theme.FontBold,
			TextSize = 18,
			TextXAlignment = Enum.TextXAlignment.Center,
			LayoutOrder = 1,
			Parent = page,
		})
		local link = Ui.box(p, 2, {
			Ui.textbox(p, DOCS, {
				TextEditable = false,
				TextColor3 = p.Accent,
				TextSize = 15,
				TextXAlignment = Enum.TextXAlignment.Center,
				Size = UDim2.new(1, 0, 0, 20),
			}),
		})
		link.Parent = page
		for i, step in STEPS do
			local card = Ui.box(p, 2 + i, {
				Ui.list(4),
				Ui.label(p, step[1], { FontFace = Theme.FontBold, TextSize = 18, LayoutOrder = 1 }),
				Ui.label(p, step[2], { TextColor3 = p.DimText, LayoutOrder = 2 }),
			})
			card.Parent = page
		end
	end

	render()
	local themeConnection = Theme.Changed:Connect(render)
	local enabledConnection = widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		if widget.Enabled then
			render(true)
		end
	end)
	return function()
		themeConnection:Disconnect()
		enabledConnection:Disconnect()
		if holder then
			holder:Destroy()
		end
	end
end

return HelpWidget
