-- Chum Chimes
-- A friendly little chime when your guildies or friends are around:
--   * "Zone" chime: one of them is in the same zone as you.
--   * "Nearby" chime: one of them is right near you (their nameplate shows up,
--     or you mouse over or target them).
-- Everything runs off game events. The only timer is an optional, gentle
-- "where is everyone?" request to the server every 2 minutes, because the
-- game doesn't tell addons when a guildie changes zones.

local ADDON = ...

---------------------------------------------------------------------------
-- Settings and constants
---------------------------------------------------------------------------
local DB_DEFAULTS = {
    enabled        = true,     -- master switch
    guild          = true,     -- chime for guild members
    friends        = true,     -- chime for WoW (character) friends
    bnet           = true,     -- chime for Battle.net friends playing this same game
    zonePings      = true,     -- chime when one is in my zone
    nearbyPings    = true,     -- chime when one is right near me
    arrivalSummary = true,     -- one summary line when I arrive in a zone, not one chime per person
    guildCheck     = true,     -- ask the server where guildies are every 2 minutes
    quietInstances = true,     -- no chimes in dungeons, raids, delves, battlegrounds, arenas
    skipGroup      = true,     -- no chimes for people already in my party or raid
    onScreen       = true,     -- also flash the line in the middle of the screen
    cooldown       = 10,       -- minutes before the same person can chime again
    zoneSound      = "toast",
    nearbySound    = "ping",
    nearbyRange    = "close",  -- "close" (~28 yd), "veryclose" (~10 yd) or "plate" (as soon as the nameplate shows)
    showMinimap    = true,
}

local MASCOT      = "Interface\\AddOns\\" .. ADDON .. "\\Media\\chumchimes"
local COLORS      = { main = "5FD35A", accent = "F2C66B", name = "FFFFFF", gray = "9A9A9A" }
local CHECK_EVERY = 120    -- seconds between gentle guild/friends zone requests
local ARRIVE_WAIT = 6      -- seconds to collect "who's here" after you change zones
local LOGIN_WAIT  = 10     -- a little longer right after logging in, while the lists load
local MAX_NAMES   = 5      -- names shown in a summary line before "and X more"
local SOUND_GAP   = 2      -- never play two chimes closer together than this

-- Sound choices. SOUNDKIT names first, with the plain number as a backup.
local SOUNDS = {
    { key = "toast",  label = "Friend toast",   kit = "UI_BNET_TOAST",  id = 18019 },
    { key = "ping",   label = "Map ping",       kit = "MAP_PING",       id = 3175 },
    { key = "whisper", label = "Whisper ding",  kit = "TELL_MESSAGE",   id = 3081 },
    { key = "ready",  label = "Ready check",    kit = "READY_CHECK",    id = 8960 },
    { key = "none",   label = "No sound" },
}

-- The fun part. %s = name, %z = zone
local ZONE_LINES = {
    "%s just showed up in %z!",
    "%s is here in %z too!",
    "Look who's in %z: %s!",
    "Hey! %s is in %z!",
}
local NEARBY_LINES = {
    "%s is right near you! Wave hello!",
    "Psst! %s is right by you!",
    "%s is close enough for a hug!",
    "Your chum %s is right here!",
}

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------
local function Hex(h)
    return tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255
end

local function Color(hex, text)
    return "|cff" .. hex .. text .. "|r"
end

local function Print(msg)
    print(Color(COLORS.main, "Chum Chimes:") .. " " .. msg)
end

-- Midnight hides some values from addons ("secret values"). Never act on one.
local function IsSecret(value)
    return issecretvalue and issecretvalue(value) or false
end

local function MyRealm()
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if not realm or realm == "" then realm = (GetRealmName() or ""):gsub("[%s%-]", "") end
    return realm
end

-- "Name-Realm", the same way every list spells it, so one person = one key
local function FullName(name, realm)
    if not name or name == "" then return nil end
    if name:find("-", 1, true) then return name end
    if not realm or realm == "" then realm = MyRealm() end
    return name .. "-" .. realm:gsub("[%s%-]", "")
end

local function ShortName(full)
    return (full:match("^([^%-]+)")) or full
end

-- The lookup key for a person: lowercase, with spaces and punctuation dropped
-- from the realm, because different lists spell realm names slightly differently
-- (WoW Forever especially). "Varala-Wyrmrest Accord" and "Varala-WyrmrestAccord"
-- both become "varala-wyrmrestaccord".
local function Key(full)
    if not full then return nil end
    local name, realm = full:match("^([^%-]+)%-(.*)$")
    if not name then name, realm = full, MyRealm() end
    return (name:lower()) .. "-" .. (realm:lower():gsub("[^%w]", ""))
