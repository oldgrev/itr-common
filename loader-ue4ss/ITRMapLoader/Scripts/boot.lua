-- boot.lua: the form path of ITRMapLoader, Blueprint first. Lua does only what no Blueprint can:
--   * list and read the forms (no file read or folder list is Blueprint-callable);
--   * at the game mode notification (ONE step, the mod's first ExecuteInGameThread): load the Blueprint classes, spawn one actor per map (BP_ITRMapEntry), one per trigger
--     (BP_ITRTrigger) and the manager (BP_ITRMapManager), write their values, call Start on each, and hand the add-on requests to ITRLevelAddons;
--   * register the maps with the game once ("itrmaps register", asked by the manager at the first level change), and print the lines the Blueprints ask for ("itrmaps log").
-- After that nothing here runs: the Blueprints own every trigger, entry, exit, arrival and return point. No hook, no timer, no loop, no console command at the moment of a trigger.
-- Nothing is kept between events (no object, no class): every look-up is made again.
-- Lua 5.1 compatible syntax (checked with luac5.1 -p).

local Forms = require("forms")
local UEHelpers = require("UEHelpers")

local M = { Maps = {}, Groups = {} }     -- Groups: always empty (the add-on requests go to ITRLevelAddons, not through here)
local Api = nil
local Logf = function(fmt, ...) print("[ITRMapLoader] " .. string.format(fmt, ...) .. "\n") end
local function Log(fmt, ...) Logf(fmt, ...) end
local ByName = {}

local ENTRY_PATH = "/Game/Mods/ITRMapLoader/BP_ITRMapEntry.BP_ITRMapEntry_C"
local TRIGGER_PATH = "/Game/Mods/ITRMapLoader/BP_ITRTrigger.BP_ITRTrigger_C"
local MANAGER_PATH = "/Game/Mods/ITRMapLoader/BP_ITRMapManager.BP_ITRMapManager_C"
local REGIONS_PATH = "/Game/Mods/ITRMapLoader/BP_ITRRegions.BP_ITRRegions_C"

local function Valid(o)
    if o == nil then return false end
    local Ok, V = pcall(function() return o:IsValid() end)
    return Ok and V == true
end
local function ShortName(P) return tostring(P):match("([^/%.]+)$") or tostring(P) end

-- Every *.json in Content/Paks/ITRMaps (IterateGameDirectories lists files without starting a process, and lists symlinks: Vortex installs by symlink)
local function ListForms()
    local Out, How = {}, nil
    local Ok, Tree = pcall(IterateGameDirectories)
    if Ok and type(Tree) == "table" then
        local Chain = { "Content", "Paks", "ITRMaps" }
        local Roots = {}
        if type(Tree.Game) == "table" then table.insert(Roots, Tree.Game) end
        for K, V in pairs(Tree) do
            if K ~= "Game" and type(V) == "table" then table.insert(Roots, V) end
        end
        for I = 1, #Roots do
            local OkI, Inner = pcall(function() return Roots[I].IntoTheRadius end)
            if OkI and type(Inner) == "table" then table.insert(Roots, Inner) end
        end
        for _, Root in ipairs(Roots) do
            local D = Root
            for _, Part in ipairs(Chain) do
                if type(D) ~= "table" then break end
                local OkD, Next = pcall(function() return D[Part] end)
                D = OkD and Next or nil
            end
            if type(D) == "table" and type(D.__files) == "table" then
                local Dir = tostring(D.__absolute_path or "")
                for _, F in pairs(D.__files) do
                    local Name = type(F) == "table" and F.__name or nil
                    local Path = type(F) == "table" and F.__absolute_path or nil
                    if type(Name) == "string" and Name:lower():match("%.json$") then table.insert(Out, { Name = Name, Path = Path or (Dir .. "/" .. Name) }) end
                end
                How = Dir
                break
            end
        end
    end
    return Out, How
end

function M.Init(A)
    Api = A or {}
end

-- Reads the forms. Returns the maps main.lua registers with the game itself (forms without enter.command).
function M.Read()
    M.Maps, ByName = {}, {}
    local List, How = ListForms()
    Log("forms folder %s: %d file(s)", How or "Content/Paks/ITRMaps (not found)", #List)
    local Fs, Lines, Refused = Forms.Load(List)
    for _, Ln in ipairs(Lines) do Log("%s", Ln) end
    local UsedLevel = {}
    for _, F in ipairs(Fs) do
        local Map = Forms.ToMap(F)
        Map.Form = F
        local Short = ShortName(Map.Level):lower()
        if not Map.Handback and UsedLevel[Short] then
            Refused = Refused + 1
            Log("form %s refused: the level name %s is already used by map %s", F.File, Short, UsedLevel[Short])
        else
            if not Map.Handback then UsedLevel[Short] = Map.Name end
            table.insert(M.Maps, Map)
            ByName[Map.Name:lower()] = Map
            Log("map %s found: '%s', level %s, %s", Map.Name, Map.DisplayName, Map.Level,
                Map.Handback and ("hands back to '" .. Map.Command .. " enter " .. Map.Name .. "'") or "entered by ITRMapLoader")
            if not Map.Regions and #F.Levels == 0 and not Map.Handback then Log("map %s: no way in", Map.Name) end
            if #F.Exits == 0 and not Map.Handback then Log("map %s: no exit trigger", Map.Name) end
            if Map.Handback and #F.Exits > 0 then Log("map %s: its exit triggers do nothing: a form with enter.command is entered and left by that mod", Map.Name) end
        end
    end
    table.sort(M.Maps, function(A, B)
        local a, b = A.DisplayName:lower(), B.DisplayName:lower()
        if a ~= b then return a < b end
        return A.Name:lower() < B.Name:lower()
    end)
    Log("%d form map(s) accepted, %d refused, %d trigger level(s)", #M.Maps, Refused, 0)
    local Own = {}
    for _, Map in ipairs(M.Maps) do if not Map.Handback then table.insert(Own, Map) end end
    return Own
end

function M.ByName(Name) return ByName[tostring(Name or ""):lower()] end

-- Is this level in an installed pak? true / false, or nil when it cannot be told
function M.LevelInstalled(Level)
    local Okl, Lib = pcall(StaticFindObject, "/Script/Engine.Default__BlueprintPathsLibrary")
    if not (Okl and Valid(Lib)) then return nil end
    local Path = "../../../IntoTheRadius/Content/" .. Level:gsub("^/Game/", "") .. ".umap"
    local Ok, Exists = pcall(function() return Lib:FileExists(Path) end)
    if Ok and (Exists == true or Exists == false) then return Exists end
    return nil
end

local Checked = false
function M.CheckInstalled()
    if Checked then return end
    if M.LevelInstalled("/Game/Engine/Nothing") == nil then return end
    Checked = true
    for _, Map in ipairs(M.Maps) do
        if M.LevelInstalled(Map.Level) == false then
            Map.Missing = true
            Log("map %s: level %s not installed: not listed", Map.Name, Map.Level)
        end
    end
end

-- The maps the Regions page lists: the form maps that asked for it and whose level is installed
function M.Listed()
    local Out = {}
    for _, Map in ipairs(M.Maps) do
        if Map.Regions and not Map.Missing then table.insert(Out, Map) end
    end
    return Out
end

local function FindAll(ClassName)
    local Out = {}
    local Ok, List = pcall(FindAllOf, ClassName)
    if not Ok or type(List) ~= "table" then return Out end
    for _, O in ipairs(List) do
        if Valid(O) then
            local OkN, N = pcall(function() return O:GetFName():ToString() end)
            if OkN and N:sub(1, 9) ~= "Default__" then table.insert(Out, O) end
        end
    end
    return Out
end

-- A row press (regions.lua) or a console command: the map's entry, found again by its MapName
function M.EnterMap(Map, Why, Anywhere)
    if Map.Missing then Log("map %s: %s ignored: level not installed", Map.Name, Why); return false end
    for _, E in ipairs(FindAll("BP_ITRMapEntry_C")) do
        local Ok, N = pcall(function() return E.MapName:ToString() end)
        if Ok and N == Map.Name then
            local OkE, Err = pcall(function() E:Enter() end)
            if not OkE then Log("map %s: %s: Enter failed: %s", Map.Name, Why, tostring(Err)) end
            return OkE
        end
    end
    Log("map %s: %s ignored: its entry is not up", Map.Name, Why)
    return false
end

-- No-ops kept for main.lua's config route and regions.lua (the form path has no state of its own)
function M.OnLevelEvent() end
function M.ForgetBinds() end
function M.OnArrived() end
function M.ReturnStart() return nil end

---------------------------------------------------------------------------------------------------------------------
-- The one step
---------------------------------------------------------------------------------------------------------------------
local function GetClass(Path)
    local Ok, C = pcall(function() return StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers"):GetAsset({ ObjectPath = FName(Path) }) end)
    if Ok and Valid(C) then return C end
    return nil
end

local function Spawn(Class)
    local Ok, A = pcall(function() return UEHelpers.GetWorld():SpawnActor(Class, { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
    if Ok and Valid(A) then return A end
    return nil
end

local function Write(Actor, Fields)
    for K, V in pairs(Fields) do
        local Ok, E = pcall(function() Actor[K] = V end)
        if not Ok then Log("write %s failed: %s", K, tostring(E)) end
    end
end

local function Tag(Name) return { TagName = FName(Name) } end

-- Called once, from main.lua's game mode notification, as the mod's first ExecuteInGameThread
function M.Step()
    M.CheckInstalled()
    local EntryC, TriggerC, ManagerC = GetClass(ENTRY_PATH), GetClass(TRIGGER_PATH), GetClass(MANAGER_PATH)
    if not (EntryC and TriggerC and ManagerC) then
        Log("helper pak not found (zzz_ITRMap_ITRMapLoader_P.pak): form maps do nothing. Install it in Content/Paks/~mods.")
        return
    end
    local Mgr = Spawn(ManagerC)
    if not Mgr then Log("manager could not be spawned"); return end
    -- the add-on requests of every trigger level, de-duplicated by level + target
    local Requests, Seen = {}, {}
    local Entries = {}
    for _, Map in ipairs(M.Maps) do
        if not Map.Missing then
            local F = Map.Form
            local E = Spawn(EntryC)
            if E then
                Entries[Map.Name] = E
                Write(E, { MapName = Map.Name, Display = Map.DisplayName or Map.Name, LevelTag = Tag(Map.NativeTag or ("Level.Zone." .. Map.Name)),
                    ReturnKey = Map.ReturnKey or "", Command = Map.Command or "", Handback = Map.Handback and true or false })
                if Map.NativeStart then
                    Write(E, { HasStart = true, StartLoc = { X = Map.NativeStart.X, Y = Map.NativeStart.Y, Z = Map.NativeStart.Z }, StartYaw = Map.NativeStart.Yaw or 0 })
                end
                pcall(function() E:Start() end)
            end
        end
    end
    local function MakeTrigger(Map, Rec, Kind, StreamName)
        local T = Spawn(TriggerC)
        if not T then return nil end
        Write(T, { Kind = Kind, Grab = Rec.Type == "grab", ObjectName = Rec.ObjectName, StreamName = StreamName, Entry = Entries[Map.Name],
            Where = string.format("map %s %s%s trigger '%s'", Map.Name, Kind == 0 and "exit " or "", Rec.Type, Rec.ObjectName) })
        return T
    end
    for _, Map in ipairs(M.Maps) do
        local F = Map.Form
        if not Map.Missing and not Map.Handback and Entries[Map.Name] then
            for _, Rec in ipairs(F.Exits) do
                local T = MakeTrigger(Map, Rec, 0, ShortName(Map.Level))
                if T then
                    if Rec.To and not Rec.To:find(".", 1, true) then
                        local D = M.ByName(Rec.To)
                        if D and not D.Missing and Entries[D.Name] then Write(T, { Dest = Entries[D.Name] })
                        else
                            Write(T, { ToMissing = true, Note = string.format("map %s exit trigger %s: map '%s' is not installed: ignored", Map.Name, Rec.ObjectName, Rec.To) })
                        end
                        if D and Rec.At then Log("map %s exit trigger %s: 'at' ignored: map %s uses its start or return point", Map.Name, Rec.ObjectName, Rec.To) end
                        if not D then Log("map %s exit trigger %s: no map named '%s': it will do nothing", Map.Name, Rec.ObjectName, Rec.To) end
                    elseif Rec.To then
                        Write(T, { HasTo = true, ToTag = Tag(Rec.To) })
                        if type(Rec.At) == "string" then Write(T, { AtGate = Tag(Rec.At) })
                        elseif type(Rec.At) == "table" then Write(T, { HasAtPos = true, AtLoc = { X = Rec.At.X, Y = Rec.At.Y, Z = Rec.At.Z }, AtYaw = Rec.At.Yaw or 0 })
                        else Log("map %s exit trigger %s: no 'at': the game picks where in %s", Map.Name, Rec.ObjectName, Rec.To) end
                    end
                    pcall(function() T:Start() end)
                end
            end
            for _, G in ipairs(F.Levels) do
                local Name = ShortName(G.Level) .. "_" .. ShortName(G.Target)
                if not Seen[Name] then
                    Seen[Name] = true
                    table.insert(Requests, { Name = Name, Level = G.Level, Target = G.Target })
                end
                for _, Rec in ipairs(G.Triggers) do
                    local T = MakeTrigger(Map, Rec, 1, "ITRAddon_" .. Name)
                    if T then pcall(function() T:Start() end) end
                end
            end
        end
    end
    -- the Regions page: one Blueprint actor holds the rows' text; the one Construct hook (regions.lua) hands it the Hub computer's page when it is built
    local Listed = M.Listed()
    -- a config map with Regions = true is a row too: its entry is a hand-back (its press runs "<ConsoleCommand> enter <name>", the config route's own command)
    local ConfigRows = {}
    local Cmd = Api and Api.Command
    if Cmd == nil then Cmd = "itrmap" end
    if type(Api and Api.ConfigMaps) == "table" and Cmd then
        for _, CM in ipairs(Api.ConfigMaps) do
            if CM.Regions == true and type(CM.Name) == "string" then
                if M.ByName(CM.Name) then
                    Log("config map %s is not listed: a form with the same name wins", CM.Name)
                else
                    local E = Spawn(EntryC)
                    if E then
                        Write(E, { MapName = CM.Name, Display = CM.DisplayName or CM.Name, Command = Cmd, Handback = true })
                        pcall(function() E:Start() end)
                        table.insert(ConfigRows, { Name = CM.Name, DisplayName = CM.DisplayName or CM.Name, Desc = CM.RegionsDesc })
                    end
                end
            end
        end
    elseif type(Api and Api.ConfigMaps) == "table" then
        for _, CM in ipairs(Api.ConfigMaps) do
            if CM.Regions == true then Log("config map %s is not listed: ConsoleCommand is false, so nothing can enter it from Regions", tostring(CM.Name)) end
        end
    end
    for _, R in ipairs(ConfigRows) do table.insert(Listed, R) end
    if #Listed > 0 then
        local RegionsC = GetClass(REGIONS_PATH)
        local Rg = RegionsC and Spawn(RegionsC) or nil
        if Rg then
            local Rows = {}
            for _, Map in ipairs(Listed) do
                local Text = string.upper(Map.DisplayName or Map.Name)
                if Map.Desc then Text = Text .. "\n" .. Map.Desc end
                Rows[#Rows + 1] = Map.Name .. string.char(31) .. Text
            end
            Write(Rg, { Rows = table.concat(Rows, string.char(30)) })
            local OkR, Reg = pcall(require, "regions")
            if OkR then Reg.Hook() else Log("regions: not started: %s", tostring(Reg)) end
            Log("regions: %d map(s) listed", #Listed)
        else
            Log("regions: BP_ITRRegions not found in the helper pak: no REGIONS row")
        end
    end
    -- the handshake with ITRLevelAddons: whichever starts second does the whole exchange (see ITRLevelAddons' main.lua)
    local Text = {}
    for _, R in ipairs(Requests) do Text[#Text + 1] = R.Name .. "|" .. R.Level .. "|" .. R.Target end
    Write(Mgr, { Requests = table.concat(Text, ";") })
    pcall(function() Mgr:Start() end)
    if #Requests > 0 then
        local A = nil
        for _, O in ipairs(FindAll("BP_ITRLevelAddons_C")) do A = O end
        if A then
            for _, R in ipairs(Requests) do
                pcall(function() A:Place("ITRAddon_" .. R.Name, R.Level, ShortName(R.Target), "", "", { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 }) end)
            end
            Log("%d trigger level request(s) handed to ITRLevelAddons", #Requests)
        else
            Log("%d trigger level request(s) waiting for ITRLevelAddons (it hands them over when it starts)", #Requests)
        end
    end
    Log("form path ready: %d map(s)", #M.Maps)
end

-- Console verbs (Blueprints reach Lua only through these two): itrmaps register | itrmaps log <text> | itrmaps enter <MapName>
function M.Console(Params)
    local Verb = Params and Params[1] and tostring(Params[1]):lower() or ""
    if Verb == "register" then
        if Api and Api.Register then Api.Register() end
    elseif Verb == "log" then
        local T = {}
        for I = 2, #Params do T[#T + 1] = tostring(Params[I]) end
        Log("%s", table.concat(T, " "))
    elseif Verb == "enter" then
        local Map = M.ByName(Params[2])
        if not Map then return false end
        M.EnterMap(Map, "console command", true)
    else
        return false
    end
    return true
end

return M
