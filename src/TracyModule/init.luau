--!strict
--!native
--!optimize 2

--[[
	Tracy.luau: streams profiler data from Roblox to the Tracy profiler
	(https://github.com/wolfpld/tracy) through the local tracy-roblox-bridge.

	Part of Tracy-Luau (https://github.com/JustChooseAndrew/tracy-luau), MIT licensed.
	An independent project, not affiliated with or endorsed by Roblox, the Luau
	team, or the Tracy project. Luau is a trademark of Roblox Corporation.

	    local Tracy = require(ReplicatedStorage.Tracy)

	    RunService.Heartbeat:Connect(function()
	        Tracy.ZoneBegin("Enemies", 0xFF5500) -- color optional
	        updateEnemies()
	        Tracy.ZoneEnd()
	        Tracy.Plot("Enemies alive", #enemies)
	        Tracy.FrameMark()
	    end)
	    Tracy.Message("Wave 3 started")

	Works from server Scripts and client LocalScripts. Clients can't make HTTP
	requests, so their data goes through the server, which needs this module
	required by at least one server Script. The server and each client get their
	own track on one aligned timeline.

	Markers can ship in a published place. Outside Studio nothing streams and
	zones go to Roblox's MicroProfiler instead, so they show up in MicroProfiler
	captures from live servers and clients.

	Wrap and Instrument add zones without ZoneBegin/ZoneEnd pairs:

	    local update = Tracy.Wrap("Enemies", updateEnemies)
	    Tracy.Instrument(EnemyService, "EnemyService") -- every function in the table

	Cost: ~0.1 ms per frame for 500 zones (docs/BENCHMARKS.md). Calls through
	locals (local ZoneBegin = Tracy.ZoneBegin) are fastest. Settings: ENABLED and
	MICROPROFILER below, and Tracy.Configure (see Options).

	Rules:
	  * Every ZoneBegin needs a ZoneEnd in the same function, on every path
	    (early returns included).
	  * Don't yield (task.wait, WaitForChild, :InvokeServer, HTTP) between them:
	    other code runs during the yield and its zones would nest inside yours.
	    Tracy closes any zone still open at the end of a frame (it yielded or
	    errored), labels it in the viewer, and warns once.
	  * Use fixed zone and plot names. Each distinct name is registered once, so
	    names built per call ("Enemy " .. i) fill the 65k-name table.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

-- Off = nothing is recorded or streamed, in Studio as well (zones still go to the
-- MicroProfiler, per MICROPROFILER). An "Enabled" attribute (boolean) on this
-- ModuleScript overrides it.
local ENABLED = true

-- When zones also go to Roblox's MicroProfiler through debug.profilebegin/end:
--   "Live"   whenever Tracy isn't streaming: published games, and Studio with Tracy
--            off. Zones then appear in MicroProfiler captures and dumps from live
--            games, at debug.profilebegin's cost (~0.17 µs per begin/end pair).
--   "Always" in Studio playtests too, next to streaming, so Studio's MicroProfiler
--            shows them as well. Adds that cost to every zone.
--   "Off"    never. Zones cost nothing when Tracy isn't streaming.
-- A "MicroProfiler" attribute (string) on this ModuleScript overrides it.
local MICROPROFILER = "Live"

local VERSION = "0.5.0"

-- Wire protocol v2 (docs/PROTOCOL.md).
local PROTOCOL_VERSION = 2
local MAGIC = 0x41554C54 -- "TLUA"
local HEADER_SIZE = 36
local FLAG_FINAL = 1

local OP_REGISTER_STRING = 0x01
local OP_ZONE_BEGIN = 0x02
local OP_ZONE_END = 0x03
local OP_FRAME_MARK = 0x04
local OP_PLOT_VALUE = 0x05
local OP_FRAME_MARK_NAMED = 0x06
local OP_ZONE_BEGIN_COLOR = 0x07
local OP_MESSAGE = 0x08
local OP_PLOT_CONFIG = 0x09
local OP_ZONE_TEXT = 0x0B

local LEAK_TEXT = "[Tracy] still open at the end of a frame (it yielded or errored before ZoneEnd); "
	.. "closed by Tracy, so this duration runs to that point"

local PLOT_FLAG_STEP = 1
local PLOT_FLAG_FILL = 2
local PLOT_FORMATS = { Number = 0, Memory = 1, Percentage = 2 }

local MAX_NAME_BYTES = 1024
local MAX_MESSAGE_BYTES = 8192
local MAX_STRING_ID = 0xFFFE
local OVERFLOW_ID = 0xFFFF
local SEQ_MOD = 0x1_0000_0000

-- HttpService allows 500 requests a minute per server, shared with the game.
-- FlushInterval can't go below MIN_FLUSH_INTERVAL (480/min); an early flush for
-- FlushBytes waits at least EARLY_FLUSH_INTERVAL (300/min) to leave the game room.
-- Client batches ride along in the server's requests, so clients cost no budget.
local MIN_FLUSH_INTERVAL = 0.125
local EARLY_FLUSH_INTERVAL = 0.2
-- How long to hold back after HttpService reports its request budget is spent.
local THROTTLE_BACKOFF = 5

local BUILTIN_PLOT_INTERVAL = 0.1
local RELAY_NAME = "TracyRelay"
local MAX_RELAY_BATCH = 4 * 1024 * 1024
local MAX_CLIENTS = 255
local CLOCK_SYNC_PINGS = 8
local CLOCK_SYNC_SPACING = 0.1

export type Options = {
	-- Where the bridge listens (server only). Use 127.0.0.1: "localhost" can add
	-- seconds per request.
	Url: string?,
	-- Seconds between batches. Each server request costs the game ~0.25 ms however
	-- small it is, so fewer, larger batches are cheaper.
	FlushInterval: number?,
	-- Send early once this many bytes are waiting (busy games), but never more
	-- often than every 0.2 s.
	FlushBytes: number?,
	-- Seconds between reconnect attempts while the bridge is unreachable.
	RetryInterval: number?,
	-- Bytes of unsent events to hold before dropping a batch.
	MaxBufferSize: number?,
	-- Plot Lua heap, instance count and ping 10 times a second (default on).
	BuiltinPlots: boolean?,
}

export type PlotOptions = {
	-- "Number" (default), "Memory" (value in bytes) or "Percentage".
	Format: string?,
	-- Draw as steps instead of a line between samples.
	Step: boolean?,
	-- Fill the area under the line (default true).
	Fill: boolean?,
	-- 0xRRGGBB; 0 or nil lets the viewer pick.
	Color: number?,
}

export type Stats = {
	-- Batches delivered (server: accepted by the bridge; client: handed to the relay).
	BatchesSent: number,
	-- Server requests that failed (bridge down, HTTP error, rate limit).
	BatchesFailed: number,
	-- Batches discarded before sending (no bridge or relay, or the buffer filled up).
	BatchesDropped: number,
	BytesSent: number,
	-- Number of flushes, and total game-thread seconds spent in them.
	Flushes: number,
	FlushSeconds: number,
	-- Server HTTP round trips (off the game thread): total, worst, most recent.
	RoundTripSeconds: number,
	MaxRoundTripSeconds: number,
	LastRoundTripSeconds: number,
	-- Bytes recorded but not yet sent, and the buffer's current size.
	PendingBytes: number,
	BufferBytes: number,
	-- Distinct zone / plot / frame names registered.
	Names: number,
	-- Server: client batches forwarded, and players in the game (each numbered
	-- like its client track).
	RelayedBatches: number,
	Clients: number,
	-- Client: seconds added to this VM's clock to match the server's.
	ClockOffset: number,
	-- Zones Tracy closed because they were still open at the end of a frame.
	ZonesLeaked: number,
	-- ZoneEnd calls with no open zone, which were ignored.
	StrayEnds: number,
}

export type Tracy = {
	VERSION: string,
	-- Opens a zone. `name` should be a fixed string; `color` is 0xRRGGBB.
	ZoneBegin: (name: string, color: number?) -> (),
	-- Closes the most recently opened zone.
	ZoneEnd: () -> (),
	-- Returns a function that runs `fn` inside a zone named `name`. Arguments and
	-- results pass through. Where zones cost nothing, it returns `fn` itself.
	Wrap: <A..., R...>(name: string, fn: (A...) -> R..., color: number?) -> (A...) -> R...,
	-- Wraps every function stored under a string key in `target`, in place, as
	-- zones named "prefix.key" ("key" without a prefix). Returns `target`.
	Instrument: <T>(target: T, prefix: string?, color: number?) -> T,
	-- Marks the end of a frame. With a name, marks a separate frame set.
	FrameMark: (name: string?) -> (),
	-- Adds a sample to the named plot.
	Plot: (name: string, value: number) -> (),
	-- Sets how a plot is drawn. Call once, before or after its first sample.
	ConfigurePlot: (name: string, options: PlotOptions) -> (),
	-- Puts a text marker on this VM's track. `color` is 0xRRGGBB.
	Message: (text: string, color: number?) -> (),
	Configure: (options: Options) -> (),
	-- True when calls are recorded (Studio, running, ENABLED).
	IsActive: () -> boolean,
	-- True while batches are reaching the bridge.
	IsConnected: () -> boolean,
	-- Counters since the module loaded. All zero when inactive.
	GetStats: () -> Stats,
}

local config = {
	Url = "http://127.0.0.1:8080/ingest",
	FlushInterval = 0.25,
	FlushBytes = 512 * 1024,
	RetryInterval = 2,
	MaxBufferSize = 4 * 1024 * 1024,
	BuiltinPlots = true,
}

local function noop() end

local function zeroStats(): Stats
	return {
		BatchesSent = 0,
		BatchesFailed = 0,
		BatchesDropped = 0,
		BytesSent = 0,
		Flushes = 0,
		FlushSeconds = 0,
		RoundTripSeconds = 0,
		MaxRoundTripSeconds = 0,
		LastRoundTripSeconds = 0,
		PendingBytes = 0,
		BufferBytes = 0,
		Names = 0,
		RelayedBatches = 0,
		Clients = 0,
		ClockOffset = 0,
		ZonesLeaked = 0,
		StrayEnds = 0,
	}
end

local enabled = ENABLED
local enabledAttribute = script:GetAttribute("Enabled")
if type(enabledAttribute) == "boolean" then
	enabled = enabledAttribute
end
local microProfiler: any = script:GetAttribute("MicroProfiler") or MICROPROFILER
if microProfiler ~= "Live" and microProfiler ~= "Always" and microProfiler ~= "Off" then
	warn(`[Tracy] MicroProfiler must be "Live", "Always" or "Off", not {tostring(microProfiler)}; using "Live"`)
	microProfiler = "Live"
end
-- Defaults for Configure's Url and BuiltinPlots (the Tracy-Luau plugin sets these).
local urlAttribute = script:GetAttribute("Url")
if type(urlAttribute) == "string" and urlAttribute ~= "" then
	config.Url = urlAttribute
end
local builtinPlotsAttribute = script:GetAttribute("BuiltinPlots")
if type(builtinPlotsAttribute) == "boolean" then
	config.BuiltinPlots = builtinPlotsAttribute
end

local profileBegin = debug.profilebegin
local profileEnd = debug.profileend

local function checkWrapArgs(name: any, fn: any)
	if type(name) ~= "string" then
		error(`Tracy.Wrap: name must be a string, got {typeof(name)}`, 3)
	end
	if type(fn) ~= "function" then
		error(`Tracy.Wrap: expected a function, got {typeof(fn)}`, 3)
	end
end

-- Wrap on top of a begin/end pair (Tracy's own, or the MicroProfiler's).
local function makeWrap(begin: (string, number?) -> (), finish: () -> ())
	local function close(...: any): ...any
		finish()
		return ...
	end
	return function(name: string, fn: (...any) -> ...any, color: number?): (...any) -> ...any
		checkWrapArgs(name, fn)
		return function(...: any): ...any
			begin(name, color)
			return close(fn(...))
		end
	end
end

-- Functions Wrap made for Instrument, so instrumenting a table twice doesn't nest.
local instrumented: { [any]: boolean } = setmetatable({} :: any, { __mode = "k" })

local function makeInstrument(wrap: (string, (...any) -> ...any, number?) -> (...any) -> ...any)
	return function(target: any, prefix: string?, color: number?): any
		if type(target) ~= "table" then
			error(`Tracy.Instrument expects a table, got {typeof(target)}`, 2)
		end
		if prefix ~= nil and type(prefix) ~= "string" then
			error(`Tracy.Instrument: prefix must be a string, got {typeof(prefix)}`, 2)
		end
		if table.isfrozen(target) then
			error("Tracy.Instrument: the table is frozen; instrument it before freezing", 2)
		end
		local base = if prefix ~= nil and prefix ~= "" then prefix .. "." else ""
		local keys = {}
		for key, value in target do
			if type(key) == "string" and type(value) == "function" and not instrumented[value] then
				table.insert(keys, key)
			end
		end
		for _, key in keys do
			local wrapped = wrap(base .. key, target[key], color)
			instrumented[wrapped] = true
			target[key] = wrapped
		end
		return target
	end
end

-- IsRunning keeps plugin and command-bar requires in Edit mode quiet.
local active = enabled and RunService:IsStudio() and RunService:IsRunning()

if not active then
	local mirror = microProfiler ~= "Off"
	local wrap = if mirror
		then makeWrap(profileBegin :: any, profileEnd)
		else function(name: string, fn: (...any) -> ...any, _color: number?)
			checkWrapArgs(name, fn)
			return fn
		end
	local off: Tracy = {
		VERSION = VERSION,
		ZoneBegin = (if mirror then profileBegin else noop) :: any,
		ZoneEnd = if mirror then profileEnd else noop,
		Wrap = wrap :: any,
		Instrument = (if mirror
			then makeInstrument(wrap)
			else function(target: any)
				return target
			end) :: any,
		FrameMark = noop :: any,
		Plot = noop :: any,
		ConfigurePlot = noop :: any,
		Message = noop :: any,
		Configure = noop :: any,
		IsActive = function()
			return false
		end,
		IsConnected = function()
			return false
		end,
		GetStats = zeroStats,
	}
	return table.freeze(off)
end

local isServer = RunService:IsServer()

---------------------------------------------------------------- state

-- Pending events: a header-sized gap, then events in the order they happened.
local buf = buffer.create(64 * 1024)
local cap = buffer.len(buf)
local off = HEADER_SIZE
-- Pending bytes before this offset are only a re-sent registration block.
local regEnd = HEADER_SIZE

local ids: { [string]: number } = {}
local names: { [number]: string } = {}
local nextId = 1
-- Plot settings, re-sent with the names whenever data may have been lost.
type PlotConfig = { format: number, flags: number, color: number }
local plotConfigs: { [number]: PlotConfig } = {}

local sessionId = Random.new():NextInteger(0, SEQ_MOD - 1)
local seq = 0
local closed = false -- set once the final batch is sealed; nothing is sent after it
local connected = false
local warnedOverflow = false
local warnedNames = false
local lastFlush = os.clock()
local lastBuiltin = 0
local relayBytes = 0 -- server: bytes of client batches waiting to be forwarded

local statSent = 0
local statFailed = 0
local statDropped = 0
local statBytes = 0
local statFlushes = 0
local statFlushSeconds = 0
local statRtt = 0
local statRttMax = 0
local statRttLast = 0
local statRelayed = 0
local statClients = 0
local clockOffset = 0 -- client: seconds to add to os.clock() to get the server's clock

-- Open zones on this VM, innermost last.
local depth = 0
local openIds: { number } = table.create(32)
local mirrorInStudio = microProfiler == "Always"
local statLeaked = 0
local statStray = 0
local warnedLeak: { [number]: boolean } = {}
local warnedStray = false

---------------------------------------------------------------- buffer management

local function writeRegistration(b: buffer, o: number, id: number, text: string): number
	local n = #text
	buffer.writeu8(b, o, OP_REGISTER_STRING)
	buffer.writeu16(b, o + 1, id)
	buffer.writeu16(b, o + 3, n)
	buffer.writestring(b, o + 5, text)
	return o + 5 + n
end

local function writePlotConfig(b: buffer, o: number, id: number, pc: PlotConfig): number
	buffer.writeu8(b, o, OP_PLOT_CONFIG)
	buffer.writeu16(b, o + 1, id)
	buffer.writeu8(b, o + 3, pc.format)
	buffer.writeu8(b, o + 4, pc.flags)
	buffer.writeu32(b, o + 5, pc.color)
	return o + 9
end

local function registrationBytes(): number
	local total = 0
	for _, text in names do
		total += 5 + #text
	end
	for _ in plotConfigs do
		total += 9
	end
	return total
end

-- Rebuilds the pending batch with every known name (and plot setting) at its
-- front. Called whenever events may have been lost, so the bridge never sees an
-- id it can't name. With keepEvents false (or no room) the pending events are
-- dropped and the sequence skips one, which tells the bridge to close open zones.
local function reRegisterAll(keepEvents: boolean)
	-- Bytes before regEnd are an earlier re-registration block, rewritten below anyway.
	local recorded = off - regEnd
	local events = if keepEvents then recorded else 0
	local regs = registrationBytes()
	if HEADER_SIZE + regs + events > config.MaxBufferSize then
		events = 0
	end
	if events == 0 and recorded > 0 then
		seq = (seq + 1) % SEQ_MOD
		statDropped += 1
	end
	local need = HEADER_SIZE + regs + events
	local start = HEADER_SIZE + regs
	if need <= cap then
		-- Rebuild in place to avoid garbage. buffer.copy is overlap-safe, so move the
		-- kept events first, then rewrite the names in front of them.
		if events > 0 and start ~= regEnd then
			buffer.copy(buf, start, buf, regEnd, events)
		end
	else
		local newCap = cap
		while newCap < need do
			newCap *= 2
		end
		if newCap > config.MaxBufferSize then
			newCap = math.max(need, config.MaxBufferSize)
		end
		local b = buffer.create(newCap)
		if events > 0 then
			buffer.copy(b, start, buf, regEnd, events)
		end
		buf = b
		cap = newCap
	end
	local o = HEADER_SIZE
	for id, text in names do
		o = writeRegistration(buf, o, id, text)
	end
	for id, pc in plotConfigs do
		o = writePlotConfig(buf, o, id, pc)
	end
	regEnd = o
	off = o + events
end

-- Makes room for `need` more bytes. False means the event can't be recorded.
local function ensure(need: number): boolean
	local want = off + need
	if want <= cap then
		return true
	end
	local limit = config.MaxBufferSize
	local newCap = cap * 2
	while newCap < want do
		newCap *= 2
	end
	if newCap > limit then
		newCap = limit
	end
	if want > newCap then
		-- Batches aren't leaving fast enough. Drop this one rather than grow forever.
		if not warnedOverflow then
			warnedOverflow = true
			warn(`[Tracy] more than {limit} bytes of events waiting to send; dropping a batch`)
		end
		reRegisterAll(false)
		return off + need <= cap
	end
	local b = buffer.create(newCap)
	buffer.copy(b, 0, buf, 0, off)
	buf = b
	cap = newCap
	return true
end

local function register(name: string): number
	if type(name) ~= "string" then
		error(`Tracy: zone, plot and frame names must be strings, got {typeof(name)}`, 3)
	end
	if nextId > MAX_STRING_ID then
		if not warnedNames then
			warnedNames = true
			warn("[Tracy] over 65,534 unique names; are names built per call? Extra names share one entry")
		end
		ids[name] = OVERFLOW_ID
		if names[OVERFLOW_ID] == nil then
			local text = "[Tracy] too many unique names"
			names[OVERFLOW_ID] = text
			if ensure(5 + #text) then
				off = writeRegistration(buf, off, OVERFLOW_ID, text)
			end
		end
		return OVERFLOW_ID
	end
	local id = nextId
	nextId += 1
	local text = if #name > MAX_NAME_BYTES then string.sub(name, 1, MAX_NAME_BYTES) else name
	ids[name] = id
	names[id] = text
	if ensure(5 + #text) then
		off = writeRegistration(buf, off, id, text)
	end
	return id
end

---------------------------------------------------------------- recording (hot path)

local function zoneBegin(name: string, color: number?)
	local id = ids[name]
	if id == nil then
		id = register(name)
	end
	local d = depth + 1
	depth = d
	openIds[d] = id
	if mirrorInStudio then
		profileBegin(name)
	end
	if color == nil then
		if off + 11 > cap and not ensure(11) then
			return
		end
		local o = off
		-- opcode + id in one write; the timestamp then overwrites the spare 4th byte
		buffer.writeu32(buf, o, OP_ZONE_BEGIN + id * 256)
		buffer.writef64(buf, o + 3, os.clock())
		off = o + 11
	else
		if off + 15 > cap and not ensure(15) then
			return
		end
		local o = off
		buffer.writeu32(buf, o, OP_ZONE_BEGIN_COLOR + id * 256)
		buffer.writeu32(buf, o + 11, color)
		buffer.writef64(buf, o + 3, os.clock()) -- last, so it's closest to the zone's code
		off = o + 15
	end
end

local function strayEnd()
	statStray += 1
	-- A leaked zone's late ZoneEnd also lands here, and was already warned about.
	if not warnedStray and statLeaked == 0 then
		warnedStray = true
		warn("[Tracy] ZoneEnd with no open zone (an extra ZoneEnd?); ignored")
	end
end

local function zoneEnd()
	local t = os.clock()
	local d = depth
	if d == 0 then
		-- Writing it could close a zone that belongs to other code.
		strayEnd()
		return
	end
	depth = d - 1
	if mirrorInStudio then
		profileEnd()
	end
	if off + 9 > cap and not ensure(9) then
		return
	end
	local o = off
	buffer.writeu8(buf, o, OP_ZONE_END)
	buffer.writef64(buf, o + 1, t)
	off = o + 9
end

-- Runs once a frame, at a point where no Luau code is mid-zone: anything still
-- open yielded inside its zone or errored before ZoneEnd. Close it now, with a
-- note in the viewer, so the rest of the track stays correct.
local function closeLeakedZones()
	local d = depth
	if d == 0 then
		return
	end
	local t = os.clock()
	local textLen = #LEAK_TEXT
	for i = d, 1, -1 do
		local id = openIds[i]
		if not warnedLeak[id] then
			warnedLeak[id] = true
			warn(
				`[Tracy] zone "{names[id]}" was still open at the end of a frame: it yielded or errored `
					.. "before ZoneEnd. Tracy closed it and will ignore its late ZoneEnd."
			)
		end
		if ensure(3 + textLen + 9) then
			local o = off
			buffer.writeu8(buf, o, OP_ZONE_TEXT)
			buffer.writeu16(buf, o + 1, textLen)
			buffer.writestring(buf, o + 3, LEAK_TEXT)
			o += 3 + textLen
			buffer.writeu8(buf, o, OP_ZONE_END)
			buffer.writef64(buf, o + 1, t)
			off = o + 9
		end
	end
	statLeaked += d
	depth = 0
end

local function frameMark(name: string?)
	local t = os.clock()
	if name == nil then
		if off + 9 > cap and not ensure(9) then
			return
		end
		local o = off
		buffer.writeu8(buf, o, OP_FRAME_MARK)
		buffer.writef64(buf, o + 1, t)
		off = o + 9
		return
	end
	local id = ids[name]
	if id == nil then
		id = register(name)
	end
	if off + 11 > cap and not ensure(11) then
		return
	end
	local o = off
	buffer.writeu32(buf, o, OP_FRAME_MARK_NAMED + id * 256)
	buffer.writef64(buf, o + 3, t)
	off = o + 11
end

local function plot(name: string, value: number)
	local t = os.clock()
	local id = ids[name]
	if id == nil then
		id = register(name)
	end
	if off + 19 > cap and not ensure(19) then
		return
	end
	local o = off
	buffer.writeu32(buf, o, OP_PLOT_VALUE + id * 256)
	buffer.writef64(buf, o + 11, value) -- errors on a non-number before anything is committed
	buffer.writef64(buf, o + 3, t)
	off = o + 19
end

local function message(text: string, color: number?)
	local t = os.clock()
	if type(text) ~= "string" then
		error(`Tracy.Message expects a string, got {typeof(text)}`, 2)
	end
	local n = #text
	if n == 0 then
		return
	end
	if n > MAX_MESSAGE_BYTES then
		text = string.sub(text, 1, MAX_MESSAGE_BYTES)
		n = MAX_MESSAGE_BYTES
	end
	if off + 15 + n > cap and not ensure(15 + n) then
		return
	end
	local o = off
	buffer.writeu8(buf, o, OP_MESSAGE)
	buffer.writef64(buf, o + 1, t)
	buffer.writeu32(buf, o + 9, color or 0)
	buffer.writeu16(buf, o + 13, n)
	buffer.writestring(buf, o + 15, text)
	off = o + 15 + n
end

local function configurePlot(name: string, options: PlotOptions)
	assert(type(options) == "table", "Tracy.ConfigurePlot expects an options table")
	local format = PLOT_FORMATS[options.Format or "Number"]
	assert(format ~= nil, `Tracy.ConfigurePlot: Format must be "Number", "Memory" or "Percentage"`)
	local id = ids[name]
	if id == nil then
		id = register(name)
	end
	local pc: PlotConfig = {
		format = format,
		flags = (if options.Step then PLOT_FLAG_STEP else 0) + (if options.Fill == false then 0 else PLOT_FLAG_FILL),
		color = options.Color or 0,
	}
	plotConfigs[id] = pc
	if ensure(9) then
		off = writePlotConfig(buf, off, id, pc)
	end
end

local function writeHeader(
	b: buffer,
	source: number,
	flags: number,
	session: number,
	sequence: number,
	flushClock: number,
	offset: number,
	length: number
)
	buffer.writeu32(b, 0, MAGIC)
	buffer.writeu8(b, 4, PROTOCOL_VERSION)
	buffer.writeu8(b, 5, source)
	buffer.writeu16(b, 6, flags)
	buffer.writeu32(b, 8, session)
	buffer.writeu32(b, 12, sequence)
	buffer.writef64(b, 16, flushClock)
	buffer.writef64(b, 24, offset)
	buffer.writeu32(b, 32, length)
end

local FLUSH_ZONE_ID = register("Tracy::Flush")

-- The profiler's own cost on the game thread, as a zone in the next batch.
local function recordFlush(t0: number, t1: number)
	statFlushes += 1
	statFlushSeconds += t1 - t0
	if ensure(20) then
		local o = off
		buffer.writeu32(buf, o, OP_ZONE_BEGIN + FLUSH_ZONE_ID * 256)
		buffer.writef64(buf, o + 3, t0)
		buffer.writeu8(buf, o + 11, OP_ZONE_END)
		buffer.writef64(buf, o + 12, t1)
		off = o + 20
	end
end

---------------------------------------------------------------- built-in plots

local builtinsConfigured = false
-- Server: "Ping Client 3 (ms)", numbered like the client tracks (not by username,
-- which would end up in shared screenshots).
local pingNames: { [Player]: string } = {}

local function sampleBuiltins()
	if not builtinsConfigured then
		builtinsConfigured = true
		configurePlot("Lua heap", { Format = "Memory" })
	end
	plot("Lua heap", gcinfo() * 1024)
	plot("Instances", Stats.InstanceCount)
	if isServer then
		for player, label in pingNames do
			local ok, ping = pcall(player.GetNetworkPing, player)
			if ok then
				plot(label, ping * 1000)
			end
		end
	else
		local player = Players.LocalPlayer
		if player then
			local ok, ping = pcall(player.GetNetworkPing, player)
			if ok then
				plot("Ping (ms)", ping * 1000)
			end
		end
	end
end

---------------------------------------------------------------- transport

local flush: (final: boolean) -> boolean
-- Called when Configure changes the Url: forget the old connection, retry at once.
local resetConnection: () -> () = noop

if isServer then
	-- Server: posts to the bridge over HTTP and forwards the clients' batches.
	local inFlight = false
	local warnedUnreachable = false
	local warnedThrottle = false
	local warnedRejected = false
	local lastAttempt = -math.huge
	local throttledUntil = -math.huge

	local request = {
		Url = config.Url,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/octet-stream" },
		Body = "",
	}

	type ClientInfo = {
		index: number,
		session: number?,
		seq: number,
		clock: number,
		offset: number,
		greeted: boolean,
	}
	local clients: { [Player]: ClientInfo } = {}
	local clientBySession: { [number]: Player } = {}
	local usedIndex: { [number]: boolean } = {}
	local relayQueue: { buffer } = {}

	local relay = script:FindFirstChild(RELAY_NAME)
	if relay == nil or not relay:IsA("RemoteEvent") then
		relay = Instance.new("RemoteEvent")
		relay.Name = RELAY_NAME
		relay.Parent = script
	end
	local remote = relay :: RemoteEvent

	local function setConnected(value: boolean)
		if connected == value then
			return
		end
		connected = value
		remote:FireAllClients("status", value)
		if value then
			-- Whatever clients sent while the bridge was away is gone, names included.
			remote:FireAllClients("resync")
		end
	end

	local function clientFor(player: Player): ClientInfo?
		local info = clients[player]
		if info then
			return info
		end
		if player.Parent == nil then
			return nil -- a batch that arrived after the player left
		end
		for i = 1, MAX_CLIENTS do
			if not usedIndex[i] then
				usedIndex[i] = true
				local created: ClientInfo =
					{ index = i, session = nil, seq = 0, clock = 0, offset = 0, greeted = false }
				clients[player] = created
				pingNames[player] = `Ping Client {i} (ms)`
				statClients += 1
				return created
			end
		end
		return nil
	end

	-- Number players as they join, so a player's ping plot and client track share a number.
	Players.PlayerAdded:Connect(function(player)
		clientFor(player)
	end)
	for _, player in Players:GetPlayers() do
		clientFor(player)
	end

	local function finalFor(info: ClientInfo): buffer
		local b = buffer.create(HEADER_SIZE)
		writeHeader(
			b,
			info.index,
			FLAG_FINAL,
			info.session :: number,
			(info.seq + 1) % SEQ_MOD,
			info.clock,
			info.offset,
			0
		)
		return b
	end

	remote.OnServerEvent:Connect(function(player: Player, kind: any, a: any)
		if kind == "batch" then
			if closed or typeof(a) ~= "buffer" then
				return
			end
			local batch = a :: buffer
			local n = buffer.len(batch)
			if n < HEADER_SIZE or n > MAX_RELAY_BATCH then
				return
			end
			if buffer.readu32(batch, 0) ~= MAGIC or buffer.readu8(batch, 4) ~= PROTOCOL_VERSION then
				return
			end
			if buffer.readu32(batch, 32) ~= n - HEADER_SIZE then
				return
			end
			local info = clientFor(player)
			if info == nil then
				return
			end
			-- The server numbers clients; that number picks the track ("Roblox Client 1").
			buffer.writeu8(batch, 5, info.index)
			local session = buffer.readu32(batch, 8)
			if info.session ~= session then
				if info.session then
					clientBySession[info.session] = nil
				end
				info.session = session
				clientBySession[session] = player
			end
			info.seq = buffer.readu32(batch, 12)
			info.clock = buffer.readf64(batch, 16)
			info.offset = buffer.readf64(batch, 24)
			if not info.greeted then
				info.greeted = true
				remote:FireClient(player, "status", connected)
			end
			if relayBytes + n > config.MaxBufferSize then
				statDropped += 1 -- the bridge sees the sequence gap and closes open zones
				return
			end
			table.insert(relayQueue, batch)
			relayBytes += n
		elseif kind == "sync" then
			if typeof(a) == "number" then
				remote:FireClient(player, "sync", a, os.clock())
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		pingNames[player] = nil
		local info = clients[player]
		if info == nil then
			return
		end
		clients[player] = nil
		usedIndex[info.index] = nil
		statClients -= 1
		if info.session then
			-- End the client's session now, so its track is free for the next player.
			clientBySession[info.session] = nil
			table.insert(relayQueue, finalFor(info))
			relayBytes += HEADER_SIZE
		end
	end)

	local function describeFailure(ok: boolean, result: any): string
		if not ok then
			return tostring(result)
		end
		local body = if type(result.Body) == "string" and #result.Body > 0 then `: {result.Body}` else ""
		return `HTTP {result.StatusCode} {result.StatusMessage}{body}`
	end

	-- 200 means some batches need attention, one line each (docs/PROTOCOL.md).
	local function handleNotes(body: string)
		for line in string.gmatch(body, "[^\n]+") do
			local kind, hex, rest = string.match(line, "^(%a+) (%S+) ?(.*)$")
			local session = if hex then tonumber(hex, 16) else nil
			if kind == "resync" and session then
				if session == sessionId then
					reRegisterAll(true)
				else
					local player = clientBySession[session]
					if player then
						remote:FireClient(player, "resync")
					end
				end
			elseif kind == "error" and not warnedRejected then
				warnedRejected = true
				local who = if session == sessionId then "the server" else "a client"
				warn(`[Tracy] the bridge rejected a batch from {who}: {rest}`)
			end
		end
	end

	local function onResponse(ok: boolean, result: any, bytes: number)
		inFlight = false
		if ok and result.Success then
			statSent += 1
			statBytes += bytes
			if not connected then
				warnedUnreachable = false
				print(`[Tracy] streaming to {config.Url}`)
			end
			setConnected(true)
			if result.StatusCode == 200 and type(result.Body) == "string" then
				handleNotes(result.Body)
			end
			return
		end

		statFailed += 1
		local reason = describeFailure(ok, result)

		if string.find(reason, "exceeded limit", 1, true) or string.find(reason, "429", 1, true) then
			-- HttpService's per-server budget is spent; the bridge is fine. Hold off so the
			-- game's own requests get through, then send a bigger batch.
			throttledUntil = os.clock() + THROTTLE_BACKOFF
			if not warnedThrottle then
				warnedThrottle = true
				warn(
					`[Tracy] HttpService request limit reached ({reason}); pausing sends for {THROTTLE_BACKOFF}s. `
						.. "Raise FlushInterval if this keeps happening."
				)
			end
			reRegisterAll(true)
			remote:FireAllClients("resync") -- their batches were in that request
			return
		end

		if not warnedUnreachable then
			warnedUnreachable = true
			if string.find(reason, "not enabled", 1, true) then
				warn("[Tracy] HTTP requests are off. Turn on Game Settings > Security > Allow HTTP Requests.")
			elseif connected then
				warn(`[Tracy] lost the bridge ({reason}); retrying every {config.RetryInterval}s`)
			else
				warn(
					`[Tracy] can't reach the bridge at {config.Url} ({reason}). `
						.. `Start tracy-roblox-bridge; retrying every {config.RetryInterval}s.`
				)
			end
		end
		setConnected(false)
		-- The batch is gone, and its name registrations with it.
		reRegisterAll(true)
	end

	resetConnection = function()
		setConnected(false)
		warnedUnreachable = false
		lastAttempt = -math.huge
	end

	local function send(payload: string)
		local t0 = os.clock()
		request.Url = config.Url
		request.Body = payload
		local ok, result = pcall(HttpService.RequestAsync, HttpService, request)
		request.Body = "" -- let the payload be collected
		local rtt = os.clock() - t0
		statRtt += rtt
		statRttLast = rtt
		if rtt > statRttMax then
			statRttMax = rtt
		end
		onResponse(ok, result, #payload)
	end

	-- Seals the pending events into a batch, appends the relayed client batches, and
	-- posts it all as one request. One request at a time, so batches arrive in order.
	flush = function(final: boolean): boolean
		if inFlight or closed then
			return false
		end
		local t0 = os.clock()
		if t0 < throttledUntil and not final then
			return false -- keep buffering until HttpService's budget recovers
		end
		if not connected and t0 - lastAttempt < config.RetryInterval then
			-- Nobody is listening. Keep the names, drop the events (clients resync
			-- once the bridge is back).
			if not final then
				if off > regEnd then
					reRegisterAll(false)
				end
				if #relayQueue > 0 then
					statDropped += #relayQueue
					table.clear(relayQueue)
					relayBytes = 0
				end
			end
			return false
		end
		if off == HEADER_SIZE and #relayQueue == 0 and not final then
			return false
		end
		lastAttempt = t0

		if final then
			for _, info in clients do
				if info.session then
					table.insert(relayQueue, finalFor(info))
					relayBytes += HEADER_SIZE
				end
			end
		end

		-- The server's batch goes first: the bridge times relayed client batches
		-- against it.
		local own = off
		writeHeader(buf, 0, if final then FLAG_FINAL else 0, sessionId, seq, t0, 0, own - HEADER_SIZE)
		seq = (seq + 1) % SEQ_MOD
		local total = own + relayBytes
		if total > cap then
			local newCap = cap
			while newCap < total do
				newCap *= 2
			end
			local b = buffer.create(newCap)
			buffer.copy(b, 0, buf, 0, own)
			buf = b
			cap = newCap
		end
		local o = own
		for _, batch in relayQueue do
			local n = buffer.len(batch)
			buffer.copy(buf, o, batch, 0, n)
			o += n
		end
		statRelayed += #relayQueue
		table.clear(relayQueue)
		relayBytes = 0

		local payload = buffer.readstring(buf, 0, total)
		off = HEADER_SIZE
		regEnd = HEADER_SIZE
		inFlight = true
		closed = final
		task.spawn(send, payload)

		if not final then
			recordFlush(t0, os.clock())
		end
		return true
	end

	-- Send what's left and tell the bridge every session here is over, so their
	-- tracks are free for the next playtest right away.
	game:BindToClose(function()
		if not connected then
			closed = true
			return
		end
		local deadline = os.clock() + 2
		while inFlight and os.clock() < deadline do
			task.wait()
		end
		if flush(true) then
			while inFlight and os.clock() < deadline do
				task.wait()
			end
		end
		closed = true
	end)
else
	-- Client: batches go to the server over the relay RemoteEvent.
	local relay: RemoteEvent? = nil
	local bestRtt = math.huge

	local function onSync(c0: any, s: any)
		if type(c0) ~= "number" or type(s) ~= "number" then
			return
		end
		local c1 = os.clock()
		local rtt = c1 - c0
		if rtt < bestRtt then
			bestRtt = rtt
			local estimate = s - (c0 + c1) / 2
			-- Within half a round trip of zero, the two clocks are the same clock (Play
			-- Solo runs server and client in one process): use exactly zero.
			clockOffset = if math.abs(estimate) <= rtt / 2 then 0 else estimate
		end
	end

	task.spawn(function()
		local found = script:WaitForChild(RELAY_NAME, 30)
		if found == nil or not found:IsA("RemoteEvent") then
			warn(
				"[Tracy] no relay from the server after 30 s, so client data has nowhere to go. "
					.. "Require Tracy from a server Script too."
			)
			return
		end
		local remote = found :: RemoteEvent
		remote.OnClientEvent:Connect(function(kind: any, a: any, b: any)
			if kind == "sync" then
				onSync(a, b)
			elseif kind == "resync" then
				reRegisterAll(true)
			elseif kind == "status" then
				connected = a == true
			end
		end)
		relay = remote
		-- Measure the client-to-server clock offset; the best (lowest round trip) wins.
		for _ = 1, CLOCK_SYNC_PINGS do
			remote:FireServer("sync", os.clock())
			task.wait(CLOCK_SYNC_SPACING)
		end
	end)

	flush = function(_final: boolean): boolean
		local remote = relay
		if remote == nil then
			-- No relay yet. Keep the names, drop the events.
			if off > regEnd then
				reRegisterAll(false)
			end
			return false
		end
		if off == HEADER_SIZE then
			return false
		end
		local t0 = os.clock()
		writeHeader(buf, 0, 0, sessionId, seq, t0, clockOffset, off - HEADER_SIZE)
		seq = (seq + 1) % SEQ_MOD
		local batch = buffer.create(off)
		buffer.copy(batch, 0, buf, 0, off)
		remote:FireServer("batch", batch)
		statSent += 1
		statBytes += off
		off = HEADER_SIZE
		regEnd = HEADER_SIZE
		recordFlush(t0, os.clock())
		return true
	end
end

RunService.Heartbeat:Connect(function()
	closeLeakedZones()
	local now = os.clock()
	if config.BuiltinPlots and now - lastBuiltin >= BUILTIN_PLOT_INTERVAL then
		lastBuiltin = now
		sampleBuiltins()
	end
	local since = now - lastFlush
	if since >= config.FlushInterval or (off + relayBytes >= config.FlushBytes and since >= EARLY_FLUSH_INTERVAL) then
		lastFlush = now
		flush(false)
	end
end)

---------------------------------------------------------------- API

local function configure(options: Options)
	assert(type(options) == "table", "Tracy.Configure expects a table")
	if options.Url ~= nil then
		assert(type(options.Url) == "string", "Url must be a string")
		config.Url = options.Url
		resetConnection()
	end
	if options.FlushInterval ~= nil then
		assert(type(options.FlushInterval) == "number", "FlushInterval must be a number")
		config.FlushInterval = math.max(options.FlushInterval, MIN_FLUSH_INTERVAL)
	end
	if options.FlushBytes ~= nil then
		assert(type(options.FlushBytes) == "number", "FlushBytes must be a number")
		config.FlushBytes = math.max(options.FlushBytes, 16 * 1024)
	end
	if options.RetryInterval ~= nil then
		assert(type(options.RetryInterval) == "number", "RetryInterval must be a number")
		config.RetryInterval = math.max(options.RetryInterval, 0.5)
	end
	if options.MaxBufferSize ~= nil then
		assert(type(options.MaxBufferSize) == "number", "MaxBufferSize must be a number")
		config.MaxBufferSize = math.max(options.MaxBufferSize, 64 * 1024)
	end
	if options.BuiltinPlots ~= nil then
		config.BuiltinPlots = options.BuiltinPlots == true
	end
end

local wrap = makeWrap(zoneBegin, zoneEnd)

local api: Tracy = {
	VERSION = VERSION,
	ZoneBegin = zoneBegin,
	ZoneEnd = zoneEnd,
	Wrap = wrap :: any,
	Instrument = makeInstrument(wrap) :: any,
	FrameMark = frameMark,
	Plot = plot,
	ConfigurePlot = configurePlot,
	Message = message,
	Configure = configure,
	IsActive = function()
		return true
	end,
	IsConnected = function()
		return connected
	end,
	GetStats = function(): Stats
		return {
			BatchesSent = statSent,
			BatchesFailed = statFailed,
			BatchesDropped = statDropped,
			BytesSent = statBytes,
			Flushes = statFlushes,
			FlushSeconds = statFlushSeconds,
			RoundTripSeconds = statRtt,
			MaxRoundTripSeconds = statRttMax,
			LastRoundTripSeconds = statRttLast,
			PendingBytes = off - HEADER_SIZE,
			BufferBytes = cap,
			Names = nextId - 1,
			RelayedBatches = statRelayed,
			Clients = statClients,
			ClockOffset = clockOffset,
			ZonesLeaked = statLeaked,
			StrayEnds = statStray,
		}
	end,
}

return table.freeze(api)
