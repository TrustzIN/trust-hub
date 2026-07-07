-- ══════════════════════════════════════════════════════════
-- ║          TRUST-HUB v3.0 — AoT Revolution              ║
-- ║                  ENI × LO                              ║
-- ══════════════════════════════════════════════════════════
-- [0] RE-INJECTION GUARD & AUTO-EXECUTE
-- GameId 4658598196 = AoT Revolution, constant across every sub-place (lobby,
-- missions, raids all have different PlaceIds). Required so this is safe to
-- drop in the executor's autoexec folder — without it, joining any other
-- game would run this too and hang ~10s on WaitForChild for remotes that
-- don't exist there before erroring out.
if game.GameId ~= 4658598196 then return end
-- Live-confirmed: 5 separate script loads and 5 fully live LinoriaLib windows
-- (CoreGui.HUI, all Enabled=true) existed at once in a single session. The
-- getgenv() guard right below assumes exactly one shared Lua environment to
-- dedupe against, but multiple near-simultaneous triggers around the same
-- teleport (autoexec + apparently-stacked queue_on_teleport callbacks — Xeno
-- does not seem to treat it as a single replaceable slot the way this script
-- assumed) can each land in their own isolated state before any of them has
-- set getgenv().TRUST_HUB, so none of them see each other to kill. This
-- debounce is file-backed instead of memory-backed specifically so it still
-- works even when the genv isn't actually shared between the loads: only the
-- first load within a 3s window writes the file and continues; every other
-- one reads a too-recent timestamp and aborts before doing anything (before
-- even the HttpGet for the UI library), so at most one instance ever gets far
-- enough to build a window or start a farm loop.
do
    local lockFile = "TrustHUB_" .. game.Players.LocalPlayer.Name .. "_LoadLock.txt"
    local now = tick()
    local last = 0
    pcall(function()
        if isfile and isfile(lockFile) then last = tonumber(readfile(lockFile)) or 0 end
    end)
    if now - last < 3 then return end
    pcall(function() writefile(lockFile, tostring(now)) end)
end
if getgenv and getgenv().TRUST_HUB then
    pcall(function() getgenv().TRUST_HUB.kill() end)
