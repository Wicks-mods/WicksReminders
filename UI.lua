-- Wick's Reminders
-- UI.lua: the window. A list of reminders, and the editor that makes them.
--
-- Everything is a click: the three New buttons, a tick to switch one on or
-- off, the cross to delete it, a click on the row to change it. In the
-- editor a length of time is a row of presets with a box for anything
-- else, a time of day is two steppers, and days of the week are chips.
-- The only thing that has to be typed is what to remind you of.

local ADDON, ns = ...
if not WickCore then return end

local Core, Chrome = WickCore, WickCore.Chrome
local C = Chrome.Colors

local UI = { offset = 0 }
ns.UI = UI

local WIDTH, HEIGHT = 470, 452
local ROW_W = WIDTH - 16   -- set again at build, for the look in use

-- How wide the window's content is: Chrome:NewPanel insets it 8px a side,
-- and 14 and 10 in the Classic look, inside the game's thicker frame.
function UI.ContentWidth(f)
    return WIDTH - ((f and f.wickGame) and 24 or 16)
end
local ROW_H, ROW_GAP, ROWS = 38, 4, 8
local WARN = { 0.878, 0.294, 0.294, 1 }   -- the suite's refusal red, for a delete about to happen

-- ============================================================
-- Small helpers
-- ============================================================

-- Set a colour and keep it following the theme.
local function Ink(fs, c, a)
    fs:SetTextColor(c[1], c[2], c[3], a or c[4] or 1)
    Chrome:Register(fs, c, "text", a)
end

local function Paint(f, c)
    if not f.border then return end
    for _, t in pairs(f.border) do t:SetColorTexture(c[1], c[2], c[3], c[4] or 1) end
end

-- A button that can be picked: its border and label in the accent while
-- it is. The hover handlers put the border back, so it is painted again
-- after them.
local function Select(b, on)
    b.selected = on and true or false
    if Chrome:Game() then
        -- The game's own buttons: the picked one stays lit, the way its
        -- tabs show a pick, and every label keeps the game's gold.
        if b.LockHighlight then
            if on then b:LockHighlight() else b:UnlockHighlight() end
        end
        return
    end
    Paint(b, on and C.fel or C.border)
    if b.label then Ink(b.label, on and C.fel or C.text) end
end

local function Chip(parent, text, w, onClick)
    local b = Chrome:Button(parent, text, w, 22)
    b:SetScript("OnClick", onClick)
    b:HookScript("OnLeave", function(s) Select(s, s.selected) end)
    return b
end

