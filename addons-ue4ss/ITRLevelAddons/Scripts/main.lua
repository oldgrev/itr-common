-- ITRLevelAddons: streams small add-on levels into a stock level of Into the Radius 1 (2.7.2) while that level is visible,
-- and hides named actors of the stock level. One JSON manifest per add-on in this mod's Addons folder; any number of
-- add-ons (from any number of mods) stack, each in its own streaming entry. See README.md.
--
-- What it does, once a second on the game thread:
--   * target level visible (two checks in a row): stream the add-on level in, at the manifest's transform (default: the
--     origin, so an add-on is built in the stock level's world coordinates). The streaming entry is made once per world
--     with LevelStreaming::CreateInstance (LevelStreamingDynamic::LoadLevelInstance can't be called from UE4SS 3.0.1 Lua) and
--     reused on every later visit, so a Hub re-entry never makes a second copy;
--   * add-on visible: hide the listed actors of the stock level (hidden in game, collision off; never destroyed, so two
--     add-ons hiding the same actor is fine). Done again whenever the stock level was reloaded;
--   * target level gone (two checks in a row, e.g. the zone transfer): unload the add-on.
-- This file avoids Lua 5.4-only syntax so `luac5.1 -p` can check it.

local UEHelpers = require("UEHelpers")
local Manifest = require("manifest")
local OkCfg, Config = pcall(require, "config")
if not OkCfg or type(Config) ~= "table" then Config = {} end

local TAG = "[" .. (Config.LogTag or "ITRLevelAddons") .. "] "
local PollMs = Config.PollMs or 1000
local Debounce = Config.Debounce or 2               -- checks in a row before loading / unloading
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
local function LoadManifests()
    local Files, How = ListManifests()
    Log("Addons folder %s: %d manifest(s) (listed with %s)", AddonsDir, #Files, How)
    local Seen = {}
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
            elseif not A.Enabled then
                Log("manifest %s: %s is switched off (enabled = false)", F.Name, A.Name)
            elseif Seen[A.Name:lower()] then
                Log("manifest REJECTED: %s: the add-on name %s is already used by %s", F.Name, A.Name, Seen[A.Name:lower()])
            else
                Seen[A.Name:lower()] = F.Name
                A.TargetL = A.Target:lower()
                A.State = "idle"               -- idle | loading | visible
                A.Seen, A.Gone = 0, 0
                A.Stream, A.HiddenFor = nil, {}
                table.insert(Addons, A)
                Log("add-on %s: %s into %s, %d actor(s) to hide%s", A.Name, A.Level, A.Target, #A.Hide,
                    (A.Location[1] ~= 0 or A.Location[2] ~= 0 or A.Location[3] ~= 0 or A.Rotation[2] ~= 0)
                    and string.format(", offset (%.0f, %.0f, %.0f) yaw %.1f", A.Location[1], A.Location[2], A.Location[3], A.Rotation[2]) or "")
            end
        end
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Streaming
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

-- The visible streaming entry of the target package (nil when it isn't visible)
local function VisibleTarget(Levels, TargetL)
    for _, S in ipairs(Levels) do
        if PkgName(S):lower() == TargetL and IsVisible(S) then return S end
    end
    return nil
end

local function InstanceName(A) return "ITRAddon_" .. A.Name end

-- An entry this mod made earlier in this world (a Lua reload, or the map loader handing a Hub level back)
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
    if not Source then LogOnce("nosource", "no LevelStreamingDynamic in this world to copy; add-ons wait"); return nil end
    local Ok, Stream = pcall(function() return Source:CreateInstance(InstanceName(A)) end)
    if not Ok or not Valid(Stream) then
        Log("add-on %s: CreateInstance failed (%s)", A.Name, tostring(Stream))
        return nil
    end
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
-- The loop
---------------------------------------------------------------------------------------------------------------------
local WorldAddr = nil

local function Tick()
    local World = UEHelpers.GetWorld()
    if not Valid(World) then return end
    local WA = Addr(World)
    if WA ~= WorldAddr then
        if WorldAddr then Log("new world: the add-on streaming entries of the old one are gone") end
        WorldAddr = WA
        for _, A in ipairs(Addons) do
            A.Stream, A.State, A.Seen, A.Gone, A.HiddenFor = nil, "idle", 0, 0, {}
        end
    end
    local Levels = StreamingLevels(World)
    for _, A in ipairs(Addons) do
        local T = VisibleTarget(Levels, A.TargetL)
        if T then A.Seen, A.Gone = A.Seen + 1, 0 else A.Seen, A.Gone = 0, A.Gone + 1 end
        if A.Stream and not Valid(A.Stream) then A.Stream, A.State = nil, "idle" end
        if A.State == "idle" and A.Seen >= Debounce then
            A.Stream = A.Stream or FindOwnEntry(Levels, A) or MakeEntry(World, Levels, A)
            if A.Stream then
                SetWanted(A.Stream, true)
                A.State, A.T0 = "loading", os.clock()
                Log("add-on %s: %s is visible; streaming %s in", A.Name, A.Target, A.Level)
            end
        elseif A.State ~= "idle" and A.Gone >= Debounce then
            SetWanted(A.Stream, false)
            A.State, A.HiddenFor = "idle", {}
            Log("add-on %s: %s is gone; %s unloaded", A.Name, A.Target, A.Level)
        elseif A.State == "loading" then
            if IsVisible(A.Stream) then
                A.State = "visible"
                Log("add-on %s: %s visible after %.1f s", A.Name, A.Level, os.clock() - (A.T0 or os.clock()))
            elseif os.clock() - (A.T0 or 0) > 60 then
                LogOnce("slow" .. A.Name, "add-on %s: %s not visible after 60 s (is the pak installed? the package path right?)", A.Name, A.Level)
            end
        end
        if A.State == "visible" then
            if not IsVisible(A.Stream) then
                -- someone else unloaded it (the map loader's Hub teardown unloads every streaming level): don't fight over it,
                -- wait about ten checks before asking again
                A.State, A.Seen, A.HiddenFor = "idle", -8, {}
                Log("add-on %s: %s was unloaded by something else; asking again in about %d s if %s stays visible", A.Name, A.Level,
                    math.floor((8 + Debounce) * PollMs / 1000), A.Target)
            else
                ApplyHides(A, Levels)
            end
        end
    end
end

LoadManifests()

local Running, Crashes = false, 0
LoopAsync(PollMs, function()
    ExecuteInGameThread(function()
        if Running then                  -- the last tick never finished: a native error UE4SS logged and pcall did not catch
            Crashes = Crashes + 1
            Log("tick %d aborted by a native error (see the Error line above)", Crashes)
        end
        if Crashes >= 20 then return end
        Running = true
        local Ok, E = pcall(Tick)
        Running = false
        if not Ok then LogOnce("err" .. tostring(E), "error: %s", tostring(E)) end
    end)
    return Crashes >= 20
end)

Log("ready: %d add-on(s); checking every %d ms", #Addons, PollMs)
