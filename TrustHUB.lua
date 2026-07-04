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
        return data
    end
    return { gameCount = 0, sessionStart = os.time(), goldEarned = 0 }
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
    SESSION = { gameCount = 0, sessionStart = os.time(), goldEarned = 0 }
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
-- [9] AUTO-REFILL (VIM R-Key + Remote Fallback)
-- ══════════════════════════════════════════════════════════
-- Segment durability (0-7 per hand, breaks per hit — see Modules.Utilities.Blades
-- Check_Durability/Break_Segment) lives on physical parts under the character's
-- rig, not on the HUD. The old code read HUD.Sets, but that field is
-- Supply.Reloads (spare blade sets remaining, e.g. "3 / 3") — it only
-- decrements when you actually swap, so it stays "3/3" even with a fully
-- broken blade and never signalled a reload. Also hud:FindFirstChild("Sets")
-- was non-recursive while Sets sits 4 levels deep (Main.Top.7.Blades.Sets),
-- so it always returned nil and checkReload was a permanent no-op regardless.
local function countIntactSegments()
    local charsFolder = workspace:FindFirstChild("Characters")
    local charFolder = charsFolder and charsFolder:FindFirstChild(LP.Name)
    local rig = charFolder and charFolder:FindFirstChild("Rig_" .. LP.Name)
    local hand = rig and rig:FindFirstChild("RightHand")
    if not hand then return nil end
    local intact = 0
    for i = 1, 7 do
        local seg = hand:FindFirstChild("Blade_" .. i)
        if seg and seg.Transparency < 1 then
            intact = intact + 1
        end
    end
    return intact
end
-- Sets/Reloads (Main.Top.7.Blades.Sets, "X / Y") — the spare kit count, not
-- the current blade's segment wear. Same exact-path caution as readGold():
-- "Sets" only exists nested 4 levels deep under HUD, not a direct child.
local function readSets()
    local pg = LP:FindFirstChild("PlayerGui")
    local iface = pg and pg:FindFirstChild("Interface")
    local hud = iface and iface:FindFirstChild("HUD")
    local main = hud and hud:FindFirstChild("Main")
    local top = main and main:FindFirstChild("Top")
    local seven = top and top:FindFirstChild("7")
    local blades = seven and seven:FindFirstChild("Blades")
    local sets = blades and blades:FindFirstChild("Sets")
    if not sets then return nil end
    local current = tonumber((tostring(sets.Text or ""):match("^%s*(%d+)")))
    return current
