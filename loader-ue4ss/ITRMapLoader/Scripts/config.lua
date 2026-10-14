-- ITRMapLoader settings. Edit this file; main.lua reads it.
-- Every key below except Maps and Key is optional; the value shown is the default.
return {
    -- Your maps: the level package path (as cooked, under /Game/Mods/) and the start marker's actor tag.
    Maps = {
        {
            Name = "Example",
            Level = "/Game/Mods/Example/L_Example",
            StartTag = "itr:player_start",
            -- true only for maps with baked lighting: hides the Hub's lighting-scenario level while loaded
            -- (only matters when the Hub teardown below is off or was skipped; the teardown unloads it anyway)
            HideLightingScenario = false,
            -- Any of HubTeardown, ReEntry and ExitRadius below can also be set per map, which overrides the global value.
        },
    },

    -- Keyboard key that loads the next map (or leaves the current one and returns you to the Hub).
    -- See UE4SS's Key table for names.
    Key = "F7",

    -- Standing within ExitRadius of a TargetPoint with this tag (in the loaded map) takes you back to the Hub. The way
    -- out in VR. Any number of exits works. An exit may also carry the tag itr:exit_id:<ID> (see ExitIdTagPrefix);
    -- a TargetPoint with only that tag counts as an exit too.
    ExitTag = "itr:exit",
    ExitIdTagPrefix = "itr:exit_id:",
    ExitRadius = 150,                    -- cm, horizontal

    -- Load this map automatically each time the Hub becomes visible (a map Name from above), or nil.
    -- Useful in VR, away from the keyboard.
    AutoLoadInHub = nil,

    -- Test hook: creating this file (full path) loads the first map once, like the key. nil = off.
    TriggerFile = nil,

    -- Re-entry memory: leaving through an exit with an id remembers it per map; the next time that map loads you arrive
    -- at the TargetPoint tagged ArriveTagPrefix..<ID> (if the map has one), else at StartTag.
    ReEntry = true,
    ArriveTagPrefix = "itr:arrive:",
    -- Where the memory is kept; nil = reentry.txt next to main.lua. Delete the file to forget.
    ReEntryFile = nil,

    -- Hub teardown: while a map is loaded, unload all of the Hub's streaming levels (see the README for why). Set false
    -- to keep the Hub loaded next to the map (the old behaviour). Skipped automatically, with a log line, when the map
    -- has no TargetPoint east of StagingMaxWestX to stand on while the Hub unloads.
    HubTeardown = true,
    StagingMaxWestX = -20000,            -- world X (cm); the staging point must be east of this
    HubLevelTag = "Level.Hub",           -- the gameplay tag the exit asks the game to load

    -- Gameplay activation: a streamed map missed the Hub's level-start events, so its loot points, stashes, anomalies,
    -- spawners and generators (all PRBasicActor) sit idle. About 3 s after you arrive, the loader sends them the same
    -- events the game would (OnLevelPrepare, GenerateLoot, OnLevelStarted, OnGameStarted, OnTransitionEnd).
    -- Can also be set per map. An optional "<Map Name>.loot.lua" next to main.lua (or Map.LootManifest = path) is read
    -- just before, for the map's loot tags (registering them is a TODO, see the README).
    ActivateGameplay = true,

    -- Dev only (ITR Showcase): retag the G2_* loot nodes / generator of the showcase map to the manifest's tags (aiMod's
    -- TEMP shim). Needs the loot manifest; leave false for any other map.
    LootRetagShim = false,

    -- Testing only: a -nohmd desktop launch never reports LevelManager::IsReady() in the Hub, so the Hub check (and thus
    -- AutoLoadInHub) never passes. false = trust "Hub level visible" alone. Leave true for real play.
    RequireLevelManagerReady = true,
}
