-- Offline run of ITRLevelAddons/Scripts/main.lua against stubs of the UE4SS API (plain Lua 5.1, no game):
--   lua test_main_sim.lua
-- A fake world with streaming levels plays: main menu, Hub, zone transfer (Hub unloaded), back to the Hub, a new world.
-- Prints "ok <n> <case>" / "not ok <n> <case>: <why>" and exits 1 when a case fails. It proves the add-on state machine and
-- the manifest handling, not the game's streaming (that is the VR test).
local Here = "./"
local Scripts = "../ITRLevelAddons/Scripts/"
package.path = Scripts .. "?.lua;" .. package.path

local N, Failed = 0, 0
local function Case(Name, Ok, Why)
    N = N + 1
    -- io.write, not print: print is replaced by the UE4SS stub below (it collects the mod's log lines)
    if Ok then io.write("ok " .. N .. " " .. Name .. "\n")
    else Failed = Failed + 1; io.write("not ok " .. N .. " " .. Name .. ": " .. tostring(Why) .. "\n") end
end

-- ---------------------------------------------------------------- fake engine
local NextAddr = 1000
local function Obj(T) NextAddr = NextAddr + 1; T.__addr = NextAddr; if T.__valid == nil then T.__valid = true end
    T.IsValid = function(self) return self.__valid end
    T.GetAddress = function(self) return self.__addr end
    return T
end
local function Name(S) return { ToString = function() return S end } end
local Actors = {}           -- full path -> actor
local function MakeLevel(Pkg)
    local Short = Pkg:gsub("^.*/", "")
    local L = Obj({ Pkg = Pkg })
    L.GetFullName = function() return "Level " .. Pkg .. "." .. Short .. ":PersistentLevel" end
    if Pkg == "/Game/ITR/Levels/Hub/L_Hub" then         -- the Hub level holds the pallet; a reload makes a fresh actor
        local A = Obj({ bHidden = false, Collision = true })
        A.SetActorHiddenInGame = function(self, V) self.bHidden = V end
        A.SetActorEnableCollision = function(self, V) self.Collision = V end
        Actors[Pkg .. "." .. Short .. ":PersistentLevel.SM_Props_WoodenPallet_01_a6"] = A
    end
    return L
end
local function MakeStream(Pkg, Class)
    local S = Obj({ Pkg = Pkg, Class = Class or "LevelStreamingDynamic", Load = false, Vis = false, Level = nil, Creates = 0 })
    S.GetWorldAssetPackageFName = function(self) return Name(self.Pkg) end
    S.IsLevelVisible = function(self) return self.Vis end
    S.SetShouldBeLoaded = function(self, V) self.Load = V end
    S.SetShouldBeVisible = function(self, V) self.WantVis = V end
    S.GetLoadedLevel = function(self) return self.Level or Obj({ __valid = false }) end
    S.GetClass = function(self) local C = self.Class; return { GetFName = function() return Name(C) end } end
    return S
end
local World
local function NewWorld(Pkgs)
    local W = Obj({ Streams = {} })
    for _, P in ipairs(Pkgs) do table.insert(W.Streams, MakeStream(P)) end
    W.StreamingLevels = { ForEach = function(self, Fn)
        for I, S in ipairs(W.Streams) do Fn(I, { get = function() return S end }) end
    end }
    for _, S in ipairs(W.Streams) do
        S.CreateInstance = function(self, Unique)
            local Dir = self.Pkg:match("^(.*)/")
            local New = MakeStream(Dir .. "/" .. Unique)
            New.CreateInstance = self.CreateInstance
            table.insert(W.Streams, New)
            W.Creates = (W.Creates or 0) + 1
            return New
        end
    end
    return W
end
-- one streaming step: entries that are wanted get loaded and visible, the others go away
local function Stream()
    for _, S in ipairs(World.Streams) do
        local Want = S.Load and S.WantVis
        if Want and not S.Vis then
            S.Vis = true
            S.Level = MakeLevel(S.PackageNameToLoad and S.PackageNameToLoad.S or S.Pkg)
        elseif not Want and S.Vis then
            S.Vis = false
            if S.Level then S.Level.__valid = false end
            S.Level = nil
        end
    end
end
local function StreamOf(Pkg) for _, S in ipairs(World.Streams) do if S.Pkg == Pkg then return S end end end
local function SetHub(On)
    local S = StreamOf("/Game/ITR/Levels/Hub/L_Hub")
    S.Load, S.WantVis = On, On
end

-- ---------------------------------------------------------------- UE4SS stubs
local Lines = {}
local RealPrint = print
print = function(S) table.insert(Lines, S); if os.getenv("SIM_VERBOSE") then RealPrint("   | " .. S:gsub("\n$", "")) end end
local Ticks = {}
function LoopAsync(Ms, Fn) table.insert(Ticks, Fn) end
function ExecuteInGameThread(Fn) Fn() end
function FName(S) return { S = S, ToString = function() return S end } end
function StaticFindObject(P) return Actors[P] or Obj({ __valid = false }) end
function IterateGameDirectories()
    local Files = {
        { __name = "HubCozyCorner.json", __absolute_path = Here .. "../../example-addon/addon/HubCozyCorner.json" },
        { __name = "SecondAddon.json", __absolute_path = Here .. "fixture_second.json" },
        { __name = "Broken.json", __absolute_path = Here .. "bad_syntax.json" },
        { __name = "README.txt", __absolute_path = Here .. "README.txt" },
    }
    return { Game = { Binaries = { Win64 = { ue4ss = { Mods = { ITRLevelAddons = { Addons = {
        __name = "Addons", __absolute_path = "C:/Game/Binaries/Win64/ue4ss/Mods/ITRLevelAddons/Addons", __files = Files } } } } } } } }
end
package.preload["UEHelpers"] = function() return { GetWorld = function() return World end } end

local function Tick(K) for _ = 1, K or 1 do for _, F in ipairs(Ticks) do F() end; Stream() end end
local function Logged(Pat) for _, L in ipairs(Lines) do if L:find(Pat) then return true end end return false end
local function AddonStream(NameS) return StreamOf("/Game/ITR/Levels/Hub/ITRAddon_" .. NameS) end

-- ---------------------------------------------------------------- the run
World = NewWorld({ "/Game/ITR/Levels/Menu/L_Menu" })
local Main = assert(loadfile(Scripts .. "main.lua"))
Main()
Case("two add-ons accepted, the broken one rejected", Logged("add%-on HubCozyCorner:") and Logged("add%-on SecondAddon:")
    and Logged("manifest REJECTED: Broken.json: not valid JSON"))
Case("README.txt not read as a manifest", not Logged("README"))

Tick(3)
Case("main menu: nothing streamed", (World.Creates or 0) == 0)

-- Continue: the game world, Hub visible
World = NewWorld({ "/Game/ITR/Levels/Hub/L_Hub", "/Game/ITR/Levels/Hub/L_Hub_Gameplay", "/Game/ITR/Levels/Zone/Buffer/L_Zone_Buffer" })
SetHub(true); Stream()
Tick(1)
Case("one visible check is not enough (debounce)", (World.Creates or 0) == 0)
Tick(3)
local A1, A2 = AddonStream("HubCozyCorner"), AddonStream("SecondAddon")
Case("both add-ons streamed in", A1 and A2 and A1.Vis and A2.Vis, tostring(A1) .. " " .. tostring(A2))
Case("add-on package and origin transform", A1 and A1.PackageNameToLoad.S == "/Game/Mods/HubCozyCorner/L_HubCozyCorner"
    and A1.LevelTransform.Translation.X == 0 and A1.LevelTransform.Rotation.W == 1)
Case("second add-on offset and yaw", A2 and A2.LevelTransform.Translation.X == 100 and math.abs(A2.LevelTransform.Rotation.Z - math.sqrt(0.5)) < 1e-6)
local Pallet = Actors["/Game/ITR/Levels/Hub/L_Hub.L_Hub:PersistentLevel.SM_Props_WoodenPallet_01_a6"]
Case("pallet hidden and without collision", Pallet.bHidden == true and Pallet.Collision == false)
Case("missing hide actor reported", Logged("NOT FOUND %(check the name%): SM_DoesNotExist_1"))
local NLines = #Lines
Tick(5)
Case("steady state: no new log lines", #Lines == NLines, Lines[#Lines])

-- zone transfer: the game unloads the Hub
SetHub(false); Stream()
Tick(3)
Case("Hub gone: both add-ons unloaded", A1.Load == false and A2.Load == false and not A1.Vis and not A2.Vis)
Case("unload logged", Logged("HubCozyCorner: /Game/ITR/Levels/Hub/L_Hub is gone"))

-- back to the Hub: the same entries are used again, the pallet of the reloaded Hub is hidden again
local CreatesBefore = World.Creates
SetHub(true); Stream()
Tick(4)
Case("Hub again: add-ons back", A1.Vis and A2.Vis)
Case("no second streaming entry on re-entry", World.Creates == CreatesBefore and World.Creates == 2, World.Creates)
local Pallet2 = Actors["/Game/ITR/Levels/Hub/L_Hub.L_Hub:PersistentLevel.SM_Props_WoodenPallet_01_a6"]
Case("reloaded Hub: the new pallet is hidden", Pallet2 ~= Pallet and Pallet2.bHidden == true and Pallet2.Collision == false)

-- someone else unloads an add-on while the Hub stays (the map loader's teardown): the mod waits instead of fighting
A1.Load, A1.WantVis = false, false; Stream()
Tick(3)
Case("unloaded by someone else: not asked again at once", A1.Load == false and Logged("unloaded by something else"))
Tick(10)
Case("asked again after the back-off", A1.Load == true and A1.Vis)

-- a new world (back to the main menu and Continue again)
World = NewWorld({ "/Game/ITR/Levels/Hub/L_Hub" })
SetHub(true); Stream()
Tick(4)
Case("new world: fresh entries, streamed in", (World.Creates or 0) == 2 and AddonStream("HubCozyCorner").Vis and Logged("new world"))

print = RealPrint
print(string.format("%d case(s), %d failed", N, Failed))
os.exit(Failed == 0 and 0 or 1)
