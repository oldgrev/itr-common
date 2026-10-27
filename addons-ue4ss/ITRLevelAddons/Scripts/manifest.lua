-- manifest.lua: reads and checks one add-on manifest (JSON). Plain Lua 5.1, no UE4SS calls, so tests/test_manifest.lua
-- runs it offline with a stock lua.exe.
--
--   local Manifest = require("manifest")
--   local Addon, Err = Manifest.Parse(Text, "HubCozyCorner.json")
--
-- Parse returns the add-on table, or nil and a message naming the file and the field. Fields (README.md has the full list):
--   level      (required) "/Game/Mods/<Name>/L_<Name>"         the add-on level to stream in
--   target     (required) "/Game/ITR/Levels/Hub/L_Hub"         the stock level the add-on belongs to
--   name       (optional) defaults to the file name without .json
--   transform  (optional) { "location": [x, y, z], "rotation": [pitch, yaw, roll], "scale": [x, y, z] }   cm / degrees
--   hide       (optional) [ "ActorName", { "actor": "ActorName", "level": "/Game/ITR/Levels/Hub/L_Hub_Gameplay" } ]
--   enabled    (optional) false turns the add-on off without deleting the file

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

local function Vec3(V, What)
    if type(V) ~= "table" or #V ~= 3 then return nil, What .. " must be a list of 3 numbers" end
    for I = 1, 3 do
        if type(V[I]) ~= "number" then return nil, What .. " must be a list of 3 numbers" end
    end
    return { V[1], V[2], V[3] }
end

local Known = { name = true, level = true, target = true, transform = true, hide = true, enabled = true, comment = true, ["_comment"] = true }

-- Text: the file's contents; FileName: for messages and the default name. Returns Addon or nil, Err; the third value lists
-- warnings (unknown fields), which do not reject the file.
function M.Parse(Text, FileName)
    FileName = FileName or "?"
    local Warn = {}
    if type(Text) ~= "string" or Text:find("%S") == nil then return nil, FileName .. ": empty file", Warn end
    Text = Text:gsub("^\239\187\191", "")                      -- UTF-8 BOM (Notepad writes one)
    local Ok, J = pcall(M.JsonDecode, Text)
    if not Ok then return nil, FileName .. ": not valid JSON (" .. tostring(J):gsub("^.-:%d+: ", "") .. ")", Warn end
    if type(J) ~= "table" or #J > 0 then return nil, FileName .. ": the top level must be a JSON object { ... }", Warn end
    for K in pairs(J) do
        if not Known[K] then table.insert(Warn, FileName .. ": unknown field '" .. tostring(K) .. "' ignored") end
    end
    local Stem = FileName:gsub("^.*[/\\]", ""):gsub("%.[Jj][Ss][Oo][Nn]$", "")
    local A = { File = FileName, Name = J.name or Stem, Level = J.level, Target = J.target, Hide = {}, Enabled = J.enabled ~= false,
                Location = { 0, 0, 0 }, Rotation = { 0, 0, 0 }, Scale = { 1, 1, 1 } }
    if type(A.Name) ~= "string" or not A.Name:match("^[%w_%-]+$") then
        return nil, FileName .. ": 'name' must be letters, digits, _ or - (got '" .. tostring(A.Name) .. "'" .. (J.name == nil and ", from the file name" or "") .. ")", Warn
    end
    if not IsPkg(A.Level) then return nil, FileName .. ": 'level' must be a package path like /Game/Mods/MyAddon/L_MyAddon", Warn end
    if not IsPkg(A.Target) then return nil, FileName .. ": 'target' must be a stock level package like /Game/ITR/Levels/Hub/L_Hub", Warn end
    if A.Level:lower() == A.Target:lower() then return nil, FileName .. ": 'level' and 'target' are the same package", Warn end
    if J.enabled ~= nil and type(J.enabled) ~= "boolean" then return nil, FileName .. ": 'enabled' must be true or false", Warn end
    if J.transform ~= nil then
        local T = J.transform
        if type(T) ~= "table" or #T > 0 then return nil, FileName .. ": 'transform' must be an object", Warn end
        local Err
        for Key, Field in pairs({ location = "Location", rotation = "Rotation", scale = "Scale" }) do
            if T[Key] ~= nil then
                A[Field], Err = Vec3(T[Key], "transform." .. Key)
                if not A[Field] then return nil, FileName .. ": " .. Err, Warn end
            end
        end
        for K in pairs(T) do
            if K ~= "location" and K ~= "rotation" and K ~= "scale" then
                table.insert(Warn, FileName .. ": unknown field 'transform." .. tostring(K) .. "' ignored")
            end
        end
    end
    if J.hide ~= nil then
        if type(J.hide) ~= "table" then return nil, FileName .. ": 'hide' must be a list", Warn end
        for I, H in ipairs(J.hide) do
            local Actor, Lvl
            if type(H) == "string" then
                Actor, Lvl = H, A.Target
            elseif type(H) == "table" then
                Actor, Lvl = H.actor, H.level or A.Target
            end
            if type(Actor) ~= "string" or not Actor:match("^[%w_%-]+$") then
                return nil, FileName .. ": hide[" .. I .. "] must be an actor name (letters, digits, _) or { \"actor\": ..., \"level\": ... }", Warn
            end
            if not IsPkg(Lvl) then return nil, FileName .. ": hide[" .. I .. "].level must be a package path", Warn end
            table.insert(A.Hide, { Actor = Actor, Level = Lvl })
        end
    end
    return A, nil, Warn
end

-- UE FQuat from pitch / yaw / roll in degrees (the same formula as FRotator::Quaternion)
function M.Quat(Pitch, Yaw, Roll)
    local D = math.pi / 360
    local SP, CP = math.sin(Pitch * D), math.cos(Pitch * D)
    local SY, CY = math.sin(Yaw * D), math.cos(Yaw * D)
    local SR, CR = math.sin(Roll * D), math.cos(Roll * D)
    return { X = CR * SP * SY - SR * CP * CY, Y = -CR * SP * CY - SR * CP * SY, Z = CR * CP * SY - SR * SP * CY, W = CR * CP * CY + SR * SP * SY }
end

return M
