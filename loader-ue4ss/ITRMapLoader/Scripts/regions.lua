-- ITRMapLoader: the Regions page on the Hub's mission computer. Optional, and only for maps that ask for it.
--
-- A map is listed here only when its form has { "kind": "regions" } in "triggers" (or its config.lua entry has Regions = true). Registering a map
-- does not list it. With no listed map this file attaches no hook at all and the stock computer page is untouched.
-- The listed maps get a "REGIONS" row on the Hub computer's main page (the stock page has a hidden third row, which is shown and renamed). Pressing
-- it opens the stock Play tape page, with one row per map instead of one per tape, and the stock Back button. Pressing a map enters it, through
-- the same function every other way in uses (maps.lua EnterMap).
--
-- Events only, no loop, no timer, no Tick:
--   * NotifyOnNewObject(page class), registered at load when a map could be listed: the first main page object means the classes are loaded,
--     so one tick later the hooks below are attached (if a map is listed by then).
--   * WBP_MCPage_Main_C:Construct (post): the page collapsed its spare rows -> the REGIONS row is shown.
--   * BP_PRPlayerCharacter_IKv4_C:InteractLeft / :InteractRight (post): the player's laser button went down or up and any press has
--     been delivered. If it hit the Hub computer's main page, the button reporting IsPressed() decides what it means; otherwise it
--     returns at once. NEVER hook WidgetInteractionComponent:PressPointerKey: it is virtual, Blueprint calls it with
--     EX_VirtualFunction, and UE4SS's native hook then reads name data as a UFunction pointer and crashes the game on the first press
--     (it registers without complaint).
--   * WBP_Element_TapeRecord_C row press, attached at the first press of REGIONS: a map row was pressed.
-- The forms are read, the trigger levels asked for and the triggers bound by maps.lua (from the game's level events), not here.
-- A Blueprint function cannot be hooked at mod start (UFunction::Func is still 0x0, and the error ends the whole mod). Script hooks
-- run only the first callback given to RegisterHook, after the function's bytecode: never pass an empty first callback.
-- Never call ExecuteInGameThread from inside a game-thread action (or anything an action calls synchronously): UE4SS c62ada0 can
-- reallocate its queue under the running pass and crash the game.
-- No game object is kept between events (a level change destroys them): every event looks its objects up again.
-- Lua 5.1 compatible syntax (checked with luac5.1 -p).

local R = {}

local TAG = "[ITRMapLoader] regions: "
local function Log(fmt, ...) print(TAG .. string.format(fmt, ...) .. "\n") end
local function Valid(o)
    if o == nil then return false end
    local Ok, V = pcall(function() return o:IsValid() end)
    return Ok and V == true
end

local MapsMod = nil           -- maps.lua, handed in by Start
local OkCfg, Config = pcall(require, "config")
if not OkCfg or type(Config) ~= "table" then Config = {} end

local PAGE_CLASS = "/Game/ITR/BPs/UI/ComputersPages/WBP_MCPage_Main.WBP_MCPage_Main_C"
local PAGE_CLASS_NAME = "WBP_MCPage_Main_C"
local PLAYER_CLASS = "/Game/ITR/Player/BP_PRPlayerCharacter_IKv4.BP_PRPlayerCharacter_IKv4_C"
local ROW_CLASS = "/Game/ITR/BPs/UI/PagesElements/WBP_Element_TapeRecord.WBP_Element_TapeRecord_C"
local ROW_PRESS = ROW_CLASS .. ":BndEvt__Button_Mission_K2Node_ComponentBoundEvent_0_OnButtonPressedEvent__DelegateSignature"
local ROW_PREFIX = "ITRMapRow."     -- kept in the row's recordTag: the row carries its map, so Lua holds no widget and no address
local VIS_VISIBLE = 0               -- ESlateVisibility
local LABEL_ROW, LABEL_NONE = "REGIONS", "NO REGIONS INSTALLED"
local DebounceMs = 500

local function Now() return os.clock() * 1000 end
local LastActionMs = -1e9

-- ---- the map list ---------------------------------------------------------------------------------------------------------
-- { Name, Display, Desc, Command, Tag, Level, Source, Map } of the listed maps, sorted by display name. Built when asked, from the form maps that asked
-- (maps.lua Listed: installed levels only) and the config maps that asked (Regions = true).
local function ListedMaps()
    local Out = {}
    if MapsMod then
        for _, F in ipairs(MapsMod.Listed()) do
            table.insert(Out, { Name = F.Name, Display = F.DisplayName, Desc = F.Desc, Command = F.Command, Tag = F.NativeTag, Level = F.Level, Source = "form", Map = F })
        end
    end
    local Cmd = Config.ConsoleCommand
    if Cmd == nil then Cmd = "itrmap" end
    if type(Config.Maps) == "table" then
        for _, M in ipairs(Config.Maps) do
            if M.Regions == true and type(M.Name) == "string" then
                local Dup = false
                for _, X in ipairs(Out) do if X.Name:lower() == M.Name:lower() then Dup = true end end
                if Dup then
                    Log("config map %s is not listed: a form with the same name wins", M.Name)
                elseif not Cmd then
                    Log("config map %s is not listed: ConsoleCommand is false, so nothing can enter it from Regions", M.Name)
                else
                    table.insert(Out, { Name = M.Name, Display = M.DisplayName or M.Name, Desc = M.RegionsDesc, Command = Cmd,
                        Tag = M.NativeTag or ("Level.Zone." .. M.Name), Level = M.Level, Source = "config" })
                end
            end
        end
    end
    table.sort(Out, function(A, B)
        local a, b = A.Display:lower(), B.Display:lower()
        if a ~= b then return a < b end
        return A.Name:lower() < B.Name:lower()
    end)
    return Out
end

function R.Maps() return ListedMaps() end

-- ---- page helpers ---------------------------------------------------------------------------------------------------
local function Parts(W)
    local P = {}
    local Ok = pcall(function() P.Log, P.TLog = W.Button_Log, W.Text_Log end)
    if not Ok then return nil end
    for _, K in ipairs({ "Log", "TLog" }) do
        if not Valid(P[K]) then return nil end
    end
    return P
end

local function SetText(T, S) pcall(function() T:SetText(FText(S)) end) end
local function Pressed(B)
    local Ok, V = pcall(function() return B:IsPressed() end)
    return Ok and V == true
end

-- The page, drawn again (it is a manually redrawn widget component)
local function Redraw(Wc) if Valid(Wc) then pcall(function() Wc:RequestRenderUpdate() end) end end

local function EntryText(Map)
    local T = string.upper(Map.Display)
    if Map.Desc then T = T .. "\n" .. Map.Desc end
    return T
end

-- The row REGIONS: the stock Construct collapsed the spare Log row; show it with its new name
local function ViewMain(P)
    SetText(P.TLog, LABEL_ROW)
    pcall(function() P.Log:SetVisibility(VIS_VISIBLE) end)
end

-- Is this actor the Hub computer? Only the stock Hub level's computer counts; a map's own computer is left alone.
local function IsHubOwner(Actor)
    if not Valid(Actor) then return false end
    local Ok, N = pcall(function() return Actor:GetFullName() end)
    return Ok and type(N) == "string" and N:find("/Levels/Hub/L_Hub", 1, true) ~= nil
end

local function ClassNameOf(O)
    local Ok, N = pcall(function() return O:GetClass():GetFName():ToString() end)
    return Ok and N or ""
end

-- The Hub computer's main-page widget component whose widget is W (nil if W is not a Hub computer's page).
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

