--!strict
-- Small helpers for building the plugin's widgets out of plain instances.

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)

type Palette = Theme.Palette
type Props = { [string]: any }

local Ui = {}

local QUICK = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SMOOTH = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PULSE = TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

-- Creates an instance. `props.Children` (a list) are parented to it, and
-- `props.Events` (name -> function) are connected.
function Ui.new(className: string, props: Props?): any
	local instance = Instance.new(className)
	local children, events
	for key, value in props or {} do
		if key == "Children" then
			children = value
		elseif key == "Events" then
			events = value
		elseif key ~= "Parent" then
			(instance :: any)[key] = value
		end
	end
	for _, child in children or {} do
		child.Parent = instance
	end
	for name, handler in events or {} do
		(instance :: any)[name]:Connect(handler)
	end
	if props and props.Parent then
		instance.Parent = props.Parent
	end
	return instance
end

function Ui.tween(instance: Instance, goal: Props, info: TweenInfo?): Tween
	local tween = TweenService:Create(instance, info or SMOOTH, goal)
	tween:Play()
	return tween
end

function Ui.corner(radius: number?): UICorner
	return Ui.new("UICorner", { CornerRadius = UDim.new(0, radius or 6) })
end

function Ui.stroke(color: Color3): UIStroke
	return Ui.new("UIStroke", { Color = color, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end

function Ui.padding(all: number, horizontal: number?): UIPadding
	local h = UDim.new(0, horizontal or all)
	return Ui.new("UIPadding", {
		PaddingTop = UDim.new(0, all),
		PaddingBottom = UDim.new(0, all),
		PaddingLeft = h,
		PaddingRight = h,
	})
end

function Ui.list(gap: number, horizontal: boolean?, align: Enum.HorizontalAlignment?): UIListLayout
	return Ui.new("UIListLayout", {
		FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
		Padding = UDim.new(0, gap),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = align or Enum.HorizontalAlignment.Left,
		VerticalAlignment = if horizontal then Enum.VerticalAlignment.Center else Enum.VerticalAlignment.Top,
	})
end

-- A full-width column that sizes to its content.
function Ui.column(order: number, children: { Instance }, gap: number?): Frame
	table.insert(children, Ui.list(gap or 6))
	return Ui.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Children = children,
	})
end

-- A rounded box that sizes to its content: filled, or just outlined like an input.
function Ui.box(p: Palette, order: number, children: { Instance }, outlined: boolean?): Frame
	table.insert(children, Ui.corner())
	table.insert(children, Ui.stroke(if outlined then p.Outline else p.Border))
	table.insert(children, Ui.padding(8, 10))
	return Ui.new("Frame", {
		BackgroundColor3 = if outlined then p.Background else p.Box,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Children = children,
	})
end

function Ui.label(p: Palette, text: string, props: Props?): TextLabel
	local label = Ui.new("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = Theme.Font,
		Text = text,
		TextColor3 = p.Text,
		TextSize = 15,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		RichText = true,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	for key, value in props or {} do
		(label :: any)[key] = value
	end
	return label
end

-- Hover eases the color in; pressing shrinks the button a touch.
local function animate(button: GuiButton, idle: Color3, hover: Color3)
	local scale = Ui.new("UIScale", { Parent = button })
	local inside = false
	button.MouseEnter:Connect(function()
		inside = true
		Ui.tween(button, { BackgroundColor3 = hover }, QUICK)
	end)
	button.MouseLeave:Connect(function()
		inside = false
		Ui.tween(button, { BackgroundColor3 = idle }, QUICK)
		Ui.tween(scale, { Scale = 1 }, QUICK)
	end)
	button.MouseButton1Down:Connect(function()
		Ui.tween(scale, { Scale = 0.95 }, QUICK)
	end)
	button.MouseButton1Up:Connect(function()
		Ui.tween(scale, { Scale = 1 }, QUICK)
		if not inside then
			button.BackgroundColor3 = idle
		end
	end)
end

function Ui.button(p: Palette, text: string, onClick: () -> (), accent: boolean?, order: number?): TextButton
	local idle = if accent then p.Accent else p.Background
	local hover = if accent then p.AccentHover else p.ButtonHover
	local button: TextButton = Ui.new("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = idle,
		FontFace = Theme.Font,
		Text = text,
		TextColor3 = if accent then p.OnAccent else p.Text,
		TextSize = 16,
		Size = UDim2.fromOffset(0, 28),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = order or 0,
		Children = { Ui.corner(), Ui.padding(0, 12), Ui.stroke(if accent then p.AccentHover else p.Outline) },
	})
	animate(button, idle, hover)
	button.Activated:Connect(onClick)
	return button
