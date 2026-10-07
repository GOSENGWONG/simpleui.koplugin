-- sui_tab_strip.lua — Simple UI
-- Compact horizontal tab strip: one text cell per tab with an underline on the
-- active one. The strip can also show a single static label in place of the
-- tabs (used when the tabs do not apply to the current view).
--
-- Usage:
--   local strip = TabStrip.new{
--       width     = px,
--       height    = px,
--       face      = Font face used for every label,
--       tabs      = { { id = "a", label = "A" }, ... },  -- optional; omit for a label-only strip
--       on_select = function(id) end,
--       fgcolor   = optional color (defaults to the primary text color),
--   }
--   strip:setActive(id)    -- highlight a tab; returns true when the view changed
--   strip:setLabel(text)   -- show a static label; nil restores the tabs
--   strip:setSpan(x, w)    -- move/resize the strip; the next setActive/setLabel
--                          -- call rebuilds the content for the new width
--
-- The first tab has no leading padding, so its text starts exactly at the
-- strip's left edge. Content swaps never change the strip's geometry; only
-- setSpan does.

local Geom            = require("ui/geometry")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local HorizontalSpan   = require("ui/widget/horizontalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local OverlapGroup    = require("ui/widget/overlapgroup")
local LineWidget      = require("ui/widget/linewidget")
local TextWidget      = require("ui/widget/textwidget")
local Screen          = require("device").screen

local SUIStyle = require("features/sui_style")

local TabStrip = WidgetContainer:extend{
    width     = nil,
    height    = nil,
    face      = nil,
    tabs      = nil,
    on_select = nil,
    fgcolor   = nil,
    _view_key = nil,
}

-- Tap container shared with the other SimpleUI tab/cell renderers.
local function _tapContainer(content, w, h, id, on_tap)
    local QARenderer = require("engines/sui_quickactions_render")
    return QARenderer.buildTapContainer(content, w, h, id,
        { on_tap_fn = on_tap, tap_event_name = "TapSUITab" }, "TapSUITab")
end

-- Builds the label widget for one tab. The widest of the regular and bold
-- variants fixes the cell width, so selecting a tab never moves its neighbours.
local function _measureLabel(self, label, max_w)
    local fg      = self.fgcolor
    local regular = TextWidget:new{ text = label, face = self.face, fgcolor = fg, max_width = max_w, padding = 0 }
    local bold    = TextWidget:new{ text = label, face = self.face, fgcolor = fg, max_width = max_w, padding = 0, bold = true }
    return regular, bold, math.max(regular:getWidth(), bold:getWidth())
end

function TabStrip:_buildTabs()
    local n = #self.tabs
    local nominal_pad = Screen:scaleBySize(14)
    local max_text_w  = math.floor(self.width / n)

    local entries, text_total = {}, 0
    for _, tab in ipairs(self.tabs) do
        local regular, bold, w = _measureLabel(self, tab.label, max_text_w)
        entries[#entries + 1] = { tab = tab, regular = regular, bold = bold, w = w }
        text_total = text_total + w
    end

    -- Shrink the horizontal padding evenly when the labels do not fit.
    local pad = math.min(nominal_pad, math.max(0, math.floor((self.width - text_total) / (2 * n))))
    local underline_h = Screen:scaleBySize(2)

    local row = HorizontalGroup:new{ allow_mirroring = false }
    for i, e in ipairs(entries) do
        local active = e.tab.id == self._active
        local text   = active and e.bold or e.regular
        local unused = active and e.regular or e.bold
        unused:free()

        local lead_pad = i == 1 and 0 or pad
        local cell_w   = lead_pad + e.w + pad
        local cell_dim = Geom:new{ w = cell_w, h = self.height }
        local cell = OverlapGroup:new{
            allow_mirroring = false,
            dimen           = cell_dim,
            LeftContainer:new{
                dimen = cell_dim,
                HorizontalGroup:new{ HorizontalSpan:new{ width = lead_pad }, text },
            },
        }
        if active then
            cell[#cell + 1] = LineWidget:new{
                dimen          = Geom:new{ w = e.w, h = underline_h },
                background     = self.fgcolor,
                overlap_offset = { lead_pad, self.height - underline_h },
            }
        end
        row[#row + 1] = _tapContainer(cell, cell_w, self.height, e.tab.id, self.on_select)
    end
    return row
end

function TabStrip:_buildLabel(text)
    return LeftContainer:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        TextWidget:new{
            text      = text,
            face      = self.face,
            fgcolor   = self.fgcolor,
            bold      = true,
            max_width = self.width,
            padding   = 0,
        },
    }
end

-- Replaces the content when the requested view differs from the current one.
function TabStrip:_render(view_key, build)
    if self._view_key == view_key then return false end
    self._view_key = view_key
    if self[1] then self[1]:free() end
    self[1] = build()
    return true
end

function TabStrip:setSpan(x, width)
    self.overlap_offset = { x, 0 }
    if width == self.width then return end
    self.width      = width
    self.dimen.w    = width
    self._view_key  = nil
end

function TabStrip:setActive(id)
    self._active = id
    self._label  = nil
    return self:_render("tab:" .. tostring(id), function() return self:_buildTabs() end)
end

function TabStrip:setLabel(text)
    if not text then return self:setActive(self._active) end
    self._label = text
    return self:_render("label:" .. text, function() return self:_buildLabel(text) end)
end

local M = {}

function M.new(opts)
    local strip = TabStrip:new{
        width     = opts.width,
        height    = opts.height,
        face      = opts.face,
        tabs      = opts.tabs or {},
        on_select = opts.on_select,
        fgcolor   = opts.fgcolor or SUIStyle.COLOR.text_primary,
        dimen     = Geom:new{ w = opts.width, h = opts.height },
    }
    if strip.tabs[1] then strip:setActive(strip.tabs[1].id) end
    return strip
end

return M
