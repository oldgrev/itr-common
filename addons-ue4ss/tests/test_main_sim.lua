-- Offline run of ITRLevelAddons/Scripts/main.lua against stubs of the UE4SS API (plain Lua 5.1, no game):
--   lua test_main_sim.lua
-- A fake world with streaming levels plays: main menu, Hub, zone transfer (Hub unloaded), back to the Hub, a new world. The level watch
-- (BP_ITRLevelWatch) is a stub that records Watch(Entry, Id); the test plays its "itraddons shown|hidden <id>" commands. It proves the add-on
-- logic (event driven: no LoopAsync, no RegisterHook) and the manifest handling, not the game streaming (that is the VR test).
local Here = "./"
local Scripts = "../ITRLevelAddons/Scripts/"
package.path = Scripts .. "?.lua;" .. package.path

local N, Failed = 0, 0
local function Case(Name, Ok, Why)
    N = N + 1
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
local Actors = {}
local function MakeLevel(Pkg)
    local Short = Pkg:gsub("^.*/", "")
    local L = Obj({ Pkg = Pkg })
    L.GetFullName = function() return "Level " .. Pkg .. "." .. Short .. ":PersistentLevel" end
    if Pkg == "/Game/ITR/Levels/Hub/L_Hub" then
        local A = Obj({ bHidden = false, Collision = true })
        A.SetActorHiddenInGame = function(self, V) self.bHidden = V end
        A.SetActorEnableCollision = function(self, V) self.Collision = V end
        Actors[Pkg .. "." .. Short .. ":PersistentLevel.SM_Props_WoodenPallet_01_a6"] = A
    end
    return L
end
local function MakeStream(Pkg, Class)
    local S = Obj({ Pkg = Pkg, Class = Class or "LevelStreamingDynamic", Load = false, Vis = false, Level = nil })
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
    local W = Obj({ Streams = {}, Spawned = 0 })
    for _, P in ipairs(Pkgs) do table.insert(W.Streams, MakeStream(P)) end
    W.StreamingLevels = { ForEach = function(self, Fn)
        for I, S in ipairs(W.Streams) do Fn(I, { get = function() return S end }) end
    end }
    W.SpawnActor = function(self, Class)
        local A = Obj({ Class = Class })
        A.Watch = function(me, Entry, Id) me.Entry, me.Id = Entry, Id end
        W.Spawned = W.Spawned + 1
        W.Watches = W.Watches or {}
        table.insert(W.Watches, A)
        return A
    end
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
local function SetHub(On) local S = StreamOf("/Game/ITR/Levels/Hub/L_Hub"); S.Load, S.WantVis = On, On end

-- ---------------------------------------------------------------- UE4SS stubs
local Lines = {}
local RealPrint = print
print = function(S) table.insert(Lines, S); if os.getenv("SIM_VERBOSE") then RealPrint("   | " .. S:gsub("\n$", "")) end end
local Counts = { LoopAsync = 0, RegisterHook = 0 }
function LoopAsync() Counts.LoopAsync = Counts.LoopAsync + 1 end
function RegisterHook() Counts.RegisterHook = Counts.RegisterHook + 1 end
function ExecuteInGameThread(Fn) Fn() end
function FName(S) return { S = S, ToString = function() return S end } end
local PakInstalled = true
local Cmds = {}
local KSL = Obj({})
KSL.ExecuteConsoleCommand = function(self, W, Cmd) table.insert(Cmds, Cmd) end
function StaticFindObject(P)
    if P == "/Script/Engine.Default__KismetSystemLibrary" then return KSL end
    if P:find("BP_ITRLevelWatch", 1, true) then return PakInstalled and Obj({ IsClass = true }) or Obj({ __valid = false }) end
    return Actors[P] or Obj({ __valid = false })
end
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
local Notifies = {}
function NotifyOnNewObject(Class, Fn) Notifies[Class] = Fn end
local Handlers = {}
function RegisterConsoleCommandHandler(N, F) Handlers[N] = F end
ModRef = { SetSharedVariable = function() end }

