-- sui_text.lua — Simple UI
-- Text helpers shared by every surface that shows metadata or user text.
-- Lengths are counted in Unicode codepoints, so multi-byte scripts are never
-- split mid-character.
--
-- Public API
-- ----------
--   Text.cut(s, max_chars)           -> the first `max_chars` characters of `s`
--   Text.truncate(s, max_chars)      -> `s` limited to `max_chars` characters,
--       ending in an ellipsis when it was cut
--   Text.truncateStart(s, max_chars) -> same, keeping the end of `s` and
--       starting with the ellipsis (paths, identifiers)
--   Text.firstLine(s)                -> first non-blank line of a
--       newline-separated field, trimmed; nil when there is none
--   Text.formatAuthors(s)            -> nil when the field holds no name, the
--       name when it holds one, "Name et al." when it holds several
--   Text.formatDuration(secs)        -> time with decimals combined: "Xs" / "Xm" / "Xh"
--   Text.formatDurationInteger(secs) -> time in whole split units: "Xh Ym" / "Xh" / "Ym"
--
-- Nil and empty strings are returned unchanged by the length helpers.

local util = require("util")
local _    = require("infra/sui_i18n").translate

local Text = {}

local ELLIPSIS = "…"

-- Byte length of the UTF-8 sequence introduced by `lead_byte`.
local function sequenceLength(lead_byte)
    return lead_byte >= 240 and 4 or lead_byte >= 224 and 3 or lead_byte >= 192 and 2 or 1
end

-- UTF-8 continuation bytes (10xxxxxx) never start a character.
local function isContinuation(byte)
    return byte >= 128 and byte < 192
end

-- Byte offset of the end of the first `count` characters of `s`.
local function prefixEnd(s, count)
    local i = 1
    while i <= #s and count > 0 do
        i     = i + sequenceLength(s:byte(i))
        count = count - 1
    end
    return i - 1
end

-- Byte offset where the last `count` characters of `s` start.
local function suffixStart(s, count)
    local i = #s + 1
    while i > 1 and count > 0 do
        i = i - 1
        while i > 1 and isContinuation(s:byte(i)) do i = i - 1 end
        count = count - 1
    end
    return i
end

function Text.cut(s, max_chars)
    if not s or s == "" then return s end
    return s:sub(1, prefixEnd(s, max_chars))
end

function Text.truncate(s, max_chars)
    if not s or s == "" then return s end
    max_chars = math.max(1, max_chars)
    local stop = prefixEnd(s, max_chars)
    if stop >= #s then return s end
    return s:sub(1, prefixEnd(s, max_chars - 1)) .. ELLIPSIS
end

function Text.truncateStart(s, max_chars)
    if not s or s == "" then return s end
    max_chars = math.max(1, max_chars)
    local start = suffixStart(s, max_chars)
    if start <= 1 then return s end
    return ELLIPSIS .. s:sub(suffixStart(s, max_chars - 1))
end

-- Iterator over the trimmed, non-blank lines of `s`.
local function eachLine(s)
    local nextRaw = (s or ""):gmatch("[^\n]+")
    return function()
        for raw in nextRaw do
            local line = util.trim(raw)
            if line ~= "" then return line end
        end
    end
end

function Text.firstLine(s)
    return eachLine(s)()
end

function Text.formatAuthors(s)
    local nextName = eachLine(s)
    local first = nextName()
    if first and nextName() then return first .. _(" et al.") end
    return first
end

-- One decimal when it carries information, none when it rounds to a whole number.
local function oneDecimal(value, whole_fmt, frac_fmt)
    local rounded = math.floor(value * 10 + 0.5) / 10
    if rounded == math.floor(rounded) then return string.format(whole_fmt, rounded) end
    return string.format(frac_fmt, rounded)
end

-- Reading time in single-unit form: seconds up to a minute, whole minutes up
-- to an hour, then hours. Only one unit is shown, so long totals stay short
-- in any locale.
function Text.formatDuration(secs)
    if secs ~= secs then secs = 0 end -- NaN never equals itself, so this catches it
    secs = math.max(0, math.floor(secs or 0))
    if secs <= 60   then return string.format(_("%ds"), secs) end
    if secs <= 3600 then return string.format(_("%dm"), math.floor(secs / 60)) end
    return            oneDecimal(secs / 3600, _("%dh"), _("%.1fh"))
end

-- Same reading time kept whole in hours and minutes: surfaces with room for
-- two units read better than the single-unit form above.
function Text.formatDurationInteger(secs)
    if secs ~= secs then secs = 0 end -- NaN never equals itself, so this catches it
    secs = math.floor(secs or 0)
    if secs <= 0 then return string.format(_("%dm"), 0) end
    local hours   = math.floor(secs / 3600)
    local minutes = math.floor((secs % 3600) / 60)
    if hours > 0 and minutes > 0 then return string.format(_("%dh %dm"), hours, minutes)
    elseif hours > 0             then return string.format(_("%dh"), hours)
    else                              return string.format(_("%dm"), minutes) end
end

return Text
