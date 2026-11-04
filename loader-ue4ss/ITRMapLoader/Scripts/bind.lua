-- bind.lua: makes the objects a map form names work, with the logic-only Blueprint BP_ITRTriggerBind (ITRMapLoader's helper pak).
--
-- The author places plain named objects in a level. For each trigger the form names, this spawns one helper and hands it the object:
--   collision  AttachCollision(Target, Id): the helper listens to overlaps on every part of the object. Only the player body fires it (a hand
--              reaching in does not), once per entry. NOTHING on the object is changed.
--   grab       AttachGrab(Target, Id): the helper listens to the grip event of the author's own GrippableActor / GrippableStaticMeshActor /
--              GrippableSkeletalMeshActor. Nothing is changed on the object either; making it grabbable is the author's part.
-- The helper reads the answer back in its variable Result: 0 nothing bound, 1 usable, 2 bound but nothing can be touched (collision: no part
-- overlaps the Pawn channel; grab: every part ignores Hand). Firing runs the console command "itrmapbind fire <Id>" (maps.lua handles it).
-- The helper destroys itself when its object ends play (its level streams out). Nothing here keeps a game object between events.
--
-- Objects are found by scanning the actors once per level arrival: StaticFindObject("<level>.<name>") misses actors of a level that was streamed
-- in as an add-on (measured), though GetFullName of those actors prints exactly that path.
-- No timer, no loop, no queue: every call here runs inside a console command or a level event.
-- Lua 5.1 compatible syntax (checked with luac5.1 -p).

local B = {}

local HELPER_PATH = "/Game/Mods/ITRMapLoader/BP_ITRTriggerBind.BP_ITRTriggerBind_C"
local Logf = function(fmt, ...) print("[ITRMapLoader] " .. string.format(fmt, ...) .. "\n") end
function B.SetLog(F) Logf = F end

local function Valid(o)
    if o == nil then return false end
    local Ok, V = pcall(function() return o:IsValid() end)
    return Ok and V == true
end

local HelperClass, NoPakLogged = nil, false
local function GetHelperClass()
    if Valid(HelperClass) then return HelperClass end
    local function Try(Fn) local Ok, O = pcall(Fn); if Ok and Valid(O) then return O end return nil end
    HelperClass = Try(function() return StaticFindObject(HELPER_PATH) end)
        or Try(function() return StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers"):GetAsset({ ObjectPath = FName(HELPER_PATH) }) end)
    return HelperClass
end

-- "Level /Game/.../ITRAddon_X.L_X:PersistentLevel" of a streaming entry, or nil when it is not loaded
function B.LevelPath(Entry)
    local Ok, P = pcall(function()
        local L = Entry:GetLoadedLevel()
        if not Valid(L) then return nil end
        return (L:GetFullName():gsub("^%S+%s+", "")), L:GetAddress()
    end)
    if not Ok then return nil end
    local Ok2, Addr = pcall(function() return Entry:GetLoadedLevel():GetAddress() end)
    return P, Ok2 and Addr or nil
end

-- The actors of one loaded level: name -> actor (one scan). Returns the table, the number of actors, the milliseconds the scan took.
function B.ActorsOf(LP)
    local T0 = os.clock()
    local Out, N = {}, 0
    local Ok, All = pcall(FindAllOf, "Actor")
    if Ok and type(All) == "table" then
        local Prefix = LP .. "."
        for _, A in ipairs(All) do
            local OkF, Full = pcall(function() return A:GetFullName() end)
            if OkF then
                local Path = Full:match("^%S+%s+(.+)$")
                if Path and Path:sub(1, #Prefix) == Prefix then
                    Out[Path:sub(#Prefix + 1)] = A
                    N = N + 1
                end
            end
        end
    end
    return Out, N, (os.clock() - T0) * 1000
end

local function ClassOf(A)
    local Ok, N = pcall(function() return A:GetClass():GetFName():ToString() end)
    return Ok and N or "?"
end

local function ProfileOf(A)
    local Ok, N = pcall(function() return A:K2_GetRootComponent():GetCollisionProfileName():ToString() end)
    return Ok and N or "?"
end

-- The actor the form names. Exact name first; else a single "name_<digits>" (an Outliner rename that collided keeps a number).
local function Find(Actors, Name)
    if Actors[Name] then return Actors[Name], Name end
    local Found, FoundName, Count = nil, nil, 0
    for N, A in pairs(Actors) do
        if N:sub(1, #Name + 1) == Name .. "_" and N:sub(#Name + 2):match("^%d+$") then Found, FoundName, Count = A, N, Count + 1 end
    end
    if Count == 1 then return Found, FoundName end
    return nil, nil
end

local function NamesOf(Actors)
    local List = {}
    for N in pairs(Actors) do table.insert(List, N) end
    table.sort(List)
    local Shown = {}
    for I = 1, math.min(#List, 40) do Shown[I] = List[I] end
    return table.concat(Shown, ", ") .. (#List > 40 and (", ... (" .. #List .. " in all)") or "")
end

-- Binds the triggers (records { Id, Kind, Type, ObjectName, Map }) whose object lives in the level of Entry. Where: "map X trigger N" for the log.
-- Bound[Id] = level address already bound (a reloaded level binds again, the same level never twice). Returns the number bound.
function B.Attach(Entry, Triggers, Bound, LevelName)
    local LP, LevelAddr = B.LevelPath(Entry)
    if not LP then Logf("level %s is not loaded: nothing to bind", LevelName); return 0 end
    local Todo = {}
    for _, T in ipairs(Triggers) do
        if Bound[T.Id] ~= LevelAddr then table.insert(Todo, T) end
    end
    if #Todo == 0 then return 0 end
    local Class = GetHelperClass()
    if not Class then
        if not NoPakLogged then NoPakLogged = true; Logf("helper pak not found (%s): triggers off, Regions rows still work", HELPER_PATH) end
        return 0
    end
    local Actors, N, Ms = B.ActorsOf(LP)
    Logf("level %s: %d actor(s) scanned in %.1f ms for %d trigger(s)", LevelName, N, Ms, #Todo)
    local World = require("UEHelpers").GetWorld()
    local Count = 0
    for _, T in ipairs(Todo) do
        local Where = string.format("map %s %s%s trigger '%s'", T.Map.Name, T.Kind == "exit" and "exit " or "", T.Type, T.ObjectName)
        local Target, Real = Find(Actors, T.ObjectName)
        if not Target then
            Logf("%s: object not in %s; actors there: %s", Where, LevelName, NamesOf(Actors))
        else
            if Real ~= T.ObjectName then Logf("%s: object is cooked as '%s': using it", Where, Real) end
            local Ok, H = pcall(function() return World:SpawnActor(Class, { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }) end)
            if not Ok or not Valid(H) then
                Logf("%s: helper could not be spawned (%s)", Where, tostring(H))
            else
                local Fn = T.Type == "grab" and "AttachGrab" or "AttachCollision"
                local OkC, E = pcall(function() H[Fn](H, Target, T.Id) end)
                local Result = nil
                pcall(function() Result = H.Result end)
                Bound[T.Id] = LevelAddr
                if not OkC then
                    Logf("%s: %s failed: %s", Where, Fn, tostring(E))
                elseif Result == 1 then
                    Count = Count + 1
                    Logf("%s: bound to %s (%s)", Where, Real, ClassOf(Target))
                elseif Result == 2 then
                    Count = Count + 1
                    if T.Type == "grab" then
                        Logf("%s: '%s' is grippable but the hand can't touch it (Hand is ignored; a BlockAll profile does this)", Where, Real)
                    else
                        Logf("%s: '%s' found but doesn't overlap the player (profile %s): it will not fire", Where, Real, ProfileOf(Target))
                    end
                else
                    if T.Type == "grab" then
                        Logf("%s: '%s' found but not grippable (class %s): needs GrippableActor, GrippableStaticMeshActor or GrippableSkeletalMeshActor", Where, Real, ClassOf(Target))
                    else
                        Logf("%s: '%s' has no collision component: not attached", Where, Real)
                    end
                    pcall(function() H:K2_DestroyActor() end)
                end
            end
        end
    end
    return Count
end

return B
