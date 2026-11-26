--!strict
-- The main window: logo, bridge address, Connect, and once connected the bridge's
-- status, the place's setup, live tracks and the Capture button.

local Assets = require(script.Parent.Parent.Assets)
local Bridge = require(script.Parent.Parent.Bridge)
local Settings = require(script.Parent.Parent.Settings)
local Setup = require(script.Parent.Parent.Setup)
local Theme = require(script.Parent.Theme)
local Ui = require(script.Parent.Ui)

local POLL_SECONDS = 1
local FAILURES_BEFORE_LOST = 3

type View = "address" | "connecting" | "error" | "connected"

type Row = { frame: Frame, dot: Frame, name: TextLabel, detail: TextLabel, active: boolean }

export type Options = {
	widget: DockWidgetPluginGui,
	version: string,
	openSettings: () -> (),
	openHelp: () -> (),
}

local MainWidget = {}

local function hex(color: Color3): string
	return "#" .. color:ToHex()
end

local function thousands(n: number): string
	local text = tostring(math.floor(n))
	return (string.gsub(string.reverse(string.gsub(string.reverse(text), "(%d%d%d)", "%1,")), "^,", ""))
end

function MainWidget.new(options: Options): () -> ()
	local widget = options.widget
	local view: View = "address"
	local errorText = ""
	local status: Bridge.Status? = nil
	local captureNote: string? = nil
	local pendingRequest: string? = nil
	local generation = 0 -- bumped on connect/disconnect, so a stale loop stops
	local alive = true

	local holder: CanvasGroup? = nil
	local live: { [string]: any } = {}
	local rows: { [string]: Row } = {}
	local render: (fadeIn: boolean?) -> ()

	local function setView(next: View)
		local changed = next ~= view
		view = next
		render(changed)
	end

	local function logo(p: Theme.Palette): Instance
		local id = if p.IsDark then Assets.LogoForDarkTheme else Assets.LogoForLightTheme
		if id ~= "" then
			return Ui.new("ImageLabel", {
				BackgroundTransparency = 1,
				Image = id,
				ScaleType = Enum.ScaleType.Fit,
				Size = UDim2.new(1, -64, 1, 0),
			})
		end
		local blue = hex(p.Accent)
		return Ui.label(
			p,
			`<font color="{blue}">&lt;</font>Tracy<font color="{blue}">-</font>Luau<font color="{blue}">&gt;</font>`,
			{
				FontFace = Theme.FontBold,
				TextSize = 21,
				Size = UDim2.new(1, -64, 1, 0),
				AutomaticSize = Enum.AutomaticSize.None,
			}
		)
	end

	local function header(p: Theme.Palette): Frame
		return Ui.new("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 28),
			LayoutOrder = 1,
			Children = {
				logo(p),
				Ui.label(p, "v" .. options.version, {
					TextColor3 = p.Text,
					TextXAlignment = Enum.TextXAlignment.Right,
					AnchorPoint = Vector2.new(1, 1),
					Position = UDim2.fromScale(1, 1),
					Size = UDim2.fromOffset(56, 16),
					AutomaticSize = Enum.AutomaticSize.None,
				}),
			},
		})
	end

	local function addressBox(p: Theme.Palette): Frame
		local host = Ui.textbox(p, tostring(Settings.get("Host")), {
			PlaceholderText = "127.0.0.1",
			Size = UDim2.new(1, -72, 1, 0),
		})
		local port = Ui.textbox(p, tostring(Settings.get("Port")), {
			PlaceholderText = "8080",
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.new(0, 52, 1, 0),
		})
		host.FocusLost:Connect(function()
			local value = string.gsub(host.Text, "%s", "")
			Settings.set("Host", if value == "" then "127.0.0.1" else value)
			host.Text = Settings.get("Host")
		end)
		port.FocusLost:Connect(function()
			local value = tonumber(port.Text)
			if value and value >= 1 and value <= 65535 and value % 1 == 0 then
				Settings.set("Port", value)
			end
			port.Text = tostring(Settings.get("Port"))
		end)
		return Ui.box(p, 2, {
			Ui.new("Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, 22),
				Children = {
					host,
					Ui.label(p, ":", {
						FontFace = Theme.Mono,
						TextSize = 17,
						TextXAlignment = Enum.TextXAlignment.Center,
						AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.new(1, -54, 0, 0),
						Size = UDim2.new(0, 14, 1, 0),
						AutomaticSize = Enum.AutomaticSize.None,
					}),
					port,
				},
			}),
		}, true)
	end

	local function notice(p: Theme.Palette, text: string, action: string, run: () -> ()): Frame
		return Ui.box(p, 0, {
			Ui.list(8),
			Ui.label(p, text, { LayoutOrder = 1 }),
			Ui.buttons(2, {
				Ui.button(p, action, function()
					local ok, err = pcall(run)
					if not ok then
						warn("[Tracy-Luau] " .. tostring(err))
					end
					render(false)
				end, true),
			}),
		}, true)
	end

	local function setupNotices(p: Theme.Palette, children: { Instance })
		if not Settings.get("CheckSetup") then
			return
		end
		local check = Setup.check()
		local order = 10
		local function add(item: Frame)
			order += 1
			item.LayoutOrder = order
			table.insert(children, item)
		end
		if not check.installed then
			add(notice(p, "Tracy isn't in this place yet.", "Insert Tracy", Setup.install))
		elseif check.outdated then
			add(
				notice(
					p,
					`This place has Tracy {check.version}; the plugin has {Setup.bundledVersion}.`,
					"Update Tracy",
					Setup.update
				)
			)
		end
		if not check.httpEnabled then
			add(
				notice(
					p,
					"Allow HTTP Requests is off, so playtests can't reach the bridge.",
					"Turn it on",
					Setup.enableHttp
				)
			)
		end
		if check.installed then
			local wanted = Settings.bridgeUrl("/ingest")
			local current = Setup.attribute("Url") or "http://127.0.0.1:8080/ingest"
			if current ~= wanted then
				add(notice(p, `This place sends to {current}.`, "Send to this bridge", function()
					Setup.setAttribute("Url", wanted)
				end))
			end
		end
	end

	-- Track rows are kept and updated in place; new ones fade in.
	local function updateTracks(p: Theme.Palette, list: Frame)
		local tracks = if status then status.tracks else {}
		local seen = {}
		for i, track in tracks do
			seen[track.label] = true
			local detail = `{thousands(track.events)} events`
			if track.gaps > 0 then
				detail ..= ` · {track.gaps} gaps`
			end
			local row = rows[track.label]
			if row == nil then
				local dot = Ui.dot(if track.active then p.Good else p.DimText, track.active)
				local name = Ui.label(p, track.label, {
					Size = UDim2.new(0.55, -16, 1, 0),
					AutomaticSize = Enum.AutomaticSize.None,
					LayoutOrder = 1,
					TextTransparency = 1,
				})
				local info = Ui.label(p, detail, {
					Size = UDim2.new(0.45, 0, 1, 0),
					AutomaticSize = Enum.AutomaticSize.None,
					TextColor3 = p.DimText,
					TextXAlignment = Enum.TextXAlignment.Right,
					LayoutOrder = 2,
					TextTransparency = 1,
				})
				row = {
					frame = Ui.new("Frame", {
						BackgroundTransparency = 1,
						Size = UDim2.new(1, 0, 0, 18),
						Children = { Ui.list(8, true), dot, name, info },
						Parent = list,
					}),
					dot = dot,
					name = name,
					detail = info,
					active = track.active,
				}
				rows[track.label] = row
				Ui.tween(name, { TextTransparency = 0 })
				Ui.tween(info, { TextTransparency = 0 })
			elseif row.active ~= track.active then
				row.active = track.active
				row.dot:Destroy()
				row.dot = Ui.dot(if track.active then p.Good else p.DimText, track.active)
				row.dot.Parent = row.frame
			end
			row.frame.LayoutOrder = i
			row.name.TextColor3 = if track.active then p.Text else p.DimText
			row.detail.Text = detail
		end
		for label, row in rows do
			if not seen[label] then
				row.frame:Destroy()
				rows[label] = nil
			end
		end
		live.empty.Visible = #tracks == 0
	end

	local function captureState(): (boolean, string?)
		if not (status and Bridge.serverActive(status)) then
			return false, nil
		end
		local agent = Settings.get("CaptureAgent")
		if type(agent) ~= "table" then
			return false, "Captures start once the playtest's server is up."
		end
		if not agent.ready then
			return false, `Captures are off: {agent.reason}.`
		end
		return true, nil
	end

	-- Updates the connected view in place, so polling doesn't rebuild the window.
	local function refresh()
		local p = Theme.palette()
		if live.summary and status then
			local viewer = if status.viewerConnected
				then `<font color="{hex(p.Good)}">Tracy viewer connected</font>`
				else "Waiting for the Tracy viewer: open Tracy and connect to 127.0.0.1"
			live.summary.Text = `Bridge {status.version} · {viewer}`
		end
		if live.tracks then
			updateTracks(p, live.tracks)
		end
		if live.capture then
			local ready, why = captureState()
			live.capture.Visible = ready
			live.captureNote.Text = captureNote or why or ""
			live.captureNote.Visible = live.captureNote.Text ~= ""
		end
	end

	local function poll(myGeneration: number)
		local failures = 0
		while alive and generation == myGeneration and view == "connected" do
			if widget.Enabled then
				local ok, result = Bridge.status(Settings.bridgeUrl(""))
				if generation ~= myGeneration or view ~= "connected" then
					return
				end
				if ok then
					failures = 0
					status = result :: Bridge.Status
					local reply = Settings.get("CaptureResult")
					if pendingRequest and type(reply) == "table" and reply.request == pendingRequest then
						pendingRequest = nil
						captureNote = if reply.ok
							then `Capture {reply.result} taken. The bridge saves it to its captures folder.`
							else `Capture failed: {reply.result}`
					end
					refresh()
				else
					failures += 1
					if failures >= FAILURES_BEFORE_LOST then
						errorText = "Lost the bridge. Make sure tracy-roblox-bridge is still running."
						generation += 1
						setView("error")
						return
					end
				end
			end
			task.wait(POLL_SECONDS)
		end
	end

	-- "Connecting", "Connecting.", ... on the Connect button while we wait.
	local function animateConnecting(myGeneration: number)
		task.spawn(function()
			local dots = 0
			while alive and generation == myGeneration and view == "connecting" do
				if live.connect then
					live.connect.Text = "Connecting" .. string.rep(".", dots)
				end
				dots = (dots + 1) % 4
				task.wait(0.3)
			end
		end)
	end

	local function connect()
		generation += 1
		local myGeneration = generation
		view = "connecting"
		animateConnecting(myGeneration)
		task.spawn(function()
			local ok, result = Bridge.status(Settings.bridgeUrl(""))
			if generation ~= myGeneration then
				return
			end
			if ok then
				status = result :: Bridge.Status
				captureNote = nil
				setView("connected")
				poll(myGeneration)
			else
				errorText = "Failed to connect! Make sure tracy-roblox-bridge is running and the address is correct."
				warn("[Tracy-Luau] " .. tostring(result))
				setView("error")
			end
		end)
	end

	local function disconnect()
		generation += 1
		status = nil
		setView("address")
	end

	local function capture()
		pendingRequest = `{os.time()}-{math.random(1, 2 ^ 30)}`
		captureNote = "Capturing…"
		Settings.set("CaptureRequest", pendingRequest)
		refresh()
	end

	render = function(fadeIn: boolean?)
		if holder then
			holder:Destroy()
		end
		live = {}
		rows = {}
		local p = Theme.palette()
		local children: { Instance } = { header(p) }
		local helpButton = Ui.iconButton(p, "?", options.openHelp, 1)
		local settingsButton = Ui.iconButton(p, "⚙", options.openSettings, 2)

		if view == "address" or view == "connecting" then
			live.connect = Ui.button(p, "Connect", function()
				if view == "address" then
					connect()
				end
			end, true, 3)
			table.insert(children, addressBox(p))
			table.insert(children, Ui.buttons(3, { helpButton, settingsButton, live.connect }))
		elseif view == "error" then
			table.insert(
				children,
				Ui.box(p, 2, {
					Ui.label(p, errorText, { FontFace = Theme.Mono, TextSize = 15 }),
				}, true)
			)
			table.insert(
				children,
				Ui.buttons(3, {
					Ui.button(p, "Proceed", function()
						setView("address")
					end, false, 1),
				})
			)
		else
			live.summary = Ui.label(p, "", { TextColor3 = p.DimText, TextSize = 13, LayoutOrder = 2 })
			table.insert(
				children,
				Ui.box(p, 2, {
					Ui.list(4),
					Ui.new("Frame", {
						BackgroundTransparency = 1,
						Size = UDim2.new(1, 0, 0, 18),
						LayoutOrder = 1,
						Children = {
							Ui.list(8, true),
							Ui.dot(p.Good, true),
							Ui.label(p, `Connected to {Settings.get("Host")}:{Settings.get("Port")}`, {
								Size = UDim2.new(1, -16, 1, 0),
								AutomaticSize = Enum.AutomaticSize.None,
								LayoutOrder = 1,
							}),
						},
					}),
					live.summary,
				}, true)
			)
			setupNotices(p, children)
			live.empty = Ui.label(p, "Press Play to start streaming.", { TextColor3 = p.DimText, LayoutOrder = 0 })
			live.tracks = Ui.box(p, 30, { Ui.list(4), live.empty }, true)
			table.insert(children, live.tracks)
			live.captureNote = Ui.label(p, "", { TextColor3 = p.DimText, TextSize = 13, LayoutOrder = 40 })
			table.insert(children, live.captureNote)
			live.capture = Ui.button(p, "Capture", capture, false, 3)
			table.insert(
				children,
				Ui.buttons(50, {
					helpButton,
					settingsButton,
					live.capture,
					Ui.button(p, "Disconnect", disconnect, true, 4),
				})
			)
		end

		local page
		page, holder = Ui.page(p, widget, fadeIn)
		for _, child in children do
			child.Parent = page
		end
		if view == "connected" then
			refresh()
		end
	end

	render(true)
	local themeConnection = Theme.Changed:Connect(function()
		render(false)
	end)
	local enabledConnection = widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		if widget.Enabled then
			render(true)
		end
	end)
	if Settings.get("AutoConnect") then
		connect()
	end

	return function()
		alive = false
		generation += 1
		themeConnection:Disconnect()
		enabledConnection:Disconnect()
		if holder then
			holder:Destroy()
		end
	end
end

return MainWidget
