-- forms.lua: reads and checks one map form (JSON), the small text file that describes a map to ITRMapLoader's Regions page.
-- Plain Lua 5.1, no UE4SS calls, so tests/test_forms.lua runs it offline with a stock lua.exe.
--
--   local Forms = require("forms")
--   local Form, Err, Warn = Forms.Parse(Text, "ItrShowcase.json")
--
-- Parse returns the form table, or nil and a message naming the file and the field; the third value lists warnings (unknown
-- fields), which do not reject the file. Fields (README.md has the table):
--   schema       (required) 1                                          above 1: "needs a newer ITRMapLoader"
--   name         (optional) defaults to the file name without .json    letters, digits, _ or -
--   displayName  (optional) defaults to name
--   description  (optional) one more line under the name
--   level        (required) "/Game/Mods/<Name>/L_<Name>"
--   levelTag     (optional) defaults to "Level.Zone.<name>"            logged only
--   start        (optional)  { "x": 0, "y": 0, "z": 0, "yaw": 0 }     where the player arrives (no return point, or none stored)
--   enter        (optional)  { "command": "mymapcommand" }             only for a map that loads itself: a press runs "<command> enter <name>"
--   returnpointstoragepath (optional) a short key (letters, digits, _ . -) for a value kept in the player's save; used exactly as written
--   noprepend    (optional)  accepted, does nothing today (reserved: a later version may prepend the map name)
--   saves        (optional)  false switches saving inside the map off; default true (maps save like a stock zone)
--   triggers     (optional)  list; missing or empty is fine. Kinds:
--                  { "kind": "regions" }                                a row on the Hub computer's REGIONS page
--                  { "kind": "level", "target": "/Game/ITR/Levels/Hub/L_Hub", "level": "/Game/Mods/MyMap/L_MyMap_Hub",
--                    "type": "collision" | "grab", "object": "mydoorhandle1" }   an object in the author's trigger level, streamed in while
--                                                                      the stock level "target" is visible. "object" is the actor name
--                                                                      or a path ending in it. Two triggers with one level+target are one request
--                  { "kind": "exit", "type": "collision" | "grab", "object": "myexit1" }   an object in the map's own level that leaves it
--                an unknown kind or a bad trigger is ignored with a log line
--   enabled      (optional) false skips the file

local M = {}

