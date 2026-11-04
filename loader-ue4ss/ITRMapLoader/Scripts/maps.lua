-- maps.lua: map forms in ITRMapLoader. A map maker hands over a pak and one small text file (forms.lua has the fields); this module is what makes
-- that enough:
--   * reads every form in Content/Paks/ITRMaps and turns it into a map record main.lua registers and enters (no mod, no Lua of the author's);
--   * asks ITRLevelAddons, from the game's level events, to stream the levels the form's triggers live in ("itraddons place ..."), and goes on
--     asking at each next level event until it hears the reply "itrmapbind placed <name>" (so the start order of the two mods does not matter);
--   * binds the author's named objects when ITRLevelAddons says the level is shown ("itrmapbind shown <entry>"): bind.lua;
--   * runs the one function every way in uses when a trigger fires ("itrmapbind fire <id>"): the same call as a Regions row;
--   * the return point: written when the player leaves through an exit trigger, read when they come back.
-- Every failure is silent for the player and one log line. Events only: no timer, no loop, nothing queued from inside an action (A.00).
-- Lua 5.1 compatible syntax (checked with luac5.1 -p).

local M = {}

local Forms = require("forms")
local Bind = require("bind")

local function Log(fmt, ...) print("[ITRMapLoader] " .. string.format(fmt, ...) .. "\n") end
local function Valid(o)
    if o == nil then return false end
    local Ok, V = pcall(function() return o:IsValid() end)
    return Ok and V == true
end

M.Maps = {}                    -- every accepted form map (record from Forms.ToMap), sorted by display name
M.Groups = {}                  -- the trigger levels: { Map, Level, Target, Name, Instance, Triggers }
local ByName, GroupByName, GroupByInstance, TrigById = {}, {}, {}, {}
local Api = nil
local Heard, Warned = false, false
local Bound = {}                -- trigger id -> address of the level it is bound in
local LoggedMissing = {}

local function Norm(P) return (tostring(P or ""):gsub("\\", "/"):gsub("/%./", "/"):gsub("/+", "/"):lower()) end

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
                    if type(Name) == "string" and Name:lower():match("%.json$") and not Name:lower():match("%.loot%.json$") then
                        table.insert(Out, { Name = Name, Path = Path or (Dir .. "/" .. Name) })
                    end
                end
                How = Dir
                break
            end
        end
    end
    return Out, How
end

-- Reads the forms. Returns the maps main.lua enters itself (forms without enter.command).
function M.Read()
    M.Maps, M.Groups = {}, {}
    ByName, GroupByName, GroupByInstance, TrigById = {}, {}, {}, {}
    local List, How = ListForms()
    Log("forms folder %s: %d file(s)", How or "Content/Paks/ITRMaps (not found)", #List)
    local Fs, Lines, Refused = Forms.Load(List)
    for _, Ln in ipairs(Lines) do Log("%s", Ln) end
    local UsedLevel, NextId = {}, 0
    for _, F in ipairs(Fs) do
        local Map = Forms.ToMap(F)
        local Short = (Map.Level:match("([^/]+)$") or Map.Level):lower()
        if not Map.Handback and UsedLevel[Short] then
            Refused = Refused + 1
            Log("form %s refused: the level name %s is already used by map %s", F.File, Short, UsedLevel[Short])
        else
            if not Map.Handback then UsedLevel[Short] = Map.Name end
            table.insert(M.Maps, Map)
            ByName[Map.Name:lower()] = Map
            Log("map %s found: '%s', level %s, %s", Map.Name, Map.DisplayName, Map.Level,
                Map.Handback and ("hands back to '" .. Map.Command .. " enter " .. Map.Name .. "'") or "entered by ITRMapLoader")
            for Gi, G in ipairs(F.Levels) do
                local Group = { Map = Map, Level = G.Level, Target = G.Target, Name = string.format("ITRMapLevel_%s_%d", Map.Name, Gi), Triggers = {} }
                Group.Instance = "ITRAddon_" .. Group.Name
                for _, T in ipairs(G.Triggers) do
                    NextId = NextId + 1
                    local Rec = { Id = "T" .. NextId, Kind = "level", Type = T.Type, ObjectName = T.ObjectName, Map = Map, Group = Group }
                    TrigById[Rec.Id] = Rec
                    table.insert(Group.Triggers, Rec)
                end
                GroupByName[Group.Name], GroupByInstance[Group.Instance] = Group, Group
                table.insert(M.Groups, Group)
            end
            Map.ExitRecs = {}
            for _, T in ipairs(F.Exits) do
                NextId = NextId + 1
                local Rec = { Id = "T" .. NextId, Kind = "exit", Type = T.Type, ObjectName = T.ObjectName, Map = Map }
                TrigById[Rec.Id] = Rec
                table.insert(Map.ExitRecs, Rec)
            end
            if not Map.Regions then Log("map %s: no Regions row", Map.Name) end
            if not Map.Regions and #F.Levels == 0 and not Map.Handback then Log("map %s: no way in", Map.Name) end
            if #F.Exits == 0 and not Map.Handback then Log("map %s: no exit trigger", Map.Name) end
        end
    end
    table.sort(M.Maps, function(A, B)
        local a, b = A.DisplayName:lower(), B.DisplayName:lower()
        if a ~= b then return a < b end
        return A.Name:lower() < B.Name:lower()
    end)
    Log("%d form map(s) accepted, %d refused, %d trigger level(s)", #M.Maps, Refused, #M.Groups)
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

-- Once, at the first level event: a map whose level is not installed has no row, no registration and no triggers.
local InstalledChecked = false
function M.CheckInstalled()
    if InstalledChecked then return end
    if M.LevelInstalled("/Game/Engine/Nothing") == nil then return end        -- cannot tell yet; try at the next event
    InstalledChecked = true
    for _, Map in ipairs(M.Maps) do
        if M.LevelInstalled(Map.Level) == false then
            Map.Missing = true
            Log("map %s: level %s not installed: not listed", Map.Name, Map.Level)
        end
    end
    for _, G in ipairs(M.Groups) do
        if not G.Map.Missing and M.LevelInstalled(G.Level) == false then
            G.Missing = true
            Log("map %s trigger level %s not installed: ignored", G.Map.Name, G.Level)
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

-- Enter a map: a form with enter.command hands back to that mod; the others go through the loader's own entry. Anywhere = a trigger in
-- a zone fired (a Regions row is always pressed in the Hub).
function M.EnterMap(Map, Why, Anywhere)
    if Map.Missing then Log("map %s: %s ignored: level not installed", Map.Name, Why); return false end
    if Map.Handback then
        Log("entering %s (%s): %s enter %s", Map.Name, Why, Map.Command, Map.Name)
        return Api.Exec(Map.Command .. " enter " .. Map.Name)
    end
    return Api.EnterNative(Map, Why, Anywhere)
end

---------------------------------------------------------------------------------------------------------------------
-- Level events: the requests to ITRLevelAddons
---------------------------------------------------------------------------------------------------------------------
-- Called inline from the game mode's level hooks (OnLevelPrepare, OnLevelStarted, OnTransitionEnd, OnEnteredMenu). Sends "itraddons place" for
-- every trigger level until a reply has been heard; the reply "itrmapbind placed <name>" comes back inside the send. A send at mod start or at the
-- game mode's creation is not heard (measured), a send from inside a level event is.
function M.OnLevelEvent(What)
    if #M.Groups == 0 then return end
    M.CheckInstalled()
    if Heard then return end
    local Sent = 0
    for _, G in ipairs(M.Groups) do
        if G.Map.Missing or G.Missing then
            -- logged once by CheckInstalled
        else
            Api.Exec(string.format("itraddons place name=%s level=%s target=%s notify=itrmapbind:shown", G.Name, G.Level, G.Target))
            Sent = Sent + 1
        end
    end
    if What == "OnTransitionEnd" and not Heard and Sent > 0 and not Warned then
        Warned = true
        Log("ITRLevelAddons not heard: %d trigger level(s) not streamed (they are asked for again at each level event)", Sent)
    end
end

---------------------------------------------------------------------------------------------------------------------
-- Return point: PRGameData.CustomMarkers keeps one string per key, "ITRReturn:<key>=x,y,z,yaw". The key is used exactly as the form wrote it.
---------------------------------------------------------------------------------------------------------------------
local PREFIX = "ITRReturn:"
local function MarkersWith(GD, Key)
    local Out, Want = {}, PREFIX .. Key .. "="
    pcall(function()
        local A = GD.CustomMarkers
        for I = 1, #A do
            local S = A[I]:ToString()
            if S:sub(1, #Want) == Want then table.insert(Out, S) end
        end
    end)
    return Out, Want
end

-- The stored return point of a map: { X, Y, Z, Yaw } or nil (no key, nothing stored, or unusable: the map's start is used and a line says why)
function M.ReturnStart(Map)
    if not Map.ReturnKey then return nil end
    local GD = Api.GameData()
    if not GD then Log("map %s: return point not readable (no game data): using start", Map.Name); return nil end
    local List, Want = MarkersWith(GD, Map.ReturnKey)
    if #List == 0 then Log("map %s: no return point: using start", Map.Name); return nil end
    local S = List[#List]
    local X, Y, Z, Yaw = S:sub(#Want + 1):match("^(-?[%d%.]+),(-?[%d%.]+),(-?[%d%.]+),(-?[%d%.]+)$")
    if not X then Log("map %s: return point '%s' not usable: using start", Map.Name, S); return nil end
    Log("map %s: return point %s", Map.Name, S)
    return { X = tonumber(X), Y = tonumber(Y), Z = tonumber(Z), Yaw = tonumber(Yaw) }
end

-- Written when the player leaves through an exit trigger: where they stand now. Older values of the key are removed.
function M.StoreReturn(Map)
    if not Map.ReturnKey then return end
    local GD = Api.GameData()
    local L, Yaw = Api.PawnLoc(), Api.PawnYaw()
    if not GD or not L then Log("map %s: return point not saved (no game data or pawn)", Map.Name); return end
    local Text = string.format("%s%s=%.1f,%.1f,%.1f,%.1f", PREFIX, Map.ReturnKey, L.X, L.Y, L.Z, Yaw or 0)
    local Old = MarkersWith(GD, Map.ReturnKey)
    local Ok, Err = pcall(function()
        for _, S in ipairs(Old) do GD:UpdateMarker(S, true) end
        GD:UpdateMarker(Text, false)
    end)
    if Ok then Log("map %s: return point saved: %s", Map.Name, Text) else Log("map %s: return point not saved (%s)", Map.Name, tostring(Err)) end
end

---------------------------------------------------------------------------------------------------------------------
-- Binding and firing
---------------------------------------------------------------------------------------------------------------------
-- ITRLevelAddons says a trigger level is shown: bind the objects the form names in it
local function OnShown(Instance)
    local G = GroupByInstance[Instance]
    if not G then return end
    if G.Map.Missing then return end
    local Entry = Api.EntryByInstance(Instance)
    if not Entry then Log("map %s: the entry %s is not in this world: nothing to bind", G.Map.Name, Instance); return end
    Bind.Attach(Entry, G.Triggers, Bound, G.Level)
end

-- A map was entered and its level is up: bind its exit triggers (objects in the map's own level)
function M.OnArrived(Map)
    if not Map.ExitRecs or #Map.ExitRecs == 0 then return end
    local Entry = Api.StreamOf(Map)
    if not Entry then Log("map %s: its streaming entry is not found: exit triggers not bound", Map.Name); return end
    Bind.Attach(Entry, Map.ExitRecs, Bound, Map.Level)
end

-- A trigger fired (from the helper). The same function a Regions row calls.
local function OnFire(Id)
    local Rec = TrigById[Id]
    if not Rec then Log("fire for unknown trigger %s: ignored", tostring(Id)); return end
    if Rec.Kind == "level" then
        M.EnterMap(Rec.Map, "trigger " .. Rec.ObjectName, true)
    else
        if Api.CurrentMap() ~= Rec.Map then
            Log("map %s: exit trigger %s fired while the map is not active: ignored", Rec.Map.Name, Rec.ObjectName)
            return
        end
        Log("map %s: exit trigger %s fired", Rec.Map.Name, Rec.ObjectName)
        M.StoreReturn(Rec.Map)
        Api.Leave("exit trigger " .. Rec.ObjectName)
    end
end

-- One list of the maps and triggers, for tooling: itrmapbind list
local function List()
    Log("%d form map(s), %d trigger level(s); ITRLevelAddons heard: %s", #M.Maps, #M.Groups, tostring(Heard))
    for _, Map in ipairs(M.Maps) do
        Log("  %s: level %s, %s, regions %s, return key %s%s", Map.Name, Map.Level, Map.Handback and "hands back" or "loader entered",
            tostring(Map.Regions), tostring(Map.ReturnKey), Map.Missing and ", NOT INSTALLED" or "")
    end
end

function M.Init(A)
    Api = A
    Bind.SetLog(Log)
    if type(RegisterConsoleCommandHandler) ~= "function" then return end
    local Ok = pcall(RegisterConsoleCommandHandler, "itrmapbind", function(_, Params)
        local Verb = Params and Params[1] and tostring(Params[1]):lower() or ""
        local Arg = Params and Params[2] and tostring(Params[2]) or ""
        local OkH, E = pcall(function()
            if Verb == "placed" then
                if not Heard then
                    Heard = true
                    if Warned then Log("ITRLevelAddons heard after all (reply for %s)", Arg) end
                end
                local G = GroupByName[Arg]
                if G then Log("level for %s asked for and taken: %s into %s", G.Map.Name, G.Level, G.Target) end
            elseif Verb == "shown" then OnShown(Arg)
            elseif Verb == "fire" then OnFire(Arg)
            elseif Verb == "list" then List()
            else Log("itrmapbind: unknown verb '%s'", Verb) end
        end)
        if not OkH then Log("itrmapbind %s %s: error %s", Verb, Arg, tostring(E)) end
        return true            -- inline: nothing is queued here
    end)
    Log("console command 'itrmapbind placed|shown|fire|list': %s", Ok and "registered" or "NOT registered")
end

return M