local function Logged(Pat) for _, L in ipairs(Lines) do if L:find(Pat) then return true end end return false end
local function CmdSeen(Pat) for _, C in ipairs(Cmds) do if C:find(Pat) then return true end end return false end
local function Cmd(Verb, Id) Handlers["itraddons"](nil, { Verb, Id }) end
-- the watch of one streaming entry plays its event
local function Event(Verb, Entry)
    local Done = false
    for _, W in ipairs(World.Watches or {}) do
        if W.Entry == Entry then Cmd(Verb, W.Id); Done = true end
    end
    return Done
end
local function AddonStream(NameS) return StreamOf("/Game/ITR/Levels/Hub/ITRAddon_" .. NameS) end
local function NewGameMode()
    Notifies["/Script/IntoTheRadius.PRGameMode"]({ GetClass = function() return { GetFName = function() return Name("BP_PRGameMode_C") end } end,
        GetFName = function() return Name("BP_PRGameMode_C_1") end })
end
local PALLET = "/Game/ITR/Levels/Hub/L_Hub.L_Hub:PersistentLevel.SM_Props_WoodenPallet_01_a6"

-- ---------------------------------------------------------------- the run
World = NewWorld({ "/Game/ITR/Levels/Menu/L_Menu" })
local Main = assert(loadfile(Scripts .. "main.lua"))
Main()
Case("two add-ons accepted, the broken one rejected", Logged("add%-on HubCozyCorner:") and Logged("add%-on SecondAddon:")
    and Logged("manifest REJECTED: Broken.json: not valid JSON"))
Case("README.txt not read as a manifest", not Logged("README"))
Case("no LoopAsync, no RegisterHook", Counts.LoopAsync == 0 and Counts.RegisterHook == 0)
Case("anchors registered (game mode, streaming entries)", Notifies["/Script/IntoTheRadius.PRGameMode"] ~= nil and Notifies["/Script/Engine.LevelStreamingDynamic"] ~= nil)

NewGameMode()
Case("main menu: nothing streamed, nothing watched", (World.Creates or 0) == 0 and (World.Spawned or 0) == 0)

