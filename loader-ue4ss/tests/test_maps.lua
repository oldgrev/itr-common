-- Offline test of maps.lua and bind.lua (plain Lua 5.1, no game): run from this folder with   lua test_maps.lua
-- A stand-in of the UE4SS API: forms on disk, console commands recorded, a level whose actors are listed, the logic-only helper as a stub that answers
-- like BP_ITRTriggerBind (Result 0 / 1 / 2), a game-data object with CustomMarkers. It proves the logic around the game, not the game.
package.path = "../ITRMapLoader/Scripts/?.lua;" .. package.path

local N, Failed = 0, 0
local function Case(Name, Ok, Why)
    N = N + 1
    if Ok then io.write("ok " .. N .. " " .. Name .. "\n")
    else Failed = Failed + 1; io.write("not ok " .. N .. " " .. Name .. ": " .. tostring(Why) .. "\n") end
end

-- ---- stubs
local Lines, Cmds = {}, {}
local RealPrint = print
print = function(S) table.insert(Lines, S) end
local function Logged(Pat) for _, L in ipairs(Lines) do if L:find(Pat) then return true end end return false end
local function Count(Pat) local C = 0 for _, L in ipairs(Lines) do if L:find(Pat) then C = C + 1 end end return C end

local Dir = os.tmpname():gsub("[^/\\]+$", "")
local function Write(Name, Text) local P = Dir .. "tm_" .. Name; local H = assert(io.open(P, "wb")); H:write(Text); H:close(); return P end
local Files = {
    { __name = "A.json", __absolute_path = Write("A.json", [[{ "schema": 1, "name": "MapA", "level": "/Game/Mods/MapA/L_MapA", "start": { "x": 1, "y": 2, "z": 3 },
        "returnpointstoragepath": "MapA_returnpoint", "noprepend": true, "triggers": [ { "kind": "regions" },
        { "kind": "level", "level": "/Game/Mods/MapA/L_MapA_Hub", "target": "/Game/ITR/Levels/Hub/L_Hub", "type": "collision", "object": "field1" },
        { "kind": "level", "level": "/Game/Mods/MapA/L_MapA_Hub", "target": "/Game/ITR/Levels/Hub/L_Hub", "type": "grab", "object": "handle1" },
        { "kind": "level", "level": "/Game/Mods/MapA/L_MapA_Hub", "target": "/Game/ITR/Levels/Hub/L_Hub", "type": "grab", "object": "plain1" },
        { "kind": "level", "level": "/Game/Mods/MapA/L_MapA_Hub", "target": "/Game/ITR/Levels/Hub/L_Hub", "type": "collision", "object": "nothere" },
        { "kind": "exit", "type": "collision", "object": "exit1" } ] }]]) },
    { __name = "B.json", __absolute_path = Write("B.json", [[{ "schema": 1, "name": "MapB", "level": "/Game/Mods/MapB/L_MapB", "enter": { "command": "mapb" } }]]) },
    { __name = "C.json", __absolute_path = Write("C.json", [[{ "schema": 1, "name": "MapC", "level": "/Game/Mods/MapC/L_MapA" }]]) },
    { __name = "D.loot.json", __absolute_path = Write("D.loot.json", "{}") },
}
function IterateGameDirectories()
    return { Game = { Content = { Paks = { ITRMaps = { __name = "ITRMaps", __absolute_path = "C:/Game/Content/Paks/ITRMaps", __files = Files } } } } }
end
local Installed = { ["/game/mods/mapa/l_mapa"] = true, ["/game/mods/mapb/l_mapb"] = true, ["/game/mods/mapa/l_mapa_hub"] = true }
local PathsLib = { FileExists = function(self, P)
    local Pkg = "/game/" .. P:gsub("^%.%./%.%./%.%./IntoTheRadius/Content/", ""):gsub("%.umap$", ""):lower()
    return Installed[Pkg] == true or Pkg == "/game/engine/nothing" and false
end, IsValid = function() return true end }
function StaticFindObject(P)
    if P == "/Script/Engine.Default__BlueprintPathsLibrary" then return PathsLib end
    if P:find("BP_ITRTriggerBind", 1, true) then return { IsValid = function() return true end } end
    return { IsValid = function() return false end }
end
function FName(S) return { ToString = function() return S end } end