-- A text box in the window's chrome, with a hint shown while it is empty.
local function Input(parent, w, hint, onChange)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(w, 24)
    if Chrome:Game() then
        Chrome:GameInputArt(holder, 0)
    else
        local bg = Chrome:Texture(holder, "BACKGROUND", C.void)
        bg:SetAllPoints()
        Chrome:AddBorder(holder)
    end
    local eb = CreateFrame("EditBox", nil, holder)
    eb:SetPoint("TOPLEFT", 7, -2)
    eb:SetPoint("BOTTOMRIGHT", -7, 2)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(200)
    local chatFont = rawget(_G, "ChatFontNormal")
    if chatFont and eb.SetFontObject then eb:SetFontObject(chatFont) end
    Chrome:SetFont(eb, 12)
    Ink(eb, C.text)

    -- The hint lives on the box itself, which draws no textures of its own.
    local ph = eb:CreateFontString(nil, "ARTWORK")
    Chrome:SetFont(ph, 12)
    Ink(ph, C.muted)
    ph:SetPoint("LEFT", 0, 0)
    ph:SetText(hint or "")

    local function paint()
        if eb:HasFocus() or (eb:GetText() or "") ~= "" then ph:Hide() else ph:Show() end
    end
    eb:SetScript("OnEditFocusGained", function() paint(); Paint(holder, C.fel) end)
    eb:SetScript("OnEditFocusLost", function() paint(); Paint(holder, C.border) end)
    eb:SetScript("OnTextChanged", function(self, user)
        paint()
        if onChange then onChange(self:GetText() or "", user) end
    end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    holder:EnableMouse(true)
    holder:SetScript("OnMouseDown", function() eb:SetFocus() end)

    holder.edit = eb
    function holder:SetValue(v) eb:SetText(v or ""); paint() end
    function holder:GetValue() return eb:GetText() or "" end
    paint()
    return holder
end

local function Label(parent, text, size, color)
    local fs = Chrome:Text(parent, size or 11, color or C.muted)
    fs:SetJustifyH("LEFT")
    fs:SetText(text or "")
    return fs
end

local function Wrap(fs, w)
    fs:SetWidth(w)
    fs:SetJustifyH("LEFT")
    if fs.SetWordWrap then fs:SetWordWrap(true) end
end

-- ============================================================
-- Window
-- ============================================================

function UI:Build()
    if self.frame then return self.frame end
    local f = Chrome:NewPanel("WicksRemindersFrame", {
        title = "Wick's Reminders", width = WIDTH, height = HEIGHT, strata = "MEDIUM", db = ns.DB().window,
    })
    self.frame = f
    ROW_W = UI.ContentWidth(f)
    f:HookScript("OnShow", function() UI:Refresh() end)
    f:HookScript("OnHide", function() UI:ShowList() end)
    self.list = self:BuildList(f.content)
    self.editor = self:BuildEditor(f.content)
    self.editor:Hide()
    return f
end

function UI:Show()
    self:Build()
    self.frame:Show()
    self:ShowList()
end

function UI:Toggle()
    self:Build()
    if self.frame:IsShown() then self.frame:Hide() else self:Show() end
end

function UI:SetTitle(sub)
    local t = Chrome:TitleMarkup("Wick's Reminders")
    if sub then t = t .. "  " .. Chrome:Esc("muted") .. sub .. "|r" end
    self.frame.title:SetText(t)
end

function UI:ShowList()
    if not self.frame then return end
    self.draft = nil
    self.editor:Hide()
    self.list:Show()
    self:SetTitle(nil)
    self:Refresh()
end

-- ============================================================
-- The list
-- ============================================================

function UI:BuildList(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()

    local x = 0
    for _, k in ipairs({ "timer", "alarm", "event" }) do
        local b = Chrome:Button(v, "New " .. ns.KINDS[k].label:lower(), 96, 22)
        b:SetPoint("TOPLEFT", x, 0)
        b:SetScript("OnClick", function() UI:OpenEditor(nil, k) end)
        x = x + 102
    end
    -- The clock sits in the footer, between Clear finished and Options,
    -- where the realm's time has room.
    v.clock = Label(v, "", 11)
    v.clock:SetPoint("BOTTOM", 0, 6)
    v.clock:SetJustifyH("CENTER")

    local area = CreateFrame("Frame", nil, v)
    area:SetPoint("TOPLEFT", 0, -32)
    area:SetSize(ROW_W, ROWS * (ROW_H + ROW_GAP))
    area:EnableMouseWheel(true)
    area:SetScript("OnMouseWheel", function(_, d) UI:Scroll(-d) end)
    v.area = area
    v.rows = {}
    for i = 1, ROWS do v.rows[i] = self:NewRow(area, i) end

    v.empty = Label(area, "", 12)
    v.empty:SetPoint("TOP", 0, -60)
    Wrap(v.empty, ROW_W - 60)
    v.empty:SetJustifyH("CENTER")
    v.empty:SetText("Nothing to remind you of yet.\n\nMake one with the buttons above. For a quick one from chat, "
        .. Chrome:Esc("fel") .. "/remind 10m check the auction house|r works too.")

    v.clear = Chrome:Button(v, "Clear finished", 110, 22)
    v.clear:SetPoint("BOTTOMLEFT", 0, 0)
    v.clear:SetScript("OnClick", function()
        local n = ns:ClearDone()
        ns.A:Print(n == 0 and "nothing finished to clear." or ("cleared " .. n .. " finished."))
    end)
    v.options = Chrome:Button(v, "Options", 80, 22)
    v.options:SetPoint("BOTTOMRIGHT", 0, 0)
    v.options:SetScript("OnClick", function() ns.A:OpenOptions() end)
    v.more = Label(v, "", 10)
    v.more:SetPoint("BOTTOM", 0, 30)
    return v
end

function UI:NewRow(area, i)
    local row = CreateFrame("Button", nil, area)
    row:SetSize(ROW_W, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * (ROW_H + ROW_GAP))
    local bg = Chrome:Texture(row, "BACKGROUND", C.shadow)
    bg:SetAllPoints()
    Chrome:AddBorder(row)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(_, d) UI:Scroll(-d) end)

    row.tag = Label(row, "", 9, C.fel)
    row.tag:SetPoint("LEFT", 10, 0)
    row.tag:SetWidth(46)

    row.text = Label(row, "", 12, C.text)
    row.text:SetPoint("TOPLEFT", 60, -6)
    row.text:SetPoint("RIGHT", row, "RIGHT", -64, 0)
    if row.text.SetWordWrap then row.text:SetWordWrap(false) end

    row.when = Label(row, "", 10)
    row.when:SetPoint("BOTTOMLEFT", 60, 6)
    row.when:SetPoint("RIGHT", row, "RIGHT", -64, 0)
    if row.when.SetWordWrap then row.when:SetWordWrap(false) end

    row.toggle = Chrome:Check(row, "",
        function() local r = row.rem; return r ~= nil and r.enabled and not r.done or false end,
        function(on) if row.rem then ns:SetEnabled(row.rem, on) end end)
    row.toggle:SetSize(20, 20)
    row.toggle:SetPoint("RIGHT", -34, 0)
    row.toggle:HookScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_TOP")
        GameTooltip:AddLine("On or off")
        GameTooltip:AddLine("Switching a finished one on starts it again.", 0.56, 0.53, 0.44, true)
        GameTooltip:Show()
    end)
    row.toggle:HookScript("OnLeave", function() GameTooltip:Hide() end)

    local del = CreateFrame("Button", nil, row)
    del:SetSize(14, 14)
    del:SetPoint("RIGHT", -10, 0)
    local x = del:CreateTexture(nil, "ARTWORK")
    x:SetAllPoints()
    x:SetTexture(Chrome:Glyph("close"))
    del.x = x
    local function rest()
        local c = (row.armUntil and GetTime() < row.armUntil) and WARN or C.muted
        x:SetVertexColor(c[1], c[2], c[3], 1)
        if c == C.muted then Chrome:Register(x, C.muted, "vertex", 1) end
    end
    del.rest = rest
    rest()
    del:SetScript("OnEnter", function(s)
        x:SetVertexColor(WARN[1], WARN[2], WARN[3], 1)
        GameTooltip:SetOwner(s, "ANCHOR_TOP")
        GameTooltip:AddLine("Delete")
        GameTooltip:AddLine("Click twice.", 0.56, 0.53, 0.44)
        GameTooltip:Show()
    end)
    del:SetScript("OnLeave", function() rest(); GameTooltip:Hide() end)
    -- Two clicks: the first arms it for a few seconds and says so.
    del:SetScript("OnClick", function()
        local r = row.rem
        if not r then return end
        if row.armId == r.id and row.armUntil and GetTime() < row.armUntil then
            row.armId, row.armUntil = nil, nil
            ns:Remove(r)
            return
        end
        row.armId, row.armUntil = r.id, GetTime() + 3
        UI:PaintRow(row, r)
    end)
    row.del = del

    row:SetScript("OnEnter", function(s) Paint(s, C.fel) end)
    row:SetScript("OnLeave", function(s) Paint(s, C.border) end)
    row:SetScript("OnClick", function(s) if s.rem then UI:OpenEditor(s.rem) end end)
    return row
