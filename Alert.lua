-- Wick's Reminders
-- Alert.lua: the card that pops up when a reminder goes off.
--
-- Cards stack down from one anchor near the top of the screen, newest at
-- the top, and stay until answered: Snooze puts the reminder back for a
-- few minutes, Done puts the card away. A ringing alarm sounds again every
-- few seconds until one of the two is pressed. Escape does not close them,
-- on purpose: Escape is how a player drops a target mid-fight, and an
-- alarm swept away with it is an alarm missed.

local ADDON, ns = ...
if not WickCore then return end

local Core, Chrome = WickCore, WickCore.Chrome
local C = Chrome.Colors

local Alert = { cards = {}, queue = {}, pool = {} }
ns.Alert = Alert

local W, H = 330, 116
local GAP = 6
local MAX = 4
local RING_EVERY, RING_FOR = 4, 60

-- ============================================================
-- Anchor
-- ============================================================

function Alert:Anchor()
    if self.anchor then return self.anchor end
    local a = CreateFrame("Frame", "WicksRemindersAlertAnchor", UIParent)
    a:SetSize(W, H)
    a:SetPoint("TOP", UIParent, "TOP", 0, -140)
    a:SetMovable(true)
    a:SetClampedToScreen(true)
    a:SetFrameStrata("DIALOG")
    local db = ns.DB().alert
    Chrome:RestorePosition(a, db)
    self.anchor = a
    -- A UI with movers of its own (Wick's UI) can list and place it.
    ns.A:RegisterMovable(a, { key = "reminders_alert", title = "Reminder alerts" })
    return a
end

function Alert:ResetPosition()
    local db = ns.DB().alert
    for k in pairs(db) do db[k] = nil end
    local a = self:Anchor()
    if Chrome:MovableClaimed(a) then
        ns.A:Print("Wick's UI is placing the alerts; move them with its movers.")
        return
    end
    a:ClearAllPoints()
    a:SetPoint("TOP", UIParent, "TOP", 0, -140)
    ns.Dirty()
    self:Test()
end

-- ============================================================
-- Cards
-- ============================================================

local function build()
    local f = Chrome:NewPanel(nil, { title = "Wick's Reminders", width = W, height = H, strata = "DIALOG" })
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)

    -- Dragging any card moves the anchor, so the stack moves as one.
    f:SetScript("OnDragStart", function()
        local a = Alert:Anchor()
        if not Chrome:MovableClaimed(a) then a:StartMoving() end
    end)
    f:SetScript("OnDragStop", function()
        local a = Alert:Anchor()
        a:StopMovingOrSizing()
        Chrome:SavePosition(a, ns.DB().alert)
        Alert:Layout()
    end)

    local body = f.content
    f.msg = Chrome:Text(body, 14)
    f.msg:SetPoint("TOPLEFT", 2, -2)
    f.msg:SetPoint("TOPRIGHT", -2, -2)
    f.msg:SetJustifyH("LEFT")
    f.msg:SetJustifyV("TOP")
    if f.msg.SetWordWrap then f.msg:SetWordWrap(true) end
    if f.msg.SetMaxLines then f.msg:SetMaxLines(2) end
    f.msg:SetHeight(36)

    f.done = Chrome:Button(body, "Done", 64, 22)
    f.done:SetPoint("BOTTOMRIGHT", 0, 0)
    f.done:SetScript("OnClick", function() Alert:Dismiss(f) end)

    f.snooze = Chrome:Button(body, "Snooze", 96, 22)
    f.snooze:SetPoint("RIGHT", f.done, "LEFT", -6, 0)
    f.snooze:SetScript("OnClick", function()
        local r = f.rid and ns:Get(f.rid)
        if r then
            ns:Snooze(r)
            ns.A:Print(("snoozed %s%s|r for %d minutes."):format(Chrome:Esc("fel"), r.text, ns.DB().snoozeMinutes))
        end
        Alert:Dismiss(f)
    end)

    -- The note has a line of its own over the buttons: "came due at ...
    -- while you were away" is the line that matters most on a missed one.
    f.note = Chrome:Text(body, 10, C.muted)
    f.note:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 2, 28)
    f.note:SetPoint("RIGHT", body, "RIGHT", -2, 0)
    f.note:SetJustifyH("LEFT")
    if f.note.SetWordWrap then f.note:SetWordWrap(false) end

    -- The close mark answers the card the same way Done does.
    if f.close then f.close:SetScript("OnClick", function() Alert:Dismiss(f) end) end
    return f
end

