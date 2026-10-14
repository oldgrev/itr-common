# ITRMapLoader (UE4SS Lua)

A small UE4SS script that gets you into a custom map in Into the Radius 1 (2.7.2) and back out again. The game
can't load custom maps yet, so you need something like this to get into one.

When you arrive in the Hub (or press a key), it streams your map in and moves you to the map's start marker. When
you step on one of the map's exit markers, it takes you back to the Hub and unloads the map.

A copy of this loader configured for a large map (with its loot manifest, `AutoLoadInHub`) is in
[`itr-showcase/loader`](../../itr-showcase/loader/).

## What's new (untested in Lua)
The Hub teardown, multiple exits, the re-entry memory, gameplay activation and loot registration were added after the
testing described below. **None of the new parts of this Lua loader have been run through a Hub load yet.** They are
ports of what our C++ mod (aiMod) does. aiMod's versions of the Hub teardown, the exit through the game's Hub load,
and the gameplay activation have since passed our `-nohmd` harness runs (an automated game run with scripted checks, see
[`extended.md`](../map-making/extended.md)), but not VR. The loot registration passed the harness too, in aiMod's C++
form. What has been seen of the Lua one: with UE4SS installed in the standard layout (below), alongside aiMod, a
`-nohmd` launch started the loader and `UE4SS.log` showed `[ITRMapLoader] ready: 1 map(s); ...`. A run that loads the map
through Lua hasn't happened yet.
- **Hub teardown.** While a map is loaded, all of the Hub's streaming levels are unloaded (see "Why the Hub teardown
  exists" at the end). On by default; `HubTeardown = false` brings back the old behaviour.
- **Multiple exits.** Any number of `TargetPoint`s tagged `itr:exit` work. An exit can also carry an id.
- **Re-entry memory.** The loader remembers which exit (by id) you left through, and next time puts you at the
  matching arrive marker.

- **Gameplay activation.** About 3 s after you arrive, the map's gameplay actors (loot points, stashes, anomalies,
  monster spawners and generators; everything that derives from `PRBasicActor`) are sent the level-start events the
  game only fires for levels it loads itself. Without it, a streamed map's spawners, loot and anomalies sit idle.
  Port of what aiMod does (the harness-tested C++ version; [`extended.md`](../map-making/extended.md) has the write-up), untested in this loader. See "Gameplay activation".

## What we've tested
We tested the original loader (map entry, one exit marker, no teardown) in October 2026 with UE4SS 3.0.1 and the
[example map](../example-map/):
- In VR (SteamVR), installed the way the Nexus page describes: the map loaded about 7 s after the Hub finished
  loading, we were moved to the start, enemies we spawned stood on the navmesh, and the exit pad took us back and
  unloaded the map.
- We got the same result with our first install layout (see the end of the install section).
- It runs fine next to a mod that uses an `XINPUT1_3.dll` proxy.