end

function UI:PaintRow(row, r, now)
    row.rem = r
    local live = (r.enabled and not r.done) or r.snoozeUntil
    Ink(row.tag, live and C.fel or C.muted)
    row.tag:SetText(ns.KINDS[r.kind] and ns.KINDS[r.kind].tag or "")
    Ink(row.text, live and C.text or C.muted)
    row.text:SetText(r.text or "")
    if row.armId ~= r.id then row.armUntil = nil end
    if row.armUntil and GetTime() < row.armUntil then
        Ink(row.when, WARN)
        row.when:SetText("Click the cross again to delete it.")
    else
        Ink(row.when, C.muted)
        row.when:SetText(ns.Describe(r, now))
    end
    row.del.rest()
    if row.toggle.Refresh then row.toggle.Refresh() end
end

function UI:Scroll(by)
    local n = self.sorted and #self.sorted or 0
    self.offset = math.max(0, math.min(math.max(0, n - ROWS), self.offset + by))
    self:Refresh()
end

function UI:PaintClock(now)
    local v = self.list
    if not v then return end
    local t = date("*t", now or time())
    local s = ns.FormatClock(t.hour, t.min)
    local off = ns.RealmOffset()
    if off ~= 0 then
        local r = date("*t", (now or time()) + off)
        s = s .. Chrome:Esc("muted") .. "   realm " .. ns.FormatClock(r.hour, r.min) .. "|r"
    end
    v.clock:SetText(s)
