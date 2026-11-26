--!strict
-- Small helpers for building the plugin's widgets out of plain instances.

local Theme = require(script.Parent.Theme)

type Palette = Theme.Palette
type Props = { [string]: any }

local Ui = {}

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

function Ui.corner(radius: number?): UICorner
	return Ui.new("UICorner", { CornerRadius = UDim.new(0, radius or 8) })
end

function Ui.stroke(p: Palette): UIStroke
	return Ui.new("UIStroke", { Color = p.Border, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
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
		VerticalAlignment = Enum.VerticalAlignment.Center,
	})
end

-- A full-width row that sizes to its content.
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

-- A rounded, outlined box that sizes to its content.
function Ui.box(p: Palette, order: number, children: { Instance }): Frame
	table.insert(children, Ui.corner())
	table.insert(children, Ui.stroke(p))
	table.insert(children, Ui.padding(10, 12))
	return Ui.new("Frame", {
		BackgroundColor3 = p.Box,
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
		TextSize = 17,
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

function Ui.button(p: Palette, text: string, onClick: () -> (), accent: boolean?, order: number?): TextButton
	local idle = if accent then p.Accent else p.Button
	local hover = if accent then p.AccentHover else p.ButtonHover
	local button: TextButton = Ui.new("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = idle,
		FontFace = Theme.Font,
		Text = text,
		TextColor3 = if accent then p.OnAccent else p.Text,
		TextSize = 18,
		Size = UDim2.fromOffset(0, 34),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = order or 0,
		Children = { Ui.corner(), Ui.padding(0, 14), if accent then nil else Ui.stroke(p) } :: any,
	})
	button.MouseEnter:Connect(function()
		button.BackgroundColor3 = hover
	end)
	button.MouseLeave:Connect(function()
		button.BackgroundColor3 = idle
	end)
	button.Activated:Connect(onClick)
	return button
end

-- A row of buttons aligned to the right.
function Ui.buttons(order: number, buttons: { TextButton }): Frame
	table.insert(buttons, Ui.list(8, true, Enum.HorizontalAlignment.Right) :: any)
	return Ui.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 34),
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
		TextSize = 20,
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
		Size = UDim2.fromOffset(16, 16),
		AnchorPoint = Vector2.new(0, 0.5),
		Children = { Ui.corner(8) },
	})
	local switch: TextButton = Ui.new("TextButton", {
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.fromOffset(40, 22),
		Children = { Ui.corner(11), knob },
	})
	local function paint()
		switch.BackgroundColor3 = if on then p.Accent else p.Button
		knob.Position = UDim2.new(0, if on then 21 else 3, 0.5, 0)
	end
	paint()
	switch.Activated:Connect(function()
		on = not on
		paint()
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
	button.Size = UDim2.fromOffset(0, 30)
	return button
end

function Ui.dot(color: Color3): Frame
	return Ui.new("Frame", {
		BackgroundColor3 = color,
		Size = UDim2.fromOffset(10, 10),
		Children = { Ui.corner(5) },
	})
end

-- A scrolling page that fills its parent and stacks its children.
function Ui.page(p: Palette, parent: Instance): ScrollingFrame
	return Ui.new("ScrollingFrame", {
		BackgroundColor3 = p.Background,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = p.DimText,
		Children = {
			Ui.new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }),
			Ui.padding(12),
		},
		Parent = parent,
	})
end

return Ui