local function HubComputer()
    local Ok, All = pcall(FindAllOf, "BP_MissionComputer_C")
    if not (Ok and type(All) == "table") then return nil end
    for _, C in ipairs(All) do
        if Valid(C) and IsHubOwner(C) then return C end
    end
    return nil
end

-- The main page was built: show the row (a Hub computer only)
local function ShowMainView(W, What)
    if not Valid(W) then Log("%s: page not valid", What); return end
    local Wc = HubComponentOf(W)
    if not Wc then Log("%s: not the Hub computer's page: left alone", What); return end
    local P = Parts(W)
    if not P then Log("%s: page parts not found", What); return end
    ViewMain(P)
    Redraw(Wc)
    Log("Hub computer main page (%s): row %s shown", What, LABEL_ROW)
end

local function EnterMap(Item)
    if Item.Map then                                   -- a form map: the one function every way in uses
        Log("entering %s from a Regions row", Item.Name)
        MapsMod.EnterMap(Item.Map, "Regions", false)
        return
    end
    Log("entering %s: %s enter %s", Item.Name, Item.Command, Item.Name)          -- a config map: its loader's own console command
    local Ok, Err = pcall(function()
        local UEHelpers = require("UEHelpers")
        local KSL = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        KSL:ExecuteConsoleCommand(UEHelpers.GetWorld(), Item.Command .. " enter " .. Item.Name, nil)
    end)
    if not Ok then Log("entering %s failed: %s", Item.Name, tostring(Err)) end
end

