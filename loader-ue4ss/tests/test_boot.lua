-- Offline test of boot.lua (plain Lua 5.1, no game): run from this folder with   lua test_boot.lua
-- A stand-in of the UE4SS API: forms on disk, Blueprint classes that answer GetAsset, actors that record what is written to them and which events are called on them.
-- It proves the logic of the one step (what is spawned, written and started, the handshake in both orders, config Regions rows), not the game.
package.path = "../ITRMapLoader/Scripts/?.lua;" .. package.path

local N, Failed = 0, 0
local function Case(Name, Ok, Why)
    N = N + 1
    if Ok then io.write("ok " .. N .. " " .. Name .. "\n")
    else Failed = Failed + 1; io.write("not ok " .. N .. " " .. Name .. ": " .. tostring(Why) .. "\n") end
end

local Lines = {}
local RealPrint = print
print = function(S) table.insert(Lines, S) end
local function Logged(Pat) for _, L in ipairs(Lines) do if L:find(Pat, 1, true) then return true end end return false end

local Dir = os.tmpname():gsub("[^/\\]+$", "")
local function Write(Name, Text) local P = Dir .. "tb_" .. Name; local H = assert(io.open(P, "wb")); H:write(Text); H:close(); return P end
local Files = {
    { __name = "A.json", __absolute_path = Write("A.json", [[{ "schema": 1, "name": "MapA", "displayName": "Alpha", "description": "first", "level": "/Game/Mods/MapA/L_MapA",
        "start": { "x": 1, "y": 2, "z": 3, "yaw": 90 }, "returnpointstoragepath": "MapA_ret", "triggers": [ { "kind": "regions" },
        { "kind": "level", "level": "/Game/Mods/MapA/L_MapA_Hub", "target": "/Game/ITR/Levels/Hub/L_Hub", "type": "collision", "object": "field1" },
        { "kind": "level", "level": "/Game/Mods/MapA/L_MapA_Hub", "target": "/Game/ITR/Levels/Hub/L_Hub", "type": "grab", "object": "handle1" },
        { "kind": "exit", "type": "collision", "object": "exit1", "to": "MapE" },
        { "kind": "exit", "type": "collision", "object": "exit2", "to": "Nowhere" },
        { "kind": "exit", "type": "collision", "object": "exit3", "to": "Level.Zone.Buffer", "at": { "kind": "object", "value": "Gate.HubToBuffer" } },
        { "kind": "exit", "type": "grab", "object": "exit4", "to": "Level.Zone.Buffer", "at": { "kind": "coordinates", "value": [1, 2, 3, 90] } },
        { "kind": "exit", "type": "collision", "object": "exit5" } ] }]]) },
    { __name = "B.json", __absolute_path = Write("B.json", [[{ "schema": 1, "name": "MapB", "level": "/Game/Mods/MapB/L_MapB", "enter": { "command": "mapb" }, "triggers": [ { "kind": "regions" } ] }]]) },
    { __name = "C.json", __absolute_path = Write("C.json", [[{ "schema": 1, "name": "MapC", "level": "/Game/Mods/MapA/L_MapA" }]]) },
    { __name = "E.json", __absolute_path = Write("E.json", [[{ "schema": 1, "name": "MapE", "level": "/Game/Mods/MapE/L_MapE", "triggers": [ { "kind": "regions" } ] }]]) },
}
function IterateGameDirectories()
    return { Game = { Content = { Paks = { ITRMaps = { __name = "ITRMaps", __absolute_path = "C:/Game/Content/Paks/ITRMaps", __files = Files } } } } }
end
function FName(S) return { Str = S, ToString = function() return S end } end