end
-- Real refill stations found live: Workspace.Climbable.Walls.Gate.GasTanks.Refill
-- (BaseParts named "Refill", detected by the game via .Touched — see
-- Modules.Utilities.Zones:198-221). Their location isn't fixed across maps,
-- so search workspace instead of hardcoding a path (the old
-- Unclimbable/Reloads guess didn't exist at all in this map instance).
local function findNearestRefillStation()
    local _, hrp = getChar()
    if not hrp then return nil end
    local nearest, nearestDist
    for _, d in ipairs(workspace:GetDescendants()) do
        if d.Name == "Refill" and d:IsA("BasePart") then
            local dist = (hrp.Position - d.Position).Magnitude
            if not nearestDist or dist < nearestDist then
                nearest, nearestDist = d, dist
            end
        end
    end
    return nearest
end
-- Runs off the main farmLoop thread — the out-of-kits branch below moves the
-- player and task.wait(1)s for the Touched event, which used to stall combat
-- for a full second every time it fired.
local reloadInProgress = false
local function checkReload()
    if not CFG.AutoReload or reloadInProgress then return end
    local bladeCount = countIntactSegments()
    if not bladeCount then return end -- rig not found this tick (respawning, etc.)
    if bladeCount > 0 then return end
    reloadInProgress = true
    task.spawn(function()
        local sets = readSets()
        if sets and sets <= 0 then
            -- Out of spare kits entirely — a mid-air reload has nothing to pull
            -- from. The real "Full_Reload" path (Modules.Core.ODMG:220-238) only
            -- fires when Modules.Zones.Refill_Station is set, which only happens
            -- when the character's Hitbox physically touches a "Refill" part
            -- (Modules.Utilities.Zones:198-221) — so fly to the nearest one and
            -- fire the same call that touch handler makes:
            -- POST:FireServer("Attacks", "Reload", refillPart).
            local station = findNearestRefillStation()
            if station then
                local _, hrp = getChar()
                if hrp then
                    pcall(function() hrp.CFrame = CFrame.new(station.Position) end)
                    task.wait(1) -- let the Touched event register Zones.Refill_Station
                    pcall(function() POST:FireServer("Attacks", "Reload", station) end)
                end
            end
            reloadInProgress = false
            return
        end
        -- Live-confirmed in Modules.Core.ODMG:274: the game's own reload key
        -- handler calls exactly GET:InvokeServer("Blades", "Reload") and plays
        -- the swap animation if it returns true. There is no separate
        -- "Full_Reload"/"Right"/"Left" GET pair — that was fabricated (same
        -- pattern as the old "Hardest" difficulty and "S_Blades" guesses); the
        -- game's only other reload path is the Attacks/Reload+station one above.
        pcall(function()
            VIM:SendKeyEvent(true, Enum.KeyCode.R, false, game)
            task.wait(0.1)
            VIM:SendKeyEvent(false, Enum.KeyCode.R, false, game)
        end)
        pcall(function() GET:InvokeServer("Blades", "Reload") end)
        reloadInProgress = false
    end)
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
        checkReload()
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
                if dist <= CFG.AttackRange and ST.canHit then
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
        if CFG.AutoRetry then
            -- Live-confirmed real end-of-mission screen:
            -- PlayerGui.Interface.Rewards (CanvasGroup, .Visible toggles),
            -- shows "MISSION COMPLETED" in Main.Info.State, with real
            -- TextButtons Retry / Leave_2 / Modify under
            -- Main.Info.Main.Buttons. Earlier approaches (i) clicked a
            -- "Retry" button found by text-matching + called an unverified
            -- "S_Missions"/"Retry" remote, neither of which existed, then
            -- (ii) inferred "mission over" from Titans==0, which is also
            -- briefly true between waves and false-fired mid-mission. This
            -- reacts to the actual screen and clicks the actual button —
            -- no heuristics, no guessed remotes.
            local pg = LP:FindFirstChild("PlayerGui")
            local iface = pg and pg:FindFirstChild("Interface")
            local rewards = iface and iface:FindFirstChild("Rewards")
            if rewards and rewards.Visible then
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
                -- Simulating the click (VIM mouse events, even with the
                -- GuiInset offset fixed) only updated the button's local
                -- visual state (turned green) without the server-side vote
                -- ever registering — stayed stuck at "RETRY (0/1)". Traced
                -- the real handlers instead (ReplicatedStorage.Modules.
                -- Utilities.Interactions):
                --   Retry: GET:InvokeServer("Functions", "Retry", "Add")
                --   Leave: POST:FireServer("Functions", "Teleport")
                -- No GUI interaction needed at all — these are the exact
                -- calls the button's own click handler makes.
                if wantLeave then
                    ST.status = "Returning to lobby"
                    pcall(function() POST:FireServer("Functions", "Teleport") end)
                else
                    ST.status = "Retrying mission"
                    local ok, err = pcall(function() return GET:InvokeServer("Functions", "Retry", "Add") end)
                    if not ok then
                        warn("[Trust-HUB] Functions/Retry/Add failed: " .. tostring(err))
                    end
                end
                task.wait(5) -- let the click register/transition before the next check
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
upgradeAllGear = function()
    if not isInLobby() then return false end
    ST.status = "Upgrading gear"
    -- Try the last-known weapon's list first; if the server rejects it (nil),
    -- the other weapon is equipped — try that and remember it.
    local order = (ST.weaponType == "Spears")
        and { {"Spears", SPEAR_UPGRADES}, {"Blades", BLADE_UPGRADES} }
        or  { {"Blades", BLADE_UPGRADES}, {"Spears", SPEAR_UPGRADES} }
    local accepted = false
    for _, pair in ipairs(order) do
        local ok, result = pcall(function() return GET:InvokeServer("S_Equipment", "Upgrade", pair[2]) end)
        if ok and type(result) == "table" then
            ST.weaponType = pair[1]
            accepted = true
            break
        end
    end
    if Library then
        Library:Notify(accepted and "Gear upgraded!" or "Upgrade: not enough Gold / maxed", 3)
    end
    return accepted
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
local function upgradeLoop()
    while ST.running do
        task.wait(15)
        -- All three of these (skill points, skill tree, gear) only apply in
        -- the lobby — skip the whole batch mid-mission so we don't fire dead
        -- S_Equipment calls every 15s during a run.
        if not isInLobby() then continue end
        if CFG.AutoSpendSP then
            local ids = (CFG.SkillPath == "Support Skills") and SUPPORT_SKILL_IDS or BLADE_SKILL_IDS
            for _, id in ipairs(ids) do trySkillUnlock(id); task.wait(0.2) end
        end
        if CFG.AutoSkillTree then autoSkillTreeCycle() end
        if CFG.AutoUpGear then upgradeAllGear() end
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
local ACCENT = Color3.fromRGB(103, 89, 179) -- Tokyo Night accent, shared
local function buildStatsPanel()
    local pg = LP:FindFirstChild("PlayerGui")
    if not pg then return end
    local existing = pg:FindFirstChild("TrustHUB_StatsPanel")
    if existing then existing:Destroy() end -- re-injection/re-execute leaves the old one orphaned otherwise
    local sg = Instance.new("ScreenGui")
    sg.Name = "TrustHUB_StatsPanel"
    sg.ResetOnSpawn = false
    sg.IgnoreGuiInset = true
    sg.Parent = pg

    local labels = { "Status", "Session", "Kills (mission)", "Missions", "Gold earned", "Gold/Hour" }
    local TITLE_H, ROW_H = 24, 20
    local bodyH = #labels * ROW_H + 6
    local fullH = TITLE_H + bodyH

    local frame = Instance.new("Frame", sg)
    frame.Size = UDim2.new(0, 230, 0, fullH)
    frame.Position = UDim2.new(1, -242, 0, 90)
    frame.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
    frame.BackgroundTransparency = 0.25
    frame.BorderSizePixel = 0
    frame.Active = true
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
    local stroke = Instance.new("UIStroke", frame)
    stroke.Color = ACCENT
    stroke.Thickness = 1

    -- Title bar doubles as the drag handle.
    local titleBar = Instance.new("TextButton", frame)
    titleBar.Size = UDim2.new(1, 0, 0, TITLE_H)
    titleBar.BackgroundTransparency = 1
    titleBar.AutoButtonColor = false
    titleBar.Text = "  TRUST-HUB"
    titleBar.Font = Enum.Font.GothamBold
    titleBar.TextSize = 14
    titleBar.TextXAlignment = Enum.TextXAlignment.Left
    titleBar.TextColor3 = Color3.fromRGB(200, 190, 255)

    -- Minimize button collapses to just the title bar.
    local minBtn = Instance.new("TextButton", frame)
    minBtn.Size = UDim2.new(0, 24, 0, TITLE_H)
    minBtn.Position = UDim2.new(1, -26, 0, 0)
    minBtn.BackgroundTransparency = 1
    minBtn.Text = "–"
    minBtn.Font = Enum.Font.GothamBold
    minBtn.TextSize = 18
    minBtn.TextColor3 = Color3.fromRGB(200, 190, 255)

    local body = Instance.new("Frame", frame)
    body.Size = UDim2.new(1, 0, 0, bodyH)
    body.Position = UDim2.new(0, 0, 0, TITLE_H)
    body.BackgroundTransparency = 1

    local rows = {}
    for i, label in ipairs(labels) do
        local row = Instance.new("TextLabel", body)
        row.BackgroundTransparency = 1
        row.Size = UDim2.new(1, -16, 0, 18)
        row.Position = UDim2.new(0, 8, 0, (i - 1) * ROW_H)
        row.Font = Enum.Font.Gotham
        row.TextSize = 13
        row.TextXAlignment = Enum.TextXAlignment.Left
        row.TextColor3 = (label == "Status") and Color3.fromRGB(150, 220, 150) or Color3.fromRGB(230, 230, 230)
        row.Text = label .. ": --"
        rows[label] = row
    end

    local minimized = false
    minBtn.MouseButton1Click:Connect(function()
        minimized = not minimized
        body.Visible = not minimized
        frame.Size = UDim2.new(0, 230, 0, minimized and TITLE_H or fullH)
        minBtn.Text = minimized and "+" or "–"
    end)

    -- Drag: standard UDim2-offset drag anchored to where the grab started.
    local dragging, dragStart, startPos
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
        end
    end)
    titleBar.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    track(UIS.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end))

    statsPanel = { Gui = sg, Rows = rows }
