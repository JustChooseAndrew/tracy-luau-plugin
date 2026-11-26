--!strict
-- Colors follow Studio's theme; the accent is the logo's blue.

local Studio = settings().Studio

export type Palette = {
	Background: Color3,
	Box: Color3,
	Border: Color3,
	Outline: Color3,
	Text: Color3,
	DimText: Color3,
	Button: Color3,
	ButtonHover: Color3,
	Accent: Color3,
	AccentHover: Color3,
	OnAccent: Color3,
	Good: Color3,
	Bad: Color3,
	IsDark: boolean,
}

local Theme = {}

Theme.Font = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Medium)
Theme.FontBold = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold)
Theme.Mono = Font.new("rbxasset://fonts/families/RobotoMono.json")

local function color(guide: Enum.StudioStyleGuideColor, modifier: Enum.StudioStyleGuideModifier?): Color3
	return Studio.Theme:GetColor(guide, modifier)
end

function Theme.palette(): Palette
	local background = color(Enum.StudioStyleGuideColor.MainBackground)
	local text = color(Enum.StudioStyleGuideColor.MainText)
	local _, _, value = background:ToHSV()
	return {
		Background = background,
		Box = color(Enum.StudioStyleGuideColor.InputFieldBackground),
		Border = color(Enum.StudioStyleGuideColor.Border),
		-- Argon-style outlines on inputs and buttons: visible in both themes.
		Outline = text:Lerp(background, 0.68),
		Text = text,
		DimText = color(Enum.StudioStyleGuideColor.DimmedText),
		Button = color(Enum.StudioStyleGuideColor.Button),
		ButtonHover = color(Enum.StudioStyleGuideColor.Button, Enum.StudioStyleGuideModifier.Hover),
		Accent = Color3.fromRGB(24, 108, 255),
		AccentHover = Color3.fromRGB(60, 132, 255),
		OnAccent = Color3.new(1, 1, 1),
		Good = Color3.fromRGB(52, 199, 105),
		Bad = Color3.fromRGB(235, 87, 87),
		IsDark = value < 0.5,
	}
end

Theme.Changed = Studio.ThemeChanged

return Theme