end
-- Claim the re-injection flag RIGHT NOW, synchronously, before anything that
-- yields (WaitForChild below, HttpGet further down for the UI libs — real
-- network time). Autoexec and queue_on_teleport can both fire on the same
-- server hop; if the claim only happens at the end of setup (where it used
-- to live), a second trigger starting in that multi-second window never sees
-- it and boots a full duplicate instance alongside this one — this is almost
-- certainly why the hub was loading 3-4x per hop. The real kill() logic is
-- filled in further down once ST/conns/threads exist; this stub just blocks
-- duplicates immediately.
getgenv().TRUST_HUB = { kill = function() end }
-- The actual queue_on_teleport registration moved below CFG (search
-- registerTeleportReload) so it can be toggled off from the GUI — see
-- "Persist Across Teleports" in the Utilities tab.
-- ══════════════════════════════════════════════════════════
-- [1] SERVICES
-- ══════════════════════════════════════════════════════════
local Players       = game:GetService("Players")
local RS            = game:GetService("ReplicatedStorage")
local RunService    = game:GetService("RunService")
local UIS            = game:GetService("UserInputService")
local TPS            = game:GetService("TeleportService")
local VIM             = game:GetService("VirtualInputManager")
local LP             = Players.LocalPlayer
-- ══════════════════════════════════════════════════════════
-- [2] ANTI-CHEAT
-- ══════════════════════════════════════════════════════════
-- L3/L4 (namecall/index hook on game's metatable) removed:
-- confirmed root cause of the client crash. On Wave, yielding
-- inside a hooked metamethod ("attempt to yield across
-- metamethod/C-call boundary") kills the client. The game's own
-- mission-start UI yields (InvokeServer/WaitForChild), and every
-- call was being routed through this hook, so opening the mission
-- panel manually crashed the client. Do not re-add a global
-- __namecall/__index hook without confirming the executor's
-- hookmetamethod supports yielding.
local BAN_ATTRS = {
    "Blacklisted","Exploiter","ShadowBanned","Banned","Flagged",
    "Cheater","LowDropRate","TradeBlocked","DetectionFlag","AntiCheat","Suspicious"
}
pcall(function()
    local old = identifyexecutor
    if old then getgenv().identifyexecutor = function() return "Unknown" end end
end)
pcall(function()
    if checkcaller then
        getgenv().checkcaller = function() return true end
    end
end)
for _, a in ipairs(BAN_ATTRS) do pcall(function() LP:SetAttribute(a, nil) end) end
LP.AttributeChanged:Connect(function(attr)
    for _, a in ipairs(BAN_ATTRS) do
        if attr == a then pcall(function() LP:SetAttribute(a, nil) end) end
    end
end)
for _, g in ipairs({"syn","Synapse","SENTINEL_V2","WRD_LOADED","pebc_execute","KRNL_LOADED","OXYGEN_LOADED","SCRIPTWARE","is_sirhurt_closure"}) do
    pcall(function() getgenv()[g] = nil end)
end
-- Traceback spoof: hide executor stack traces from game detection
pcall(function()
    if debug and debug.traceback then
        local _realTB = debug.traceback
        debug.traceback = function(...)
            local t = _realTB(...)
            if type(t) == "string" then
                t = t:gsub("@%S+", "@game.CoreGui")
                t = t:gsub("loadstring%b()", "CoreScript")
            end
            return t
        end
    end
end)
-- ══════════════════════════════════════════════════════════
-- [3] REMOTE SETUP
-- ══════════════════════════════════════════════════════════
local rem  = RS:WaitForChild("Assets", 10):WaitForChild("Remotes", 10)
local POST = rem:WaitForChild("POST")   -- RemoteEvent
local GET  = rem:WaitForChild("GET")    -- RemoteFunction
-- ══════════════════════════════════════════════════════════
-- [4] REAL IN-GAME DATA
-- ══════════════════════════════════════════════════════════
local mapList  = {"Shiganshina","Trost","Outskirts","Forest","Utgard","Docks","Stohess","Chapel"}
-- "Hardest" does not exist in this game (0 matches in the decompiled scripts) —
-- it was a fabricated value. Real tiers, gated server-side by weapon "Potential"
-- (ReplicatedStorage.Modules.Storage.Values.Difficulty_Potential.Missions):
-- Easy=0, Normal=2, Hard=5, Severe=9, Aberrant=12 (average upgrade level required).
-- "Hardest" isn't a real game difficulty (0 matches in decompiled scripts,
-- same as the old fabricated-value mistake) — it's a script-local sentinel:
-- picking it in the dropdown routes through getMaxClearableDiffIdx() below
-- instead of a fixed CFG.Difficulty string, same mechanism the standalone
-- Auto Difficulty toggle uses.
local diffList = {"Easy","Normal","Hard","Severe","Aberrant","Hardest"}
local diffOrderHardToEasy = {"Aberrant","Severe","Hard","Normal","Easy"}
local objList  = {"Skirmish","Breach","Protect","Escort","Guard","Defend","Stall","Survive","Random"}
local modMap   = {
    "No Perks","No Skills","No Memories","Nightmare","Oddball",
    "Injury Prone","Chronic Injuries","Fog","Glass Cannon",
    "Time Trial","Boring","Simple"
}
local BOSS_LIST = {"Attack Titan","Female Titan","Armored Titan","Colossal Titan"}
local mapObjectives = { Missions = {
        Shiganshina = {"Skirmish", "Breach", "Random"},
        Trost       = {"Skirmish", "Protect", "Random"},
        Outskirts   = {"Skirmish", "Escort", "Random"},
        Forest      = {"Skirmish", "Guard", "Random"},
        Utgard      = {"Skirmish", "Defend", "Random"},
        Docks       = {"Skirmish", "Stall", "Random"},
        Stohess     = {"Skirmish", "Random"},
        Chapel      = {"Skirmish", "Random"},
    },
    Raids = {
        Shiganshina = {"Armored Titan", "Colossal Titan"},
        Trost       = {"Attack Titan"},
        Stohess     = {"Female Titan"},
    }
}
local function getObjsForMap(mapName, startType)
    local typeTable = mapObjectives[startType or "Missions"] or mapObjectives.Missions
    return typeTable[mapName] or {"Skirmish", "Random"}
end
-- ══════════════════════════════════════════════════════════
-- [5] CONFIG & STATE
-- ══════════════════════════════════════════════════════════
local CFG = {
    AutoFarm=false, RaidMode=false, AutoReload=true, AutoEscape=true, SafeFarm=false,
    DamageMode="Legit (Safe)", AttackRange=150,
    MultiTarget=false, MultiTargetN=5,
    NapeExtend=false, NapeExtSize=6,
    AutoStart=false, SoloOnly=true, AutoRetry=true, AutoReturn=false,
    ReturnAfter=10, StartDelay=5,
    AutoSkip=false, AutoChest=false, FailSafe=true, FailSafeMins=15,
    StartType="Missions", MapName="Shiganshina", Objective="Breach",
    Difficulty="Aberrant", AutoDifficulty=false, Modifiers={},
    MoveMode="Gliding", Noclip=true, FloatHeight=170, HoverSpeed=400,
    TitanESP=false, BossESP=false, RemoveFog=false, DeleteMap=true,
    AutoSpendSP=false, SkillPath="Blade Skills", AutoUpGear=false,
    ShowStatsPanel=true, PersistReload=true, Disable3D=false,
    -- v3.0: combat upgrades
    RoarDodge=true, InjuryRemove=true, StallMode=true,
    ObjectiveTracking=true, KillNotif=false,
    TitanMastery=false, MasteryMode="Both", AutoShift=false,
    WeaponAutoDetect=true, BanCheckOnLoad=true,
    -- v3.1: RamenHub integration
    AutoSkillTree=false, SkillTreePath="Blades", SkillTreeSub="Damage",
    SpearAutoFire=true, ShifterSkills=true,
    -- v3.2: TITANIC hub integration (lobby automation)
    AutoPrestige=false, PrestigeGoldM=0, PrestigeBoost="Luck Boost",
    AutoEnhance=false, PerkSlot="Body", FoodRarities={},
    AutoClaimAch=false,
    -- v3.2: multi-account / AFK hardening
    AutoRejoin=true, AutoBoostedMap=false, AutoModifiers=false,
    AutoSelectSlot=false, SelectSlot="A",
    DieAtStreak=false, DieStreakN=10000,
    -- v2.0: user-configured webhook
    WebhookURL="", RewardWebhook=false, MythicalWebhook=false,
    DropLog=false, SessionReport=false, ReportMins=30,
}
local ST = {
    running=false, canHit=true, startT=tick(), lastKill=tick(),
    killCount=0, gameCount=0, ogHitboxSize=nil,
    autoDiffIdx=1, stayedInLobby=false,
    startGold=0, sessionKills=0,
    -- v3.0
    weaponType="Blades", masteryCombo=1, titanKillCount=0,
    mapData=nil, cachedObjectivePart=nil, nextObjCacheUpdate=0, lastMapDataFetch=0,
    -- v3.1
    currentTargetNape=nil, attackTitanSpawnTime=nil, shifterSkillsRunning=false,
    charParts={}, currentChar=nil, wasInLobby=false,
}
local conns   = {}
local threads = {}
-- Forward-declared so TRUST_HUB.kill (defined below, long before the real
-- `local Library = ...` near the UI section) closes over THIS variable
-- instead of creating its own separate global "Library" upvalue. That bug
-- meant Library:Unload() never ran on re-injection — every re-execute left
-- the previous LinoriaLib window (and its own Insert-key listener) alive
-- alongside the new one, which looked like "the GUI won't close, there's
-- several of them" since each stacked window still responded to the toggle.
local Library
-- Same forward-declare reason as Library above: TRUST_HUB.kill (right below)
-- closes over this before the real "local function clearESP" is declared
-- further down — without this, kill() would resolve to a global clearESP
-- (nil) instead of the real one, and ESP highlights would leak past kill.
local clearESP
-- lobbyLoop (defined before the real "local function upgradeAllGear" further
-- down in [15]) needs to call it on lobby arrival — same forward-declare
-- reason as Library/clearESP above.
local upgradeAllGear
-- farmLoop (defined before [15a2]) calls this each tick — forward-declare so
-- it binds the real function, not a nil global.
local checkDieAtStreak
local function track(c) table.insert(conns, c) end
local function trackThread(fn)
    local th = task.spawn(fn)
    table.insert(threads, th)
    return th
end
-- Fill in the real kill() on the table already claimed at the very top —
-- don't reassign getgenv().TRUST_HUB here, that would momentarily leave the
-- stub in place for anything checking it mid-setup for no reason.
getgenv().TRUST_HUB.kill = function()
    ST.running = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns = {}
    for _, th in ipairs(threads) do pcall(function() task.cancel(th) end) end
    threads = {}
    if Library then pcall(function() Library:Unload() end) end
    if clearESP then pcall(clearESP) end
    getgenv().TRUST_HUB = nil
end
-- ══════════════════════════════════════════════════════════
-- [5b] CROSS-HOP SESSION PERSISTENCE
-- ══════════════════════════════════════════════════════════
-- Lobby<->mission is a real Roblox place teleport (different PlaceId per
-- sub-place), so PersistReload's queue_on_teleport re-runs this entire file
-- and ST resets to its defaults on every single hop — "Return After X Games"
-- could never count past 1 because ST.gameCount died with it on every trip
-- back to the lobby. File-backed per-account (LP.Name) so multiple accounts
-- run side by side under a multi-instance launcher without clobbering each
-- other's count.
-- Unified per-account session store (JSON). Holds everything that has to
-- survive a lobby<->mission hop but reset on a genuine cold Roblox launch:
--   gameCount   — "Return After X Games" counter
--   sessionStart— os.time() the session began (real wall clock, unlike tick()
--                 which is per-Lua-state and so resets to ~0 on every reload —
--                 that reset was why the Session timer kept dropping to 0)
--   goldEarned  — cumulative POSITIVE gold deltas only (mission rewards), so
--                 spending gold on upgrades never drives it negative
-- File name keyed on LP.Name so 4 accounts under one launcher don't collide.
local HttpService = game:GetService("HttpService")
-- ══════════════════════════════════════════════════════════
-- [5a] WEBHOOK (user-configured, not hardcoded)
-- ══════════════════════════════════════════════════════════
-- Sends to WHATEVER Discord webhook URL the user pastes in the GUI (saved in
-- the config). Nothing is hardcoded — the opposite of the identity-harvest
-- backdoor found in the TITANIC script. Uses the executor's HTTP primitive
-- (request/http_request/…); silently no-ops if none exists or no URL is set.
local function httpRequest(opts)
    local req = (syn and syn.request) or (http and http.request) or http_request or request or (fluxus and fluxus.request)
    if not req then return false end
    return pcall(req, opts)
end
local function sendWebhook(embed, content)
    local url = CFG and CFG.WebhookURL
    if not url or url == "" or not url:match("^https?://") then return end
    embed.footer = embed.footer or { text = "TRUST-HUB • " .. os.date("%H:%M:%S") }
    local body = HttpService:JSONEncode({ content = content, embeds = { embed } })
    task.spawn(function()
        httpRequest({ Url = url, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = body })
    end)
end
-- Formatting helpers (defined early so the webhook/report loops can use them).
local function formatDuration(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    return string.format("%02d:%02d:%02d", h, m, s)
end
-- Compact number: 1234 -> "1.2K", 3450000 -> "3.4M".
local function formatNumber(n)
    n = tonumber(n) or 0
    local neg = n < 0 and "-" or ""
    n = math.abs(n)
    if n >= 1e9 then return string.format("%s%.2fB", neg, n / 1e9) end
    if n >= 1e6 then return string.format("%s%.2fM", neg, n / 1e6) end
    if n >= 1e3 then return string.format("%s%.1fK", neg, n / 1e3) end
    return neg .. tostring(math.floor(n))
end
local SESSION_FILE = "TrustHUB_" .. LP.Name .. "_Session.json"
local function loadSession()
    local ok, data = pcall(function()
        if isfile and isfile(SESSION_FILE) then
            return HttpService:JSONDecode(readfile(SESSION_FILE))
        end
    end)
    if ok and type(data) == "table" then
        data.gameCount   = tonumber(data.gameCount) or 0
        data.sessionStart= tonumber(data.sessionStart) or os.time()
        data.goldEarned  = tonumber(data.goldEarned) or 0
        data.lastGold    = tonumber(data.lastGold) -- may be nil (unknown yet)
        return data
    end
    return { gameCount = 0, sessionStart = os.time(), goldEarned = 0, lastGold = nil }
end
local function saveSession(s)
    pcall(function() writefile(SESSION_FILE, HttpService:JSONEncode(s)) end)
end
-- A genuine cold launch must start a fresh session; a teleport hop must
-- continue the existing one. queue_on_teleport's payload only runs after a
-- REAL teleport lands (never on a plain autoexec/manual run), so it arms a
-- one-shot marker file; here we consume it and only keep the old session when
-- it was actually armed. Cold launch never armed it → fresh session.
local TELEPORT_MARKER_FILE = "TrustHUB_" .. LP.Name .. "_TeleportFlag.txt"
local function isTeleportContinuation()
    local ok, armed = pcall(function()
        if isfile and isfile(TELEPORT_MARKER_FILE) and readfile(TELEPORT_MARKER_FILE) == "1" then
            writefile(TELEPORT_MARKER_FILE, "0") -- consume: one-shot per hop
            return true
        end
        return false
    end)
    return ok and armed
end
local SESSION = loadSession()
if not isTeleportContinuation() then
    -- fresh cold start: reset everything
    SESSION = { gameCount = 0, sessionStart = os.time(), goldEarned = 0, lastGold = nil }
    saveSession(SESSION)
end
-- Re-arms the reload-on-teleport hook for the *next* teleport only (that's
-- how queue_on_teleport works — it doesn't stay armed across multiple hops on
-- its own). Since this same file re-runs this line near its own top on every
-- reload, it keeps re-arming itself each hop as long as PersistReload is on;
-- turning the toggle off just stops calling this, so the next teleport won't
-- bring the hub back.
-- Public repo so game:HttpGet needs no auth header (same reason LinoriaLib's
-- own raw.githubusercontent.com fetches work) — pushed via
-- https://github.com/TrustzIN/trust-hub. Fetching this on every hop means
-- every account running this script picks up an edit here immediately, no
-- manual copy to the 3 local files needed for that account. Falls back to
-- the local Trust_HUB.lua copy if the fetch fails (offline, repo down, etc).
local REMOTE_SCRIPT_URL = "https://raw.githubusercontent.com/TrustzIN/trust-hub/master/TrustHUB.lua"
local function registerTeleportReload()
    if not CFG.PersistReload then return end
    pcall(function()
        queue_on_teleport(([[
            pcall(function() writefile(%q, "1") end)
            -- A truncated/corrupted HTTP body still counts as a "successful"
            -- HttpGet (ok=true) — that only failed at loadstring() with
            -- "bytecode corrupted", past this local fallback entirely since
            -- it only triggered on the fetch itself failing. Wrap the
            -- compile-and-run in its own pcall so a bad download still falls
            -- through to the local copy instead of just erroring out.
            local ok, src = pcall(function() return game:HttpGet(%q) end)
            local ran = false
            if ok and src and #src > 0 then
                ran = pcall(function() loadstring(src)() end)
            end
            if not ran and readfile and isfile and isfile("Trust_HUB.lua") then
                loadstring(readfile("Trust_HUB.lua"))()
            end
        ]]):format(TELEPORT_MARKER_FILE, REMOTE_SCRIPT_URL))
    end)
end
registerTeleportReload()
-- ══════════════════════════════════════════════════════════
-- [6] UTILITY FUNCTIONS
-- ══════════════════════════════════════════════════════════
local function getChar()
    local c = LP.Character
    return c, c and c:FindFirstChild("HumanoidRootPart")
end
local function humanWait(base)
    local jitter = CFG.SafeFarm and (math.random() * 0.15 + 0.05) or 0
    task.wait(base + jitter)
end
local function isGrabbed()
    local c = getChar()
    if not c then return false end
    if c:GetAttribute("Grabbed") or c:GetAttribute("IsGrabbed") then return true end
    local hum = c:FindFirstChildOfClass("Humanoid")
    return hum and hum:GetState() == Enum.HumanoidStateType.Physics
end
local function escapeGrab()
    local c = getChar()
    if not c then return end
    local hum = c:FindFirstChildOfClass("Humanoid")
    if hum then
        for _ = 1, 8 do
            hum:Move(Vector3.new(math.random(-1,1), 0, math.random(-1,1)), true)
        end
        hum:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end
local function processAntiGrab()
    local titans = workspace:FindFirstChild("Titans")
    if not titans then return end
    for _, t in ipairs(titans:GetChildren()) do
        local hb = t:FindFirstChild("Hitboxes")
        if hb then
            local detect = hb:FindFirstChild("Detect")
            if detect then
                for _, p in ipairs(detect:GetChildren()) do
                    if p:IsA("BasePart") and (p.Name:match("Hand") or p.Name:match("Punch") or p.Name:match("Grab") or p.Name:match("Foot")) then
                        p.CanTouch = false
                        p.CanCollide = false
                    end
                end
            end
        end
    end
end
-- ══════════════════════════════════════════════════════════
-- [6b] v3.0 — INJURY, MAP DATA, WEAPON, NOTIF, OBJECTIVE, BAN
-- ══════════════════════════════════════════════════════════
local TweenService = game:GetService("TweenService")
local function removeInjuries()
    local c = getChar()
    if not c then return end
    local injuries = c:FindFirstChild("Injuries")
    if injuries then
        for _, v in ipairs(injuries:GetChildren()) do pcall(function() v:Destroy() end) end
    end
end
-- Throttled: getPotential/getWeaponType/upgradeAllGear and the AutoDifficulty
-- lobby check all call this, and recent additions made several of those call
-- it unconditionally (every lobby arrival, every upgrade) instead of only
-- when ST.mapData was nil — piling up extra "Data"/"Copy" InvokeServer round
-- trips per minute. Not confirmed as the cause of the executor-side
-- BytecodePatchWatcher crash, but it's unnecessary server pressure either
-- way, so cap real fetches to once per 2s and serve the cache otherwise.
local function refreshMapData()
    local now = tick()
    if ST.mapData and (now - (ST.lastMapDataFetch or 0)) < 2 then
        return ST.mapData
    end
    ST.lastMapDataFetch = now
    local ok, data = pcall(function() return GET:InvokeServer("Data", "Copy") end)
    if ok and data then ST.mapData = data end
    return ST.mapData
end
-- NOTE on gear Potential / "read the hardest clearable difficulty": removed.
-- It required the account upgrade levels, which only exist in the client's
-- Actor Cache.Data — Data/Copy returns nil in the lobby (confirmed live), so
-- any potential math there computes 0 and always picks Easy. AutoDifficulty /
-- "Hardest" now just start at the hardest tier and step down when the server
-- rejects the Create (see lobbyLoop), which needs no local gear data.
local function getWeaponType()
    if not CFG.WeaponAutoDetect then return ST.weaponType end
    local data = ST.mapData or refreshMapData()
    if not data then return ST.weaponType end
    local slotIdx = LP:GetAttribute("Slot")
    local slot = slotIdx and data.Slots and data.Slots[slotIdx]
    if slot and slot.Weapon then ST.weaponType = slot.Weapon end
    return ST.weaponType
end
local activeNotifs = {}
local function showKillNotification(count)
    if not CFG.KillNotif then return end
    local pg = LP:FindFirstChild("PlayerGui")
    if not pg then return end
    local sg = Instance.new("ScreenGui", pg)
    sg.Name = "TrustHUB_KN_" .. tick()
    sg.ResetOnSpawn = false
    sg.IgnoreGuiInset = true
    local frame = Instance.new("Frame", sg)
    frame.Size = UDim2.new(0, 190, 0, 55)
    frame.Position = UDim2.new(1, 20, 0, 10 + (#activeNotifs * 62))
    frame.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
    frame.BackgroundTransparency = 0.15
    frame.BorderSizePixel = 0
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 6)
    local sN = Instance.new("UIStroke", frame)
    sN.Color = Color3.fromRGB(103, 89, 179)
    sN.Thickness = 1
    local lbl = Instance.new("TextLabel", frame)
    lbl.Size = UDim2.new(0.55, 0, 1, 0)
    lbl.Position = UDim2.new(0, 8, 0, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = "Kill Hit:"
    lbl.TextColor3 = Color3.fromRGB(200, 190, 255)
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 15
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    local ctr = Instance.new("TextLabel", frame)
    ctr.Size = UDim2.new(0.4, 0, 1, 0)
    ctr.Position = UDim2.new(0.55, 0, 0, 0)
    ctr.BackgroundTransparency = 1
    ctr.Text = tostring(count)
    ctr.TextColor3 = Color3.fromRGB(255, 255, 255)
    ctr.Font = Enum.Font.GothamBold
    ctr.TextSize = 20
    ctr.TextXAlignment = Enum.TextXAlignment.Right
    table.insert(activeNotifs, sg)
    TweenService:Create(frame, TweenInfo.new(0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
        Position = UDim2.new(1, -210, 0, 10 + ((#activeNotifs - 1) * 62))
    }):Play()
    task.delay(4, function()
        TweenService:Create(frame, TweenInfo.new(0.25, Enum.EasingStyle.Sine, Enum.EasingDirection.In), {
            Position = UDim2.new(1, 20, frame.Position.Y.Scale, frame.Position.Y.Offset),
            BackgroundTransparency = 1
        }):Play()
        task.wait(0.3)
        pcall(function() sg:Destroy() end)
        for i, v in ipairs(activeNotifs) do
            if v == sg then table.remove(activeNotifs, i) break end
        end
        for i, notif in ipairs(activeNotifs) do
            local f = notif:FindFirstChildWhichIsA("Frame")
            if f then
                TweenService:Create(f, TweenInfo.new(0.2), {
                    Position = UDim2.new(1, -210, 0, 10 + ((i - 1) * 62))
                }):Play()
            end
        end
    end)
end
local function getObjectiveReference()
    if not CFG.ObjectiveTracking then return nil end
    local now = tick()
    if now < ST.nextObjCacheUpdate and ST.cachedObjectivePart then
        return ST.cachedObjectivePart
    end
    ST.nextObjCacheUpdate = now + 1
    ST.cachedObjectivePart = nil
    local objFolder = workspace:FindFirstChild("Unclimbable")
    objFolder = objFolder and objFolder:FindFirstChild("Objective")
    if not objFolder then return nil end
    for _, desc in ipairs(objFolder:GetDescendants()) do
        if desc:IsA("BillboardGui") and desc.Parent and desc.Parent:IsA("BasePart") then
            ST.cachedObjectivePart = desc.Parent
            return ST.cachedObjectivePart
        end
    end
    return nil
end
local function checkBanStatus()
    local banned, keys = false, {}
    pcall(function()
        local data = GET:InvokeServer("Data", "Get")
        if type(data) ~= "table" then return end
        for key, value in pairs(data) do
            local lk = key:lower()
            if lk:match("blacklist") or lk:match("exploit") or lk:match("banned") or lk:match("flag") then
                if key ~= "Is_Blacklisted" and key ~= "Is_Blacklisted_NEW" then
                    if value == true or value == 1 or value == "true" then
                        banned = true
                        table.insert(keys, key .. "=" .. tostring(value))
                    end
                end
            end
        end
    end)
    return banned, keys
end
-- ══════════════════════════════════════════════════════════
-- [7] DAMAGE & TARGETING
-- ══════════════════════════════════════════════════════════
local function getLegitDmg(nape)
    local _, hrp = getChar()
    if not hrp then return 0, 0.25 end
    local vel  = hrp.AssemblyLinearVelocity.Magnitude
    local dist = (hrp.Position - nape.Position).Magnitude
    local dmg  = math.floor(vel * 2 + dist / 4)
    if CFG.DamageMode == "Legit (Safe)" then
        dmg = math.clamp(dmg, 200, 3100)
    else
        dmg = math.clamp(dmg, 4500, 5000)
    end
    return dmg, math.random(20, 30) / 100
end
local BOSS_NAMES = {Attack_Titan=true, Armored_Titan=true, Female_Titan=true}
local function getValidNapes(reqCount)
    local _, hrp = getChar()
    if not hrp then return {} end
    local valid = {}
    local titans = workspace:FindFirstChild("Titans")
    if not titans then return valid end
    local objRef = getObjectiveReference()
    local refPos = (objRef and objRef.Position) or hrp.Position
    local data = ST.mapData
    local isStall = CFG.StallMode and data and data.Map and data.Map.Objective == "Stall"
    -- v3.1: raid-specific context from workspace
    local RS = game:GetService("ReplicatedStorage")
    local wsObj = workspace:FindFirstChild("Unclimbable") and workspace.Unclimbable:FindFirstChild("Objective")
    local rsObj = RS:FindFirstChild("Objectives")
    local isArmoredRaid = wsObj and wsObj:FindFirstChild("Armored_Boss")
    local hasReinerObj = rsObj and rsObj:FindFirstChild("Defeat_Reiner")
    local closestBossDist, closestBossHit, bossIsRoaring = math.huge, nil, false
    for _, t in ipairs(titans:GetChildren()) do
        if not t:IsA("Model") then continue end
        if t:GetAttribute("Dead") or t:GetAttribute("Killed") then continue end
        local fakeCollision = false
        pcall(function()
            if t:FindFirstChild("Fake") and t.Fake:FindFirstChild("Collision") and not t.Fake.Collision.CanCollide then
                fakeCollision = true
            end
        end)
        if fakeCollision then continue end
        if CFG.RoarDodge then
            local atk = t:GetAttribute("Attack")
            if atk == "Roar" or atk == "Berserk_Mode" then continue end
        end
        local isBoss = BOSS_NAMES[t.Name]
        -- v3.1: skip Armored_Titan when Reiner objective doesn't exist yet
        if isBoss and isArmoredRaid and not hasReinerObj and t.Name == "Armored_Titan" then continue end
        if isBoss and not t:GetAttribute("State") then continue end
        local nape
        if CFG.RaidMode and isBoss then
            local hitPart = (t:FindFirstChild("Marker") and t.Marker.Adornee) or nil
            if not hitPart then
                local hb = t:FindFirstChild("Hitboxes")
                hitPart = hb and hb:FindFirstChild("Hit") and hb.Hit:FindFirstChild("Nape")
            end
            nape = hitPart
        end
        if not nape then
            local hb = t:FindFirstChild("Hitboxes")
            if hb and hb:FindFirstChild("Hit") then
                nape = hb.Hit:FindFirstChild("Nape")
            end
        end
        if nape then
            local dx = refPos.X - nape.Position.X
            local dz = refPos.Z - nape.Position.Z
            local distSq = dx*dx + dz*dz
            -- v3.1: target stickiness — bonus for current target to prevent flickering
            if ST.currentTargetNape == nape then distSq = distSq - 15000 end
            -- v3.1: range limit during armored raid pre-reiner phase
            if isArmoredRaid and not hasReinerObj and distSq > 90000 then continue end
            local sortVal
            if isStall then
                sortVal = -nape.Position.Z
            else
                sortVal = distSq
            end
            -- Track closest boss hit point separately for priority
            if isBoss and CFG.RaidMode then
                local roaring = t:GetAttribute("Attack") == "Roar" or t:GetAttribute("Attack") == "Berserk_Mode"
                if distSq < closestBossDist then
                    closestBossDist = distSq
                    closestBossHit = nape
                    bossIsRoaring = roaring
                end
            end
            table.insert(valid, {part = nape, dist = sortVal, isBoss = isBoss})
        end
    end
    table.sort(valid, function(a, b) return a.dist < b.dist end)
    -- Boss priority in raid mode: if boss exists, put it first
    if CFG.RaidMode and closestBossHit and not bossIsRoaring then
        local out = {closestBossHit}
        for i = 1, math.min(reqCount - 1, #valid) do
            if valid[i].part ~= closestBossHit then table.insert(out, valid[i].part) end
        end
        ST.currentTargetNape = closestBossHit
        return out
    end
    local out = {}
    for i = 1, math.min(reqCount, #valid) do table.insert(out, valid[i].part) end
    if #out > 0 then ST.currentTargetNape = out[1] end
    return out
end
-- ══════════════════════════════════════════════════════════
-- [8] COMBAT
-- ══════════════════════════════════════════════════════════
local HIT_COOLDOWN = 0.35 -- base cooldown; overridden by WeaponAutoDetect
local lastFireT = 0
local _notifiedNapes = {} -- track unique nape hits for kill notifications
-- Register every nape first, then one Slash resolves all.
local function comboSlash(napes)
    if not napes or #napes == 0 then return end
    local now = tick()
    local wepType = CFG.WeaponAutoDetect and getWeaponType() or ST.weaponType
    local cooldown = (wepType == "Blades") and 0.15 or 1
    if now - lastFireT < cooldown then return end
    lastFireT = now
    local c = getChar()
    local isShifted = c and c:GetAttribute("Shifter")
    if CFG.TitanMastery and isShifted then
        for _, nape in ipairs(napes) do
            POST:FireServer("Hitboxes", "Register", nape, nil, nil, ST.masteryCombo)
        end
        POST:FireServer("Attacks", "Slash", true)
        ST.masteryCombo = ST.masteryCombo + 1
        if ST.masteryCombo > 4 then ST.masteryCombo = 1 end
    elseif wepType == "Spears" and CFG.SpearAutoFire then
        -- v3.1: Spear auto-fire system (from RamenHub)
        local pg = LP:FindFirstChild("PlayerGui")
        local hud = pg and pg:FindFirstChild("Interface") and pg.Interface:FindFirstChild("HUD")
        local spearTxt = hud and hud.Main.Top.Spears.Spears.Text
        local curAmmo, maxAmmo = 0, 0
        if spearTxt then
            curAmmo, maxAmmo = string.match(spearTxt, "(%d+)%s*/%s*(%d+)")
            curAmmo, maxAmmo = tonumber(curAmmo) or 0, tonumber(maxAmmo) or 0
        end
        if curAmmo > 0 then
            task.spawn(function()
                local function getAmmo()
                    return tonumber(string.match(pg.Interface.HUD.Main.Top.Spears.Spears.Text, "(%d+)")) or 0
                end
                local before = getAmmo()
                pcall(function() GET:InvokeServer("Spears", "S_Fire", tostring(curAmmo)) end)
                local after = getAmmo()
                if after == before then
                    for j = maxAmmo, 1, -1 do
                        local prev = getAmmo()
                        pcall(function() GET:InvokeServer("Spears", "S_Fire", tostring(j)) end)
                        if getAmmo() < prev then break end
                    end
                end
                local targetPos = napes[1] and napes[1].Position
                if targetPos then
                    local isBoss = napes[1].Parent and napes[1].Parent.Parent and napes[1].Parent.Parent.Parent
                        and BOSS_NAMES[napes[1].Parent.Parent.Parent.Name]
                    local loops = isBoss and 30 or 1
                    for j = 1, loops do
                        POST:FireServer("Spears", "S_Explode", targetPos)
                    end
                end
            end)
        end
    else
        for _, nape in ipairs(napes) do
            local dmg, acc = getLegitDmg(nape)
            POST:FireServer("Hitboxes", "Register", nape, dmg, acc)
        end
        POST:FireServer("Attacks", "Slash", true)
    end
    for _, nape in ipairs(napes) do
        local id = tostring(nape)
        if not _notifiedNapes[id] then
            _notifiedNapes[id] = true
            ST.titanKillCount = ST.titanKillCount + 1
            showKillNotification(ST.titanKillCount)
        end
    end
end
local function moveToNape(hrp, nape)
    local targetPos = nape.Position + Vector3.new(0, CFG.FloatHeight, 0)
    local dir = (targetPos - hrp.Position)
    if CFG.MoveMode == "Teleport" then
        hrp.CFrame = CFrame.new(targetPos)
    else
        hrp.AssemblyLinearVelocity = dir.Unit * CFG.HoverSpeed
        if dir.Magnitude < 20 then hrp.CFrame = CFrame.new(targetPos) end
    end
    return dir.Magnitude
end
-- ══════════════════════════════════════════════════════════
-- [9] AUTO-REFILL (user's proven working method)
-- ══════════════════════════════════════════════════════════
-- The entire durability-detection saga (rig transparency, HUD bar gradient,
-- attack-gating, VIM R) was a dead end — the display signals don't reflect
-- true server durability while idle, and the direct reload gets rejected
-- without the client state. The user's own working version sidesteps all of
-- it: just fire GET Blades/Reload every 0.5s while in a match. The server
-- only acts when the blade is actually depleted and no-ops (returns nil, no
-- reserve consumed) when it's full, so blind spamming is safe and needs no
-- durability read at all. When the spare SETS run out, fire the station
-- refill POST at the "Refill" part FARTHEST from titans (safest), no teleport
-- — the remote is proximity-validated but firing from afar is harmless.
local function inMatch()
    local mapAttr = workspace:GetAttribute("Map")
    if not mapAttr then return false end
    return string.find(string.lower(tostring(mapAttr)), "lobby") == nil
end
-- Blade durability (0-7 segments) read from the HUD bar fill, the same signal
-- the game's own HUD.Update writes: Main.Top.7.Blades.Inner.Bar.Gradient.Offset.X
-- = Blades_X[segments]. Reverse-map the offset to the nearest table entry.
-- Used ONLY to skip pointless swings while the blade is empty (reloadLoop is
-- what actually refills it); returns nil when the HUD/bar isn't present
-- (lobby, or a non-blade weapon whose bar path differs), which disables the
-- gate rather than blocking attacks.
local BLADES_X = {[0]=-0.15,[1]=0.02,[2]=0.17,[3]=0.34,[4]=0.5,[5]=0.675,[6]=0.765,[7]=1}
local function bladeDurability()
    local pg = LP:FindFirstChild("PlayerGui")
    local iface = pg and pg:FindFirstChild("Interface")
    local hud = iface and iface:FindFirstChild("HUD")
    local main = hud and hud:FindFirstChild("Main")
    local top = main and main:FindFirstChild("Top")
    local seven = top and top:FindFirstChild("7")
    local blades = seven and seven:FindFirstChild("Blades")
    local bar = blades and blades:FindFirstChild("Inner") and blades.Inner:FindFirstChild("Bar")
    local grad = bar and bar:FindFirstChild("Gradient")
    if not grad then return nil end
    local x = grad.Offset.X
    local best, bestDist = 7, math.huge
    for seg, val in pairs(BLADES_X) do
        local d = math.abs(x - val)
        if d < bestDist then bestDist = d; best = seg end
    end
    return best
end
-- The HUD weapon section (Main.Top.7) holds both a "Blades" and a "Spears"
-- frame; only the equipped one is Visible. Confirmed reliable (from the
-- TITANIC hub) — a real weapon detector that works without the account data
-- that Data/Copy won't give us in the lobby.
local function weaponHUD()
    local pg = LP:FindFirstChild("PlayerGui")
    local iface = pg and pg:FindFirstChild("Interface")
    local hud = iface and iface:FindFirstChild("HUD")
    local main = hud and hud:FindFirstChild("Main")
    local top = main and main:FindFirstChild("Top")
    return top and top:FindFirstChild("7")
end
local function detectWeapon()
    local seven = weaponHUD()
    if not seven then return nil end
    local b = seven:FindFirstChild("Blades")
    local s = seven:FindFirstChild("Spears")
    if b and b.Visible then return "Blades" end
    if s and s.Visible then return "Spears" end
    return nil
end
-- Spare sets ("X / Y") for the equipped weapon.
local function weaponSetsLeft()
    local seven = weaponHUD()
    if not seven then return nil end
    local w = detectWeapon()
    local frame = w and seven:FindFirstChild(w)
    local label = frame and (frame:FindFirstChild("Sets") or frame:FindFirstChild(w)) -- Blades.Sets / Spears.Spears
    if not label then return nil end
    return tonumber((tostring(label.Text or ""):match("(%d+)")))
end
-- Robust "Refill" station finder (from the TITANIC hub): the part lives under
-- different parents per map, so check the known paths then fall back to a
-- recursive search.
local function getRefillPart()
    local u = workspace:FindFirstChild("Unclimbable")
    if not u then return nil end
    local reloads = u:FindFirstChild("Reloads")
    local gt = reloads and reloads:FindFirstChild("GasTanks")
    if gt and gt:FindFirstChild("Refill") then return gt.Refill end
    local props = u:FindFirstChild("Props")
    local hq = props and props:FindFirstChild("HQ")
    if hq then
        local hgt = hq:FindFirstChild("GasTanks")
        if hgt and hgt:FindFirstChild("Refill") then return hgt.Refill end
        for _, c in ipairs(hq:GetChildren()) do
            if c:FindFirstChild("Refill") then return c.Refill end
        end
    end
    return u:FindFirstChild("Refill", true)
end
local function reloadLoop()
    local lastEmpty = false
    while ST.running do
        task.wait(0.5)
        if CFG.AutoReload and inMatch() then
            -- Durability top-up: the server no-ops when the blade is full and
            -- swaps a set when it's depleted, so blind-firing is safe.
            pcall(function() GET:InvokeServer("Blades", "Reload") end)
            -- Out of spare sets → refill at a station. Fire the no-arg form
            -- (TITANIC) and the part form (our earlier working version) so at
            -- least one lands regardless of what this map's handler expects.
            local sets = weaponSetsLeft()
            local empty = (sets ~= nil and sets <= 0)
            if empty and not lastEmpty then
                pcall(function() POST:FireServer("Attacks", "Reload") end)
                local refill = getRefillPart()
                if refill then
                    pcall(function() POST:FireServer("Attacks", "Reload", refill) end)
                end
            end
            lastEmpty = empty
        end
    end
end
-- ══════════════════════════════════════════════════════════
-- [10] NAPE EXTENDER
-- ══════════════════════════════════════════════════════════
local ogHitboxSize = nil
local function expandNape(on)
    local c = getChar()
    if not c then return end
    local hb = c:FindFirstChild("Hitboxes") or c:FindFirstChild("HumanoidRootPart")
    if not hb then return end
    if on then
        if not ogHitboxSize then ogHitboxSize = hb.Size end
        hb.Size = ogHitboxSize + Vector3.one * CFG.NapeExtSize
    elseif ogHitboxSize then
        hb.Size = ogHitboxSize
    end
end
-- ══════════════════════════════════════════════════════════
-- [10b] TITAN / BOSS ESP
-- ══════════════════════════════════════════════════════════
-- T_TitanESP/T_BossESP toggles existed in the UI and CFG but nothing ever
-- drew anything — dead feature. Highlight instances (built-in, no
-- per-frame drawing cost) parented to each titan model; red for regular
-- titans, purple for bosses (BOSS_NAMES, same list combat targeting uses).
local espHighlights = {}
-- Assigns the forward-declared upvalue from [5] (same reason as Library
-- further down) — a `local function` here would shadow it with a new local,
-- leaving kill()'s reference permanently nil.
clearESP = function()
    for _, h in pairs(espHighlights) do pcall(function() h:Destroy() end) end
    espHighlights = {}
end
local function updateESP()
    if not CFG.TitanESP and not CFG.BossESP then
        if next(espHighlights) then clearESP() end
        return
    end
    local titans = workspace:FindFirstChild("Titans")
    if not titans then return end
    local seen = {}
    for _, t in ipairs(titans:GetChildren()) do
        if t:IsA("Model") and not t:GetAttribute("Dead") and not t:GetAttribute("Killed") then
            local isBoss = BOSS_NAMES[t.Name]
            local want = (isBoss and CFG.BossESP) or (not isBoss and CFG.TitanESP)
            if want then
                seen[t] = true
                local h = espHighlights[t]
                if not h then
                    h = Instance.new("Highlight")
                    h.Name = "TrustHUB_ESP"
                    h.FillTransparency = 0.7
                    h.OutlineTransparency = 0
                    h.Parent = t
                    espHighlights[t] = h
                end
                local color = isBoss and Color3.fromRGB(170, 0, 255) or Color3.fromRGB(255, 0, 0)
                h.FillColor = color
                h.OutlineColor = color
            end
        end
    end
    for t, h in pairs(espHighlights) do
        if not seen[t] then
            pcall(function() h:Destroy() end)
            espHighlights[t] = nil
        end
    end
end
-- Combined 0.5s auxiliary loop: ESP refresh + cutscene skip. These were two
-- separate 0.5s threads doing independent low-frequency work — merged into one
-- to cut a spawned coroutine (fewer parallel tasks = less pressure on the
-- executor's bytecode-patch watcher, which is what's been auto-closing Xeno).
local function auxLoop()
    while ST.running do
        task.wait(0.5)
        updateESP()
        if CFG.AutoSkip then
            local pg = LP:FindFirstChild("PlayerGui")
            local iface = pg and pg:FindFirstChild("Interface")
            local skip = iface and iface:FindFirstChild("Skip")
            if skip and skip.Visible then
                pcall(function()
                    VIM:SendKeyEvent(true, Enum.KeyCode.E, false, game)
                    task.wait(0.05)
                    VIM:SendKeyEvent(false, Enum.KeyCode.E, false, game)
                end)
            end
        end
    end
    clearESP()
end
-- ══════════════════════════════════════════════════════════
-- [11] MAIN FARM LOOP
-- ══════════════════════════════════════════════════════════
local function farmLoop()
    pcall(refreshMapData)
    local titansFolder = workspace:FindFirstChild("Titans")
    local lastMasteryPunch = 0
    while ST.running do
        humanWait(0.1)
        if not CFG.AutoFarm then continue end
        if LP:GetAttribute("Cutscene") then continue end
        local c, hrp = getChar()
        if not hrp then continue end
        if CFG.InjuryRemove then removeInjuries() end
        if CFG.DieAtStreak then checkDieAtStreak() end
        if isGrabbed() then
            if CFG.AutoEscape then escapeGrab(); processAntiGrab() end
            continue
        end
        -- v3.1: refresh map data periodically
        if not ST.mapData then pcall(refreshMapData) end
        -- v3.0: auto-shift
        local isShifted = c:GetAttribute("Shifter") or false
        if CFG.AutoShift and CFG.TitanMastery then
            local bar = LP:GetAttribute("Bar")
            if not isShifted and bar and bar >= 100 then
                pcall(function() GET:InvokeServer("S_Skills", "Usage", "999", false) end)
                task.wait(1)
                continue
            end
        end
        -- Reload is handled entirely by reloadLoop (own 0.5s thread) — the
        -- farm loop just keeps attacking, no reload logic or attack-gating.
        titansFolder = workspace:FindFirstChild("Titans") or titansFolder
        local reqCount = CFG.MultiTarget and CFG.MultiTargetN or 1
        local napes = getValidNapes(reqCount)
        -- v3.1: track Attack Titan spawn time (from RamenHub)
        local atkTitanFound = false
        if titansFolder then
            for _, t in ipairs(titansFolder:GetChildren()) do
                if t.Name == "Attack_Titan" and not t:GetAttribute("Dead") then atkTitanFound = true break end
            end
        end
        if atkTitanFound then
            ST.attackTitanSpawnTime = ST.attackTitanSpawnTime or tick()
        else
            ST.attackTitanSpawnTime = nil
        end
        local atkTitanReady = not atkTitanFound or (ST.attackTitanSpawnTime and (tick() - ST.attackTitanSpawnTime) >= 5)
        -- v3.1: don't kill last titan when <29s left (from RamenHub)
        local mapType = workspace:GetAttribute("Type") or (ST.mapData and ST.mapData.Map and ST.mapData.Map.Type)
        if #napes == 1 and mapType == "Missions" and (workspace:GetAttribute("Seconds") or 999) < 29 then
            napes = {} -- let timer run out with 1 titan left
        end
        if #napes > 0 then
            ST.status = "Farming titans"
            if CFG.TitanMastery and isShifted then
                local titanModel = napes[1]
                while titanModel and titanModel.Parent ~= titansFolder do
                    titanModel = titanModel.Parent
                end
                local titanHRP = titanModel and titanModel:FindFirstChild("HumanoidRootPart")
                if titanHRP then
                    hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                    hrp.CFrame = titanHRP.CFrame * CFrame.new(0, 0, 80)
                end
                local now = tick()
                local mode = CFG.MasteryMode
                local doPunch = mode == "Both" or mode == "Punching"
                local doSkills = mode == "Both" or mode == "Skill Usage"
                if doPunch and ST.canHit and (now - lastMasteryPunch) >= 1 then
                    lastMasteryPunch = now
                    ST.canHit = false
                    comboSlash(napes)
                    ST.lastKill = tick()
                    ST.canHit = true
                end
                -- v3.1: auto-use shifter skills (from RamenHub)
                if doSkills and CFG.ShifterSkills and not ST.shifterSkillsRunning then
                    local data = ST.mapData
                    local slotIdx = LP:GetAttribute("Slot")
                    local slot = slotIdx and data and data.Slots and data.Slots[slotIdx]
                    if slot and slot.Skills and slot.Skills.Shifter then
                        ST.shifterSkillsRunning = true
                        task.spawn(function()
                            local SKIP = {[200]=1,[300]=1,[400]=1,[210]=1,[211]=1,[306]=1,[308]=1,[402]=1,[403]=1,[407]=1}
                            for _, skillId in ipairs(slot.Skills.Shifter) do
                                local n = tonumber(skillId)
                                if n and not SKIP[n] then
                                    pcall(function() GET:InvokeServer("S_Skills", "Usage", tostring(skillId), false) end)
                                end
                                task.wait(1)
                            end
                            ST.shifterSkillsRunning = false
                        end)
                    end
                end
            else
                if not atkTitanReady then task.wait() continue end
                local dist = moveToNape(hrp, napes[1])
                -- Don't swing at a titan with an empty blade — it does nothing.
                -- Keep moving to the target, but hold the attack until the
                -- reloadLoop tops durability back up (bladeDurability is nil for
                -- spears, so this gate never blocks them).
                local dur = bladeDurability()
                local outOfBlades = (dur ~= nil and dur <= 0)
                if outOfBlades then
                    ST.status = "Reloading blades"
                    ST.bladeEmptySince = ST.bladeEmptySince or tick()
                    -- Fail-open: if the reloadLoop somehow hasn't refilled
                    -- durability after 4s, swing anyway rather than freeze
                    -- forever waiting on a reload that isn't landing.
                    if tick() - ST.bladeEmptySince > 4 then outOfBlades = false end
                else
                    ST.bladeEmptySince = nil
                end
                if dist <= CFG.AttackRange and ST.canHit and not outOfBlades then
                    ST.canHit = false
                    comboSlash(napes)
                    ST.lastKill = tick()
                    ST.canHit = true
                end
            end
        else
            ST.status = "Waiting for titans"
            hrp.AssemblyLinearVelocity = Vector3.new(0, 5, 0)
        end
    end
end
-- ══════════════════════════════════════════════════════════
-- [12] COUNTDOWN GUI (visual timer on screen)
-- ══════════════════════════════════════════════════════════
local function showCountdown(seconds, msg)
    local sg = Instance.new("ScreenGui", LP:FindFirstChild("PlayerGui"))
    sg.Name = "TrustHUB_Countdown"
    sg.ResetOnSpawn = false
    local txt = Instance.new("TextLabel", sg)
    txt.Size = UDim2.new(0, 300, 0, 50)
    txt.Position = UDim2.new(0.5, -150, 0, 20)
    txt.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    txt.BackgroundTransparency = 0.3
    txt.TextColor3 = Color3.fromRGB(255, 80, 80)
    txt.Font = Enum.Font.GothamBold
    txt.TextSize = 20
    txt.TextStrokeTransparency = 0.5
    local corner = Instance.new("UICorner", txt)
    corner.CornerRadius = UDim.new(0, 8)
    for i = seconds, 1, -1 do
        txt.Text = msg .. " in " .. i .. "s"
        task.wait(1)
    end
    txt.Text = msg .. " NOW!"
    task.wait(1)
    sg:Destroy()
end
-- ══════════════════════════════════════════════════════════
-- [13] AUTO-START / AUTO-RETRY / FAILSAFE
-- ══════════════════════════════════════════════════════════
local function lobbyLoop()
    while ST.running do
        task.wait(2)
        local mapAttr = workspace:GetAttribute("Map")
        local isLobby = mapAttr and string.find(string.lower(tostring(mapAttr)), "lobby")
        -- Auto Upgrade Gear used to only run on upgradeLoop's blind 15s
        -- timer, wherever the player happened to be. Firing it once right on
        -- lobby arrival (the only place S_Equipment/Upgrade is actually
        -- meant to be used) means gear is maxed *before* the next
        -- getMaxClearableDiffIdx() call below picks a difficulty from it.
        if isLobby and not ST.wasInLobby and CFG.AutoUpGear then
            task.spawn(upgradeAllGear)
        end
        -- Multi-account boot: pick a slot if we joined without one.
        if isLobby and CFG.AutoSelectSlot and not LP:GetAttribute("Slot") then
            task.spawn(doAutoSelectSlot)
        end
        ST.wasInLobby = isLobby
        if not isLobby then
            ST.stayedInLobby = false -- we left the lobby: current difficulty tier worked, keep it
        end
        if isLobby and CFG.AutoStart then
            -- "Hardest" in the Difficulty dropdown and the standalone Auto
            -- Difficulty toggle both mean the same thing: stop using a fixed
            -- CFG.Difficulty string and compute it from real gear Potential.
            local useAutoCap = CFG.AutoDifficulty or CFG.Difficulty == "Hardest"
            if useAutoCap then
                if ST.stayedInLobby then
                    -- previous attempt didn't leave the lobby (gear too low for
                    -- that tier): step down one difficulty and retry.
                    ST.autoDiffIdx = math.min(ST.autoDiffIdx + 1, #diffOrderHardToEasy)
                    warn("[Trust-HUB] Mission didn't start, trying lower difficulty: " .. diffOrderHardToEasy[ST.autoDiffIdx])
                else
                    -- Fresh attempt: start at the HARDEST tier and let the
                    -- server's own gear gate reject it (→ step down above).
                    -- The gear Potential can't be read in the lobby at all
                    -- (Data/Copy returns nil there, confirmed live), so a
                    -- potential-based pick would always compute 0 → Easy;
                    -- trying hardest-first and stepping down on rejection is
                    -- the only thing that actually lands the true max tier,
                    -- and it's what the friend's RamenHub "Hardest" does too.
                    ST.autoDiffIdx = 1
                end
            end
            ST.stayedInLobby = true -- cleared below once we leave the lobby
            local difficulty = useAutoCap and diffOrderHardToEasy[ST.autoDiffIdx] or CFG.Difficulty
            ST.status = "Starting mission (" .. tostring(difficulty) .. ")"
            if CFG.StartDelay > 0 then
                showCountdown(CFG.StartDelay, "Starting Mission")
            end
            local tbl = {
                Name       = CFG.MapName,
                Difficulty = difficulty,
                Type       = CFG.StartType,
                Objective  = CFG.Objective,
                Minimum    = CFG.SoloOnly and 0 or 1,
            }
            if CFG.Modifiers and #CFG.Modifiers > 0 then
                tbl.Modifiers = CFG.Modifiers
            end
            local ok, err = pcall(function() GET:InvokeServer("S_Missions", "Create", tbl) end)
            if not ok then
                warn("[Trust-HUB] S_Missions Create failed: " .. tostring(err))
                tbl.Modifiers = nil
                local ok2, err2 = pcall(function() GET:InvokeServer("S_Missions", "Create", tbl) end)
                if not ok2 then
                    warn("[Trust-HUB] S_Missions Create retry failed: " .. tostring(err2))
                end
            end
            task.wait(2)
            local okStart, errStart = pcall(function() GET:InvokeServer("S_Missions", "Start") end)
            if not okStart then
                warn("[Trust-HUB] S_Missions Start failed: " .. tostring(errStart))
            end
            task.wait(5)
        end
        do
            -- Real end-of-mission screen: PlayerGui.Interface.Rewards
            -- (CanvasGroup, .Visible toggles). Reward accounting + game count
            -- run REGARDLESS of Auto Retry (so stats track even when you
            -- retry manually); only the actual Retry/Leave click is gated on
            -- CFG.AutoRetry. Everything is edge-guarded (ST.rewardsSeen) so it
            -- fires exactly once per screen.
            local pg = LP:FindFirstChild("PlayerGui")
            local iface = pg and pg:FindFirstChild("Interface")
            local rewards = iface and iface:FindFirstChild("Rewards")
            if rewards and rewards.Visible then
                if not ST.rewardsSeen then
                    ST.rewardsSeen = true
                    -- Exact payout from S_Rewards/Get(.Obtained) — the true
                    -- gold/gems/XP, far better than diffing Topbar gold text.
                    local ob
                    pcall(function()
                        local res = GET:InvokeServer("S_Rewards", "Get", true)
                        if res and res.Obtained then
                            ob = res.Obtained
                            SESSION.goldEarned = SESSION.goldEarned + (tonumber(ob.Gold) or 0)
                            SESSION.gemsEarned = (SESSION.gemsEarned or 0) + (tonumber(ob.Gems) or 0)
                            SESSION.xpEarned   = (SESSION.xpEarned or 0) + (tonumber(ob.XP) or 0)
                        end
                    end)
                    -- Webhook: send the payout to the user's configured Discord.
                    if CFG.RewardWebhook or CFG.MythicalWebhook or CFG.DropLog then
                        -- Red rarity tint = mythical/secret. Also collect every
                        -- item name from the rewards frames for the drop log.
                        local special, allDrops = {}, {}
                        pcall(function()
                            local itemsFrame = rewards.Main.Info.Main.Items
                            for _, v in ipairs(itemsFrame:GetChildren()) do
                                local inner = v:IsA("Frame") and v:FindFirstChild("Main") and v.Main:FindFirstChild("Inner")
                                if inner then
                                    local nm = (tostring(v.Name):gsub("_", " "))
                                    local qty = inner:FindFirstChild("Quantity")
                                    allDrops[#allDrops + 1] = nm .. (qty and (" x" .. tostring(qty.Text)) or "")
                                    if inner:FindFirstChild("Rarity") and inner.Rarity.BackgroundColor3 == Color3.fromRGB(255, 0, 0) then
                                        special[#special + 1] = nm
                                    end
                                end
                            end
                        end)
                        local hasSpecial = #special > 0
                        local g  = ob and ob.Gold or 0
                        local gm = ob and ob.Gems or 0
                        local xp = ob and ob.XP or 0
                        -- Full drop log (every mission) — separate embed.
                        if CFG.DropLog and #allDrops > 0 then
                            sendWebhook({
                                title = "📦 Drop Log",
                                description = "**" .. LP.Name .. "**\n" .. table.concat(allDrops, "\n"),
                                color = 8421504,
                            })
                        end
                        -- Reward summary / mythical ping.
                        if CFG.RewardWebhook or (hasSpecial and CFG.MythicalWebhook) then
                            local desc = ("**User:** %s\n**Gold:** %s\n**Gems:** %s\n**XP:** %s"):format(LP.Name, tostring(g), tostring(gm), tostring(xp))
                            if hasSpecial then desc = desc .. "\n**🔥 Special:** " .. table.concat(special, ", ") end
                            sendWebhook({
                                title = hasSpecial and "🔥 MYTHICAL / SECRET DROP" or "✅ Mission Complete",
                                description = desc,
                                color = hasSpecial and 16711680 or 3092790,
                            }, (hasSpecial and CFG.MythicalWebhook) and "@everyone" or nil)
                        end
                    end
                    if CFG.AutoChest then
                        pcall(function()
                            for _, d in ipairs(pg:GetDescendants()) do
                                if d:IsA("ProximityPrompt") and (d.ObjectText:lower():match("chest") or d.ActionText:lower():match("open")) then
                                    fireproximityprompt(d)
                                end
                            end
                        end)
                        task.wait(1)
                    end
                    ST.gameCount = ST.gameCount + 1
                    local wantLeave = CFG.AutoReturn and ST.gameCount >= CFG.ReturnAfter
                    if wantLeave then ST.gameCount = 0 end
                    SESSION.gameCount = ST.gameCount
                    saveSession(SESSION)
                    -- Real handlers (Modules.Utilities.Interactions):
                    --   Retry: GET:InvokeServer("Functions","Retry","Add")
                    --   Leave: POST:FireServer("Functions","Teleport")
                    if CFG.AutoRetry then
                        if wantLeave then
                            ST.status = "Returning to lobby"
                            pcall(function() POST:FireServer("Functions", "Teleport") end)
                        else
                            ST.status = "Retrying mission"
                            pcall(function() return GET:InvokeServer("Functions", "Retry", "Add") end)
                        end
                        task.wait(5)
                    end
                end
            else
                ST.rewardsSeen = false -- screen closed: re-arm for the next mission
            end
        end
        if CFG.FailSafe and (tick() - ST.lastKill) > (CFG.FailSafeMins * 60) then
            pcall(function()
                TPS:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP)
            end)
        end
    end
end
-- ══════════════════════════════════════════════════════════
-- [14] CUTSCENE SKIP
-- ══════════════════════════════════════════════════════════
-- Confirmed live: the mission-intro skip prompt is PlayerGui.Interface.Skip
-- (a CanvasGroup), toggled via its .Visible property, and reads "SKIP [E]" —
-- it's a keybind prompt, not a clickable button. The old code hunted for a
-- TextButton/ImageButton named "cutscene"/"cinematic" with Activated to fire,
-- which never existed here — that's why even a manual click never worked,
-- there was nothing to click.
-- ══════════════════════════════════════════════════════════
-- [15] AUTO-UPGRADE + SKILL TREE (v3.1 RamenHub integration)
-- ══════════════════════════════════════════════════════════
local BLADE_SKILL_IDS = {"3","7","14","23","26","35","107","108","164","165"}
local SUPPORT_SKILL_IDS = {"76","93","95","97","103","158","163"}
-- v3.1: Full skill tree paths (from RamenHub) — ordered unlock IDs
local SKILL_TREE = {
    Blades = {
        Damage   = {"1","2","3","4","5","6","7","8","9","10","11","12","13","26","27","28","29","30","31","32","33","34","35","36","37"},
        Critical = {"1","2","3","4","5","6","7","8","9","10","11","12","13","14","15","16","17","18","19","20","21","22","23","24","25"},
    },
    Spears = {
        Damage   = {"113","114","115","116","117","118","119","120","121","122","123","124","125","138","139","140","141","142","143","144","145","146","147","148","149"},
        Critical = {"113","114","115","116","117","118","119","120","121","122","123","124","125","126","127","128","129","130","131","132","133","134","135","136","137"},
    },
    Defense = {
        Health           = {"38","39","40","41","42","43","44","45","46","47","48","49","50","51","52","53","54","55","56","57"},
        ["Damage Reduction"] = {"38","39","40","41","42","43","44","45","58","59","60","61","62","63","64","65","66","67","68","69"},
    },
    Support = {
        Regen              = {"70","71","72","73","74","75","76","77","78","79","80","81","82","83","84","85","86","87","88","89"},
        ["Cooldown Reduction"] = {"70","71","72","73","74","75","76","77","78","79","80","90","91","92","93","94","95","96","97","98"},
    },
}
-- Upgrades happen in the lobby only — firing the remote mid-mission is wasted
-- calls (and Data/Copy returns nil there anyway, confirmed live).
local function isInLobby()
    local mapAttr = workspace:GetAttribute("Map")
    return mapAttr and string.find(string.lower(tostring(mapAttr)), "lobby") ~= nil
end
-- Real upgrade stat keys, read live from the game's own upgrade UI
-- (Interface.Equipment.Stats.<Weapon>) and confirmed accepted by the server:
--   * The remote wants a LIST, not a bare string — GET:InvokeServer(
--     "S_Equipment","Upgrade",{"ODM_Damage"}) returns a table (accepted),
--     while the bare string "ODM_Damage" returns nil (ignored). This single
--     detail is why Auto Upgrade never did anything before.
--   * Crit keys are the un-prefixed data names (Crit_Damage/Crit_Chance), not
--     the UI CanvasGroup names (ODM_Crit_Damage) — the server rejects the
--     prefixed form.
--   * The server validates the stat against the equipped weapon: ODM_* only
--     lands on Blades, TS_* only on Spears. Sending the wrong weapon's list
--     just returns nil, so we can auto-detect by trying Blades then Spears.
local BLADE_UPGRADES = {"ODM_Damage","ODM_Gas","ODM_Speed","ODM_Range","ODM_Control","Crit_Damage","Crit_Chance","Blade_Durability"}
local SPEAR_UPGRADES = {"TS_Damage","TS_Gas","TS_Speed","TS_Range","TS_Control","Crit_Damage","Crit_Chance","Blast_Radius"}
-- One Upgrade call = one level bought on the cheapest affordable stat in the
-- list (returns a table when it upgraded something, nil when it couldn't —
-- out of gold, or everything maxed). To actually spend the whole balance we
-- have to call it repeatedly until it returns nil, not just once.
local _upgradeRunning = false
upgradeAllGear = function()
    if not isInLobby() or _upgradeRunning then return false end
    _upgradeRunning = true
    task.spawn(function()
        ST.status = "Upgrading gear"
        -- Detect the equipped weapon once (last-known first, else the other):
        -- send its list; a table back means it's the right weapon.
        local order = (ST.weaponType == "Spears")
            and { {"Spears", SPEAR_UPGRADES}, {"Blades", BLADE_UPGRADES} }
            or  { {"Blades", BLADE_UPGRADES}, {"Spears", SPEAR_UPGRADES} }
        local list, bought = nil, 0
        for _, pair in ipairs(order) do
            local ok, result = pcall(function() return GET:InvokeServer("S_Equipment", "Upgrade", pair[2]) end)
            if ok and type(result) == "table" then
                ST.weaponType = pair[1]
                list = pair[2]
                bought = 1
                break
            end
        end
        -- Keep buying on the detected weapon's list until the server says no
        -- (nil). Cap iterations so a weird server response can't spin forever.
        if list then
            for _ = 1, 300 do
                local ok, result = pcall(function() return GET:InvokeServer("S_Equipment", "Upgrade", list) end)
                if not (ok and type(result) == "table") then break end
                bought = bought + 1
                task.wait(0.06) -- fast, but not a tight spin (executor pressure)
            end
        end
        if Library then
            Library:Notify(bought > 0 and ("Bought " .. bought .. " gear upgrade(s)") or "Upgrade: not enough Gold / maxed", 3)
        end
        _upgradeRunning = false
    end)
    return true
end
local function trySkillUnlock(id)
    return pcall(function() return GET:InvokeServer("S_Equipment", "Unlock", { id }) end)
end
local function autoSkillTreeCycle()
    local path = SKILL_TREE[CFG.SkillTreePath]
    if not path then return end
    local ids = path[CFG.SkillTreeSub]
    if not ids then return end
    for _, id in ipairs(ids) do
        trySkillUnlock(id)
        task.wait(0.2)
    end
end
-- ══════════════════════════════════════════════════════════
-- [15a] LOBBY AUTOMATION (v3.2 — prestige / perk enhance / achievements)
-- ══════════════════════════════════════════════════════════
-- Account-wide data (Slots/Perks/Currency) for lobby features.
-- Confirmed live: on Xeno the "Functions"/"Settings"/"Get" remote returns nil
-- (the real account data lives in the character Actor's Cache.Data, a parallel
-- Luau VM Xeno can't reach — no getactors). So we try, in order:
--   1) the remote (works on some executors),
--   2) getsenv() on the Actor Host script (works where getsenv crosses the
--      Actor boundary, e.g. Real),
--   3) getactors() + each actor's env (best-effort),
-- and return nil if none work — callers no-op gracefully. This is why Auto
-- Enhance needs a fuller executor; Auto Prestige avoids it by reading Topbar.
local function getAccountData()
    local ok, r = pcall(function() return GET:InvokeServer("Functions", "Settings", "Get") end)
    if ok and type(r) == "table" and r.Slots then return r end
    if type(getsenv) == "function" then
        local host
        for _, d in ipairs(workspace:GetDescendants()) do
            if d.Name == "Host" and d:IsA("LocalScript") then host = d break end
        end
        if host then
            local ok2, env = pcall(getsenv, host)
            if ok2 and type(env) == "table" then
                local cache = rawget(env, "Cache") or env.Cache
                if type(cache) == "table" and type(cache.Data) == "table" and cache.Data.Slots then
                    return cache.Data
                end
            end
        end
    end
    return nil
end
-- Perk name -> rarity, for filtering "food" perks when enhancing. Static data.
local PERK_RARITY = {}
do
    local perksByRarity = {
        Common = {"Cripple","Lucky","Enhanced Metabolism","First Aid","Mighty","Fortitude","Hollow","Gear Beginner","Enduring"},
        Rare = {"Blessed","Gear Intermediate","Unyielding","Fully Stocked","Forceful","Lightweight","Protection","Mangle","Experimental Shells","Critical Hunter","Tough","Heightened Vitality"},
        Epic = {"Munitions Expert","Gear Expert","Butcher","Resilient","Speedy","Reckless Abandon","Focus","Stalwart Durability","Adrenaline","Safeguard","Warrior","Solo","Mutilate","Trauma Battery","Hardy","Unbreakable","Siphoning","Flawed Release","Luminous","Peerless Strength"},
        Legendary = {"Peerless Commander","Indefatigable","Tyrant's Stare","Invincible","Eviscerate","Font of Vitality","Flame Rhapsody","Robust","Sixth Sense","Gear Master","Carnifex","Munitions Master","Sanctified","Wind Rhapsody","Peerless Constitution","Exhumation","Warchief","Peerless Focus","Perfect Form","Courage Catalyst","Aegis","Unparalleled Strength","Perfect Soul"},
    }
    for rarity, names in pairs(perksByRarity) do
        for _, n in ipairs(names) do PERK_RARITY[n] = rarity end
    end
end
local PRESTIGE_TALENTS = {
    "Blitzblade","Crescendo","Swiftshot","Surgeshot","Guardian","Deflectra","Mendmaster","Cooldown Blitz",
    "Stalwart","Stormcharged","Aegisurge","Riposte","Lifefeed","Vitalize","Gem Fiend","Luck Boost","EXP Boost",
    "Gold Boost","Furyforge","Quakestrike","Assassin","Amputation","Steel Frame","Resilience","Vengeflare",
    "Flashstep","Omnirange","Tactician","Gambler","Overslash","Afterimages","Necromantic","Thanatophobia","Apotheosis","Bloodthief",
}
-- One prestige attempt. Gold threshold is read from the Topbar (readGold),
-- NOT the account remote — that remote returns nil on Xeno (account data
-- lives in the Actor VM we can't reach). SAFETY: a threshold of 0 means
-- "disabled" — otherwise enabling this with the default would prestige
-- (reset the account) immediately. The server also validates eligibility,
-- so a call below the real requirement just gets rejected.
local function doAutoPrestige()
    if CFG.PrestigeGoldM <= 0 then return end
    local gold = readGold()
    if not gold or gold < (CFG.PrestigeGoldM * 1e6) then return end
    for _, talent in ipairs(PRESTIGE_TALENTS) do
        local ok, res = pcall(function()
            return GET:InvokeServer("S_Equipment", "Prestige", { Boosts = CFG.PrestigeBoost, Talents = talent })
        end)
        if ok and res then
            if Library then Library:Notify("Prestiged (" .. CFG.PrestigeBoost .. " / " .. talent .. ")", 5) end
            return
        end
        task.wait(0.1)
    end
end
-- One perk-enhance pass: feed the equipped perk in CFG.PerkSlot with up to 5
-- storage perks whose rarity is selected as food. Enhance payload is a dict
-- {[perkId]=qty}, confirmed by the TITANIC hub.
local function doAutoEnhance()
    local data = getAccountData()
    local slot = LP:GetAttribute("Slot")
    local sd = slot and data and data.Slots and data.Slots[slot]
    if not sd or not sd.Perks then return end
    local equippedId = sd.Perks.Equipped and sd.Perks.Equipped[CFG.PerkSlot]
    local storage = sd.Perks.Storage
    if not equippedId or not storage then return end
    local wantRarity = {}
    for _, r in ipairs(CFG.FoodRarities) do wantRarity[r] = true end
    local food, count = {}, 0
    for perkId, tbl in pairs(storage) do
        if count >= 5 then break end
        if perkId ~= equippedId and wantRarity[PERK_RARITY[tbl.Name]] then
            food[perkId] = 1
            count = count + 1
        end
    end
    if count == 0 then return end
    local ok, res = pcall(function()
        return GET:InvokeServer("S_Equipment", "Enhance", equippedId, food)
    end)
    if ok and res and Library then Library:Notify("Enhanced perk (+" .. count .. " food)", 3) end
end
-- One achievements-claim sweep (indices 1..70), from the TITANIC hub.
local function doClaimAchievements()
    local claimed = false
    for i = 1, 70 do
        local ok, res = pcall(function() return GET:InvokeServer("S_Achievements", "Claim", i) end)
        if ok and res ~= nil then claimed = true end
    end
    if claimed and Library then Library:Notify("Claimed achievements", 3) end
end
-- ══════════════════════════════════════════════════════════
-- [15a2] MULTI-ACCOUNT / AFK HARDENING (v3.2)
-- ══════════════════════════════════════════════════════════
-- Auto-select a slot when joining with none (needed for hands-off multi-acc
-- boot). Fires the same Functions/Select the slot UI does, then bounces to
-- the lobby so the account is ready to farm.
local function doAutoSelectSlot()
    if LP:GetAttribute("Slot") then return end
    local letter = tostring(CFG.SelectSlot):sub(-1)
    for _ = 1, 8 do
        if LP:GetAttribute("Slot") then break end
        pcall(function() GET:InvokeServer("Functions", "Select", letter) end)
        task.wait(1)
    end
    if LP:GetAttribute("Slot") then
        pcall(function() GET:InvokeServer("Functions", "Teleport", "Lobby") end)
    end
end
-- Suicide at a streak threshold (some farms want to reset the streak for
-- reward pacing). Reads the real LP "Streak" attribute.
checkDieAtStreak = function()
    if not CFG.DieAtStreak then return end
    local streak = LP:GetAttribute("Streak") or 0
    if streak >= CFG.DieStreakN then
        local c = getChar()
        local hum = c and c:FindFirstChildOfClass("Humanoid")
        if hum then hum.Health = 0 end
    end
end
-- Auto-rejoin on a crashed/stuck mission: if BOTH Titans and Unclimbable are
-- missing for two consecutive ~10s checks while farming, the mission has
-- desynced/crashed — teleport back through the lobby to recover. This is the
-- single biggest reliability win for unattended multi-account farming (a
-- crashed client otherwise sits dead forever). Ported from the TITANIC hub.
-- Periodic session report to the webhook (gold/hour, games, totals). Fires
-- every CFG.ReportMins minutes while enabled + a URL is set.
local function sessionReportLoop()
    local nextReport = tick() + (CFG.ReportMins * 60)
    while ST.running do
        task.wait(15)
        if not CFG.SessionReport or CFG.WebhookURL == "" then
            nextReport = tick() + (CFG.ReportMins * 60)
        elseif tick() >= nextReport then
            nextReport = tick() + (CFG.ReportMins * 60)
            local el = math.max(os.time() - SESSION.sessionStart, 1)
            local perHr = math.floor(SESSION.goldEarned / el * 3600)
            local desc = ("**User:** %s\n**Session:** %s\n**Missions:** %d\n**Gold:** %s (%s/hr)\n**Gems:** %s\n**XP:** %s"):format(
                LP.Name, formatDuration(el), SESSION.gameCount,
                formatNumber(SESSION.goldEarned), formatNumber(perHr),
                formatNumber(SESSION.gemsEarned or 0), formatNumber(SESSION.xpEarned or 0))
            sendWebhook({ title = "📊 Session Report", description = desc, color = 5793266 })
        end
    end
end
local function crashRejoinLoop()
    while ST.running do
        task.wait(10)
        if not CFG.AutoRejoin or isInLobby() or not CFG.AutoFarm then continue end
        local titans = workspace:FindFirstChild("Titans")
        local unclimb = workspace:FindFirstChild("Unclimbable")
        if not titans and not unclimb then
            task.wait(10)
            if isInLobby() then continue end
            titans = workspace:FindFirstChild("Titans")
            unclimb = workspace:FindFirstChild("Unclimbable")
            if not titans and not unclimb then
                if Library then Library:Notify("Crash detected — rejoining...", 5) end
                pcall(function() GET:InvokeServer("Functions", "Teleport", "Lobby") end)
                task.wait(0.5)
                pcall(function() TPS:Teleport(14916516914, LP) end)
            end
        end
    end
end
-- Auto-join the currently boosted map (2x rewards). In the lobby: read the
-- server's Boosted_Map attribute, leave any pending mission, create the
-- boosted map at the hardest difficulty that starts, optionally apply all
-- modifiers, and start it. In a mission: if the boost changed to a different
-- map, bail back to the lobby to re-pick. Ported from the TITANIC hub.
local BOOST_MODS = {"No Perks","No Skills","No Memories","Nightmare","Oddball","Injury Prone","Chronic Injuries","Fog","Glass Cannon","Time Trial"}
local function boostedMapLoop()
    local lastBoost = nil
    while ST.running do
        task.wait(5)
        if not CFG.AutoBoostedMap then lastBoost = nil continue end
        local boosted = workspace:GetAttribute("Boosted_Map")
        if not isInLobby() then
            -- mid-mission: if the boost moved to another map, return to re-pick
            if boosted and boosted ~= "" and boosted ~= lastBoost then
                pcall(function() GET:InvokeServer("Functions", "Teleport", "Lobby") end)
                task.wait(0.5)
                pcall(function() TPS:Teleport(14916516914, LP) end)
                lastBoost = nil
                task.wait(5)
            end
            continue
        end
        if boosted and boosted ~= "" and boosted ~= lastBoost then
            lastBoost = boosted
            if Library then Library:Notify("Boosted map: " .. boosted .. " — joining", 4) end
            pcall(function()
                for _, m in ipairs(RS.Missions:GetChildren()) do
                    if m:FindFirstChild("Leader") and m.Leader.Value == LP.Name then
                        GET:InvokeServer("S_Missions", "Leave")
                    end
                end
            end)
            task.wait(1)
            local created = false
            for _, diff in ipairs({"Aberrant","Severe","Hard","Normal"}) do
                if created then break end
                pcall(function()
                    GET:InvokeServer("S_Missions", "Create", { Difficulty = diff, Type = "Missions", Name = boosted, Objective = "Skirmish" })
                end)
                task.wait(0.5)
                for _, m in ipairs(RS.Missions:GetChildren()) do
                    if m:FindFirstChild("Leader") and m.Leader.Value == LP.Name then created = true break end
                end
            end
            if created then
                if CFG.AutoModifiers then
                    for _, mod in ipairs(BOOST_MODS) do
                        pcall(function() GET:InvokeServer("S_Missions", "Modify", mod) end)
                        task.wait(0.05)
                    end
                end
                task.wait(0.5)
                pcall(function() GET:InvokeServer("S_Missions", "Start") end)
            end
        end
    end
end
local function upgradeLoop()
    local lastAch = 0
    while ST.running do
        task.wait(15)
        -- All of these apply in the lobby only — skip the whole batch mid-run
        -- so we don't fire dead S_Equipment calls during a mission.
        if not isInLobby() then continue end
        if CFG.AutoSpendSP then
            local ids = (CFG.SkillPath == "Support Skills") and SUPPORT_SKILL_IDS or BLADE_SKILL_IDS
            for _, id in ipairs(ids) do trySkillUnlock(id); task.wait(0.2) end
        end
        if CFG.AutoSkillTree then autoSkillTreeCycle() end
        if CFG.AutoUpGear then upgradeAllGear() end
        if CFG.AutoEnhance then doAutoEnhance() end
        if CFG.AutoPrestige then doAutoPrestige() end
        -- Achievements change rarely — sweep at most once a minute.
        if CFG.AutoClaimAch and tick() - lastAch > 60 then
            lastAch = tick()
            doClaimAchievements()
        end
    end
end
-- ══════════════════════════════════════════════════════════
-- [15b] SESSION STATS PANEL
-- ══════════════════════════════════════════════════════════
-- Old path (Interface.HUD.Main.Top.2.Gold.Title) only exists while a mission
-- is actually loaded — Interface.HUD doesn't exist at all in the lobby
-- (Town Central), confirmed live, which is why the stats panel's Gold row
-- and the Gold/Hour calc both stayed on "--" the whole time the player
-- wasn't mid-mission. The real always-present currency display is the
-- Topbar chrome: Interface.Topbar.Main.Currencies.Gold.Amount, confirmed
-- live in the lobby. Mission HUD path kept as a fallback in case the Topbar
-- is ever hidden mid-mission.
local function readGold()
    local pg = LP:FindFirstChild("PlayerGui")
    local iface = pg and pg:FindFirstChild("Interface")
    local topbar = iface and iface:FindFirstChild("Topbar")
    local currencies = topbar and topbar:FindFirstChild("Main") and topbar.Main:FindFirstChild("Currencies")
    local goldAmount = currencies and currencies:FindFirstChild("Gold") and currencies.Gold:FindFirstChild("Amount")
    if goldAmount then
        return tonumber((tostring(goldAmount.Text or ""):gsub("[^%d]", "")))
    end
    local hud = iface and iface:FindFirstChild("HUD")
    local main = hud and hud:FindFirstChild("Main")
    local top = main and main:FindFirstChild("Top")
    local goldSection = top and top:FindFirstChild("2")
    local gold = goldSection and goldSection:FindFirstChild("Gold")
    local title = gold and gold:FindFirstChild("Title")
    if not title then return nil end
    return tonumber((tostring(title.Text or ""):gsub("[^%d]", "")))
end
local function readMissionKillsText()
    local pg = LP:FindFirstChild("PlayerGui")
    local iface = pg and pg:FindFirstChild("Interface")
    local hud = iface and iface:FindFirstChild("HUD")
    local slay = hud and hud:FindFirstChild("Slay", true)
    return slay and slay.Text or nil -- e.g. "Slay Titans [10/44]"
end
local statsPanel
local ACCENT = Color3.fromRGB(139, 122, 255) -- brighter Tokyo Night accent
local ACCENT2 = Color3.fromRGB(90, 70, 200)
local function buildStatsPanel()
    local pg = LP:FindFirstChild("PlayerGui")
    if not pg then return end
    local existing = pg:FindFirstChild("TrustHUB_StatsPanel")
    if existing then existing:Destroy() end -- re-injection/re-execute leaves the old one orphaned otherwise
    local sg = Instance.new("ScreenGui")
    sg.Name = "TrustHUB_StatsPanel"
    sg.ResetOnSpawn = false
    sg.IgnoreGuiInset = true
    sg.DisplayOrder = 50
    sg.Parent = pg

    -- label -> {emoji icon, is-status?}
    local rowDefs = {
        { "Status",          "🟢" },
        { "Session",         "⏱️" },
        { "Kills (mission)", "⚔️" },
        { "Missions",        "🗺️" },
        { "Gold earned",     "🪙" },
        { "Gems earned",     "💎" },
        { "XP earned",       "✨" },
        { "Gold/Hour",       "📈" },
    }
    local HEAD_H, ROW_H, PAD = 30, 22, 6
    local WIDTH = 244
    local bodyH = #rowDefs * ROW_H + PAD * 2
    local fullH = HEAD_H + bodyH

    -- soft drop shadow behind the panel
    local shadow = Instance.new("ImageLabel", sg)
    shadow.BackgroundTransparency = 1
    shadow.Image = "rbxassetid://5554236805"
    shadow.ScaleType = Enum.ScaleType.Slice
    shadow.SliceCenter = Rect.new(23, 23, 277, 277)
    shadow.ImageColor3 = Color3.fromRGB(0, 0, 0)
    shadow.ImageTransparency = 0.35
    shadow.Size = UDim2.new(0, WIDTH + 30, 0, fullH + 30)

    local frame = Instance.new("Frame", sg)
    frame.Size = UDim2.new(0, WIDTH, 0, fullH)
    frame.Position = UDim2.new(1, -(WIDTH + 14), 0, 90)
    frame.BackgroundColor3 = Color3.fromRGB(18, 18, 26)
    frame.BackgroundTransparency = 0.1
    frame.BorderSizePixel = 0
    frame.Active = true
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
    local stroke = Instance.new("UIStroke", frame)
    stroke.Color = ACCENT
    stroke.Thickness = 1.4
    stroke.Transparency = 0.2
    -- keep the shadow glued behind the frame
    local function syncShadow() shadow.Position = UDim2.new(frame.Position.X.Scale, frame.Position.X.Offset - 15, frame.Position.Y.Scale, frame.Position.Y.Offset - 15) end
    syncShadow()

    -- gradient header (drag handle)
    local header = Instance.new("TextButton", frame)
    header.Size = UDim2.new(1, 0, 0, HEAD_H)
    header.BorderSizePixel = 0
    header.AutoButtonColor = false
    header.Text = ""
    header.BackgroundColor3 = ACCENT2
    Instance.new("UICorner", header).CornerRadius = UDim.new(0, 10)
    local hgrad = Instance.new("UIGradient", header)
    hgrad.Color = ColorSequence.new(ACCENT2, ACCENT)
    hgrad.Rotation = 12
    -- flatten the header's bottom corners (cover the rounded bottom)
    local hFix = Instance.new("Frame", header)
    hFix.BackgroundColor3 = ACCENT2
    hFix.BorderSizePixel = 0
    hFix.Size = UDim2.new(1, 0, 0.5, 0)
    hFix.Position = UDim2.new(0, 0, 0.5, 0)
    local hFixGrad = Instance.new("UIGradient", hFix)
    hFixGrad.Color = ColorSequence.new(ACCENT2, ACCENT)
    hFixGrad.Rotation = 12

    local hTitle = Instance.new("TextLabel", header)
    hTitle.BackgroundTransparency = 1
    hTitle.Position = UDim2.new(0, 12, 0, 0)
    hTitle.Size = UDim2.new(1, -44, 1, 0)
    hTitle.Font = Enum.Font.GothamBold
    hTitle.TextSize = 15
    hTitle.TextXAlignment = Enum.TextXAlignment.Left
    hTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
    hTitle.Text = "⚔️  TRUST-HUB"

    local minBtn = Instance.new("TextButton", header)
    minBtn.Size = UDim2.new(0, 30, 1, 0)
    minBtn.Position = UDim2.new(1, -30, 0, 0)
    minBtn.BackgroundTransparency = 1
    minBtn.Text = "–"
    minBtn.Font = Enum.Font.GothamBold
    minBtn.TextSize = 20
    minBtn.TextColor3 = Color3.fromRGB(255, 255, 255)

    local body = Instance.new("Frame", frame)
    body.Size = UDim2.new(1, 0, 0, bodyH)
    body.Position = UDim2.new(0, 0, 0, HEAD_H)
    body.BackgroundTransparency = 1

    local rows = {}
    for i, def in ipairs(rowDefs) do
        local label, icon = def[1], def[2]
        local isStatus = (label == "Status")
        local rowY = PAD + (i - 1) * ROW_H

        -- left: icon + name
        local name = Instance.new("TextLabel", body)
        name.BackgroundTransparency = 1
        name.Position = UDim2.new(0, 12, 0, rowY)
        name.Size = UDim2.new(0.6, -12, 0, ROW_H - 3)
        name.Font = Enum.Font.Gotham
        name.TextSize = 13
        name.TextXAlignment = Enum.TextXAlignment.Left
        name.TextColor3 = Color3.fromRGB(170, 170, 190)
        name.Text = icon .. "  " .. label:gsub(" %(mission%)", "")

        -- right: value (accent/bold)
        local value = Instance.new("TextLabel", body)
        value.BackgroundTransparency = 1
        value.Position = UDim2.new(0.6, 0, 0, rowY)
        value.Size = UDim2.new(0.4, -12, 0, ROW_H - 3)
        value.Font = Enum.Font.GothamBold
        value.TextSize = 13
        value.TextXAlignment = Enum.TextXAlignment.Right
        value.TextColor3 = isStatus and Color3.fromRGB(150, 230, 150) or Color3.fromRGB(235, 235, 245)
        value.Text = "--"
        rows[label] = { Value = value }
    end

    local minimized = false
    minBtn.MouseButton1Click:Connect(function()
        minimized = not minimized
        body.Visible = not minimized
        shadow.Visible = not minimized
        frame.Size = UDim2.new(0, WIDTH, 0, minimized and HEAD_H or fullH)
        minBtn.Text = minimized and "+" or "–"
    end)

    -- Drag via the header.
    local dragging, dragStart, startPos
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = input.Position; startPos = frame.Position
        end
    end)
    header.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    track(UIS.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
            syncShadow()
        end
    end))

    statsPanel = { Gui = sg, Rows = rows }
end
local lastStatsUpdate = 0
local lastSessionSave = 0
track(RunService.Heartbeat:Connect(function()
    if not statsPanel then return end
    statsPanel.Gui.Enabled = CFG.ShowStatsPanel
    if not CFG.ShowStatsPanel then return end
    local now = tick()
    if now - lastStatsUpdate < 1 then return end
    lastStatsUpdate = now

    do
        local st = ST.status or "Idle"
        local sv = statsPanel.Rows["Status"].Value
        sv.Text = st
        if st:find("Farm") or st:find("Attack") then
            sv.TextColor3 = Color3.fromRGB(120, 230, 120)
        elseif st:find("Reload") or st:find("Wait") or st:find("Start") or st:find("Retry") or st:find("Return") then
            sv.TextColor3 = Color3.fromRGB(240, 200, 110)
        else
            sv.TextColor3 = Color3.fromRGB(180, 180, 200)
        end
    end

    -- Real wall-clock elapsed (survives hops) — not tick(), which is per-Lua
    -- state and resets to ~0 every reload.
    local elapsed = os.time() - SESSION.sessionStart
    statsPanel.Rows["Session"].Value.Text = formatDuration(elapsed)

    local slayText = readMissionKillsText()
    statsPanel.Rows["Kills (mission)"].Value.Text = (slayText and slayText:match("%[(.-)%]") or "--")

    statsPanel.Rows["Missions"].Value.Text = tostring(ST.gameCount)

    -- Gold/Gems/XP come straight from the exact per-mission S_Rewards payout
    -- accumulated at the rewards screen (see lobbyLoop).
    statsPanel.Rows["Gold earned"].Value.Text = formatNumber(SESSION.goldEarned)
    statsPanel.Rows["Gems earned"].Value.Text = formatNumber(SESSION.gemsEarned or 0)
    statsPanel.Rows["XP earned"].Value.Text = formatNumber(SESSION.xpEarned or 0)
    local perHour = elapsed > 5 and math.floor(SESSION.goldEarned / elapsed * 3600) or 0
    statsPanel.Rows["Gold/Hour"].Value.Text = formatNumber(perHour)

    -- Persist the accumulating session every ~10s so a crash/close loses at
    -- most 10s of gold/time, without hammering the disk every second.
    if now - lastSessionSave >= 10 then
        lastSessionSave = now
        SESSION.gameCount = ST.gameCount
        saveSession(SESSION)
    end
end))
-- ══════════════════════════════════════════════════════════
-- [15c] ANTI-AFK
-- ══════════════════════════════════════════════════════════
-- Ported from a friend's RamenHub script: Roblox disconnects idle clients
-- with no input after ~20min, which kills a long unattended farm session
-- outright — VirtualUser simulates real input on the Idled signal so the
-- server never sees the client as idle. Always on, no downside, not gated
-- by a toggle.
do
    local VirtualUser = game:GetService("VirtualUser")
    track(LP.Idled:Connect(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end))
end
-- ══════════════════════════════════════════════════════════
-- [16] ESP & VISUALS
-- ══════════════════════════════════════════════════════════
local function removeFog()
    pcall(function()
        game:GetService("Lighting").FogEnd = 1e6
        game:GetService("Lighting").FogStart = 1e6
        for _, e in ipairs(game:GetService("Lighting"):GetChildren()) do
            if e:IsA("Atmosphere") or e:IsA("BlurEffect") or e:IsA("DepthOfFieldEffect") then
                e:Destroy()
            end
        end
    end)
end
local function deleteMap()
    -- Confirmed live: deleting everything under Unclimbable broke the mission
    -- intro. The game's own Raids/Initiate script expects
    -- Unclimbable.Cutscene to exist ("Cutscene is not a valid member of
    -- Folder Workspace.Unclimbable"); with it gone, Initiate errors out
    -- mid-way and the skip prompt never resolves even after pressing E,
    -- because the cutscene state machine never finished starting.
    pcall(function()
        local u = workspace:FindFirstChild("Unclimbable")
        if u then
            for _, c in ipairs(u:GetChildren()) do
                if c.Name ~= "Reloads" and c.Name ~= "Cutscene" then c:Destroy() end
            end
        end
    end)
end
-- Single noclip enforcer: caches BasePart descendants per-character (instead
-- of re-walking GetDescendants/GetChildren every Stepped) and re-flattens
-- CanCollide on the cache. Runs off CFG.Noclip alone — Noclip is a standalone
-- Visuals toggle, not tied to AutoFarm/ST.running, so it must not require the
-- farm loop to be active.
track(RunService.Stepped:Connect(function()
    if not CFG.Noclip then return end
    local c = getChar()
    if not c then return end
    if c ~= ST.currentChar then
        ST.currentChar = c
        ST.charParts = {}
        for _, p in ipairs(c:GetDescendants()) do
            if p:IsA("BasePart") then table.insert(ST.charParts, p) end
        end
    end
    for i = 1, #ST.charParts do
        local p = ST.charParts[i]
        if p and p.Parent then p.CanCollide = false end
    end
end))
track(LP.CharacterAdded:Connect(function()
    task.wait(1.5)
    ogHitboxSize = nil
    ST.currentChar = nil -- force noclip cache rebuild for the new character
    if ST.running and CFG.NapeExtend then expandNape(true) end
end))
-- ══════════════════════════════════════════════════════════
-- [17] MASTER START / STOP
-- ══════════════════════════════════════════════════════════
local function masterStart()
    ST.running = true
    ST.startT = tick()
    ST.lastKill = tick()
    ST.titanKillCount = 0
    ST.masteryCombo = 1
    -- Session values come from the persisted store (survives hops). lastGold
    -- must ALSO persist: re-seeding it to the current balance on every reload
    -- meant the mission-reward jump (which lands across the mission->lobby
    -- reload boundary) was never seen as a positive delta, so Gold earned
    -- stayed 0. Keep the persisted lastGold across a hop; only seed from the
    -- current balance on a genuine cold start (SESSION.lastGold == nil).
    ST.gameCount = SESSION.gameCount
    if SESSION.lastGold == nil then SESSION.lastGold = readGold() end
    _notifiedNapes = {}
    buildStatsPanel()
    if CFG.DeleteMap then deleteMap() end
    if CFG.RemoveFog then removeFog() end
    pcall(refreshMapData)
    -- v3.0: ban check on load
    if CFG.BanCheckOnLoad then
        task.spawn(function()
            task.wait(3)
            local banned, keys = checkBanStatus()
            if banned then
                warn("[Trust-HUB] SHADOW BAN DETECTED: " .. table.concat(keys, ", "))
                if Library then Library:Notify("BAN DETECTED: " .. table.concat(keys, ", "), 15) end
            end
        end)
    end
    trackThread(farmLoop)
    trackThread(lobbyLoop)
    trackThread(upgradeLoop)
    trackThread(auxLoop) -- ESP + cutscene skip merged
    trackThread(reloadLoop) -- blade durability + set refill
    trackThread(crashRejoinLoop) -- multi-account: recover a crashed mission
    trackThread(boostedMapLoop) -- auto-join the 2x boosted map
    trackThread(sessionReportLoop) -- periodic webhook session report
    -- Ban-attribute clearing already happens reactively via the
    -- AttributeChanged connection set up in [2]; a second 0.5s polling loop
    -- doing the exact same clear on the exact same attribute list was pure
    -- redundant work, not an actual fallback (AttributeChanged fires
    -- synchronously on every set, there's no gap for polling to catch).
end
local function masterStop()
    ST.running = false
    for _, th in ipairs(threads) do pcall(function() task.cancel(th) end) end
    threads = {}
    clearESP()
end
-- ══════════════════════════════════════════════════════════
-- [18] OBSIDIAN UI
-- ══════════════════════════════════════════════════════════
local repo = 'https://raw.githubusercontent.com/mstudio45/LinoriaLib/refs/heads/main/'
Library      = loadstring(game:HttpGet(repo .. 'Library.lua'))() -- assigns the forward-declared upvalue, not a new local
local ThemeManager = loadstring(game:HttpGet(repo .. 'addons/ThemeManager.lua'))()
local SaveManager  = loadstring(game:HttpGet(repo .. 'addons/SaveManager.lua'))()
local Window = Library:CreateWindow({
    Title    = "⚔️ TRUST-HUB v2.0 | " .. LP.Name,
    Center   = true,
    AutoShow = true,
    UnlockMouseWhileOpen = true, -- library defaults this true, but the game's own ODM
                                 -- camera-lock control script fights it every frame during
                                 -- combat, winning the race and re-locking the mouse — see
                                 -- the reactive override connected below, which is what
                                 -- actually fixes the cursor not showing mid-mission.
})
-- Reactive cursor-lock override: the game's ODM flight controller re-asserts
-- MouseBehavior/hides the icon every frame it runs, racing LinoriaLib's own
-- UnlockMouseWhileOpen handling and usually winning it during combat. Snap it
-- back the instant it changes while our menu is open, instead of fighting it
-- once per Toggle call.
-- Cursor fix stays a Heartbeat: the reactive property-changed version missed
-- the case where the menu opens while the icon is ALREADY hidden (no property
-- change fires, so it never re-shows) and lost the cursor mid-mission. A
-- per-frame check of two booleans is negligible next to the farm loop; the
-- executor auto-close is the bytecode watcher, not this.
track(RunService.Heartbeat:Connect(function()
    if Library and Library.Toggled then
        if not UIS.MouseIconEnabled then UIS.MouseIconEnabled = true end
        if UIS.MouseBehavior ~= Enum.MouseBehavior.Default then
            UIS.MouseBehavior = Enum.MouseBehavior.Default
        end
    end
end))
local Options = Library.Options -- was missing: D_MapName callback indexed a nil global, threw
                                 -- "attempt to index nil with 'D_Objective'" on every map change
                                 -- (including at load, since Default=1 fires the callback),
                                 -- leaving Objective/Mission config stuck — this was why auto-start
                                 -- never actually started a mission.
-- ═══ TAB: FARM (what to farm) ═══
local TabFarm = Window:AddTab("Farm")
local gMission = TabFarm:AddLeftGroupbox("Mission Selection")
gMission:AddDropdown("D_StartType", { Text = "Start Type",  Values = {"Missions","Raids"}, Default = 1, Callback = function(v) CFG.StartType = v end })
gMission:AddDropdown("D_MapName",   { Text = "Map",         Values = mapList,  Default = 1, Callback = function(v)
    CFG.MapName = v
    local validObjs = getObjsForMap(v, CFG.StartType)
    -- D_MapName's Default=1 fires this Callback synchronously during AddDropdown,
    -- before D_Objective (declared further below) has been created — guard against that.
    if Options.D_Objective then
        Options.D_Objective:SetValues(validObjs)
        Options.D_Objective:SetValue(validObjs[1])
    end
    CFG.Objective = validObjs[1]
end})
gMission:AddDropdown("D_Objective", { Text = "Objective",   Values = getObjsForMap("Shiganshina"),  Default = 1, Callback = function(v) CFG.Objective = v end })
gMission:AddDropdown("D_Difficulty",{ Text = "Difficulty (manual, ignored when Auto Difficulty is on)",  Values = diffList, Default = 5, Callback = function(v) CFG.Difficulty = v end })
gMission:AddDropdown("D_Mods",     { Text = "Modifiers",   Values = modMap,   Default = {}, Multi = true, Callback = function(v)
    local m = {}
    for k, st in pairs(v) do if st then table.insert(m, k) end end
    CFG.Modifiers = m
end})
gMission:AddButton({ Text = "Select All Modifiers", Func = function()
    local allSelected = {}
    for _, name in ipairs(modMap) do allSelected[name] = true end
    Options.D_Mods:SetValue(allSelected) -- fires the Callback above and still opens editable afterward
end})
local gForce = TabFarm:AddRightGroupbox("Manual")
gForce:AddButton({ Text = "Force Return to Lobby", Func = function() pcall(function() GET:InvokeServer("Functions", "Teleport", "Lobby") end) end })
gForce:AddButton({ Text = "Upgrade Gear Now", Func = function() upgradeAllGear() end })
gForce:AddButton({ Text = "EMERGENCY STOP", Func = function() masterStop(); Library:Notify("EMERGENCY STOP!", 5) end })
-- v2.0: one-click AFK presets. Each sets the whole config in the right order
-- (type/map before objective, since the objective list depends on the map).
local ALL_MODS = {}
for _, name in ipairs(modMap) do ALL_MODS[name] = true end
local function setTog(key, val) pcall(function() if Toggles[key] then Toggles[key]:SetValue(val) end end) end
local function setOpt(key, val) pcall(function() if Options[key] then Options[key]:SetValue(val) end end) end
local function applyPreset(map, objective, opts)
    opts = opts or {}
    setOpt("D_StartType", "Missions")
    setOpt("D_MapName", map)
    task.wait(0.05)
    setOpt("D_Objective", objective)
    setOpt("D_Difficulty", "Hardest")
    setOpt("D_Mods", ALL_MODS)
    -- movement
    setOpt("D_MoveMode", opts.move or "Teleport")
    if opts.height then setOpt("S_Height", opts.height) end
    setTog("T_Noclip", true)
    -- combat
    setTog("T_AutoReload", true)
    setTog("T_AutoEscape", true)
    setTog("T_MultiTarget", opts.multi ~= false)
    -- flow
    setTog("T_DeleteMap", opts.deleteMap ~= false)
    setTog("T_SoloOnly", true)
    setTog("T_AutoRetry", true)
    setTog("T_AutoRejoin", true)
    setTog("T_AutoStart", true)
    setTog("T_AutoFarm", true)
    Library:Notify("Preset applied: " .. map .. " / " .. objective .. " / Hardest", 5)
end
local gPreset = TabFarm:AddLeftGroupbox("Quick Presets (1-click AFK)")
gPreset:AddButton({ Text = "AFK Farm — Breach (Shiganshina)", Func = function() applyPreset("Shiganshina", "Breach", { height = 170 }) end })
gPreset:AddButton({ Text = "AFK Farm — Defend (Utgard)",      Func = function() applyPreset("Utgard", "Defend", { height = 170 }) end })
gPreset:AddButton({ Text = "AFK Farm — Stall (Docks)",        Func = function() applyPreset("Docks", "Stall", { height = 310, multi = false, deleteMap = false }) end })
gPreset:AddButton({ Text = "Boosted Map Farm (2x)", Func = function()
    setTog("T_AutoModifiers", true)
    setTog("T_AutoBoostedMap", true)
    setTog("T_AutoReload", true); setTog("T_AutoEscape", true); setTog("T_Noclip", true)
    setTog("T_AutoRetry", true); setTog("T_AutoRejoin", true); setTog("T_AutoFarm", true)
    Library:Notify("Boosted-map farm armed — will join the 2x map", 5)
end})
-- ═══ TAB: AFK ENGINE (everything needed to leave the game running unattended) ═══
local TabAFK = Window:AddTab("AFK Engine")
local gStart  = TabAFK:AddLeftGroupbox("Auto Start && Retry")
gStart:AddToggle("T_AutoStart",  { Text = "Auto Start Mission",     Default = false, Callback = function(v) CFG.AutoStart = v end })
gStart:AddToggle("T_SoloOnly",   { Text = "Solo Only (Min 0)",      Default = true,  Callback = function(v) CFG.SoloOnly = v end })
gStart:AddToggle("T_AutoRetry",  { Text = "Auto Retry",             Default = true,  Callback = function(v) CFG.AutoRetry = v end })
gStart:AddToggle("T_AutoReturn", { Text = "Auto Return Lobby",      Default = false, Callback = function(v) CFG.AutoReturn = v end })
gStart:AddSlider("S_ReturnAfter",{ Text = "Return After X Games",   Default = 10, Min = 1, Max = 50, Rounding = 0, Callback = function(v) CFG.ReturnAfter = v end })
gStart:AddSlider("S_StartDelay", { Text = "Auto-Start Timer (sec)", Default = 5, Min = 0, Max = 30, Rounding = 0, Callback = function(v) CFG.StartDelay = v end })
gStart:AddToggle("T_AutoDiff",  { Text = "Auto Difficulty (real gear cap)", Default = false, Callback = function(v) CFG.AutoDifficulty = v end })
local gFlow = TabAFK:AddRightGroupbox("Unattended Safety")
gFlow:AddToggle("T_AutoSkip",  { Text = "Auto Skip Cutscene",  Default = false, Callback = function(v) CFG.AutoSkip = v end })
gFlow:AddToggle("T_AutoChest", { Text = "Auto Open Chests",     Default = false, Callback = function(v) CFG.AutoChest = v end })
gFlow:AddToggle("T_FailSafe",  { Text = "Failsafe (Rejoin)",    Default = true,  Callback = function(v) CFG.FailSafe = v end })
gFlow:AddSlider("S_FailSafe",  { Text = "Failsafe Minutes",     Default = 15, Min = 5, Max = 60, Rounding = 0, Callback = function(v) CFG.FailSafeMins = v end })
gFlow:AddToggle("T_BanCheck",  { Text = "Ban Check on Load",    Default = true,  Callback = function(v) CFG.BanCheckOnLoad = v end })
gFlow:AddButton({ Text = "Check Ban Status", Func = function()
    local banned, keys = checkBanStatus()
    if banned then
        Library:Notify("BAN DETECTED: " .. table.concat(keys, ", "), 10)
    else
        Library:Notify("No shadow ban detected", 5)
    end
end})
-- v3.2: multi-account hardening
local gMulti = TabAFK:AddRightGroupbox("Multi-Account")
gMulti:AddToggle("T_AutoRejoin", { Text = "Auto Rejoin on Crash", Default = true, Tooltip = "Detects a crashed/stuck mission and teleports back through the lobby", Callback = function(v) CFG.AutoRejoin = v end })
gMulti:AddToggle("T_AutoSelectSlot", { Text = "Auto Select Slot", Default = false, Tooltip = "Picks a slot automatically when joining with none (hands-off boot)", Callback = function(v) CFG.AutoSelectSlot = v end })
gMulti:AddDropdown("D_SelectSlot", { Text = "Slot", Values = {"A","B","C"}, Default = 1, Callback = function(v) CFG.SelectSlot = v end })
gMulti:AddDivider()
gMulti:AddToggle("T_AutoBoostedMap", { Text = "Auto Join Boosted Map (2x)", Default = false, Tooltip = "Auto-creates and starts whichever map currently has the 2x reward boost", Callback = function(v) CFG.AutoBoostedMap = v end })
gMulti:AddToggle("T_AutoModifiers", { Text = "Apply All Modifiers on Boosted", Default = false, Callback = function(v) CFG.AutoModifiers = v end })
gMulti:AddDivider()
gMulti:AddToggle("T_DieAtStreak", { Text = "Die at Streak", Default = false, Callback = function(v) CFG.DieAtStreak = v end })
gMulti:AddSlider("S_DieStreak", { Text = "Die at streak >=", Default = 10000, Min = 10, Max = 100000, Rounding = 0, Callback = function(v) CFG.DieStreakN = v end })
local gAfkUp = TabAFK:AddLeftGroupbox("Progression While AFK")
gAfkUp:AddToggle("T_AutoUpGear", { Text = "Auto Upgrade Gear (on lobby arrival)", Default = false, Callback = function(v) CFG.AutoUpGear = v end })
gAfkUp:AddToggle("T_AutoSP",   { Text = "Auto Spend SP",            Default = false, Callback = function(v) CFG.AutoSpendSP = v end })
gAfkUp:AddDropdown("D_SkillPath",{ Text = "Skill Path Focus", Values = {"Blade Skills","Support Skills"}, Default = 1, Callback = function(v) CFG.SkillPath = v end })
gAfkUp:AddToggle("T_AutoSkillTree",  { Text = "Auto Skill Tree",       Default = false, Callback = function(v) CFG.AutoSkillTree = v end })
local treeSubValues = {"Damage", "Critical"}
gAfkUp:AddDropdown("D_TreePath", { Text = "Tree Path", Values = {"Blades","Spears","Defense","Support"}, Default = 1, Callback = function(v)
    CFG.SkillTreePath = v
    local subs = {}
    local tree = SKILL_TREE[v]
    if tree then for k in pairs(tree) do table.insert(subs, k) end end
    if Options.D_TreeSub then Options.D_TreeSub:SetValues(subs); Options.D_TreeSub:SetValue(subs[1] or "Damage") end
    CFG.SkillTreeSub = subs[1] or "Damage"
end})
gAfkUp:AddDropdown("D_TreeSub", { Text = "Sub-Path", Values = treeSubValues, Default = 1, Callback = function(v) CFG.SkillTreeSub = v end })
-- v3.2: lobby automation (prestige / perk enhance / achievements)
local gLobby = TabAFK:AddRightGroupbox("Lobby Automation")
gLobby:AddToggle("T_AutoClaimAch", { Text = "Auto Claim Achievements", Default = false, Callback = function(v) CFG.AutoClaimAch = v end })
gLobby:AddDivider()
gLobby:AddToggle("T_AutoPrestige", { Text = "Auto Prestige", Default = false, Callback = function(v) CFG.AutoPrestige = v end })
gLobby:AddSlider("S_PrestigeGold", { Text = "Prestige at Gold (millions)", Default = 0, Min = 0, Max = 100, Rounding = 0, Callback = function(v) CFG.PrestigeGoldM = v end })
gLobby:AddDropdown("D_PrestigeBoost", { Text = "Prestige Boost", Values = {"Luck Boost","EXP Boost","Gold Boost"}, Default = 1, Callback = function(v) CFG.PrestigeBoost = v end })
gLobby:AddDivider()
gLobby:AddToggle("T_AutoEnhance", { Text = "Auto Enhance Perk (needs getactors — no known exec)", Default = false, Tooltip = "Perk data lives in the character Actor VM; unreachable without getactors/run_on_actor, which Xeno and Real both lack. Left here in case a future executor adds it.", Callback = function(v) CFG.AutoEnhance = v end })
gLobby:AddDropdown("D_PerkSlot", { Text = "Perk Slot to Enhance", Values = {"Defense","Support","Family","Extra","Offense","Body"}, Default = 6, Callback = function(v) CFG.PerkSlot = v end })
gLobby:AddDropdown("D_FoodRarities", { Text = "Food Perk Rarities", Values = {"Common","Rare","Epic","Legendary"}, Default = {}, Multi = true, Callback = function(v)
    local r = {}
    for k, on in pairs(v) do if on then table.insert(r, k) end end
    CFG.FoodRarities = r
end})
-- ═══ TAB: COMBAT ═══
local TabCombat = Window:AddTab("Combat")
local gFarm = TabCombat:AddLeftGroupbox("Farm Controls")
gFarm:AddToggle("T_AutoFarm",   { Text = "Auto Farm Enabled",          Default = false, Callback = function(v) CFG.AutoFarm = v end })
gFarm:AddDivider()
gFarm:AddToggle("T_RaidMode",   { Text = "Raid Mode (Boss Priority)",  Default = false, Callback = function(v) CFG.RaidMode = v end })
gFarm:AddToggle("T_AutoReload", { Text = "Auto Refill Blades/Gas (R)", Default = true,  Callback = function(v) CFG.AutoReload = v end })
gFarm:AddToggle("T_AutoEscape", { Text = "Auto Escape Grab",           Default = true,  Callback = function(v) CFG.AutoEscape = v end })
gFarm:AddToggle("T_SafeFarm",   { Text = "Safe Farm (Humanize)",       Default = false, Callback = function(v) CFG.SafeFarm = v end })
local gAdv = TabCombat:AddRightGroupbox("Advanced Combat")
gAdv:AddDropdown("D_DmgMode",   { Text = "Damage Mode",  Values = {"Legit (Safe)","Maximum (Risk)"}, Default = 1, Callback = function(v) CFG.DamageMode = v end })
gAdv:AddSlider("S_AtkRange",    { Text = "Attack Range",    Default = 150, Min = 50, Max = 500, Rounding = 0, Callback = function(v) CFG.AttackRange = v end })
gAdv:AddToggle("T_MultiTarget", { Text = "Multi-Target (1 swing hits N titans)", Default = false, Callback = function(v) CFG.MultiTarget = v end })
gAdv:AddSlider("S_MultiTargetN",{ Text = "Titans per Swing",Default = 5, Min = 1, Max = 10, Rounding = 0, Callback = function(v) CFG.MultiTargetN = v end })
gAdv:AddToggle("T_NapeExt",     { Text = "Nape Extender",   Default = false, Callback = function(v) CFG.NapeExtend = v; expandNape(v) end })
gAdv:AddSlider("S_NapeSize",    { Text = "Nape Extend Size",Default = 6, Min = 0, Max = 15, Rounding = 0, Callback = function(v) CFG.NapeExtSize = v; if CFG.NapeExtend then expandNape(true) end end })
gAdv:AddToggle("T_RoarDodge",   { Text = "Dodge Boss Roar/Berserk",  Default = true,  Callback = function(v) CFG.RoarDodge = v end })
gAdv:AddToggle("T_WeaponAuto",  { Text = "Auto-Detect Weapon Type",  Default = true,  Callback = function(v) CFG.WeaponAutoDetect = v end })
gAdv:AddToggle("T_ObjTrack",    { Text = "Objective Tracking",       Default = true,  Callback = function(v) CFG.ObjectiveTracking = v end })
gAdv:AddToggle("T_StallMode",   { Text = "Stall Priority (Z-Axis)",  Default = true,  Callback = function(v) CFG.StallMode = v end })
-- ═══ MASTERY ═══
local gMastery = TabCombat:AddRightGroupbox("Titan Mastery")
gMastery:AddToggle("T_TitanMastery", { Text = "Titan Mastery Mode",    Default = false, Callback = function(v) CFG.TitanMastery = v end })
gMastery:AddDropdown("D_MasteryMode",{ Text = "Mastery Style", Values = {"Both","Punching","Skill Usage"}, Default = 1, Callback = function(v) CFG.MasteryMode = v end })
gMastery:AddToggle("T_AutoShift",    { Text = "Auto Shift (Bar 100%)",  Default = false, Callback = function(v) CFG.AutoShift = v end })
gMastery:AddToggle("T_ShifterSkills",{ Text = "Auto Shifter Skills",    Default = true,  Callback = function(v) CFG.ShifterSkills = v end })
gMastery:AddToggle("T_SpearFire",    { Text = "Spear Auto-Fire",        Default = true,  Callback = function(v) CFG.SpearAutoFire = v end })
-- ═══ TAB: VISUALS ═══
local TabVisuals = Window:AddTab("Visuals")
local gMove = TabVisuals:AddLeftGroupbox("Movement")
gMove:AddDropdown("D_MoveMode", { Text = "Movement Style", Values = {"Gliding","Teleport"}, Default = 1, Callback = function(v) CFG.MoveMode = v end })
gMove:AddToggle("T_Noclip",     { Text = "Noclip",       Default = true,  Callback = function(v) CFG.Noclip = v end })
gMove:AddSlider("S_Height",     { Text = "Float Height", Default = 170, Min = 50, Max = 500, Rounding = 0, Callback = function(v) CFG.FloatHeight = v end })
gMove:AddSlider("S_Speed",      { Text = "Hover Speed",  Default = 400, Min = 100, Max = 1000, Rounding = 0, Callback = function(v) CFG.HoverSpeed = v end })
local gVis = TabVisuals:AddRightGroupbox("World")
gVis:AddToggle("T_TitanESP",  { Text = "Titan ESP (Red)",       Default = false, Callback = function(v) CFG.TitanESP = v end })
gVis:AddToggle("T_BossESP",   { Text = "Boss ESP (Purple)",     Default = false, Callback = function(v) CFG.BossESP = v end })
gVis:AddToggle("T_RemoveFog", { Text = "Remove Fog",            Default = false, Callback = function(v) CFG.RemoveFog = v; if v then removeFog() end end })
gVis:AddToggle("T_DeleteMap", { Text = "Delete Map (FPS Boost)",Default = true,  Callback = function(v) CFG.DeleteMap = v; if v then deleteMap() end end })
gVis:AddToggle("T_InjuryRem", { Text = "Auto Remove Injuries",  Default = true,  Callback = function(v) CFG.InjuryRemove = v end })
gVis:AddToggle("T_KillNotif", { Text = "Kill Notifications",    Default = false, Callback = function(v) CFG.KillNotif = v end })
gVis:AddToggle("T_Disable3D", { Text = "Disable 3D Rendering (FPS Boost)", Default = false, Callback = function(v)
    CFG.Disable3D = v
    RunService:Set3dRenderingEnabled(not v)
end })
-- ═══ TAB: UTILITIES ═══
local TabUtils = Window:AddTab("Utilities")
local gTool = TabUtils:AddLeftGroupbox("Tools")
gTool:AddButton({ Text = "Load Cobalt (Remote Spy)", Func = function()
    loadstring(game:HttpGet("https://github.com/notpoiu/cobalt/releases/latest/download/Cobalt.luau"))()
    Library:Notify("Cobalt loaded!", 3)
end})
-- v2.0: user-configured Discord webhook (any channel — paste your own URL)
local gWebhook = TabUtils:AddRightGroupbox("Discord Webhook")
gWebhook:AddInput("I_WebhookURL", {
    Default = "", Text = "Webhook URL", Numeric = false, Finished = false,
    Placeholder = "https://discord.com/api/webhooks/...",
    Tooltip = "Paste ANY Discord channel's webhook URL — reward/drop pings go there. Saved with your config.",
    Callback = function(v) CFG.WebhookURL = v end,
})
gWebhook:AddToggle("T_RewardWebhook", { Text = "Send Every Reward", Default = false, Tooltip = "Post gold/gems/XP to your webhook after every mission", Callback = function(v) CFG.RewardWebhook = v end })
gWebhook:AddToggle("T_MythicalWebhook", { Text = "Ping on Mythical/Secret Drop", Default = false, Tooltip = "@everyone ping when a red-rarity (mythical/secret) item drops", Callback = function(v) CFG.MythicalWebhook = v end })
gWebhook:AddToggle("T_DropLog", { Text = "Full Drop Log", Default = false, Tooltip = "Log EVERY item dropped each mission (separate message)", Callback = function(v) CFG.DropLog = v end })
gWebhook:AddToggle("T_SessionReport", { Text = "Periodic Session Report", Default = false, Tooltip = "Post a gold/hour + totals summary every X minutes", Callback = function(v) CFG.SessionReport = v end })
gWebhook:AddSlider("S_ReportMins", { Text = "Report every (min)", Default = 30, Min = 5, Max = 180, Rounding = 0, Callback = function(v) CFG.ReportMins = v end })
gWebhook:AddButton({ Text = "Send Test Message", Func = function()
    if not CFG.WebhookURL or CFG.WebhookURL == "" then
        Library:Notify("Paste a webhook URL first", 4)
        return
    end
    sendWebhook({ title = "✅ TRUST-HUB Test", description = "Webhook connected for **" .. LP.Name .. "**", color = 3092790 })
    Library:Notify("Test sent — check your Discord", 4)
end})
-- ═══ TAB: SETTINGS ═══
local TabSettings = Window:AddTab("Settings")
local gHub = TabSettings:AddLeftGroupbox("Hub")
gHub:AddToggle("T_StatsPanel", { Text = "Show Stats Panel", Default = true, Tooltip = "The draggable/minimizable on-screen session panel", Callback = function(v) CFG.ShowStatsPanel = v end })
gHub:AddToggle("T_PersistReload", { Text = "Persist Across Teleports (Auto Execute)", Default = true, Tooltip = "Re-runs the hub from your GitHub repo on every teleport (auto-updates across all accounts); local copy fallback if offline", Callback = function(v)
    CFG.PersistReload = v
    if v then registerTeleportReload() end -- re-arm immediately instead of waiting for the next load
end })
gHub:AddButton({ Text = "Reset Session Stats", Func = function()
    SESSION.gameCount = 0; SESSION.goldEarned = 0; SESSION.gemsEarned = 0; SESSION.xpEarned = 0
    SESSION.sessionStart = os.time(); ST.gameCount = 0
    saveSession(SESSION)
    Library:Notify("Session stats reset", 3)
end})
SaveManager:SetLibrary(Library)
SaveManager:SetFolder("TrustHUB_" .. LP.Name)
SaveManager:IgnoreThemeSettings()
SaveManager:BuildConfigSection(TabSettings)
-- BuildConfigSection wires up the "Set as autoload" button and config list,
-- but LinoriaLib leaves the actual auto-apply commented out in its own
-- source (addons/SaveManager.lua: "-- self:LoadAutoloadConfig()") so the
-- caller controls when it fires. Without this line, autoload never actually
-- restored anything — toggles only looked "already right" if you hadn't
-- reloaded the script yet in that session.
SaveManager:LoadAutoloadConfig()
-- BuildConfigSection populates the "Config list" dropdown once, synchronously,
-- from RefreshConfigList() at construction time. Reported symptom: right
-- after a queue_on_teleport reload the dropdown shows completely empty (as
-- if no configs existed) even though the autoload one is applied correctly
-- and files are genuinely on disk — and creating any new config makes every
-- old one reappear too, because SaveManager's own "create" handler calls
-- RefreshConfigList() again internally. That points at listfiles() briefly
-- returning stale/empty results immediately after a reload on this executor;
-- a short delayed re-refresh papers over that race without touching
-- LinoriaLib's own code.
task.spawn(function()
    task.wait(1)
    pcall(function()
        if Options.SaveManager_ConfigList then
            Options.SaveManager_ConfigList:SetValues(SaveManager:RefreshConfigList())
        end
    end)
end)
ThemeManager:SetLibrary(Library)
ThemeManager:SetFolder("TrustHUB")
ThemeManager:ApplyToTab(TabSettings)
ThemeManager:ApplyTheme("Tokyo Night") -- switchable later from the Settings tab
-- ══════════════════════════════════════════════════════════
-- [19] STARTUP
-- ══════════════════════════════════════════════════════════
masterStart()
Library:Notify("Trust-HUB v3.0 loaded! | by ENI x LO | User: " .. LP.Name, 5)
print(string.format("[Trust-HUB v3.0] Loaded in %.2fs | Titans: %d",
    tick() - ST.startT,
    #(workspace:FindFirstChild("Titans") and workspace.Titans:GetChildren() or {})
))