-- actors: record the writes (plain fields) and the calls
local Spawned = {}
local function NewActor(Class)
    local A = { Class = Class, Calls = {} }
    A.IsValid = function() return true end
    A.GetFName = function() return FName(Class .. "_1") end
    A.Start = function() table.insert(A.Calls, "Start") end
    A.Place = function(self, ...) table.insert(A.Calls, "Place:" .. tostring((...))); return true end
    A.AddonsReady = function() table.insert(A.Calls, "AddonsReady") end
    table.insert(Spawned, A)
    return A
end
local Classes = {}
local function ClassObj(Name) local C = { Name = Name, IsValid = function() return true end }; Classes[Name] = C; return C end
local Helpers = { GetAsset = function(self, Arg)
    local P = Arg.ObjectPath.Str
    for _, K in ipairs({ "BP_ITRMapEntry", "BP_ITRTrigger", "BP_ITRMapManager", "BP_ITRRegions" }) do
        if P:find(K .. "_C", 1, true) then return ClassObj(K) end
    end
    return { IsValid = function() return false end }
end, IsValid = function() return true end }
local PathsLib = { FileExists = function(self, P) return not P:find("MapC") and not P:find("Nowhere") end, IsValid = function() return true end }
function StaticFindObject(P)
    if P:find("AssetRegistryHelpers", 1, true) then return Helpers end
    if P:find("BlueprintPathsLibrary", 1, true) then return PathsLib end
    return { IsValid = function() return false end }
end
local World = { SpawnActor = function(self, Class) return NewActor(Class.Name) end }
package.preload["UEHelpers"] = function() return { GetWorld = function() return World end } end
local Queued = 0
function ExecuteInGameThread() Queued = Queued + 1 end
local Existing = {}
function FindAllOf(Name) return Existing[Name] end
local Hooks = {}
function RegisterHook(Path) table.insert(Hooks, Path) end
package.loaded["regions"] = nil

