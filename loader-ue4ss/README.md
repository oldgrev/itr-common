# ITRMapLoader (UE4SS Lua)

A UE4SS script that gets you into a custom map in Into the Radius 1 (2.7.2) and back out again. The game has no way
to load a custom map by itself, so you need something like this to get into one.

It registers your map with the game as a **level**, the way zones are, and then enters it through the
game's level transfer, the call a zone gate makes. You get the normal transition screen, the Hub unloading, the level
start events, loot and the arrival, and you leave the same way. This is the **native mode** and it is the default. The
older mode, which streams the map in next to the Hub, is still in the script as a fallback (see "Streaming mode").

As provided, this loader is set up for the [example map](../example-map/): in the Hub, pick up the sugar cube, and you are
on the example map. Step on its return pad and you are back in the Hub.

A second loader configured for a large map, with its loot manifest, is in [`itr-showcase/loader`](../../itr-showcase/loader/).
Both can be installed at the same time (see "Several maps").

## What was tested
The native mode with the showcase map, in VR (UE4SS 3.0.1, October 2026): picking up a Hub item ran the game's
transition, the arrival on the map had its loot, and the map's return pad took us back to the Hub through the same
transition. The example map has not been entered natively yet; the first run is the next test.

Not tested: the streaming mode's Hub teardown, multiple exits and re-entry memory beyond what its section says,
UE4SS installed through Vortex, a desktop `-nohmd` start (the game never reports the Hub as ready there, so nothing
triggers).

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

   **The standard UE4SS 3 layout** works too: `dwmapi.dll` and the release's `ue4ss\` folder (with `UE4SS.dll`,
   `UE4SS-settings.ini` and `Mods\` inside) both go next to `IntoTheRadius-Win64-Shipping.exe` in `Binaries\Win64`.
   There is no `override.txt`, nothing in `Content\Paks`, and `Mods` keeps its name. Put the loader in `ue4ss\Mods\`
   instead of `LuaMods`. In that layout `Mods\mods.txt` also needs the line `ITRMapLoader : 1`. Don't install both layouts at once.

   **If the game hangs at startup** (no window, around 12 MB of memory), there is a hidden "UE4SS Error: Failed to load
   UE4SS.dll" message box behind it: `UE4SS.dll` isn't where `override.txt` points. Usually the `ue4ss` folder itself
   was copied into `Paks` instead of what is inside it.
2. Copy the `ITRMapLoader` folder into `LuaMods` (or `ue4ss\Mods`). The empty `enabled.txt` inside turns it on.
3. Put your map's pak in `<game>\IntoTheRadius\Content\Paks\` (for the example: `zzz_ITRMap_Example_P.pak`).
4. Edit `ITRMapLoader\Scripts\config.lua` (below), start the game and Continue into the Hub.

To uninstall, delete `dwmapi.dll`, `override.txt`, the UE4SS files you copied, and the map's pak.

## Registering your own map
Everything that belongs to one map is in `config.lua`. `main.lua` holds no map names, tags, positions or triggers. Copy
the `Maps` entry and change it:

```lua
Maps = { {
    Name = "MyMap",                          -- short name; also picks the loot manifest file
    Level = "/Game/Mods/MyMap/L_MyMap",      -- the cooked level package
    StartTag = "itr:player_start",           -- tag of the TargetPoint you arrive at
    Native = true,
    NativeTag = "Level.Zone.MyMap",          -- the level's gameplay tag (this is the default)
    DisplayName = "My Map",
    NativeDonorTag = "Level.Zone.Buffer",
    NativeSaves = false,
    NativeCenter = { X = 0, Y = -600000, Z = 0 },
    NativeStart = { X = -3000, Y = -600000, Z = 20, Yaw = 0 },
    NativeTriggerMesh = "SM_Tea01D",
} },
Key = "F10",
```

### What each field means
| Field | Default | Meaning |
|---|---|---|
| `Name` | required | Short name. Names the map in the log and picks the loot manifest `Scripts/<Name>.loot.json`. |
| `Level` | required | Package path of the cooked level under `/Game/Mods/`. Its last part is the world's name, and must match the `.umap` file name. |
| `StartTag` | `itr:player_start` in the examples | Actor tag of the `TargetPoint` where you arrive. |
| `Native` | `true` | `true`: register as a game level and use the level transfer. `false`: the streaming mode. |
| `NativeTag` | `Level.Zone.<Name>` | The level's gameplay tag. Must be unique. |
| `NativeSublevel` | last part of `Level` | The level's main sublevel: the map's world name. Leave it. |
| `DisplayName` | `Name` | The level name the game shows. |
| `NativeDonorTag` | `Level.Zone.Buffer` | A stock zone whose time, inventory, generator and map-scale settings are copied into the new level. |
| `NativeSaves` | `false` | See "Saving". |
| `NativeReloadOnTide` | `false` | `true` only once the map has its own tide actor. |
| `NativeRadius` | `250000` | The level row's `MaxLevelRadius` in cm. |
| `NativeCenter` | `0, 0, 0` | Where the map sits in the world (cm), for the handheld map and map points: the centre of your playable area. |
| `NativeStart` | none | World position (cm) and yaw (degrees) the game puts you at on arrival. Use the start marker's position; without it the game searches for a `PlayerStart` and may pick another level's. |
| `NativeArriveTolerance` | `3000` | If you arrive farther than this (cm) from the start (or arrive) marker, the loader moves you there. |
| `NativeFallback` | `false` | `true`: if the registration fails, enter with the streaming mode instead. |
| `NativeTriggerMesh` | none | Entry by Hub item: grabbing a Hub prop whose static mesh has this name enters the map. `SM_Tea01D` is the sugar cube. nil = no item trigger. |
| `NativeTriggerFunction` | the Hub props' `OnGrip` | The grab event that is hooked for the item trigger. |
| `ExitTag` | `ExitTag` below | A map can use its own exit tag. |
| `NativeExitLocation` | none | A Hub gate's location tag to arrive at in the Hub; none = the Hub's `PlayerStart`. Can be set globally. |
| `LootManifest` | `Scripts/<Name>.loot.json` | Path of the loot manifest (see "Loot"). |
| `LootHolderClass` | `BP_<Name>_LootTables_C` | Class name of the actor in the map that keeps the map's loot tables alive. |

Global settings (outside `Maps`):
| Field | Default | Meaning |
|---|---|---|
| `Key` | `"F10"` | A UE4SS key name that enters the map from the Hub and leaves it again. `false` = no key. |
| `ConsoleCommand` | `"itrmap"` | A command for the game console, or for another mod through `ExecuteConsoleCommand`: `itrmap enter [MapName]`, `itrmap leave`. `false` = none. |
| `LogTag` | `"ITRMapLoader"` | The prefix of this loader's lines in `UE4SS.log`. |
| `ExitTag`, `ExitIdTagPrefix`, `ExitRadius` | `itr:exit`, `itr:exit_id:`, `150` | Exit markers (below). |
| `TriggerFile` | none | Test hook: creating this file enters the first map once. |
| `HubLevelTag` | `Level.Hub` | The level the exit transfers to. |
| `RequireLevelManagerReady` | `true` | `false` only for desktop `-nohmd` test runs. |
| `ReEntry`, `ArriveTagPrefix`, `ReEntryFile` | `true`, `itr:arrive:`, `reentry.txt` | Re-entry memory (below). |

### Getting in
A map can be entered three ways; use any of them.
- **A Hub item.** Set `NativeTriggerMesh` to the name of a Hub prop's static mesh. Picking that item up starts the
  transfer. The loader hooks `BP_PhysicsActor_C:OnGrip` and compares the grabbed actor's `Mesh`. It fires at most once
  every 10 s, only in the Hub, and only once the map is registered. `SM_Tea01D` is the sugar cube; `SM_Pumice01` (a
  pumice stone) is the only one of its kind in the Hub. Pick an item that only this loader uses.
- **A key.** `Key` enters from the Hub and leaves from the map. The default F10 is one no common ITR mod uses; avoid F5
  to F7.
- **A console command.** `itrmap enter` / `itrmap leave`. A command that names a map this loader doesn't have is left
  for other handlers.

### Getting out
Put a `TargetPoint` tagged `itr:exit` in the map where people can leave, with something visible on it (the example uses a
small pad with a post). Standing within `ExitRadius` of it takes you back to the Hub through the level transfer. The key
and `itrmap leave` do the same. Please don't skip the exit: without one, people in VR are stuck until they quit to the menu.
Leaving some other way (dying, a gate) is noticed, and the exits are disarmed.

### Tag conventions
All of these go on `TargetPoint` actors in your map's level.

| Tag | Meaning |
|---|---|
| `itr:player_start` | where people arrive when nothing is remembered (the map's `StartTag`) |
| `itr:exit` | an exit. Standing within `ExitRadius` takes you back to the Hub. As many as you like |
| `itr:exit_id:<ID>` | gives that exit an id (for example `itr:exit_id:R2`); leaving through it is remembered. A point with only this tag is an exit too |
| `itr:arrive:<ID>` | where you arrive when the last remembered exit was `<ID>`. Put it a few metres in front of that exit, not on it, or you leave again right away |

Re-entry: you leave through `itr:exit_id:R2`, and the loader writes `<Name><TAB>R2` to `reentry.txt` next to
`main.lua`. The next time the map loads, even after a game restart, you arrive at `itr:arrive:R2` if the map has one.
Leaving by key, or through an exit without an id, changes nothing. Delete the file to forget; `ReEntry = false` turns it off.

## What happens at startup (native mode)
Once the game is idle in the Hub (or the menu), the loader adds, fail-safe and checked at each step:
1. an unloaded, hidden **streaming entry** named after the map's world (`L_Example`) that points at your package;
2. a **row in the level table** (`SystemConfig.LevelConfigurations`) under `NativeTag`. The flags are copied from the donor
   zone, the tag is written last, and the loader checks that the earlier rows are unchanged and that the game accepts the tag;
3. a **map centre** for the handheld map;
4. the map's **loot tags** (see "Loot").

If a step fails, the log says why and entry stays off for the session (`NativeFallback = true` uses the streaming
mode). Entering then calls the game mode's `TransferToLevel`. The details of how the game looks a level up are in the
"Native level" comment block in `main.lua`.

## Saving
By default (`NativeSaves = false`) the level's row turns off autosave, save-on-load, save-on-exit and sleeping. So no
save file is written while you stand in the map, and no save ever names a level that exists only with the mod
installed. What you did there (loot taken, spawner state, your inventory) is written by the Hub's autosave after you
return. Quitting while inside the map loses that visit back to the last Hub save.

With `NativeSaves = true` the level row saves like a zone, but that is **not enough** for the save to load back into the map.
A save stores every gameplay tag as its name and turns the name back into a tag when it loads, and a tag the game has not
registered comes back as `None`. So without a registered level tag the save loses its level: Continue opens the Hub, and
whatever you left in the map (items on the ground, the sleep marker) is gone. Your map's tag (`Level.Zone.<Name>`, or your
`NativeTag`) is not registered by the game, so you have to register it:

1. **The tags pak.** A tag ini is read from `IntoTheRadius/Config/Tags/` at startup, and a pak can put one there. The ini is
   one line, with a file name that is yours and unique:
   ```ini
   [/Script/GameplayTags.GameplayTagsList]
   GameplayTagList=(Tag="Level.Zone.MyMap",DevComment="MyMap level; registered so a save made in the map keeps its level")
   ```
   Pack it with the mount point `../../../IntoTheRadius/Config/Tags/`, as its own small pak (about 700 bytes), and name it
   `zzz_ITRMap_<Name>_Tags_P.pak`. Don't add the ini to the map pak: a Config file changes the pak's mount point, and the map
   pak's is `../../../IntoTheRadius/Content/Mods/<Name>/`.
   Never call the ini `LevelGameplayTags.ini`: a pak file at the same path as a game file replaces it, and that one is the
   game's list of level tags.
2. **Where it goes.** Next to the map pak, in `Content\Paks` (or `Content\Paks\~mods`). The game has to be restarted after you
   add it.
3. **How to build it.** [`example-map/build-tags.ps1`](../example-map/build-tags.ps1) does steps 1 and 2 from a tag name
   (`.\build-tags.ps1 -Engine "C:\ue427\Engine" -Map MyMap [-Tag Level.Zone.Mine] [-Install]`), and the example's
   `build-map.ps1` runs it after packing the map. The example's prebuilt copy is
   [`example-map/prebuilt/zzz_ITRMap_Example_Tags_P.pak`](../example-map/prebuilt/).
4. **Check it.** The loader logs one line at startup, `tags: Level.Zone.MyMap is REGISTERED` or `NOT registered` (in
   `UE4SS.log`). Then save inside the map, quit, press Continue: you should land in the map, where you saved.

Keep the tags pak and the loader installed together. If the loader is gone and the tags pak is not, the tag is registered but
the level does not exist, so Continue can't open it. If you remove the mod entirely, a save made inside the map names a level
the game doesn't know and opens the Hub, so leave the map before you uninstall. If the registration fails at startup while the
loaded save is inside the map, the loader moves the save's level back to the Hub.

## Loot
A map can have loot nodes (`BP_LootSpawnPoint_C`, stashes). Their loot tags must exist in the game's loot config, so give the
map a manifest, `Scripts/<Name>.loot.json` (or `LootManifest = "<path>"`; a `.loot.lua` returning the same table also
works). Each entry: `tag` (your new loot tag), `source_tag` (a stock donor tag whose table and budget to borrow),
`loot_points` (the budget), and optionally `table_asset` / `table_name` (a DataTable of your own in the map pak, so your
tag does not share used points with the donor).

The game's config is loaded at engine start and the garbage collector doesn't look inside it, so a table that only the
config refers to would be collected and later crash the loot roll. So:
- the tags are registered at startup on the donor's (stock) tables;
- your own tables are kept alive by one Blueprint actor in the map, whose instance-editable array `Tables` lists them
  (class `BP_<Name>_LootTables_C`, or `LootHolderClass`);
- while the map's level is loaded the entries point at your tables, and before it goes they point back at the donor tables.

A map without loot nodes needs no manifest, and the example map has none. `Scripts/Example.loot.example.json` is a sample
manifest with both forms (a donor-only tag, and a tag with its own table). The loader ignores it; copy it to
`Scripts/<Name>.loot.json` and edit it for your map.

## Limits
- One native map per loader. To load several maps, copy the `ITRMapLoader` folder under another name (for example
  `MyMapLoader`) and give each copy its own map, `LogTag`, `ConsoleCommand`, `Key` and `NativeTriggerMesh`. Copies are
  separate UE4SS mods and don't share state. They can be installed at the same time (see below).
- Everything lives in the game's memory: the level row and map centre vanish when the game closes and are registered again
  at the next start. Nothing is written to the game's files.
- The map must be built where it sits in the world (the example is built at X 0, Y -600000). Its baked navmesh tiles are absolute.
- It never loads anything from the main menu: enter from the Hub.
- Tested with UE4SS 3.0.1 (`c62ada0`) only. The table growth and `TMap:Add` it uses work around quirks of that build.
- `UE4SS.log` (next to `UE4SS.dll`) shows what the loader does; look for lines starting with `[ITRMapLoader]` (your `LogTag`):
  `native: registering ...`, `native: level row ... added`, `native: READY`, `native trigger: ...`, `native: arrived ...`,
  `native exit ...`.

## Several maps
Two loader folders can be installed together, as the example loader and the showcase loader are. Each is its own UE4SS mod
with its own Lua state, its own registration (one level row each), its own hook on the grab event that only reacts to
its own item, and its own key and console command. `main.lua` can be the same file in both. What must differ: the map,
`LogTag`, `ConsoleCommand`, `Key` and `NativeTriggerMesh`. In the standard layout, each folder needs its own line in
`mods.txt`.

## Streaming mode (the fallback)
`Native = false` on a map keeps the original behaviour: stream the map in next to the Hub, move the player, tear down the
Hub, and activate the map's gameplay by hand. It works for the cases where the native registration can't be used. It is
less complete: the game does not know the map is a level, so there is no transition screen, saves can name the Hub
while you stand in your map, and the loader has to do by hand what the game does for a level. Settings that only matter
here: `AutoLoadInHub`, `HubTeardown`, `StagingMaxWestX`, `ActivateGameplay`, `LootRetagShim`, `HideLightingScenario`.

Tested in VR (October 2026): the map entry, one exit marker and the unload, with no Hub teardown. Not run in game: the Hub
teardown, multiple exits, the re-entry memory, gameplay activation and the loot registration of this mode.

- **Entry.** `AutoLoadInHub = "MyMap"` loads the map once per Hub visit after two checks 2 s apart, or the key does.
- **How it streams.** `LevelStreamingDynamic::LoadLevelInstance` can't be called from UE4SS 3.0.1 Lua (after a non-struct
  out-parameter it reads the next argument from the wrong stack slot). So the script does what that function does inside:
  `LevelStreaming::CreateInstance(<unique name>)` on an existing dynamic entry, `PackageNameToLoad` = your package,
  `LevelTransform` = identity, `SetShouldBeLoaded(true)`, `SetShouldBeVisible(true)`. Then it teleports the player to the
  start marker with `K2_TeleportTo`.
- **Gameplay activation.** A streamed map missed the Hub's level-start events. About 3 s after you arrive, every
  `PRBasicActor` in the map gets `OnLevelPrepare(<level tag>)`, loot points get `GenerateLoot()` (the game's
  distance check then spawns the items; calling `SpawnLoot()` as well spawns everything twice), then `OnLevelStarted`,
  `OnGameStarted` and `OnTransitionEnd`. The game's global events are not fired. `ActivateGameplay = false` turns it off.
- **Hub teardown.** With the Hub loaded, standing west of roughly world X -30000 sent the player back to the Hub, and the
  Hub's fog and lighting apply to your map. So the loader teleports to a staging `TargetPoint` east of `StagingMaxWestX`
  (preferring `itr:tp:*`, `itr:arrive*`, `itr:exit_id*`), waits until you stand on the map, unloads every other
  streaming level, and only then teleports to the arrival point. A map therefore needs at least one `TargetPoint` with
  world X greater than -20000, or the teardown is skipped.
- **Leaving.** With the Hub gone, the exit asks the game to load the Hub (`LevelManager::LoadLevel(Level.Hub)`, falling
  back to `TransferToLevel`) while you still stand on the map, waits for the Hub, restores the Hub levels the game did
  not bring back, and unloads the map once you are off it.
- `RequireLevelManagerReady = false` is for desktop `-nohmd` test runs only.
