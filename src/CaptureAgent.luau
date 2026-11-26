--!strict
-- Runs in a playtest's server, where the MicroProfiler lives. The widget (in the
-- Edit DataModel) asks for a capture through the plugin's settings, which every
-- copy of the plugin shares; Tracy.Capture takes it and sends it to the bridge.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Settings = require(script.Parent.Settings)
local Setup = require(script.Parent.Setup)

local POLL_SECONDS = 0.25

export type AgentState = {
	ready: boolean,
	reason: string?,
	session: number,
}

local CaptureAgent = {}

local function publish(state: AgentState)
	Settings.set("CaptureAgent", state)
end

function CaptureAgent.start(): () -> ()
	local session = math.random(1, 2 ^ 30)
	local tracy = ReplicatedStorage:FindFirstChild("Tracy")
	local captureModule = tracy and tracy:FindFirstChild("Capture")
	local libmp = Setup.libmp()
	if not Settings.get("Captures") then
		publish({ ready = false, reason = "captures are turned off in settings", session = session })
		return function() end
	elseif not (captureModule and captureModule:IsA("ModuleScript")) then
		publish({ ready = false, reason = "the Tracy module (with Capture) isn't in the place", session = session })
		return function() end
	elseif not libmp then
		publish({ ready = false, reason = "LibMP isn't in ReplicatedStorage or ServerStorage", session = session })
		return function() end
	end

	local Capture = require(captureModule) :: any
	local started, why = Capture.Start({
		LibMP = require(libmp :: ModuleScript),
		Sink = Capture.BridgeSink(Settings.bridgeUrl("/capture")),
		HitchMs = 0,
		Warmup = 10,
		MaxCaptures = 100,
	})
	publish({ ready = started, reason = why, session = session })
	if not started then
		return function() end
	end

	local running = true
	local last = Settings.get("CaptureRequest")
	task.spawn(function()
		while running do
			local request = Settings.get("CaptureRequest")
			if request ~= nil and request ~= last then
				last = request
				local ok, result = Capture.Now("Studio plugin")
				Settings.set("CaptureResult", { request = request, ok = ok, result = result })
			end
			task.wait(POLL_SECONDS)
		end
	end)
	return function()
		running = false
		Capture.Stop()
		publish({ ready = false, reason = "the playtest ended", session = session })
	end
end

return CaptureAgent
