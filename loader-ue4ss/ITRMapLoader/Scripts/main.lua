-- ITRMapLoader: gets you into a custom map in Into the Radius 1 (2.7.2) and back out again.
-- The map entry, exit markers and the basic load/unload were tested in VR with UE4SS 3.0.1 (the Nexus Mods ITR repack).
-- Added since (multiple exits, re-entry memory, Hub teardown, gameplay activation) is NOT tested yet. See README.md.
-- Roughly:
--   1. once you're in the Hub, stream the map in at the origin (maps are built where they'll sit in the world).
--      Normally you'd use LevelStreamingDynamic::LoadLevelInstance, but UE4SS can't call it, see Load();
--   2. when the level's visible: (HubTeardown) teleport to a staging point on the map, unload every other streaming
--      level (the Hub), then teleport to the arrival marker. Without the teardown: just teleport to the arrival marker
--      and, for maps with baked lighting, hide the Hub's lighting-scenario level;
--   3. stepping near any ExitTag marker (or pressing the key again) takes you back to the Hub. With the teardown that
--      means asking the game to load the Hub (LevelManager::LoadLevel) while you still stand on the map;
--   4. leaving through an exit that has an id is remembered, and the next entry arrives at the matching arrive marker.
--   5. (ActivateGameplay) ~3 s after arrival the map's own gameplay actors (loot, stashes, anomalies, spawners,
--      generators) get the level-start events they missed: OnLevelPrepare, GenerateLoot + SpawnLoot, OnLevelStarted,
--      OnGameStarted, OnTransitionEnd, called on each actor in the map's level (port of aiMod ActivateModMapGameplay).
-- This file avoids Lua 5.4-only syntax so `luac5.1 -p` can check it.

local UEHelpers = require("UEHelpers")
local Config = require("config")

local TAG = "[ITRMapLoader] "
local Current = nil          -- { Map, Stream, Return, Phase, Exits, TornDown, HubLevels }
local HiddenScenarios = {}   -- ULevelStreaming objects we hid (no-teardown path only)
local NextIndex = 1
local InstanceCount = 0
local Memory = {}            -- map name -> last exit id

