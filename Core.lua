-- Wick's Reminders
-- Core.lua: the addon object, the saved reminders, the clock and the triggers.
--
-- A reminder is one of three kinds. A timer counts down from when it was
-- set, an alarm goes off at a time of day, and an event reminder waits for
-- something to happen in the game: logging in, reaching a zone, opening the
-- mailbox. Timers and alarms keep an absolute due time read from the
-- computer's clock, so they go on counting while you are logged out, and
-- anything that came due in the meantime is shown the moment you are back.

local ADDON, ns = ...

local Core = WickCore
if not Core then
    -- WickCore is missing or switched off. The TOC asks for it with
    -- OptionalDeps so this still loads and can say what is wrong, in the
    -- one line the whole suite shares.
    local need = _G.WicksNeedCore
    if not need then
        need = {}
        _G.WicksNeedCore = need
        local f = CreateFrame("Frame")
        f:RegisterEvent("PLAYER_LOGIN")
        f:SetScript("OnEvent", function()
            table.sort(need)
            print(("|cff4FC778Wick's Mods|r: %s %s WickCore, which is not installed or not switched on. It is in the same download as the rest of the suite: |cffD4C8A1wicksmods.com|r")
                :format(table.concat(need, ", "), #need == 1 and "needs" or "need"))
        end)
    end
    need[#need + 1] = "Wick's Reminders"
    return
end
ns.Core = Core
-- The harness, and anyone scripting the addon, reaches it by this name.
_G.WicksReminders = ns

local Chrome = Core.Chrome
local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or rawget(_G, "GetAddOnMetadata")
ns.version = GetMeta and GetMeta(ADDON, "Version") or "0.1.0"

local A = Core:NewAddon(ADDON, {
    title    = "Wick's Reminders",
    version  = ns.version,
    savedVar = "WicksRemindersDB",
    defaults = {
        -- Everything is account-wide: a reminder set on one character is
        -- there on the next unless it was made for that character alone.
        global = {
            reminders     = {},
            nextId        = 1,
            sound         = true,
            ringAlarms    = true,
            raidNotice    = true,
            chat          = true,
            flash         = true,
            snoozeMinutes = 10,
            missed        = true,
            realmClock    = false,
            window        = {},
            alert         = {},
        },
    },
})
ns.A = A

-- When this session began. Anything due before it came due while the
-- player was away.
ns.sessionStart = time()

-- The saved table is read through here every time, never kept: WickCore
-- may swap in the client's own table at login.
function ns.DB() return A.db and A.db.global end

function ns.Dirty()
    if Core.Store and Core.Store.Dirty then Core.Store:Dirty() end
end

function ns.CharKey() return Core.Profiles:CharKey() end

-- A reminder made for one character only goes off on that character.
function ns.Mine(r) return r.scope ~= "char" or r.owner == ns.CharKey() end

local function cvar(name)
    local CV = rawget(_G, "C_CVar")
    if CV and CV.GetCVar then return CV.GetCVar(name) end
    local f = rawget(_G, "GetCVar")
    return f and f(name) or nil
end

-- ============================================================
-- Kinds, triggers and sounds
-- ============================================================

ns.KINDS = {
    timer = { label = "Timer", tag = "TIMER", sound = "raid" },
    alarm = { label = "Alarm", tag = "ALARM", sound = "alarm" },
    event = { label = "Event", tag = "EVENT", sound = "chime" },
}

-- Seconds until the daily quests and the raid lockouts reset, where the
-- client can say.
local function untilDaily()
    local f = rawget(_G, "GetQuestResetTime")
    local s = f and tonumber(f())
    if s and s > 0 then return s end
end
local function untilWeekly()
    local DT = rawget(_G, "C_DateAndTime")
    local s = DT and DT.GetSecondsUntilWeeklyReset and tonumber(DT.GetSecondsUntilWeeklyReset())
    if s and s > 0 then return s end
end

ns.TRIGGERS = {
    { id = "login",   label = "When I log in" },
    { id = "zone",    label = "When I enter a zone", arg = "zone" },
    { id = "rested",  label = "When I reach an inn or a city" },
    { id = "mail",    label = "When I open a mailbox",         event = "MAIL_SHOW" },
    { id = "bank",    label = "When I open my bank",           event = "BANKFRAME_OPENED" },
    { id = "auction", label = "When I open the auction house", event = "AUCTION_HOUSE_SHOW" },
    { id = "vendor",  label = "When I talk to a vendor",       event = "MERCHANT_SHOW" },
    { id = "trainer", label = "When I talk to a trainer",      event = "TRAINER_SHOW" },
    { id = "combat",  label = "When my next fight ends",       event = "PLAYER_REGEN_ENABLED" },
    { id = "level",   label = "When I reach a level", arg = "level" },
    { id = "daily",   label = "When the daily quests reset", timed = untilDaily,  period = 86400 },
    { id = "weekly",  label = "When the raids reset",        timed = untilWeekly, period = 604800 },
}
ns.TRIGGER = {}
for _, t in ipairs(ns.TRIGGERS) do ns.TRIGGER[t.id] = t end

-- The highest level this game goes to, as the client says.
function ns.MaxLevel()
    local f = rawget(_G, "GetMaxPlayerLevel")
    local n = f and tonumber(f())
    return n or tonumber(rawget(_G, "MAX_PLAYER_LEVEL")) or 70
end

-- A timed trigger is only offered where the client can tell us when.
function ns.TriggerAvailable(t)
    if type(t) == "string" then t = ns.TRIGGER[t] end
    return t ~= nil and (not t.timed or t.timed() ~= nil)
end

ns.SOUNDS = {
    { id = "alarm",   label = "Alarm clock",  kit = "ALARM_CLOCK_WARNING_2",  fallback = 12867 },
    { id = "chime",   label = "Clock chime",  kit = "ALARM_CLOCK_WARNING_1",  fallback = 18871 },
    { id = "raid",    label = "Raid warning", kit = "RAID_WARNING",           fallback = 8959 },
    { id = "ready",   label = "Ready check",  kit = "READY_CHECK",            fallback = 8960 },
    { id = "whisper", label = "Whisper",      kit = "TELL_MESSAGE",           fallback = 3081 },
    { id = "quest",   label = "Quest done",   kit = "IG_QUEST_LIST_COMPLETE", fallback = 878 },
    { id = "none",    label = "No sound" },
}
ns.SOUND = {}
for _, s in ipairs(ns.SOUNDS) do ns.SOUND[s.id] = s end

-- One sound at a time: a handful of reminders that came due together at
-- login should not all shout at once.
local lastSound = 0
function ns.PlaySound(id, force)
    local s = ns.SOUND[id or "alarm"] or ns.SOUND.alarm
    if not s.kit then return end
    local now = GetTime and GetTime() or 0
    if not force and now - lastSound < 1.5 then return end
    lastSound = now
    local kits = rawget(_G, "SOUNDKIT")
    local kit = (kits and kits[s.kit]) or s.fallback
    -- The master channel, so an alarm is heard with game sounds turned down.
    if PlaySound then pcall(PlaySound, kit, "Master") end
end

-- ============================================================
-- Clock and wording
-- ============================================================

ns.DAY_ORDER = { 2, 3, 4, 5, 6, 7, 1 }   -- Monday first; date().wday is 1 for Sunday
ns.DAY_SHORT = { "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" }

-- How far the realm's clock is from this computer's, to the quarter hour.
function ns.RealmOffset()
    local gt = rawget(_G, "GetGameTime")
    if not gt then return 0 end
    local rh, rm = gt()
    if not (rh and rm) then return 0 end
    local t = date("*t", time())
    local diff = (rh * 60 + rm) - (t.hour * 60 + t.min)
    if diff > 720 then diff = diff - 1440 elseif diff < -720 then diff = diff + 1440 end
    return math.floor(diff / 15 + 0.5) * 15 * 60
end

-- The offset alarms are read in: none, or the realm's.
function ns.AlarmOffset()
    local db = ns.DB()
    return (db and db.realmClock) and ns.RealmOffset() or 0
end

-- The game clock's own 12 or 24 hour setting decides how times are written.
function ns.Use24h()
    local v = cvar("timeMgrUseMilitaryTime")
    if v == nil then return true end
    return v == "1" or v == 1 or v == true
end

function ns.FormatClock(h, m)
    if ns.Use24h() then return ("%02d:%02d"):format(h, m) end
    local h12 = h % 12
    if h12 == 0 then h12 = 12 end
    return ("%d:%02d %s"):format(h12, m, h < 12 and "AM" or "PM")
end

-- An epoch as a time of day, with the day when it is not today.
function ns.FormatStamp(epoch)
    local off = ns.AlarmOffset()
    local t, today = date("*t", epoch + off), date("*t", time() + off)
    local clock = ns.FormatClock(t.hour, t.min)
    if t.yday == today.yday and t.year == today.year then return clock end
    return ns.DAY_SHORT[t.wday] .. " " .. clock
end

-- What is left: "45s", "12m 05s", "3h 20m", "2d 4h".
function ns.FormatLeft(s)
    s = math.max(0, math.floor(s or 0))
    if s < 60 then return s .. "s" end
    if s < 3600 then return ("%dm %02ds"):format(math.floor(s / 60), s % 60) end
    if s < 86400 then return ("%dh %02dm"):format(math.floor(s / 3600), math.floor(s % 3600 / 60)) end
    return ("%dd %dh"):format(math.floor(s / 86400), math.floor(s % 86400 / 3600))
end

-- The same, coarser, for a broker bar or a tooltip.
function ns.FormatShort(s)
    s = math.max(0, math.floor(s or 0))
    if s < 60 then return s .. "s" end
    if s < 3600 then return math.floor(s / 60) .. "m" end
    if s < 86400 then return ("%dh %02dm"):format(math.floor(s / 3600), math.floor(s % 3600 / 60)) end
    return ("%dd %dh"):format(math.floor(s / 86400), math.floor(s % 86400 / 3600))
end

-- A length of time as a person would say it: "1h 30m", "10m", "45s".
function ns.FormatSpan(s)
    s = math.max(0, math.floor(s or 0))
    local d, h, m, sec = math.floor(s / 86400), math.floor(s % 86400 / 3600), math.floor(s % 3600 / 60), s % 60
    local out = {}
    if d > 0 then out[#out + 1] = d .. "d" end
    if h > 0 then out[#out + 1] = h .. "h" end
    if m > 0 then out[#out + 1] = m .. "m" end
    if sec > 0 or #out == 0 then out[#out + 1] = sec .. "s" end
    return table.concat(out, " ")
end

function ns.AnyDay(days)
    if type(days) ~= "table" then return false end
    for i = 1, 7 do if days[i] then return true end end
    return false
end

function ns.DaysText(days)
    if not ns.AnyDay(days) then return nil end
    local list, n = {}, 0
    for _, w in ipairs(ns.DAY_ORDER) do
        if days[w] then n = n + 1; list[#list + 1] = ns.DAY_SHORT[w] end
    end
    if n == 7 then return "every day" end
    if n == 5 and not days[1] and not days[7] then return "weekdays" end
    if n == 2 and days[1] and days[7] then return "weekends" end
    return table.concat(list, " ")
end

-- "1h30m", "90s", "2h", "45", "1:30" (hours and minutes). A bare number
-- is minutes, the unit a player means nine times in ten.
function ns.ParseDuration(s)
    s = Core.trim(tostring(s or "")):lower():gsub("%s+", "")
    if s == "" then return nil end
    local h, m = s:match("^(%d+):(%d%d)$")
    if h then return tonumber(h) * 3600 + tonumber(m) * 60 end
    if s:match("^%d+$") then return tonumber(s) * 60 end
    local total, rest = 0, s
    local UNIT = { d = 86400, h = 3600, m = 60, s = 1 }
    while rest ~= "" do
        local n, u, after = rest:match("^(%d+)([dhms])[a-z]*(.*)$")
        if not n then return nil end
        total = total + tonumber(n) * UNIT[u]
        rest = after
    end
    return total > 0 and total or nil
end

-- "20:30", "8:30pm", "8pm", "8 PM". Returns hour, minute.
function ns.ParseClock(s)
    s = Core.trim(tostring(s or "")):lower():gsub("%s+", ""):gsub("%.", "")
    local h, m, ap = s:match("^(%d%d?):(%d%d)([ap]?)m?$")
    if not h then
        h, ap = s:match("^(%d%d?)([ap])m?$")
        m = "0"
    end
    h, m = tonumber(h), tonumber(m)
    if not h or not m or m > 59 then return nil end
    if ap == "a" or ap == "p" then
        if h < 1 or h > 12 then return nil end
        if ap == "a" then h = (h == 12) and 0 or h else h = (h == 12) and 12 or h + 12 end
    elseif h > 23 then
        return nil
    end
    return h, m
end

-- The next time an alarm goes off after `from`. With no days picked it is
-- the next time the clock reads hour:minute; with days, the next of those.
function ns.NextAlarm(hour, minute, days, from)
    local off = ns.AlarmOffset()
    local shifted = (from or time()) + off
    local t = date("*t", shifted)
    local any = ns.AnyDay(days)
    for add = 0, 8 do
        local cand = time({ year = t.year, month = t.month, day = t.day + add, hour = hour, min = minute, sec = 0 })
        if cand > shifted and (not any or days[date("*t", cand).wday]) then
            return cand - off
        end
    end
end

-- What a reminder waits for, without the countdown.
function ns.Schedule(r)
    if r.kind == "timer" then
        return (r.repeats and "every " or "") .. ns.FormatSpan(r.duration)
    elseif r.kind == "alarm" then
        local days = ns.DaysText(r.days)
        return ns.FormatClock(r.hour or 0, r.min or 0) .. (days and (", " .. days) or "")
    end
    local t = ns.TRIGGER[r.trigger]
    local s
    if r.trigger == "zone" then s = "When I enter " .. tostring(r.arg or "a zone")
    elseif r.trigger == "level" then s = "When I reach level " .. tostring(r.arg or "?")
    else s = t and t.label or tostring(r.trigger) end
    return s .. (r.repeats and ", every time" or "")
end

-- What the list says about a reminder: where it stands, then its schedule.
function ns.Describe(r, now)
    now = now or time()
    if r.snoozeUntil then return "Snoozed, " .. ns.FormatLeft(r.snoozeUntil - now) end
    if r.done then return "Done" .. (r.lastFired and (" at " .. ns.FormatStamp(r.lastFired)) or "") .. ". Tick to start it again." end
    if not r.enabled then return "Off: " .. ns.Schedule(r) end
    if r.kind == "timer" then
        return "In " .. ns.FormatLeft((r.due or now) - now) .. (r.repeats and (", every " .. ns.FormatSpan(r.duration)) or "")
    end
    local s = ns.Schedule(r)
    if r.due then s = s .. ", in " .. ns.FormatLeft(r.due - now) end
    return s
end

-- The next moment a reminder goes off, or nil for one that waits on an event.
function ns.NextUp(r)
    if not ns.Mine(r) then return nil end
    if r.snoozeUntil then return r.snoozeUntil end
    if r.enabled and not r.done then return r.due end
end

-- ============================================================
-- The model
-- ============================================================

local function timedDue(r, now)
    local t = ns.TRIGGER[r.trigger]
    if not (t and t.timed) then return nil end
    local s = t.timed()
    if not s then return nil end
    -- Right on the reset the client can answer zero or a whole period.
    if s < 60 then s = s + t.period end
    return now + s
end

-- Inside the zone a zone reminder names, as of the last look.
ns.zoneIn = {}

local function zoneNames()
    local out = {}
    for _, fn in ipairs({ "GetRealZoneText", "GetZoneText", "GetSubZoneText", "GetMinimapZoneText" }) do
        local f = rawget(_G, fn)
        local n = f and f()
        if type(n) == "string" and n ~= "" then out[#out + 1] = n:lower() end
    end
    return out
end

local function inZone(r, names)
    local want = Core.trim(tostring(r.arg or "")):lower()
    if want == "" then return false end
    for _, n in ipairs(names) do if n == want then return true end end
    return false
end

-- Start a reminder from now: a timer runs its full length again, an alarm
-- finds its next time, an event reminder waits afresh.
function ns:Arm(r, now)
    now = now or time()
    r.enabled, r.done, r.snoozeUntil = true, nil, nil
    if r.kind == "timer" then
        r.due = now + math.max(1, tonumber(r.duration) or 60)
    elseif r.kind == "alarm" then
        r.due = ns.NextAlarm(r.hour or 0, r.min or 0, r.days, now)
    else
        r.due = timedDue(r, now)
        -- Already standing in the zone does not count as entering it.
        if r.trigger == "zone" then ns.zoneIn[r.id] = inZone(r, zoneNames()) end
    end
end

-- Moves a reminder on once it has gone off at its proper time: a repeating
-- one to its next time, anything else to done.
local function advance(r, now)
    if r.kind == "timer" then
        if r.repeats then
            local d, step = r.due or now, math.max(1, tonumber(r.duration) or 60)
            while d <= now do d = d + step end
            r.due = d
            return
        end
    elseif r.kind == "alarm" then
        if ns.AnyDay(r.days) then
            r.due = ns.NextAlarm(r.hour or 0, r.min or 0, r.days, now)
            return
        end
    elseif r.repeats then
        r.due = timedDue(r, now)
        return
    end
    r.done, r.due = true, nil
end

-- opts: missed (it came due while away), snooze (a snooze ran out),
-- test (nothing is changed, only shown).
function ns:Fire(r, opts)
    opts = opts or {}
    local now = time()
    if not opts.test then
        if not opts.snooze then advance(r, now) end
        r.snoozeUntil = nil
        r.lastFired = now
        ns.Dirty()
    end
    local db = ns.DB()
    if opts.missed and not db.missed then
        self:Refresh()
        return
    end
    if db.chat then
        local when = opts.missed and opts.at and (Chrome:Esc("muted") .. " (came due at " .. ns.FormatStamp(opts.at) .. " while you were away)|r") or ""
        A:Print(Chrome:Esc("text") .. tostring(r.text) .. "|r" .. when)
    end
    if db.raidNotice and ns.Alert then ns.Alert:Banner(tostring(r.text)) end
    if db.flash then
        local flash = rawget(_G, "FlashClientIcon")
        if flash then pcall(flash) end
    end
    if db.sound then ns.PlaySound(r.sound or ns.KINDS[r.kind].sound, opts.test) end
    if ns.Alert then ns.Alert:Show(r, opts) end
    self:Refresh()
end

function ns:Add(r)
    local db = ns.DB()
    r.id = db.nextId
    db.nextId = db.nextId + 1
    r.created = time()
    r.owner = r.owner or ns.CharKey()
    r.sound = r.sound or ns.KINDS[r.kind].sound
    table.insert(db.reminders, r)
    self:Arm(r)
    ns.Dirty()
    self:Refresh()
    return r
end

function ns:Get(id)
    for _, r in ipairs(ns.DB().reminders) do if r.id == id then return r end end
end

function ns:Remove(r)
    local list = ns.DB().reminders
    for i = #list, 1, -1 do
        if list[i] == r or list[i].id == r.id then table.remove(list, i) end
    end
    ns.zoneIn[r.id] = nil
    if ns.Alert then ns.Alert:Forget(r.id) end
    ns.Dirty()
    self:Refresh()
end

function ns:SetEnabled(r, on)
    if on then
        self:Arm(r)
    else
        r.enabled, r.due, r.snoozeUntil = false, nil, nil
        if ns.Alert then ns.Alert:Forget(r.id) end
    end
    ns.Dirty()
    self:Refresh()
end

function ns:Snooze(r, minutes)
    minutes = minutes or ns.DB().snoozeMinutes or 10
    r.snoozeUntil = time() + minutes * 60
    ns.Dirty()
    self:Refresh()
end

-- The fields that decide when a reminder goes off. Editing anything else
-- (the words, the sound) leaves a running reminder running.
function ns.ScheduleKey(r)
    local days = {}
    for i = 1, 7 do days[i] = (type(r.days) == "table" and r.days[i]) and "1" or "0" end
    return table.concat({ tostring(r.kind), tostring(r.duration), tostring(r.hour), tostring(r.min),
        table.concat(days), tostring(r.trigger), tostring(r.arg), tostring(r.repeats and true or false) }, "|")
end

-- Save a reminder the editor built. A new one gets an id and starts; an
-- edited one restarts only if its schedule changed or it was not running.
function ns:Save(draft)
    local r = draft.id and self:Get(draft.id)
    if not r then
        draft.id = nil
        return self:Add(draft)
    end
    local before = ns.ScheduleKey(r)
    local wasRunning = r.enabled and not r.done
    for _, k in ipairs({ "text", "kind", "duration", "hour", "min", "days", "trigger", "arg", "repeats", "scope", "owner", "sound" }) do
        r[k] = draft[k]
    end
    if before ~= ns.ScheduleKey(r) or not wasRunning then self:Arm(r) end
    ns.Dirty()
    self:Refresh()
    return r
end

-- Done ones, swept away.
function ns:ClearDone()
    local list, n = ns.DB().reminders, 0
    for i = #list, 1, -1 do
        local r = list[i]
        if r.done and not r.snoozeUntil and ns.Mine(r) then
            table.remove(list, i)
            n = n + 1
        end
    end
    ns.Dirty()
    self:Refresh()
    return n
end

-- Mine, in the order the list shows them: what goes off soonest, then what
-- waits on an event, then what is off, then what is done.
function ns:Sorted()
    local out = {}
    for _, r in ipairs(ns.DB().reminders) do
        if ns.Mine(r) then out[#out + 1] = r end
    end
    local function rank(r)
        if r.snoozeUntil then return 1 end
        if r.done then return 4 end
        if not r.enabled then return 3 end
        return r.due and 1 or 2
    end
    table.sort(out, function(a, b)
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        local da, db = ns.NextUp(a), ns.NextUp(b)
        if da and db and da ~= db then return da < db end
        if ra == 4 then return (a.lastFired or 0) > (b.lastFired or 0) end
        return (a.id or 0) < (b.id or 0)
    end)
    return out
end

function ns:Refresh()
    if ns.UI and ns.UI.Refresh then ns.UI:Refresh() end
    ns:UpdateBroker()
end

-- ============================================================
-- The clock tick and the triggers
-- ============================================================

function ns:Tick()
    local now = time()
    if ns.ready then
        -- A copy, since a reminder that goes off can change the list.
        local list = {}
        for i, r in ipairs(ns.DB().reminders) do list[i] = r end
        for _, r in ipairs(list) do
            if ns.Mine(r) then
                if r.snoozeUntil then
                    if r.snoozeUntil <= now then
                        self:Fire(r, { snooze = true, missed = r.snoozeUntil < ns.sessionStart, at = r.snoozeUntil })
                    end
                elseif r.enabled and not r.done and r.due and r.due <= now then
                    self:Fire(r, { missed = r.due < ns.sessionStart, at = r.due })
                end
            end
        end
    end
    if ns.Alert then ns.Alert:Tick(now) end
    if ns.UI and ns.UI.Tick then ns.UI:Tick(now) end
    self:UpdateBroker(now)
end

-- Every running event reminder waiting on this trigger goes off.
function ns:Trigger(id, filter)
    if not ns.ready then return end
    for _, r in ipairs(ns:Sorted()) do
        if r.kind == "event" and r.trigger == id and r.enabled and not r.done and not r.snoozeUntil
           and (not filter or filter(r)) then
            self:Fire(r)
        end
    end
end

function ns:CheckZone(arriving)
    if not ns.ready then return end
    local names = zoneNames()
    for _, r in ipairs(ns:Sorted()) do
        if r.kind == "event" and r.trigger == "zone" and r.enabled and not r.done then
            local inside = inZone(r, names)
            local was = ns.zoneIn[r.id]
            if arriving then was = false end
            ns.zoneIn[r.id] = inside
            if inside and not was and not r.snoozeUntil then self:Fire(r) end
        end
    end
end

-- Timed triggers re-ask the client at login, in case the reset moved.
function ns:RefreshTimed()
    local now = time()
    for _, r in ipairs(ns.DB().reminders) do
        if r.kind == "event" and r.enabled and not r.done and r.due and r.due > now then
            r.due = timedDue(r, now) or r.due
        end
    end
end

-- Alarms re-read in a new clock when the realm clock setting changes.
function ns:RearmAlarms()
    local now = time()
    for _, r in ipairs(ns.DB().reminders) do
        if r.kind == "alarm" and r.enabled and not r.done then
            r.due = ns.NextAlarm(r.hour or 0, r.min or 0, r.days, now)
        end
    end
    ns.Dirty()
    self:Refresh()
end

for _, t in ipairs(ns.TRIGGERS) do
    if t.event and t.id ~= "combat" then
        A:On(t.event, function() ns:Trigger(t.id) end)
    end
end
A:On("PLAYER_REGEN_ENABLED", function() ns:Trigger("combat") end)
A:On("ZONE_CHANGED_NEW_AREA", function() ns:CheckZone() end)
A:On("ZONE_CHANGED", function() ns:CheckZone() end)
A:On("ZONE_CHANGED_INDOORS", function() ns:CheckZone() end)
A:On("PLAYER_UPDATE_RESTING", function()
    local resting = IsResting and IsResting() and true or false
    if resting and not ns.wasResting then ns:Trigger("rested") end
    ns.wasResting = resting
end)
A:On("PLAYER_LEVEL_UP", function(level)
    level = tonumber(level) or 0
    ns:Trigger("level", function(r) return (tonumber(r.arg) or 999) <= level end)
end)

-- The first time into the world is the login. A few seconds later, once
-- the screen has settled, anything that came due while away goes off,
-- then the login reminders, then the zone ones for where you stand.
A:On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
    if ns.entered then return end
    ns.entered = true
    local fresh = isLogin == true or (isLogin == nil and not isReload)
    C_Timer.After(3, function()
        ns.ready = true
        ns.wasResting = IsResting and IsResting() and true or false
        ns:RefreshTimed()
        ns:Tick()
        if fresh then ns:Trigger("login") end
        ns:CheckZone(true)
    end)
end)

-- ============================================================
-- Broker text
-- ============================================================

function ns:Upcoming(n)
    local now, out = time(), {}
    for _, r in ipairs(ns:Sorted()) do
        local at = ns.NextUp(r)
        if at then out[#out + 1] = { r = r, at = at, left = at - now } end
    end
    table.sort(out, function(a, b) return a.at < b.at end)
    while n and #out > n do table.remove(out) end
    return out
end

function ns:UpdateBroker(now)
    local entry = Core.Launcher and Core.Launcher.entries and Core.Launcher.entries[A.name]
    local obj = entry and entry.ldb
    if not obj or not ns.DB() then return end
    local next1 = ns:Upcoming(1)[1]
    local text = next1 and ns.FormatShort(next1.at - (now or time())) or ""
    if obj.text ~= text then obj.text = text end
end

-- ============================================================
-- Slash command: the quick way in, and the scripting surface
-- ============================================================

local HELP = {
    "/remind  opens the window",
    "/remind 10m check the auction house  (a timer: 90s, 45m, 1h30m)",
    "/remind every 30m stretch  (a timer that starts again)",
    "/remind 20:30 raid invites  (an alarm, also 8:30pm)",
    "/remind daily 20:30 raid invites  (an alarm every day)",
    "/remind login check the mail  (the next time you log in)",
    "/remind list | test | options",
    "/reminder, /reminders and /wrem work the same.",
}

local function confirm(r)
    local when = ns.Describe(r):gsub("^In ", "in ")
    A:Print(("%s set: %s%s|r, %s."):format(ns.KINDS[r.kind].label, Chrome:Esc("fel"), r.text, when))
end

-- The leading time and the words after it. "8 pm raid" keeps the pm
-- with the hour.
local function splitLead(s)
    local c, ap, text = s:match("^(%d%d?:?%d*)%s*([aApP][mM])%s+(.*)$")
    if c then return c .. ap, text end
    c, ap = s:match("^(%d%d?:?%d*)%s*([aApP][mM])$")
    if c then return c .. ap, "" end
    return s:match("^(%S+)%s*(.*)$")
end

local function isClock(s)
    return s:find(":", 1, true) or s:lower():find("[ap]m?$")
end

function ns:Command(msg)
    msg = Core.trim(msg or "")
    local lower = msg:lower()
    if msg == "" then if ns.UI then ns.UI:Toggle() end return end
    if lower == "help" or lower == "?" then
        for _, line in ipairs(HELP) do A:Print(line) end
        return
    end
    if lower == "options" or lower == "config" then A:OpenOptions() return end
    if lower == "test" then if ns.Alert then ns.Alert:Test() end return end
    if lower == "list" then
        local list = ns:Sorted()
        if #list == 0 then A:Print("nothing set. /remind help shows how.") return end
        for _, r in ipairs(list) do
            A:Print(("%s%s|r %s  %s%s|r"):format(Chrome:Esc("fel"), ns.KINDS[r.kind].tag, r.text, Chrome:Esc("muted"), ns.Describe(r)))
        end
        return
    end

    local first, rest = msg:match("^(%S+)%s*(.*)$")
    local f = first:lower()
    if f == "every" then
        local span, text = rest:match("^(%S+)%s*(.*)$")
        local secs = ns.ParseDuration(span)
        if not secs then A:Print("every how long? e.g. /remind every 30m stretch") return end
        confirm(ns:Add({ kind = "timer", duration = secs, repeats = true, text = text ~= "" and text or "Time's up", enabled = true }))
        return
    end
    if f == "daily" then
        local clock, text = splitLead(rest)
        local h, m = ns.ParseClock(clock)
        if not h then A:Print("daily at what time? e.g. /remind daily 20:30 raid invites") return end
        confirm(ns:Add({ kind = "alarm", hour = h, min = m, days = { true, true, true, true, true, true, true },
            text = (text and text ~= "") and text or "Alarm", enabled = true }))
        return
    end
    if f == "login" then
        confirm(ns:Add({ kind = "event", trigger = "login", text = rest ~= "" and rest or "Logged in", enabled = true }))
        return
    end
    first, rest = splitLead(msg)
    local h, m = ns.ParseClock(first)
    if h and isClock(first) then
        confirm(ns:Add({ kind = "alarm", hour = h, min = m, text = rest ~= "" and rest or "Alarm", enabled = true }))
        return
    end
    local secs = ns.ParseDuration(first)
    if secs then
        confirm(ns:Add({ kind = "timer", duration = secs, text = rest ~= "" and rest or "Time's up", enabled = true }))
        return
    end
    A:Print("not sure when you mean. /remind help shows the forms it knows.")
end

-- /reminder and /reminders too: the name of the thing is what people type.
A:RegisterSlash(function(_, msg) ns:Command(msg) end, "/remind", "/wrem", "/reminder", "/reminders")

-- ============================================================
-- Lifecycle, options page, launcher
-- ============================================================

function A:OnEnable()
    -- Saved reminders from before a field existed get it now.
    local top = ns.MaxLevel()
    for _, r in ipairs(ns.DB().reminders) do
        if r.enabled == nil then r.enabled = true end
        r.sound = r.sound or (ns.KINDS[r.kind] and ns.KINDS[r.kind].sound) or "alarm"
        -- A level past the cap could never be reached. The first build
        -- offered "your level + 1" even at the cap.
        if r.trigger == "level" and (tonumber(r.arg) or 0) > top then r.arg = top end
    end

    if C_Timer and C_Timer.NewTicker then
        ns.ticker = C_Timer.NewTicker(1, function() ns:Tick() end)
    end

    self:RegisterLauncher({
        icon = "Interface\\Icons\\INV_Misc_PocketWatch_01",
        onClick = function(addon, button)
            if button == "RightButton" then addon:OpenOptions()
            elseif ns.UI then ns.UI:Toggle() end
        end,
        tooltip = function(tt)
            tt:AddLine(Chrome:TitleMarkup("Wick's Reminders"))
            local up = ns:Upcoming(5)
            if #up == 0 then
                tt:AddLine("Nothing counting down.", 0.56, 0.53, 0.44)
            end
            for _, u in ipairs(up) do
                local c = Chrome.Colors.text
                tt:AddDoubleLine(u.r.text, ns.FormatShort(u.left), c[1], c[2], c[3], 0.31, 0.78, 0.47)
            end
            tt:AddLine(" ")
            tt:AddLine("Left-click: reminders   Right-click: options", 0.5, 0.5, 0.5)
        end,
    })

    self:RegisterOptions(function(page)
        local O = Core.Options
        local function check(label, key, y, after)
            return O:Check(page, label, function() return ns.DB()[key] == true end,
                function(v) ns.DB()[key] = v and true or false; if after then after(v) end end, y)
        end

        local y = O:Button(page, "Open Wick's Reminders", function() if ns.UI then ns.UI:Show() end end, 0, 170)

        y = O:Heading(page, "When a reminder goes off", y - 6)
        y = check("Play its sound", "sound", y)
        y = check("Keep ringing until I answer an alarm", "ringAlarms", y)
        y = O:Note(page, "Every few seconds for up to a minute, until you press Snooze or Done.", y)
        y = check("Flash the words in large letters", "raidNotice", y)
        y = check("Print it in chat", "chat", y)
        y = check("Flash the game on the taskbar", "flash", y)
        y = O:Note(page, "Only shows while the game is in the background.", y)
        y = O:Stepper(page, "Snooze for (minutes)", function() return ns.DB().snoozeMinutes end,
            function(v) ns.DB().snoozeMinutes = math.max(1, math.min(120, v)) end, y, { step = 1 })
        y = O:Button(page, "Test the alert", function() if ns.Alert then ns.Alert:Test() end end, y - 4, 130)
        y = O:Button(page, "Put the alert back", function() if ns.Alert then ns.Alert:ResetPosition() end end, y, 130)
        y = O:Note(page, "Drag an alert by its title to move where they appear.", y)

        y = O:Heading(page, "While you were away", y - 6)
        y = check("Show what came due while I was logged out", "missed", y)
        y = O:Note(page, "Timers and alarms keep counting while you are offline. With this off, the ones that came due are quietly moved on to their next time.", y)

        y = O:Heading(page, "Clock", y - 6)
        y = check("Alarms follow the realm's clock", "realmClock", y, function() ns:RearmAlarms() end)
        local t = date("*t", time())
        local off = ns.RealmOffset()
        local r = date("*t", time() + off)
        y = O:Note(page, off == 0
            and ("Your computer and the realm agree: it is " .. ns.FormatClock(t.hour, t.min) .. ".")
            or ("Your computer says " .. ns.FormatClock(t.hour, t.min) .. " and the realm says " .. ns.FormatClock(r.hour, r.min) .. "."), y)
        y = O:Note(page, "Times are written the way the game clock is set to show them, 12 or 24 hour.", y)
    end)
end