local Boot = require("boot")
Boot.Init({ Register = function() end, ConfigMaps = { { Name = "CfgMap", DisplayName = "Config One", Regions = true }, { Name = "NoRow", Regions = false } }, Command = "itrmap" })
local Own = Boot.Read()
Case("MapA and MapE accepted (loader enters), MapB hands back, MapC refused (same level name)", #Boot.Maps == 3 and #Own == 2 and Logged("form C.json refused"), #Boot.Maps)
Case("maps sorted by display name", Boot.Maps[1].Name == "MapA")
local function Of(Class) local Out = {}; for _, A in ipairs(Spawned) do if A.Class == Class then table.insert(Out, A) end end return Out end

-- ---- the step with ITRLevelAddons absent
Boot.Step()
Case("no ExecuteInGameThread from the step", Queued == 0)
Case("one manager, one entry per accepted map (3), nothing for the refused one", #Of("BP_ITRMapManager") == 1 and #Of("BP_ITRMapEntry") == 4, #Of("BP_ITRMapEntry"))   -- 3 form maps + the config row's entry
local Entries = {}
for _, A in ipairs(Of("BP_ITRMapEntry")) do Entries[A.MapName] = A end
local EA = Entries.MapA
Case("MapA entry: values written", EA and EA.Display == "Alpha" and EA.LevelTag.TagName.Str == "Level.Zone.MapA" and EA.HasStart == true and EA.StartLoc.X == 1 and EA.StartYaw == 90 and EA.ReturnKey == "MapA_ret" and EA.Handback == false)
Case("MapA entry started", EA and EA.Calls[1] == "Start")
Case("MapB (hand-back) entry: Handback, Command", Entries.MapB and Entries.MapB.Handback == true and Entries.MapB.Command == "mapb")
Case("config row: an entry with Handback and the console command", Entries.CfgMap and Entries.CfgMap.Handback == true and Entries.CfgMap.Command == "itrmap" and Entries.NoRow == nil)
local Trig = Of("BP_ITRTrigger")
Case("MapA: 5 exit triggers and 2 level triggers spawned, none for the hand-back map", #Trig == 7, #Trig)
local ByObj = {}
for _, T in ipairs(Trig) do ByObj[T.ObjectName] = T end
Case("exit to a map: Dest is that map's entry", ByObj.exit1.Dest == Entries.MapE and ByObj.exit1.Kind == 0 and ByObj.exit1.StreamName == "L_MapA")
Case("exit to a map that does not exist: ToMissing and a note", ByObj.exit2.ToMissing == true and ByObj.exit2.Note:find("'Nowhere' is not installed", 1, true) ~= nil and Logged("no map named 'Nowhere'"))
Case("exit to a level by gate", ByObj.exit3.HasTo == true and ByObj.exit3.ToTag.TagName.Str == "Level.Zone.Buffer" and ByObj.exit3.AtGate.TagName.Str == "Gate.HubToBuffer" and not ByObj.exit3.HasAtPos)
Case("exit to a level by coordinates (grab)", ByObj.exit4.Grab == true and ByObj.exit4.HasAtPos == true and ByObj.exit4.AtLoc.X == 1 and ByObj.exit4.AtLoc.Z == 3 and ByObj.exit4.AtYaw == 90)
Case("exit with no destination: nothing written (the Hub)", ByObj.exit5.HasTo == nil and ByObj.exit5.Dest == nil and Logged("") and true)
Case("level triggers: Kind 1, the add-on stream name, grab flag", ByObj.field1.Kind == 1 and ByObj.field1.StreamName == "ITRAddon_L_MapA_Hub_L_Hub" and ByObj.handle1.Grab == true)
Case("every trigger started", (function() for _, T in ipairs(Trig) do if T.Calls[1] ~= "Start" then return false end end return true end)())
local Mgr = Of("BP_ITRMapManager")[1]
Case("manager: Requests carries one request for the level + target, started", Mgr.Requests == "L_MapA_Hub_L_Hub|/Game/Mods/MapA/L_MapA_Hub|/Game/ITR/Levels/Hub/L_Hub" and Mgr.Calls[1] == "Start")
Case("ITRLevelAddons absent: the requests wait, a line says so", Logged("waiting for ITRLevelAddons") and Mgr.Calls[2] == nil)
local Rg = Of("BP_ITRRegions")[1]
Case("Regions: one actor; Rows hold the 4 listed maps (3 forms with regions + the config row), RS/US delimiters", Rg ~= nil and select(2, Rg.Rows:gsub(string.char(30), "")) == 3 and Rg.Rows:find("MapA" .. string.char(31) .. "ALPHA\nfirst", 1, true) ~= nil and Rg.Rows:find("CfgMap" .. string.char(31) .. "CONFIG ONE", 1, true) ~= nil, Rg and Rg.Rows)
Case("Regions: the one Construct hook registered", #Hooks == 1 and Hooks[1]:find("WBP_MCPage_Main_C:Construct", 1, true) ~= nil)

-- ---- the other order: ITRLevelAddons' manager exists already
Spawned = {}
package.loaded["boot"] = nil
Boot = require("boot")
Boot.Init({ Register = function() end })
Boot.Read()
local AddonsMgr = NewActor("BP_ITRLevelAddons")
Existing["BP_ITRLevelAddons_C"] = { AddonsMgr }
Spawned = {}
Boot.Step()
local Placed = {}
for _, C in ipairs(AddonsMgr.Calls) do if C:find("^Place:") then table.insert(Placed, C) end end
Case("ITRLevelAddons first: Place called once with the ITRAddon_ name", #Placed == 1 and Placed[1] == "Place:ITRAddon_L_MapA_Hub_L_Hub", Placed[1])
Case("no AddonsReady event anywhere", AddonsMgr.Calls[#AddonsMgr.Calls] ~= "AddonsReady" and Of("BP_ITRMapManager")[1].Calls[2] == nil)

print = RealPrint
for _, F in ipairs(Files) do os.remove(F.__absolute_path) end
print(string.format("%d case(s), %d failed", N, Failed))
os.exit(Failed == 0 and 0 or 1)