end

-- A square button with a glyph, like "?" or the gear.
function Ui.iconButton(p: Palette, glyph: string, onClick: () -> (), order: number): TextButton
	local button = Ui.button(p, glyph, onClick, false, order)
	button.AutomaticSize = Enum.AutomaticSize.None
	button.Size = UDim2.fromOffset(28, 28)
	button.FontFace = Theme.FontBold
	button.TextSize = 17;
	(button:FindFirstChildOfClass("UIPadding") :: UIPadding):Destroy()
	return button
end

-- A row of buttons aligned to the right.
function Ui.buttons(order: number, buttons: { TextButton }): Frame
	table.insert(buttons, Ui.list(6, true, Enum.HorizontalAlignment.Right) :: any)
	return Ui.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 28),
		LayoutOrder = order,
		Children = buttons,
	})
end

function Ui.textbox(p: Palette, text: string, props: Props?): TextBox
	local box = Ui.new("TextBox", {
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		FontFace = Theme.Mono,
		Text = text,
		TextColor3 = p.Text,
		PlaceholderColor3 = p.DimText,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	for key, value in props or {} do
		(box :: any)[key] = value
	end
	return box
end

function Ui.toggle(p: Palette, on: boolean, onChange: (boolean) -> ()): TextButton
	local knob = Ui.new("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromOffset(14, 14),
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, if on then 18 else 2, 0.5, 0),
		Children = { Ui.corner(7) },
	})
	local switch: TextButton = Ui.new("TextButton", {
		AutoButtonColor = false,
		Text = "",
		BackgroundColor3 = if on then p.Accent else p.Button,
		Size = UDim2.fromOffset(34, 18),
		Children = { Ui.corner(9), knob },
	})
	switch.Activated:Connect(function()
		on = not on
		Ui.tween(switch, { BackgroundColor3 = if on then p.Accent else p.Button })
		Ui.tween(knob, { Position = UDim2.new(0, if on then 18 else 2, 0.5, 0) })
		onChange(on)
	end)
	return switch
end

-- A button that steps through `options` on each click.
function Ui.cycle(p: Palette, options: { string }, value: string, onChange: (string) -> ()): TextButton
	local button: TextButton
	button = Ui.button(p, value .. "  ▾", function()
		local index = table.find(options, value) or 0
		value = options[index % #options + 1]
		button.Text = value .. "  ▾"
		onChange(value)
	end)
	button.Size = UDim2.fromOffset(0, 26)
	return button
end

-- A status dot; `pulse` makes it breathe.
function Ui.dot(color: Color3, pulse: boolean?): Frame
	local dot = Ui.new("Frame", {
		BackgroundColor3 = color,
		Size = UDim2.fromOffset(8, 8),
		Children = { Ui.corner(4) },
	})
	if pulse then
		Ui.tween(dot, { BackgroundTransparency = 0.55 }, PULSE)
	end
	return dot
end

-- A scrolling page that fills its parent and stacks its children. Returns the page
-- and its holder (destroy the holder); with `fadeIn`, it eases into view.
function Ui.page(p: Palette, parent: Instance, fadeIn: boolean?): (ScrollingFrame, CanvasGroup)
	local page = Ui.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Position = UDim2.fromOffset(0, if fadeIn then 8 else 0),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = p.DimText,
		Children = {
			Ui.new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
			Ui.padding(10),
		},
	})
	local holder = Ui.new("CanvasGroup", {
		BackgroundColor3 = p.Background,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		GroupTransparency = if fadeIn then 1 else 0,
		Children = { page },
		Parent = parent,
	})
	if fadeIn then
		Ui.tween(holder, { GroupTransparency = 0 })
		Ui.tween(page, { Position = UDim2.new() })
	end
	return page, holder
end

return Ui
