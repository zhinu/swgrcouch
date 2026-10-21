-- solocamp.lua (couch-fix70, 1.0.1): the "one player only" window of the COUCH CAMPAIGN page.
-- Jules 2026-10-21: "in couch campaign if only one player is connected, and they continue or start a new run. Ask if they
-- want to start a single campaign or go back to the menu and add a second player. I think it would be better not to mix
-- the couch campaign code with the normal campaign mode." Decided the same day: no save-profile switch and no campaign
-- start from the window; it only offers the page's two existing exits.
--
-- The page (couchpage.lua) asks M.wanted before CONTINUE CAMPAIGN / an act poster / NEW CAMPAIGN runs: with no joined
-- guest it shows M.prompt in its own confirm (the replay confirm's look and focus keeper) instead of starting:
--   BACK TO MENU            -> the page closes exactly as P1's B closes it (couchpage.M.close): the main menu again,
--                              where the game's own CAMPAIGN tab plays the normal solo campaign. Nothing is started.
--   ADD A SECOND PLAYER     -> (B too) the window closes, the page and its join strip stay: P2 presses A to join.
-- A guest who joins while the window is up closes it (the page stays; P1 presses again, as a couch run).
-- No couch code runs from here: the window starts nothing, so the couch campaign and the normal campaign stay apart.
-- Config: cfg.CouchSoloPrompt (true; false = the page starts the couch run with P1 alone, as before).
local cfg = require("config")

local M = {}

-- the page's question: show the window? guests = joined guests (join.joinedList)
function M.wanted(guests)
    if cfg.CouchSoloPrompt == false then return false end
    return (tonumber(guests) or 0) < 1
end

-- the window's data (couchpage's confirm): kind "solo", entry ("continue" | "new"), n (act poster), from (the poster
-- focused again on ADD A SECOND PLAYER)
function M.prompt(entry, from, n)
    return { kind = "solo", entry = entry, n = n, from = from, title = "2 PLAYERS NEEDED",
             body = "No second player has joined. The couch campaign needs 2 or more players: press (A) on another "
                 .. "controller to join.\n\nFor a solo run, go back to the main menu and open the game's normal "
                 .. "CAMPAIGN.",
             yes = "BACK TO MENU", no = "ADD A SECOND PLAYER" }
end

return M
