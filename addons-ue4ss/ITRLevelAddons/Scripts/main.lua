-- ITRLevelAddons: streams small add-on levels into a stock level of Into the Radius 1 (2.7.2) while that level is visible,
-- and hides named actors of the stock level. One JSON manifest per add-on in this mod's Addons folder (or "itraddons place" from another mod);
-- any number of add-ons (from any number of mods) stack, each in its own streaming entry. See README.md.
--
-- Event driven: no timers, no loops and no script hooks. A small logic-only Blueprint (BP_ITRLevelWatch, in this mod's helper pak) binds a
-- streaming entry's OnLevelShown / OnLevelHidden and runs the console command "itraddons shown|hidden <id>" when the level really appears or goes:
--   * target level shown:  the add-on level is streamed in (at the manifest's transform; the default is the origin, so an add-on is built in the
--                           stock level's world coordinates). A target that is already visible when the watch is set up is acted on at once.
--                           The streaming entry is made once per world with LevelStreaming::CreateInstance and reused on every later visit.
--   * add-on shown:        the listed actors of the stock level are hidden (hidden in game, collision off, never destroyed); the add-on's
--                           "notify" command, if it has one, is run with the entry name.
--   * target level hidden: the add-on level is unloaded.
-- Setup (finding the entries and binding the watches) runs when a world's game mode appears, when the game registers streaming entries, and when
-- another mod places an add-on. Without the helper pak the mod logs it and does nothing.
-- This file avoids Lua 5.4-only syntax so `luac5.1 -p` can check it.

local UEHelpers = require("UEHelpers")
local Manifest = require("manifest")
local OkCfg, Config = pcall(require, "config")
if not OkCfg or type(Config) ~= "table" then Config = {} end

local TAG = "[" .. (Config.LogTag or "ITRLevelAddons") .. "] "
local ModName = Config.ModName or "ITRLevelAddons"

local function Log(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end
local function Valid(o)
    if o == nil then return false end
    local Ok, V = pcall(function() return o:IsValid() end)
    return Ok and V == true
end
local function Addr(o)
    local Ok, A = pcall(function() return o:GetAddress() end)
    return Ok and A or nil
end
local LoggedOnce = {}
local function LogOnce(Key, fmt, ...)
    if LoggedOnce[Key] then return end
    LoggedOnce[Key] = true
    Log(fmt, ...)
end

---------------------------------------------------------------------------------------------------------------------
-- Finding the manifests
---------------------------------------------------------------------------------------------------------------------
local function ScriptDir()
    local Ok, Info = pcall(debug.getinfo, 1, "S")
    if Ok and Info and type(Info.source) == "string" then
        local Dir = Info.source:gsub("^@", ""):match("^(.*[/\\])")
        if Dir then return Dir end
    end
    local Ok2, Found = pcall(function() return package.searchpath("manifest", package.path) end)
    if Ok2 and type(Found) == "string" then return Found:match("^(.*[/\\])") or "" end
    return ""
end

local function Norm(P) return (tostring(P or ""):gsub("\\", "/"):gsub("/%./", "/"):gsub("/+", "/"):lower()) end

-- The Addons folder: <mod>/Addons (Config.AddonsDir overrides)
local AddonsDir = Config.AddonsDir or (ScriptDir():gsub("[Ss]cripts[/\\]$", "") .. "Addons")

-- Every *.json in the Addons folder. UE4SS's IterateGameDirectories() lists files without starting a process; the mods
-- folder sits at one of three places depending on how UE4SS was installed. Falls back to `dir /b` (a short console
-- process) only when none of them is found.
local function ListManifests()
    local Out, How = {}, nil
    local Ok, Tree = pcall(IterateGameDirectories)
    if Ok and type(Tree) == "table" then
        local Chains = {
            { "Binaries", "Win64", "ue4ss", "Mods", ModName, "Addons" },
            { "Binaries", "Win64", "Mods", ModName, "Addons" },
            { "Content", "Paks", "LuaMods", ModName, "Addons" },
        }
        local Roots = {}
        if type(Tree.Game) == "table" then table.insert(Roots, Tree.Game) end
        for K, V in pairs(Tree) do
            if K ~= "Game" and type(V) == "table" then table.insert(Roots, V) end
        end
        for I = 1, #Roots do                 -- in case "Game" is the folder above the one that holds Binaries
            local OkI, Inner = pcall(function() return Roots[I].IntoTheRadius end)
            if OkI and type(Inner) == "table" then table.insert(Roots, Inner) end
        end
        local Want = Norm(AddonsDir)
        for _, Root in ipairs(Roots) do
            for _, Chain in ipairs(Chains) do
                local D = Root
                for _, Part in ipairs(Chain) do
                    if type(D) ~= "table" then break end
                    local OkD, Next = pcall(function() return D[Part] end)
                    D = OkD and Next or nil
                end
                if type(D) == "table" and type(D.__files) == "table" then
                    local Abs = Norm(D.__absolute_path)
                    if Want == "" or Abs == "" or Abs == Want or Want:sub(-#Abs) == Abs or Abs:sub(-#Want) == Want
                        or Abs:find("/" .. ModName:lower() .. "/addons$") then
                        for _, F in pairs(D.__files) do
                            local Name = type(F) == "table" and F.__name or nil
                            local Path = type(F) == "table" and F.__absolute_path or nil
                            if type(Name) == "string" and Name:lower():match("%.json$") then
                                table.insert(Out, { Name = Name, Path = Path or (AddonsDir .. "/" .. Name) })
                            end
                        end
                        How = "IterateGameDirectories " .. tostring(D.__absolute_path)
                        break
                    end
                end
            end
            if How then break end
        end
    end
    if not How then
        local Win = AddonsDir:gsub("/", "\\")
        local OkP, P = pcall(io.popen, 'dir /b /a-d "' .. Win .. '\\*.json" 2>nul')
        if OkP and P then
            for Line in P:lines() do
                local Name = Line:gsub("[\r\n]", "")
                if Name:lower():match("%.json$") then table.insert(Out, { Name = Name, Path = AddonsDir .. "/" .. Name }) end
            end
            P:close()
            How = "dir " .. Win
        end
    end
    table.sort(Out, function(A, B) return A.Name:lower() < B.Name:lower() end)
    return Out, How or "nothing (no Addons folder found)"
end

local Addons = {}
local Seen = {}
-- Adds one checked add-on record (from a manifest file or from "itraddons place"). Returns true when it was added.
local function AddAddon(A, Source)
    if not A.Enabled then
        Log("%s: %s is switched off (enabled = false)", Source, A.Name)
        return false
    end
    if Seen[A.Name:lower()] then
        Log("manifest REJECTED: %s: the add-on name %s is already used by %s", Source, A.Name, Seen[A.Name:lower()])
        return false
    end
    -- the same level and target as an add-on already listed would stream a second copy on top of the first (a level is streamed once): refused
    for _, O in ipairs(Addons) do
        if O.Level:lower() == A.Level:lower() and O.Target:lower() == A.Target:lower() then
            Log("manifest REJECTED: %s: add-on %s names the same level and target as %s (%s): a level is streamed once", Source, A.Name, O.Name, Seen[O.Name:lower()] or "?")
            return false
        end
    end
    Seen[A.Name:lower()] = Source
    A.TargetL, A.LevelL = A.Target:lower(), A.Level:lower()
    A.Wanted, A.Shown = false, false
    A.Stream, A.HiddenFor = nil, {}
    table.insert(Addons, A)
    Log("add-on %s: %s into %s, %d actor(s) to hide%s", A.Name, A.Level, A.Target, #A.Hide,
        (A.Location[1] ~= 0 or A.Location[2] ~= 0 or A.Location[3] ~= 0 or A.Rotation[2] ~= 0)
        and string.format(", offset (%.0f, %.0f, %.0f) yaw %.1f", A.Location[1], A.Location[2], A.Location[3], A.Rotation[2]) or "")
    return true
end

local function LoadManifests()
    local Files, How = ListManifests()
    Log("Addons folder %s: %d manifest(s) (listed with %s)", AddonsDir, #Files, How)
    for _, F in ipairs(Files) do
        local Text
        local Ok, H = pcall(io.open, F.Path, "rb")
        if Ok and H then Text = H:read("*a"); H:close() end
        if not Text then
            Log("manifest %s: cannot read %s", F.Name, tostring(F.Path))
        else
            local A, Err, Warn = Manifest.Parse(Text, F.Name)
            for _, W in ipairs(Warn or {}) do Log("manifest %s", W) end
            if not A then
                Log("manifest REJECTED: %s", Err)
            else
                AddAddon(A, F.Name)
            end
        end
    end
end


---------------------------------------------------------------------------------------------------------------------
-- Streaming helpers
---------------------------------------------------------------------------------------------------------------------
local function StreamingLevels(World)
    local Out = {}
    pcall(function()
        World.StreamingLevels:ForEach(function(_, Elem)
            local S = Elem:get()
            if Valid(S) then table.insert(Out, S) end
        end)
    end)
    return Out
end

local function PkgName(S)
    local Ok, N = pcall(function() return S:GetWorldAssetPackageFName():ToString() end)
    return Ok and N or "?"
end

local function IsVisible(S)
    local Ok, R = pcall(function() return S:IsLevelVisible() end)
    return Ok and R == true
end

-- Every streaming entry of one package (normally one; several are all watched)
local function EntriesOf(Levels, PkgL)
    local Out = {}
    for _, S in ipairs(Levels) do
        if PkgName(S):lower() == PkgL then table.insert(Out, S) end
    end
    return Out
end

local function AnyVisible(List)
    for _, S in ipairs(List) do if IsVisible(S) then return true end end
    return false
end

local function InstanceName(A) return "ITRAddon_" .. A.Name end

-- An entry this mod made earlier in this world (a Lua reload, or the map loader handing a level back)
local function FindOwnEntry(Levels, A)
    local Suffix = "/" .. InstanceName(A):lower()
    for _, S in ipairs(Levels) do
        local P = PkgName(S):lower()
        if P:sub(-#Suffix) == Suffix then return S end
    end
    return nil
end

local function MakeEntry(World, Levels, A)
    local Source = nil
    for _, S in ipairs(Levels) do
        local Ok, N = pcall(function() return S:GetClass():GetFName():ToString() end)
        if Ok and N == "LevelStreamingDynamic" then Source = S; break end
    end
    if not Source then return nil, "no LevelStreamingDynamic in this world to copy" end
    local Ok, Stream = pcall(function() return Source:CreateInstance(InstanceName(A)) end)
    if not Ok or not Valid(Stream) then return nil, "CreateInstance failed (" .. tostring(Stream) .. ")" end
    Stream.PackageNameToLoad = FName(A.Level)
    local Q = Manifest.Quat(A.Rotation[1], A.Rotation[2], A.Rotation[3])
    Stream.LevelTransform = { Rotation = Q, Translation = { X = A.Location[1], Y = A.Location[2], Z = A.Location[3] },
                              Scale3D = { X = A.Scale[1], Y = A.Scale[2], Z = A.Scale[3] } }
    pcall(function() Stream:SetShouldBeVisible(false) end)
    pcall(function() Stream:SetShouldBeLoaded(false) end)
    Log("add-on %s: streaming entry %s made (package %s)", A.Name, PkgName(Stream), A.Level)
    return Stream
end

local function SetWanted(S, On)
    pcall(function() S:SetShouldBeLoaded(On) end)
    pcall(function() S:SetShouldBeVisible(On) end)
end

---------------------------------------------------------------------------------------------------------------------
-- Hiding
---------------------------------------------------------------------------------------------------------------------
-- "Level /Game/ITR/Levels/Hub/L_Hub.L_Hub:PersistentLevel" -> "/Game/ITR/Levels/Hub/L_Hub.L_Hub:PersistentLevel"
local function LevelPath(S)
    local Ok, P = pcall(function()
        local L = S:GetLoadedLevel()
        if not Valid(L) then return nil end
        return (L:GetFullName():gsub("^%S+%s+", ""))
    end)
    if Ok then return P, nil end
    return nil, P
end

local function HideActor(A, H, Levels)
    local LvlL = H.Level:lower()
    local S = nil
    for _, E in ipairs(Levels) do
        if PkgName(E):lower() == LvlL and IsVisible(E) then S = E; break end
    end
    if not S then return "level not visible" end
    local LP = LevelPath(S)
    if not LP then return "level not loaded" end
    local Key = H.Level .. ":" .. H.Actor
    local LevelAddr = Addr(S:GetLoadedLevel())
    if A.HiddenFor[Key] == LevelAddr then return "done" end
    local Actor = StaticFindObject(LP .. "." .. H.Actor)
    if not Valid(Actor) then
        A.HiddenFor[Key] = LevelAddr
        return "not found"
    end
    pcall(function() Actor:SetActorHiddenInGame(true) end)
    pcall(function() Actor:SetActorEnableCollision(false) end)
    A.HiddenFor[Key] = LevelAddr
    local Hidden = false
    pcall(function() Hidden = Actor.bHidden == true end)
    return Hidden and "hidden" or "hide call made (bHidden not readable)"
end

local function ApplyHides(A, Levels)
    for _, H in ipairs(A.Hide) do
        local R = HideActor(A, H, Levels)
        if R ~= "done" and R ~= "level not visible" and R ~= "level not loaded" then
            Log("add-on %s: %s %s in %s", A.Name, R == "not found" and "NOT FOUND (check the name):" or R .. ":", H.Actor, H.Level)
        end
    end
end

---------------------------------------------------------------------------------------------------------------------
-- The level watch (BP_ITRLevelWatch, in this mod's helper pak): the only way a level appearing or going reaches Lua. No hook, no timer.
---------------------------------------------------------------------------------------------------------------------
local WATCH_PATH = "/Game/Mods/ITRLevelAddons/BP_ITRLevelWatch.BP_ITRLevelWatch_C"
local WatchClass = nil
local function GetWatchClass()
    if Valid(WatchClass) then return WatchClass end
    local function Try(Fn) local Ok, O = pcall(Fn); if Ok and Valid(O) then return O end return nil end
    WatchClass = Try(function() return StaticFindObject(WATCH_PATH) end)
        or Try(function() return StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers"):GetAsset({ ObjectPath = FName(WATCH_PATH) }) end)
    return WatchClass
end

local WorldAddr = nil
local Watched = {}        -- entry address -> true (this world)
local PkgOfId = {}        -- watch id -> package (lower case)
local IdOfPkg = {}        -- package (lower case) -> watch id
local IdCount = 0
local NoPak = false

local function ResetWorld(Why)
    Watched, PkgOfId, IdOfPkg, IdCount = {}, {}, {}, 0
    for _, A in ipairs(Addons) do
        A.Stream, A.Wanted, A.Shown, A.HiddenFor = nil, false, false, {}
    end
    if Why then Log("%s", Why) end
end

local function WatchEntry(Entry, PkgL)
    local Key = tostring(Addr(Entry))
    if Watched[Key] then return true end
    local Class = GetWatchClass()
    if not Class then
        if not NoPak then NoPak = true; Log("helper pak not found (%s): add-ons off", WATCH_PATH) end
        return false
    end
    local Id = IdOfPkg[PkgL]
    if not Id then
        IdCount = IdCount + 1
        Id = "P" .. IdCount
        IdOfPkg[PkgL], PkgOfId[Id] = Id, PkgL
    end
    local World = UEHelpers.GetWorld()
    local Ok, W = pcall(function() return World:SpawnActor(Class, { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
    if not Ok or not Valid(W) then Log("level watch for %s: SpawnActor failed (%s)", PkgL, tostring(W)); return false end
    local OkW, E = pcall(function() W:Watch(Entry, Id) end)
    if not OkW then Log("level watch for %s: Watch failed (%s)", PkgL, tostring(E)); return false end
    Watched[Key] = true
    return true
end

---------------------------------------------------------------------------------------------------------------------
-- Setup: runs when a world starts (the game mode), when streaming entries appear, and when a request is taken. Idempotent.
---------------------------------------------------------------------------------------------------------------------
local function Exec(Cmd)
    local World = UEHelpers.GetWorld()
    local OkK, KSL = pcall(StaticFindObject, "/Script/Engine.Default__KismetSystemLibrary")
    if not OkK or not Valid(KSL) then return false end
    return (pcall(function() KSL:ExecuteConsoleCommand(World, Cmd, nil) end))
end

local function Setup(Why, Loud)
    if #Addons == 0 then return end
    local World = UEHelpers.GetWorld()
    if not Valid(World) then return end
    local WA = Addr(World)
    if WA ~= WorldAddr then
        local Old = WorldAddr
        WorldAddr = WA
        ResetWorld(Old and "new world: the add-on streaming entries of the old one are gone" or nil)
    end
    local Levels = StreamingLevels(World)
    for _, A in ipairs(Addons) do
        local Targets = EntriesOf(Levels, A.TargetL)
        if #Targets == 0 then
            if Loud then Log("add-on %s: %s has no streaming entry in this world: ignored for now (tried again at the next level event)", A.Name, A.Target) end
        else
            if A.Stream and not Valid(A.Stream) then A.Stream = nil end
            if not A.Stream then
                A.Stream = FindOwnEntry(Levels, A)
                if not A.Stream then
                    local S, Err = MakeEntry(World, Levels, A)
                    if not S and Loud then Log("add-on %s: %s", A.Name, Err) end
                    A.Stream = S
                end
            end
            if A.Stream then
                local OkAll = true
                for _, T in ipairs(Targets) do OkAll = WatchEntry(T, A.TargetL) and OkAll end
                OkAll = WatchEntry(A.Stream, A.LevelL) and OkAll
                for _, H in ipairs(A.Hide) do
                    local HL = H.Level:lower()
                    if HL ~= A.TargetL then
                        for _, E in ipairs(EntriesOf(Levels, HL)) do WatchEntry(E, HL) end
                    end
                end
                -- a target that is already visible gives no event: act now
                if OkAll and not A.Wanted and AnyVisible(Targets) then
                    A.Wanted = true
                    SetWanted(A.Stream, true)
                    Log("add-on %s: %s is visible; streaming %s in", A.Name, A.Target, A.Level)
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Level events (from the watch: console command 'itraddons shown|hidden <id>')
---------------------------------------------------------------------------------------------------------------------
local function OnShown(Id)
    local PkgL = PkgOfId[Id]
    if not PkgL then return end
    local World = UEHelpers.GetWorld()
    local Levels = StreamingLevels(World)
    for _, A in ipairs(Addons) do
        if A.TargetL == PkgL and not A.Wanted and A.Stream then
            A.Wanted = true
            SetWanted(A.Stream, true)
            Log("add-on %s: %s is visible; streaming %s in", A.Name, A.Target, A.Level)
        end
        if A.LevelL == PkgL and A.Wanted then
            A.Shown = true
            Log("add-on %s: %s visible", A.Name, A.Level)
            ApplyHides(A, Levels)
            if A.Notify then Exec(A.Notify .. " " .. InstanceName(A)) end
        end
        if A.Shown then
            for _, H in ipairs(A.Hide) do
                if H.Level:lower() == PkgL then ApplyHides(A, Levels) break end
            end
        end
    end
end

local function OnHidden(Id)
    local PkgL = PkgOfId[Id]
    if not PkgL then return end
    for _, A in ipairs(Addons) do
        if A.TargetL == PkgL and A.Wanted then
            A.Wanted, A.Shown, A.HiddenFor = false, false, {}
            if A.Stream then SetWanted(A.Stream, false) end
            Log("add-on %s: %s is gone; %s unloaded", A.Name, A.Target, A.Level)
        elseif A.LevelL == PkgL and A.Shown then
            A.Shown, A.HiddenFor = false, {}
            Log("add-on %s: %s was unloaded by something else while %s stays", A.Name, A.Level, A.Target)
        end
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Entry points: console commands, the game mode, new streaming entries
---------------------------------------------------------------------------------------------------------------------
-- Other mods ask for an add-on by console command ("itraddons place name=... level=... target=... [notify=verb:sub]"; values have no spaces).
-- The handler adds a record, sets it up, and answers by console command "itrmapbind placed <name>" (that is how this mod registers itself with the
-- map loader). A repeated name is refused quietly. Nothing is queued here: the caller may be inside a game-thread action (UE4SS c62ada0).
pcall(function() ModRef:SetSharedVariable("ITRLevelAddons.Place", 1) end)
if type(RegisterConsoleCommandHandler) == "function" then
    local OkC = pcall(RegisterConsoleCommandHandler, "itraddons", function(_, Params)
        local Verb = Params and Params[1] and tostring(Params[1]):lower() or ""
        if Verb == "shown" or Verb == "hidden" then
            local Id = Params[2] and tostring(Params[2]) or ""
            local Ok, E = pcall(Verb == "shown" and OnShown or OnHidden, Id)
            if not Ok then LogOnce("lverr" .. tostring(E), "level event %s %s: error %s", Verb, Id, tostring(E)) end
            return true
        end
        if Verb ~= "place" then Log("itraddons: unknown verb '%s' (use place)", Verb); return true end
        local Kv = {}
        for I = 2, (Params and #Params or 0) do
            local K, V = tostring(Params[I]):match("^([%w_]+)=(.*)$")
            if K then Kv[K] = V end
        end
        local A, Err = Manifest.FromPlace(Kv)
        if not A then Log("itraddons place REJECTED: %s", Err); return true end
        if AddAddon(A, "itraddons place") then
            Setup("place", true)
            Exec("itrmapbind placed " .. A.Name)
        end
        return true
    end)
    Log("console command 'itraddons place': %s", OkC and "registered" or "NOT registered")
end

LoadManifests()

-- A world starts: its game mode is created. Setup is queued (never run inside the notify callback itself).
local Pending = false
local function QueueSetup(Why)
    if Pending or #Addons == 0 then return end
    Pending = true
    ExecuteInGameThread(function()
        Pending = false
        local Ok, E = pcall(Setup, Why, false)
        if not Ok then LogOnce("seterr" .. tostring(E), "setup error: %s", tostring(E)) end
    end)
end
if #Addons > 0 and type(NotifyOnNewObject) == "function" then
    pcall(NotifyOnNewObject, "/Script/IntoTheRadius.PRGameMode", function(Obj)
        local Ok, Cls = pcall(function() return Obj:GetClass():GetFName():ToString() end)
        local Okn, Nm = pcall(function() return Obj:GetFName():ToString() end)
        if not (Ok and Cls == "BP_PRGameMode_C") or (Okn and Nm:sub(1, 9) == "Default__") then return end
        QueueSetup("game mode")
    end)
    -- streaming entries (the game registers one per sublevel when a world starts) are the other moment a target can appear
    pcall(NotifyOnNewObject, "/Script/Engine.LevelStreamingDynamic", function() QueueSetup("streaming entry") end)
end

Log("ready: %d add-on(s); no timers, no hooks; level watch %s", #Addons, WATCH_PATH)