end
local function formatDuration(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    return string.format("%02d:%02d:%02d", h, m, s)
end
-- Compact number: 1234 -> "1.2K", 3450000 -> "3.4M". Keeps the panel readable
-- once gold/hour reaches the hundred-thousands on a long farm.
local function formatNumber(n)
    n = tonumber(n) or 0
    local neg = n < 0 and "-" or ""
    n = math.abs(n)
    if n >= 1e9 then return string.format("%s%.2fB", neg, n / 1e9) end
    if n >= 1e6 then return string.format("%s%.2fM", neg, n / 1e6) end
    if n >= 1e3 then return string.format("%s%.1fK", neg, n / 1e3) end
    return neg .. tostring(math.floor(n))
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

    statsPanel.Rows["Status"].Text = "Status: " .. (ST.status or "Idle")

    -- Real wall-clock elapsed (survives hops) — not tick(), which is per-Lua
    -- state and resets to ~0 every reload.
    local elapsed = os.time() - SESSION.sessionStart
    statsPanel.Rows["Session"].Text = "Session: " .. formatDuration(elapsed)

    local slayText = readMissionKillsText()
    statsPanel.Rows["Kills (mission)"].Text = "Kills (mission): " .. (slayText and slayText:match("%[(.-)%]") or "--")

    statsPanel.Rows["Missions"].Text = "Missions: " .. tostring(ST.gameCount)

    -- Gold earned = sum of POSITIVE balance changes only. Spending on gear
    -- upgrades drops the balance, which we ignore, so the figure never goes
    -- negative and reflects only what missions actually paid out.
    local gold = readGold()
    if gold then
        if ST.lastGold and gold > ST.lastGold then
            SESSION.goldEarned = SESSION.goldEarned + (gold - ST.lastGold)
        end
        ST.lastGold = gold
        statsPanel.Rows["Gold earned"].Text = "Gold earned: " .. formatNumber(SESSION.goldEarned)
        local perHour = elapsed > 5 and math.floor(SESSION.goldEarned / elapsed * 3600) or 0
        statsPanel.Rows["Gold/Hour"].Text = "Gold/Hour: " .. formatNumber(perHour)
    end

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
    -- Session values come from the persisted store (survives hops), not from
    -- fresh tick()/readGold each load. lastGold seeds the positive-delta gold
    -- tracker with the current balance so the first reading never counts the
    -- whole balance as "earned".
    ST.gameCount = SESSION.gameCount
    ST.lastGold = readGold()
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
    Title    = "Trust-HUB v3.0 | " .. LP.Name,
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
-- Both cursor fixes are now purely reactive (property-changed), not a
-- per-frame Heartbeat: snap MouseBehavior back to Default and re-show the
-- icon only when the game actually changes them while our menu is open. The
-- old Heartbeat variant re-checked every single frame for the same effect.
track(UIS:GetPropertyChangedSignal("MouseBehavior"):Connect(function()
    if Library.Toggled and UIS.MouseBehavior ~= Enum.MouseBehavior.Default then
        UIS.MouseBehavior = Enum.MouseBehavior.Default
    end
end))
track(UIS:GetPropertyChangedSignal("MouseIconEnabled"):Connect(function()
    if Library.Toggled and not UIS.MouseIconEnabled then
        UIS.MouseIconEnabled = true
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
-- ═══ TAB: SETTINGS ═══
local TabSettings = Window:AddTab("Settings")
local gHub = TabSettings:AddLeftGroupbox("Hub")
gHub:AddToggle("T_StatsPanel", { Text = "Show Stats Panel", Default = true, Callback = function(v) CFG.ShowStatsPanel = v end })
gHub:AddToggle("T_PersistReload", { Text = "Persist Across Teleports", Default = true, Callback = function(v)
    CFG.PersistReload = v
    if v then registerTeleportReload() end -- re-arm immediately instead of waiting for the next load
end })
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
