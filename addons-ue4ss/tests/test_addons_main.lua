-- Offline run of ITRLevelAddons/Scripts/main.lua against stubs of the UE4SS API (plain Lua 5.1, no game):   lua test_addons_main.lua
-- Manifests on disk, a manager Blueprint that records Place(...), ITRMapLoader's manager as a table of requests. It proves what Lua does (the one step, the arguments of Place, the
-- handshake in both orders, the console verbs, the rules: one ExecuteInGameThread, no timer, no loop, no hook), not the game.
package.path = "../ITRLevelAddons/Scripts/?.lua;" .. package.path

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
local function Write(Name, Text) local P = Dir .. "ta_" .. Name; local H = assert(io.open(P, "wb")); H:write(Text); H:close(); return P end
local Files = {
    { __name = "One.json", __absolute_path = Write("One.json", [[{ "name": "One", "target": "/Game/ITR/Levels/Hub/L_Hub", "level": "/Game/Mods/X/L_One",
        "transform": { "location": [1, 2, 3], "rotation": [0, 90, 0], "scale": [1, 1, 2] },
        "hide": [ "PalletA", { "actor": "PropB", "level": "/Game/ITR/Levels/Hub/L_Hub_BaseBuilding" } ] }]]) },
    { __name = "Two.json", __absolute_path = Write("Two.json", [[{ "name": "Two", "target": "/Game/ITR/Levels/Hub/L_Hub", "level": "/Game/Mods/X/L_One" }]]) },
    { __name = "Bad.json", __absolute_path = Write("Bad.json", "not json") },
}
function IterateGameDirectories()
    return { Game = { Content = { Paks = { LuaMods = { ITRLevelAddons = { Addons = { __name = "Addons", __absolute_path = "C:/G/Content/Paks/LuaMods/ITRLevelAddons/Addons", __files = Files } } } } } } }
end

local function Valid() return true end
local Queued, Calls = 0, { LoopAsync = 0, ExecuteWithDelay = 0, RegisterHook = 0 }
function ExecuteInGameThread(F) Queued = Queued + 1; F() end
function LoopAsync() Calls.LoopAsync = Calls.LoopAsync + 1 end
function ExecuteWithDelay() Calls.ExecuteWithDelay = Calls.ExecuteWithDelay + 1 end
function RegisterHook() Calls.RegisterHook = Calls.RegisterHook + 1 end
function FName(S) return { Str = S, ToString = function() return S end } end

local Notify
function NotifyOnNewObject(Path, F) Notify = F end
local Handlers = {}
function RegisterConsoleCommandHandler(Name, F) Handlers[Name] = F end

local Placed = {}
local function NewManager()
    local M = { IsValid = Valid, GetFName = function() return FName("BP_ITRLevelAddons_C_1") end }
    M.LastReport = { ToString = function() return M.Report or "" end }
    M.Place = function(self, ...) table.insert(Placed, { ... }) ; local Args = { ... }; M.Report = M.DupOf[Args[1]] and "already placed (test)" or "" end
    M.DupOf = {}
    return M
end
local Manager = nil
local HavePak = true
local Helpers = { GetAsset = function() if HavePak then return { IsValid = Valid } end return { IsValid = function() return false end } end, IsValid = Valid }
function StaticFindObject(P) if P:find("AssetRegistryHelpers", 1, true) then return Helpers end return { IsValid = function() return false end } end
local World = { SpawnActor = function() Manager = NewManager(); return Manager end }
package.preload["UEHelpers"] = function() return { GetWorld = function() return World end } end
local Existing = {}
function FindAllOf(Name) if Name == "BP_ITRLevelAddons_C" and Manager then return { Manager } end return Existing[Name] end

dofile("../ITRLevelAddons/Scripts/main.lua")
Case("loaded: one notification registered, console verb registered, nothing queued yet", Notify ~= nil and Handlers.itraddons ~= nil and Queued == 0)
Case("manifests read: One and Two accepted, Bad rejected, a repeated level+target refused", Logged("add-on One:") and Logged("manifest REJECTED: Bad.json") and Logged("names the same level and target as One"))

