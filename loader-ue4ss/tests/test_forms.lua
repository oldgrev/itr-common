-- Offline test of the map form parser (plain Lua 5.1, no game): run from this folder with
--   lua test_forms.lua
-- Prints "ok <n> <case>" / "not ok <n> <case>: <why>" and exits 1 when a case fails.
package.path = "../ITRMapLoader/Scripts/?.lua;" .. package.path
local Forms = require("forms")

local N, Failed = 0, 0
local function Case(Name, Ok, Why)
    N = N + 1
    if Ok then print("ok " .. N .. " " .. Name)
    else Failed = Failed + 1; print("not ok " .. N .. " " .. Name .. ": " .. tostring(Why)) end
end

local GOOD = [[{ "schema": 1, "name": "Demo", "displayName": "Demo Map", "description": "a small map", "level": "/Game/Mods/Demo/L_Demo",
  "start": { "x": 1, "y": 2, "z": 3 }, "enter": { "command": "demomap" }, "triggers": [ { "kind": "regions" } ] }]]

do
    local F, Err = Forms.Parse(GOOD, "Demo.json")
    Case("valid form parses", F ~= nil, Err)
    if F then
        Case("fields", F.Name == "Demo" and F.Display == "Demo Map" and F.Desc == "a small map" and F.Command == "demomap"
            and F.Tag == "Level.Zone.Demo" and F.Start.Z == 3 and #F.Triggers == 1, F.Tag)
    end
end
do
    local F = Forms.Parse([[{ "schema": 1, "level": "/Game/Mods/A/L_A", "enter": { "command": "a" } }]], "My-Map_2.json")
    Case("name defaults to the file name, no triggers is fine", F and F.Name == "My-Map_2" and F.Display == "My-Map_2" and #F.Triggers == 0)
end
do
    local F, Err = Forms.Parse("{ broken", "Bad.json")
    Case("broken JSON refused", F == nil and Err:find("not valid JSON", 1, true), Err)
end
do
    local F, Err = Forms.Parse([[{ "schema": 2, "level": "/Game/Mods/A/L_A", "enter": { "command": "a" } }]], "New.json")
    Case("schema 2 refused", F == nil and Err:find("newer ITRMapLoader", 1, true), Err)
end
do
    local F, Err = Forms.Parse([[{ "level": "/Game/Mods/A/L_A", "enter": { "command": "a" } }]], "NoSchema.json")
    Case("missing schema refused", F == nil and Err:find("schema", 1, true), Err)
end
do
    local F, Err = Forms.Parse([[{ "schema": 1, "name": "Has Space", "level": "/Game/Mods/A/L_A", "enter": { "command": "a" } }]], "X.json")
    Case("bad name refused", F == nil and Err:find("'name'", 1, true), Err)
end
do
    local F, Err = Forms.Parse([[{ "schema": 1, "enter": { "command": "a" } }]], "NoLevel.json")
    Case("missing level refused", F == nil and Err:find("'level'", 1, true), Err)
end
do
    local F, Err = Forms.Parse([[{ "schema": 1, "level": "/Game/Mods/A/L_A" }]], "NoEnter.json")
    Case("enter is optional now", F ~= nil and F.Command == nil and F.Saves == true, Err)
end
do
    local F, _, Warn = Forms.Parse([[{ "schema": 1, "level": "/Game/Mods/A/L_A", "enter": { "command": "a" }, "colour": "red" }]], "Extra.json")
    Case("unknown field is a warning", F ~= nil and #Warn == 1 and Warn[1]:find("colour", 1, true), Warn[1])
end
do
    local F = Forms.Parse("\239\187\191" .. GOOD, "Bom.json")
    Case("BOM is stripped", F ~= nil)
end
do
    local F = Forms.Parse([[{ "schema": 1, "enabled": false, "level": "/Game/Mods/A/L_A", "enter": { "command": "a" } }]], "Off.json")
    Case("enabled false parses as disabled", F ~= nil and F.Enabled == false)
end

-- triggers
local BASE = [[{ "schema": 1, "level": "/Game/Mods/A/L_A", "triggers": ]]
do
    local F, _, Warn = Forms.Parse(BASE .. [[[
        { "kind": "regions" },
        { "kind": "level", "target": "/Game/ITR/Levels/Hub/L_Hub", "level": "/Game/Mods/A/L_A_Hub", "type": "collision", "object": "/Game/Mods/A/L_A_Hub/field1" },
        { "kind": "level", "target": "/Game/ITR/Levels/Hub/L_Hub", "level": "/Game/Mods/A/L_A_Hub", "type": "grab", "object": "handle1" },
        { "kind": "level", "target": "/Game/ITR/Levels/Zone/L_Z", "level": "/Game/Mods/A/L_A_Z", "type": "grab", "object": "L_A_Z.PersistentLevel.h2" },
        { "kind": "exit", "type": "collision", "object": "exit1" } ] }]], "T.json")
    Case("regions, two level triggers, exit parse with no warnings", F and F.Regions == true and #F.Exits == 1 and #Warn == 0, Warn and Warn[1])
    Case("two triggers in one level and target are one request", F and #F.Levels == 2 and #F.Levels[1].Triggers == 2 and #F.Levels[2].Triggers == 1)
    Case("object path reduced to the actor name", F and F.Triggers[2].ObjectName == "field1" and F.Triggers[2].Object == "/Game/Mods/A/L_A_Hub/field1" and F.Levels[2].Triggers[1].ObjectName == "h2")
    Case("exit has the map's own level, no target", F and F.Exits[1].Type == "collision" and F.Exits[1].Target == nil and F.Exits[1].ObjectName == "exit1")
    Case("all five triggers kept in order", F and #F.Triggers == 5 and F.Triggers[1].Kind == "regions" and F.Triggers[5].Kind == "exit")
end
do
    local F, _, Warn = Forms.Parse(BASE .. [[[
        { "kind": "walkin" }, { "kind": "level" },
        { "kind": "level", "level": "/Game/Mods/X/L_X", "target": "Hub", "type": "grab", "object": "a" },
        { "kind": "level", "level": "/Game/Mods/X/L_X", "type": "poke", "object": "a" },
        { "kind": "level", "level": "/Game/Mods/X/L_X", "type": "grab" },
        { "kind": "item", "mesh": "SM_Tea01D" }, { "kind": "door", "at": { "x": 1, "y": 2, "z": 3 } }, "x",
        { "kind": "exit", "type": "grab" } ] }]], "Bad.json")
    Case("bad triggers lose only themselves, the form stays", F ~= nil and #F.Levels == 0 and #F.Exits == 0 and #F.Triggers == 0 and #Warn == 9, Warn and #Warn)
    Case("unknown kind named in the warning", Warn and Warn[1] and Warn[1]:find("unknown kind 'walkin'", 1, true) ~= nil, Warn and Warn[1])
    Case("kind item is gone: unknown kind", Warn and Warn[6] and Warn[6]:find("unknown kind 'item'", 1, true) ~= nil, Warn and Warn[6])
    Case("old door kind is unknown", Warn and Warn[7] and Warn[7]:find("unknown kind 'door'", 1, true) ~= nil, Warn and Warn[7])
    Case("bad type is named", Warn and Warn[4] and Warn[4]:find("'type' must be collision or grab", 1, true) ~= nil, Warn and Warn[4])
end
do
    local F = Forms.Parse([[{ "schema": 1, "level": "/Game/Mods/A/L_A", "triggers": [ { "kind": "level", "level": "/Game/Mods/A/H", "type": "grab", "object": "o" } ] }]], "Def.json")
    Case("target defaults to the Hub", F and F.Levels[1].Target == "/Game/ITR/Levels/Hub/L_Hub")
end
do
    local F = Forms.Parse([[{ "schema": 1, "level": "/Game/Mods/A/L_A" }]], "None.json")
    Case("no triggers: empty lists, no Regions row", F ~= nil and #F.Levels == 0 and #F.Triggers == 0 and F.Regions == false)
end

-- exit destinations: "to" and "at"
do
    local function X(Extra) return Forms.Parse([==[{ "schema": 1, "level": "/Game/Mods/A/L_A", "triggers": [ { "kind": "exit", "type": "collision", "object": "e1"]==] .. Extra .. " } ] }", "Ex.json") end
    local F, _, W = X("")
    Case("exit with no 'to': kept, no destination", F and #F.Exits == 1 and F.Exits[1].To == nil and F.Exits[1].At == nil and #W == 0)
    local F2, _, W2 = X([[, "to": "OtherMap"]])
    Case("exit 'to' a map name", F2 and F2.Exits[1].To == "OtherMap" and #W2 == 0)
    local F3, _, W3 = X([[, "to": "Level.Zone.Buffer", "at": { "kind": "object", "value": "Gate.HubToBuffer" }]])
    Case("exit 'at' an object (a gate tag)", F3 and F3.Exits[1].To == "Level.Zone.Buffer" and F3.Exits[1].At == "Gate.HubToBuffer" and #W3 == 0)
    local F4, _, W4 = X([[, "to": "Level.Zone.Buffer", "at": { "kind": "coordinates", "value": [1, -2.5, 3] }]])
    local A4 = F4 and F4.Exits[1].At
    Case("exit 'at' coordinates [x, y, z] (yaw defaults to 0)", type(A4) == "table" and A4.X == 1 and A4.Y == -2.5 and A4.Z == 3 and A4.Yaw == 0 and #W4 == 0)
    local F5 = X([[, "to": "Level.Zone.Buffer", "at": { "kind": "coordinates", "value": [1, 2, 3, 90] }]])
    Case("exit 'at' coordinates with a yaw", F5 and F5.Exits[1].At.Yaw == 90)
    local F6, _, W6 = X([[, "to": "Level.Zone.Buffer", "at": [ { "kind": "object", "value": "Gate.A" } ] ]])
    Case("a one-item list is the same as the object", F6 and F6.Exits[1].At == "Gate.A" and #W6 == 0)
    local F7, _, W7 = X([[, "to": "Level.Zone.Buffer", "at": [ { "kind": "object", "value": "Gate.A" }, { "kind": "object", "value": "Gate.B" } ] ]])
    Case("a longer list uses the first and logs it", F7 and F7.Exits[1].At == "Gate.A" and #W7 == 1 and W7[1]:find("only the first is used", 1, true) ~= nil, W7 and W7[1])
    for _, Bad in ipairs({ [[, "to": "Not A Name"]], [[, "to": 5]], [[, "to": "a.b"]], [[, "to": "Level."]] }) do
        local FB, _, WB = X(Bad)
        Case("bad exit 'to' " .. Bad:gsub("^, ", "") .. ": trigger ignored, one line", FB ~= nil and #FB.Exits == 0 and #WB == 1 and WB[1]:find("'to' must be", 1, true) ~= nil, WB and WB[1])
    end
    for _, Bad in ipairs({ [[, "at": 5]], [[, "at": "Gate.HubToBuffer"]], [[, "at": { "x": 1, "y": 2, "z": 3 }]], [[, "at": { "kind": "object", "value": "Gate X" }]],
        [[, "at": { "kind": "coordinates", "value": [1, 2] }]], [[, "at": { "kind": "coordinates", "value": [1, "2", 3] }]], [[, "at": { "kind": "room", "value": "x" }]] }) do
        local FB, _, WB = X(Bad)
        Case("bad exit 'at' " .. Bad:gsub("^, ", "") .. ": trigger ignored, one line", FB ~= nil and #FB.Exits == 0 and #WB == 1 and WB[1]:find("'at' must be", 1, true) ~= nil, WB and WB[1])
    end
end

-- rifts
do
    local function R(Extra) return Forms.Parse([[{ "schema": 1, "level": "/Game/Mods/A/L_A"]] .. Extra .. " }", "Rift.json") end
    local F, _, W = R("")
    Case("rifts default to 99", F and F.Rifts == 99 and #W == 0)
    local F2, _, W2 = R([[, "rifts": 33]])
    Case("rifts 33 accepted and reach the map record", F2 and F2.Rifts == 33 and #W2 == 0 and Forms.ToMap(F2).NativeGenerators == 33)
    Case("rifts 0 accepted", (R([[, "rifts": 0]])).Rifts == 0)
    for _, Bad in ipairs({ [[, "rifts": "many"]], [[, "rifts": -1]], [[, "rifts": 2.5]], [[, "rifts": true]], [==[, "rifts": [1] ]==] }) do
        local FB, _, WB = R(Bad)
        Case("bad rifts " .. Bad:gsub("^, ", "") .. ": logged, form kept, default 99", FB ~= nil and FB.Rifts == 99 and #WB == 1 and WB[1]:find("'rifts'", 1, true) ~= nil, WB and WB[1])
    end
end

-- enter, saves, return point
do
    local F = Forms.Parse([[{ "schema": 1, "level": "/Game/Mods/A/L_A", "enter": { "command": "mymap" }, "saves": false }]], "E.json")
    Case("enter.command and saves false", F and F.Command == "mymap" and F.Saves == false)
    local G, Err = Forms.Parse([[{ "schema": 1, "level": "/Game/Mods/A/L_A", "enter": { "command": "bad cmd" } }]], "E2.json")
    Case("bad enter.command refused", G == nil and Err:find("enter.command", 1, true), Err)
    local H, Err2 = Forms.Parse([[{ "schema": 1, "level": "/Game/Mods/A/L_A", "saves": "no" }]], "E3.json")
    Case("bad saves refused", H == nil and Err2:find("'saves'", 1, true), Err2)
end
do
    local F, _, Warn = Forms.Parse([[{ "schema": 1, "level": "/Game/Mods/A/L_A", "returnpointstoragepath": "MyMap_returnpoint", "noprepend": true }]], "R.json")
    Case("return key used exactly as written, noprepend quiet", F and F.ReturnKey == "MyMap_returnpoint" and F.NoPrepend == true and #Warn == 0, Warn and Warn[1])
    local G = Forms.Parse([[{ "schema": 1, "level": "/Game/Mods/A/L_A" }]], "R2.json")
    Case("no return key means nil", G and G.ReturnKey == nil and G.NoPrepend == false)
    local H, _, W2 = Forms.Parse([[{ "schema": 1, "level": "/Game/Mods/A/L_A", "returnpointstoragepath": "has space" }]], "R3.json")
    Case("bad return key warns, map stays, no key", H and H.ReturnKey == nil and #W2 == 1 and W2[1]:find("returnpointstoragepath", 1, true))
end

-- Load: duplicate names, disabled, sorting, refusals
do
    local Dir = os.tmpname():gsub("[^/\\]+$", "")
    local function Write(Name, Text) local P = Dir .. "t_forms_" .. Name; local H = assert(io.open(P, "wb")); H:write(Text); H:close(); return { Name = Name, Path = P } end
    local List = {
        Write("b.json", [[{ "schema": 1, "name": "Zed", "displayName": "zeta", "level": "/Game/Mods/A/L_A", "enter": { "command": "a" } }]]),
        Write("a.json", [[{ "schema": 1, "name": "Alpha", "displayName": "Beta", "level": "/Game/Mods/A/L_A", "enter": { "command": "a" } }]]),
        Write("c.json", [[{ "schema": 1, "name": "alpha", "level": "/Game/Mods/A/L_A", "enter": { "command": "a" } }]]),
        Write("d.json", "nonsense"),
        Write("e.json", [[{ "schema": 1, "enabled": false, "level": "/Game/Mods/A/L_A", "enter": { "command": "a" } }]]),
    }
    local Fs, Lines, Refused = Forms.Load(List)
    Case("Load keeps 2 forms", #Fs == 2, #Fs)
    Case("Load sorts by display name, ignoring case", Fs[1].Display == "Beta" and Fs[2].Display == "zeta", Fs[1] and Fs[1].Display)
    Case("Load refuses the duplicate and the broken file", Refused == 2, Refused)
    local Text = table.concat(Lines, "\n")
    Case("Load logs the duplicate", Text:find("already used by a.json", 1, true), Text)
    Case("Load logs the switched-off form", Text:find("switched off", 1, true), Text)
    for _, E in ipairs(List) do os.remove(E.Path) end
end

print(string.format("%d case(s), %d failed", N, Failed))
os.exit(Failed == 0 and 0 or 1)
