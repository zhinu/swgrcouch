-- SWGRCouch · nameedit.lua: the pad text editor of FREE MODE > OPTIONS > PLAYER NAMES (lobby.lua), an arcade-style
-- name entry: one character cell under a cursor, UP / DOWN step its character through CHARSET, LEFT / RIGHT move the
-- cursor (right of the last character is the "append" cell), X deletes, A keeps the name, B gives the old one back.
-- Why not a text box: the game ships UMG's UEditableTextBox (reflect.tsv), but the FREE MODE page is driven by our
-- own pad poll and focus traps (lobby.lua "Pad / keyboard navigation"), the game has no on-screen keyboard of its own,
-- and letter keybinds would cost the racing keyboard player its F-key binds (keyq.lua: a held bound key drops the
-- other keybind events of the frame). Keyboard users type names in settings.txt or with 'couch set Name2 Jules'.
-- The page shows text upper case (theme rowValue / statusText: ETextTransformPolicy ToUpper), so CHARSET has upper
-- case letters only; a lower case letter of a typed name (settings.txt) steps from its upper case one.
-- Pure Lua, no game calls, no module state (tools/test_names.lua).

local M = {}

M.CHARSET = { "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U",
              "V", "W", "X", "Y", "Z", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", " ", "-", ".", "'", "!", "?",
              "#", "&", "_" }
local INDEX = {}
for i, c in ipairs(M.CHARSET) do INDEX[c] = i end

M.CURSOR_L, M.CURSOR_R, M.EMPTY = "[", "]", "_"

local function chars(s)
    local out = {}
    s = tostring(s or "")
    if utf8.len(s) == nil then s = s:gsub("[\128-\255]", "?") end
    for _, cp in utf8.codes(s) do out[#out + 1] = utf8.char(cp) end
    return out
end

--- A new editor over text (max characters, default 16). The cursor starts on the last character (the append cell
--- of an empty name).
function M.new(text, max)
    max = math.tointeger(tonumber(max) or 16) or 16
    if max < 1 then max = 1 end
    local c = chars(text)
    while #c > max do c[#c] = nil end
    return { chars = c, cur = math.max(1, #c), max = max, orig = table.concat(c) }
end

local function lastCell(e) return math.min(#e.chars + 1, e.max) end

--- UP (+1) / DOWN (-1): the character under the cursor steps through CHARSET (wraps). On the append cell the first
--- step writes CHARSET[1] (up) or the last entry (down).
function M.step(e, d)
    d = (tonumber(d) or 1) < 0 and -1 or 1
    local n = #M.CHARSET
    local c = e.chars[e.cur]
    if c == nil then
        if #e.chars >= e.max then return e end
        e.chars[#e.chars + 1] = (d > 0) and M.CHARSET[1] or M.CHARSET[n]
        e.cur = #e.chars
        return e
    end
    local i = INDEX[c] or INDEX[string.upper(c)] or 0
    i = ((i - 1 + d) % n) + 1
    e.chars[e.cur] = M.CHARSET[i]
    return e
end

--- LEFT (-1) / RIGHT (+1): the cursor moves, from the first character to the append cell (none at max length).
function M.move(e, d)
    d = (tonumber(d) or 1) < 0 and -1 or 1
    local c = e.cur + d
    if c < 1 then c = 1 end
    if c > lastCell(e) then c = lastCell(e) end
    e.cur = c
    return e
end

--- X: delete the character under the cursor (on the append cell: the last character, like a backspace).
function M.delete(e)
    if e.cur > #e.chars then
        if #e.chars > 0 then e.chars[#e.chars] = nil end
        e.cur = lastCell(e)
        return e
    end
    table.remove(e.chars, e.cur)
    if e.cur > lastCell(e) then e.cur = lastCell(e) end
    return e
end

--- Keyboard Backspace: delete the character left of the cursor.
function M.backspace(e)
    if e.cur > #e.chars then return M.delete(e) end
    if e.cur > 1 then
        table.remove(e.chars, e.cur - 1)
        e.cur = e.cur - 1
    end
    return e
end

--- The name as stored: blanks trimmed / collapsed ("" = no name).
function M.text(e)
    return (table.concat(e.chars):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

function M.changed(e) return M.text(e) ~= (e.orig:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")) end

--- The row value while editing: the cursor cell in brackets ("JUL[E]S", "JULES[_]"); a blank under the cursor shows
--- as the EMPTY mark too.
function M.render(e)
    local out = {}
    for i = 1, lastCell(e) do
        local c = e.chars[i]
        if i == e.cur then
            out[#out + 1] = M.CURSOR_L .. ((c == nil or c == " ") and M.EMPTY or c) .. M.CURSOR_R
        elseif c ~= nil then
            out[#out + 1] = c
        end
    end
    return table.concat(out)
end

return M
