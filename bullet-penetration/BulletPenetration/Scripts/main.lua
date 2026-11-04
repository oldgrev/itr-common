-- BulletPenetration: tells the game to spawn BP_PenBulletProjectile (from BulletPenetration_P.pak) for every bullet. The penetration itself runs in the Blueprint.
-- This script only (re)writes DA_AmmoConfig.BulletClassActor and the Blueprint's tunables, and offers the console command "bpen".
local Cfg = require("config")

local BpAsset = "/Game/Mods/BulletPenetration/BP_PenBulletProjectile"
local BpClassPath = BpAsset .. ".BP_PenBulletProjectile_C"
local BpCdoPath = BpAsset .. ".Default__BP_PenBulletProjectile_C"
local BpClassName = "BP_PenBulletProjectile_C"
local AmmoCfgPath = "/Game/ITR/Configurations/DA_AmmoConfig.DA_AmmoConfig"

local Scale = tonumber(Cfg.Scale) or 1
local BpClass, Cdo = nil, nil

local function Valid(O)
    if O == nil then return false end
    local Ok, V = pcall(function() return O:IsValid() end)
    return Ok and V == true
end

local function NameOf(O)
    local Ok, N = pcall(function() return O:GetFName():ToString() end)
    return Ok and N or nil
end

-- KismetSystemLibrary:LoadClassAsset_Blocking is not used: with UE4SS c62ada0 it crashed the game (null read at 0x70 inside UE4SS) because the class did not load that way.
-- If the class cannot be loaded, Apply returns false and the next trigger (map load, new AmmoConfig, the 10 s read-back) tries again; bullets stay stock meanwhile.
local function LoadClass()
    if Valid(BpClass) then return BpClass end
    BpClass, Cdo = nil, nil
    for _, Fn in ipairs({
        function() return StaticFindObject(BpClassPath) end,
        -- AssetRegistryHelpers:GetAsset = FindObject, else LoadObject on the object path: loads a pak-only asset. The global LoadAsset of UE4SS c62ada0 goes through the asset registry and does not find it.
        function()
            local Arh = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
            return Arh:GetAsset({ ObjectPath = FName(BpClassPath) })
        end,
        function() return LoadAsset(BpAsset) end,
    }) do
        local Ok, O = pcall(Fn)
        if Ok and Valid(O) and NameOf(O) == BpClassName then BpClass = O break end
    end
    return BpClass
end

local function GetCdo()
    if Valid(Cdo) then return Cdo end
    Cdo = nil
    if not LoadClass() then return nil end
    local Ok, O = pcall(StaticFindObject, BpCdoPath)
    if not (Ok and Valid(O)) then Ok, O = pcall(function() return BpClass:GetCDO() end) end
    if Ok and Valid(O) then Cdo = O end
    return Cdo
end

local function Tunables()
    return {
        Scale = Scale, PlayerOnly = Cfg.PlayerOnly and true or false,
        BudgetK = Cfg.BudgetK or 30, ProbeCapCm = Cfg.ProbeCapCm or 500, MinSpeed = Cfg.MinSpeed or 2500, MinExitSpeed = Cfg.MinExitSpeed or 2000,
        MinCos = Cfg.MinCos or 0.2, MaxPenetrations = Cfg.MaxPenetrations or 4, ExitOffsetCm = Cfg.ExitOffsetCm or 2, ConeDegrees = Cfg.ConeDegrees or 0.5,
        DamageFloor = Cfg.DamageFloor or 0.25, MinThicknessCm = Cfg.MinThicknessCm or 0.5, SheetThicknessCm = Cfg.SheetThicknessCm or 0,
        UnmarkedResistance = Cfg.UnmarkedResistance or 15, AssumedSpeed = Cfg.AssumedSpeed or 40000, EntryTrace = Cfg.EntryTrace ~= false,
        DivideByVelocityMultiplier = Cfg.DivideByVelocityMultiplier ~= false, Retire = Cfg.Retire ~= false, ChainTimeoutSec = 4,
    }
end