local function Log(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end

local function Valid(o) return o ~= nil and o:IsValid() end

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

-- Runs fn on the game thread every ms until it returns true (or throws). LoopAsync runs on another thread, so the
-- stop flag is only seen one round after the game thread set it.
local function Every(ms, fn)
    local Done = false
    LoopAsync(ms, function()
        if Done then return true end
        ExecuteInGameThread(function()
            if Done then return end
            local Ok, Res = pcall(fn)
            if not Ok then
                Log("error: %s", tostring(Res))
                Done = true
            elseif Res then
                Done = true
            end
        end)
        return false
    end)
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
local function ScriptDir()
    local Ok, Info = pcall(debug.getinfo, 1, "S")
    if Ok and Info and type(Info.source) == "string" then
        local Src = (Info.source:gsub("^@", ""))
        local Dir = Src:match("^(.*[/\\])")
        if Dir then return Dir end
    end
    return ""
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
                if T == ExitTag then IsExit = true end
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

local function ArmExits(M)
    Current.Exits = M.Exits
    if #M.Exits > 0 then
        local Ids = {}
        for _, E in ipairs(M.Exits) do table.insert(Ids, E.Id or "-") end
        Log("%d exit marker(s) (ids: %s)", #M.Exits, table.concat(Ids, ", "))
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
    return Vec(Pawn:K2_GetActorLocation())
end

-- Is the player standing on this streamed level? true / false, or nil when the pawn can't tell (no movement base).
local function OnMapGround(Stream)
    local Pawn = UEHelpers.GetPlayer()
    if not Valid(Pawn) or not Valid(Stream) then return nil end
    local Ok, Base = pcall(function() return Pawn:GetMovementBase() end)
    if not Ok or not Valid(Base) then return nil end
    local Ok2, Same = pcall(function()
        local Owner = Base:GetOwner()
        local Level = Stream:GetLoadedLevel()
        if not Valid(Owner) or not Valid(Level) then return nil end
        return Owner:GetOuter():GetAddress() == Level:GetAddress()
    end)
    if Ok2 then return Same end
    return nil
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

-- Fallback aiMod uses when LoadLevel does nothing (the game thinks it's still in the Hub): the game mode's
-- TransferToLevel(LevelTag, LocationTag), as the zone gates call it.
local function CallTransferHub()
    local Ok, Res = pcall(function()
        local GM = FindFirstOf("PRGameMode")
        if not Valid(GM) then error("no PRGameMode") end
        return GM:TransferToLevel({ TagName = FName(HubLevelTag) }, { TagName = FName("None") })
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
            if S ~= (Current and Current.Stream) and Valid(L) and L.bIsLightingScenario and S:IsLevelVisible() then
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
-- Gameplay activation (port of aiMod Maps.cpp ActivateModMapGameplay, T-052 / research/level-activation.md; untested here)
---------------------------------------------------------------------------------------------------------------------
-- The map streams in after the Hub already fired its level-start events, so the map's own gameplay actors (loot points,
-- stashes, anomalies, spawners, generators; all APRBasicActor) never get them. We call the same UFUNCTIONs on each actor
-- that lives in our level, in the game's order, through the actor so Blueprint overrides run. The global
-- UEventsManager delegates are NOT fired (the game mode, the player and the UI listen to those too).
local ActivateDelayMs = 3000                 -- after arrival: the actors' BeginPlay must have run
local LootBaseClass = "BP_LootSpawnPoint_C"  -- GenerateLoot + SpawnLoot are called on this class and its children

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

-- ---- loot manifest (T-051; port of aiMod Loot.cpp LootRegisterManifest) ------------------------------------------------
-- The map's own loot tags go into the game config's LootArray (TMap<FGameplayTag, FPRLootTableConfig>) before its loot is
-- generated, so its nodes never draw on the save-wide budgets of the real zone tags. aiMod drives the TMap's memory by hand;
-- here it is TMap:Add through UE4SS. Manifest = tools/itr-showcase/loot_manifest.json (copied next to this script as
-- "<Map.Name>.loot.json"); a "<Map.Name>.loot.lua" returning the same table also works, or Map.LootManifest = path.

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
    local Last = Candidates[1]
    for _, Path in ipairs(Candidates) do
        Last = Path
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
    return nil, Last
end

local function TMapCount(M)
    local N = 0
    local Ok = pcall(function() M:ForEach(function() N = N + 1 end) end)
    return Ok and N or -1
end

-- The value struct of Key in the TMap, or nil
local function TMapFind(M, Key)
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

local LootRegisteredOnce = false

-- Called before the activation pass, once per session. For each manifest tag not already in LootArray: copy the donor
-- (source_tag) entry's table, set LootPoints, TMap:Add. Own DataTable (table_asset) if the map pak ships it, else the donor's
-- (used points are then SHARED with the donor zone, as in aiMod).
local function RegisterLootTags(Manifest)
    if not Manifest then return 0 end
    if LootRegisteredOnce then return 0 end
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
    local Before = TMapCount(M)
    Log("loot manifest: %d tag(s); LootArray has %d entries before", #Tags, Before)
    local Added, Skipped, NoDonor, Failed, Own = 0, 0, 0, 0, 0
    for _, T in ipairs(Tags) do
        local Tag, Src, Points = T.tag, T.source_tag, math.floor(tonumber(T.loot_points) or 0)
        if type(Tag) == "string" and Tag ~= "" then
            local Key = { TagName = FName(Tag) }
            if TMapFind(M, Key) ~= nil then
                Skipped = Skipped + 1
                Log("loot: tag %s already in LootArray: skipped", Tag)
            else
                local Donor = type(Src) == "string" and TMapFind(M, { TagName = FName(Src) }) or nil
                if Donor == nil then
                    NoDonor = NoDonor + 1
                    Log("loot: tag %s: source tag %s not in LootArray (no donor DataTable): skipped", Tag, tostring(Src))
                else
                    local Table = Donor.LootTable
                    local OwnTable = nil
                    if type(T.table_asset) == "string" and T.table_asset ~= "" then
                        local Ok, O = pcall(function()
                            if LoadAsset then pcall(LoadAsset, T.table_asset) end
                            return StaticFindObject(T.table_asset)
                        end)
                        if Ok and Valid(O) then OwnTable = O end
                    end
                    if OwnTable then
                        Table = OwnTable
                        Own = Own + 1
                        Log("loot: tag %s: own DataTable %s (isolated used points)", Tag, T.table_asset)
                    else
                        Log("loot: tag %s: no own DataTable asset (%s); using the donor's: its used points are SHARED with the zone tag %s",
                            Tag, tostring(T.table_asset), tostring(Src))
                    end
                    local Ok, Err = pcall(function()
                        M:Add(Key, { Conditions = {}, LootPoints = Points, LootTable = Table, ExcludeGeneration = false })
                    end)
                    if not Ok then
                        Failed = Failed + 1
                        Log("loot: tag %s: TMap:Add failed: %s", Tag, tostring(Err))
                    else
                        local Back = TMapFind(M, Key)
                        if Back ~= nil then
                            Added = Added + 1
                            local Pts = -1
                            pcall(function() Pts = Back.LootPoints end)
                            Log("loot: tag %s added: budget %s (wanted %d), donor %s", Tag, tostring(Pts), Points, tostring(Src))
                        else
                            Failed = Failed + 1
                            Log("loot: tag %s: TMap:Add returned but Find does not see it", Tag)
                        end
                    end
                end
            end
        end
    end
    LootRegisteredOnce = Added + Skipped > 0
    Log("loot manifest registered: LootArray %d -> %d entries (%d added, %d already present, %d without donor, %d failed, %d own tables)",
        Before, TMapCount(M), Added, Skipped, NoDonor, Failed, Own)
    return Added
end

-- TEMP shim (config LootRetagShim; mirrors aiMod Loot.cpp LootTempRetagG2): until the map pipeline emits the showcase tags,
-- retag the G2_* loot nodes (Loot.Buffer.<Area>.<Cat> -> Loot.ItrShowcase.T1.<Cat>) and the G2 generator id.
local function LootRetagShim(Acts)
    local Nodes, Gens = 0, 0
    for _, A in ipairs(Acts) do
        if Valid(A) then
            local Name = A:GetFName():ToString()
            if Name:sub(1, 3) == "G2_" then
                if IsClassNamed(A, LootBaseClass) then
                    local Ok, Old = pcall(function() return A.LootTable.TagName:ToString() end)
                    local New = ""
                    if Ok and Old:sub(1, 12) == "Loot.Buffer." then
                        local Rest = Old:sub(13)
                        if Rest:sub(1, 6) == "Stash." then New = "Loot.ItrShowcase.T1." .. Rest
                        else New = "Loot.ItrShowcase.T1." .. (Rest:match("^[^.]+%.(.*)$") or Rest) end
                    end
                    if New == "" or not LootHasTag(New) then
                        Log("loot: TEMP retag %s: %s -> %s not possible (tag not registered)", Name, tostring(Old), New)
                    else
                        local Ok2, Err = pcall(function() A.LootTable = { TagName = FName(New) } end)
                        Log("loot: TEMP retag %s: %s -> %s: %s", Name, tostring(Old), New, Ok2 and "done" or ("ERROR " .. tostring(Err)))
                        if Ok2 then Nodes = Nodes + 1 end
                    end
                elseif ClassNameOf(A):find("SpawnGenerator", 1, true) then
                    local Ok, Old = pcall(function() return A.generatorID.TagName:ToString() end)
                    local Ok2, Err = pcall(function() A.generatorID = { TagName = FName("NPC.Generator.ItrShowcase.A0_1") } end)
                    Log("loot: TEMP generator %s id %s -> NPC.Generator.ItrShowcase.A0_1: %s", Name, Ok and Old or "?",
                        Ok2 and "done" or ("ERROR " .. tostring(Err)))
                    if Ok2 then Gens = Gens + 1 end
                end
            end
        end
    end
    Log("loot: TEMP shim done: %d node(s) retagged, %d generator id(s)", Nodes, Gens)
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
local function ActivationPass(Acts, Fn, Args, Filter)
    local C = { Ok = 0, NoFunc = 0, Failed = 0, Dead = 0 }
    for _, A in ipairs(Acts) do
        if not Filter or Filter(A) then
            if not Valid(A) then
                C.Dead = C.Dead + 1
            else
                local Name = A:GetFName():ToString()
                local Cls = ClassNameOf(A)
                local Okf, F = pcall(function() return A[Fn] end)
                if not Okf or type(F) ~= "function" then
                    C.NoFunc = C.NoFunc + 1
                    Log("activate: %s -> %s (%s): NO SUCH FUNCTION", Fn, Name, Cls)
                else
                    local Ok, Res = pcall(F, A, (table.unpack or unpack)(Args or {}))
                    if Ok then
                        C.Ok = C.Ok + 1
                        Log("activate: %s -> %s (%s): called%s%s", Fn, Name, Cls, Res ~= nil and (" = " .. tostring(Res)) or "",
                            Valid(A) and "" or "; actor DESTROYED itself")
                    else
                        C.Failed = C.Failed + 1
                        Log("activate: %s -> %s (%s): ERROR %s", Fn, Name, Cls, tostring(Res))
                    end
                end
            end
        end
    end
    Log("activate: %s: %d called, %d without the function, %d errors, %d already gone", Fn, C.Ok, C.NoFunc, C.Failed, C.Dead)
    return C
end

local function ActivateGameplay(Map, Stream)
    local T0 = os.clock()
    if not Valid(Stream) or not CallBool(Stream, "IsLevelVisible") then
        Log("activate: skipped (map gone)")
        return
    end
    local TagName = CurrentLevelTagName()
    local Tag = { TagName = FName(TagName) }
    local Acts = BasicActorsIn(Stream)
    local Before = CountByClass(Acts)
    Log("activate: %d APRBasicActor(s) in %s; level tag %s", #Acts, Map.Level, TagName)
    for _, N in ipairs(SortedKeys(Before)) do Log("activate:   %s x %d", N, Before[N]) end

    local Manifest, ManifestPath = LoadLootManifest(Map)
    if Manifest then Log("activate: loot manifest %s", ManifestPath)
    else Log("activate: no loot manifest (%s); the map's loot uses the tags it was built with", ManifestPath) end
    local Ok, Err = pcall(RegisterLootTags, Manifest)
    if not Ok then Log("activate: RegisterLootTags failed: %s", tostring(Err)) end
    if Opt(Map, "LootRetagShim", false) then
        local Ok2, Err2 = pcall(LootRetagShim, Acts)
        if not Ok2 then Log("activate: LootRetagShim failed: %s", tostring(Err2)) end
    end

    -- Order of the game's own chain (level-activation.md section 3). An actor that destroys itself in OnLevelPrepare
    -- (generator excluded in the save) is skipped by the later passes through the Valid check.
    local function IsLoot(A) return IsClassNamed(A, LootBaseClass) end
    local Prep = ActivationPass(Acts, "OnLevelPrepare", { Tag })
    local Gen = ActivationPass(Acts, "GenerateLoot", nil, IsLoot)
    local Spawn = ActivationPass(Acts, "SpawnLoot", nil, IsLoot)
    local Start = ActivationPass(Acts, "OnLevelStarted", { Tag })
    local Game = ActivationPass(Acts, "OnGameStarted")
    local Trans = ActivationPass(Acts, "OnTransitionEnd")

    local After = CountByClass(Acts)
    Log("activate: summary per class (before -> alive after):")
    for _, N in ipairs(SortedKeys(Before)) do
        Log("activate:   %s: %d -> %d%s", N, Before[N], After[N] or 0, (After[N] or 0) < Before[N] and "  (destroyed itself)" or "")
    end
    Log("activate: done in %.0f ms; level tag %s; basic actors %d; OnLevelPrepare %d, GenerateLoot %d, SpawnLoot %d, "
        .. "OnLevelStarted %d, OnGameStarted %d, OnTransitionEnd %d; errors %d", (os.clock() - T0) * 1000, TagName, #Acts, Prep.Ok,
        Gen.Ok, Spawn.Ok, Start.Ok, Game.Ok, Trans.Ok,
        Prep.Failed + Gen.Failed + Spawn.Failed + Start.Failed + Game.Failed + Trans.Failed)
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
    local Waited = 0
    Every(250, function()
        if not Current or Current.Stream ~= Stream or not Valid(Stream) then
            Log("activate: skipped (map unloaded or another load started)")
            return true
        end
        Waited = Waited + 250
        if Waited < ActivateDelayMs then return false end
        ActivateGameplay(Map, Stream)
        return true
    end)
end

---------------------------------------------------------------------------------------------------------------------
-- Arrival
---------------------------------------------------------------------------------------------------------------------
-- Watches whether the player stays at the arrival point after the teardown (the Hub's snap-back shows up here)
local function StayCheck(Arrive)
    local At = { 1, 3, 6, 10, 20 }
    local Step, Elapsed = 1, 0
    Every(500, function()
        if not Current or Current.Phase ~= "active" then return true end
        Elapsed = Elapsed + 500
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
-- Hub teardown (port of aiMod Maps.cpp "Hub teardown"; untested here)
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
        if S ~= Current.Stream then
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
    local Waited = 0
    Every(250, function()
        if not Current or not Valid(Current.Stream) then return true end
        Waited = Waited + 250
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
        if Left > 0 or Ground == false then
            Log("Hub teardown: NOT moving to the arrival marker (%d Hub level(s) did not unload, on map ground: %s); "
                .. "the player stays at the staging point", Left, tostring(Ground))
            ArmExits(M)
            Current.Phase = "active"
            ScheduleActivation(Map)              -- aiMod activates whatever the teardown did
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
    local Waited, Near = 0, 0
    Every(250, function()
        if not Current or not Valid(Current.Stream) then return true end
        Waited = Waited + 250
        local Ground = OnMapGround(Current.Stream)
        local L = PawnLoc()
        local Confirmed
        if Ground ~= nil then
            Confirmed = Ground
        else
            -- the pawn can't report its floor: counts as standing on the map after a second at the staging point
            if L and Dist2D(L, Staging.Loc) < 400 then Near = Near + 1 else Near = 0 end
            Confirmed = Near >= 4
        end
        if Confirmed then
            Log("Hub teardown +%d ms: player at %s on map ground (%s); unloading the Hub", Waited, L and FmtV(L) or "?",
                Ground ~= nil and "movement base" or "position")
            UnloadHub(Map, M, Arrival, Staging)
            return true
        end
        if Waited >= 15000 then
            Log("Hub teardown skipped: the player was not on the map's ground at the staging point within 15 s (on map: %s)",
                tostring(Ground))
            if Map.HideLightingScenario then SetLightingScenariosHidden(UEHelpers.GetWorld(), true) end
            Arrive(Map, M, Arrival)
            return true
        end
        return false
    end)
end

---------------------------------------------------------------------------------------------------------------------
-- Leaving
---------------------------------------------------------------------------------------------------------------------
local function FinishUnload()
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
local function ConfirmOffMapThenUnload(Return)
    local Waited, Near = 0, 0
    local Stream = Current.Stream
    Every(250, function()
        if not Current then return true end
        Waited = Waited + 250
        local Ground = OnMapGround(Stream)
        local Off
        if Ground ~= nil then
            Off = not Ground
        elseif Return then
            local L = PawnLoc()
            if L and Dist2D(L, Return) < 600 then Near = Near + 1 else Near = 0 end
            Off = Near >= 2
        else
            Off = true                           -- nothing to compare with: nothing to wait for
        end
        if Off then
            Log("exit: player is off the map (%s); unloading it", Ground ~= nil and "movement base" or "position")
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
    RestoreHubLevels()
    if Moved <= 5000 and Return then
        Log("exit: teleporting the player back to their Hub position %s", FmtV(Return.Loc))
        TeleportPlayer(Return.Loc, Return.Rot, "saved Hub position")
        ConfirmOffMapThenUnload(Return.Loc)
    else
        ConfirmOffMapThenUnload(nil)
    end
end

-- Exit with the Hub torn down: the game's own Hub load while the player still stands on the map, then unload the map
-- only if it is still loaded and the player isn't on it.
local function HubExit()
    local Start = PawnLoc()
    local Return = Current.Return
    for _, H in ipairs(Current.HubLevels or {}) do H.Gone = nil end
    Log("exit: Hub teardown is active; asking the game to load %s while the player stands on the map", HubLevelTag)
    local Called = CallLoadLevelHub()
    local Transferred = false
    if not Called then
        Transferred = true
        if not CallTransferHub() then
            Log("exit FAILED: neither LoadLevel nor TransferToLevel could be called; the map stays loaded")
            Current.Phase = "active"
            return
        end
    end
    local Elapsed, Activity = 0, false
    Every(250, function()
        if not Current or Current.Phase ~= "exiting" then return true end
        Elapsed = Elapsed + 250
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

local function StartExit(Why)
    if not Current or Current.Phase ~= "active" then
        Log("%s ignored: the map is %s", Why, Current and Current.Phase or "not loaded")
        return
    end
    Log("leaving %s (%s)", Current.Map.Name, Why)
    Current.Phase = "exiting"
    if Current.TornDown then HubExit() else SimpleExit() end
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
    local Waited = 0
    Every(250, function()
        if not Current or Current.Stream ~= Stream or not Valid(Stream) then return true end
        Waited = Waited + 250
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
    return nil
end

LoadMemory()

RegisterKeyBind(Key[Config.Key] or Key.F7, function()
    ExecuteInGameThread(function()
        if Current then
            StartExit("key")
        else
            local Map = Config.Maps[NextIndex]
            NextIndex = NextIndex % #Config.Maps + 1
            if Map then Load(Map) end
        end
    end)
end)

-- Test hook (config TriggerFile): creating that file loads the first map once, like F7; the file is deleted when seen.
-- Lets an unattended run start the load at a moment of its choosing instead of when the Hub is first seen.
if Config.TriggerFile then
    LoopAsync(1000, function()
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
                Load(Map)
            end
        end)
        return false
    end)
end

-- Exit markers: checked twice a second while a map is loaded and settled
LoopAsync(500, function()
    ExecuteInGameThread(function()
        if not Current or Current.Phase ~= "active" or not Current.Exits or #Current.Exits == 0 then return end
        local Pawn = UEHelpers.GetPlayer()
        if not Valid(Pawn) then return end
        local L = Pawn:K2_GetActorLocation()
        local R = Opt(Current.Map, "ExitRadius", 150)
        for _, E in ipairs(Current.Exits) do
            local DX, DY, DZ = L.X - E.X, L.Y - E.Y, L.Z - E.Z
            if DX * DX + DY * DY < R * R and math.abs(DZ) < 250 then
                Log("exit marker reached%s", E.Id and (" (id " .. E.Id .. ")") or "")
                Remember(Current.Map, E.Id)
                StartExit("exit marker")
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
        -- Load once per Hub visit, after two consecutive checks (2 s apart) found the player in the Hub.
        -- While a map is loaded the Hub may be gone (teardown); that is not a new visit, so nothing resets then.
        local HubChecks, LoadedThisVisit = 0, false
        LoopAsync(2000, function()
            ExecuteInGameThread(function()
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

Log("ready: %d map(s); key %s%s; Hub teardown %s; re-entry %s; gameplay activation %s", #Config.Maps, Config.Key,
    Config.AutoLoadInHub and (", auto-load " .. Config.AutoLoadInHub .. " in the Hub") or "",
    Opt(nil, "HubTeardown", true) and "on" or "off", Opt(nil, "ReEntry", true) and "on" or "off",
    Opt(nil, "ActivateGameplay", true) and "on" or "off")