-- Continue: the game world, Hub visible
World = NewWorld({ "/Game/ITR/Levels/Hub/L_Hub", "/Game/ITR/Levels/Hub/L_Hub_Gameplay", "/Game/ITR/Levels/Zone/Buffer/L_Zone_Buffer" })
SetHub(true); Stream()
NewGameMode()
local A1, A2 = AddonStream("HubCozyCorner"), AddonStream("SecondAddon")
Case("entries made for both add-ons, once", A1 ~= nil and A2 ~= nil and World.Creates == 2, tostring(World.Creates))
Case("target already visible: both add-ons asked to stream in", A1.Load and A1.WantVis and A2.Load and A2.WantVis)
Stream()
Case("watches: the Hub (one, shared) and the two add-on entries = 3", World.Spawned == 3, tostring(World.Spawned))
Case("pallet not hidden before the add-on shown event", Actors[PALLET].bHidden == false)
Case("the add-on shown event hides the pallet", Event("shown", A1) and Actors[PALLET].bHidden == true)
Event("shown", A2)
Case("missing hide actor reported", Logged("NOT FOUND %(check the name%): SM_DoesNotExist_1"))
local NLines, NSpawn = #Lines, World.Spawned
NewGameMode(); Notifies["/Script/Engine.LevelStreamingDynamic"]({})
Case("setup again changes nothing (idempotent)", #Lines == NLines and World.Spawned == NSpawn and World.Creates == 2, tostring(#Lines - NLines))

-- zone transfer: the game unloads the Hub
SetHub(false); Stream()
Event("hidden", StreamOf("/Game/ITR/Levels/Hub/L_Hub"))
Stream()
Case("Hub hidden event: both add-ons unloaded", A1.Load == false and A2.Load == false and not A1.Vis and not A2.Vis)
Case("unload logged", Logged("HubCozyCorner: /Game/ITR/Levels/Hub/L_Hub is gone"))
Event("hidden", A1)
Case("the add-on own hidden event after that is quiet", not Logged("unloaded by something else"))

-- back to the Hub: the same entries are used again
local CreatesBefore = World.Creates
SetHub(true); Stream()
Event("shown", StreamOf("/Game/ITR/Levels/Hub/L_Hub"))
Stream()
Case("Hub shown event: add-ons back, no second entry", A1.Vis and A2.Vis and World.Creates == CreatesBefore)
Event("shown", A1)
Case("reloaded Hub: the new pallet is hidden again", Actors[PALLET].bHidden == true)

-- someone else unloads an add-on while the Hub stays: logged, not fought over
A1.Load, A1.WantVis = false, false; Stream()
Event("hidden", A1)
Case("unloaded by something else: logged, not asked again", Logged("unloaded by something else") and A1.Load == false)

-- place: reply, duplicate quiet, notify
do
    local H = Handlers["itraddons"]
    Case("itraddons handler registered", type(H) == "function")
    H(nil, { "place", "name=Lvl_A", "level=/Game/Mods/MapAHub/L_MapAHub", "target=/Game/ITR/Levels/Hub/L_Hub", "notify=itrmapbind:shown" })
    Case("place taken: reply 'itrmapbind placed Lvl_A'", CmdSeen("^itrmapbind placed Lvl_A$"))
    local C0 = #Cmds
    H(nil, { "place", "name=Lvl_A", "level=/Game/Mods/MapAHub/L_MapAHub", "target=/Game/ITR/Levels/Hub/L_Hub", "notify=itrmapbind:shown" })
    Case("a repeated name is refused quietly, no second reply", #Cmds == C0 and Logged("name Lvl_A is already used"))
    H(nil, { "place", "name=Lvl_C", "level=/Game/Mods/MapAHub/L_MapAHub", "target=/Game/ITR/Levels/Hub/L_Hub" })
    Case("same level and target under another name refused, no reply", Logged("Lvl_C names the same level and target as Lvl_A") and not CmdSeen("placed Lvl_C"))
    H(nil, { "place", "name=Bad", "level=/Game/Mods/X/L_X", "target=/Game/ITR/Levels/Hub/L_Hub", "notify=oops" })
    Case("bad notify rejected", Logged("itraddons place REJECTED") and not CmdSeen("placed Bad"))
    local D = AddonStream("Lvl_A")
    Case("placed add-on streamed in at once (Hub visible)", D ~= nil and D.Load and D.WantVis)
    Stream()
    Event("shown", D)
    Case("notify command runs when the placed level is shown", CmdSeen("^itrmapbind shown ITRAddon_Lvl_A$"))
    H(nil, { "place", "name=NoTarget", "level=/Game/Mods/N/L_N", "target=/Game/ITR/Levels/Zone/Nowhere/L_Nowhere" })
    Case("target without an entry in this world: logged, still replied", Logged("L_Nowhere has no streaming entry in this world") and CmdSeen("placed NoTarget"))
end

-- a new world (back to the main menu and Continue again)
World = NewWorld({ "/Game/ITR/Levels/Hub/L_Hub", "/Game/ITR/Levels/Hub/L_Hub_Gameplay" })
SetHub(true); Stream()
NewGameMode()
Case("new world: fresh entries made and asked to stream in", AddonStream("HubCozyCorner") ~= nil and AddonStream("HubCozyCorner").Load and Logged("new world"))

-- helper pak absent: logged once, nothing happens
do
    PakInstalled = false
    World = NewWorld({ "/Game/ITR/Levels/Hub/L_Hub", "/Game/ITR/Levels/Hub/L_Hub_Gameplay" })
    SetHub(true); Stream()
    Lines = {}
    local Main2 = assert(loadfile(Scripts .. "main.lua"))
    Main2()
    NewGameMode()
    Case("no pak: 'helper pak not found' logged, nothing spawned", Logged("helper pak not found") and (World.Spawned or 0) == 0)
    local S = AddonStream("HubCozyCorner")
    Case("no pak: the add-on is not asked to load", not (S and S.Load))
end

print = RealPrint
print(string.format("%d case(s), %d failed", N, Failed))
os.exit(Failed == 0 and 0 or 1)