end

function UI:Refresh()
    if not (self.frame and self.frame:IsShown()) then return end
    if self.draft then self:PaintEditor() return end
    local v, now = self.list, time()
    local list = ns:Sorted()
    self.sorted = list
    self.offset = math.max(0, math.min(math.max(0, #list - ROWS), self.offset))
    for i, row in ipairs(v.rows) do
        local r = list[i + self.offset]
        if r then
            row:Show()
            self:PaintRow(row, r, now)
        else
            row.rem = nil
            row:Hide()
        end
    end
    if #list == 0 then v.empty:Show() else v.empty:Hide() end
    if #list > ROWS then
        v.more:SetText(("%d to %d of %d. Scroll for the rest."):format(self.offset + 1, math.min(#list, self.offset + ROWS), #list))
    else
        v.more:SetText("")
    end
    self:PaintClock(now)
end

-- Once a second while the window is open: the countdowns and the clock.
function UI:Tick(now)
    if not (self.frame and self.frame:IsShown()) then return end
    if self.draft then
        self:PaintSummary(now)
        return
    end
    for _, row in ipairs(self.list.rows) do
        if row.rem and row:IsShown() then
            if row.armUntil and now and GetTime() >= row.armUntil then row.armUntil = nil; row.armId = nil end
            self:PaintRow(row, row.rem, now)
        end
    end
    self:PaintClock(now)
end

-- ============================================================
-- The editor
-- ============================================================

local TIMER_PRESETS = {
    { 300, "5m" }, { 600, "10m" }, { 900, "15m" }, { 1800, "30m" },
    { 2700, "45m" }, { 3600, "1h" }, { 7200, "2h" },
}

local function newDraft(kind)
    local t = date("*t", time() + ns.AlarmOffset())
    local lvl = UnitLevel and tonumber(UnitLevel("player")) or 1
    return {
        kind = kind or "timer",
        text = "",
        duration = 600,
        hour = (t.hour + 1) % 24, min = 0,
        days = {},
        trigger = "login",
        level = math.min(lvl + 1, ns.MaxLevel()),
        repeats = false,
        scope = "account",
        enabled = true,
    }
end

function UI:BuildEditor(parent)
    local v = CreateFrame("Frame", nil, parent)
    v:SetAllPoints()

    local what = Label(v, "Remind me to")
    what:SetPoint("TOPLEFT", 0, 0)
    v.text = Input(v, ROW_W, "check the auction house", function(t)
        if UI.draft then UI.draft.text = t end
    end)
    v.text:SetPoint("TOPLEFT", 0, -16)

    v.tabs = {}
    local x = 0
    for _, k in ipairs({ "timer", "alarm", "event" }) do
        local b = Chip(v, ns.KINDS[k].label, 90, function() UI:SetKind(k) end)
        b:SetPoint("TOPLEFT", x, -50)
        v.tabs[k] = b
        x = x + 96
    end

    v.panes = {
        timer = self:BuildTimerPane(v),
        alarm = self:BuildAlarmPane(v),
        event = self:BuildEventPane(v),
    }
    for _, p in pairs(v.panes) do
        p:SetPoint("TOPLEFT", 0, -84)
        p:SetSize(ROW_W, 200)
    end

    v.mine = Chrome:Check(v, "Only on this character",
        function() return UI.draft and UI.draft.scope == "char" or false end,
        function(on) if UI.draft then UI.draft.scope = on and "char" or "account" end end)
    v.mine:SetPoint("TOPLEFT", 0, -292)

    v.sound = Chrome:Button(v, "Sound", 200, 22)
    v.sound:SetPoint("TOPLEFT", 0, -318)
    v.sound:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    v.sound:SetScript("OnClick", function(_, button)
        local d = UI.draft
        if not d then return end
        local cur = d.sound or ns.KINDS[d.kind].sound
        local idx = 1
        for i, s in ipairs(ns.SOUNDS) do if s.id == cur then idx = i end end
        idx = idx + (button == "RightButton" and -1 or 1)
        if idx > #ns.SOUNDS then idx = 1 elseif idx < 1 then idx = #ns.SOUNDS end
        d.sound = ns.SOUNDS[idx].id
        ns.PlaySound(d.sound, true)
        UI:PaintEditor()
    end)
    v.sound:HookScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_TOP")
        GameTooltip:AddLine("Click for the next sound, right-click for the one before.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    v.sound:HookScript("OnLeave", function() GameTooltip:Hide() end)

    v.save = Chrome:Button(v, "Save", 90, 22)
    v.save:SetPoint("BOTTOMRIGHT", 0, 0)
    v.save:SetScript("OnClick", function() UI:SaveDraft() end)
    v.cancel = Chrome:Button(v, "Cancel", 90, 22)
    v.cancel:SetPoint("RIGHT", v.save, "LEFT", -6, 0)
    v.cancel:SetScript("OnClick", function() UI:ShowList() end)
    v.try = Chrome:Button(v, "Try it", 90, 22)
    v.try:SetPoint("BOTTOMLEFT", 0, 0)
    v.try:SetScript("OnClick", function()
        local d = UI.draft
        if not d then return end
        local r = Core.copy(d)
        r.id = 0
        r.text = Core.trim(r.text or "") ~= "" and r.text or "Your reminder"
        ns.Alert:Show(r, { test = true })
        if ns.DB().sound then ns.PlaySound(d.sound or ns.KINDS[d.kind].sound, true) end
    end)

    v.err = Label(v, "", 11, WARN)
    v.err:SetPoint("BOTTOMLEFT", v.try, "TOPLEFT", 0, 8)
    Wrap(v.err, ROW_W)
    return v
end

function UI:BuildTimerPane(v)
    local p = CreateFrame("Frame", nil, v)
    local l = Label(p, "Go off in")
    l:SetPoint("TOPLEFT", 0, 0)
    p.chips = {}
    for i, pr in ipairs(TIMER_PRESETS) do
        local b = Chip(p, pr[2], 56, function()
            if not UI.draft then return end
            UI.draft.duration = pr[1]
            p.custom:SetValue("")
            UI:PaintEditor()
        end)
        b:SetPoint("TOPLEFT", (i - 1) * 62, -16)
        b.secs = pr[1]
        p.chips[i] = b
    end
    p.custom = Input(p, 170, "or type 1h 20m", function(t, user)
        if not (user and UI.draft) then return end
        local secs = ns.ParseDuration(t)
        if secs then UI.draft.duration = secs end
        UI:PaintEditor()
    end)
    p.custom:SetPoint("TOPLEFT", 0, -50)
    p.parsed = Label(p, "", 11, C.fel)
    p.parsed:SetPoint("LEFT", p.custom, "RIGHT", 10, 0)
    p.rep = Chrome:Check(p, "Start again each time it ends",
        function() return UI.draft and UI.draft.repeats or false end,
        function(on) if UI.draft then UI.draft.repeats = on; UI:PaintEditor() end end)
    p.rep:SetPoint("TOPLEFT", 0, -86)
    p.summary = Label(p, "", 11, C.text)
    p.summary:SetPoint("TOPLEFT", 0, -116)
    Wrap(p.summary, ROW_W)
    return p
end

function UI:BuildAlarmPane(v)
    local p = CreateFrame("Frame", nil, v)
    local l = Label(p, "Go off at")
    l:SetPoint("TOPLEFT", 0, 0)
    p.big = Chrome:Text(p, 22, C.fel, nil, true)
    p.big:SetPoint("TOPLEFT", 0, -20)

    p.hour = Chrome:Stepper(p, "Hour",
        function() return UI.draft and UI.draft.hour end,
        function(val) if UI.draft then UI.draft.hour = val % 24; UI:PaintEditor() end end,
        { text = function(h) return ns.Use24h() and ("%02d"):format(h) or ns.FormatClock(h, 0):gsub(":00", "") end })
    p.hour:SetPoint("TOPLEFT", 150, -16)
    p.minute = Chrome:Stepper(p, "Minute",
        function() return UI.draft and UI.draft.min end,
        function(val)
            if not UI.draft then return end
            local by = val - UI.draft.min
            if IsShiftKeyDown and IsShiftKeyDown() then by = by * 10 end
            UI.draft.min = (UI.draft.min + by) % 60
            UI:PaintEditor()
        end,
        { format = "%02d" })
    p.minute:SetPoint("TOPLEFT", 150, -38)
    p.shift = Label(p, "Shift-click moves the minutes by ten.", 10)
    p.shift:SetPoint("TOPLEFT", 150, -58)

    p.typed = Input(p, 130, "or type 8:30pm", function(t, user)
        if not (user and UI.draft) then return end
        local h, m = ns.ParseClock(t)
        if h then UI.draft.hour, UI.draft.min = h, m end
        UI:PaintEditor()
    end)
    p.typed:SetPoint("TOPLEFT", 0, -56)

    local on = Label(p, "On these days (none for just once)")
    on:SetPoint("TOPLEFT", 0, -92)
    p.days = {}
    for i, w in ipairs(ns.DAY_ORDER) do
        local b = Chip(p, ns.DAY_SHORT[w], 40, function()
            local d = UI.draft
            if not d then return end
            d.days = d.days or {}
            d.days[w] = not d.days[w] or nil
            UI:PaintEditor()
        end)
        b:SetPoint("TOPLEFT", (i - 1) * 44, -108)
        b.wday = w
        p.days[i] = b
    end
    p.everyDay = Chip(p, "Every day", 84, function()
        local d = UI.draft
        if not d then return end
        local all = true
        for w = 1, 7 do if not (d.days and d.days[w]) then all = false end end
        d.days = {}
        if not all then for w = 1, 7 do d.days[w] = true end end
        UI:PaintEditor()
    end)
    p.everyDay:SetPoint("TOPLEFT", 7 * 44 + 6, -108)

    p.summary = Label(p, "", 11, C.text)
    p.summary:SetPoint("TOPLEFT", 0, -142)
    Wrap(p.summary, ROW_W)
    p.clockNote = Label(p, "", 10)
    p.clockNote:SetPoint("TOPLEFT", 0, -176)
    Wrap(p.clockNote, ROW_W)
    return p
end

function UI:BuildEventPane(v)
    local p = CreateFrame("Frame", nil, v)
    local l = Label(p, "Go off")
    l:SetPoint("TOPLEFT", 0, 0)
    p.radios = {}
    local n = 0
    for _, t in ipairs(ns.TRIGGERS) do
        if ns.TriggerAvailable(t) then
            local col, line = n % 2, math.floor(n / 2)
            local b = Chrome:Check(p, t.label,
                function() return UI.draft and UI.draft.trigger == t.id or false end,
                function()
                    local d = UI.draft
                    if not d then return end
                    d.trigger = t.id
                    UI:PaintEditor()
                end)
            b:SetPoint("TOPLEFT", col * 224, -16 - line * 20)
            b.trigger = t.id
            p.radios[#p.radios + 1] = b
            n = n + 1
        end
    end
    local below = -16 - math.ceil(n / 2) * 20 - 6

    p.zone = Input(p, 220, "the zone's name", function(t)
        if UI.draft and UI.draft.trigger == "zone" then UI.draft.zone = t end
    end)
    p.zone:SetPoint("TOPLEFT", 0, below)
    p.here = Chrome:Button(p, "Where I am", 100, 22)
    p.here:SetPoint("LEFT", p.zone, "RIGHT", 6, 0)
    p.here:SetScript("OnClick", function()
        local zone = (GetRealZoneText and GetRealZoneText()) or ""
        -- Shift takes the part of the zone you stand in instead.
        local sub = GetSubZoneText and GetSubZoneText()
        if IsShiftKeyDown and IsShiftKeyDown() and sub and sub ~= "" then zone = sub end
        if UI.draft then UI.draft.zone = zone end
        p.zone:SetValue(zone)
    end)

    p.level = Chrome:Stepper(p, "Level",
        function() return UI.draft and UI.draft.level end,
        function(val)
            if UI.draft then UI.draft.level = math.max(2, math.min(ns.MaxLevel(), val)) ; UI:PaintEditor() end
        end)
    p.level:SetPoint("TOPLEFT", 0, below - 2)
    p.levelNote = Label(p, "", 10)
    p.levelNote:SetPoint("LEFT", p.level, "RIGHT", 10, 0)

    p.rep = Chrome:Check(p, "Every time, not only the next time",
        function() return UI.draft and UI.draft.repeats or false end,
        function(on) if UI.draft then UI.draft.repeats = on end end)
    p.below = below
    return p
end

function UI:OpenEditor(r, kind)
    self:Build()
    self.frame:Show()
    local d
    if r then
        d = Core.copy(r)
        d.days = Core.copy(r.days) or {}
        d.zone = r.trigger == "zone" and r.arg or nil
        d.level = math.min(r.trigger == "level" and tonumber(r.arg) or ((UnitLevel and tonumber(UnitLevel("player")) or 1) + 1), ns.MaxLevel())
        local fresh = newDraft(r.kind)
        for k, val in pairs(fresh) do if d[k] == nil then d[k] = val end end
    else
        d = newDraft(kind)
    end
    self.draft = d
    self.originalScope = r and r.scope or nil
    self.list:Hide()
    local e = self.editor
    e:Show()
    e.err:SetText("")
    e.text:SetValue(d.text)
    e.panes.timer.custom:SetValue("")
    e.panes.alarm.typed:SetValue("")
    e.panes.event.zone:SetValue(d.zone or "")
    self:SetTitle(r and "change a reminder" or ("new " .. ns.KINDS[d.kind].label:lower()))
    self:SetKind(d.kind)
    if not r then e.text.edit:SetFocus() end
end

function UI:SetKind(k)
    if not self.draft then return end
    self.draft.kind = k
    if not self.draft.id then self:SetTitle("new " .. ns.KINDS[k].label:lower()) end
    for id, pane in pairs(self.editor.panes) do
        if id == k then pane:Show() else pane:Hide() end
    end
    self:PaintEditor()
end

function UI:PaintSummary(now)
    local d, e = self.draft, self.editor
    if not d then return end
    now = now or time()
    if d.kind == "timer" then
        local p = e.panes.timer
        local due = now + (d.duration or 0)
        local t = date("*t", due)
        p.summary:SetText(("Goes off at %s, %s from now%s."):format(ns.FormatClock(t.hour, t.min), ns.FormatSpan(d.duration),
            d.repeats and (", then every " .. ns.FormatSpan(d.duration) .. " until you switch it off") or ""))
    elseif d.kind == "alarm" then
        local p = e.panes.alarm
        local due = ns.NextAlarm(d.hour, d.min, d.days, now)
        local days = ns.DaysText(d.days)
        local when = due and ("next in " .. ns.FormatLeft(due - now)) or ""
        if days then
            p.summary:SetText(("At %s, %s. The %s."):format(ns.FormatClock(d.hour, d.min), days, when))
        else
            p.summary:SetText(("Once, at %s. Goes off %s."):format(ns.FormatClock(d.hour, d.min), when:gsub("^next ", "")))
        end
    end
end

function UI:PaintEditor()
    local d, e = self.draft, self.editor
    if not (d and e) then return end
    for k, b in pairs(e.tabs) do Select(b, k == d.kind) end

    local tp = e.panes.timer
    local preset = false
    for _, b in ipairs(tp.chips) do
        local on = d.duration == b.secs
        preset = preset or on
        Select(b, on)
    end
    local typed = Core.trim(tp.custom:GetValue())
    if typed == "" then
        tp.parsed:SetText(preset and "" or ("= " .. ns.FormatSpan(d.duration)))
        Ink(tp.parsed, C.fel)
    elseif ns.ParseDuration(typed) then
        tp.parsed:SetText("= " .. ns.FormatSpan(ns.ParseDuration(typed)))
        Ink(tp.parsed, C.fel)
    else
        tp.parsed:SetText("try 25m, 1h 30m or 90s")
        Ink(tp.parsed, WARN)
    end
    tp.rep.Refresh()

    local ap = e.panes.alarm
    d.hour, d.min = d.hour or 0, d.min or 0
    ap.big:SetText(ns.FormatClock(d.hour, d.min))
    ap.hour.Refresh()
    ap.minute.Refresh()
    for _, b in ipairs(ap.days) do Select(b, d.days and d.days[b.wday]) end
    local all = true
    for w = 1, 7 do if not (d.days and d.days[w]) then all = false end end
    Select(ap.everyDay, all)
    ap.clockNote:SetText(ns.DB().realmClock and "Read on the realm's clock. Change that under Options."
        or "Read on your computer's clock. Options can switch alarms to the realm's.")
    local typedClock = Core.trim(ap.typed:GetValue())
    if typedClock ~= "" and not ns.ParseClock(typedClock) then
        ap.summary:SetText("That is not a time I can read. Try 20:30 or 8:30pm.")
        Ink(ap.summary, WARN)
    else
        Ink(ap.summary, C.text)
    end

    local ep = e.panes.event
    for _, b in ipairs(ep.radios) do b.Refresh() end
    if d.trigger == "zone" then ep.zone:Show(); ep.here:Show() else ep.zone:Hide(); ep.here:Hide() end
    if d.trigger == "level" then
        ep.level:Show(); ep.level.Refresh()
        local mine = UnitLevel and tonumber(UnitLevel("player")) or 1
        ep.levelNote:SetText(mine >= ns.MaxLevel() and ("This character is already level " .. ns.MaxLevel() .. ".") or "")
        ep.levelNote:Show()
    else
        ep.level:Hide(); ep.levelNote:Hide()
    end
    -- Straight under the choices, or under the zone box or level stepper
    -- when the choice has one.
    local hasArg = d.trigger == "zone" or d.trigger == "level"
    ep.rep:ClearAllPoints()
    ep.rep:SetPoint("TOPLEFT", 0, ep.below - (hasArg and 32 or 0))
    ep.rep.Refresh()

    e.mine.label:SetText("Only on this character (" .. tostring((UnitName and UnitName("player")) or "this one") .. ")")
    e.mine.Refresh()
    local s = ns.SOUND[d.sound or ns.KINDS[d.kind].sound] or ns.SOUND.alarm
    local label = "Sound: " .. s.label
    if e.sound.label then e.sound.label:SetText(label) elseif e.sound.SetText then e.sound:SetText(label) end

    if typedClock == "" or ns.ParseClock(typedClock) then self:PaintSummary() end
end

-- Check the draft, tidy away what its kind does not use, and save it.
function UI:SaveDraft()
    local d, e = self.draft, self.editor
    if not d then return end
    d.text = Core.trim(e.text:GetValue())
    if d.kind == "timer" then
        if not (d.duration and d.duration > 0) then
            e.err:SetText("How long? Pick a length or type one, like 25m.")
            return
        end
        d.hour, d.min, d.days, d.trigger, d.arg = nil, nil, nil, nil, nil
        if d.text == "" then d.text = "Time's up" end
    elseif d.kind == "alarm" then
        d.duration, d.trigger, d.arg, d.repeats = nil, nil, nil, nil
        if not ns.AnyDay(d.days) then d.days = nil end
        if d.text == "" then d.text = "Alarm" end
    else
        if not ns.TriggerAvailable(d.trigger) then
            e.err:SetText("Pick what it waits for.")
            return
        end
        if d.trigger == "zone" then
            d.arg = Core.trim(e.panes.event.zone:GetValue())
            if d.arg == "" then
                e.err:SetText("Which zone? Type its name, or stand in it and press Where I am.")
                return
            end
        elseif d.trigger == "level" then
            d.arg = d.level
        else
            d.arg = nil
        end
        d.duration, d.hour, d.min, d.days = nil, nil, nil, nil
        if d.text == "" then d.text = ns.Schedule(d) end
    end
    d.zone, d.level = nil, nil
    if d.scope == "char" and (not d.id or self.originalScope ~= "char") then d.owner = ns.CharKey() end
    d.sound = d.sound or ns.KINDS[d.kind].sound
    -- The editor lets go of the draft first: saving repaints, and a draft
    -- tidied for its kind has nothing for the other panes to show.
    self.draft = nil
    local saved = ns:Save(d)
    ns.A:Print(("saved %s%s|r: %s."):format(Chrome:Esc("fel"), saved.text, ns.Describe(saved)))
    self:ShowList()
end
