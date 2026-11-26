--!strict

--[[
	Tracy.Capture: MicroProfiler captures from live games, for Tracy.

	When a server frame takes too long, or when you ask, this grabs the last few
	dozen frames of Roblox's MicroProfiler and sends them out of the game. A capture
	holds the engine's work (physics, replication, scripts, GC) and your Tracy
	zones, which Tracy mirrors into the MicroProfiler in live games. Convert
	captures to .tracy files with tracy-roblox-bridge --convert (docs/GUIDE.md,
	"In live games").

	Needs LibMP (https://github.com/Roblox/libmp, MIT), Roblox's MicroProfiler API,
	as a ModuleScript in your game. Server only.

	    local Capture = require(ReplicatedStorage.Tracy.Capture)
	    Capture.Start({
	        LibMP = require(ServerStorage.LibMP),
	        Sink = Capture.DataStoreSink("TracyCaptures"),
	        HitchMs = 100, -- capture when a frame takes 100 ms or more
	    })

	    Capture.Now("boss fight started") -- or capture on demand

	Sinks:
	  * DataStoreSink(name): stores captures in a DataStore. Nothing to host; fetch
	    them with tools/fetch_captures.py and an Open Cloud API key.
	  * HttpSink(url, options): POSTs each capture to a URL you run.
	  * BridgeSink(): POSTs to tracy-roblox-bridge on this machine (Studio).
	  * Or any function(info, data) that errors on failure.

	Costs: the MicroProfiler keeps its frame history in memory (MemoryMB, default
	256 MB), which is why SampleRate exists. Taking a capture blocks the frame while
	it's compressed, ~15-50 ms for 64 busy frames; sending happens in the background.
	If converted captures have few or no frames, the history overflowed: raise
	MemoryMB or lower Frames.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

export type CaptureInfo = {
	-- Unique id, also the DataStore key: "20261125T174902Z-1a2b3c4d".
	Id: string,
	-- "hitch" for automatic captures, or the reason given to Now().
	Reason: string,
	-- Unix time when the capture was taken.
	Time: number,
	JobId: string,
	PlaceId: number,
	PlaceVersion: number,
	-- The frame time that triggered a hitch capture, in ms.
	FrameMs: number?,
	-- Complete frames in the capture (-1 if they couldn't be counted), bytes, how
	-- long taking it blocked the frame, and tries it took (see MemoryMB).
	Frames: number,
	Bytes: number,
	CaptureMs: number,
	Attempts: number,
}

export type Sink = (info: CaptureInfo, data: buffer) -> ()

export type Options = {
	-- The LibMP module (require it and pass it in).
	LibMP: any,
	-- Where captures go. Defaults to BridgeSink() in Studio; required in live games.
	Sink: Sink?,
	-- Capture automatically when a frame takes at least this long. 0 = only Now().
	HitchMs: number?,
	-- Frames of history the MicroProfiler keeps, and so the frames per capture (default 64).
	Frames: number?,
	-- Seconds between automatic captures (default 300).
	Cooldown: number?,
	-- Captures per server, automatic and Now() together (default 10).
	MaxCaptures: number?,
	-- Fraction of servers that turn the MicroProfiler on at all (default 1).
	SampleRate: number?,
	-- Ignore hitches for this many seconds after Start (default 15): servers
	-- hitch while they load.
	Warmup: number?,
	-- Memory budget for the MicroProfiler's history, in MB (default 256). Too small,
	-- and busy frames are overwritten before they're captured.
	MemoryMB: number?,
}

export type CaptureStats = {
	Running: boolean,
	Captures: number,
	Sent: number,
	Failed: number,
	LastId: string?,
	LastError: string?,
}

local DEFAULT_BRIDGE_URL = "http://127.0.0.1:8080/capture"

-- DataStore values hold at most 4 MB of JSON. Base64 makes a part 4/3 larger.
local DATASTORE_PART_BYTES = 2_400_000
-- Encode in slices so a big capture doesn't stall a frame.
local ENCODE_SLICE_BYTES = 3 * 64 * 1024

local Capture = {}

local libmp: any = nil
local sink: Sink? = nil
local options = {
	HitchMs = 100,
	Frames = 64,
	Cooldown = 300,
	MaxCaptures = 10,
	SampleRate = 1,
	Warmup = 15,
	MemoryMB = 256,
}
local running = false
local heartbeat: RBXScriptConnection? = nil
local startedAt = 0
local lastAuto = -math.huge
local statCaptures = 0
local statSent = 0
local statFailed = 0
local lastId: string? = nil
local lastError: string? = nil
local warnedSend = false

---------------------------------------------------------------- base64

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64Table = buffer.create(64)
for i = 1, 64 do
	buffer.writeu8(b64Table, i - 1, string.byte(B64, i))
end

local function base64Slice(data: buffer, from: number, count: number): string
	local out = buffer.create(math.ceil(count / 3) * 4)
	local o = 0
	local i = from
	local whole = from + count - count % 3
	while i < whole do
		local n = bit32.bor(
			bit32.lshift(buffer.readu8(data, i), 16),
			bit32.lshift(buffer.readu8(data, i + 1), 8),
			buffer.readu8(data, i + 2)
		)
		buffer.writeu8(out, o, buffer.readu8(b64Table, bit32.rshift(n, 18)))
		buffer.writeu8(out, o + 1, buffer.readu8(b64Table, bit32.band(bit32.rshift(n, 12), 63)))
		buffer.writeu8(out, o + 2, buffer.readu8(b64Table, bit32.band(bit32.rshift(n, 6), 63)))
		buffer.writeu8(out, o + 3, buffer.readu8(b64Table, bit32.band(n, 63)))
		i += 3
		o += 4
	end
	local rest = from + count - whole
	if rest > 0 then
		local n = bit32.lshift(buffer.readu8(data, i), 16)
		if rest == 2 then
			n = bit32.bor(n, bit32.lshift(buffer.readu8(data, i + 1), 8))
		end
		buffer.writeu8(out, o, buffer.readu8(b64Table, bit32.rshift(n, 18)))
		buffer.writeu8(out, o + 1, buffer.readu8(b64Table, bit32.band(bit32.rshift(n, 12), 63)))
		buffer.writeu8(
			out,
			o + 2,
			if rest == 2 then buffer.readu8(b64Table, bit32.band(bit32.rshift(n, 6), 63)) else 61
		) -- "="
		buffer.writeu8(out, o + 3, 61)
	end
	return buffer.tostring(out)
end

-- Base64 of data[from, from + count), yielding between slices.
local function base64(data: buffer, from: number, count: number): string
	local pieces = {}
	local done = 0
	while done < count do
		local n = math.min(ENCODE_SLICE_BYTES, count - done) -- a multiple of 3 until the last slice
		table.insert(pieces, base64Slice(data, from + done, n))
		done += n
		if done < count then
			task.wait()
		end
	end
	return table.concat(pieces)
end

Capture._base64 = base64 -- for tests

---------------------------------------------------------------- sinks

-- Stores each capture in a DataStore: "<id>/1".."<id>/N" hold base64 parts, then
-- "<id>" holds the capture info (written last, so it marks a complete capture).
-- Captures count against the experience's DataStore storage and request budget;
-- tools/fetch_captures.py --delete removes them once downloaded.
-- Pass a DataStore name, or a DataStore you got yourself (to use a scope).
function Capture.DataStoreSink(nameOrStore: string | DataStore): Sink
	local name = if type(nameOrStore) == "string" then nameOrStore else tostring((nameOrStore :: any).Name)
	assert(name ~= "", "DataStoreSink needs a DataStore name")
	return function(info: CaptureInfo, data: buffer)
		local store: any = if type(nameOrStore) == "string" then DataStoreService:GetDataStore(name) else nameOrStore
		local size = buffer.len(data)
		local parts = math.max(1, math.ceil(size / DATASTORE_PART_BYTES))
		local function put(key: string, value: string)
			local lastErr = nil
			for attempt = 1, 4 do
				local ok, err = pcall(store.SetAsync, store, key, value)
				if ok then
					return
				end
				lastErr = err
				task.wait(2 ^ attempt)
			end
			error(`DataStore {name}: couldn't write {key}: {lastErr}`)
		end
		for part = 1, parts do
			local from = (part - 1) * DATASTORE_PART_BYTES
			put(`{info.Id}/{part}`, base64(data, from, math.min(DATASTORE_PART_BYTES, size - from)))
		end
		local meta = table.clone(info) :: any
		meta.Format = "libmp-compressed"
		meta.Parts = parts
		meta.Version = 1
		put(info.Id, HttpService:JSONEncode(meta))
	end
end

export type HttpSinkOptions = {
	-- Extra request headers.
	Headers: { [string]: string }?,
	-- Name of a Roblox secret (Creator Hub > Secrets) sent as "Authorization: Bearer <secret>".
	Secret: string?,
}

-- POSTs each capture as application/octet-stream, with the capture info (JSON, then
-- base64) in an X-Tracy-Capture header.
function Capture.HttpSink(url: string, sinkOptions: HttpSinkOptions?): Sink
	assert(type(url) == "string" and url ~= "", "HttpSink needs a URL")
	local extra = if sinkOptions then sinkOptions.Headers else nil
	local secretName = if sinkOptions then sinkOptions.Secret else nil
	return function(info: CaptureInfo, data: buffer)
		-- HttpService refuses "{" in header values, so the info JSON travels as base64.
		local infoJson = HttpService:JSONEncode(info)
		local headers: { [string]: any } = {
			["Content-Type"] = "application/octet-stream",
			["X-Tracy-Capture"] = base64Slice(buffer.fromstring(infoJson), 0, #infoJson),
		}
		if extra then
			for key, value in extra do
				headers[key] = value
			end
		end
		if secretName then
			headers["Authorization"] = HttpService:GetSecret(secretName):AddPrefix("Bearer ")
		end
		local result = HttpService:RequestAsync({
			Url = url,
			Method = "POST",
			Headers = headers,
			Body = buffer.tostring(data),
		})
		if not result.Success then
			error(`HTTP {result.StatusCode} {result.StatusMessage}`)
		end
	end
end

-- Sends captures to tracy-roblox-bridge on this machine, which saves them (and
-- converts them to .tracy when it can). Studio only: live servers can't reach it.
function Capture.BridgeSink(url: string?): Sink
	return Capture.HttpSink(url or DEFAULT_BRIDGE_URL)
end

---------------------------------------------------------------- capturing

local function newId(now: number): string
	local hex = string.sub(string.gsub(HttpService:GenerateGUID(false), "-", ""), 1, 8)
	return (os.date("!%Y%m%dT%H%M%SZ", now) :: string) .. "-" .. string.lower(hex)
end

-- One capture attempt: the data, its complete frames, and how long it blocked.
local function captureOnce(): (buffer?, number, number, string?)
	local t0 = os.clock()
	local ok, data = pcall(function()
		-- Everything the MicroProfiler holds (SetFrameLimit bounds it to Frames). A
		-- nonzero MaxFrameCount can return fewer frames than asked.
		return libmp.Control:CaptureToBufferSync({
			MaxFrameCount = 0,
			ContainerFormat = libmp.Enums.ContainerFormat.Compressed,
		})
	end)
	local ms = (os.clock() - t0) * 1000
	if not ok or typeof(data) ~= "buffer" then
		return nil, 0, ms, if ok then "LibMP returned no data" else tostring(data)
	end
	-- Count the complete frames; an overflowed history (see MemoryMB) can leave none.
	local counted, frames = pcall(function()
		local session = libmp.Session.OpenFromBuffer(data)
		if session == nil then
			return 0
		end
		local first, last = session:GetFrameIdMin(), session:GetFrameIdMax()
		local n = if session:FetchFrameDesc(first) then last - first + 1 else 0
		session:Dispose()
		return n
	end)
	return data, if counted then frames else -1, ms, nil
end

local function send(info: CaptureInfo, data: buffer)
	local ok, err = pcall(sink :: Sink, info, data)
	if ok then
		statSent += 1
		return
	end
	statFailed += 1
	lastError = tostring(err)
	if not warnedSend then
		warnedSend = true
		warn(`[Tracy.Capture] couldn't send capture {info.Id}: {err}`)
	end
end

local CAPTURE_ATTEMPTS = 4
local RETRY_DELAY = 0.5

local function take(reason: string, frameMs: number?): (boolean, string)
	if not running then
		return false, "Capture.Start hasn't run (or this server was sampled out)"
	end
	if statCaptures >= options.MaxCaptures then
		return false, `MaxCaptures ({options.MaxCaptures}) reached`
	end
	statCaptures += 1
	local now = os.time()
	local id = newId(now)
	lastId = id
	local function finish(data: buffer, frames: number, ms: number, attempts: number)
		send({
			Id = id,
			Reason = reason,
			Time = now,
			JobId = game.JobId,
			PlaceId = game.PlaceId,
			PlaceVersion = game.PlaceVersion,
			FrameMs = frameMs,
			Frames = frames,
			Bytes = buffer.len(data),
			CaptureMs = ms,
			Attempts = attempts,
		} :: any, data)
	end
	local function retry()
		local err: string? = nil
		for attempt = 2, CAPTURE_ATTEMPTS do
			task.wait(RETRY_DELAY)
			local data, frames, ms, captureErr = captureOnce()
			if data and frames ~= 0 then
				finish(data, frames, ms, attempt)
				return
			end
			err = captureErr
		end
		statFailed += 1
		lastError = err
			or `no complete frames after {CAPTURE_ATTEMPTS} tries: the MicroProfiler's history overflowed; raise MemoryMB or lower Frames`
		if not warnedSend then
			warnedSend = true
			warn(`[Tracy.Capture] capture {id} failed: {lastError}`)
		end
	end
	local function attempt()
		local data, frames, ms = captureOnce()
		if data and frames ~= 0 then
			task.spawn(finish, data, frames, ms, 1)
		else
			-- No complete frames (or an error): try again shortly, off this frame.
			task.spawn(retry)
		end
	end
	-- Until Warmup ends the history is still filling and captures come back hollow.
	local warming = options.Warmup - (os.clock() - startedAt)
	if warming > 0 then
		task.delay(warming, attempt)
	else
		attempt()
	end
	return true, id
end

-- Takes a capture now (the cooldown doesn't apply; MaxCaptures does). Within
-- Warmup seconds of Start, it waits until then. Returns true and the capture id,
-- or false and why not. Sending happens in the background.
function Capture.Now(reason: string?): (boolean, string)
	return take(if type(reason) == "string" and reason ~= "" then reason else "manual", nil)
end

-- Turns the MicroProfiler on and starts watching for hitches. Returns false and a
-- reason when this server won't capture (sampled out, or no MicroProfiler access).
function Capture.Start(startOptions: Options): (boolean, string?)
	assert(RunService:IsServer(), "Tracy.Capture runs on the server")
	assert(type(startOptions) == "table", "Capture.Start expects an options table")
	assert(type(startOptions.LibMP) == "table", "Capture.Start needs LibMP: pass require(path.to.LibMP)")
	if running then
		return true
	end
	for key, value in startOptions :: any do
		if options[key] ~= nil then
			assert(type(value) == "number" and value >= 0, `{key} must be a non-negative number`)
			options[key] = value
		end
	end
	options.Frames = math.max(1, math.floor(options.Frames))
	sink = startOptions.Sink
	if sink == nil then
		if not RunService:IsStudio() then
			error("Capture.Start needs a Sink in live games (DataStoreSink or HttpSink)", 2)
		end
		sink = Capture.BridgeSink()
	end
	if Random.new():NextNumber() >= options.SampleRate then
		return false, "sampled out (SampleRate)"
	end

	libmp = startOptions.LibMP
	local control = libmp.Control
	if not control:IsBackendAccessible() then
		return false, "the MicroProfiler isn't accessible from this server"
	end
	if not control:IsBackendVersionCompatible() then
		return false, "this LibMP version doesn't match the engine's MicroProfiler; update LibMP"
	end
	control:SetMemTargetMB(options.MemoryMB)
	control:SetFrameLimit(options.Frames)
	control:EnableProfiler(true)
	control:EnableCapture(true)

	running = true
	startedAt = os.clock()
	if options.HitchMs > 0 then
		heartbeat = RunService.Heartbeat:Connect(function(dt)
			local frameMs = dt * 1000
			if frameMs < options.HitchMs then
				return
			end
			local now = os.clock()
			if now - startedAt < options.Warmup or now - lastAuto < options.Cooldown then
				return
			end
			lastAuto = now
			take("hitch", frameMs)
		end)
	end
	return true
end

-- Stops watching for hitches and turns capture off. Captures already taken still send.
function Capture.Stop()
	if not running then
		return
	end
	running = false
	if heartbeat then
		heartbeat:Disconnect()
		heartbeat = nil
	end
	pcall(function()
		libmp.Control:EnableCapture(false)
	end)
end

function Capture.GetStats(): CaptureStats
	return {
		Running = running,
		Captures = statCaptures,
		Sent = statSent,
		Failed = statFailed,
		LastId = lastId,
		LastError = lastError,
	}
end

return Capture