-- ---- the list page: the stock Play tape page, one row per map ------------------------------------------------------
-- A map row is a stock tape row (WBP_Element_TapeRecord) made here and added to the page's scroll box. It carries its map in its recordTag
-- ("ITRMapRow.<Name>"). The stock page clears and refills its rows every time it is shown, so Play tape afterwards lists tapes again and
-- nothing needs putting back. The rows never run the tape code: they are not given a tape, so a press cannot play anything.
local function OnRowPressed(Ctx)
    local Row = Ctx:get()
    if not Valid(Row) then return end
    local T = Row.recordTag.TagName:ToString()
    if T:sub(1, #ROW_PREFIX):lower() ~= ROW_PREFIX:lower() then return end     -- a stock tape, or the "none" row
    if Now() - LastActionMs < DebounceMs then return end
    LastActionMs = Now()
    local Name = T:sub(#ROW_PREFIX + 1):lower()
    -- Not queued: this hook is called from the press, not from an action, and the map's own command handler defers what it needs to.
    for _, M in ipairs(ListedMaps()) do
        if M.Name:lower() == Name then EnterMap(M); return end
    end
    Log("row pressed for %s, which is not listed", Name)
end

local RowHookAsked = false
local function FillRow(Page, Cls, Lib, PC, Text, Tag)
    local Row = Lib:Create(Page, Cls, PC)
    if not Valid(Row) then Log("row '%s' could not be created", Text); return end
    Page.SB_Tapes:AddChild(Row)
    Row.Text_RecordName:SetText(FText(Text))
    if Tag then Row.recordTag = { TagName = FName(ROW_PREFIX .. Tag) } end
end

local function OpenRegions(C)
    if not RowHookAsked then           -- attached at the first press: everything is loaded by then
        RowHookAsked = true
        RegisterHook(ROW_PRESS, function(Ctx)
            local Ok, E = pcall(OnRowPressed, Ctx)
            if not Ok then Log("row press handling failed: %s", tostring(E)) end
        end)
        Log("row press hook attached")
    end
    local T0 = os.clock()
    C:GoToTapes()                      -- stock: shows the page and runs ShowPage, which fills tape rows
    local Wc = C.WC_Page_Tapes
    local Page = Valid(Wc) and Wc:GetUserWidgetObject() or nil
    if not Valid(Page) then Log("Tapes page not found"); return end
    Page.SB_Tapes:ClearChildren()
    local Cls = StaticFindObject(ROW_CLASS)
    local Lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local PC = require("UEHelpers").GetPlayerController()
    local Maps = ListedMaps()
    for _, M in ipairs(Maps) do FillRow(Page, Cls, Lib, PC, EntryText(M), M.Name) end
    if #Maps == 0 then FillRow(Page, Cls, Lib, PC, LABEL_NONE, nil) end
    Redraw(Wc)
    Log("page opened: %d map(s) in %.0f ms", #Maps, (os.clock() - T0) * 1000)
end

-- ---- the press ------------------------------------------------------------------------------------------------------
-- InteractLeft / InteractRight (post): the player's interact button went down or up, and any press has been delivered, so IsPressed()
-- names the button that took it (on release nothing is pressed and this returns). LaserName = the laser's property name on the player.
-- Do not read the event's Pressed parameter: IsPressed() already says it. Cheap exits first. The change is made one tick later.
local function OnInteract(Ctx, LaserName)
    local Player = Ctx:get()
    if not Valid(Player) then return end
    local Wi = Player[LaserName]
    if not Valid(Wi) then return end
    local Wc = Wi:GetHoveredWidgetComponent()
    if not Valid(Wc) then return end
    local W = Wc:GetUserWidgetObject()
    if not Valid(W) or ClassNameOf(W) ~= PAGE_CLASS_NAME then return end
    if not IsHubOwner(Wc:GetOwner()) then return end
    local P = Parts(W)
    if not P then return end
    if not Pressed(P.Log) then return end
    Log("press on the Hub page: Log true")
    if Now() - LastActionMs < DebounceMs then return end
    LastActionMs = Now()
    ExecuteInGameThread(function()
        -- checked again: nothing from the hook is trusted across the tick
        if not (Valid(W) and Valid(Wc)) then return end
        local C = Wc:GetOwner()
        if not IsHubOwner(C) then return end
        local Ok, Err = pcall(OpenRegions, C)
        if not Ok then Log("press handling failed: %s", tostring(Err)) end
    end)
end

-- Test and tooling entry (no laser needed):
--   itrregions list                 log the listed maps
--   itrregions press row            open the list, as a press on REGIONS does
--   itrregions press back           stock Back: the main page
--   itrregions press entry <Name>   enter that map, as a press on its row does
--   itrregions press rowevent <Name>   call the row's own press event, so the row hook is tested end to end
local function ConsoleHandler(_, Params)
    local Verb = Params and Params[1] and tostring(Params[1]):lower() or "list"
    local Which = Params and Params[2] and tostring(Params[2]):lower() or nil
    local Arg = Params and Params[3] and tostring(Params[3]) or nil
    ExecuteInGameThread(function()
        if Verb == "list" then
            local Maps = ListedMaps()
            Log("%d listed map(s)", #Maps)
            for _, M in ipairs(Maps) do Log("  %s: display '%s', command '%s', tag %s, from %s", M.Name, M.Display, tostring(M.Command), tostring(M.Tag), M.Source) end
        elseif Verb == "press" then
            local C = HubComputer()
            if not C then Log("press %s: no Hub computer", tostring(Which)); return end
            if Which == "row" then
                local Ok, E = pcall(OpenRegions, C)
                Log("press row: %s", Ok and "done" or tostring(E))
            elseif Which == "back" then
                local Ok, E = pcall(function() C:GoToMainPage() end)
                Log("press back: %s", Ok and "done" or tostring(E))
            elseif Which == "entry" and Arg then
                for _, M in ipairs(ListedMaps()) do
                    if M.Name:lower() == Arg:lower() then EnterMap(M); return end
                end
                Log("press entry: %s is not listed", Arg)
            elseif Which == "rowevent" and Arg then
                local Ok, E = pcall(function()
                    local Page = C.WC_Page_Tapes:GetUserWidgetObject()
                    local N = Page.SB_Tapes:GetChildrenCount()
                    for I = 0, N - 1 do
                        local Row = Page.SB_Tapes:GetChildAt(I)
                        if Valid(Row) and Row.recordTag.TagName:ToString():lower() == (ROW_PREFIX .. Arg):lower() then
                            Row:BndEvt__Button_Mission_K2Node_ComponentBoundEvent_0_OnButtonPressedEvent__DelegateSignature()
                            return
                        end
                    end
                    Log("press rowevent: no row for %s among %d", Arg, N)
                end)
                if not Ok then Log("press rowevent failed: %s", tostring(E)) end
            else
                Log("press: use row, back, entry <Name> or rowevent <Name>")
            end
        else
            Log("unknown verb '%s' (use list or press)", Verb)
        end
    end)
    return true
end

-- Attach the Blueprint hooks, once, one tick after the first page object exists, and only if a map is listed by then.
-- An error here ends only this callback.
local HooksAsked = false
local function OnNewPage()
    if HooksAsked then return end
    HooksAsked = true
    ExecuteInGameThread(function()
        if #ListedMaps() == 0 then
            Log("no map asks to be listed (or its level is not installed): the computer page is left alone, no Regions hook")
            return
        end
        Log("first main page object: attaching the hooks")
        RegisterHook(PAGE_CLASS .. ":Construct", function(Ctx)
            local W = Ctx:get()
            local Ok, E = pcall(ShowMainView, W, "Construct")
            if not Ok then Log("Construct handling failed: %s", tostring(E)) end
        end)
        Log("Construct hook attached")
        for Event, Laser in pairs({ InteractLeft = "WidgetInteractionLeft", InteractRight = "WidgetInteractionRight" }) do
            RegisterHook(PLAYER_CLASS .. ":" .. Event, function(Ctx)
                local Ok, E = pcall(OnInteract, Ctx, Laser)
                if not Ok then Log("%s handling failed: %s", Event, tostring(E)) end
            end)
            Log("%s hook attached", Event)
        end
    end)
end

-- Api = { Maps = the maps.lua module (the forms are read already) }
function R.Start(Api)
    MapsMod = Api and Api.Maps or nil
    local OkC = false
    if type(RegisterConsoleCommandHandler) == "function" then
        OkC = pcall(RegisterConsoleCommandHandler, "itrregions", ConsoleHandler)
    end
    -- Could any map be listed? If not, no page notification is registered either.
    local Candidates = 0
    if MapsMod then Candidates = Candidates + #MapsMod.Listed() end
    for _, M in ipairs(Config.Maps or {}) do if M.Regions == true then Candidates = Candidates + 1 end end
    if Candidates == 0 then
        Log("ready: no map asks to be listed: no hook, the stock computer page is untouched; console 'itrregions list|press' %s", OkC and "registered" or "not registered")
        return
    end
    NotifyOnNewObject(PAGE_CLASS, OnNewPage)
    Log("ready: %d map(s) ask to be listed; hooks wait for the first main page; console 'itrregions list|press' %s", Candidates, OkC and "registered" or "not registered")
end

return R