-- the level with the author's objects; every actor answers GetFullName
local LP = "/Game/ITR/Levels/Hub/ITRAddon_ITRMapLevel_MapA_1.L_MapA_Hub:PersistentLevel"
local function Actor(Name, Result)
    local A = { Name = Name, Result = Result }
    A.IsValid = function() return true end
    A.GetFullName = function() return "StaticMeshActor " .. LP .. "." .. Name end
    A.GetClass = function() return { GetFName = function() return FName("StaticMeshActor") end } end
    A.K2_GetRootComponent = function() return { GetCollisionProfileName = function() return FName("BlockAll") end } end
    return A
end
local ActorList = { Actor("field1", 1), Actor("handle1", 2), Actor("plain1", 0), Actor("other_5", 1) }
function FindAllOf(Cls) if Cls == "Actor" then return ActorList end end
local Spawned, Destroyed = {}, 0
local Level = { IsValid = function() return true end, GetFullName = function() return "Level " .. LP end, GetAddress = function() return 4242 end }
local Entry = { IsValid = function() return true end, GetLoadedLevel = function() return Level end }
Entry.GetLoadedLevel = function() return Level end
local World = { SpawnActor = function(self, Class)
    local H = { IsValid = function() return true end, K2_DestroyActor = function() Destroyed = Destroyed + 1 end }
    H.AttachCollision = function(me, Target, Id) me.Id, me.Result = Id, Target.Result end
    H.AttachGrab = function(me, Target, Id) me.Id, me.Result = Id, Target.Result end
    table.insert(Spawned, H)
    return H
end }
package.preload["UEHelpers"] = function() return { GetWorld = function() return World end } end
local Handlers = {}
function RegisterConsoleCommandHandler(Name, F) Handlers[Name] = F end

