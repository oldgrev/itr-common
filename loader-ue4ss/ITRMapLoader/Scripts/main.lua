-- ITRMapLoader: gets you into a custom map in Into the Radius 1 (2.7.2) and back out again.
-- Map-agnostic: every map-specific value (level name, level tag, donor zone, map centre, loot manifest, entry trigger,
-- exit) comes from config.lua. See README.md.
--
-- NATIVE mode (per map: Native = true; the recommended way). The map is registered with the game as a level at startup
-- (an unloaded streaming entry + a row in SystemConfig.LevelConfigurations + a map centre + the loot tags), and entering
-- calls the game mode's TransferToLevel, as a zone gate does. The game then runs its own transition, level events, loot
-- and arrival. Any number of maps can be registered at once; each has its own trigger (a Hub item and/or a key).
-- See "Native level" below.
--
-- STREAMING mode (Native = false; the older fallback). Roughly:
--   1. once you're in the Hub, stream the map in at the origin (maps are built where they'll sit in the world).
--      Normally you'd use LevelStreamingDynamic::LoadLevelInstance, but UE4SS can't call it, see Load();
--   2. when the level's visible: (HubTeardown) teleport to a staging point on the map, unload every other streaming
--      level (the Hub), then teleport to the arrival marker. Without the teardown: just teleport to the arrival marker
--      and, for maps with baked lighting, hide the Hub's lighting-scenario level;
--   3. stepping near any ExitTag marker (or pressing the key again) takes you back to the Hub. With the teardown that
--      means asking the game to load the Hub (LevelManager::LoadLevel) while you still stand on the map;
--   4. leaving through an exit that has an id is remembered, and the next entry arrives at the matching arrive marker.
--   5. (ActivateGameplay) ~3 s after arrival the map's gameplay actors (loot, stashes, anomalies, spawners,
--      generators) get the level-start events they missed: OnLevelPrepare, GenerateLoot (the native distance check spawns the items), OnLevelStarted,
--      OnGameStarted, OnTransitionEnd, called on each actor in the map's level.
--   The streaming mode was tested in VR with UE4SS 3.0.1 (the Nexus Mods ITR repack) for entry, exit markers and the
--   basic load/unload; multiple exits, re-entry memory, Hub teardown and gameplay activation were not tested in game.
-- RULE: never change level from an action. The transition start fires inside the transfer call and stock components clear their
-- references there; an action runs inside whatever ProcessEvent the game is in, so native code can lose a reference mid-function
-- (a crash with an NPC nearby). Native entry and exit run at frame end through RunLater (the engine's DEFER command).
-- This file avoids Lua 5.4-only syntax so `luac5.1 -p` can check it.

local UEHelpers = require("UEHelpers")
local Config = require("config")

-- LogTag names this loader in the log lines (config LogTag, default "ITRMapLoader"): give a second loader mod its own
local LogName = Config.LogTag or "ITRMapLoader"
local TAG = "[" .. LogName .. "] "
local Current = nil          -- { Map, Stream, Return, Phase, Exits, TornDown, HubLevels }
local HiddenScenarios = {}   -- ULevelStreaming objects we hid (no-teardown path only)
local NextIndex = 1
local InstanceCount = 0
local Memory = {}            -- map name -> last exit id

local function Log(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end

local function Valid(o) return o ~= nil and o:IsValid() end

-- A second copy of this loader never registers its maps (only the first copy to start gets the game mode's level hooks): say so once.
do
    local OkS, V = pcall(function() return ModRef:GetSharedVariable("ITRMapLoader.Loaded") end)
    if OkS and V == 1 then
        print(TAG .. "another ITRMapLoader copy is already loaded: only the first copy can hook the level events, so this copy will not register its maps; use one copy with several Maps or forms\n")
    end
    pcall(function() ModRef:SetSharedVariable("ITRMapLoader.Loaded", 1) end)
end

-- Option lookup: per-map value, then global config value, then default
local function Opt(Map, Key, Default)
    if Map and Map[Key] ~= nil then return Map[Key] end
    if Config[Key] ~= nil then return Config[Key] end
    return Default
end

local ExitTag = Config.ExitTag or "itr:exit"
local ExitIdPrefix = Config.ExitIdTagPrefix or "itr:exit_id:"
local ArrivePrefix = Config.ArriveTagPrefix or "itr:arrive:"
local HubLevelTag = Config.HubLevelTag or "Level.Hub"
local StagingMaxWestX = Config.StagingMaxWestX or -20000

-- Wall-clock milliseconds. The loops below measure their waits with this, never by counting ticks: a tick count assumes
-- every LoopAsync tick runs its game-thread callback on time (it did not).
local function Now() return os.clock() * 1000 end

-- RULE (UE4SS c62ada0): never call ExecuteInGameThread from inside a game-thread action, or from anything an action calls synchronously.
-- Appending to its queue can reallocate it under the running pass and crash the game. Calling it from a hook, NotifyOnNewObject, a key
-- bind, LoopAsync or ExecuteWithDelay is fine, as long as that caller is not itself inside an action.
-- SECOND RULE (UE4SS, read in the DLL): a mod's FIRST ExecuteInGameThread adds an entry to an unlocked list that the game thread walks every frame, so that first
-- call must come from the game thread outside any action (here: the game mode notification, C: NativeStartup). A mod that makes it from a LoopAsync tick
-- or at start-up, off the game thread, can corrupt that list.
-- Primed: this mod's first ExecuteInGameThread is made as an empty call from the game mode notification (the real BP_PRGameMode_C, not Default__),
-- on the game thread outside any action. Nothing queues before that: the LoopAsync ticks below, the key and the console command wait for it.
local Prime = { Done = false }
pcall(NotifyOnNewObject, "/Script/IntoTheRadius.PRGameMode", function(Obj)
    if Prime.Done then return end
    local Ok, Cls = pcall(function() return Obj:GetClass():GetFName():ToString() end)
    local Okn, Nm = pcall(function() return Obj:GetFName():ToString() end)
    if not (Ok and Cls == "BP_PRGameMode_C") or (Okn and Nm:sub(1, 9) == "Default__") then return end
    Prime.Done = true
    ExecuteInGameThread(function() local S = Prime.Step; if S then S() end end)       -- the form path's step (boot.lua), else an empty call
end)
-- Runs fn on the game thread every ms until it returns true (or throws). LoopAsync runs on another thread, so the
-- stop flag is only seen one round after the game thread set it. The flag lives in a table (shared by reference).
-- IMPORTANT (UE4SS c62ada0): errors raised by UE4SS's functions (TMap:Find on a missing key, calling an invalid UFunction
-- object, ...) are C++ exceptions that pcall does NOT catch; they unwind to UE4SS, which logs "Error: ..." and drops the tick.
-- Such a tick never reaches the line after pcall, which is how it is noticed: Running is still set on the next tick.
-- MaxCrashes ticks lost that way end the loop (default 3), so one bad call can't repeat every tick for the whole session.
local function Every(ms, fn, MaxCrashes)
    local St = { Done = false, Running = false, Crashes = 0 }
    LoopAsync(ms, function()
        if St.Done then return true end
        if not Prime.Done then return false end
        ExecuteInGameThread(function()
            if St.Done then return end
            if St.Running then
                St.Crashes = St.Crashes + 1
                St.Running = false
                Log("loop tick %d aborted by a native error (see the Error line above)", St.Crashes)
                if St.Crashes >= (MaxCrashes or 3) then
                    Log("loop stopped after %d aborted ticks", St.Crashes)
                    St.Done = true
                    return
                end
            end
            St.Running = true
            local Ok, Res = pcall(fn)
            St.Running = false
            if not Ok then
                Log("error: %s", tostring(Res))
                St.Done = true
            elseif Res then
                St.Done = true
            end
        end)
        return false
    end)
end

-- Log each distinct message once (for failures that would otherwise repeat every tick)
local LoggedOnce = {}
local function LogOnce(Key, fmt, ...)
    if LoggedOnce[Key] then return end
    LoggedOnce[Key] = true
    Log(fmt, ...)
end

-- Calling a UFunction by name. UE4SS (c62ada0) answers obj[Name] with a UFunction userdata (callable), or with an invalid
-- UObject userdata when the class has no such function; older builds return a Lua function. Returns Found, Ok, Result.
local function FindUF(O, Name)
    local Ok, F = pcall(function() return O[Name] end)
    if not Ok or F == nil then return nil end
    if type(F) == "function" then return F end
    if type(F) == "userdata" then
        local Ok2, V = pcall(function() return F:IsValid() end)
        if Ok2 and V == true then return F end
    end
    return nil
end

local function CallUF(O, Name, ...)
    local F = FindUF(O, Name)
    if not F then return false, false, nil end
    local Args = { ... }
    local Ok, Res = pcall(function() return F(O, (table.unpack or unpack)(Args)) end)
    return true, Ok, Res
end

-- Same UObject? (UE4SS hands out a fresh Lua wrapper per access, so == on wrappers is not an identity test)
local function SameObj(A, B)
    if A == nil or B == nil then return false end
    local Ok, R = pcall(function() return A:IsValid() and B:IsValid() and A:GetAddress() == B:GetAddress() end)
    return Ok and R == true
end

local function Vec(v) return { X = v.X, Y = v.Y, Z = v.Z } end
local function Rot(r) return { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } end
local function FmtV(v) return string.format("(%.0f, %.0f, %.0f)", v.X, v.Y, v.Z) end
local function Dist2D(A, B) local DX, DY = A.X - B.X, A.Y - B.Y; return math.sqrt(DX * DX + DY * DY) end
local function Dist3D(A, B)
    local DX, DY, DZ = A.X - B.X, A.Y - B.Y, A.Z - B.Z
    return math.sqrt(DX * DX + DY * DY + DZ * DZ)
end

local function StreamingLevels(World)
    local out = {}
    World.StreamingLevels:ForEach(function(_, Elem)
        local S = Elem:get()
        if Valid(S) then table.insert(out, S) end
    end)
    return out
end

local function PkgName(S)
    local Ok, N = pcall(function() return S:GetWorldAssetPackageFName():ToString() end)
    return Ok and N or "?"
end

local function ShortName(P)
    local S = tostring(P):gsub("^.*/", "")
    S = S:gsub("%..*$", "")
    return S
end

local function CallBool(O, Fn)
    local Ok, R = pcall(function() return O[Fn](O) end)
    return Ok and R == true
end

local function PropBool(O, Prop)
    local Ok, R = pcall(function() return O[Prop] end)
    return Ok and R == true
end

-- A streaming entry is "in use" if it is requested, loaded or visible
local function StreamActive(S)
    return PropBool(S, "bShouldBeLoaded") or PropBool(S, "bShouldBeVisible")
        or CallBool(S, "IsLevelLoaded") or CallBool(S, "IsLevelVisible")
end

local function StreamBitsText(S)
    return string.format("shouldLoad %d shouldVisible %d loaded %d visible %d",
        PropBool(S, "bShouldBeLoaded") and 1 or 0, PropBool(S, "bShouldBeVisible") and 1 or 0,
        CallBool(S, "IsLevelLoaded") and 1 or 0, CallBool(S, "IsLevelVisible") and 1 or 0)
end

local function GetLevelManager()
    local Ok, LM = pcall(function()
        local LMClass = StaticFindObject("/Script/IntoTheRadius.Default__LevelManager")
        if Valid(LMClass) then return LMClass:GetLevelManager() end
        return nil
    end)
    if Ok and Valid(LM) then return LM end
    return nil
end

-- In the Hub = the Hub level visible and the game's level manager not mid-transition (the Hub level becomes visible
-- while the player is still in the menu room, during the transition; callers also wait for two checks in a row).
local function IsHubVisible(World)
    local Hub = false
    for _, S in ipairs(StreamingLevels(World)) do
        if S:IsLevelVisible() and PkgName(S):find("/Levels/Hub/L_Hub", 1, true) then
            Hub = true
        end
    end
    if not Hub then return false end
    local LM = GetLevelManager()
    if LM and Config.RequireLevelManagerReady ~= false and not LM:IsReady() then return false end
    return true
end

---------------------------------------------------------------------------------------------------------------------
-- Re-entry memory: { map name -> last exit id }, one "name<TAB>id" line each, in a small file next to this script.
---------------------------------------------------------------------------------------------------------------------
-- Where this script lives. debug.getinfo's source can be relative or empty under UE4SS (the first c62ada0 runs never found
-- the loot manifest next to main.lua), so also ask package.searchpath where config.lua was found.
local ScriptDirCache = nil
local function ScriptDir()
    if ScriptDirCache then return ScriptDirCache end
    local Cands = {}
    local Ok, Info = pcall(debug.getinfo, 1, "S")
    if Ok and Info and type(Info.source) == "string" then
        local Src = (Info.source:gsub("^@", ""))
        local Dir = Src:match("^(.*[/\\])")
        if Dir then table.insert(Cands, Dir) end
    end
    local Ok2, Found = pcall(function() return package.searchpath("config", package.path) end)
    if Ok2 and type(Found) == "string" then
        local Dir = Found:match("^(.*[/\\])")
        if Dir then table.insert(Cands, Dir) end
    end
    table.insert(Cands, "ue4ss/Mods/" .. LogName .. "/Scripts/")
    table.insert(Cands, "Mods/" .. LogName .. "/Scripts/")
    for _, Dir in ipairs(Cands) do
        local OkF, F = pcall(io.open, Dir .. "config.lua", "r")
        if OkF and F then
            F:close()
            ScriptDirCache = Dir
            return Dir
        end
    end
    ScriptDirCache = Cands[1] or ""
    return ScriptDirCache
end

local MemoryPath = Config.ReEntryFile or (ScriptDir() .. "reentry.txt")
local MemoryWarned = false

local function LoadMemory()
    Memory = {}
    local Ok, F = pcall(io.open, MemoryPath, "r")
    if not Ok or not F then return end       -- no file yet: first run
    local Ok2, Text = pcall(F.read, F, "*a")
    pcall(F.close, F)
    if not Ok2 or type(Text) ~= "string" then
        Log("re-entry file %s unreadable; starting empty", MemoryPath)
        return
    end
    local N = 0
    for Line in Text:gmatch("[^\r\n]+") do
        local Name, Id = Line:match("^([^\t]+)\t(.+)$")
        if Name and Id then
            Memory[Name] = Id
            N = N + 1
        end                                  -- anything else (corrupt line) is ignored
    end
    Log("re-entry memory: %d entr%s from %s", N, N == 1 and "y" or "ies", MemoryPath)
end

local function SaveMemory()
    local Lines = {}
    for Name, Id in pairs(Memory) do table.insert(Lines, Name .. "\t" .. Id) end
    table.sort(Lines)
    local Ok, F = pcall(io.open, MemoryPath, "w")
    if Ok and F then
        pcall(F.write, F, table.concat(Lines, "\n") .. "\n")
        pcall(F.close, F)
        return
    end
    if not MemoryWarned then
        MemoryWarned = true
        Log("cannot write the re-entry file %s; the last exit will not be remembered across game restarts", MemoryPath)
    end
end

local function Remember(Map, ExitId)
    if not Opt(Map, "ReEntry", true) or not ExitId then return end
    local Id = tostring(ExitId):gsub("[\t\r\n]", " ")
    Memory[Map.Name] = Id
    SaveMemory()
    Log("remembered exit '%s' for %s", Id, Map.Name)
end

---------------------------------------------------------------------------------------------------------------------
-- Markers
---------------------------------------------------------------------------------------------------------------------
local function TagsOf(P)
    local Out = {}
    pcall(function()
        P.Tags:ForEach(function(_, T) table.insert(Out, T:get():ToString()) end)
    end)
    return Out
end