-- The Blueprint reads its tunables from its own variables: the class defaults (bullets spawned later) and, once, every live bullet (pooled ones already exist).
local function WriteTunables(Map, Live)
    local C = GetCdo()
    if not C then return false end
    for K, V in pairs(Map) do pcall(function() C[K] = V end) end
    if Live then
        local Ok, All = pcall(FindAllOf, BpClassName)
        if Ok and All then
            for _, I in ipairs(All) do
                if Valid(I) then
                    for K, V in pairs(Map) do pcall(function() I[K] = V end) end
                end
            end
        end
    end
    return true
end

-- Makes DA_AmmoConfig hold our class (tunables first). Returns true when it does, nil when DA_AmmoConfig is not loaded yet, false and a reason when it cannot.
local function Apply()
    local Ok, Da = pcall(StaticFindObject, AmmoCfgPath)
    if not (Ok and Valid(Da)) then return nil end
    local Ok2, Cur = pcall(function() return Da.BulletClassActor end)
    if Ok2 and Valid(Cur) and NameOf(Cur) == BpClassName then return true end
    if not LoadClass() then return false, "BP_PenBulletProjectile not found (is BulletPenetration_P.pak in ~mods?)" end
    WriteTunables(Tunables(), true)
    if not pcall(function() Da.BulletClassActor = BpClass end) then return false, "could not write DA_AmmoConfig.BulletClassActor" end
    local Ok3, Back = pcall(function() return Da.BulletClassActor end)
    if Ok3 and Valid(Back) and Back:GetAddress() == BpClass:GetAddress() then return true end
    return false, "DA_AmmoConfig.BulletClassActor did not take the class"
end

local Reported, FailTold = false, false
local function Check()
    local R, Why = Apply()
    if R == nil or Reported then return end
    if R then
        Reported = true
        print("[BulletPenetration] active\n")
    elseif Why and not FailTold then
        FailTold = true
        print("[BulletPenetration] not active yet: " .. Why .. " (retrying on the next map load or in 10 s)\n")
    end
end

-- Nothing queues before the mod is primed. UE4SS adds a mod to an unlocked list on its first ExecuteInGameThread, so that first call is an empty one made
-- from the game thread outside any action: the game mode notification (the real BP_PRGameMode_C, not Default__). Until then Later does nothing; the
-- retry below (every 10 s) and the first map load or AmmoConfig object after it do the write.
local Primed = false
local function Later()
    if not Primed then return end
    ExecuteInGameThread(function() pcall(Check) end)
end

-- Console command: bpen scale <x> | up | down | off. Writes the class defaults and every live bullet once.
local function SetScale(X)
    Scale = math.max(0, math.min(1000, X))
    WriteTunables({ Scale = Scale }, true)
end

if type(RegisterConsoleCommandHandler) == "function" then
    pcall(RegisterConsoleCommandHandler, "bpen", function(_, Params)
        local Verb = Params and Params[1] and tostring(Params[1]):lower() or ""
        if Verb == "scale" and tonumber(Params[2]) then SetScale(tonumber(Params[2]))
        elseif Verb == "up" then SetScale(Scale <= 0 and 1 or Scale * 2)
        elseif Verb == "down" then SetScale(Scale / 2 < 0.1 and 0 or Scale / 2)
        elseif Verb == "off" then SetScale(0) end
        return true
    end)
end

-- DA_AmmoConfig may not exist yet (main menu). A new AmmoConfig object or a map load triggers the write; a read-back of one property every 10 s
-- covers a reloaded asset that neither reports.
pcall(NotifyOnNewObject, "/Script/IntoTheRadius.PRGameMode", function(Obj)
    if Primed then return end
    local Ok, Cls = pcall(function() return Obj:GetClass():GetFName():ToString() end)
    local Okn, Nm = pcall(function() return Obj:GetFName():ToString() end)
    if not (Ok and Cls == "BP_PRGameMode_C") or (Okn and Nm:sub(1, 9) == "Default__") then return end
    Primed = true
    ExecuteInGameThread(function() end)
    Later()                                  -- the write that used to happen at mod start
end)
pcall(NotifyOnNewObject, "/Script/IntoTheRadius.AmmoConfig", Later)
if type(RegisterLoadMapPostHook) == "function" then pcall(RegisterLoadMapPostHook, Later) end
LoopAsync(10000, function() Later() return false end)