Not tested yet:
- Everything under "What's new". In particular, whether `LevelManager::LoadLevel(Level.Hub)` called from Lua behaves
  as it does in aiMod, and whether `GetMovementBase` works on the VR pawn (the loader falls back to comparing
  positions if it doesn't).
- The F7 key. It calls the same load and unload code, so it should be fine.
- Going into the Hub with the menu's Continue button. Our test used a shortcut into the Hub, and the script waits
  for the game's level manager to say it's ready, so Continue should work the same way.
- Installing UE4SS through Vortex. The mod page says the ITR extension expects this exact build.
- On desktop (`-nohmd`) the auto-load never fires. In that mode the game doesn't seem to finish moving you into the
  Hub, so the level manager never reports ready. It isn't a real way to play anyway.

## Installing
1. **UE4SS.** We used "UE4SS for ITR1" from Nexus Mods (https://www.nexusmods.com/intotheradiusvr/mods/359), a
   repack of UE4SS 3.0.1 by MerithXYZ, file `UE4SS-ITR-359-v3-0-1-321-gc62ada0`. Use Vortex with the Into the Radius
   extension, or do what the mod page says for a manual install:
   - put `dwmapi.dll` and `override.txt` in `<game>\IntoTheRadius\Binaries\Win64\`. `override.txt` just contains
     `../../Content/Paks`, which tells `dwmapi.dll` where to find `UE4SS.dll`;
   - put the **contents** of the zip's `ue4ss\` folder in `<game>\IntoTheRadius\Content\Paks\`, so `UE4SS.dll`,
     `UE4SS-settings.ini` and the `Mods` folder end up directly in `Paks`;
   - in `Paks`, rename `Mods` to `LuaMods`. This build's `UE4SS-settings.ini` has `ModsFolderPath = ./LuaMods`, and
     if you skip the rename, `UE4SS.log` shows a `directory_iterator` error and no Lua mods start at all.

   Our first layout also worked: `dwmapi.dll` and the whole `ue4ss` folder in `Binaries\Win64`, no `override.txt`,
   and `Mods` renamed to `LuaMods` inside the `ue4ss` folder.

   **The standard UE4SS 3 layout** is another option, and it's what a plain UE4SS release is made for: `dwmapi.dll` and
   the release's `ue4ss\` folder (with `UE4SS.dll`, `UE4SS-settings.ini` and `Mods\` inside) both go next to the
   game's `IntoTheRadius-Win64-Shipping.exe` in `Binaries\Win64`. There's no `override.txt` and nothing in
   `Content\Paks`, and `Mods` keeps its name. Put the loader in `ue4ss\Mods\` rather than `LuaMods`. Everything else
   below applies, with those folder names swapped. We installed a UE4SS 3.0.1 build this way next to a mod that uses an
   `XINPUT1_3.dll` proxy: the game started, `UE4SS.log` appeared inside `ue4ss\`, and the loader started. That's as far
   as we've gone with it, a `-nohmd` start only. Not tried in VR. Don't install both layouts at once.
2. Copy the `ITRMapLoader` folder into `LuaMods` (or `ue4ss\Mods` in the standard layout). The empty `enabled.txt` inside it turns it on, so you don't need to
   touch `mods.txt`.
3. Edit `ITRMapLoader\Scripts\config.lua`:
   - `Maps` lists your maps (a name, the level path, and the start tag);
   - `AutoLoadInHub` is the map to load when you get to the Hub, which is what you want in VR;
   - `Key` is the keyboard key, F7 by default;
   - `ExitTag` is the exit marker's tag, `itr:exit` by default.

   The rest are optional, and the defaults are in `config.lua`. `HubTeardown`, `ReEntry` and `ExitRadius` can also be
   set on a single map entry, which overrides the global value.

   | Key | Default | What it does |
   |---|---|---|
   | `ExitIdTagPrefix` | `"itr:exit_id:"` | prefix of the tag that gives an exit its id |
   | `ExitRadius` | `150` | how close (cm, horizontal) you must stand to an exit to use it |
   | `ReEntry` | `true` | remember the last exit id per map and arrive at the matching arrive marker |
   | `ArriveTagPrefix` | `"itr:arrive:"` | prefix of the arrive markers' tags |
   | `ReEntryFile` | `nil` | where the memory is kept; `nil` means `reentry.txt` next to `main.lua` |
   | `HubTeardown` | `true` | unload the Hub's streaming levels while the map is loaded |
   | `StagingMaxWestX` | `-20000` | the staging point must have a world X greater than this (cm) |
   | `HubLevelTag` | `"Level.Hub"` | the gameplay tag the exit asks the game to load |
   | `ActivateGameplay` | `true` | send the map's gameplay actors the level-start events (see "Gameplay activation") |
   | `LootRetagShim` | `false` | dev only, see "Gameplay activation" |
   | `RequireLevelManagerReady` | `true` | `false` only for desktop `-nohmd` test runs |

**If the game hangs at startup** (no window, around 12 MB of memory), there's a hidden "UE4SS Error: Failed to load
UE4SS.dll" message box behind it. It means `UE4SS.dll` isn't where `override.txt` points. We did that the
first time, by copying the `ue4ss` folder itself into `Paks` (so it ended up at `Paks\ue4ss\UE4SS.dll`) instead of
what's inside it.

To uninstall, delete `dwmapi.dll`, `override.txt` and the UE4SS files you copied (`UE4SS.dll`,
`UE4SS-settings.ini`, `LuaMods`, `LogicMods` and so on).

## Using it
- In VR, set `AutoLoadInHub = "Example"` (or whichever map name). Every time you go into the Hub the map loads once,
  and a few seconds later you're on it. To leave, walk onto an exit marker (you need to be within about 1.5 m).
- On a keyboard, F7 loads the next map in your list, and pressing it again takes you back and unloads it.
- It never loads anything from the main menu.
- `UE4SS.log` (next to `UE4SS.dll`) shows what it's doing. Look for lines starting with `[ITRMapLoader]`, like
  `streaming ...`, `Hub teardown: ...`, `teleport to ...: true`, `exit marker(s)`, `exit marker reached`, `exit: ...`
  and `unloaded <map>`. Every step of the teardown and the exit is logged.

## If you're making a map
- Put a `TargetPoint` tagged `itr:player_start` where people should arrive.
- Put another `TargetPoint` tagged `itr:exit` where they can leave, and put something visible there so they can
  find it. The example uses a small pad with a post.
- Please don't skip the exit. Without one, people in VR are stuck until they quit to the menu.

### Tag conventions
All of these go on `TargetPoint` actors in your map's level.

| Tag | Meaning |
|---|---|
| `itr:player_start` | where people arrive when nothing is remembered (the map's `StartTag`) |
| `itr:exit` | an exit. Standing within `ExitRadius` of it takes you back to the Hub. You can have as many as you like |
| `itr:exit_id:<ID>` | gives that exit an id (for example `itr:exit_id:R2`), and leaving through it is remembered. A `TargetPoint` with only this tag is an exit too |
| `itr:arrive:<ID>` | where you arrive when the last remembered exit was `<ID>`. Put it a few metres in front of that exit, not on it, or you'll leave again right away |

Re-entry works like this: you leave through the exit `itr:exit_id:R2`, and the loader writes `Example<TAB>R2` to
`reentry.txt`. The next time the map loads (even after restarting the game), you arrive at `itr:arrive:R2` if the map
has one. With no memory, an id the map has no arrive marker for, or `ReEntry = false`, you arrive at
`itr:player_start`. Leaving by key, or through an exit without an id, doesn't change what's remembered. A missing or
damaged `reentry.txt` is treated as empty (bad lines are skipped), and you can delete it to forget everything. If the
loader can't write the file, it logs that once and carries on.

For the Hub teardown the map also needs at least one `TargetPoint` (any, preferably the arrive or exit ones) whose
world X is greater than -20000, as a place to stand while the Hub unloads. If there isn't one, the teardown is
skipped with a log line and you get the old behaviour.

## How it works
Normally you'd call `LevelStreamingDynamic::LoadLevelInstance(World, Level, Location, Rotation, out bOutSuccess,
OptionalLevelNameOverride)`. UE4SS 3.0.1 can't make that call from Lua, though. After a non-struct out-parameter
like `bOutSuccess`, it leaves that parameter's table on the Lua stack, and the next argument gets read from the wrong
place. You get `[push_strproperty] StrProperty can only be set to a string or FString` in the log, and if you pass a
string where the out-parameter goes instead, it complains that "no table was on the stack".

So the script does what `LoadLevelInstance` does internally:
1. It calls `LevelStreaming::CreateInstance(<unique name>)` on an existing dynamic streaming entry, which makes a new
   entry and adds it to the world.
2. It sets that entry's `PackageNameToLoad` to your map's package.
3. It sets `LevelTransform` to identity.
4. It calls `SetShouldBeLoaded(true)` and `SetShouldBeVisible(true)`.

Your level will show up with a name like `/Game/ITR/Levels/Hub/ITRMap_Example_1`. That's just the instance name;
what actually gets loaded is your package.

Once the level is visible, the script looks for the tagged `TargetPoint`s in it and calls `K2_TeleportTo` on the
player.

"Are we in the Hub yet?" took a couple of goes to get right. While you're coming from the menu, the Hub level
already counts as visible even though you're still in the menu room. So the script also waits for
`LevelManager::IsReady()`, and checks twice, 2 s apart.

Anything that touches the game runs inside `ExecuteInGameThread`, and the timers use `LoopAsync`.

## Gameplay activation
Maps are streamed in after the Hub already went through its level-start events, so the gameplay actors in your map
never receive them. When the player has arrived (or the teardown gave up), the loader waits 3 s for the actors'
BeginPlay and then, for every `PRBasicActor` whose level is your map:
1. `OnLevelPrepare(<level tag>)` (spawner generators check whether they are excluded; one that is destroys itself),
2. on loot points (`BP_LootSpawnPoint_C` and its children, which includes stashes): `GenerateLoot()` only. The game's
   distance check (armed by `OnLevelPrepare`) spawns a point's items once the player is within `LootSpawnDistance`; calling
   `SpawnLoot()` as well spawns every item twice. A point that already spawned its items gets no `OnLevelPrepare`,
3. `OnLevelStarted(<level tag>)` (stash doors, anomalies), `OnGameStarted()`, `OnTransitionEnd()` (spawners and generators go live).

Each call goes through the actor, so Blueprint overrides run. The level tag is the game's current one (`Level.Hub` while
the Hub is torn down). The game's global events are not fired, because the game mode, the player and the UI listen to
them too. Actors that destroyed themselves are skipped by the later steps. `UE4SS.log` shows every call
(`[ITRMapLoader] activate: ...`), a count per class, and a one-line summary ending in `errors N`.
- `ActivateGameplay = false` (global or per map) turns it off.
- Loot comes from the vanilla `Loot.*` tags and budgets unless your map has custom ones. A loot manifest registers your own:
  put `<Map Name>.loot.json` next to `main.lua` (or `LootManifest = "<path>"` on the map entry; a `.loot.lua` file
  returning the same table works too). Just before the activation, `RegisterLootTags` adds each manifest tag
  (`tag`, `source_tag` donor, `loot_points`, optional `table_asset`) to the game config's `LootArray` with `TMap:Add`,
  taking the donor's DataTable (shared used points) unless the map pak includes the `table_asset`. Same as aiMod's
  `Loot.cpp`, which writes the TMap's memory by hand instead. Each add is read back and logged (`loot: tag ... added`).
  The map's tables must be kept alive by the map itself (Lua cannot add them to the GC root set): place one actor whose
  `Tables` array (instance-editable, `DataTable` object references) lists them, class `BP_ItrShowcase_LootTables` in the
  showcase. The loader takes the tables from that actor, re-points the entries at each load and points them back at the
  donor tables on unload, so `LootArray` never holds a collected table.
  `LootRetagShim = true` is a dev-only helper for the ITR Showcase map (retags its `G2_*` loot nodes and generator).
- Whether this works through UE4SS Lua is not tested. Things most likely to need a fix on the first run: calling the
  functions through the object (`A[Fn]`), the by-value `FGameplayTag` argument, and reading the level tag from
  `PRGameData`. All are logged per call.
- `RequireLevelManagerReady = false` is for desktop `-nohmd` test runs only: the game never reports its level manager
  ready there, so the "are we in the Hub" check never passes without it.

Testing this next to aiMod means switching aiMod's map handling off so the two don't both manage the map. That's
done on our side and not part of this repo.

## Why the Hub teardown exists
Maps are streamed in next to the Hub, in the same world. Two things go wrong if the Hub's levels stay loaded:
- In our aiMod tests, standing west of roughly world X -30000 with the Hub loaded sent the player back to the Hub (the
  game's level manager dropped to level None, ran the transition room and respawned them in the Hub).
- The Hub's fog and lighting (including its lighting-scenario level) apply to your map too.

So while a map is loaded, the loader replaces the Hub, in this order (it mirrors `Maps.cpp` in aiMod):
1. Stream the map in and wait until it's visible.
2. Teleport the player to a staging `TargetPoint` east of X `StagingMaxWestX`: one tagged `itr:tp:*`, `itr:arrive*` or
   `itr:exit_id*` if there is one, else any, nearest to `itr:player_start`.
3. Wait until the player stands on the map's ground (up to 15 s, otherwise the teardown is skipped). It asks the pawn
   for its movement base; if the pawn can't say, a second at the staging point counts as standing on the map.
4. Call `SetShouldBeVisible(false)` and `SetShouldBeLoaded(false)` on every other streaming level that's requested,
   loaded or visible, and wait (up to 30 s) until they're all unloaded. A level that holds the player's pawn or
   controller is kept and logged.
5. Only then teleport to the arrival point (the remembered `itr:arrive:<ID>`, or `itr:player_start`), and log whether
   the player stays there at +1, 3, 6, 10 and 20 s.

If a Hub level doesn't unload, the player stays at the staging point and the exit still works.

**Leaving** with the Hub gone:
1. While the player still stands on the map, call the game's `LevelManager::LoadLevel(Level.Hub)`. It takes a
   gameplay tag by value, so the out-parameter bug above doesn't affect it. If nothing happens within 4 s, the game
   probably believes it's still in the Hub, and the loader tries `TransferToLevel(Level.Hub, None)` on the game mode.
2. Wait until the Hub's main level is visible and the level manager is ready.
3. If the game didn't move the player, teleport them back to where they were before the map loaded.
4. Levels the game didn't bring back and that no level configuration lists (read from `SystemConfig`) are restored by
   the loader. If the configuration can't be read, only lighting-scenario levels are.
5. Unload the map, but only if it's still loaded and the player isn't standing on it. If they still are after 10 s,
   the map is kept, it's logged, and you can use the exit again.

Compared with aiMod, the port doesn't disable the zone gates and teleport exits in the persistent level (`L_Common`)
while a map is loaded, and it only checks the player's pawn and controller when deciding whether a Hub level holds
something of theirs (aiMod checks every attached or owned actor). We don't know yet whether either matters in practice.