-- Every TargetPoint in the streamed level, with its tags; picks out start / arrive:<id> / exit markers.
local function ScanMarkers(Map, Stream)
    local M = { All = {}, Start = nil, Arrive = {}, Exits = {} }
    local Level = Stream:GetLoadedLevel()
    local Points = FindAllOf("TargetPoint")
    if not Points or not Valid(Level) then return M end
    for _, P in ipairs(Points) do
        if Valid(P) and P:GetOuter():GetAddress() == Level:GetAddress() then
            local Rec = { P = P, Loc = Vec(P:K2_GetActorLocation()), Rot = Rot(P:K2_GetActorRotation()), Tags = TagsOf(P) }
            local IsExit, ExitId = false, nil
            for _, T in ipairs(Rec.Tags) do
                if T == Map.StartTag and not M.Start then M.Start = Rec end
                if T == Opt(Map, "ExitTag", ExitTag) then IsExit = true end
                if T:sub(1, #ExitIdPrefix) == ExitIdPrefix and #T > #ExitIdPrefix then
                    IsExit = true            -- an exit id alone also makes an exit
                    ExitId = ExitId or T:sub(#ExitIdPrefix + 1)
                end
                if T:sub(1, #ArrivePrefix) == ArrivePrefix and #T > #ArrivePrefix then
                    local Id = T:sub(#ArrivePrefix + 1)
                    if not M.Arrive[Id] then M.Arrive[Id] = Rec end
                end
            end
            Rec.IsExit, Rec.ExitId = IsExit, ExitId
            if IsExit then table.insert(M.Exits, { X = Rec.Loc.X, Y = Rec.Loc.Y, Z = Rec.Loc.Z, Id = ExitId }) end
            table.insert(M.All, Rec)
        end
    end
    return M
end

-- Where to arrive: the remembered exit's arrive marker if there is one, else the start marker
local function ChooseArrival(Map, M)
    if Opt(Map, "ReEntry", true) then
        local Id = Memory[Map.Name]
        if Id then
            if M.Arrive[Id] then
                Log("re-entry: last exit was '%s'; arriving at %s%s", Id, ArrivePrefix, Id)
                return M.Arrive[Id]
            end
            Log("re-entry: last exit was '%s' but the map has no '%s%s' marker; using '%s'", Id, ArrivePrefix, Id, Map.StartTag)
        end
    end
    return M.Start
end

-- The exit watch (ExitWatchTick, defined near the end of this file) runs only while a map with exit markers is loaded: standing near
-- a plain TargetPoint raises no event, so this is a check twice a second, started here and ended when the map is gone.
local ExitWatchTick = nil
local ExitWatching = false
local function ArmExits(M)
    if Current.Map.FromForm then            -- a form map leaves through its exit triggers (bound on arrival): no marker watch, no timer
        Current.Exits = {}
        return
    end
    Current.Exits = M.Exits
    if #M.Exits > 0 then
        local Ids = {}
        for _, E in ipairs(M.Exits) do table.insert(Ids, E.Id or "-") end
        Log("%d exit marker(s) (ids: %s)", #M.Exits, table.concat(Ids, ", "))
        for _, E in ipairs(M.Exits) do Log("exit point %s at (%.0f, %.0f, %.0f)", E.Id or "-", E.X, E.Y, E.Z) end
        if not ExitWatching then
            ExitWatching = true
            Every(500, function()
                local Done = ExitWatchTick()
                if Done then ExitWatching = false end
                return Done
            end)
        end
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Player helpers
---------------------------------------------------------------------------------------------------------------------
local function TeleportPlayer(Loc, Rt, What)
    local Pawn = UEHelpers.GetPlayer()
    if not Valid(Pawn) then
        Log("teleport %s: no player pawn", What)
        return false
    end
    local Ok, R = pcall(function() return Pawn:K2_TeleportTo(Loc, Rt) end)
    Log("teleport to %s %s: %s", What, FmtV(Loc), Ok and tostring(R) or ("error " .. tostring(R)))
    return Ok and R ~= false
end

local function PawnLoc()
    local Pawn = UEHelpers.GetPlayer()
    if not Valid(Pawn) then return nil end
    local Ok, L = pcall(function() return Vec(Pawn:K2_GetActorLocation()) end)
    if not Ok then
        LogOnce("pawnloc", "cannot read the pawn location: %s", tostring(L))
        return nil
    end
    return L
end

-- Is the player standing on this streamed level? true / false, or nil when the pawn can't tell.
-- Information only: Pawn:GetMovementBase() is not a UFunction (UE4SS c62ada0 returns an invalid object for it and every call
-- raised "Tried calling a member function but the UObject instance is nullptr", ~2000x per run), so the base is read as the
-- Character's BasedMovement.MovementBase property. It can be stale or empty for a VR pawn, so no decision depends on it;
-- the staging/exit decisions use the pawn's position (StablePosition below). One log line on the first failure.
local function OnMapGround(Stream)
    local Pawn = UEHelpers.GetPlayer()
    if not Valid(Pawn) or not Valid(Stream) then return nil end
    local Ok, Res = pcall(function()
        local Base = Pawn.BasedMovement.MovementBase
        if not Valid(Base) then return nil end
        local Owner = Base:GetOwner()
        local Level = Stream:GetLoadedLevel()
        if not Valid(Owner) or not Valid(Level) then return nil end
        return Owner:GetOuter():GetAddress() == Level:GetAddress()
    end)
    if not Ok then
        LogOnce("ground", "movement base unreadable (BasedMovement.MovementBase): %s; positions are used instead", tostring(Res))
        return nil
    end
    return Res
end

-- The pawn has stayed within HRadius (horizontal) and VRadius (vertical) cm of Target for HoldMs of wall-clock time.
-- State = a table the caller keeps between ticks. Returns true once stable, plus the current pawn location (may be nil).
local function StablePosition(State, Target, HRadius, VRadius, HoldMs)
    local L = PawnLoc()
    if L and Dist2D(L, Target) <= HRadius and math.abs(L.Z - Target.Z) <= VRadius then
        State.Since = State.Since or Now()
        if Now() - State.Since >= HoldMs then return true, L end
    else
        State.Since = nil
    end
    return false, L
end

---------------------------------------------------------------------------------------------------------------------
-- Hub teardown helpers
---------------------------------------------------------------------------------------------------------------------
-- Short names of the sublevels any level configuration lists (the game reloads these itself). nil: couldn't read it.
local function ManagedSublevels()
    local Ok, Set = pcall(function()
        local SCClass = StaticFindObject("/Script/IntoTheRadius.Default__SystemConfig")
        if not Valid(SCClass) then return nil end
        local SC = SCClass:GetSystemConfig()
        if not Valid(SC) then return nil end
        local Out, N = {}, 0
        SC.LevelConfigurations:ForEach(function(_, E)
            local C = E:get()
            Out[ShortName(C.MainSublevel:ToString())] = true
            C.StaticSublevels:ForEach(function(_, S) Out[ShortName(S:get():ToString())] = true end)
            N = N + 1
        end)
        if N == 0 then return nil end
        return Out
    end)
    if Ok then return Set end
    return nil
end

-- Request a Hub load from the game, like its gates do. LevelManager::LoadLevel takes a FGameplayTag by value (a plain
-- struct, no out-parameter), so UE4SS 3.0.1 can call it.
local function CallLoadLevelHub()
    local LM = GetLevelManager()
    if not LM then
        Log("exit: no LevelManager")
        return false
    end
    local Ok, Err = pcall(function() LM:LoadLevel({ TagName = FName(HubLevelTag) }) end)
    if not Ok then
        Log("exit: LevelManager LoadLevel(%s) failed: %s", HubLevelTag, tostring(Err))
        return false
    end
    Log("exit: LevelManager LoadLevel(%s) called; ready now %s", HubLevelTag, tostring(LM:IsReady()))
    return true
end

-- Fallback when LoadLevel does nothing (the game thinks it's still in the Hub): the game mode's
-- TransferToLevel(LevelTag, LocationTag), as the zone gates call it.
local function CallTransferHub()
    local Ok, Res = pcall(function()
        local GM = FindFirstOf("PRGameMode")
        if not Valid(GM) then error("no PRGameMode") end
        -- an interface function (IPRGameMode), not one of the game mode's class: call it with the game mode as context
        local Fn = StaticFindObject("/Script/IntoTheRadius.IPRGameMode:TransferToLevel")
        if not Valid(Fn) then error("IPRGameMode:TransferToLevel not found") end
        return Fn(GM, { TagName = FName(HubLevelTag) }, { TagName = FName("None") })
    end)
    Log("exit: game mode TransferToLevel(%s) -> %s", HubLevelTag, Ok and tostring(Res) or ("failed: " .. tostring(Res)))
    return Ok
end

---------------------------------------------------------------------------------------------------------------------
-- Lighting scenarios (no-teardown path)
---------------------------------------------------------------------------------------------------------------------
local function SetLightingScenariosHidden(World, Hide)
    if Hide then
        for _, S in ipairs(StreamingLevels(World)) do
            local L = S:GetLoadedLevel()
            if not SameObj(S, Current and Current.Stream) and Valid(L) and L.bIsLightingScenario and S:IsLevelVisible() then
                S:SetShouldBeVisible(false)
                table.insert(HiddenScenarios, S)
                Log("hid lighting scenario %s", PkgName(S))
            end
        end
    else
        for _, S in ipairs(HiddenScenarios) do
            if Valid(S) then S:SetShouldBeVisible(true) end
        end
        HiddenScenarios = {}
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Gameplay activation (streaming mode; untested in game)
---------------------------------------------------------------------------------------------------------------------
-- The map streams in after the Hub already fired its level-start events, so the map's gameplay actors (loot points,
-- stashes, anomalies, spawners, generators; all APRBasicActor) never get them. We call the same UFUNCTIONs on each actor
-- that lives in our level, in the game's order, through the actor so Blueprint overrides run. The global
-- UEventsManager delegates are NOT fired (the game mode, the player and the UI listen to those too).
local ActivateDelayMs = 3000                 -- after arrival: the actors' BeginPlay must have run
local LootBaseClass = "BP_LootSpawnPoint_C"  -- GenerateLoot is called on this class and its children

local function ClassNameOf(A)
    local Ok, N = pcall(function() return A:GetClass():GetFName():ToString() end)
    return Ok and N or "?"
end

-- Is the actor's class (or one of its parents) called Name?
local function IsClassNamed(A, Name)
    local Ok, Res = pcall(function()
        local C = A:GetClass()
        local Guard = 0
        while Valid(C) and Guard < 32 do
            if C:GetFName():ToString() == Name then return true end
            C = C:GetSuperStruct()
            Guard = Guard + 1
        end
        return false
    end)
    return Ok and Res or false
end

-- The level tag the game is in (Level.Hub with the Hub torn down); HubLevelTag when it can't be read.
local function CurrentLevelTagName()
    local Ok, N = pcall(function()
        local GD = FindFirstOf("PRGameData")
        if not Valid(GD) then return nil end
        return GD.CurrentLevelTag.TagName:ToString()
    end)
    if Ok and type(N) == "string" and N ~= "" and N ~= "None" then return N end
    return HubLevelTag
end

-- ---- loot manifest -----------------------------------------------------------------------------------------------------
-- The map's loot tags go into the game config's LootArray (TMap<FGameplayTag, FPRLootTableConfig>) before its loot is
-- generated, so its nodes never draw on the save-wide budgets of the real zone tags. The entries are added with TMap:Add through UE4SS.
-- Manifest = "<Map.Name>.loot.json" next to this script; a "<Map.Name>.loot.lua" returning the same table also works, or
-- set Map.LootManifest = path.

-- Minimal JSON decoder (objects, arrays, strings, numbers, true/false/null); errors on malformed input.
local function JsonDecode(Text)
    local Pos = 1
    local function Ws() Pos = Text:find("%S", Pos) or (#Text + 1) end
    local ParseValue
    local Esc = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }
    local function ParseString()
        local Out = {}
        Pos = Pos + 1
        while true do
            local C = Text:sub(Pos, Pos)
            if C == "" then error("unterminated string") end
            if C == '"' then Pos = Pos + 1; break end
            if C == "\\" then
                local N = Text:sub(Pos + 1, Pos + 1)
                if N == "u" then table.insert(Out, "?"); Pos = Pos + 6
                else table.insert(Out, Esc[N] or N); Pos = Pos + 2 end
            else
                table.insert(Out, C); Pos = Pos + 1
            end
        end
        return table.concat(Out)
    end
    ParseValue = function()
        Ws()
        local C = Text:sub(Pos, Pos)
        if C == "{" then
            local O = {}
            Pos = Pos + 1
            Ws()
            if Text:sub(Pos, Pos) == "}" then Pos = Pos + 1; return O end
            while true do
                Ws()
                if Text:sub(Pos, Pos) ~= '"' then error("object key expected at " .. Pos) end
                local K = ParseString()
                Ws()
                if Text:sub(Pos, Pos) ~= ":" then error("':' expected at " .. Pos) end
                Pos = Pos + 1
                O[K] = ParseValue()
                Ws()
                local D = Text:sub(Pos, Pos)
                Pos = Pos + 1
                if D == "}" then return O end
                if D ~= "," then error("',' or '}' expected at " .. (Pos - 1)) end
            end
        elseif C == "[" then
            local A = {}
            Pos = Pos + 1
            Ws()
            if Text:sub(Pos, Pos) == "]" then Pos = Pos + 1; return A end
            while true do
                table.insert(A, ParseValue())
                Ws()
                local D = Text:sub(Pos, Pos)
                Pos = Pos + 1
                if D == "]" then return A end
                if D ~= "," then error("',' or ']' expected at " .. (Pos - 1)) end
            end
        elseif C == '"' then
            return ParseString()
        elseif Text:sub(Pos, Pos + 3) == "true" then Pos = Pos + 4; return true
        elseif Text:sub(Pos, Pos + 4) == "false" then Pos = Pos + 5; return false
        elseif Text:sub(Pos, Pos + 3) == "null" then Pos = Pos + 4; return nil
        else
            local Num = Text:match("^-?%d+%.?%d*[eE]?[+-]?%d*", Pos)
            if not Num or Num == "" then error("unexpected character at " .. Pos) end
            Pos = Pos + #Num
            return tonumber(Num)
        end
    end
    local V = ParseValue()
    return V
end

-- Returns the manifest table (or nil) and the path that was used / tried last.
local function LoadLootManifest(Map)
    local Dir = ScriptDir()
    local Candidates = {}
    if Map.LootManifest then table.insert(Candidates, Map.LootManifest) end
    table.insert(Candidates, Dir .. Map.Name .. ".loot.json")
    table.insert(Candidates, Dir .. Map.Name .. ".loot.lua")
    local Tried = {}
    for _, Path in ipairs(Candidates) do
        table.insert(Tried, Path)
        if Path:sub(-5) == ".json" then
            local Ok, F = pcall(io.open, Path, "r")
            if Ok and F then
                local Text = F:read("*a")
                F:close()
                local Ok2, Res = pcall(JsonDecode, Text or "")
                if Ok2 and type(Res) == "table" then return Res, Path end
                Log("loot manifest %s is not usable: %s", Path, tostring(Res))
                return nil, Path
            end
        else
            local Chunk = loadfile(Path)
            if Chunk then
                local Ok, Res = pcall(Chunk)
                if Ok and type(Res) == "table" then return Res, Path end
                Log("loot manifest %s is not usable: %s", Path, tostring(Res))
                return nil, Path
            end
        end
    end
    return nil, table.concat(Tried, " | ")
end

local function TMapCount(M)
    local N = 0
    local Ok = pcall(function() M:ForEach(function() N = N + 1 end) end)
    return Ok and N or -1
end

-- The value struct of Key in the TMap, or nil. TMap:Find THROWS (natively, not catchable) on a missing key, so Contains first.
local function TMapFind(M, Key)
    local Okc, Has = pcall(function() return M:Contains(Key) end)
    if not Okc or Has ~= true then return nil end
    local Ok, V = pcall(function() return M:Find(Key) end)
    if not Ok or V == nil then return nil end
    if type(V) == "userdata" then
        local Ok2, Isv = pcall(function() return V:IsValid() end)
        if Ok2 and Isv == false then return nil end
        local Ok3, Got = pcall(function() return V:get() end)
        if Ok3 and Got ~= nil then return Got end
    end
    return V
end

local function LootArrayOf()
    local Ok, GC = pcall(function() return FindFirstOf("GameConfig") end)
    if not Ok or not Valid(GC) then return nil end
    local Ok2, M = pcall(function() return GC.LootArray end)
    if Ok2 then return M end
    return nil
end

local function LootHasTag(Tag)
    local M = LootArrayOf()
    return M ~= nil and TMapFind(M, { TagName = FName(Tag) }) ~= nil
end

-- Loading the map pak's DataTable. c62ada0's global LoadAsset goes through the asset registry and found nothing for pak-only
-- assets in the first run, so: (1) already loaded? (2) LoadAsset (3 results: object, found, loaded) (3) KismetSystemLibrary
-- LoadAsset_Blocking with a soft-object struct, the route used by the game's blueprints. The route that worked is logged once.
local function LoadOwnTable(Path)
    local function Try(Name, Fn)
        local Ok, O = pcall(Fn)
        if Ok and O ~= nil and type(O) == "userdata" then
            local Ok2, V = pcall(function() return O:IsValid() end)
            if Ok2 and V == true then
                LogOnce("loadroute", "loot: custom tables load via %s", Name)
                return O
            end
        end
        return nil
    end
    -- AssetRegistryHelpers::GetAsset(FAssetData) = FindObject, else LoadObject on ObjectPath: works for pak assets the game's asset
    -- registry does not list (it also finds pak assets the game's asset registry does not list). Tried first.
    local Obj = Path:find(".", 1, true) and Path or (Path .. "." .. ShortName(Path))
    return Try("AssetRegistryHelpers.GetAsset", function()
            local ARH = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
            return ARH:GetAsset({ ObjectPath = FName(Obj) })
        end)
        or Try("StaticFindObject", function() return StaticFindObject(Path) end)
        or Try("LoadAsset", function() local O = LoadAsset(Path); return O end)
        or Try("KismetSystemLibrary.LoadAsset_Blocking", function()
            local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
            return KSL:LoadAsset_Blocking({ AssetPathName = FName(Path), SubPathString = "" })
        end)
end

-- The map's table holder: one Blueprint actor in the map (config LootHolderClass, default "BP_<Map.Name>_LootTables_C") with
-- a "Tables" array that hard-references every loot DataTable, so the tables load with the level and the GC keeps them while
-- it is loaded (UE4SS Lua cannot AddToRoot). Returns { [DataTable name] = DataTable } and the count; empty for a map without
-- a holder.
local function HolderClassOf(Map) return Opt(Map, "LootHolderClass", "BP_" .. Map.Name .. "_LootTables_C") end

-- Loot state per map (maps register and switch their tables independently)
local LootCtxs = {}
local function LootCtxOf(Map)
    local C = LootCtxs[Map.Name]
    if not C then
        C = { Reg = { I = 0, Added = 0, Skipped = 0, NoDonor = 0, Failed = 0, Own = 0, Before = nil },
              Once = false,       -- the tags are registered (once per session)
              KeepAlive = {},     -- Lua-side references to the map's DataTables (not GC roots; see RegisterLootTags)
              Manifest = nil,     -- the manifest of the registration (re-pointing / clearing the map's entries on later loads / unload)
              Native = false }    -- native mode registered the tags at startup with donor tables: never load the map's own tables then
        LootCtxs[Map.Name] = C
    end
    return C
end

local function HeldTables(Map)
    local Out, N = {}, 0
    local Ok, All = pcall(FindAllOf, HolderClassOf(Map))
    if not Ok or not All then return Out, 0 end
    for _, H in ipairs(All) do
        if Valid(H) then
            pcall(function()
                H.Tables:ForEach(function(_, Elem)
                    local T = Elem:get()
                    if Valid(T) then
                        Out[T:GetFName():ToString()] = T
                        N = N + 1
                    end
                end)
            end)
        end
    end
    return Out, N
end

-- Called before the activation pass, once per session. For each manifest tag not already in LootArray: copy the donor
-- (source_tag) entry's table, set LootPoints, TMap:Add. The map's DataTable (table_asset) if the map pak includes it, else the donor's
-- (used points are then SHARED with the donor zone).
-- Progress survives a native error (not catchable by pcall) in the middle of the tag list: the step is re-run and resumes after the
-- tag that was being processed, so one bad tag is skipped instead of repeating forever or losing the rest.
-- The map's entries point at tables that live only while the map is loaded. Each later load re-points them at the tables the new
-- level's holder brought in (ToDonor = false), each unload points them back at the donor's vanilla table (ToDonor = true), so LootArray
-- never keeps a pointer to a collected table.
local function RepointOwnTables(Map, ToDonor)
    local Manifest = LootCtxOf(Map).Manifest
    local M = LootArrayOf()
    if not Manifest or type(Manifest.tags) ~= "table" or not M then return 0 end
    local Held, HeldN = {}, 0
    if not ToDonor then Held, HeldN = HeldTables(Map) end
    if not ToDonor and HeldN == 0 then
        Log("loot: %s: no table holder loaded; entries stay on the donor tables", Map.Name)
        return 0
    end
    local N, Missing = 0, 0
    for _, T in ipairs(Manifest.tags) do
        if type(T.tag) == "string" and type(T.table_name) == "string" and T.table_asset and T.table_asset ~= "" then
            local Back = TMapFind(M, { TagName = FName(T.tag) })
            local New = nil
            if ToDonor then
                local Donor = type(T.source_tag) == "string" and TMapFind(M, { TagName = FName(T.source_tag) }) or nil
                if Donor then pcall(function() New = Donor.LootTable end) end
            else
                New = Held[T.table_name]
            end
            if Back ~= nil and New ~= nil then
                if pcall(function() Back.LootTable = New end) then N = N + 1 end
            else
                Missing = Missing + 1
            end
        end
    end
    Log("loot: %s: own entries %s: %d re-pointed, %d without a table%s", Map.Name, ToDonor and "back to the donor tables (map unloaded)" or "to the map's held tables",
        N, Missing, ToDonor and "" or string.format(" (holder: %d table(s))", HeldN))
    return N
end

-- Append loaded assets to GameInstance.ReferencedObjects (a UPROPERTY TArray<UObject*> of the game instance: the garbage collector walks it and the
-- instance lives for the whole session). UE4SS Lua has no AddToRoot. Returns true, count after | false, reason.
local function KeepAssetsAlive(Objs)
    local GI = nil
    pcall(function() if UEHelpers.GetGameInstance then GI = UEHelpers.GetGameInstance() end end)
    if not Valid(GI) then
        local Ok, F = pcall(FindFirstOf, "GameInstance")
        if Ok and Valid(F) then GI = F end
    end
    if not Valid(GI) then return false, "no GameInstance yet" end
    local Ok, Arr = pcall(function() return GI.ReferencedObjects end)
    if not Ok or Arr == nil then return false, "GameInstance.ReferencedObjects is not readable" end
    local Before = Arr:GetArrayNum()
    for _, O in ipairs(Objs) do
        local Ok2, Err = pcall(function()
            local N = Arr:GetArrayNum()
            local _ = Arr[N + 1]                 -- an index past the end grows a TArray by one zeroed element in UE4SS c62ada0
            Arr[N + 1] = O
        end)
        if not Ok2 then return false, "could not append to ReferencedObjects: " .. tostring(Err) end
    end
    local Want = {}
    for _, O in ipairs(Objs) do Want[O:GetAddress()] = true end
    local After, Found = Arr:GetArrayNum(), 0
    if After - Before ~= #Objs then return false, string.format("ReferencedObjects grew by %d, expected %d", After - Before, #Objs) end
    for I = Before + 1, After do      -- read back only the tail that was written, by address
        local Ok3, O = pcall(function() return Arr[I] end)
        if Ok3 and Valid(O) and Want[O:GetAddress()] then Found = Found + 1 end
    end
    if Found ~= #Objs then return false, string.format("only %d of %d assets read back from ReferencedObjects", Found, #Objs) end
    return true, After
end

local function RegisterLootTags(Map, Manifest)
    if not Manifest then return 0 end
    local C = LootCtxOf(Map)
    if C.Once then return RepointOwnTables(Map, false) end
    local Tags = Manifest.tags
    if type(Tags) ~= "table" then
        Log("loot manifest: no tags array")
        return 0
    end
    local M = LootArrayOf()
    if not M then
        Log("loot manifest: GameConfig / LootArray not available yet; nothing registered")
        return 0
    end
    local R = C.Reg
    R.Held, R.HeldN = HeldTables(Map)
    if not R.Before then
        R.Before = TMapCount(M)
        Log("loot manifest: %d tag(s); LootArray has %d entries before", #Tags, R.Before)
    else
        Log("loot manifest: resuming after tag #%d (the previous attempt was aborted by a native error)", R.I)
    end
    for I = R.I + 1, #Tags do
        R.I = I
        local T = Tags[I]
        local Tag, Src, Points = T.tag, T.source_tag, math.floor(tonumber(T.loot_points) or 0)
        if type(Tag) == "string" and Tag ~= "" then
            local Key = { TagName = FName(Tag) }
            if TMapFind(M, Key) ~= nil then
                R.Skipped = R.Skipped + 1
                Log("loot: tag %s already in LootArray: skipped", Tag)
            else
                local Donor = type(Src) == "string" and TMapFind(M, { TagName = FName(Src) }) or nil
                if Donor == nil then
                    R.NoDonor = R.NoDonor + 1
                    Log("loot: tag %s: source tag %s not in LootArray (no donor DataTable): skipped", Tag, tostring(Src))
                else
                    local Table = Donor.LootTable
                    local OwnTable = nil
                    if type(T.table_asset) == "string" and T.table_asset ~= "" then
                        if C.Native then
                            -- native maps: the table is loaded now and kept alive for the session (below), so no holder actor is needed
                            OwnTable = LoadOwnTable(T.table_asset)
                        else
                            OwnTable = R.Held[T.table_name or ""]
                            if OwnTable then
                                LogOnce("held", "loot: custom tables come from the map's table holder (%d table(s))", R.HeldN)
                            else
                                OwnTable = LoadOwnTable(T.table_asset)
                                if OwnTable then
                                    Log("loot: tag %s: table %s is NOT held by the map (no %s actor): nothing keeps it alive in Lua", Tag,
                                        tostring(T.table_asset), HolderClassOf(Map))
                                end
                            end
                        end
                    end
                    if OwnTable then
                        Table = OwnTable
                        R.Own = R.Own + 1
                        Log("loot: tag %s: own DataTable %s (isolated used points)", Tag, T.table_asset)
                    else
                        Log("loot: tag %s: no own DataTable asset (%s); using the donor's: its used points are SHARED with the zone tag %s",
                            Tag, tostring(T.table_asset), tostring(Src))
                    end
                    Log("loot: tag %s: adding (budget %d)", Tag, Points)
                    local Ok, Err = pcall(function()
                        M:Add(Key, { Conditions = {}, LootPoints = Points, LootTable = Table, ExcludeGeneration = false })
                    end)
                    if not Ok then
                        R.Failed = R.Failed + 1
                        Log("loot: tag %s: TMap:Add failed: %s", Tag, tostring(Err))
                    else
                        local Back = TMapFind(M, Key)
                        if Back ~= nil then
                            -- c62ada0's TMap:Add stored a zeroed value (read back: budget 0), so write the fields into the stored
                            -- struct in place (Find hands out a reference to the map's storage)
                            local PtsNow = -1
                            pcall(function() PtsNow = Back.LootPoints end)
                            if PtsNow ~= Points then
                                local OkW, ErrW = pcall(function()
                                    Back.LootPoints = Points
                                    Back.LootTable = Table
                                    Back.ExcludeGeneration = false
                                end)
                                pcall(function() PtsNow = Back.LootPoints end)
                                LogOnce("inplace", "loot: Add stored the struct without its fields; wrote LootPoints/LootTable in place: %s (LootPoints now %s)",
                                    OkW and "ok" or tostring(ErrW), tostring(PtsNow))
                            end
                            R.Added = R.Added + 1
                            local Pts = -1
                            pcall(function() Pts = Back.LootPoints end)
                            Log("loot: tag %s added: budget %s (wanted %d), donor %s", Tag, tostring(Pts), Points, tostring(Src))
                            if OwnTable then
                                -- UE4SS Lua has no AddToRoot / SetFlags (only HasAnyFlags / HasAnyInternalFlags), so the map's
                                -- DataTable is kept alive the only way Lua can: by the UPROPERTY reference in GameConfig.LootArray
                                -- (a TMap<FGameplayTag, FPRLootTableConfig> on a live data asset is traversed by the GC). Pin the
                                -- Lua wrapper too, and log the root-set bit (EInternalObjectFlags::RootSet = 1<<30) once per table.
                                C.KeepAlive[Tag] = OwnTable
                                local Ok3, Root = pcall(function() return OwnTable:HasAnyInternalFlags(0x40000000) end)
                                local Ok4, TblBack = pcall(function() return Back.LootTable end)
                                Log("loot: tag %s: custom table %s RootSet flag %s; referenced from LootArray: %s", Tag,
                                    ClassNameOf(OwnTable) .. " " .. tostring(T.table_asset), Ok3 and tostring(Root) or "unreadable",
                                    (Ok4 and Valid(TblBack)) and "yes (GC-reachable)" or "no")
                            end
                        else
                            R.Failed = R.Failed + 1
                            Log("loot: tag %s: TMap:Add returned but Find does not see it", Tag)
                        end
                    end
                end
            end
        end
    end
    if C.Native then
        -- the map's tables stay loaded for the session: unique objects by address
        local Objs, Seen = {}, {}
        for _, O in pairs(C.KeepAlive) do
            local Ok, A = pcall(function() return O:GetAddress() end)
            if Ok and not Seen[A] then Seen[A] = true; Objs[#Objs + 1] = O end
        end
        if #Objs > 0 then
            local OkK, Info = KeepAssetsAlive(Objs)
            Log("loot: %d custom loot table(s) kept alive in GameInstance.ReferencedObjects (%s)", #Objs, OkK and ("array now " .. tostring(Info)) or ("FAILED: " .. tostring(Info)))
            if not OkK then
                -- a table left in LootArray with nothing referencing it is collected and read later (access violation): point the entries back at the donor tables
                C.Manifest = Manifest
                RepointOwnTables(Map, true)
                Log("loot: the entries point at the donor tables instead")
            end
        end
    end
    C.Once = true
    C.Manifest = Manifest
    Log("loot manifest registered: LootArray %d -> %d entries (%d added, %d already present, %d without donor, %d failed, %d custom tables)",
        R.Before, TMapCount(M), R.Added, R.Skipped, R.NoDonor, R.Failed, R.Own)
    return R.Added
end

-- Optional dev aid (config LootRetagShim = { NodePrefix, TagPrefix, GeneratorId [, FromPrefix] }, off by default): for a map
-- whose loot nodes still carry stock tags. Nodes whose actor name starts with NodePrefix get their loot tag
-- FromPrefix<Area>.<Cat> (default FromPrefix "Loot.Buffer.") rewritten to TagPrefix<Cat>, and the spawn generators among them
-- get the generator id GeneratorId. The new tags must be registered (loot manifest).
local function LootRetagShim(Map, Acts)
    local Cfg = Opt(Map, "LootRetagShim", false)
    if type(Cfg) ~= "table" or type(Cfg.NodePrefix) ~= "string" then return end
    local NodePrefix, TagPrefix, GenId = Cfg.NodePrefix, Cfg.TagPrefix or "", Cfg.GeneratorId
    local FromPrefix = Cfg.FromPrefix or "Loot.Buffer."
    local Nodes, Gens = 0, 0
    for _, A in ipairs(Acts) do
        if Valid(A) then
            local Name = A:GetFName():ToString()
            if Name:sub(1, #NodePrefix) == NodePrefix then
                if IsClassNamed(A, LootBaseClass) then
                    local Ok, Old = pcall(function() return A.LootTable.TagName:ToString() end)
                    local New = ""
                    if Ok and Old:sub(1, #FromPrefix) == FromPrefix then
                        local Rest = Old:sub(#FromPrefix + 1)
                        if Rest:sub(1, 6) == "Stash." then New = TagPrefix .. Rest
                        else New = TagPrefix .. (Rest:match("^[^.]+%.(.*)$") or Rest) end
                    end
                    if New == "" or not LootHasTag(New) then
                        Log("loot: retag %s: %s -> %s not possible (tag not registered)", Name, tostring(Old), New)
                    else
                        local Ok2, Err = pcall(function() A.LootTable = { TagName = FName(New) } end)
                        Log("loot: retag %s: %s -> %s: %s", Name, tostring(Old), New, Ok2 and "done" or ("ERROR " .. tostring(Err)))
                        if Ok2 then Nodes = Nodes + 1 end
                    end
                elseif GenId and ClassNameOf(A):find("SpawnGenerator", 1, true) then
                    local Ok, Old = pcall(function() return A.generatorID.TagName:ToString() end)
                    local Ok2, Err = pcall(function() A.generatorID = { TagName = FName(GenId) } end)
                    Log("loot: generator %s id %s -> %s: %s", Name, Ok and Old or "?", GenId, Ok2 and "done" or ("ERROR " .. tostring(Err)))
                    if Ok2 then Gens = Gens + 1 end
                end
            end
        end
    end
    Log("loot: retag shim done: %d node(s) retagged, %d generator id(s)", Nodes, Gens)
end

-- Every APRBasicActor whose outer is our streamed level
local function BasicActorsIn(Stream)
    local Out = {}
    local Level = Stream:GetLoadedLevel()
    if not Valid(Level) then return Out end
    local LA = Level:GetAddress()
    local All = FindAllOf("PRBasicActor")
    if not All then return Out end
    for _, A in ipairs(All) do
        if Valid(A) and A:GetOuter():GetAddress() == LA then table.insert(Out, A) end
    end
    return Out
end

local function CountByClass(Acts)
    local C = {}
    for _, A in ipairs(Acts) do
        if Valid(A) then
            local N = ClassNameOf(A)
            C[N] = (C[N] or 0) + 1
        end
    end
    return C
end

local function SortedKeys(T)
    local K = {}
    for k in pairs(T) do table.insert(K, k) end
    table.sort(K)
    return K
end

-- One pass: call Fn(Args) on every actor in Acts that passes Filter and is still valid, logging each call.
-- One pass: call Fn(Args) on every actor in Acts that passes Filter and is still valid. St = {I, C} lives in the caller's context:
-- a native error in a call (not catchable by pcall) aborts the step, the step is re-run and resumes after that actor.
local function ActivationPass(Acts, Fn, Args, Filter, St)
    St.I = St.I or 0
    St.C = St.C or { Ok = 0, NoFunc = 0, Failed = 0, Dead = 0 }
    local C = St.C
    if St.I > 0 then Log("activate: %s: resuming after actor #%d (aborted by a native error)", Fn, St.I) end
    while St.I < #Acts do
        St.I = St.I + 1
        local A = Acts[St.I]
        if not Filter or Filter(A) then
            if not Valid(A) then
                C.Dead = C.Dead + 1
            else
                local Name = A:GetFName():ToString()
                local Cls = ClassNameOf(A)
                C.Failed = C.Failed + 1                -- counted as failed until the call returns (undone below)
                local Found, Ok, Res = CallUF(A, Fn, (table.unpack or unpack)(Args or {}))
                C.Failed = C.Failed - 1
                if not Found then
                    C.NoFunc = C.NoFunc + 1
                    if C.NoFunc <= 10 then Log("activate: %s -> %s (%s): NO SUCH FUNCTION", Fn, Name, Cls) end
                elseif Ok then
                    C.Ok = C.Ok + 1
                    if C.Ok <= 25 or not Valid(A) or Name:sub(1, 3) == "G2_" then
                        Log("activate: %s -> %s (%s): called%s%s", Fn, Name, Cls, Res ~= nil and (" = " .. tostring(Res)) or "",
                            Valid(A) and "" or "; actor DESTROYED itself")
                    end
                else
                    C.Failed = C.Failed + 1
                    if C.Failed <= 10 then Log("activate: %s -> %s (%s): ERROR %s", Fn, Name, Cls, tostring(Res)) end
                end
            end
        end
    end
    Log("activate: %s: %d called, %d without the function, %d errors, %d already gone", Fn, C.Ok, C.NoFunc, C.Failed, C.Dead)
    return C
end

local function ActivationSteps(Map, Stream, Ctx)
    local function Alive()
        if Valid(Stream) and CallBool(Stream, "IsLevelVisible") then return true end
        Log("activate: step skipped (map gone)")
        return false
    end
    local function IsLoot(A) return IsClassNamed(A, LootBaseClass) end
    -- The native APRLootSpawner::OnLevelPrepare arms a distance timer that calls SpawnLoot once the player is within
    -- GameConfig.LootSpawnDistance; calling SpawnLoot here as well spawned every item twice. So: OnLevelPrepare +
    -- GenerateLoot only, and no OnLevelPrepare for a node that already spawned (saved items from an earlier visit), which would re-arm it.
    local function NotPreSpawned(A)
        local Ok, Addr = pcall(function() return A:GetAddress() end)
        return not (Ok and Ctx.PreSpawned and Ctx.PreSpawned[Addr])
    end
    local function PassStep(Key, Fn, Args, Filter)
        return { Pass = true, Run = function()
            if not Alive() then Ctx[Key] = Ctx[Key] or { Ok = 0, Failed = 0 }; return end
            local St = Ctx[Key .. "St"]
            if not St then St = {}; Ctx[Key .. "St"] = St end
            St.C = St.C or { Ok = 0, NoFunc = 0, Failed = 0, Dead = 0 }
            Ctx[Key] = St.C
            ActivationPass(Ctx.Acts, Fn, Args and Args(Ctx) or nil, Filter, St)
        end }
    end
    local function TagArgs(C) return { C.Tag } end
    return {
        { Run = function()
            Ctx.T0 = os.clock()
            if not Alive() then return end
            Ctx.TagName = CurrentLevelTagName()
            Ctx.Tag = { TagName = FName(Ctx.TagName) }
            Ctx.Acts = BasicActorsIn(Stream)
            local Before = CountByClass(Ctx.Acts)
            Ctx.Before = Before
            Log("activate: %d APRBasicActor(s) in %s; level tag %s", #Ctx.Acts, Map.Level, Ctx.TagName)
            for _, N in ipairs(SortedKeys(Before)) do Log("activate:   %s x %d", N, Before[N]) end
            Ctx.PreSpawned, Ctx.PreSpawnedN = {}, 0
            for _, A in ipairs(Ctx.Acts) do
                if Valid(A) and IsLoot(A) then
                    local Ok, N = pcall(function() return A.SpawnedItems:GetArrayNum() end)
                    if Ok and (N or 0) > 0 then
                        Ctx.PreSpawned[A:GetAddress()] = true
                        Ctx.PreSpawnedN = Ctx.PreSpawnedN + 1
                    end
                end
            end
            Log("activate: %d loot node(s) already spawned their items (no OnLevelPrepare for them)", Ctx.PreSpawnedN)
            local Manifest, ManifestPath = LoadLootManifest(Map)
            if Manifest then Log("activate: loot manifest %s", ManifestPath)
            else Log("activate: no loot manifest (tried %s)", ManifestPath) end
            Ctx.Step1Done = true
        end },
        { Pass = true, Run = function()
            -- loot tags: TMap:Add into GameConfig.LootArray (a native error here only loses this step)
            if not Alive() then return end
            local Manifest = LoadLootManifest(Map)
            local Ok, Err = pcall(RegisterLootTags, Map, Manifest)
            if not Ok then Log("activate: RegisterLootTags failed: %s", tostring(Err)) end
            if type(Opt(Map, "LootRetagShim", false)) == "table" then
                local Ok2, Err2 = pcall(LootRetagShim, Map, Ctx.Acts)
                if not Ok2 then Log("activate: LootRetagShim failed: %s", tostring(Err2)) end
            end
        end },
        -- Order of the game's chain (level-activation.md section 3). An actor that destroys itself in OnLevelPrepare
        -- (generator excluded in the save) is skipped by the later passes through the Valid check.
        PassStep("Prep", "OnLevelPrepare", TagArgs, NotPreSpawned),
        PassStep("Gen", "GenerateLoot", nil, IsLoot),
        -- (no SpawnLoot pass: the native distance check spawns each node's items once)
        PassStep("Start", "OnLevelStarted", TagArgs),
        PassStep("Game", "OnGameStarted"),
        PassStep("Trans", "OnTransitionEnd"),
        { Run = function()
            local Acts = Ctx.Acts or {}
            local After = CountByClass(Acts)
            Log("activate: summary per class (before -> alive after):")
            for _, N in ipairs(SortedKeys(Ctx.Before or {})) do
                Log("activate:   %s: %d -> %d%s", N, Ctx.Before[N], After[N] or 0, (After[N] or 0) < Ctx.Before[N] and "  (destroyed itself)" or "")
            end
            local Z = { Ok = 0, Failed = 0 }
            local P, G, S, St, Gm, T = Ctx.Prep or Z, Ctx.Gen or Z, Ctx.Spawn or Z, Ctx.Start or Z, Ctx.Game or Z, Ctx.Trans or Z
            Log("activate: done in %.0f ms; level tag %s; basic actors %d; OnLevelPrepare %d, GenerateLoot %d, SpawnLoot %d (native), "
                .. "OnLevelStarted %d, OnGameStarted %d, OnTransitionEnd %d; errors %d", (os.clock() - (Ctx.T0 or os.clock())) * 1000,
                Ctx.TagName or "?", #Acts, P.Ok, G.Ok, S.Ok, St.Ok, Gm.Ok, T.Ok,
                P.Failed + G.Failed + S.Failed + St.Failed + Gm.Failed + T.Failed)
        end },
    }
end

-- Once per load: ActivateDelayMs after the player is settled, if this load is still the current one and still visible
local function ScheduleActivation(Map)
    if not Opt(Map, "ActivateGameplay", true) then
        Log("activate: off (ActivateGameplay = false)")
        return
    end
    if not Current or Current.Activated then return end
    Current.Activated = true
    local Stream = Current.Stream
    local T0w = Now()
    local Ctx, Steps = { Next = 0, Tries = {} }, nil
    Every(250, function()
        if not Current or not SameObj(Current.Stream, Stream) or not Valid(Stream) then
            Log("activate: skipped (map unloaded or another load started)")
            return true
        end
        if Now() - T0w < ActivateDelayMs then return false end
        Steps = Steps or ActivationSteps(Map, Stream, Ctx)
        local I = Ctx.Next + 1
        if I > #Steps then return true end
        -- a step that was aborted by a native error is re-run (passes resume where they stopped); the others get 2 attempts
        Ctx.Tries[I] = (Ctx.Tries[I] or 0) + 1
        if Ctx.Tries[I] > (Steps[I].Pass and 300 or 2) then
            Log("activate: step %d given up after %d attempts", I, Ctx.Tries[I] - 1)
            Ctx.Next = I
            return Ctx.Next >= #Steps
        end
        Steps[I].Run()
        Ctx.Next = I
        return I >= #Steps
    end, 400)
end

---------------------------------------------------------------------------------------------------------------------
-- Arrival
---------------------------------------------------------------------------------------------------------------------
-- Watches whether the player stays at the arrival point after the teardown (the Hub's snap-back shows up here)
local function StayCheck(Arrive)
    local At = { 1, 3, 6, 10, 20 }
    local T0w = Now()
    local Step, Elapsed = 1, 0
    Every(500, function()
        if not Current or Current.Phase ~= "active" then return true end
        Elapsed = math.floor(Now() - T0w)
        if Elapsed < At[Step] * 1000 then return false end
        local L = PawnLoc()
        if L then
            local D = Dist3D(L, Arrive)
            Log("stay check +%ds: player at %s, %.0f m from the arrival point: %s", At[Step], FmtV(L), D / 100,
                D < 30000 and "stayed" or "MOVED AWAY (snap-back?)")
            if D >= 30000 then return true end
        end
        Step = Step + 1
        return Step > #At
    end)
end

local function Arrive(Map, M, Rec)
    if Rec then
        TeleportPlayer(Rec.Loc, Rec.Rot, "arrival marker")
    else
        Log("no start marker tagged '%s' in %s (or no player pawn); you stay where you are", Map.StartTag, Map.Level)
    end
    ArmExits(M)
    Current.Phase = "active"
    if Rec and Current.TornDown then StayCheck(Rec.Loc) end
    ScheduleActivation(Map)
end

---------------------------------------------------------------------------------------------------------------------
-- Hub teardown (streaming mode; untested in game)
---------------------------------------------------------------------------------------------------------------------
-- Staging point: a TargetPoint east of StagingMaxWestX (positions west of about X -30000 snap back to the Hub while it
-- is loaded), preferring itr:tp:* / itr:arrive* / itr:exit_id* markers, nearest to itr:player_start.
local function FindStaging(M)
    local Ref = M.Start and M.Start.Loc or nil
    local Best, BestD, BestTier = nil, 1e30, 3
    for _, Rec in ipairs(M.All) do
        if Rec ~= M.Start and Rec.Loc.X > StagingMaxWestX then
            local Tier = 2
            for _, T in ipairs(Rec.Tags) do
                if T:sub(1, 7) == "itr:tp:" or T:sub(1, 10) == "itr:arrive" or T:sub(1, 11) == "itr:exit_id" then Tier = 1 end
            end
            local D = Ref and Dist3D(Rec.Loc, Ref) or 0
            if Tier < BestTier or (Tier == BestTier and D < BestD) then
                Best, BestD, BestTier = Rec, D, Tier
            end
        end
    end
    if not Best and M.Start and M.Start.Loc.X > StagingMaxWestX then
        Best, BestD = M.Start, 0                 -- the start itself is east of the limit: stand there
    end
    return Best, BestD
end

-- Unload every streaming level that isn't ours (and doesn't hold the player), wait until they are gone, then call Done.
local function UnloadHub(Map, M, Arrival, Staging)
    local T0 = os.clock()
    local World = UEHelpers.GetWorld()
    local Pawn, PC = UEHelpers.GetPlayer(), UEHelpers.GetPlayerController()
    local Levels = {}
    local Idle = 0
    for _, S in ipairs(StreamingLevels(World)) do
        if not SameObj(S, Current.Stream) then
            if not StreamActive(S) then
                Idle = Idle + 1
            else
                local L = S:GetLoadedLevel()
                local H = {
                    S = S, Package = PkgName(S), Name = ShortName(PkgName(S)),
                    WasLoaded = CallBool(S, "IsLevelLoaded"), WasVisible = CallBool(S, "IsLevelVisible"),
                    WasShouldLoad = PropBool(S, "bShouldBeLoaded"), WasShouldVisible = PropBool(S, "bShouldBeVisible"),
                    Scenario = Valid(L) and PropBool(L, "bIsLightingScenario") or false,
                }
                if Valid(L) then
                    -- a level holding the player's pawn / controller stays
                    local LA = L:GetAddress()
                    for _, O in ipairs({ Pawn, PC }) do
                        if Valid(O) and O:GetOuter():GetAddress() == LA then
                            H.Kept = true
                            Log("Hub teardown: player's %s lives in %s: that level is KEPT", O:GetFullName(), H.Name)
                        end
                    end
                end
                table.insert(Levels, H)
            end
        end
    end
    local Count = 0
    for _, H in ipairs(Levels) do
        Log("Hub teardown: %s %s (%s): %s%s", H.Kept and "KEEP" or "unload", H.Name, H.Package, StreamBitsText(H.S),
            H.Scenario and ", lighting scenario" or "")
        if not H.Kept then
            H.S:SetShouldBeVisible(false)
            H.S:SetShouldBeLoaded(false)
            Count = Count + 1
        end
    end
    Current.HubLevels = Levels
    Current.TornDown = true
    Log("Hub teardown: %d level(s) unloading, %d kept, %d streaming level(s) already idle", Count, #Levels - Count, Idle)
    Current.Phase = "tearing"
    local T0w = Now()
    local Waited = 0
    Every(250, function()
        if not Current or not Valid(Current.Stream) then return true end
        Waited = math.floor(Now() - T0w)
        local Left = 0
        for _, H in ipairs(Levels) do
            if not H.Kept and not H.Gone then
                if not Valid(H.S) or not (CallBool(H.S, "IsLevelLoaded") or CallBool(H.S, "IsLevelVisible")) then
                    H.Gone = true
                    Log("Hub teardown: %s unloaded after %d ms", H.Name, Waited)
                else
                    Left = Left + 1
                end
            end
        end
        -- loaded but hidden and not requested for 5 s (L_Transition after a -nohmd start): an unload that never completes. A level
        -- that is not visible has no collision and runs nothing, so it cannot hold or move the player: counted as gone.
        if Left > 0 and Waited > 5000 then
            for _, H in ipairs(Levels) do
                if not H.Kept and not H.Gone and Valid(H.S) and not CallBool(H.S, "IsLevelVisible")
                    and not PropBool(H.S, "bShouldBeLoaded") and not PropBool(H.S, "bShouldBeVisible") then
                    H.Gone = true
                    Left = Left - 1
                    Log("Hub teardown: %s is loaded but hidden and not requested after %d ms (%s); counted as gone", H.Name, Waited,
                        StreamBitsText(H.S))
                end
            end
        end
        if Left > 0 and Waited < 30000 then return false end
        for _, H in ipairs(Levels) do
            if not H.Kept and not H.Gone then
                Log("Hub teardown: %s still there after %d ms (%s)  <-- did not unload", H.Name, Waited, StreamBitsText(H.S))
            end
        end
        local L = PawnLoc()
        local Ground = OnMapGround(Current.Stream)
        Log("Hub teardown done after %d ms: %d unloaded, %d left; player at %s, on map ground: %s", Waited,
            Count - Left, Left, L and FmtV(L) or "?", tostring(Ground))
        if Left > 0 then
            Log("Hub teardown: NOT moving to the arrival marker (%d Hub level(s) did not unload, on map ground: %s); "
                .. "the player stays at the staging point", Left, tostring(Ground))
            ArmExits(M)
            Current.Phase = "active"
            ScheduleActivation(Map)              -- activate whatever the teardown did
            return true
        end
        Log("Hub teardown: %.1f s since the map became visible; moving to the arrival marker", os.clock() - T0)
        Arrive(Map, M, Arrival)
        return true
    end)
end

-- (a) to the staging point, (b) confirm the player stands on the map, (c) unload the Hub, (d) arrive
local function Teardown(Map, M)
    local Arrival = ChooseArrival(Map, M)
    local Staging, StageD = FindStaging(M)
    if not Staging then
        Log("Hub teardown skipped: %s has no TargetPoint east of X %.0f to stand on while the Hub unloads; plain arrival",
            Map.Level, StagingMaxWestX)
        if Map.HideLightingScenario then SetLightingScenariosHidden(UEHelpers.GetWorld(), true) end
        Arrive(Map, M, Arrival)
        return
    end
    Log("Hub teardown: staging point %s (%.0f m from the start marker)", FmtV(Staging.Loc), StageD / 100)
    Current.Phase = "staging"
    TeleportPlayer(Staging.Loc, Staging.Rot, "staging point")
    local T0w = Now()
    local Waited, Stable, Logged = 0, {}, 0
    Every(250, function()
        if not Current or not Valid(Current.Stream) then return true end
        Waited = math.floor(Now() - T0w)
        -- Standing on the map = the pawn has held still at the staging point for 1.5 s (the Hub is far away from it, so the
        -- only ground there is the map's; a snap-back to the Hub would move the pawn). The movement base is logged for info.
        local Confirmed, L = StablePosition(Stable, Staging.Loc, 400, 1000, 1500)
        if Confirmed then
            local Ground = OnMapGround(Current.Stream)
            Log("Hub teardown +%d ms: player at %s held the staging point 1.5 s (movement base on map: %s); unloading the Hub",
                Waited, L and FmtV(L) or "?", tostring(Ground))
            UnloadHub(Map, M, Arrival, Staging)
            return true
        end
        if Waited >= 2000 * (Logged + 1) and Logged < 7 then
            Logged = Logged + 1
            Log("Hub teardown: waiting %d ms; player at %s, %s from the staging point", Waited, L and FmtV(L) or "?",
                L and string.format("%.0f cm", Dist3D(L, Staging.Loc)) or "?")
        end
        if Waited >= 15000 then
            Log("Hub teardown skipped: the player did not hold the staging point within 15 s (player at %s)", L and FmtV(L) or "?")
            if Map.HideLightingScenario then SetLightingScenariosHidden(UEHelpers.GetWorld(), true) end
            Arrive(Map, M, Arrival)
            return true
        end
        return false
    end)
end

---------------------------------------------------------------------------------------------------------------------
-- Native level (config Native = true; one native map per loader mod, see README.md)
---------------------------------------------------------------------------------------------------------------------
-- How the game finds a level, read from the 2.7.2 exe (static disassembly, not a guess):
--   * USystemConfig::IsLevelTagValid / GetLevelConfig walk SystemConfig.LevelConfigurations (TArray<FLevelConfig>, 0x70 bytes
--     a row) on every call and compare the tag's FName. Nothing is cached, so a row appended at runtime is seen.
--   * ULevelManager::LoadSublevel(Name) calls UGameplayStatics::GetStreamingLevel(Name): every call walks World.StreamingLevels
--     and takes the first entry whose world-asset package name ends with "/<Name>" (case-insensitive). No cache either.
--   * FLGeneral::GetActorLevelTag (used by IsActorInLevel, PlayerStart search, zone gates) maps an actor to a level by the NAME
--     OF ITS UWORLD object (not the package) against MainSublevel / StaticSublevels.
-- So: MainSublevel = the map's world name (short name of Map.Level, e.g. L_Example), and the streaming entry made with
-- LevelStreaming::CreateInstance(<that name>) gets the package "<source dir>/L_Example" (suffix match) while the loaded
-- world keeps its own object name L_Example (actor -> level tag match). PackageNameToLoad points it at the real package.
--
-- Registration (once per session for the row and map centre, once per world for the streaming entry), all fail-safe:
--   (1) streaming entry, unloaded and hidden; (2) row: TArray grows by one zeroed element (UE4SS c62ada0 TArray:__index past the
--   end = FScriptArray::AddZeroed through the game's GMalloc), fields copied from a donor zone row and overridden, the tag written
--   LAST, then checked: earlier rows unchanged and the game's IsLevelTagValid says yes; (3) MapPointsConfig.levelCenters entry;
--   (4) the loot manifest (tables loaded through AssetRegistryHelpers.GetAsset and held by GameConfig.LootArray).
-- If any of (1)/(2) fails, native entry stays off for the session (logged), nothing else changes.
--
-- Saves: by default (NativeSaves = false) the row turns off autosave, save-on-load, save-on-exit and sleeping, so no save file is
-- ever written while the game stands in the map's level: what you did there is kept by the Hub autosave after you return
-- (save-wide data: loot taken, spawners, inventory). A save that still names the level (NativeSaves = true) is moved to the Hub
-- by the startup guard below when the registration failed.
local NativeState = { Ready = false, Failed = nil, RowDone = false, CenterDone = false, LootDone = false, WorldAddr = nil,
                      Entry = nil, Map = nil, Tag = nil, Sub = nil, RowFill = nil, Checks = 0, Logged = {} }
local NativeTrip = nil       -- the current native transfer in progress { Map, T0, Phase, Return }
-- One record per native map (config maps and form maps). NativeState points at the record being worked on: every entry point selects the
-- record of its map first (NativeSelect), then the functions below read and write it as they always did.
local NativeList, NativeBy = {}, {}
local NativeRegisterNow            -- defined after NativeAttempt
local Maps = nil             -- maps.lua (form maps), set at the end of this file
local function NativeNew(Map)
    local N = { Ready = false, Failed = nil, RowDone = false, CenterDone = false, LootDone = false, WorldAddr = nil,
                Entry = nil, Map = Map, Tag = nil, Sub = nil, RowFill = nil, Checks = 0, Logged = {} }
    table.insert(NativeList, N)
    NativeBy[Map] = N
    return N
end
local function NativeSelect(Map)
    local N = Map and NativeBy[Map] or nil
    if N then NativeState = N end
    return N
end

local function NativeTagOf(Map) return Map.NativeTag or ("Level.Zone." .. Map.Name) end
local function NativeSubOf(Map) return Map.NativeSublevel or ShortName(Map.Level) end
local function TagStruct(Name) return { TagName = FName(Name) } end

local function GetSystemConfig()
    local Ok, SC = pcall(function()
        local C = StaticFindObject("/Script/IntoTheRadius.Default__SystemConfig")
        if not Valid(C) then return nil end
        return C:GetSystemConfig()
    end)
    if Ok and Valid(SC) then return SC end
    return nil
end

-- Live (non-default) instances of a class, by short class name
local function LiveOf(ClassName)
    local Out = {}
    local Ok, All = pcall(FindAllOf, ClassName)
    if not Ok or not All then return Out end
    for _, O in ipairs(All) do
        if Valid(O) then
            local Okn, N = pcall(function() return O:GetFName():ToString() end)
            if Okn and type(N) == "string" and N:sub(1, 9) ~= "Default__" then table.insert(Out, O) end
        end
    end
    return Out
end

-- FindAllOf walks every object; the game mode / game data lookups are cached for 2 s (and re-checked with IsValid) so the
-- 100 ms transfer loop does not scan the object array while the level streams
local LookCache = {}
local function Cached(Key, Fn)
    local C = LookCache[Key]
    if C and Now() - C.T < 2000 and Valid(C.O) then return C.O end
    local O = Fn()
    LookCache[Key] = O and { O = O, T = Now() } or nil
    return O
end

local function GetGameMode()
    return Cached("gm", function() return LiveOf("PRGameMode")[1] end)
end

-- The game data that holds the current level: the live PRGameData whose CurrentLevelTag is set (others: none, or a save preview)
local GameDataLogged = false
local function GetGameDataUncached()
    local All = LiveOf("PRGameData")
    local Best = nil
    local Seen = {}
    for _, GD in ipairs(All) do
        local Ok, N = pcall(function() return GD.CurrentLevelTag.TagName:ToString() end)
        table.insert(Seen, string.format("%s=%s", GD:GetFName():ToString(), Ok and tostring(N) or "?"))
        if not Best and Ok and type(N) == "string" and N ~= "None" and N ~= "" then Best = GD end
    end
    if not GameDataLogged and #All > 0 then
        GameDataLogged = true
        Log("native: PRGameData instance(s): %s", table.concat(Seen, ", "))
    end
    return Best or All[1]
end

local function GetGameData()
    return Cached("gd", GetGameDataUncached)
end

-- The game's current level tag as a string, or nil when it can't be read
local function LevelTagNow()
    local GD = GetGameData()
    if not GD then return nil end
    local Ok, N = pcall(function() return GD.CurrentLevelTag.TagName:ToString() end)
    if Ok and type(N) == "string" and N ~= "" then return N end
    return nil
end

-- TransferToLevel and GetIsInTransition are functions of the game mode's INTERFACES (IPRGameMode, IPRGameModeNative,
-- implemented in C++), not of its class, so GM:TransferToLevel finds nothing ("UObject instance is nullptr"). The interface
-- UFunction is called with the game mode as context: ProcessEvent -> UFunction::Invoke moves the context to the interface
-- address for functions whose outer is an interface.
local IfaceFns = {}
local function IfaceFn(Path)
    local F = IfaceFns[Path]
    if F and Valid(F) then return F end
    local Ok, O = pcall(StaticFindObject, Path)
    if Ok and Valid(O) then
        IfaceFns[Path] = O
        return O
    end
    return nil
end
local TransferFnPath = "/Script/IntoTheRadius.IPRGameMode:TransferToLevel"
local InTransitionFnPath = "/Script/IntoTheRadius.IPRGameModeNative:GetIsInTransition"

-- GM:TransferToLevel(LevelTag, LocationTag) through the interface function. Returns the game's bool, or nil + reason.
-- (A native error inside the call is not catchable by pcall; callers run it from a loop tick or the key handler.)
local function CallTransfer(GM, LevelTag, LocationTag)
    if not Valid(GM) then return nil, "no PRGameMode" end
    local Fn = IfaceFn(TransferFnPath)
    if not Fn then return nil, "interface function " .. TransferFnPath .. " not found" end
    local Ok, Res = pcall(function() return Fn(GM, TagStruct(LevelTag), TagStruct(LocationTag or "None")) end)
    if not Ok then return nil, "error " .. tostring(Res) end
    return Res == true, nil
end

local function InTransition(GM)
    GM = GM or GetGameMode()
    if not Valid(GM) then return false end
    local Fn = IfaceFn(InTransitionFnPath)
    if not Fn then return false end
    local Ok, Res = pcall(function() return Fn(GM) end)
    return Ok and Res == true
end

local function EndsWithI(S, Suffix)
    S, Suffix = S:lower(), Suffix:lower()
    return #S >= #Suffix and S:sub(-#Suffix) == Suffix
end

-- The streaming entry GetStreamingLevel would return for Sub (first package name ending in "/Sub"), or nil
local function FindNativeEntry(World, Sub)
    for _, S in ipairs(StreamingLevels(World)) do
        if EndsWithI(PkgName(S), "/" .. Sub) then return S end
    end
    return nil
end

local function NativeLogOnce(Key, fmt, ...)
    if NativeState.Logged[Key] then return end
    NativeState.Logged[Key] = true
    Log(fmt, ...)
end

local function TagsOfRows(Arr)
    local Out = {}
    pcall(function()
        Arr:ForEach(function(_, E) table.insert(Out, E:get().LevelTag.TagName:ToString()) end)
    end)
    return Out
end

-- (1) streaming entry for the current world
local function NativeEnsureEntry(World)
    local Sub, Map = NativeState.Sub, NativeState.Map
    local Have = FindNativeEntry(World, Sub)
    if Have then
        local Want = Map.Level:lower()
        local Pkg = PkgName(Have)
        local ToLoad = "?"
        pcall(function() ToLoad = Have.PackageNameToLoad:ToString() end)
        if ToLoad:lower() ~= Want and Pkg:lower() ~= Want then
            NativeLogOnce("foreign", "native: another streaming entry already answers to '%s' (%s, loads %s); native entry disabled", Sub, Pkg, ToLoad)
            NativeState.Failed = "foreign streaming entry " .. Pkg
            return false
        end
        NativeState.Entry = Have
        return true
    end
    local Source = nil
    for _, S in ipairs(StreamingLevels(World)) do
        if S:GetClass():GetFName():ToString() == "LevelStreamingDynamic" then Source = S; break end
    end
    if not Source then
        NativeLogOnce("nosource", "native: no LevelStreamingDynamic in this world yet; waiting")
        return false
    end
    local Ok, E = pcall(function() return Source:CreateInstance(Sub) end)
    if not Ok or not Valid(E) then
        Log("native: CreateInstance(%s) failed (%s); native entry disabled", Sub, tostring(E))
        NativeState.Failed = "CreateInstance failed"
        return false
    end
    E.PackageNameToLoad = FName(Map.Level)
    E.LevelTransform = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 },
                         Scale3D = { X = 1, Y = 1, Z = 1 } }
    local Pkg = PkgName(E)
    if not EndsWithI(Pkg, "/" .. Sub) or not SameObj(FindNativeEntry(World, Sub), E) then
        Log("native: the new streaming entry is '%s', which the game's lookup of '%s' would not find first; native entry disabled", Pkg, Sub)
        NativeState.Failed = "streaming entry name mismatch"
        return false
    end
    NativeState.Entry = E
    Log("native: streaming entry %s -> %s created (unloaded; the game's LevelManager loads it by the name %s)", Pkg, Map.Level, Sub)
    return true
end

-- (2) the level row. Returns true when the row is in place and the game accepts the tag.
local function NativeEnsureRow(SC)
    local Map, Tag, Sub = NativeState.Map, NativeState.Tag, NativeState.Sub
    local Arr = SC.LevelConfigurations
    local Ok0, Valid0 = pcall(function() return SC:IsLevelTagValid(TagStruct(Tag)) end)
    if Ok0 and Valid0 == true and not NativeState.RowFill then
        Log("native: %s is already a valid level tag (registered earlier this session)", Tag)
        return true
    end
    local Fill = NativeState.RowFill
    if not Fill then
        -- Values to copy, read BEFORE the array grows (growing can move the rows)
        local DonorTag = Opt(Map, "NativeDonorTag", "Level.Zone.Buffer")
        local D = nil
        local Before = TagsOfRows(Arr)
        local N = #Before
        if N == 0 then
            Log("native: SystemConfig.LevelConfigurations is empty or unreadable; waiting")
            return false
        end
        for I = 1, N do
            if Before[I] == DonorTag then
                pcall(function()
                    local R = Arr[I]
                    D = { StopGameTimeTick = R.StopGameTimeTick, InventoryAllowed = R.InventoryAllowed, SleepAllowed = R.SleepAllowed,
                          GenMin = R.AllowedGenerators.Min, GenMax = R.AllowedGenerators.Max, SaveOnExit = R.SaveOnExit,
                          Autosave = R.Autosave, SaveOnLoad = R.SaveOnLoad, MapScale = R.MapScale, FullPlayerStats = R.FullPlayerStats }
                end)
            end
        end
        if not D then
            Log("native: donor row %s not found; using built-in zone defaults", DonorTag)
            D = { StopGameTimeTick = false, InventoryAllowed = true, SleepAllowed = true, GenMin = 0, GenMax = 0, SaveOnExit = true,
                  Autosave = true, SaveOnLoad = true, MapScale = 1.0, FullPlayerStats = false }
        end
        local Empty = nil
        pcall(function() Empty = SC.EmptyMapMaterial end)
        local Saves = Opt(Map, "NativeSaves", false)
        Fill = { N = N, Before = Before, D = D, Empty = Empty, Saves = Saves, Grown = false }
        NativeState.RowFill = Fill
        Log("native: level table has %d rows; adding %s (main sublevel %s, flags from %s, saves %s)", N, Tag, Sub, DonorTag,
            Saves and "ON" or "off")
    else
        Log("native: resuming the row fill (the previous attempt was aborted by a native error)")
    end
    local Now1 = Arr:GetArrayNum()
    local Row
    if Now1 == Fill.N then
        Row = Arr[Fill.N + 1]                    -- grows the array by one zeroed row
        Fill.Grown = true
    elseif Now1 == Fill.N + 1 and Fill.Grown then
        Row = Arr[Fill.N + 1]                    -- resume: our zeroed / half-written row
    else
        Log("native: level table changed size unexpectedly (%d -> %d); not touching it; native entry disabled", Fill.N, Now1)
        NativeState.Failed = "level table size changed"
        return false
    end
    if Arr:GetArrayNum() ~= Fill.N + 1 then
        Log("native: could not grow the level table (%d rows); native entry disabled", Arr:GetArrayNum())
        NativeState.Failed = "TArray growth failed"
        return false
    end
    local D, Saves = Fill.D, Fill.Saves
    -- a zeroed FText has no text data; FText:SetString (UE4SS) builds a new one through the game's FText(FString&&) and
    -- overwrites the slot without reading the old one, so this is safe on the zeroed row
    Row.LevelName = FText(Map.DisplayName or Map.Name)
    Row.MainSublevel = FName(Sub)
    Row.StopGameTimeTick = D.StopGameTimeTick == true
    Row.ReloadOnTideHappening = Opt(Map, "NativeReloadOnTide", false) == true
    Row.InventoryAllowed = D.InventoryAllowed ~= false
    Row.SleepAllowed = Saves and (D.SleepAllowed == true) or false
    Row.AllowedGenerators = { Min = math.floor(tonumber(D.GenMin) or 0), Max = math.floor(tonumber(D.GenMax) or 0) }
    -- The game keeps only AllowedGenerators of the level's rifts and removes the rest in OnLevelPrepare ("Excluded from this cruel world"); the donor zone allows 3,
    -- so a map with 12 rifts would run 3. NativeGenerators = the number of rifts to keep (a form's "rifts", default 99).
    local WantGen = tonumber(Opt(Map, "NativeGenerators", nil))
    if WantGen and WantGen >= 0 then
        Row.AllowedGenerators = { Min = math.floor(WantGen), Max = math.floor(WantGen) }
    end
    Row.SaveOnExit = Saves and (D.SaveOnExit == true) or false
    Row.Autosave = Saves and (D.Autosave == true) or false
    Row.SaveOnLoad = Saves and (D.SaveOnLoad == true) or false
    if Valid(Fill.Empty) then
        Row.MapMaterial = Fill.Empty
        Row.MapLegendMaterial = Fill.Empty
    end
    Row.MapScale = tonumber(D.MapScale) or 1.0
    Row.MapRotation = 0.0
    Row.MaxLevelRadius = tonumber(Opt(Map, "NativeRadius", 250000)) or 250000
    Row.FullPlayerStats = D.FullPlayerStats == true
    Row.LevelTag = TagStruct(Tag)                -- last: until here the row answers to no tag
    NativeState.RowFill = nil
    -- checks: the earlier rows are untouched, ours reads back, and the game itself accepts the tag
    local After = TagsOfRows(SC.LevelConfigurations)
    local Damaged = 0
    for I = 1, Fill.N do
        if After[I] ~= Fill.Before[I] then Damaged = Damaged + 1 end
    end
    if Damaged > 0 then
        Log("native: !! %d earlier level row(s) changed while adding ours. The level table in memory is damaged: quit the game "
            .. "without saving and report this. Native entry disabled.", Damaged)
        NativeState.Failed = "level table damaged"
        return false
    end
    local Ok2, V2 = pcall(function() return SC:IsLevelTagValid(TagStruct(Tag)) end)
    if not (Ok2 and V2 == true) then
        Log("native: row added (%d rows) but SystemConfig:IsLevelTagValid(%s) = %s; native entry disabled", #After, Tag, tostring(V2))
        NativeState.Failed = "IsLevelTagValid false"
        return false
    end
    local Back = {}
    pcall(function()
        local R = SC.LevelConfigurations[Fill.N + 1]
        Back = { Main = R.MainSublevel:ToString(), Name = R.LevelName:ToString(), Radius = R.MaxLevelRadius, Auto = R.Autosave,
                 Time = R.StopGameTimeTick, Inv = R.InventoryAllowed }
    end)
    Log("native: level row %d added: %s, main sublevel %s, name '%s', radius %s cm, time stopped %s, inventory %s, autosave %s; "
        .. "IsLevelTagValid = true", Fill.N + 1, Tag, tostring(Back.Main), tostring(Back.Name), tostring(Back.Radius), tostring(Back.Time),
        tostring(Back.Inv), tostring(Back.Auto))
    return true
end

-- (3) map centre: MapPointsConfig.levelCenters[tag] (level <-> world transforms for the handheld map and map points)
local function NativeEnsureCenter()
    local Map, Tag = NativeState.Map, NativeState.Tag
    local MPC = nil
    pcall(function()
        local C = StaticFindObject("/Script/IntoTheRadius.Default__MapPointsConfig")
        if Valid(C) then MPC = C:GetMapPointsConfig() end
    end)
    if not Valid(MPC) then
        Log("native: MapPointsConfig not found; no map centre registered")
        return true
    end
    local M = MPC.levelCenters
    local Key = TagStruct(Tag)
    local C = Opt(Map, "NativeCenter", { X = 0, Y = 0, Z = 0 })
    local Want = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = C.X or 0, Y = C.Y or 0, Z = C.Z or 0 },
                   Scale3D = { X = 1, Y = 1, Z = 1 } }
    if TMapFind(M, Key) == nil then
        local Ok, Err = pcall(function() M:Add(Key, Want) end)
        if not Ok then Log("native: levelCenters:Add failed: %s", tostring(Err)) end
    end
    local Back = TMapFind(M, Key)
    if Back == nil then
        Log("native: map centre for %s not registered (levelCenters has no entry)", Tag)
        return true
    end
    -- c62ada0's TMap:Add stored zeroed values for the loot tags: write the fields into the stored struct in place
    pcall(function()
        Back.Rotation = Want.Rotation
        Back.Translation = Want.Translation
        Back.Scale3D = Want.Scale3D
    end)
    local T = { X = 0, Y = 0, Z = 0 }
    local W = -1
    pcall(function() T = Vec(Back.Translation); W = Back.Rotation.W end)
    Log("native: map centre for %s = %s (rotation W %s, %d level centres)", Tag, FmtV(T), tostring(W), TMapCount(M))
    return true
end

-- One registration tick (game thread). Returns nothing; NativeState tells the story.
local function NativeRegisterTick()
    local Map = NativeState.Map
    if not Map or NativeState.Failed then return end
    local World = UEHelpers.GetWorld()
    if not Valid(World) then return end
    local WA = World:GetAddress()
    if NativeState.WorldAddr ~= WA then          -- new world (first time, or after a full map change): entry again
        NativeState.WorldAddr = WA
        NativeState.Entry = nil
        NativeState.Ready = false
    end
    if NativeState.Ready then
        if not Valid(NativeState.Entry) then NativeState.Ready = false end
        return
    end
    -- the level manager must be idle (no level load holding a pointer into the level table while it grows)
    local LM = GetLevelManager()
    if not LM then return end
    if Config.RequireLevelManagerReady ~= false and not LM:IsReady() then
        NativeState.Checks = 0
        return
    end
    NativeState.Checks = NativeState.Checks + 1
    if NativeState.Checks < 2 then return end
    local SC = GetSystemConfig()
    if not SC then return end
    if not Valid(NativeState.Entry) and not NativeEnsureEntry(World) then return end
    if not NativeState.RowDone then
        if not NativeEnsureRow(SC) then return end
        NativeState.RowDone = true
    end
    if not NativeState.CenterDone then
        NativeState.CenterDone = true            -- one attempt; a failure is logged and does not block entry
        NativeEnsureCenter()
    end
    if not NativeState.LootDone then
        NativeState.LootDone = true
        local Manifest, Path = LoadLootManifest(Map)
        if Manifest then
            LootCtxOf(Map).Native = true
            local Ok, Err = pcall(RegisterLootTags, Map, Manifest)
            Log("native: loot manifest %s registered at startup: %s", Path, Ok and "ok" or ("error " .. tostring(Err)))
        else
            Log("native: no loot manifest (tried %s); the map's loot tags are not registered", Path)
        end
    end
    NativeState.Ready = true
    Log("native: READY: %s is a game level (%s). Entering uses the game's TransferToLevel; the streaming loader is not used.",
        Map.Name, NativeState.Tag)
    -- Probe (once): is the map's level tag in the gameplay tag tree? A save keeps the tag only when it is
    -- (see "Saving" in the loader README: the tags pak).
    local OkT, Reg = pcall(function()
        local Lib = StaticFindObject("/Script/GameplayTags.Default__BlueprintGameplayTagLibrary")
        return Lib:MatchesTag(TagStruct(NativeState.Tag), TagStruct("Level.Zone"), false)
    end)
    local Registered = OkT and Reg == true
    Log("tags: %s is %s in the gameplay tag tree%s", NativeState.Tag, Registered and "REGISTERED" or "NOT registered",
        Registered and " (a save made in the map keeps its level)"
                   or (Opt(Map, "NativeSaves", false) and ": NativeSaves is on, so a save made in the map will load into the Hub; install the tags pak (see Saving in the README)"
                                                       or " (fine while NativeSaves is false)"))
end

-- Arrival transform for the save slot the game reads first (PlayerGameData position for the level)
local function NativeStartTransform(Map, Override)
    local S = Override or Opt(Map, "NativeStart", nil)
    if type(S) ~= "table" then return nil end
    local Yaw = math.rad(tonumber(S.Yaw) or 0) / 2
    return { Rotation = { X = 0, Y = 0, Z = math.sin(Yaw), W = math.cos(Yaw) },
             Translation = { X = S.X or 0, Y = S.Y or 0, Z = S.Z or 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
end

local function NativeSavePosition(Map, Override)
    local T = NativeStartTransform(Map, Override)
    if not T then return false end
    local GD = GetGameData()
    if not GD then return false end
    local Ok = pcall(function() GD.PlayerData:SavePosition(TagStruct(NativeState.Tag), T, { X = 0, Y = 0, Z = 0 }) end)
    return Ok
end

local TryArrive = nil        -- defined in the level-event block below (it needs the trigger hook)

-- RULE: never change level from an action. TransferToLevel fires the transition start synchronously, and stock components clear their
-- references in it. A UE4SS action runs inside whatever ProcessEvent the game happens to be in, so a transfer from one can pull those
-- references out from under native code in mid-function (an NPC's sight update found a null Player: access violation).
-- So a transfer asked for from Lua runs at the end of the frame, through the engine's DEFER console command, outside any ProcessEvent.
local Later = nil
local function RunLater(Fn)
    if Later then Log("end of frame call: one is already waiting"); return false end
    Later = Fn
    Log("end of frame call: asked (itrmapdo)")
    local Ok, E = pcall(function()
        StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):ExecuteConsoleCommand(UEHelpers.GetWorld(), "defer itrmapdo", nil)
    end)
    if not Ok then Later = nil; Log("end of frame call failed: %s", tostring(E)); return false end
    return true
end
if type(RegisterConsoleCommandHandler) == "function" then
    pcall(RegisterConsoleCommandHandler, "itrmapdo", function()
        local Fn = Later
        Later = nil
        if Fn then
            Log("end of frame call: itrmapdo heard")
            local Ok, E = pcall(Fn)
            if not Ok then Log("end of frame call error: %s", tostring(E)) end
        end
        return true
    end)
end

-- Enter the map through the game's level transfer. Returns true when the transfer was asked for (it runs at frame end). The arrival is finished by
-- TryArrive, from the game's level events (OnLevelStarted / OnTransitionEnd).
local function NativeEnter(Map, Why)
    if NativeTrip and Now() - NativeTrip.T0 > 200000 then NativeTrip = nil end       -- a stale record never blocks for good
    if NativeTrip then
        Log("native: %s ignored: a transfer is already running", Why)
        return false
    end
    NativeSelect(Map)
    if not NativeState.Ready then
        Log("native: %s: not registered (%s)", Why, NativeState.Failed or "registration not finished")
        return false
    end
    local GM = GetGameMode()
    if not GM then
        Log("native: %s: no PRGameMode yet", Why)
        return false
    end
    if not Valid(UEHelpers.GetPlayer()) then
        Log("native: %s: no player pawn yet", Why)
        return false
    end
    if not IfaceFn(TransferFnPath) then
        Log("native: %s: %s not found", Why, TransferFnPath)
        return false
    end
    local Tag = NativeState.Tag
    local Return = Maps and Maps.ReturnStart(Map) or nil
    local Saved = NativeSavePosition(Map, Return)
    if not Saved and Map.FromForm then
        Log("map %s: no start in the form: the game picks the arrival, then the loader moves the player to the level's start marker", Map.Name)
    end
    Log("native: %s: calling TransferToLevel(%s) on %s (arrival position %s)", Why, Tag, GM:GetFName():ToString(),
        Return and "the return point" or (Saved and "saved for the level" or "from the game"))
    -- the transfer itself runs at the end of the frame (see RunLater)
    return RunLater(function()
        if NativeTrip then Log("native: %s ignored: a transfer is already running", Why); return end
        local Res, Err = CallTransfer(GM, Tag, "None")
        Log("native: %s: TransferToLevel(%s) -> %s", Why, Tag, Err or tostring(Res))
        if Res ~= true then return end
        local Trip = { Map = Map, T0 = Now(), Phase = "transfer", Return = Return }
        NativeTrip = Trip
        -- No retry timer: the arrival is finished from the level events (OnLevelSettled), each of which logs "level not ready yet" when it cannot yet.
    end)
end

-- An exit to a spot in a stock level: the position for that level, written again from the level hooks because the game's position save overwrites it.
local function SaveExitSpot()
    local C = Current
    if not (C and C.ExitSpot) then return end
    local T = NativeStartTransform(C.Map, C.ExitSpot)
    local GD = GetGameData()
    if T and GD then pcall(function() GD.PlayerData:SavePosition(TagStruct(C.ExitTag), T, { X = 0, Y = 0, Z = 0 }) end) end
end

-- Leave the map through the game's level transfer: to To (a level tag), else to HubLevelTag. Arriving is noticed by TryBack, from the level events.
local function NativeExit(Why, To, At)
    local GM = GetGameMode()
    local Tag = To or HubLevelTag
    local Gate = type(At) == "string" and At or (not To and Config.NativeExitLocation) or "None"
    Current.ExitTag, Current.ExitSpot = Tag, type(At) == "table" and At or nil
    SaveExitSpot()
    local Res, Err = CallTransfer(GM, Tag, Gate)
    Log("native exit (%s): TransferToLevel(%s, %s) -> %s", Why, Tag, Gate, Err or tostring(Res))
    if Res ~= true then
        Current.Phase, Current.ExitTag, Current.ExitSpot = "active", nil, nil
    end
end

-- Pickup trigger (config NativeTriggerMesh = the name of a Hub item's static mesh): grabbing a Hub prop with that mesh starts the
-- transfer. Hub props such as cups, books and tins are BP_PhysicsActor_C actors whose Mesh property names the static mesh.
-- The hook only reacts to the mesh named in a map's config entry. It is one RegisterHook on BP_PhysicsActor_C:OnGrip, and only the first mod to register a
-- callback on a script function gets it called, so another mod hooking the same function can silence this one (or be silenced).
-- BP_PhysicsActor_C implements the VRExpansion grip event OnGrip(GrippingController, GripInformation) as a Blueprint
-- function, which the grip controller calls when a hand takes the item, so UE4SS can hook it like any script function.
local TriggerHooked = false
local TriggerLastMs = -1e9
local function NativeTriggerGrab(Context)
    local Ok, MeshName = pcall(function()
        local A = Context:get()
        if not Valid(A) then return nil end
        local M = A.Mesh
        if not Valid(M) then return nil end
        return M:GetFName():ToString()
    end)
    if not Ok or not MeshName then return end
    local Map = nil
    for _, N in ipairs(NativeList) do
        if Opt(N.Map, "NativeTriggerMesh", nil) == MeshName then Map = N.Map; NativeState = N; break end
    end
    if not Map then return end
    local Want = MeshName
    local T = Now()
    if T - TriggerLastMs < 10000 then return end            -- debounce: one transfer per grab, 10 s apart
    TriggerLastMs = T
    -- start the transfer on the next game-thread tick, outside the grip call
    ExecuteInGameThread(function()
        if not NativeState.Ready then Log("native trigger: %s grabbed, but the level is not registered (%s)", Want, NativeState.Failed or "not finished"); return end
        if Current or NativeTrip then Log("native trigger: %s grabbed, but a map is already active / a transfer is running", Want); return end
        local World = UEHelpers.GetWorld()
        local Lvl = LevelTagNow()
        if not (Valid(World) and IsHubVisible(World)) or (Lvl ~= nil and Lvl ~= HubLevelTag) then
            Log("native trigger: %s grabbed outside the Hub (level %s); ignored", Want, tostring(Lvl))
            return
        end
        if InTransition() then Log("native trigger: %s grabbed during a transition; ignored", Want); return end
        Log("native trigger: %s grabbed in the Hub", Want)
        NativeEnter(Map, "pickup of " .. Want)
    end)
end

local function NativeHookTrigger()
    if TriggerHooked then return end
    local Map = nil
    for _, N in ipairs(NativeList) do
        if N.Ready and Opt(N.Map, "NativeTriggerMesh", nil) then Map = N.Map; NativeState = N; break end
    end
    if not Map then
        local Any = false
        for _, N in ipairs(NativeList) do if Opt(N.Map, "NativeTriggerMesh", nil) then Any = true end end
        if not Any then TriggerHooked = true end          -- no map asks for an item trigger: the hook is never made
        return
    end
    local Path = Opt(Map, "NativeTriggerFunction", "/Game/ITR/BPs/Items/BP_PhysicsActor.BP_PhysicsActor_C:OnGrip")
    local Ok, F = pcall(StaticFindObject, Path)
    if not Ok or not Valid(F) then
        NativeLogOnce("trigwait", "native trigger: waiting for %s to load", Path)
        return
    end
    TriggerHooked = true
    local OkH, Err = pcall(RegisterHook, Path, function(Context)
        local OkT, E = pcall(NativeTriggerGrab, Context)
        if not OkT then LogOnce("trigerr", "native trigger: error %s", tostring(E)) end
    end)
    Log("native trigger: hook on %s (grab an item with mesh %s in the Hub to enter %s): %s", Path,
        tostring(Opt(Map, "NativeTriggerMesh", nil)), Map.Name, OkH and "registered" or ("FAILED " .. tostring(Err)))
end

---------------------------------------------------------------------------------------------------------------------
-- Level events (replace the timed watches). The game mode announces level changes with Blueprint events; they are hooked once, one tick
-- after the first PRGameMode object exists (a Blueprint function cannot be hooked at mod start: UFunction::Func is still 0x0 and the
-- error ends the whole mod). Script hooks run only the first callback given to RegisterHook.
---------------------------------------------------------------------------------------------------------------------
local GM_CLASS = "/Game/ITR/BPs/Game/BP_PRGameMode.BP_PRGameMode_C"
local function LevelReady()   -- level manager idle, not in transition
    local LM = GetLevelManager()
    return LM ~= nil and (Config.RequireLevelManagerReady == false or LM:IsReady()) and not InTransition()
end
local function ResavePosition()
    if NativeTrip then NativeSelect(NativeTrip.Map); NativeSavePosition(NativeTrip.Map, NativeTrip.Return)
    else SaveExitSpot() end
end

-- Arrival: the level is the map's, visible, and the level manager is idle. Returns true when done or not applicable.
TryArrive = function()
    local Trip = NativeTrip
    if not Trip then return true end
    if not LevelReady() then return false end
    local Map = Trip.Map
    NativeSelect(Map)
    local LevelNow = LevelTagNow()
    if LevelNow ~= nil and LevelNow ~= NativeState.Tag then
        if Now() - Trip.T0 > 120000 then
            Log("native: the transfer ended in %s, not %s", LevelNow, NativeState.Tag)
            NativeTrip = nil
            return true
        end
        return false
    end
    local World = UEHelpers.GetWorld()
    local Stream = Valid(World) and FindNativeEntry(World, NativeState.Sub) or nil
    if not (Stream and CallBool(Stream, "IsLevelVisible")) then return false end
    local Ms = Now() - Trip.T0
    local L = PawnLoc()
    local M = ScanMarkers(Map, Stream)
    local Want = ChooseArrival(Map, M)
    local R = Trip.Return
    if R then
        Want = { Loc = { X = R.X, Y = R.Y, Z = R.Z }, Rot = { Pitch = 0, Yaw = R.Yaw, Roll = 0 } }       -- the return point, not the start marker
    elseif Map.FromForm and Map.NativeStart then
        local S = Map.NativeStart                                                                         -- the form's start, not a marker 30 m away
        Want = { Loc = { X = S.X, Y = S.Y, Z = S.Z }, Rot = { Pitch = 0, Yaw = S.Yaw or 0, Roll = 0 } }
    end
    Log("native: arrived after %.1f s: level %s, player at %s, %d TargetPoint(s), start marker %s",
        Ms / 1000, tostring(LevelNow), L and FmtV(L) or "?", #M.All, M.Start and "found" or "MISSING")
    if Want and L and Dist3D(L, Want.Loc) > Opt(Map, "NativeArriveTolerance", 3000) then
        Log("native: the game placed the player %.0f m from the arrival marker; moving them there", Dist3D(L, Want.Loc) / 100)
        TeleportPlayer(Want.Loc, Want.Rot, "arrival marker")
    end
    Current = { Map = Map, Stream = Stream, Return = nil, Phase = "active", Exits = {}, Native = true }
    ArmExits(M)
    NativeTrip = nil
    if Maps and Map.FromForm then Maps.OnArrived(Map) end
    return true
end

-- After a native exit: at the destination and the level manager idle. Ending anywhere else is noted, so nothing stays "exiting" for good.
local function TryBack()
    if not (Current and Current.Native and Current.Phase == "exiting") then return end
    local Want = Current.ExitTag or HubLevelTag
    local LevelNow, World = LevelTagNow(), UEHelpers.GetWorld()
    local Back = LevelNow == Want or (Want == HubLevelTag and LevelNow == nil and Valid(World) and IsHubVisible(World))
    if not LevelReady() then return end
    if Back then
        Log("native exit: back in %s", Want)
        Current = nil
    elseif LevelNow and LevelNow ~= NativeTagOf(Current.Map) then
        Log("native exit: ended in %s, not %s", LevelNow, Want)
        Current = nil
    end
end

-- The game moved the player out of the map another way (death, fog, gate)
local function NoteLeft()
    if Current and Current.Native and Current.Phase == "active" and not NativeTrip then
        NativeSelect(Current.Map)
        local LevelNow = LevelTagNow()
        if LevelNow and LevelNow ~= NativeState.Tag and not InTransition() then
            Log("native: the game left the map another way (level now %s); exits disarmed", LevelNow)
            Current = nil
        end
    end
end

-- One pass of what the old 1 s tick did: registration (waits for an idle level manager), the Hub item hook, the failed-registration guard
local function NativeAttempt()
    if Maps then Maps.CheckInstalled() end
    for _, N in ipairs(NativeList) do
        NativeState = N
        if N.Map.Missing and not N.Failed then N.Failed = "level not installed" end
        if N.Map.Missing then
            -- a map whose level is not installed is not registered and not listed (Maps logged it once). A save made in the level must still not strand the player.
            local GD = GetGameData()
            if GD and LevelTagNow() == N.Tag then
                local Ok = pcall(function() GD.CurrentLevelTag = TagStruct(HubLevelTag) end)
                Log("native: the loaded save is in %s, whose level is not installed: moved to %s: %s", N.Tag, HubLevelTag, Ok and "done" or "FAILED")
            end
        else
            NativeRegisterTick()
            if NativeState.Ready and not TriggerHooked then NativeHookTrigger() end
            if NativeState.Failed then
                NativeLogOnce("failed", "native: registration FAILED (%s); %s", NativeState.Failed,
                    Opt(NativeState.Map, "NativeFallback", false) and "entry falls back to the streaming loader" or "map entry is off this session")
                -- startup guard: a save made in the level must not strand the player when the level cannot be registered
                local GD = GetGameData()
                if GD and LevelTagNow() == NativeState.Tag then
                    local Ok = pcall(function() GD.CurrentLevelTag = TagStruct(HubLevelTag) end)
                    Log("native: the loaded save is in %s, which is not registered: moved to %s: %s", NativeState.Tag, HubLevelTag, Ok and "done" or "FAILED")
                end
            end
        end
    end
end

-- A save made in a map (NativeSaves on) loads the map's level through the game's own Continue: no transfer was started here, so this adopts it as
-- the Showcase loader does: exits armed (for a form map: its exit triggers bound), a guard against a bad saved position. Called from the level events.
-- Run once, inline, from the level event that adopts the save (no timer: a position that is only bad later is not caught).
local function NativeGuardPosition(Map, S)
    if not (Current and Current.Map == Map) then return end
    local L = PawnLoc()
    if not L then Log("native: the saved position could not be read at the adoption: not checked"); return end
    local C = Opt(Map, "NativeCenter", { X = 0, Y = 0, Z = 0 })
    local Far = (not Map.FromForm) and Dist2D(L, { X = C.X or 0, Y = C.Y or 0 }) > Opt(Map, "NativeRadius", 250000)   -- a form map is not moved for being far
    local Falling = OnMapGround(S) ~= true and L.Z < -50000
    if Far or Falling then
        local M = Valid(S) and ScanMarkers(Map, S) or nil
        local Want = M and ChooseArrival(Map, M) or nil
        Log("native: saved position %s is %s; moving the player to the arrival marker", FmtV(L), Far and "outside the map" or "falling")
        if Want then TeleportPlayer(Want.Loc, Want.Rot, "arrival marker (bad saved position)") end
    end
end
local function NativeAdopt()
    if Current or NativeTrip then return end
    for _, N in ipairs(NativeList) do
        if N.Ready then
            local World = UEHelpers.GetWorld()
            local S = Valid(World) and FindNativeEntry(World, N.Sub) or nil
            if S and CallBool(S, "IsLevelVisible") then
                NativeState = N
                if LevelTagNow() == N.Tag and not InTransition() then
                    local Map = N.Map
                    local M = ScanMarkers(Map, S)
                    local L = PawnLoc()
                    Log("native: the game loaded %s itself (a save made in the map); player at %s, %d TargetPoint(s); exits armed", N.Tag, L and FmtV(L) or "?", #M.All)
                    Current = { Map = Map, Stream = S, Return = nil, Phase = "active", Exits = {}, Native = true }
                    ArmExits(M)
                    NativeGuardPosition(Map, S)
                    if Maps and Map.FromForm then Maps.OnArrived(Map) end
                    return
                end
            end
        end
    end
end

local function OnLevelSettled(What)
    ExecuteInGameThread(function()
        NativeAttempt()
        TryBack()
        NoteLeft()
        if NativeTrip and not TryArrive() then Log("native: %s: level not ready yet", What) end
        NativeAdopt()
    end)
end

-- Registration of every native map, asked once by BP_ITRMapManager at the first level change after the game started ("itrmaps register"). The two-checks-in-a-row gate is
-- skipped: nothing polls. A map the level manager was too busy for is logged as waiting.
NativeRegisterNow = function()
    for _, N in ipairs(NativeList) do N.Checks = 1 end
    NativeAttempt()
    local Ready, Failed = 0, 0
    for _, N in ipairs(NativeList) do
        if N.Ready then Ready = Ready + 1 elseif N.Failed then Failed = Failed + 1 end
    end
    Log("registration (asked at the first level change): %d ready, %d failed, %d waiting", Ready, Failed, #NativeList - Ready - Failed)
end

local LevelHooksAsked = false
-- Runs as ONE game-thread action. Never call ExecuteInGameThread in here, or in anything it calls synchronously: appending to UE4SS's
-- queue from inside an action can reallocate it under the running pass (c62ada0) and crash the game. A failing RegisterHook ends the
-- rest of this action: the log shows how far it got.
local function AttachLevelHooks()
    local function H(Fn, Cb)
        RegisterHook(GM_CLASS .. ":" .. Fn, Cb)
        Log("level hook %s attached", Fn)
    end
    -- the requests to ITRLevelAddons go out inline from inside the hook (a console command, nothing queued): a send from a level event is heard
    local function Send(What) if Maps then local Ok, E = pcall(Maps.OnLevelEvent, What); if not Ok then LogOnce("sendr" .. What, "level event %s: %s", What, tostring(E)) end end end
    H("DoSavePlayerPosition", function() ResavePosition() end)
    H("OnTransitionStart",    function() if Maps then Maps.ForgetBinds() end; ResavePosition() end)
    H("OnLevelPrepare",       function() Send("OnLevelPrepare"); ResavePosition(); ExecuteInGameThread(NoteLeft) end)
    H("OnLevelStarted",       function() Send("OnLevelStarted"); OnLevelSettled("OnLevelStarted") end)
    H("OnTransitionEnd",      function() Send("OnTransitionEnd"); OnLevelSettled("OnTransitionEnd") end)
    H("OnEnteredMenu",        function()
        Send("OnEnteredMenu")
        NativeTrip = nil
        if Current and Current.Native then Current = nil end
        OnLevelSettled("OnEnteredMenu")
    end)
    NativeAttempt()
end

-- Registration and the level hooks. One record per native map: the config maps and the form maps the loader enters itself. The hooks are attached
-- whenever there is a record or a form with trigger levels (a form that only hands back to another mod still needs the level events for its triggers).
local function NativeStartup(FormMaps)
    for _, M in ipairs(Config.Maps) do
        if Opt(M, "Native", true) then NativeNew(M) end
    end
    for _, M in ipairs(FormMaps or {}) do NativeNew(M) end
    for _, N in ipairs(NativeList) do
        N.Tag, N.Sub = NativeTagOf(N.Map), NativeSubOf(N.Map)
        Log("native: registering %s as %s (main sublevel %s) once the game is idle", N.Map.Name, N.Tag, N.Sub)
    end
    local NeedHooks = #Config.Maps > 0          -- the form path has no hook: its Blueprints listen to the game's level events themselves
    if not NeedHooks then return end
    -- Only the Blueprint game mode (BP_PRGameMode_C) counts: a notification for the native class or a default object can arrive before the
    -- Blueprint class is bound, and hooking its functions then crashes the game (seen 1 s after start).
    NotifyOnNewObject("/Script/IntoTheRadius.PRGameMode", function(Obj)
        if LevelHooksAsked then return end
        local Ok, Cls = pcall(function() return Obj:GetClass():GetFName():ToString() end)
        local Okn, Nm = pcall(function() return Obj:GetFName():ToString() end)
        if not (Ok and Cls == "BP_PRGameMode_C") or (Okn and Nm:sub(1, 9) == "Default__") then return end
        LevelHooksAsked = true
        Log("native: first game mode object %s: attaching the level hooks", Okn and Nm or "?")
        ExecuteInGameThread(AttachLevelHooks)
    end)
end

---------------------------------------------------------------------------------------------------------------------
-- Leaving
---------------------------------------------------------------------------------------------------------------------
local function FinishUnload()
    if Current then pcall(RepointOwnTables, Current.Map, true) end   -- the map's tables go with the level
    local World = UEHelpers.GetWorld()
    if Current and Valid(Current.Stream) then
        Current.Stream:SetShouldBeVisible(false)
        Current.Stream:SetShouldBeLoaded(false)
        Log("unloaded %s", Current.Map.Name)
    end
    if Valid(World) then SetLightingScenariosHidden(World, false) end
    Current = nil
end

-- Player must stand off the map before it goes away. Return = where they stood in the Hub (may be nil).
-- With a Return position: off the map = within 6 m of it for 2 ticks (the Hub is far from the map). Without one: the
-- movement base decides when it can tell, else there is nothing to wait for.
local function ConfirmOffMapThenUnload(Return)
    local T0w = Now()
    local Waited, Near = 0, 0
    local Stream = Current.Stream
    Every(250, function()
        if not Current then return true end
        Waited = math.floor(Now() - T0w)
        local Off, How
        if Return then
            local L = PawnLoc()
            if L and Dist2D(L, Return) < 600 then Near = Near + 1 else Near = 0 end
            Off, How = Near >= 2, "position"
        else
            local Ground = OnMapGround(Stream)
            Off, How = (Ground ~= true), (Ground ~= nil and "movement base" or "nothing to compare with")
        end
        if Off then
            Log("exit: player is off the map (%s); unloading it", How)
            FinishUnload()
            return true
        end
        if Waited >= 10000 then
            Log("exit: the player is still on %s after the Hub load and the teleport back; map kept (never unloaded from under "
                .. "the player). Use the exit again.", Current.Map.Name)
            Current.Phase = "active"
            return true
        end
        return false
    end)
end

-- Hub levels the game did not bring back: restore the ones no level configuration lists (nobody else will)
local function RestoreHubLevels()
    local Levels = Current and Current.HubLevels or {}
    if #Levels == 0 then return end
    local Managed = ManagedSublevels()
    local Back, NotBack, Restored = 0, 0, 0
    for _, H in ipairs(Levels) do
        if not H.Kept and Valid(H.S) then
            local Back1 = CallBool(H.S, "IsLevelLoaded") or PropBool(H.S, "bShouldBeLoaded")
                or not (H.WasLoaded or H.WasShouldLoad)
            if Back1 then
                Back = Back + 1
            else
                NotBack = NotBack + 1
                -- Managed unknown: restore only a lighting-scenario level, the one level the configs are least likely to list
                local Restore
                if Managed then Restore = not Managed[H.Name] else Restore = H.Scenario end
                Log("exit: %s NOT brought back by the game (%s)%s", H.Name, StreamBitsText(H.S),
                    Restore and "  -> restored by the loader" or "  -> left to the game")
                if Restore then
                    H.S:SetShouldBeLoaded(true)
                    H.S:SetShouldBeVisible(H.WasVisible or H.WasShouldVisible)
                    Restored = Restored + 1
                end
            end
        end
    end
    Log("exit: %d Hub level(s) back via the game, %d not (%d restored by the loader)", Back, NotBack, Restored)
end

local function HubExitFinish(Start, Return)
    local L = PawnLoc()
    local Moved = (L and Start) and Dist3D(L, Start) or 0
    local MapLoaded = Valid(Current.Stream) and StreamActive(Current.Stream)
    Log("exit: Hub ready; the native Hub load left the map loaded: %s; player at %s, moved %.0f m since the exit began (%s)",
        tostring(MapLoaded), L and FmtV(L) or "?", Moved / 100, Moved > 5000 and "the game placed them" or "the game did not move them")
    -- The game brings the Hub's sublevels back one after the other after the main Hub level turned visible (the first run judged
    -- them at that moment and called 8 of 11 "not brought back", though all 9 were back a few seconds later): wait up to 20 s
    -- for the ones it had loaded before, then judge.
    local T0w = Now()
    local Ctx = { Judged = false }
    local function Finish()
        if Ctx.Judged then return end
        Ctx.Judged = true
        RestoreHubLevels()
        if Moved <= 5000 and Return then
            Log("exit: teleporting the player back to their Hub position %s", FmtV(Return.Loc))
            TeleportPlayer(Return.Loc, Return.Rot, "saved Hub position")
            ConfirmOffMapThenUnload(Return.Loc)
        else
            ConfirmOffMapThenUnload(nil)
        end
    end
    Every(500, function()
        if not Current then return true end
        local Missing = 0
        for _, H in ipairs(Current.HubLevels or {}) do
            if not H.Kept and Valid(H.S) and (H.WasLoaded or H.WasShouldLoad)
                and not (CallBool(H.S, "IsLevelLoaded") or PropBool(H.S, "bShouldBeLoaded")) then
                Missing = Missing + 1
            end
        end
        if Missing > 0 and Now() - T0w < 20000 then return false end
        Finish()
        return true
    end)
end

-- Exit with the Hub torn down: the game's Hub load while the player still stands on the map, then unload the map
-- only if it is still loaded and the player isn't on it.
local function HubExit()
    local Start = PawnLoc()
    local Return = Current.Return
    for _, H in ipairs(Current.HubLevels or {}) do H.Gone = nil end
    Log("exit: Hub teardown is active; asking the game to load %s while the player stands on the map", HubLevelTag)
    local St = { LoadTried = false, Called = false, Transferred = false }
    local T0w = Now()
    local Elapsed, Activity = 0, false
    local Transferred = false
    Every(250, function()
        if not Current or Current.Phase ~= "exiting" then return true end
        Elapsed = math.floor(Now() - T0w)
        -- The calls are made from inside the loop, one per tick, so a native error in LoadLevel (not catchable by pcall)
        -- leaves the loop alive and the next tick falls back to TransferToLevel.
        if not St.LoadTried then
            St.LoadTried = true
            St.Called = CallLoadLevelHub()
            if not St.Called then
                St.Transferred = true
                if not CallTransferHub() then
                    Log("exit FAILED: neither LoadLevel nor TransferToLevel could be called; the map stays loaded")
                    Current.Phase = "active"
                    return true
                end
            end
            return false
        end
        if not St.Called and not St.Transferred then
            Log("exit: LoadLevel did not return (native error); falling back to TransferToLevel")
            St.Transferred = true
            CallTransferHub()
            return false
        end
        Transferred = St.Transferred
        local World = UEHelpers.GetWorld()
        if not Valid(World) then return false end
        local LM = GetLevelManager()
        if LM and not LM:IsReady() then Activity = true end
        for _, H in ipairs(Current.HubLevels or {}) do
            if not H.Kept and Valid(H.S) and StreamActive(H.S) then Activity = true end
        end
        if Activity and IsHubVisible(World) then
            Log("exit +%d ms: Hub visible and the level manager ready", Elapsed)
            HubExitFinish(Start, Return)
            return true
        end
        if not Activity and not Transferred and Elapsed > 4000 then
            Log("exit +%d ms: LoadLevel(%s) did nothing (the game probably believes it is still in the Hub); "
                .. "falling back to TransferToLevel", Elapsed, HubLevelTag)
            Transferred = true
            St.Transferred = true
            CallTransferHub()
        end
        if Elapsed > 120000 then
            Log("exit FAILED: the Hub was not ready after %d ms (activity %s); map kept", Elapsed, tostring(Activity))
            Current.Phase = "active"
            return true
        end
        return false
    end)
end

-- Exit with the Hub still loaded: back to where the player stood, then unload
local function SimpleExit()
    local Return = Current.Return
    if Return then
        TeleportPlayer(Return.Loc, Return.Rot, "saved Hub position")
        Log("returned to the Hub")
        ConfirmOffMapThenUnload(Return.Loc)
    else
        FinishUnload()
    end
end

local function StartExit(Why, To, At)
    if not Current or Current.Phase ~= "active" then
        Log("%s ignored: the map is %s", Why, Current and Current.Phase or "not loaded")
        return
    end
    Log("leaving %s (%s)", Current.Map.Name, Why)
    Current.Phase = "exiting"
    if Current.Native then
        if not RunLater(function()
            if Current and Current.Native and Current.Phase == "exiting" then NativeExit(Why, To, At) end
        end) then Current.Phase = "active" end
    elseif Current.TornDown then HubExit() else SimpleExit() end
end

---------------------------------------------------------------------------------------------------------------------
-- Loading
---------------------------------------------------------------------------------------------------------------------
local function OnVisible(Map)
    local Stream = Current.Stream
    local M = ScanMarkers(Map, Stream)
    Log("%s visible: %d TargetPoint(s), start marker %s, %d arrive marker(s)", Map.Level, #M.All,
        M.Start and "found" or "MISSING", (function() local N = 0; for _ in pairs(M.Arrive) do N = N + 1 end; return N end)())
    if Opt(Map, "HubTeardown", true) then
        Teardown(Map, M)
    else
        if Map.HideLightingScenario then SetLightingScenariosHidden(UEHelpers.GetWorld(), true) end
        Arrive(Map, M, ChooseArrival(Map, M))
    end
end

local function Load(Map)
    if Current then return end
    local World = UEHelpers.GetWorld()
    if not Valid(World) then Log("no world yet"); return end
    if not IsHubVisible(World) then
        -- From the main menu the teleport reports success but the VR player doesn't move.
        Log("load maps from the Hub")
        return
    end
    -- LevelStreamingDynamic::LoadLevelInstance can't be called from UE4SS 3.0.1 Lua: after its bool out-parameter the
    -- next argument is read from the wrong stack slot. So do what LoadLevelInstance does inside: make a new streaming
    -- entry with LevelStreaming::CreateInstance (copies an existing dynamic entry under a unique name and adds it to the
    -- world), point it at our package with PackageNameToLoad, place it at the origin, and load it.
    local Source = nil
    for _, S in ipairs(StreamingLevels(World)) do
        if S:GetClass():GetFName():ToString() == "LevelStreamingDynamic" then Source = S; break end
    end
    if not Source then Log("no dynamic streaming level to copy"); return end
    InstanceCount = InstanceCount + 1
    local Stream = Source:CreateInstance(string.format("ITRMap_%s_%d", Map.Name, InstanceCount))
    if not Valid(Stream) then
        Log("CreateInstance failed")
        return
    end
    Stream.PackageNameToLoad = FName(Map.Level)
    Stream.LevelTransform = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 },
                              Scale3D = { X = 1, Y = 1, Z = 1 } }
    Stream:SetShouldBeLoaded(true)
    Stream:SetShouldBeVisible(true)
    local Pawn = UEHelpers.GetPlayer()
    local Return = nil
    if Valid(Pawn) then
        Return = { Loc = Vec(Pawn:K2_GetActorLocation()), Rot = Rot(Pawn:K2_GetActorRotation()) }
    end
    Current = { Map = Map, Stream = Stream, Return = Return, Phase = "loading", Exits = {} }
    Log("streaming %s ...", Map.Level)
    local T0w = Now()
    local Waited = 0
    Every(250, function()
        if not Current or not SameObj(Current.Stream, Stream) or not Valid(Stream) then return true end
        Waited = math.floor(Now() - T0w)
        if Stream:IsLevelVisible() then
            OnVisible(Map)
            return true
        elseif Waited > 60000 then
            Log("%s did not become visible within 60 s", Map.Level)
            Current.Phase = "active"             -- lets the key unload it
            return true
        end
        return false
    end)
end

local function MapByName(Name)
    for _, M in ipairs(Config.Maps) do
        if M.Name == Name then return M end
    end
    return Maps and Maps.ByName(Name) or nil
end

-- Enter Map: through the game's level transfer when the map is Native, else stream it in (Load). Native maps fall back to
-- Load only with NativeFallback = true. Returns true when something was started.
local function Enter(Map, Why, Anywhere)
    if Opt(Map, "Native", true) then
        local N = NativeBy[Map]
        if N and N.Ready then
            local World = UEHelpers.GetWorld()
            if not Anywhere and not (Valid(World) and IsHubVisible(World)) then
                Log("native: %s: enter the map from the Hub", Why)
                return false
            end
            if Current then Log("native: %s: %s is already active", Why, Current.Map.Name); return false end
            return NativeEnter(Map, Why)
        end
        if not Opt(Map, "NativeFallback", false) then
            Log("native: %s: %s is not registered (%s); NativeFallback is off, nothing loaded", Why, Map.Name,
                N and N.Failed or "registration not finished")
            return false
        end
        Log("native: %s: %s is not registered (%s); falling back to the streaming loader", Why, Map.Name,
            N and N.Failed or "registration not finished")
    end
    Load(Map)
    return Current ~= nil
end

LoadMemory()

-- Key: enters the map (the next one, with several maps), or leaves the current one. Config Key = a UE4SS key name; false = no key.
-- The default is F10, which none of the common ITR mods use.
local DefaultKey = "F10"
local KeyName = Config.Key
if KeyName == nil then KeyName = DefaultKey end
if KeyName ~= false then
    local Code = Key[KeyName]
    if not Code then
        Log("config Key '%s' is not a UE4SS key name; no key is bound", tostring(KeyName))
    else
        RegisterKeyBind(Code, function()
            if not Prime.Done then return end          -- not primed yet: nothing queues
            ExecuteInGameThread(function()
                if Current then
                    StartExit("key")
                elseif #Config.Maps > 0 then       -- (a Regions-only install has Maps = {})
                    local Map = Config.Maps[NextIndex]
                    NextIndex = NextIndex % #Config.Maps + 1
                    if Map then Enter(Map, "key") end
                end
            end)
        end)
    end
end

-- Console command (config ConsoleCommand, default "itrmap"; false = none), typed in the game console or sent by another mod
-- (ExecuteConsoleCommand):
--   <command> enter [MapName]    enter the map (the first map when no name is given)
--   <command> leave              leave the current map (back to the Hub)
-- A command naming a map this loader does not have is left for other handlers, so two loader mods can each use their own
-- command name (set ConsoleCommand per loader) without taking each other's commands.
local CommandName = Config.ConsoleCommand
if CommandName == nil then CommandName = "itrmap" end
if CommandName and type(RegisterConsoleCommandHandler) == "function" then
    local OkC, ErrC = pcall(RegisterConsoleCommandHandler, CommandName, function(FullCommand, Parameters)
        local Verb = Parameters and Parameters[1] and tostring(Parameters[1]):lower() or "enter"
        local Name = Parameters and Parameters[2] and tostring(Parameters[2]) or nil
        if Verb == "leave" then
            if not Prime.Done then Log("console command: not ready yet (the game mode has not started); ignored"); return true end
            ExecuteInGameThread(function()
                if Current then StartExit("console command") else Log("console command: leave ignored: no map is loaded") end
            end)
            return true
        end
        local Map = Config.Maps[1]
        if Name then Map = MapByName(Name) end
        if not Map then return false end
        if not Prime.Done then Log("console command: not ready yet (the game mode has not started); ignored"); return true end
        ExecuteInGameThread(function()
            if Verb == "leave" then
                if Current then StartExit("console command") else Log("console command: leave ignored: no map is loaded") end
            elseif Verb == "enter" then
                if Current then Log("console command: enter ignored: %s is already loaded", Current.Map.Name)
                else Enter(Map, "console command") end
            else
                Log("console command: unknown verb '%s' (use enter or leave)", Verb)
            end
        end)
        return true
    end)
    Log("console command '%s enter|leave [MapName]': %s", CommandName, OkC and "registered" or ("FAILED " .. tostring(ErrC)))
end

-- Test hook (config TriggerFile): creating that file loads the first map once, like its key; the file is deleted when seen.
-- Lets an unattended run start the load at a moment of its choosing instead of when the Hub is first seen.
if Config.TriggerFile then
    LoopAsync(1000, function()
        if not Prime.Done then return false end
        ExecuteInGameThread(function()
            local Ok, F = pcall(io.open, Config.TriggerFile, "r")
            if not Ok or not F then return end
            F:close()
            pcall(os.remove, Config.TriggerFile)
            if Current then
                Log("trigger file: a map is already loaded; ignored")
                return
            end
            local Map = Config.Maps[1]
            if Map then
                Log("trigger file: loading %s", Map.Name)
                Enter(Map, "trigger file")
            end
        end)
        return false
    end)
end

-- Exit markers: one check of the exit watch (started by ArmExits). Returns true when the map is gone, which ends the watch.
ExitWatchTick = function()
    if not Current then return true end
    if Current.Phase ~= "active" or not Current.Exits or #Current.Exits == 0 then return false end
    local Pawn = UEHelpers.GetPlayer()
    if not Valid(Pawn) then return false end
    local L = Pawn:K2_GetActorLocation()
    local R = Opt(Current.Map, "ExitRadius", 150)
    Current.WatchTicks = (Current.WatchTicks or 0) + 1
    if Current.WatchTicks % 60 == 1 and Current.WatchTicks < 400 then          -- every 30 s, a handful of lines
        local Best, BestD = nil, 1e30
        for _, E in ipairs(Current.Exits) do
            local D = Dist2D(L, E)
            if D < BestD then Best, BestD = E, D end
        end
        Log("exit watch: player at %s, nearest exit %s %.1f m away (radius %.1f m)", FmtV(L), Best and Best.Id or "-", BestD / 100, R / 100)
    end
    for _, E in ipairs(Current.Exits) do
        local DX, DY, DZ = L.X - E.X, L.Y - E.Y, L.Z - E.Z
        if DX * DX + DY * DY < R * R and math.abs(DZ) < 250 then
            Log("exit marker reached%s", E.Id and (" (id " .. E.Id .. ")") or "")
            Remember(Current.Map, E.Id)
            StartExit("exit marker")
            return false
        end
    end
    return false
end

if Config.AutoLoadInHub then
    local Map = MapByName(Config.AutoLoadInHub)
    if not Map then
        Log("AutoLoadInHub: no map named %s in config.lua", Config.AutoLoadInHub)
    else
        -- Load once per Hub visit, after two consecutive checks (2 s apart) found the player in the Hub.
        -- While a map is loaded the Hub may be gone (teardown); that is not a new visit, so nothing resets then.
        local HubChecks, LoadedThisVisit = 0, false
        LoopAsync(2000, function()
            if not Prime.Done then return false end
            ExecuteInGameThread(function()
                -- Native map: no timed entry. The transfer starts when the trigger item is picked up (NativeTriggerMesh),
                -- or with the key. Only a failed registration with NativeFallback = true streams the map in as before.
                if Opt(Map, "Native", true) and not ((NativeBy[Map] and NativeBy[Map].Failed) and Opt(Map, "NativeFallback", false)) then
                    return
                end
                if Current then
                    LoadedThisVisit = true
                    HubChecks = 0
                    if Current.Phase == "active" and not Valid(Current.Stream) then Current = nil end
                    return
                end
                local World = UEHelpers.GetWorld()
                local InHub = Valid(World) and IsHubVisible(World)
                HubChecks = InHub and HubChecks + 1 or 0
                if not InHub then LoadedThisVisit = false end
                if HubChecks >= 2 and not LoadedThisVisit then
                    LoadedThisVisit = true
                    Load(Map)
                end
            end)
            return false
        end)
    end
end

-- Map forms (Content/Paks/ITRMaps): read by the copy installed as "ITRMapLoader" (a renamed copy reads none, as it starts no Regions page). boot.lua (the form path, Blueprint
-- first) spawns the Blueprints at the game mode notification, which runs Prime.Step above; this file only registers the maps with the game, once, when the manager asks.
local FormMaps = {}
do
    local Dir = tostring(ScriptDir() or ""):gsub("\\", "/"):lower()
    local ReadForms = Config.Forms
    if ReadForms == nil then ReadForms = Dir:find("/itrmaploader/", 1, true) ~= nil end
    if ReadForms then
        local OkM, M = pcall(require, "boot")
        if OkM then
            Maps = M
            Maps.Init({ Register = function() NativeRegisterNow() end, ConfigMaps = Config.Maps, Command = Config.ConsoleCommand })
            local OkR, Own = pcall(Maps.Read)
            if OkR then FormMaps = Own; Prime.Step = Maps.Step else Log("forms: not read: %s", tostring(Own)) end
            if type(RegisterConsoleCommandHandler) == "function" then
                pcall(RegisterConsoleCommandHandler, "itrmaps", function(_, Params) return Maps.Console(Params) end)
            end
        else
            Log("forms: boot.lua not loaded: %s", tostring(M))
        end
    end
end

NativeStartup(FormMaps)

Log("ready: %d map(s); key %s%s; native %s; Hub teardown %s; re-entry %s; gameplay activation %s; scripts dir %s", #Config.Maps, tostring(KeyName),
    Config.AutoLoadInHub and (", auto-load " .. Config.AutoLoadInHub .. " in the Hub") or "",
    #NativeList > 0 and (#NativeList .. " native map(s), first " .. NativeList[1].Map.Name .. " as " .. tostring(NativeList[1].Tag)) or "off",
    Opt(nil, "HubTeardown", true) and "on" or "off", Opt(nil, "ReEntry", true) and "on" or "off",
    Opt(nil, "ActivateGameplay", true) and "on" or "off", ScriptDir())

-- The Regions page: boot.lua spawns its Blueprint and registers the one Construct hook (regions.lua) at the game mode notification, when a map is listed.
