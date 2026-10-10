-- ITRMapLoader: gets you into a custom map in Into the Radius 1 (2.7.2) and back out again.
-- Tested in VR with UE4SS 3.0.1 (the Nexus Mods ITR repack). See README.md.
-- Roughly:
--   1. once you're in the Hub, stream the map in at the origin (maps are built where they'll sit in the world).
--      Normally you'd use LevelStreamingDynamic::LoadLevelInstance, but UE4SS can't call it, see Load();
--   2. when the level's visible, teleport the player to the TargetPoint tagged StartTag;
--   3. for maps with baked lighting, hide the Hub's lighting-scenario level;
--   4. stepping near an ExitTag marker (or pressing the key again) moves you back to where you were and unloads it.

local UEHelpers = require("UEHelpers")
local Config = require("config")

local TAG = "[ITRMapLoader] "
local Current = nil          -- { Map = <config entry>, Stream = ULevelStreamingDynamic }
local HiddenScenarios = {}   -- ULevelStreaming objects we hid
local NextIndex = 1
local Busy = false

local function Log(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end

local function Valid(o) return o ~= nil and o:IsValid() end

local function StreamingLevels(World)
    local out = {}
    World.StreamingLevels:ForEach(function(_, Elem)
        local S = Elem:get()
        if Valid(S) then table.insert(out, S) end
    end)
    return out
end

-- In the Hub = the Hub level visible and the game's level manager not mid-transition (the Hub level becomes visible
-- while the player is still in the menu room, during the transition; callers also wait for two checks in a row).
local function IsHubVisible(World)
    local Hub = false
    for _, S in ipairs(StreamingLevels(World)) do
        if S:IsLevelVisible() and S:GetWorldAssetPackageFName():ToString():find("/Levels/Hub/L_Hub", 1, true) then
            Hub = true
        end
    end
    if not Hub then return false end
    local LMClass = StaticFindObject("/Script/IntoTheRadius.Default__LevelManager")
    if Valid(LMClass) then
        local LM = LMClass:GetLevelManager()
        if Valid(LM) and not LM:IsReady() then return false end
    end
    return true
end

local function SetLightingScenariosHidden(World, Hide)
    if Hide then
        for _, S in ipairs(StreamingLevels(World)) do
            local L = S:GetLoadedLevel()
            if S ~= (Current and Current.Stream) and Valid(L) and L.bIsLightingScenario and S:IsLevelVisible() then
                S:SetShouldBeVisible(false)
                table.insert(HiddenScenarios, S)
                Log("hid lighting scenario %s", S:GetWorldAssetPackageFName():ToString())
            end
        end
    else
        for _, S in ipairs(HiddenScenarios) do
            if Valid(S) then S:SetShouldBeVisible(true) end
        end
        HiddenScenarios = {}
    end
end

-- TargetPoints in the streamed level carrying Tag
local function FindTagged(Stream, Tag)
    local Level = Stream:GetLoadedLevel()
    local Points = FindAllOf("TargetPoint")
    local Out = {}
    if not Points or not Valid(Level) then return Out end
    for _, P in ipairs(Points) do
        if Valid(P) and P:GetOuter():GetAddress() == Level:GetAddress() then
            local Found = false
            P.Tags:ForEach(function(_, T)
                if T:get():ToString() == Tag then Found = true end
            end)
            if Found then table.insert(Out, P) end
        end
    end
    return Out
end

local function Teleport(Map, Stream)
    local Start = FindTagged(Stream, Map.StartTag)[1]
    local Pawn = UEHelpers.GetPlayer()
    if not Valid(Start) or not Valid(Pawn) then
        Log("no start marker tagged '%s' in %s (or no player pawn); you stay where you are", Map.StartTag, Map.Level)
        return
    end
    local Ok = Pawn:K2_TeleportTo(Start:K2_GetActorLocation(), Start:K2_GetActorRotation())
    Log("teleport to %s: %s", Start:GetFullName(), tostring(Ok))
    -- Exit markers (VR-friendly way out): standing within 1.5 m of one unloads the map and returns you to the Hub
    Current.Exits = {}
    for _, E in ipairs(FindTagged(Stream, Config.ExitTag or "itr:exit")) do
        local L = E:K2_GetActorLocation()
        table.insert(Current.Exits, { X = L.X, Y = L.Y, Z = L.Z })
    end
    if #Current.Exits > 0 then Log("%d exit marker(s)", #Current.Exits) end
