-- ITRMapLoader settings. Edit this file; main.lua reads it, and main.lua holds nothing that belongs to one particular map.
-- This copy is set up for the example map (example-map/): grab the sugar cube in the Hub and you arrive on the example map;
-- step on its return pad and you are back in the Hub.
--
-- To load your own map, change the Maps entry below (see "Maps" for what each field does). One loader mod loads one
-- native map. To load several maps, copy the ITRMapLoader folder under another name (for example MyMapLoader), give
-- each copy its own map, trigger (NativeTriggerMesh / Key) and ConsoleCommand, and enable both in mods.txt.
--
-- Every key below except Maps is optional; the value shown is the default.
return {
    Maps = {
        {
            -- ---- Which map ----
            -- Name: short name of the map. Also picks the loot manifest file (Scripts/<Name>.loot.json) and names the map in the log.
            Name = "Example",
            -- Level: the level package as cooked, under /Game/Mods/. The last part is the world's name and must match the
            -- .umap file name; it becomes the level's "main sublevel" the game looks up by name.
            Level = "/Game/Mods/Example/L_Example",
            -- StartTag: actor tag of the TargetPoint the player arrives at (the start marker in your map).
            StartTag = "itr:player_start",

            -- ---- How it is registered ----
            -- Native = true (default): the map is registered with the game as a level at startup (a streaming entry, a row in
            -- the game's level table and a map centre) and entered through the game's level transfer, like a zone gate does.
            -- You get the transition screen, Hub unloading, level events, loot and arrival the game normally gives a zone.
            -- Native = false: the older streaming mode, which streams the map in next to the Hub (see "Streaming mode" below).
            Native = true,
            -- NativeTag: the level's gameplay tag. Default "Level.Zone." .. Name.
            -- NativeTag = "Level.Zone.Example",
            -- DisplayName: the level name the game shows. Default Name.
            DisplayName = "Example",
            -- NativeDonorTag: a stock zone whose time, inventory, generator and map-scale settings are copied into the new level.
            NativeDonorTag = "Level.Zone.Buffer",
            -- NativeSaves: false = no autosave, save-on-load, save-on-exit or sleeping while you are in the map, so no save file
            -- ever names the level (safe if you remove the mod later; progress is kept by the Hub autosave after you return).
            -- true = the level saves like a zone; if the mod is removed, a save made there would point at a level that no
            -- longer exists, so only use it for a map you are sure stays installed. It also needs the level tag registered
            -- (a zzz_ITRMap_<Name>_Tags_P.pak, see "Saving" in the loader README), or the save loads into the Hub.
            NativeSaves = false,
            -- NativeReloadOnTide: true only once the map has its own tide actor (reloads the level when a tide happens).
            NativeReloadOnTide = false,
            -- NativeRadius: the level row's MaxLevelRadius (cm).
            NativeRadius = 50000,
            -- NativeCenter: where the map sits in the world (cm), for the handheld map and map points. Use the centre of
            -- your playable area in world coordinates (the example is built at (0, -600000, 0)).
            NativeCenter = { X = 0, Y = -600000, Z = 0 },
            -- NativeStart: where the game puts you on arrival (world cm, Yaw in degrees). Use the start marker's position;
            -- without it the game searches for a PlayerStart and may pick another level's.
            NativeStart = { X = -3000, Y = -600000, Z = 20, Yaw = 0 },
            -- NativeArriveTolerance: if you arrive farther than this (cm) from the start (or arrive) marker, you are moved there.
            -- NativeArriveTolerance = 3000,
            -- NativeFallback: true = if the native registration fails, enter with the streaming mode instead.
            -- NativeFallback = false,

            -- ---- How you get in ----
            -- NativeTriggerMesh: grabbing a Hub item whose static mesh has this name enters the map. "SM_Tea01D" is the sugar
            -- cube on the Hub's table. Give each loader mod a different item. nil = no item trigger (use Key or ConsoleCommand).
            NativeTriggerMesh = "SM_Tea01D",
            -- NativeTriggerFunction: the grab event hooked for the item trigger. This one is the Hub props' Blueprint.
            -- NativeTriggerFunction = "/Game/ITR/BPs/Items/BP_PhysicsActor.BP_PhysicsActor_C:OnGrip",

            -- ---- How you get out ----
            -- Standing within ExitRadius of a TargetPoint tagged ExitTag in the map takes you back to the Hub. The example has one,
            -- on the small pad with a post. Any number of exits works (see ExitTag below; a map can also set its own here).
            -- ExitTag = "itr:exit",
            -- NativeExitLocation: a Hub gate's location tag to arrive at in the Hub, or nil for the Hub's PlayerStart.
            -- NativeExitLocation = nil,

            -- ---- Loot (maps with loot nodes) ----
            -- The map's loot tags come from Scripts/<Name>.loot.json (or Map.LootManifest = path). Each tag borrows the budget
            -- and tables of a stock "donor" tag. The tables in the manifest are kept alive by one Blueprint actor in the map,
            -- found by its class name:
            -- LootHolderClass = "BP_Example_LootTables_C",   -- default "BP_" .. Name .. "_LootTables_C"
            -- The example map has no loot, so it needs no manifest.

            -- ---- Streaming mode only (Native = false) ----
            -- HideLightingScenario: true only for maps with baked lighting: hides the Hub's lighting-scenario level while loaded.
            HideLightingScenario = false,
            -- HubTeardown, ReEntry, ExitRadius and ActivateGameplay below can also be set per map, which overrides the global value.
        },
    },

    -- Keyboard key that enters the map, or leaves it again. A UE4SS key name; false = no key. Default F10.
    -- Give each loader mod a different key.
    Key = "F10",

    -- Console command typed in the game console (or sent by another mod):
    --   itrmap enter [MapName]    enter the map          itrmap leave    leave the map
    -- A command that names a map this loader does not have is ignored, so give each loader mod its own command name.
    -- false = no console command.
    ConsoleCommand = "itrmap",

    -- Standing within ExitRadius (cm, horizontal) of a TargetPoint with this tag (in the loaded map) takes you back to the
    -- Hub. The way out in VR. Any number of exits works. An exit may also carry the tag itr:exit_id:<ID> (see
    -- ExitIdTagPrefix); a TargetPoint with only that tag counts as an exit too.
    ExitTag = "itr:exit",
    ExitIdTagPrefix = "itr:exit_id:",
    ExitRadius = 150,

    -- Test hook: creating this file (full path) enters the first map once, like the key. nil = off.
    TriggerFile = nil,

    -- Streaming mode only: load this map automatically each time the Hub becomes visible (a map Name from above), or nil.
    -- Not used for a Native map.
    AutoLoadInHub = nil,

    -- Re-entry memory: leaving through an exit with an id remembers it per map; the next time that map loads you arrive
    -- at the TargetPoint tagged ArriveTagPrefix..<ID> (if the map has one), else at StartTag.
    ReEntry = true,
    ArriveTagPrefix = "itr:arrive:",
    -- Where the memory is kept; nil = reentry.txt next to main.lua. Delete the file to forget.
    ReEntryFile = nil,

    ---------------------------------------------------------------------------------------------------------------
    -- Streaming mode (Native = false): kept as a fallback
    ---------------------------------------------------------------------------------------------------------------
    -- Hub teardown: while a map is loaded, unload all of the Hub's streaming levels (see the README for why). Set false
    -- to keep the Hub loaded next to the map. Skipped automatically, with a log line, when the map has no TargetPoint
    -- east of StagingMaxWestX to stand on while the Hub unloads.
    HubTeardown = true,
    StagingMaxWestX = -20000,            -- world X (cm); the staging point must be east of this
    HubLevelTag = "Level.Hub",           -- the gameplay tag the exit asks the game to load (also used by the native exit)

    -- Gameplay activation: a streamed map missed the Hub's level-start events, so its loot points, stashes, anomalies,
    -- spawners and generators (all PRBasicActor) sit idle. About 3 s after you arrive, the loader sends them the same
    -- events the game would (OnLevelPrepare, GenerateLoot, OnLevelStarted, OnGameStarted, OnTransitionEnd).
    ActivateGameplay = true,

    -- Dev aid, off by default: rewrite the loot tags of nodes whose actor name starts with NodePrefix, and the generator id,
    -- for a map whose nodes still carry stock tags. See main.lua (LootRetagShim). Example:
    --   LootRetagShim = { NodePrefix = "G2_", TagPrefix = "Loot.MyMap.T1.", GeneratorId = "NPC.Generator.MyMap.A0_1" },
    LootRetagShim = false,

    -- Testing only: a -nohmd desktop launch never reports LevelManager::IsReady() in the Hub, so the Hub check never
    -- passes. false = trust "Hub level visible" alone. Leave true for real play.
    RequireLevelManagerReady = true,
}
