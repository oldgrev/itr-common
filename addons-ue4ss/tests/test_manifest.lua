-- Offline test of the manifest parser (plain Lua 5.1, no game): run from this folder with
--   lua test_manifest.lua
-- Prints "ok <n> <case>" / "not ok <n> <case>: <why>" and exits 1 when a case fails.
package.path = "../ITRLevelAddons/Scripts/?.lua;" .. package.path
local Manifest = require("manifest")

local N, Failed = 0, 0
local function Case(Name, Ok, Why)
    N = N + 1
    if Ok then print("ok " .. N .. " " .. Name)
    else Failed = Failed + 1; print("not ok " .. N .. " " .. Name .. ": " .. tostring(Why)) end
end
local function ReadFile(P)
    local F = assert(io.open(P, "rb"))
    local T = F:read("*a")
    F:close()
    return T
end

-- 1. the example add-on's manifest
do
    local A, Err = Manifest.Parse(ReadFile("../../example-addon/addon/HubCozyCorner.json"), "HubCozyCorner.json")
    Case("example parses", A ~= nil, Err)
    if A then
        Case("example name", A.Name == "HubCozyCorner", A.Name)
        Case("example level", A.Level == "/Game/Mods/HubCozyCorner/L_HubCozyCorner", A.Level)
        Case("example target", A.Target == "/Game/ITR/Levels/Hub/L_Hub", A.Target)
        Case("example one hide entry", #A.Hide == 1 and A.Hide[1].Actor == "SM_Props_WoodenPallet_01_a6"
            and A.Hide[1].Level == "/Game/ITR/Levels/Hub/L_Hub", #A.Hide)
        Case("example transform at the origin", A.Location[1] == 0 and A.Location[2] == 0 and A.Location[3] == 0 and A.Scale[1] == 1)
        Case("example enabled", A.Enabled == true)
    end
end

-- 2. a malformed file (a missing comma)
do
    local A, Err = Manifest.Parse(ReadFile("bad_syntax.json"), "bad_syntax.json")
    Case("malformed file rejected", A == nil and tostring(Err):find("not valid JSON") ~= nil, Err)
    print("   message: " .. tostring(Err))
end

-- 3. more broken and edge cases
local function Rejects(Name, Text, Want)
    local A, Err = Manifest.Parse(Text, (Name:gsub("[^%w]", "_")) .. ".json")
    Case(Name, A == nil and tostring(Err):find(Want, 1, true) ~= nil, A and "accepted" or Err)
end
Rejects("empty file", "   \n", "empty file")
Rejects("top level is a list", '[1, 2]', "JSON object")
Rejects("missing level", '{"target": "/Game/ITR/Levels/Hub/L_Hub"}', "'level'")
Rejects("missing target", '{"level": "/Game/Mods/X/L_X"}', "'target'")
Rejects("level not a package", '{"level": "L_X", "target": "/Game/ITR/Levels/Hub/L_Hub"}', "'level'")
Rejects("level equals target", '{"level": "/Game/ITR/Levels/Hub/L_Hub", "target": "/Game/ITR/Levels/Hub/L_Hub"}', "same package")
Rejects("hide not a list", '{"level": "/Game/Mods/X/L_X", "target": "/Game/ITR/Levels/Hub/L_Hub", "hide": "SM_A"}', "'hide'")
Rejects("hide entry with a space", '{"level": "/Game/Mods/X/L_X", "target": "/Game/ITR/Levels/Hub/L_Hub", "hide": ["SM A"]}', "hide[1]")
Rejects("hide entry level bad", '{"level": "/Game/Mods/X/L_X", "target": "/Game/ITR/Levels/Hub/L_Hub", "hide": [{"actor": "SM_A", "level": "Hub"}]}', "hide[1].level")
Rejects("transform location of 2", '{"level": "/Game/Mods/X/L_X", "target": "/Game/ITR/Levels/Hub/L_Hub", "transform": {"location": [1, 2]}}', "transform.location")
Rejects("transform rotation text", '{"level": "/Game/Mods/X/L_X", "target": "/Game/ITR/Levels/Hub/L_Hub", "transform": {"rotation": [0, "90", 0]}}', "transform.rotation")
Rejects("text after the object", '{"level": "/Game/Mods/X/L_X", "target": "/Game/ITR/Levels/Hub/L_Hub"} x', "not valid JSON")
Rejects("unterminated string", '{"level": "/Game/Mods/X/L_X, "target": 1}', "not valid JSON")
Rejects("bad name", '{"name": "my addon", "level": "/Game/Mods/X/L_X", "target": "/Game/ITR/Levels/Hub/L_Hub"}', "'name'")
Rejects("enabled not a bool", '{"level": "/Game/Mods/X/L_X", "target": "/Game/ITR/Levels/Hub/L_Hub", "enabled": "no"}', "'enabled'")

do
    local A, Err, Warn = Manifest.Parse('\239\187\191{"level": "/Game/Mods/X/L_X", "target": "/Game/ITR/Levels/Hub/L_Hub", "hide": ["SM_A", "SM_B"], "colour": 1}', "Shorthand.json")
    Case("BOM + string hide shorthand", A ~= nil and #A.Hide == 2 and A.Hide[2].Level == "/Game/ITR/Levels/Hub/L_Hub", Err)
    Case("name defaults to the file name", A ~= nil and A.Name == "Shorthand", A and A.Name)
    Case("unknown field warned, not rejected", A ~= nil and Warn and #Warn == 1 and Warn[1]:find("colour", 1, true) ~= nil, Warn and Warn[1])
    local B = Manifest.Parse('{"level": "/Game/Mods/X/L_X", "target": "/Game/ITR/Levels/Hub/L_Hub", "enabled": false, "transform": {"location": [10, -20.5, 3e2], "rotation": [0, 90, 0]}}', "Off.json")
    Case("enabled false kept as off", B ~= nil and B.Enabled == false)
    Case("numbers incl. exponent", B ~= nil and B.Location[2] == -20.5 and B.Location[3] == 300)
    local Q = Manifest.Quat(0, 90, 0)
    Case("quat of yaw 90", math.abs(Q.Z - math.sqrt(0.5)) < 1e-6 and math.abs(Q.W - math.sqrt(0.5)) < 1e-6 and math.abs(Q.X) < 1e-9, string.format("%f %f %f %f", Q.X, Q.Y, Q.Z, Q.W))
end

print(string.format("%d case(s), %d failed", N, Failed))
os.exit(Failed == 0 and 0 or 1)
