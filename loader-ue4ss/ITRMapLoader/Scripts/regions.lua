-- regions.lua: the one hook of the Regions page. A Blueprint cannot see the Hub computer's main page being built (WBP_MCPage_Main_C:Construct has no delegate),
-- so this file hooks that one function and hands the page's spare row (Button_Log, Text_Log) and the page's widget component to BP_ITRRegions.PageBuilt, which does
-- everything else (shows and renames the row, releases a held laser press, binds the press, switches the computer's page, fills it with one row per map, enters a map).
-- Called once, from boot.lua's step (the game mode notification), only when a map is listed. The Construct runs once per Hub arrival, from the widget component's tick.
-- The hook keeps nothing: every call looks the page, the computer and the Blueprint actor up again. Never hook WidgetInteractionComponent:PressPointerKey: it is virtual and
-- UE4SS's native hook crashes the game on the first press.
-- Lua 5.1 compatible syntax (checked with luac5.1 -p).

local R = {}
local PAGE_CONSTRUCT = "/Game/ITR/BPs/UI/ComputersPages/WBP_MCPage_Main.WBP_MCPage_Main_C:Construct"
local Logf = function(fmt, ...) print("[ITRMapLoader] regions: " .. string.format(fmt, ...) .. "\n") end

local function Valid(o)
    if o == nil then return false end
    local Ok, V = pcall(function() return o:IsValid() end)
    return Ok and V == true
end

-- Only the stock Hub level's computer counts; a map's own computer is left alone.
local function IsHubOwner(Actor)
    if not Valid(Actor) then return false end
    local Ok, N = pcall(function() return Actor:GetFullName() end)
    return Ok and type(N) == "string" and N:find("/Levels/Hub/L_Hub", 1, true) ~= nil
end

-- The Hub computer's main-page widget component whose widget is W (nil if W is not a Hub computer's page)
local function HubComponentOf(W)
    local Ok, All = pcall(FindAllOf, "BP_MissionComputer_C")
    if not (Ok and type(All) == "table") then return nil end
    for _, C in ipairs(All) do
        if Valid(C) and IsHubOwner(C) then
            local Wc = C.WC_Page_Main
            if Valid(Wc) then
                local Okw, Wo = pcall(function() return Wc:GetUserWidgetObject() end)
                if Okw and Valid(Wo) and Wo:GetAddress() == W:GetAddress() then return Wc end
            end
        end
    end
    return nil
end

local function RegionsActor()
    local Ok, All = pcall(FindAllOf, "BP_ITRRegions_C")
    if not (Ok and type(All) == "table") then return nil end
    for _, A in ipairs(All) do
        if Valid(A) then
            local OkN, N = pcall(function() return A:GetFName():ToString() end)
            if OkN and N:sub(1, 9) ~= "Default__" then return A end
        end
    end
    return nil
end

local function OnConstruct(Ctx)
    local W = Ctx:get()
    if not Valid(W) then return end
    local Wc = HubComponentOf(W)
    if not Wc then return end
    local Reg = RegionsActor()
    if not Reg then return end
    local Ok, E = pcall(function() Reg:PageBuilt(W.Button_Log, W.Text_Log, Wc) end)
    if not Ok then Logf("PageBuilt failed: %s", tostring(E)) end
end

-- Registers the hook. Returns true when it was registered.
function R.Hook()
    local Ok, Err = pcall(RegisterHook, PAGE_CONSTRUCT, function(Ctx)
        local OkC, E = pcall(OnConstruct, Ctx)
        if not OkC then Logf("Construct handling failed: %s", tostring(E)) end
    end)
    if Ok then Logf("Construct hook attached") else Logf("Construct hook NOT attached: %s", tostring(Err)) end
    return Ok
end

return R