end

local function Unload()
    local World = UEHelpers.GetWorld()
    -- Back to where the player stood before the map loaded, before the floor goes away
    local Pawn = UEHelpers.GetPlayer()
    if Current and Current.Return and Valid(Pawn) then
        Pawn:K2_TeleportTo(Current.Return.Loc, Current.Return.Rot)
        Log("returned to the Hub")
    end
    if Current and Valid(Current.Stream) then
        Current.Stream:SetShouldBeVisible(false)
        Current.Stream:SetShouldBeLoaded(false)
        Log("unloaded %s", Current.Map.Name)
    end
    if Valid(World) then SetLightingScenariosHidden(World, false) end
    Current = nil
end

local function Load(Map)
    if Busy then return end
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
    InstanceCount = (InstanceCount or 0) + 1
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
        local L, R = Pawn:K2_GetActorLocation(), Pawn:K2_GetActorRotation()
        Return = { Loc = { X = L.X, Y = L.Y, Z = L.Z }, Rot = { Pitch = R.Pitch, Yaw = R.Yaw, Roll = R.Roll } }
    end
    Current = { Map = Map, Stream = Stream, Return = Return }
    Busy = true
    Log("streaming %s ...", Map.Level)
    -- ExecuteInGameThread runs later, so the loop sees Done one round after the game thread set it.
    local Waited, Done = 0, false
    LoopAsync(250, function()
        Waited = Waited + 250
        if Done then Busy = false; return true end      -- returning true stops the loop
        ExecuteInGameThread(function()
            if Done then return end
            if not Current or not Valid(Current.Stream) then Done = true; return end
            if Current.Stream:IsLevelVisible() then
                Done = true
                if Map.HideLightingScenario then SetLightingScenariosHidden(UEHelpers.GetWorld(), true) end
                Teleport(Map, Current.Stream)
            elseif Waited > 60000 then
                Done = true
                Log("%s did not become visible within 60 s", Map.Level)
            end
        end)
        return false
    end)
end

local function MapByName(Name)
    for _, M in ipairs(Config.Maps) do
        if M.Name == Name then return M end
    end
    return nil
end

RegisterKeyBind(Key[Config.Key] or Key.F7, function()
    ExecuteInGameThread(function()
        if Current then
            Unload()
        else
            local Map = Config.Maps[NextIndex]
            NextIndex = NextIndex % #Config.Maps + 1
            if Map then Load(Map) end
        end
    end)
end)

-- Exit markers: checked twice a second while a map is loaded
LoopAsync(500, function()
    ExecuteInGameThread(function()
        if not Current or not Current.Exits or #Current.Exits == 0 then return end
        local Pawn = UEHelpers.GetPlayer()
        if not Valid(Pawn) then return end
        local L = Pawn:K2_GetActorLocation()
        for _, E in ipairs(Current.Exits) do
            local DX, DY, DZ = L.X - E.X, L.Y - E.Y, L.Z - E.Z
            if DX * DX + DY * DY < 150 * 150 and math.abs(DZ) < 250 then
                Log("exit marker reached")
                Unload()
                return
            end
        end
    end)
    return false
end)

if Config.AutoLoadInHub then
    local Map = MapByName(Config.AutoLoadInHub)
    if not Map then
        Log("AutoLoadInHub: no map named %s in config.lua", Config.AutoLoadInHub)
    else
        -- Load once per Hub visit, after two consecutive checks (2 s apart) found the player in the Hub
        local HubChecks, LoadedThisVisit = 0, false
        LoopAsync(2000, function()
            ExecuteInGameThread(function()
                local World = UEHelpers.GetWorld()
                local InHub = Valid(World) and IsHubVisible(World)
                HubChecks = InHub and HubChecks + 1 or 0
                if not InHub then LoadedThisVisit = false end
                if HubChecks >= 2 and not LoadedThisVisit and not Current then
                    LoadedThisVisit = true
                    Load(Map)
                end
                if Current and not Valid(Current.Stream) then Current = nil end
            end)
            return false
        end)
    end
end

Log("ready: %d map(s); key %s%s", #Config.Maps, Config.Key,
    Config.AutoLoadInHub and (", auto-load " .. Config.AutoLoadInHub .. " in the Hub") or "")