-- Minimal JSON decoder (objects, arrays, strings, numbers, true/false/null). Errors on malformed input, including text
-- after the value.
function M.JsonDecode(Text)
    local Pos = 1
    local function Ws() Pos = Text:find("%S", Pos) or (#Text + 1) end
    local ParseValue
    local Esc = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f", ["/"] = "/", ["\\"] = "\\", ['"'] = '"' }
    local function ParseString()
        local Out = {}
        Pos = Pos + 1
        while true do
            local C = Text:sub(Pos, Pos)
            if C == "" then error("unterminated string") end
            if C == '"' then Pos = Pos + 1; break end
            if C == "\\" then
                local N = Text:sub(Pos + 1, Pos + 1)
                if N == "u" then table.insert(Out, "?"); Pos = Pos + 6
                elseif Esc[N] then table.insert(Out, Esc[N]); Pos = Pos + 2
                else error("bad escape \\" .. N .. " at " .. Pos) end
            else
                table.insert(Out, C); Pos = Pos + 1
            end
        end
        return table.concat(Out)
    end
    ParseValue = function()
        Ws()
        local C = Text:sub(Pos, Pos)
        if C == "{" then
            local O = {}
            Pos = Pos + 1
            Ws()
            if Text:sub(Pos, Pos) == "}" then Pos = Pos + 1; return O end
            while true do
                Ws()
                if Text:sub(Pos, Pos) ~= '"' then error("object key expected at " .. Pos) end
                local K = ParseString()
                Ws()
                if Text:sub(Pos, Pos) ~= ":" then error("':' expected at " .. Pos) end
                Pos = Pos + 1
                O[K] = ParseValue()
                Ws()
                local D = Text:sub(Pos, Pos)
                Pos = Pos + 1
                if D == "}" then return O end
                if D ~= "," then error("',' or '}' expected at " .. (Pos - 1)) end
            end
        elseif C == "[" then
            local A = {}
            Pos = Pos + 1
            Ws()
            if Text:sub(Pos, Pos) == "]" then Pos = Pos + 1; return A end
            while true do
                table.insert(A, ParseValue())
                Ws()
                local D = Text:sub(Pos, Pos)
                Pos = Pos + 1
                if D == "]" then return A end
                if D ~= "," then error("',' or ']' expected at " .. (Pos - 1)) end
            end
        elseif C == '"' then
            return ParseString()
        elseif Text:sub(Pos, Pos + 3) == "true" then Pos = Pos + 4; return true
        elseif Text:sub(Pos, Pos + 4) == "false" then Pos = Pos + 5; return false
        elseif Text:sub(Pos, Pos + 3) == "null" then Pos = Pos + 4; return nil
        else
            local Num = Text:match("^-?%d+%.?%d*[eE]?[+-]?%d*", Pos)
            if not Num or Num == "" or not tonumber(Num) then error("unexpected character at " .. Pos) end
            Pos = Pos + #Num
            return tonumber(Num)
        end
    end
    local V = ParseValue()
    Ws()
    if Pos <= #Text then error("text after the JSON value at " .. Pos) end
    return V
end

local function IsPkg(S) return type(S) == "string" and S:match("^/Game/[%w_/%-]+$") ~= nil end

local Known = { schema = true, name = true, displayName = true, description = true, level = true, levelTag = true, start = true,
                enter = true, triggers = true, enabled = true, returnpointstoragepath = true, noprepend = true, saves = true,
                comment = true, ["_comment"] = true }

local HUB = "/Game/ITR/Levels/Hub/L_Hub"
local Types = { collision = true, grab = true }

-- The actor name from what the author wrote: what follows the last / . or :
local function ObjectName(S)
    if type(S) ~= "string" then return nil end
    local N = S:match("([^/%.:]+)$")
    if N and N:match("^[%w_%-]+$") then return N end
    return nil
end

-- Text: the file's contents; FileName: for messages and the default name.
function M.Parse(Text, FileName)
    FileName = FileName or "?"
    local Warn = {}
    if type(Text) ~= "string" or Text:find("%S") == nil then return nil, FileName .. ": empty file", Warn end
    Text = Text:gsub("^\239\187\191", "")                      -- UTF-8 BOM (Notepad writes one)
    local Ok, J = pcall(M.JsonDecode, Text)
    if not Ok then return nil, FileName .. ": not valid JSON (" .. tostring((tostring(J):gsub("^.-:%d+: ", ""))) .. ")", Warn end
    if type(J) ~= "table" or #J > 0 then return nil, FileName .. ": the top level must be a JSON object { ... }", Warn end
    if type(J.schema) ~= "number" or J.schema ~= math.floor(J.schema) or J.schema < 1 then
        return nil, FileName .. ": 'schema' is required and must be 1", Warn
    end
    if J.schema > 1 then return nil, FileName .. ": schema " .. J.schema .. " needs a newer ITRMapLoader", Warn end
    for K in pairs(J) do
        if not Known[K] then table.insert(Warn, FileName .. ": unknown field '" .. tostring(K) .. "' ignored") end
    end
    local Stem = FileName:gsub("^.*[/\\]", ""):gsub("%.[Jj][Ss][Oo][Nn]$", "")
    local F = { File = FileName, Name = J.name or Stem, Level = J.level, Enabled = J.enabled ~= false, Triggers = {} }
    if type(F.Name) ~= "string" or not F.Name:match("^[%w_%-]+$") then
        return nil, FileName .. ": 'name' must be letters, digits, _ or - (got '" .. tostring(F.Name) .. "'" .. (J.name == nil and ", from the file name" or "") .. ")", Warn
    end
    if not IsPkg(F.Level) then return nil, FileName .. ": 'level' must be a package path like /Game/Mods/MyMap/L_MyMap", Warn end
    if J.enabled ~= nil and type(J.enabled) ~= "boolean" then return nil, FileName .. ": 'enabled' must be true or false", Warn end
    if J.enter ~= nil then
        if type(J.enter) ~= "table" or (J.enter.command ~= nil and (type(J.enter.command) ~= "string" or not J.enter.command:match("^[%w_]+$"))) then
            return nil, FileName .. ": 'enter.command' must be letters, digits or _: the console command of the mod that enters the map", Warn
        end
        F.Command = J.enter.command
    end
    if J.saves ~= nil and type(J.saves) ~= "boolean" then return nil, FileName .. ": 'saves' must be true or false", Warn end
    F.Saves = J.saves ~= false
    F.NoPrepend = J.noprepend == true                     -- accepted quietly; does nothing yet
    if J.returnpointstoragepath ~= nil then
        local K = J.returnpointstoragepath
        if type(K) == "string" and K:match("^[%w_%.%-]+$") then
            F.ReturnKey = K                                -- exactly as written
        else
            table.insert(Warn, FileName .. ": 'returnpointstoragepath' must be letters, digits, _ . or - : ignored, players arrive at start")
        end
    end
    F.Display = F.Name
    if J.displayName ~= nil then
        if type(J.displayName) ~= "string" or J.displayName == "" then return nil, FileName .. ": 'displayName' must be text", Warn end
        F.Display = J.displayName
    end
    if J.description ~= nil then
        if type(J.description) ~= "string" then return nil, FileName .. ": 'description' must be text", Warn end
        if J.description ~= "" then F.Desc = J.description end
    end
    F.Tag = "Level.Zone." .. F.Name
    if J.levelTag ~= nil then
        if type(J.levelTag) ~= "string" or J.levelTag == "" then return nil, FileName .. ": 'levelTag' must be text", Warn end
        F.Tag = J.levelTag
    end
    if J.start ~= nil then
        local S = J.start
        if type(S) ~= "table" or type(S.x) ~= "number" or type(S.y) ~= "number" or type(S.z) ~= "number" or (S.yaw ~= nil and type(S.yaw) ~= "number") then
            return nil, FileName .. ": 'start' must be { \"x\": n, \"y\": n, \"z\": n } with an optional \"yaw\"", Warn
        end
        F.Start = { X = S.x, Y = S.y, Z = S.z, Yaw = S.yaw or 0 }
    end
    F.Levels, F.Items, F.Exits, F.Regions = {}, {}, {}, false     -- F.Items stays an empty list: kind 'item' is gone
    if J.triggers ~= nil then
        if type(J.triggers) ~= "table" then return nil, FileName .. ": 'triggers' must be a list", Warn end
        -- A bad trigger loses only that trigger: the map stays registered.
        local Groups = {}
        for I, T in ipairs(J.triggers) do
            local function Bad(Why, Kind) table.insert(Warn, FileName .. ": trigger " .. I .. (Kind and (" (" .. Kind .. ")") or "") .. ": " .. Why .. ": ignored") end
            if type(T) ~= "table" then
                Bad("must be an object { \"kind\": ... }")
            elseif T.kind == "regions" then
                F.Regions = true
                table.insert(F.Triggers, { Index = I, Kind = "regions" })
            elseif T.kind == "level" or T.kind == "exit" then
                local Kind = T.kind
                local Name = ObjectName(T.object)
                local Target = T.target
                if Kind == "level" and Target == nil then Target = HUB end
                if Kind == "level" and not IsPkg(T.level) then
                    Bad("'level' must be a package path like /Game/Mods/MyMap/L_MyMap_Hub", Kind)
                elseif Kind == "level" and not IsPkg(Target) then
                    Bad("'target' must be a stock level package like " .. HUB, Kind)
                elseif not Types[T.type] then
                    Bad("'type' must be collision or grab (got '" .. tostring(T.type) .. "')", Kind)
                elseif not Name then
                    Bad("'object' must be the actor's name (letters, digits, _ or -), or a path ending in it", Kind)
                else
                    local Rec = { Index = I, Kind = Kind, Type = T.type, Object = T.object, ObjectName = Name }
                    if Kind == "level" then
                        Rec.Level, Rec.Target = T.level, Target
                        local Key = Rec.Level .. "|" .. Target
                        local G = Groups[Key]
                        if not G then
                            G = { Index = I, Level = Rec.Level, Target = Target, Triggers = {} }
                            Groups[Key] = G
                            table.insert(F.Levels, G)     -- one stream request per level+target
                        end
                        table.insert(G.Triggers, Rec)
                    else
                        table.insert(F.Exits, Rec)
                    end
                    table.insert(F.Triggers, Rec)
                end
            else
                table.insert(Warn, FileName .. ": trigger " .. I .. ": unknown kind '" .. tostring(T.kind) .. "' ignored")
            end
        end
    end
    return F, nil, Warn
end

-- The map record the loader works with (main.lua's native-map fields). A form with enter.command is handed back to that mod: Handback, never registered.
function M.ToMap(F)
    local S = F.Start
    return { Name = F.Name, DisplayName = F.Display, Desc = F.Desc, Level = F.Level, Command = F.Command, Handback = F.Command ~= nil,
        Regions = F.Regions, FromForm = true, Native = true, StartTag = "itr:player_start", NativeTag = F.Tag,
        NativeStart = S, NativeCenter = S and { X = S.X, Y = S.Y, Z = 0 } or nil, NativeRadius = 250000, NativeSaves = F.Saves,
        ReturnKey = F.ReturnKey, LevelGroups = F.Levels, ExitTriggers = F.Exits, File = F.File }
end

-- List = { { Name = "file.json", Path = "full path" }, ... }. Reads each file with io.open and checks it. Returns the accepted forms
-- (sorted by display name, ignoring case), a list of log lines, and the number of files refused. A duplicate name: the first file
-- (by file name) wins and the later one is refused.
function M.Load(List)
    local Forms, Lines, Refused = {}, {}, 0
    local ByName = {}
    local function Line(S) table.insert(Lines, S) end
    local Sorted = {}
    for _, E in ipairs(List) do table.insert(Sorted, E) end
    table.sort(Sorted, function(A, B) return A.Name:lower() < B.Name:lower() end)
    for _, E in ipairs(Sorted) do
        local Text
        local Ok, H = pcall(io.open, E.Path, "rb")
        if Ok and H then Text = H:read("*a"); H:close() end
        if not Text then
            Refused = Refused + 1
            Line("form " .. E.Name .. " refused: cannot read " .. tostring(E.Path))
        else
            local F, Err, Warn = M.Parse(Text, E.Name)
            for _, W in ipairs(Warn or {}) do Line("form " .. W) end
            if not F then
                Refused = Refused + 1
                Line("form " .. E.Name .. " refused: " .. Err:sub(#E.Name + 3))
            elseif not F.Enabled then
                Line("form " .. E.Name .. ": " .. F.Name .. " is switched off (enabled = false)")
            elseif ByName[F.Name:lower()] then
                Refused = Refused + 1
                Line("form " .. E.Name .. " refused: the name " .. F.Name .. " is already used by " .. ByName[F.Name:lower()])
            else
                ByName[F.Name:lower()] = E.Name
                table.insert(Forms, F)
            end
        end
    end
    table.sort(Forms, function(A, B)
        local a, b = A.Display:lower(), B.Display:lower()
        if a ~= b then return a < b end
        return A.Name:lower() < B.Name:lower()
    end)
    return Forms, Lines, Refused
end

return M
