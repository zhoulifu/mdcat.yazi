local M = {}

local MAX_CACHE_BYTES = 1024 * 1024
local APPROX_LINE_OVERHEAD = 32

-- Keep a single rendered document in memory and fall back to streaming for larger files.
local cache = nil

local function as_int(value)
	return math.max(0, math.floor(tonumber(value) or 0))
end

local function file_revision(file)
	local mtime = 0
	local size = 0

	if file and file.cha then
		mtime = math.floor(file.cha.mtime or 0)
	end

	local ok, value = pcall(function()
		return file:size()
	end)
	if ok and value then
		size = value
	end

	return {
		url = file.url,
		mtime = mtime,
		size = size,
	}
end

local function max_skip(total_lines, height)
	return math.max(0, total_lines - height)
end

local function cache_matches(revision, width)
	return cache
		and cache.url == revision.url
		and cache.width == width
		and cache.mtime == revision.mtime
		and cache.size == revision.size
		and cache.lines
		and cache.total_lines ~= nil
end

local function emit_peek(job, skip, upper_bound)
	local args = {
		tostring(skip),
		only_if = job.file.url,
	}
	if upper_bound ~= nil then
		args.upper_bound = upper_bound
	end
	ya.emit("peek", args)
end

local function render_text(job, text)
	ya.preview_widget(job, { ui.Text.parse(text):area(job.area) })
end

local function render_slice(job, lines, skip)
	local height = as_int(job.area.h)
	local page = {}
	local stop = math.min(#lines, skip + height)

	for i = skip + 1, stop do
		page[#page + 1] = lines[i]
	end

	render_text(job, table.concat(page))
end

local function spawn_mdcat(job)
	return Command("mdcat")
		:arg({
			"--ansi",
			"--columns",
			tostring(job.area.w),
			tostring(job.file.url),
		})
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()
end

function M:peek(job)
	local width = as_int(job.area.w)
	local height = as_int(job.area.h)
	local skip = as_int(job.skip)
	local revision = file_revision(job.file)

	if cache_matches(revision, width) then
		cache.last_height = height

		local bounded = math.min(skip, max_skip(cache.total_lines, height))
		if skip > 0 and bounded ~= skip then
			emit_peek(job, bounded, "")
		else
			render_slice(job, cache.lines, bounded)
		end
		return
	end

	cache = nil

	local child = spawn_mdcat(job)
	local count = 0
	local cached_lines = {}
	local page_lines = {}
	local cache_bytes = 0
	local cacheable = true
	local page_limit = skip + height

	repeat
		local line, event = child:read_line()
		if event ~= 0 then
			break
		end

		count = count + 1

		if cacheable then
			cache_bytes = cache_bytes + #line + APPROX_LINE_OVERHEAD
			if cache_bytes <= MAX_CACHE_BYTES then
				cached_lines[#cached_lines + 1] = line
			else
				cached_lines = nil
				cacheable = false
			end
		end

		if count > skip and #page_lines < height then
			page_lines[#page_lines + 1] = line
		end
	until (not cacheable) and count >= page_limit

	child:start_kill()

	if cacheable then
		cache = {
			url = revision.url,
			width = width,
			mtime = revision.mtime,
			size = revision.size,
			lines = cached_lines,
			total_lines = count,
			last_height = height,
		}

		local bounded = math.min(skip, max_skip(count, height))
		if skip > 0 and bounded ~= skip then
			emit_peek(job, bounded, "")
		else
			render_slice(job, cached_lines, bounded)
		end
		return
	end

	if skip > 0 and count < page_limit then
		emit_peek(job, math.max(0, count - height), "")
	else
		render_text(job, table.concat(page_lines))
	end
end

function M:seek(job)
	local h = cx.active.current.hovered
	if not (h and h.url == job.file.url) then
		return
	end

	local target = math.max(0, as_int(cx.active.preview.skip) + (tonumber(job.units) or 0))
	if cache and cache.url == job.file.url and cache.total_lines ~= nil then
		target = math.min(target, max_skip(cache.total_lines, cache.last_height or 0))
	end

	emit_peek(job, target)
end

return M
