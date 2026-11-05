-- ITRLevelAddons: streams small add-on levels into a stock level of Into the Radius 1 (2.7.2) while that level is visible,
-- and hides named actors of the stock level. One JSON manifest per add-on in this mod's Addons folder (or "itraddons place" from another mod);
-- any number of add-ons (from any number of mods) stack, each in its own streaming entry. See README.md.
--
-- Blueprint first: the Blueprints in zzz_ITRMap_ITRLevelAddons_P.pak do the work (BP_ITRLevelAddon: the streaming entry, the follow-the-target switching and the hiding;
-- BP_ITRLevelAddons: the manager that makes them). This file only lists the manifests (no Blueprint can read a file), makes the manager once, hands it every
-- add-on, finds ITRMapLoader's manager and does the same for the levels it asked for, and answers "itraddons place". After that it does nothing:
-- no timer, no loop, no hook, and its one ExecuteInGameThread is made from the game mode notification.
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
-- The Blueprints
---------------------------------------------------------------------------------------------------------------------
local MANAGER_PATH = "/Game/Mods/ITRLevelAddons/BP_ITRLevelAddons.BP_ITRLevelAddons_C"

local function ShortName(Pkg) return tostring(Pkg):match("([^/%.]+)$") or tostring(Pkg) end

-- The first object of a Blueprint class (not its default object), or nil
local function FindOne(ClassName)
    local Ok, List = pcall(FindAllOf, ClassName)
    if not Ok or type(List) ~= "table" then return nil end
    for _, O in ipairs(List) do
        if Valid(O) then
            local OkN, N = pcall(function() return O:GetFName():ToString() end)
            if OkN and N:sub(1, 9) ~= "Default__" then return O end
        end
    end
    return nil
end

-- Looked up every time, never kept: nothing holds a pak-only class once its last instance is gone
local function SpawnManager()
    local Ok, M = pcall(function()
        local Cls = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers"):GetAsset({ ObjectPath = FName(MANAGER_PATH) })
        if not Valid(Cls) then return nil end
        return UEHelpers.GetWorld():SpawnActor(Cls, { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if Ok and Valid(M) then return M end
    return nil
end

-- One add-on to the manager. The manager makes a BP_ITRLevelAddon (a name it has already placed is ignored) and leaves its report in LastReport.
local function PlaceOne(Mgr, A)
    local Hides, Levels, SeenLevel = {}, {}, { [ShortName(A.Target)] = true }
    for _, H in ipairs(A.Hide or {}) do
        local L = ShortName(H.Level)
        Hides[#Hides + 1] = L .. ":PersistentLevel." .. H.Actor
        if not SeenLevel[L] then SeenLevel[L] = true; Levels[#Levels + 1] = L end       -- a hide in a level other than the target: that level's entry is listened to too
    end
    local Loc, Rot, Scale = A.Location or { 0, 0, 0 }, A.Rotation or { 0, 0, 0 }, A.Scale or { 1, 1, 1 }
    local Ok, E = pcall(function()
        Mgr:Place("ITRAddon_" .. A.Name, A.Level, ShortName(A.Target), table.concat(Hides, ","), table.concat(Levels, ","),
            { X = Loc[1], Y = Loc[2], Z = Loc[3] }, { Pitch = Rot[1], Yaw = Rot[2], Roll = Rot[3] }, { X = Scale[1], Y = Scale[2], Z = Scale[3] })
    end)
    if not Ok then Log("add-on %s: Place failed: %s", A.Name, tostring(E)); return end
    local Report = ""
    pcall(function() Report = Mgr.LastReport:ToString() end)
    if Report ~= "" then Log("add-on %s: %s", A.Name, Report) else Log("add-on %s placed", A.Name) end
end

local Stepped = false

-- ITRMapLoader's requests ("name|level|target;name|level|target"): written on its manager when it started first
local function TakeLoaderRequests(Mgr)
    local M = FindOne("BP_ITRMapManager_C")
    if not M then return end
    local Text = ""
    pcall(function() Text = M.Requests:ToString() end)
    for Entry in Text:gmatch("[^;]+") do
        local Name, Level, Target = Entry:match("^([^|]+)|([^|]+)|([^|]+)$")
        if Name then
            local A = { Name = Name, Level = Level, Target = Target, Hide = {}, Location = { 0, 0, 0 }, Rotation = { 0, 0, 0 } }
            PlaceOne(Mgr, A)
        end
    end
end

-- The one step: at the game mode notification. Runs once; the manager and every add-on are made here.
local function Step()
    if Stepped then return end
    Stepped = true
    local Mgr = SpawnManager()
    if not Mgr then Log("helper pak not found (%s): nothing is streamed. Install zzz_ITRMap_ITRLevelAddons_P.pak.", MANAGER_PATH); return end
    for _, A in ipairs(Addons) do PlaceOne(Mgr, A) end
    TakeLoaderRequests(Mgr)
    Log("ready: %d add-on(s) placed", #Addons)
end

LoadManifests()
local Primed = false
NotifyOnNewObject("/Script/IntoTheRadius.PRGameMode", function(Obj)
    if Primed then return end
    local Ok, Cls = pcall(function() return Obj:GetClass():GetFName():ToString() end)
    local Okn, Nm = pcall(function() return Obj:GetFName():ToString() end)
    if not (Ok and Cls == "BP_PRGameMode_C") or (Okn and Nm:sub(1, 9) == "Default__") then return end
    Primed = true
    -- the mod's one ExecuteInGameThread: from this notification (game thread, outside any action), and it does the work
    ExecuteInGameThread(Step)
end)

-- Other mods ask for an add-on by console command ("itraddons place name=... level=... target=..."; values have no spaces), after the step has run
if type(RegisterConsoleCommandHandler) == "function" then
    local OkC = pcall(RegisterConsoleCommandHandler, "itraddons", function(_, Params)
        local Verb = Params and Params[1] and tostring(Params[1]):lower() or ""
        if Verb == "log" then      -- a line the Blueprints ask for ("itraddons log <text>"): a Blueprint cannot write to UE4SS.log
            local T = {}
            for I = 2, #Params do T[#T + 1] = tostring(Params[I]) end
            Log("%s", table.concat(T, " "))
            return true
        end
        if Verb ~= "place" then Log("itraddons: unknown verb '%s' (use place or log)", Verb); return true end
        local Kv = {}
        for I = 2, #Params do
            local K, V = tostring(Params[I]):match("^([%w_]+)=(.*)$")
            if K then Kv[K:lower()] = V end
        end
        local A, Err = Manifest.FromPlace(Kv)
        if not A then Log("itraddons place REJECTED: %s", Err); return true end
        local Mgr = FindOne("BP_ITRLevelAddons_C")
        if not Mgr then Log("itraddons place %s: the manager is not up yet", A.Name); return true end
        PlaceOne(Mgr, A)
        return true
    end)
    Log("console command 'itraddons place': %s", OkC and "registered" or "NOT registered")
end