-- the game mode notification: only the real BP_PRGameMode_C counts
local Wrong = { GetClass = function() return { GetFName = function() return FName("PRGameMode") end } end, GetFName = function() return FName("PRGameMode_1") end }
Notify(Wrong)
Case("a notification for the native class does nothing", Queued == 0)
local Real = { GetClass = function() return { GetFName = function() return FName("BP_PRGameMode_C") end } end, GetFName = function() return FName("BP_PRGameMode_C_1") end }
Existing["BP_ITRMapManager_C"] = { { IsValid = Valid, GetFName = function() return FName("BP_ITRMapManager_C_1") end,
    Requests = { ToString = function() return "L_M_L_Hub|/Game/Mods/M/L_M|/Game/ITR/Levels/Hub/L_Hub" end } } }
Notify(Real)
Case("the step ran once, from the notification: exactly one ExecuteInGameThread", Queued == 1)
Case("a second notification does nothing", (function() Notify(Real); return Queued == 1 end)())
local P1 = Placed[1]
Case("Place for One: name, level, short target", P1 and P1[1] == "ITRAddon_One" and P1[2] == "/Game/Mods/X/L_One" and P1[3] == "L_Hub", P1 and tostring(P1[1]))
Case("Place for One: hides as <level>:PersistentLevel.<actor>, hide levels without the target", P1 and P1[4] == "L_Hub:PersistentLevel.PalletA,L_Hub_BaseBuilding:PersistentLevel.PropB" and P1[5] == "L_Hub_BaseBuilding", P1 and P1[4])
Case("Place for One: location, rotation, scale", P1 and P1[6].X == 1 and P1[6].Z == 3 and P1[7].Yaw == 90 and P1[8].X == 1 and P1[8].Z == 2)
Case("ITRMapLoader's request handed over (it started first): Place for it too", #Placed == 2 and Placed[2][1] == "ITRAddon_L_M_L_Hub" and Placed[2][3] == "L_Hub" and Placed[2][8].X == 1)
Case("no timer, no loop, no hook", Calls.LoopAsync == 0 and Calls.ExecuteWithDelay == 0 and Calls.RegisterHook == 0)
Case("the ready line", Logged("ready: 1 add-on(s) placed"))

-- the console verbs
Placed = {}
Handlers.itraddons(nil, { "place", "name=Three", "level=/Game/Mods/Y/L_Three", "target=/Game/ITR/Levels/Hub/L_Hub" })
Case("itraddons place: Place called with the ITRAddon_ name", #Placed == 1 and Placed[1][1] == "ITRAddon_Three")
Handlers.itraddons(nil, { "place", "name=Bad Name", "level=/Game/x", "target=/Game/ITR/Levels/Hub/L_Hub" })
Case("itraddons place with a bad name: rejected with a line, nothing placed", #Placed == 1 and Logged("itraddons place REJECTED"))
Handlers.itraddons(nil, { "place", "name=Four", "level=/Game/Mods/Y/L_Three", "target=/Game/ITR/Levels/Hub/L_Hub", "notify=a:b" })
Case("notify is gone: an unknown key is ignored, the add-on is placed", #Placed == 2)
Manager.DupOf["ITRAddon_Dup"] = true
Handlers.itraddons(nil, { "place", "name=Dup", "level=/Game/Mods/Z/L_Z", "target=/Game/ITR/Levels/Hub/L_Hub" })
Case("a repeat the manager refuses is reported from LastReport", Logged("add-on Dup: already placed"), "")
Handlers.itraddons(nil, { "log", "add-on", "One:", "hide", "X", "matches", "no", "actor" })
Case("itraddons log prints the Blueprint's line", Logged("add-on One: hide X matches no actor"))
Handlers.itraddons(nil, { "shown", "x" })
Case("an unknown verb is answered with a line", Logged("unknown verb 'shown'"))

-- helper pak missing
local PlacedBefore = #Placed
Notify = nil
HavePak = false
Lines = {}
Queued = 0
package.loaded["manifest"] = nil
dofile("../ITRLevelAddons/Scripts/main.lua")
Notify(Real)
Case("helper pak not found: one line, no new Place", Logged("helper pak not found") and #Placed == PlacedBefore)

print = RealPrint
for _, F in ipairs(Files) do os.remove(F.__absolute_path) end
print(string.format("%d case(s), %d failed", N, Failed))
os.exit(Failed == 0 and 0 or 1)