end

local function MyKey()
    local name, realm = UnitName("player")
    return Key(FullName(name, realm))
end

-- Is this me? Checked by the character's unique ID when the list gives one,
-- and by name too, so you never get a chime about yourself.
local function IsMe(key, guid, me)
    if guid and not IsSecret(guid) and guid == UnitGUID("player") then return true end
    return key == me
end

local function SameGameFlavor(projectID)
    return projectID == nil or WOW_PROJECT_ID == nil or projectID == WOW_PROJECT_ID
end

local function InQuietPlace()
    if not ChumChimesDB.quietInstances then return false end
    local inInstance, kind = IsInInstance()
    return inInstance and kind ~= "none"
end

local function InMyGroup(full)
    if not ChumChimesDB.skipGroup then return false end
    local ok, result = pcall(function()
        local short = Ambiguate and Ambiguate(full, "none") or full
        return UnitInParty(short) or UnitInRaid(short)
    end)
    return ok and result and true or false
end

local function MyZones()
    return GetRealZoneText and GetRealZoneText() or "", GetZoneText and GetZoneText() or ""
end

local function Pick(list)
    return list[math.random(#list)]
end

---------------------------------------------------------------------------
-- Sound and on-screen line
---------------------------------------------------------------------------
local lastSound = 0
local function PlayChime(key, force)
    if not force and GetTime() - lastSound < SOUND_GAP then return end
    for _, sound in ipairs(SOUNDS) do
        if sound.key == key then
            if not sound.id then return end
            local id = (SOUNDKIT and sound.kit and SOUNDKIT[sound.kit]) or sound.id
            pcall(PlaySound, id, "Master")
            lastSound = GetTime()
            return
        end
    end
end

local function OnScreen(text)
    if not ChumChimesDB.onScreen then return end
    if RaidNotice_AddMessage and RaidWarningFrame then
        pcall(RaidNotice_AddMessage, RaidWarningFrame, text, { r = 0.37, g = 0.83, b = 0.35 })
    end
end

-- A clickable name in chat: click it to whisper, right-click for the usual menu
local function NameLink(person)
    local shown = Color(COLORS.name, person.short)
    if person.tag then shown = shown .. Color(COLORS.gray, " (" .. person.tag .. ")") end
    return "|Hplayer:" .. (person.link or person.key) .. "|h" .. shown .. "|h"
end

local function Fill(line, person, zone)
    -- Built by hand rather than with format(), so names and zones are never read as codes
    local nameText = NameLink(person)
    local zoneText = Color(COLORS.accent, zone or "")
    local out = line:gsub("%%z", function() return zoneText end)
    out = out:gsub("%%s", function() return nameText end)
    return out
end

---------------------------------------------------------------------------
-- Cooldowns: each person can chime once per cooldown, for each kind of chime
---------------------------------------------------------------------------
local lastChime = { zone = {}, nearby = {} }

local function CoolingDown(kind, key)
    local last = lastChime[kind][key]
    return last and (GetTime() - last) < ChumChimesDB.cooldown * 60
end

local function MarkChimed(kind, key)
    lastChime[kind][key] = GetTime()
    -- If they're right next to you, a "they're in your zone" chime would be old news
    if kind == "nearby" then lastChime.zone[key] = GetTime() end
end

---------------------------------------------------------------------------
-- Chimes
---------------------------------------------------------------------------
local function ZoneChime(person, zone, isTest)
    if not isTest and CoolingDown("zone", person.key) then return end
    if not isTest then MarkChimed("zone", person.key) end
    local text = Fill(Pick(ZONE_LINES), person, zone)
    Print(text)
    OnScreen(text)
    PlayChime(ChumChimesDB.zoneSound, isTest)
end

local function NearbyChime(person, isTest)
    if not isTest and CoolingDown("nearby", person.key) then return end
    if not isTest then MarkChimed("nearby", person.key) end
    local text = Fill(Pick(NEARBY_LINES), person)
    Print(text)
    OnScreen(text)
    PlayChime(ChumChimesDB.nearbySound, isTest)
end

-- Arriving somewhere busy: one line and one chime for everyone who's already there
local function SummaryChime(people, zone, isTest)
    if #people == 0 then return end
    if #people == 1 then
        ZoneChime(people[1], zone, isTest)
        return
    end
    table.sort(people, function(a, b) return a.short < b.short end)
    local names = {}
    for i = 1, math.min(#people, MAX_NAMES) do
        names[#names + 1] = NameLink(people[i])
        if not isTest then MarkChimed("zone", people[i].key) end
    end
    local extra = #people - MAX_NAMES
    if not isTest then
        for i = MAX_NAMES + 1, #people do MarkChimed("zone", people[i].key) end
    end
    local list
    if extra > 0 then
        list = table.concat(names, ", ") .. " and " .. extra .. " more"
    else
        list = table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
    end
    Print("Your chums in " .. Color(COLORS.accent, zone) .. ": " .. list .. "!")
    OnScreen(#people .. " of your chums are in " .. zone .. "!")
    PlayChime(ChumChimesDB.zoneSound, isTest)
end

---------------------------------------------------------------------------
-- Who's in my zone? Reads the guild roster and friends lists the game
-- already keeps. Runs only when one of those lists changes.
---------------------------------------------------------------------------
local present = {}               -- key -> person, everyone in my zone right now
local arriving = nil             -- while set, newcomers are collected for one summary line
local arrivingZone = nil

-- full = "Name-Realm" (used for the lookup key). link = the name exactly as the
-- game's own list gave it, so clicking it to whisper works the same as there
-- (WoW Forever lists same-ruleset players with no realm, and allows last names).
local function AddPerson(found, full, link, short, tag, zone, kind)
    local key = Key(full)
    if not key or found[key] then return end
    found[key] = { key = key, link = link or full, short = short or ShortName(full), tag = tag, zone = zone, kind = kind }
end

local function ReadGuild(found, zoneA, zoneB, me)
    if not (ChumChimesDB.guild and IsInGuild and IsInGuild()) then return end
    for i = 1, GetNumGuildMembers() do
        local name, _, _, _, _, zone, _, _, online, _, _, _, _, isMobile, _, _, guid = GetGuildRosterInfo(i)
        if online and not isMobile and zone and (zone == zoneA or zone == zoneB) then
            local full = FullName(name)
            if full and not IsMe(Key(full), guid, me) then AddPerson(found, full, name, nil, nil, zone, "guild") end
        end
    end
end

local function ReadFriends(found, zoneA, zoneB, me)
    if not (ChumChimesDB.friends and C_FriendList and C_FriendList.GetNumFriends) then return end
    for i = 1, C_FriendList.GetNumFriends() do
        local info = C_FriendList.GetFriendInfoByIndex(i)
        if info and info.connected and info.area and (info.area == zoneA or info.area == zoneB) then
            local full = FullName(info.name)
            if full and not IsMe(Key(full), info.guid, me) then AddPerson(found, full, info.name, nil, nil, info.area, "friend") end
        end
    end
end

local function BattleTagName(account)
    local tag = account and account.battleTag
    return tag and tag:match("^([^#]+)") or nil
end

local function ReadBnet(found, zoneA, zoneB, me)
    if not (ChumChimesDB.bnet and C_BattleNet and C_BattleNet.GetFriendAccountInfo and BNGetNumFriends) then return end
    local _, numOnline = BNGetNumFriends()
    for i = 1, numOnline or 0 do
        local account = C_BattleNet.GetFriendAccountInfo(i)
        local numGames = C_BattleNet.GetFriendNumGameAccounts and C_BattleNet.GetFriendNumGameAccounts(i) or 0
        for j = 1, numGames do
            local game = C_BattleNet.GetFriendGameAccountInfo(i, j)
            if game and game.isOnline and game.clientProgram == (BNET_CLIENT_WOW or "WoW")
                and SameGameFlavor(game.wowProjectID) and game.characterName
                and game.areaName and (game.areaName == zoneA or game.areaName == zoneB) then
                local full = FullName(game.characterName, game.realmName)
                if full and not IsMe(Key(full), game.playerGuid, me) then
                    AddPerson(found, full, nil, game.characterName, BattleTagName(account), game.areaName, "bnet")
                end
            end
        end
    end
end

local function FinishArriving()
    if not arriving then return end
    local people, zone = arriving, arrivingZone
    arriving, arrivingZone = nil, nil
    if not (ChumChimesDB.enabled and ChumChimesDB.zonePings) or InQuietPlace() then return end
    local fresh = {}
    for _, person in ipairs(people) do
        if present[person.key] and not CoolingDown("zone", person.key) then fresh[#fresh + 1] = person end
    end
    SummaryChime(fresh, zone)
end

local function Refresh()
    if not ChumChimesDB.enabled then return end
    local zoneA, zoneB = MyZones()
    if zoneA == "" and zoneB == "" then return end
    local me = MyKey()
    local found = {}
    pcall(ReadGuild, found, zoneA, zoneB, me)
    pcall(ReadFriends, found, zoneA, zoneB, me)
    pcall(ReadBnet, found, zoneA, zoneB, me)

    local quiet = InQuietPlace() or not ChumChimesDB.zonePings
    for key, person in pairs(found) do
        if not present[key] and not quiet and not InMyGroup(person.link) then
            if arriving then
                arriving[#arriving + 1] = person
            else
                ZoneChime(person, person.zone)
            end
        end
    end
    present = found
end

-- Lists can update many times in a row; wait a moment and do the work once
local refreshQueued = false
local function QueueRefresh()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(1, function()
        refreshQueued = false
        Refresh()
    end)
end

local function AskServer()
    if not ChumChimesDB.enabled then return end
    if ChumChimesDB.guild and IsInGuild and IsInGuild() then
        if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() elseif GuildRoster then GuildRoster() end
    end
    if ChumChimesDB.friends and C_FriendList and C_FriendList.ShowFriends then C_FriendList.ShowFriends() end
end

-- You changed zones: start fresh, ask for up-to-date lists, then summarize who's here
local function StartArriving(wait)
    present = {}
    if ChumChimesDB.arrivalSummary then
        arriving = {}
        arrivingZone = (MyZones())
        C_Timer.After(wait, FinishArriving)
    else
        arriving = nil
    end
    AskServer()
    QueueRefresh()
end

---------------------------------------------------------------------------
-- Who's right near me? Checks one player at a time, only when the game
-- shows a new nameplate, or you mouse over or target someone.
---------------------------------------------------------------------------
local function CheckUnit(unit)
    if not (ChumChimesDB.enabled and ChumChimesDB.nearbyPings) or InQuietPlace() then return end
    if not UnitExists(unit) or not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then return end
    if ChumChimesDB.skipGroup and (UnitInParty(unit) or UnitInRaid(unit)) then return end

    local guid = UnitGUID(unit)
    local name, realm = UnitName(unit)
    if IsSecret(guid) or IsSecret(name) or IsSecret(realm) then return end
    local full = FullName(name, realm)
    local key = Key(full)
    -- Whisper link: just the name for your own realm/ruleset, Name-Realm otherwise
    local link = (realm and realm ~= "") and full or name
    if not key or CoolingDown("nearby", key) then return end

    local person
    if ChumChimesDB.bnet and C_BattleNet and C_BattleNet.GetAccountInfoByGUID and guid then
        local account = C_BattleNet.GetAccountInfoByGUID(guid)
        if account then person = { key = key, link = link, short = name, tag = BattleTagName(account) } end
    end
    if not person and ChumChimesDB.friends and C_FriendList and C_FriendList.IsFriend and guid
        and C_FriendList.IsFriend(guid) then
        person = { key = key, link = link, short = name }
    end
    if not person and ChumChimesDB.guild and UnitIsInMyGuild and UnitIsInMyGuild(unit) then
        person = { key = key, link = link, short = name }
    end
    if person then person.guid = guid end
    return person
end

-- How close is "right near me"? Uses the game's own interaction ranges.
-- 4 = follow range (about 28 yards), 3 = duel range (about 10 yards).
local RANGE_INDEX = { close = 4, veryclose = 3 }

local function CloseEnough(unit)
    local index = RANGE_INDEX[ChumChimesDB.nearbyRange]
    if not index then return true end                 -- "nameplate range": chime right away
    if InCombatLockdown() or not CheckInteractDistance then return false end
    local ok, inRange = pcall(CheckInteractDistance, unit, index)
    return ok and not IsSecret(inRange) and inRange and true or false
end

-- A chum's nameplate showed up but they're still far away: keep an eye on just
-- them, once a second, until they come close, walk off, or a minute goes by.
-- Strangers never get watched, and the timer only runs while someone is.
local WATCH_EVERY, WATCH_FOR = 1, 60
local watching = {}       -- nameplate unit -> { person, started }
local watchTicker

local function StopWatchingIfEmpty()
    if watchTicker and next(watching) == nil then
        watchTicker:Cancel()
        watchTicker = nil
    end
end

local function WatchTick()
    for unit, watch in pairs(watching) do
        local guid = UnitGUID(unit)
        if not UnitExists(unit) or IsSecret(guid) or guid ~= watch.person.guid
            or GetTime() - watch.started > WATCH_FOR or CoolingDown("nearby", watch.person.key) then
            watching[unit] = nil                      -- gone, someone else, too long, or already chimed
        elseif not InQuietPlace() and CloseEnough(unit) then
            watching[unit] = nil
            NearbyChime(watch.person)
        end
    end
    StopWatchingIfEmpty()
end

local function OnNameplate(unit)
    local person = CheckUnit(unit)
    if not person then return end
    if CloseEnough(unit) then
        NearbyChime(person)
        return
    end
    watching[unit] = { person = person, started = GetTime() }
    if not watchTicker then watchTicker = C_Timer.NewTicker(WATCH_EVERY, function() pcall(WatchTick) end) end
end

local function OnNameplateGone(unit)
    if watching[unit] then
        watching[unit] = nil
        StopWatchingIfEmpty()
    end
end

-- Mouseover and target: you're looking right at them, so chime right away
local function SafeCheckUnit(unit)
    local ok, person = pcall(CheckUnit, unit)
    if ok and person then NearbyChime(person) end
end

local function SafeNameplate(unit)
    pcall(OnNameplate, unit)
end

---------------------------------------------------------------------------
-- Friendly nameplates (needed for the "they just walked up" part of nearby chimes)
---------------------------------------------------------------------------
local NAMEPLATE_CVAR = "nameplateShowFriends"

local function FriendlyPlatesOn()
    return C_CVar and C_CVar.GetCVarBool and C_CVar.GetCVarBool(NAMEPLATE_CVAR)
end

local function TurnOnFriendlyPlates()
    if InCombatLockdown() then
        Print("can't change nameplates during combat. Try again after the fight.")
        return
    end
    if C_CVar and C_CVar.SetCVar then
        C_CVar.SetCVar(NAMEPLATE_CVAR, "1")
        Print("friendly nameplates are on. (Shift-V toggles them too.)")
    end
end

---------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------
local TEST_PERSON = { key = "Sunny-Test", short = "Sunny", tag = "Sunny" }

local function TestZone()
    ZoneChime(TEST_PERSON, (MyZones()) ~= "" and (MyZones()) or "Dornogal", true)
end

local function TestNearby()
    NearbyChime(TEST_PERSON, true)
end

local function TestSummary()
    local people = {
        { key = "Sunny-Test", short = "Sunny" },
        { key = "Maple-Test", short = "Maple" },
        { key = "Juniper-Test", short = "Juniper", tag = "Juni" },
    }
    SummaryChime(people, (MyZones()) ~= "" and (MyZones()) or "Dornogal", true)
end

---------------------------------------------------------------------------
-- Settings panel (Options > AddOns > NerdyBertie > Chum Chimes)
---------------------------------------------------------------------------
local settingsCategory
local SetMinimapShown   -- defined with the minimap button below

-- Shared "NerdyBertie" heading: whichever NerdyBertie addon loads first creates it.
-- Every NerdyBertie addon carries this same function, the same list, and the
-- same Media/workshop.tga image, so the page looks the same whoever builds it.
local WORKSHOP_ADDONS = {
    { name = "HandyNotes: Dive Bar Front Crawl",   folder = "HandyNotes_DiveBarCrawl" },
    { name = "HandyNotes: Seeking the Soulstones", folder = "HandyNotes_SeekingTheSoulstones" },
    { name = "ItemWatch",                          folder = "ItemWatch" },
    { name = "Boomkin Buff Watcher",               folder = "BoomkinBuffWatcher" },
    { name = "Holiday Herald",                     folder = "HolidayHerald" },
    { name = "Pinkies Up!",                        folder = "PinkiesUp" },
    { name = "Chum Chimes",                        folder = "ChumChimes" },
}

local function GetBrandCategory()
    if NerdyBertie_SettingsCategory then return NerdyBertie_SettingsCategory end
    local panel = CreateFrame("Frame")

    local mascot = panel:CreateTexture(nil, "ARTWORK")
    mascot:SetSize(80, 80)
    mascot:SetPoint("TOPLEFT", 16, -16)
    mascot:SetTexture("Interface\\AddOns\\" .. ADDON .. "\\Media\\workshop")

    local heading = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    heading:SetPoint("TOPLEFT", mascot, "TOPRIGHT", 14, -10)
    heading:SetText("NerdyBertie's Addon Workshop")

    local presents = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    presents:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -6)
    presents:SetText("presents...")

    local blurb = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    blurb:SetPoint("TOPLEFT", mascot, "BOTTOMLEFT", 0, -16)
    blurb:SetWidth(560)
    blurb:SetJustifyH("LEFT")
    blurb:SetText("Addons for quality of life improvements. If you'd like to check out my other addons, here's the list:")

    local lines = {}
    for i, addon in ipairs(WORKSHOP_ADDONS) do
        local line = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        line:SetPoint("TOPLEFT", (i == 1) and blurb or lines[i - 1], "BOTTOMLEFT", (i == 1) and 12 or 0, (i == 1) and -12 or -6)
        lines[i] = line
        line.addon = addon
    end

    local footer = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footer:SetPoint("TOPLEFT", lines[#lines], "BOTTOMLEFT", -12, -16)
    footer:SetWidth(560)
    footer:SetJustifyH("LEFT")
    footer:SetText("Find them all on CurseForge, Wago, and WoWInterface. Pick an installed one from the list on the left to see its settings.")

    -- Fill in the list, with "installed" marks. This runs right away, and again
    -- every time the page is shown, since other addons may load after this one.
    local function RefreshList()
        for i, line in ipairs(lines) do
            local loaded = C_AddOns and C_AddOns.IsAddOnLoaded(line.addon.folder)
            line:SetText(i .. ". " .. line.addon.name
                .. (loaded and "  |cff33ff33(installed)|r" or ""))
        end
    end
    RefreshList()
    panel:SetScript("OnShow", RefreshList)
    -- Start hidden so the first time the page is opened counts as "shown"
    panel:Hide()

    local category = Settings.RegisterCanvasLayoutCategory(panel, "NerdyBertie")
    Settings.RegisterAddOnCategory(category)
    NerdyBertie_SettingsCategory = category
    return category
end

local function OnSettingChanged(setting, variable, callback)
    if setting.SetValueChangedCallback then
        setting:SetValueChangedCallback(callback)
    elseif Settings.SetOnValueChangedCallback then
        Settings.SetOnValueChangedCallback(variable, callback)
    end
end

local function BuildSettings()
    local category, layout = Settings.RegisterVerticalLayoutSubcategory(GetBrandCategory(), "Chum Chimes")
    settingsCategory = category

    local function Register(key, label)
        return Settings.RegisterAddOnSetting(category, "ChumChimes_" .. key, key,
            ChumChimesDB, type(DB_DEFAULTS[key]), label, DB_DEFAULTS[key])
    end
    local function Checkbox(key, label, tooltip)
        local setting = Register(key, label)
        Settings.CreateCheckbox(category, setting, tooltip)
        return setting
    end
    local function Header(text)
        if CreateSettingsListSectionHeaderInitializer then
            layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
        end
    end
    local function Button(label, buttonText, onClick, tooltip)
        layout:AddInitializer(CreateSettingsButtonInitializer(label, buttonText, onClick, tooltip, true))
    end
    local function SoundDropdown(key, label, tooltip)
        local setting = Register(key, label)
        local function Options()
            local container = Settings.CreateControlTextContainer()
            for _, sound in ipairs(SOUNDS) do container:Add(sound.key, sound.label) end
            return container:GetData()
        end
        Settings.CreateDropdown(category, setting, Options, tooltip)
        -- Play the new choice so you can hear it right away
        OnSettingChanged(setting, "ChumChimes_" .. key, function(_, value) PlayChime(value, true) end)
    end

    Checkbox("enabled", "Chum Chimes on",
        "The main switch. Turn this off to silence every chime.")

    Header("Who to chime for")
    Checkbox("guild", "Guild members",
        "Chime for people in your guild.")
    Checkbox("friends", "WoW friends",
        "Chime for characters on your WoW friends list.")
    Checkbox("bnet", "Battle.net friends",
        "Chime for Battle.net friends who are playing this same version of WoW.")
    Checkbox("skipGroup", "Skip people already in my group",
        "No chimes for people in your party or raid. You already know they're with you!")

    Header("When to chime")
    Checkbox("zonePings", "When one is in my zone",
        "Chimes when a guildie or friend is in the same zone as you, whether they arrive or you do.")
    Checkbox("nearbyPings", "When one is right near me",
        "Chimes when their nameplate shows up, or when you mouse over or target them. For the nameplate part, friendly nameplates need to be on (Shift-V).")
    do
        local setting = Register("nearbyRange", "\"Right near me\" means")
        local function Options()
            local container = Settings.CreateControlTextContainer()
            container:Add("close", "Close (about 28 yards)")
            container:Add("veryclose", "Very close (about 10 yards)")
            container:Add("plate", "As soon as their nameplate shows")
            return container:GetData()
        end
        Settings.CreateDropdown(category, setting, Options,
            "How close a chum has to be before the \"right near me\" chime plays. Nameplates show up from quite far away, so Close waits until they're about follow distance. Mousing over or targeting them always chimes right away.")
    end
    Checkbox("arrivalSummary", "One summary line when I arrive somewhere busy",
        "When you change zones, everyone already there gets one line and one chime, like \"Your chums in Dornogal: Tom, Johnny and 3 more!\", instead of a chime for each person.")
    Checkbox("guildCheck", "Check where guildies are every 2 minutes",
        "The game doesn't tell addons when a guildie changes zones, so this asks the server for the guild and friends lists every 2 minutes. It's one small request, the same one the guild window makes. Battle.net friends update on their own either way. Turn this off and zone chimes for guild and WoW friends happen only when the lists refresh for some other reason, like when you change zones.")
    Checkbox("quietInstances", "Stay quiet in dungeons, raids, delves and battlegrounds",
        "No chimes inside instances. Your group is right there anyway.")

    Header("How it chimes")
    SoundDropdown("zoneSound", "Sound for \"in my zone\"",
        "Plays when a chum is in your zone. You'll hear it when you pick it.")
    SoundDropdown("nearbySound", "Sound for \"right near me\"",
        "Plays when a chum is right near you. You'll hear it when you pick it.")
    Checkbox("onScreen", "Also show it in the middle of the screen",
        "Flashes the line in the middle of your screen as well as in your chat window.")
    do
        local setting = Register("cooldown", "Minutes before the same person chimes again")
        local options = Settings.CreateSliderOptions(1, 60, 1)
        if MinimalSliderWithSteppersMixin and options.SetLabelFormatter then
            options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value) return value .. " min" end)
        end
        Settings.CreateSlider(category, setting, options,
            "After someone chimes, they stay quiet this long, so a guildie running back and forth doesn't ding you over and over. Zone and nearby chimes are counted separately.")
    end
    do
        local setting = Checkbox("showMinimap", "Minimap button",
            "Show the Chum Chimes button on the minimap. Left-click it for settings, right-click to hear both test chimes.")
        OnSettingChanged(setting, "ChumChimes_showMinimap", function(_, value) SetMinimapShown(value) end)
    end

    Header("Try it out")
    Button("Test \"in my zone\"", "Play it", TestZone, "Shows and plays a pretend zone chime.")
    Button("Test \"right near me\"", "Play it", TestNearby, "Shows and plays a pretend nearby chime.")
    Button("Test the summary line", "Play it", TestSummary, "Shows and plays a pretend \"arrived somewhere busy\" summary.")
    Button("Friendly nameplates", "Turn them on", TurnOnFriendlyPlates,
        "Nearby chimes notice a chum walking up when their nameplate appears, so friendly nameplates need to be on. You can also toggle them with Shift-V.")
end

local function SetUpSettings()
    -- If the settings system is missing or different, slash commands still work
    if not (Settings and Settings.RegisterVerticalLayoutSubcategory) then return end
    local ok, err = pcall(BuildSettings)
    if not ok then Print("settings page couldn't be built (" .. tostring(err) .. ")") end
end

local function OpenSettings()
    if settingsCategory and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(settingsCategory:GetID())
    else
        Print("type /chum test to hear the chimes, or /chum help for commands.")
    end
end

---------------------------------------------------------------------------
-- Minimap button and addon compartment (the puzzle-piece menu by the minimap)
-- Left-click opens settings, right-click plays both test chimes.
---------------------------------------------------------------------------
local function HandleIconClick(button)
    if button == "RightButton" then
        TestZone()
        C_Timer.After(SOUND_GAP + 0.5, TestNearby)
    else
        OpenSettings()
    end
end

local function AddIconTooltip(tooltip)
    tooltip:AddLine("Chum Chimes", Hex(COLORS.main))
    tooltip:AddLine("Left-click: open settings", 0.8, 0.8, 0.8)
    tooltip:AddLine("Right-click: hear the test chimes", 0.8, 0.8, 0.8)
end

-- Behind-the-scenes name. It deliberately avoids the letters "Pin": some minimap
-- button bars skip anything with "Pin" in its name, thinking it's a map pin.
local ICON_NAME = "NerdyBertieChumBell"

local function CreateMinimapButton()
    local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
    local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not LDB or not DBIcon then return end

    local dataObject = LDB:NewDataObject(ICON_NAME, {
        type = "launcher",
        label = "Chum Chimes",
        icon = MASCOT,
        OnClick = function(_, button) HandleIconClick(button) end,
        OnTooltipShow = AddIconTooltip,
    })
    ChumChimesDB.minimapIcon.hide = not ChumChimesDB.showMinimap
    DBIcon:Register(ICON_NAME, dataObject, ChumChimesDB.minimapIcon)
end

SetMinimapShown = function(shown)
    local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    ChumChimesDB.minimapIcon.hide = not shown
    if DBIcon then
        if shown then DBIcon:Show(ICON_NAME) else DBIcon:Hide(ICON_NAME) end
    end
end

-- These must be true globals: the .toc refers to them by name
function ChumChimes_OnAddonCompartmentClick(_, button)
    HandleIconClick(button)
end

function ChumChimes_OnAddonCompartmentEnter(_, button)
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    AddIconTooltip(GameTooltip)
    GameTooltip:Show()
end

function ChumChimes_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local LIST_EVENTS = {
    "GUILD_ROSTER_UPDATE", "FRIENDLIST_UPDATE",
    "BN_FRIEND_INFO_CHANGED", "BN_FRIEND_ACCOUNT_ONLINE", "BN_FRIEND_ACCOUNT_OFFLINE",
}
local UNIT_EVENTS = { "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "UPDATE_MOUSEOVER_UNIT", "PLAYER_TARGET_CHANGED" }

local events = CreateFrame("Frame")

local function SafeRegister(event)
    pcall(events.RegisterEvent, events, event)
end

local function GentleCheck()
    if ChumChimesDB.guildCheck and ChumChimesDB.zonePings and not InQuietPlace() then AskServer() end
end

events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        ChumChimesDB = ChumChimesDB or {}
        for key, value in pairs(DB_DEFAULTS) do
            if ChumChimesDB[key] == nil then ChumChimesDB[key] = value end
        end
        ChumChimesDB.minimapIcon = ChumChimesDB.minimapIcon or {}
        SetUpSettings()
        CreateMinimapButton()
        for _, e in ipairs(LIST_EVENTS) do SafeRegister(e) end
        for _, e in ipairs(UNIT_EVENTS) do SafeRegister(e) end
        SafeRegister("PLAYER_ENTERING_WORLD")
        SafeRegister("ZONE_CHANGED_NEW_AREA")
        C_Timer.NewTicker(CHECK_EVERY, GentleCheck)
        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_ENTERING_WORLD" then
        local isLogin, isReload = arg1, arg2
        StartArriving((isLogin or isReload) and LOGIN_WAIT or ARRIVE_WAIT)
        -- One-time tip about friendly nameplates
        if isLogin and ChumChimesDB.nearbyPings and not ChumChimesDB.plateTipShown and not FriendlyPlatesOn() then
            ChumChimesDB.plateTipShown = true
            C_Timer.After(LOGIN_WAIT + 2, function()
                Print("tip: turn on friendly nameplates (Shift-V) so I can chime the moment a chum walks up. Mouseover and target work either way.")
            end)
        end

    elseif event == "ZONE_CHANGED_NEW_AREA" then
        StartArriving(ARRIVE_WAIT)

    elseif event == "NAME_PLATE_UNIT_ADDED" then
        SafeNameplate(arg1)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        OnNameplateGone(arg1)
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        SafeCheckUnit("mouseover")
    elseif event == "PLAYER_TARGET_CHANGED" then
        SafeCheckUnit("target")

    else
        -- One of the guild or friends lists changed
        QueueRefresh()
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_CHUMCHIMES1 = "/chum"
SLASH_CHUMCHIMES2 = "/chumchimes"
SlashCmdList.CHUMCHIMES = function(msg)
    local cmd = strtrim((msg or ""):lower())
    if cmd == "" or cmd == "options" or cmd == "settings" then
        OpenSettings()
    elseif cmd == "test" or cmd == "test zone" then
        TestZone()
    elseif cmd == "test near" or cmd == "test nearby" then
        TestNearby()
    elseif cmd == "test summary" then
        TestSummary()
    elseif cmd == "who" then
        local names = {}
        for _, person in pairs(present) do names[#names + 1] = NameLink(person) end
        table.sort(names)
        local zone = (MyZones())
        if #names == 0 then
            Print("no chums in " .. zone .. " right now (that I know of).")
        else
            Print("chums in " .. zone .. ": " .. table.concat(names, ", "))
        end
    elseif cmd == "on" or cmd == "off" then
        ChumChimesDB.enabled = (cmd == "on")
        Print("chimes " .. (ChumChimesDB.enabled and "on." or "off."))
    elseif cmd == "plates" then
        TurnOnFriendlyPlates()
    else
        Print("commands: /chum (settings), /chum test, /chum test near, /chum test summary, /chum who, /chum plates, /chum on, /chum off")
    end
end