-- game data with CustomMarkers
local Markers = {}
local GD = { CustomMarkers = {} }
local function Sync()   -- Lua 5.1 has no __len on tables: the array of objects is rebuilt after each change (a UE4SS TArray has # and 1-based indexing)
    GD.CustomMarkers = {}
    for I, S in ipairs(Markers) do GD.CustomMarkers[I] = { ToString = function() return S end } end
end
GD.UpdateMarker = function(self, S, Remove)
    if Remove then for I = #Markers, 1, -1 do if Markers[I] == S then table.remove(Markers, I) end end
    else table.insert(Markers, S) end
    Sync()
end

local Maps = require("maps")
local Entered, Left, Current = {}, {}, nil
local PawnAt = { X = 10, Y = 20, Z = 30 }
Maps.Init({
    Exec = function(Cmd) table.insert(Cmds, Cmd); local V, A = Cmd:match("^itrmapbind (%w+) (%S+)"); return true end,
    EnterNative = function(Map, Why, Anywhere) table.insert(Entered, Map.Name .. "|" .. Why .. "|" .. tostring(Anywhere)); return true end,
    Leave = function(Why) table.insert(Left, Why) end,
    CurrentMap = function() return Current end,
    GameData = function() return GD end,
    PawnLoc = function() return PawnAt end,
    PawnYaw = function() return 90 end,
    StreamOf = function(Map) return Entry end,
    EntryByInstance = function(Inst) return Entry end,
})
local Own = Maps.Read()
Case("MapA accepted (loader entered), MapB hands back, MapC refused", #Maps.Maps == 2 and #Own == 1 and Own[1].Name == "MapA", #Maps.Maps)
Case("loot json not read as a form", not Logged("D.loot"))
Case("one trigger level for MapA (3+1 triggers, one request)", #Maps.Groups == 1 and #Maps.Groups[1].Triggers == 4)
Case("noprepend and the key accepted quietly", not Logged("unknown field"))
Case("one-line statements for missing pieces", Logged("map MapB: no Regions row") and not Logged("map MapB: no way in") and not Logged("map MapA: no way in") and not Logged("map MapA: no exit trigger"))
Case("a second loader-entered form with the same level name refused", Logged("the level name l_mapa is already used by map MapA"))
Case("only MapA is listed in Regions", #Maps.Listed() == 1 and Maps.Listed()[1].Name == "MapA")

-- sends from level events until a reply is heard
local Console = Handlers["itrmapbind"]
Maps.OnLevelEvent("OnLevelPrepare")
local Sent1 = #Cmds
Case("level event: place request sent inline with notify", Sent1 == 1 and Cmds[1]:find("^itraddons place name=ITRMapLevel_MapA_1 level=/Game/Mods/MapA/L_MapA_Hub target=/Game/ITR/Levels/Hub/L_Hub notify=itrmapbind:shown$") ~= nil, Cmds[1])
Maps.OnLevelEvent("OnLevelStarted")
Maps.OnLevelEvent("OnTransitionEnd")
Case("no reply: sent again at each level event, 'not heard' once at the first OnTransitionEnd", #Cmds == 3 and Count("ITRLevelAddons not heard") == 1)
Maps.OnLevelEvent("OnTransitionEnd")
Case("'not heard' not repeated", Count("ITRLevelAddons not heard") == 1)
Console(nil, { "placed", "ITRMapLevel_MapA_1" })
Case("reply heard after all: logged", Logged("ITRLevelAddons heard after all"))
local N0 = #Cmds
Maps.OnLevelEvent("OnLevelPrepare")
Case("after the reply: no more requests", #Cmds == N0)

-- shown: binding with the three answers and the missing object
Console(nil, { "shown", "ITRAddon_ITRMapLevel_MapA_1" })
Case("collision object bound (Result 1)", Logged("map MapA collision trigger 'field1': bound to field1"))
Case("grab object: grippable but hand ignored (Result 2)", Logged("'handle1' is grippable but the hand can't touch it"))
Case("grab object: not grippable (Result 0), helper destroyed", Logged("'plain1' found but not grippable") and Destroyed == 1)
Case("missing object: one line with the actors there", Logged("trigger 'nothere': object not in") and Logged("actors there: field1, handle1, other_5, plain1"))
Case("the scan is logged once with its time", Count("actor%(s%) scanned in") == 1)
Case("three helpers spawned (the missing object got none)", #Spawned == 3, #Spawned)
Console(nil, { "shown", "ITRAddon_ITRMapLevel_MapA_1" })
Case("the same level address is not bound twice", #Spawned == 3)

-- fire: a level trigger enters through the one function; an exit stores the return point and leaves
Console(nil, { "fire", "T1" })
Case("level trigger fired: EnterMap with Anywhere", Entered[1] == "MapA|trigger field1|true", Entered[1])
Console(nil, { "fire", "T5" })
Case("exit fired while the map is not active: ignored", #Left == 0 and Logged("exit trigger exit1 fired while the map is not active"))
Current = Maps.ByName("MapA")
Console(nil, { "fire", "T5" })
Case("exit fired in the map: leave called", #Left == 1 and Left[1] == "exit trigger exit1", Left[1])
Case("return point written under the internal prefix, key as written", Markers[1] == "ITRReturn:MapA_returnpoint=10.0,20.0,30.0,90.0", Markers[1])
PawnAt = { X = 5, Y = 6, Z = 7 }
Maps.StoreReturn(Maps.ByName("MapA"))
Case("a second write replaces the first", #Markers == 1 and Markers[1] == "ITRReturn:MapA_returnpoint=5.0,6.0,7.0,90.0", #Markers)
local R = Maps.ReturnStart(Maps.ByName("MapA"))
Case("read back on entry", R and R.X == 5 and R.Y == 6 and R.Z == 7 and R.Yaw == 90)
Markers[1] = "ITRReturn:MapA_returnpoint=garbage"; Sync()
Case("a damaged value: start is used, one line", Maps.ReturnStart(Maps.ByName("MapA")) == nil and Logged("return point 'ITRReturn:MapA_returnpoint=garbage' not usable"))
Markers[1] = nil; Sync()
Case("nothing stored: start, one line", Maps.ReturnStart(Maps.ByName("MapA")) == nil and Logged("map MapA: no return point: using start"))
Case("a map with no key never reads or writes", Maps.ReturnStart(Maps.ByName("MapB")) == nil)

-- missing level: no row, no triggers
Installed["/game/mods/mapa/l_mapa"] = nil
package.loaded["maps"] = nil
Maps = require("maps")
Maps.Init({ Exec = function(Cmd) table.insert(Cmds, Cmd); return true end, GameData = function() return GD end })
Maps.Read()
local CmdsBefore = #Cmds
Maps.OnLevelEvent("OnLevelPrepare")
Case("level not installed: map not listed, no request sent for it", Logged("map MapA: level /Game/Mods/MapA/L_MapA not installed: not listed") and #Maps.Listed() == 0 and #Cmds == CmdsBefore)

-- fire for an unknown id
Console(nil, { "fire", "T99" })
Case("unknown trigger id ignored with a line", Logged("fire for unknown trigger T99"))

print = RealPrint
for _, F in ipairs(Files) do os.remove(F.__absolute_path) end
print(string.format("%d case(s), %d failed", N, Failed))
os.exit(Failed == 0 and 0 or 1)