local function fill(f, r, opts)
    local kind = ns.KINDS[r.kind] or ns.KINDS.timer
    local head = kind.label
    if r.kind == "alarm" then head = head .. "  " .. ns.FormatClock(r.hour or 0, r.min or 0) end
    f.title:SetText(Chrome:Esc("fel") .. head .. "|r")
    f.msg:SetText(tostring(r.text or ""))
    local note
    if opts.test then
        note = "A test. Drag the title to move it."
    elseif opts.missed and opts.at then
        note = "Came due at " .. ns.FormatStamp(opts.at) .. " while you were away"
    elseif opts.snooze then
        note = "Snoozed, now back"
    elseif r.kind == "timer" then
        note = (r.repeats and "Starts again: every " or "After ") .. ns.FormatSpan(r.duration)
    elseif r.kind == "event" then
        note = ns.Schedule(r)
    else
        note = ns.DaysText(r.days) and ("Again " .. ns.DaysText(r.days)) or "Once"
    end
    f.note:SetText(note)
    local snooze = ns.DB().snoozeMinutes or 10
    if f.snooze.label then f.snooze.label:SetText(("Snooze %dm"):format(snooze))
    elseif f.snooze.SetText then f.snooze:SetText(("Snooze %dm"):format(snooze)) end
    if opts.test then f.snooze:Hide() else f.snooze:Show() end
end

-- Show a card for a reminder. One card per reminder: going off again
-- refreshes its card rather than stacking a second.
function Alert:Show(r, opts)
    opts = opts or {}
    self:Anchor()
    local now = time()
    local f
    for _, c in ipairs(self.cards) do if c.rid == r.id then f = c end end
    if f then
        for i, c in ipairs(self.cards) do if c == f then table.remove(self.cards, i) break end end
    elseif #self.cards >= MAX then
        -- A full stack: this one waits its turn.
        for _, q in ipairs(self.queue) do if q.r.id == r.id then q.opts = opts return end end
        self.queue[#self.queue + 1] = { r = r, opts = opts }
        return
    else
        f = table.remove(self.pool) or build()
    end
    f.rid = r.id
    f.test = opts.test
    f.sound = r.sound
    f.ringUntil = (not opts.test and r.kind == "alarm" and ns.DB().ringAlarms and ns.DB().sound) and (now + RING_FOR) or nil
    f.nextRing = now + RING_EVERY
    fill(f, r, opts)
    table.insert(self.cards, 1, f)
    f:Show()
    self:Layout()
end

function Alert:Layout()
    local a = self:Anchor()
    for i, f in ipairs(self.cards) do
        f:ClearAllPoints()
        if i == 1 then f:SetPoint("TOP", a, "TOP", 0, 0)
        else f:SetPoint("TOP", self.cards[i - 1], "BOTTOM", 0, -GAP) end
    end
end

function Alert:Dismiss(f)
    for i, c in ipairs(self.cards) do
        if c == f then table.remove(self.cards, i) break end
    end
    f:Hide()
    f.rid, f.ringUntil = nil, nil
    self.pool[#self.pool + 1] = f
    local q = table.remove(self.queue, 1)
    if q then
        local r = q.r.id == 0 and q.r or ns:Get(q.r.id)
        if r then self:Show(r, q.opts) return end
    end
    self:Layout()
end

-- A reminder deleted or switched off takes its card with it.
function Alert:Forget(id)
    for i = #self.queue, 1, -1 do
        if self.queue[i].r.id == id then table.remove(self.queue, i) end
    end
    for _, c in ipairs(self.cards) do
        if c.rid == id then self:Dismiss(c) return end
    end
end

function Alert:Tick(now)
    for _, f in ipairs(self.cards) do
        if f.ringUntil then
            if now > f.ringUntil then
                f.ringUntil = nil
            elseif now >= f.nextRing then
                f.nextRing = now + RING_EVERY
                ns.PlaySound(f.sound, true)
            end
        end
    end
end

-- The words in large letters just above the cards, for a few seconds. Our
-- own frame, not the game's raid warning: addon code writing into one of
-- Blizzard's frames taints it on Forever, and the next real raid warning
-- can then fail.
function Alert:Banner(text)
    local b = self.banner
    if not b then
        b = CreateFrame("Frame", "WicksRemindersBanner", UIParent)
        b:SetSize(760, 34)
        b:SetPoint("BOTTOM", self:Anchor(), "TOP", 0, 10)
        b:SetClampedToScreen(true)
        b:SetFrameStrata("HIGH")
        b:EnableMouse(false)
        b.text = Chrome:Text(b, 24, C.fel, "OUTLINE", true)
        b.text:SetPoint("CENTER")
        b:SetScript("OnUpdate", function(s, elapsed)
            s.left = (s.left or 0) - (elapsed or 0)
            if s.left <= 0 then s:Hide()
            elseif s.left < 1 then s:SetAlpha(s.left) end
        end)
        b:Hide()
        self.banner = b
    end
    b.text:SetText(text)
    b.left = 5
    b:SetAlpha(1)
    b:Show()
end

function Alert:Test()
    local r = { id = 0, kind = "timer", duration = 600, text = "This is how a reminder looks when it goes off.", sound = "chime" }
    self:Show(r, { test = true })
    if ns.DB().raidNotice then self:Banner("Wick's Reminders") end
    if ns.DB().sound then ns.PlaySound(r.sound, true) end
end

function Alert:Count() return #self.cards, #self.queue end
