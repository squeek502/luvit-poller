local Emitter = require("core").Emitter
local http = require("https")
local parse_url = require("url").parse
local timer = require("timer")

local function secs_to_milli(secs)
	if secs == nil then secs = 0 end
	if type(secs) ~= number then secs = tonumber(secs) end 
	return secs * 1000
end

local function table_fallback(settings, defaults)
	local merged = {}
	for key,value in pairs(defaults) do
		if settings[key] == nil then
			merged[key] = value
		end
	end
	return merged
end

local Poller = Emitter:extend()

function Poller:initialize(url, interval, headers, auto_start)
	self.url = url
	self.interval = interval or secs_to_milli(60)
	self.headers = headers or {}

	self.parsed_url = parse_url(url)
	self.userinterval = interval
	self.task = nil

	self.etag = nil
	self.ratelimit_limit = nil	-- Request limit per x (differs by API)
	self.ratelimit_remaining = nil	-- The number of requests left for the time window
	self.ratelimit_reset = nil	-- The remaining window before the rate limit resets in UTC epoch seconds

	self:on("intervalchange", function()
		if self:isactive() then
			self:reschedule()
		end
	end)

	if auto_start then
		self:start()
	end
end

function Poller:isactive()
	return self.task ~= nil
end

function Poller:stop()
	if self:isactive() then
		timer.clearTimer(self.task)
		self.task = nil
	end
end

function Poller:reschedule(interval)
	self:stop()
	if interval then
		self.userinterval = interval
		self.interval = interval
	end
	self.task = timer.setInterval(self.interval, function() self:_poll() end)
end

function Poller:start(interval)
	self:_poll()
	self:reschedule(interval)
end

function Poller:_canpoll()
	return self.ratelimit_remaining == nil or self.ratelimit_remaining > 0
end

function Poller:_poll()
	if not self:_canpoll() then
		return
	end

	p("polling "..self.url)

	local default_request_headers = {
		["User-Agent"] = "luvit-poller",
		["If-None-Match"] = self.etag,
		["Accept"] = "*/*"
	}
	local request_headers = table_fallback(self.headers, default_request_headers)
	local request = http.request(
	{
		protocol = self.parsed_url.protocol or "http",
		host = self.parsed_url.hostname,
		port = self.parsed_url.port or 80,
		path = self.parsed_url.pathname or "/",
		headers = request_headers
	}, 
	function (response)
		local data = ""
		response:on("data", function (chunk)
			data = data .. chunk
		end)
		response:on("error", function(err)
			self:emit("error", "Error while receiving a response: " .. tostring(err), err)
		end)
		response:on("end", function ()
			self:_conformtoheader(response.headers)
			if response.statusCode == 304 then -- "Not Modified"
				self:emit("notmodified", "Not Modified", response)
			else
				self:emit("data", data, response)
			end
			response:destroy()
		end)
	end)

	request:on("error", function(err)
		self:emit("Error while sending a request: " .. tostring(err), err)
	end)

	request:done()
end

function Poller:_getratelimitedinterval()
	if self.ratelimit_reset and self.ratelimit_remaining then
		local time_left = self.ratelimit_reset - require("os").time()
		if time_left > 0 then
			return secs_to_milli(time_left/(self.ratelimit_remaining+1))
		end
	end
	return 0
end

function Poller:_conformtoheader(header)
	-- TODO: respect "Retry-After"
	self.ratelimit_limit = tonumber(header["x-ratelimit-limit"] or header["x-rate-limit-limit"] or self.ratelimit_limit)
	self.ratelimit_remaining = tonumber(header["x-ratelimit-remaining"] or header["x-rate-limit-remaining"] or self.ratelimit_remaining)
	self.ratelimit_reset = tonumber(header["x-ratelimit-reset"] or header["x-rate-limit-reset"] or self.ratelimit_reset)
	self.etag = header.etag or self.etag
	local poll_interval = secs_to_milli(header["x-poll-interval"])
	local rate_interval = self:_getratelimitedinterval()
	local min_interval = math.max(poll_interval, rate_interval)
	local old_interval = self.interval
	self.interval = math.max(self.interval, min_interval)
	if old_interval ~= self.interval then
		self:emit("intervalchange", old_interval, self.interval)
	end
end

return Poller