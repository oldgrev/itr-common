# ITRMapLoader (UE4SS Lua)

This UE4SS script gets you into a custom map in Into the Radius 1 (2.7.2), and back out again.
The game cannot load custom maps on its own, so the loader handles that part for you.

By default, it tells the game to treat your map as a **level**, much like one of the existing zones.
Entering the map then uses the same level transfer as a zone gate: you get the usual transition screen,
the Hub unloads, and the game handles level-start events, loot and arrival. Leaving works the same way.
This is called **native mode**.

There is also an older fallback that loads the map alongside the Hub. See "Streaming mode" if you need it. It's kind of the worst but it's what I started with.

**The easy way in is a pak and a text file** ("Map forms", below): no Lua, no Blueprint, no copy of this mod. ITRMapLoader registers the map, enters
it, streams the levels of your triggers through ITRLevelAddons and makes the objects you named work. The `config.lua` route that follows is for
maps that need more control (several entry triggers, loot manifests, the streaming mode).

As provided, this loader has no config map: map forms are read and the Regions page lists the maps that ask for it. The [example map](../example-map/)'s
entry is in `Scripts/config.lua` as a commented block; with it uncommented, picking up the sugar cube in the Hub puts you on the example map, and stepping on its
return pad takes you back to the Hub.

The Showcase has its own loader mod, [`itr-showcase/loader`](../../itr-showcase/loader/): a separate mod in its own folder. It can be installed next to this one.

## What was tested
**Map forms and the changes around them are new and only partly tested: read "What has been run" at the end of this file before relying on anything in
"Map forms".** The older parts, as they were tested before the forms were added:

The native mode with the showcase map, in VR (UE4SS 3.0.1, October 2026): picking up a Hub item ran the game's
transition, the arrival on the map had its loot, and the map's return pad took us back to the Hub through the same
transition. The example map was entered natively once (4 November 2026, an emulated headset, a renamed copy of this loader with `NativeStart` removed
and the example pak and its tag pak installed): the game placed the player far from the map and the loader moved them to the start marker.

Not tested: the streaming mode's Hub teardown, multiple exits and re-entry memory beyond what its section says,
UE4SS installed through Vortex, a desktop `-nohmd` start (the game never reports the Hub as ready there, so nothing
triggers).

## Installing

For a first try with the config route, use the example map: its entry is in `config.lua`, commented out (step 4). For map forms, no edit is needed.

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
3. Put your map's pak in `<game>\IntoTheRadius\Content\Paks\~mods\` (create `~mods` if it isn't there; for the example: `zzz_ITRMap_Example_P.pak`). Every pak goes in `~mods`, forms in `Paks\ITRMaps`, Lua mods in `Paks\LuaMods`.
4. For the config route: Open `ITRMapLoader\Scripts\config.lua` and remove the `-- ` in front of the example block, then delete the line `Maps = {},` above it and set `Key = "F10"` if you want the key. (The block is the example map's entry; with it the sugar cube in the Hub enters the example map. The config route with this block has not been run since the block was commented out.) For a form: put the form in `Content\Paks\ITRMaps\`. Then start the game and Continue into the Hub.

To uninstall, delete `dwmapi.dll`, `override.txt`, the UE4SS files you copied, and the map's pak.

## Registering your own map
Your map settings all live in `config.lua`: names, tags, positions and triggers. You do not need to edit
`main.lua` for those. Use this `Maps` entry as a starting point, then change it to match your map:

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
| `Level` | required | Package path of the cooked level under `/Game/Mods/`. The final part is the world name and must match your `.umap` file name. |
| `StartTag` | `itr:player_start` in the examples | Actor tag of the `TargetPoint` where you arrive. |
| `Native` | `true` | `true`: register as a game level and use the level transfer. `false`: the streaming mode. |
| `NativeTag` | `Level.Zone.<Name>` | The level's gameplay tag. Must be unique. |
| `NativeSublevel` | last part of `Level` | The level's main sublevel, using the map's world name. You can leave this at its default. |
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
| `LootHolderClass` | `BP_<Name>_LootTables_C` | Streaming mode only: class name of the actor in the map that keeps the map's loot tables alive. A native map no longer needs it (the tables are loaded at startup and kept alive for the session); a placed holder actor is harmless. |

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

You have three ways to enter a map. Choose whichever suits your setup:
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
and `itrmap leave` do the same. Give VR players a visible exit: without one, they have to quit to the menu to get out.
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
Once the game is idle in the Hub (or the menu), the loader registers the map in four steps. It checks each
step before continuing, and keeps entry disabled if something goes wrong:
1. an unloaded, hidden **streaming entry** named after the map's world (`L_Example`) that points at your package;
2. a **row in the level table** (`SystemConfig.LevelConfigurations`) under `NativeTag`. The flags are copied from the donor
   zone, the tag is written last, and the loader checks that the earlier rows are unchanged and that the game accepts the tag;
3. a **map centre** for the handheld map;
4. the map's **loot tags** (see "Loot").

If a step fails, the log says why and entry stays off for the session (`NativeFallback = true` uses the streaming
mode). Entering then calls the game mode's `TransferToLevel`. The details of how the game looks a level up are in the
"Native level" comment block in `main.lua`.

## Saving
**By default, return to the Hub before quitting.** With `NativeSaves = false`, the level disables autosave,
save-on-load, save-on-exit and sleeping. Nothing is saved while you are inside the custom map, so your save
will not depend on a level that only exists while the mod is installed.

When you return, the Hub's autosave records the visit: loot taken, spawner state and your inventory.
If you quit while still inside the map, you lose progress since the last Hub save.

With `NativeSaves = true` the level row saves like a zone, but that is **not enough** for the save to load back into the map.
There is one more piece to set up: **register the map's gameplay tag** (`Level.Zone.<Name>`, or your `NativeTag`).
The game does not register this custom tag for you.

Saves store gameplay tags by name. When loading, the game turns those names back into tags; an unregistered name
becomes `None`. Without the level tag, Continue opens the Hub instead, and anything you left in the custom map
(items on the ground or the sleep marker) is lost. Here is how to register it:

1. **The tags pak.** A tag ini is read from `IntoTheRadius/Config/Tags/` at startup, and a pak can put one there. Give the ini
   a unique file name of your own and use these contents:
   ```ini
   [/Script/GameplayTags.GameplayTagsList]
   GameplayTagList=(Tag="Level.Zone.MyMap",DevComment="MyMap level; registered so a save made in the map keeps its level")
   ```
   Pack it with the mount point `../../../IntoTheRadius/Config/Tags/`, as its own small pak (about 700 bytes), and name it
   `zzz_ITRMap_<Name>_Tags_P.pak`. Don't add the ini to the map pak: a Config file changes the pak's mount point, and the map
   pak's is `../../../IntoTheRadius/Content/Mods/<Name>/`.
   Never call the ini `LevelGameplayTags.ini`: a pak file at the same path as a game file replaces it, and that one is the
   game's list of level tags.
2. **Where it goes.** Next to the map pak, in `Content\Paks\~mods`. The game has to be restarted after you
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
works). Each entry describes one loot tag:

- `tag`: your new loot tag.
- `source_tag`: an existing game tag to borrow a loot table and budget from.
- `loot_points`: the budget.
- `table_asset` / `table_name` (optional): your own DataTable in the map pak. This keeps your tag
  from sharing used points with the donor.

There is a lifetime issue to account for here. The game loads its config at engine startup, but the garbage
collector does not look inside that config. If only the config refers to a table, the table can be removed
from memory and a later loot roll will crash. The loader avoids that as follows:
- the tags are registered at startup on the donor's (stock) tables;
- a native map's own tables are loaded at startup and kept alive for the whole session, so the entries point at them from the first roll (a
  holder actor is no longer needed);
- streaming mode: your own tables are kept alive by one Blueprint actor in the map, whose instance-editable array `Tables` lists them
  (class `BP_<Name>_LootTables_C`, or `LootHolderClass`); while the map's level is loaded the entries point at your tables, and before it
  goes they point back at the donor tables.

A map without loot nodes needs no manifest, and the example map has none. `Scripts/Example.loot.example.json` is a sample
manifest with both forms (a donor-only tag, and a tag with its own table). The loader ignores it; copy it to
`Scripts/<Name>.loot.json` and edit it for your map.

## Limits
- One copy of the loader handles any number of maps: each `Maps` entry and each form gets its own record. Two forms were run in turn (see "What has been run");
  more than one config map, and more than two maps, were not. **Do not install a second copy of the loader under another folder name:** a script function takes only
  the first mod's hook, so a second copy's level hooks never fire and it never registers its maps. A second copy logs a line saying so.
- Everything lives in the game's memory: the level row and map centre vanish when the game closes and are registered again
  at the next start. Nothing is written to the game's files.
- The map must be built where it sits in the world (the example is built at X 0, Y -600000). Its baked navmesh tiles are absolute.
- It never loads anything from the main menu: enter from the Hub.
- Tested with UE4SS 3.0.1 (`c62ada0`) only. The table growth and `TMap:Add` it uses work around quirks of that build.
- `UE4SS.log` (next to `UE4SS.dll`) shows what the loader does; look for lines starting with `[ITRMapLoader]` (your `LogTag`):
  `native: registering ...`, `native: level row ... added`, `native: READY`, `native trigger: ...`, `native: arrived ...`,
  `native exit ...`.

## Several maps

Several `Maps` entries and several forms can be installed together in one copy of the loader; each becomes its own level row and its own entry. Two form maps were
entered in turn in the game; nothing else about several maps was run. The Showcase's loader is a different mod (`ItrShowcaseLoader`) and is installed alongside.

## Streaming mode (the fallback)

Use this only when you need the older loading approach. Native mode is the default and handles more of the game's normal level behaviour.

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

## Map forms: a pak and a text file
This is the easy way to add a map. You hand over **two things**: your map's pak and one small text file. You write no Lua, no Blueprint
and no mod. ITRMapLoader registers the map, enters it, and makes the objects you place in your levels work as ways in and out.

The text file goes in `IntoTheRadius/Content/Paks/ITRMaps/` (the map's pak goes in `IntoTheRadius/Content/Paks/~mods/`). If ITRMapLoader is
not installed it does nothing. Copy this one into Notepad and change the values:

```json
{
  "schema": 1,
  "name": "MyMap",
  "displayName": "My Map",
  "description": "One line for the list",
  "level": "/Game/Mods/MyMap/L_MyMap",
  "start": { "x": -3000, "y": -600000, "z": 20, "yaw": 0 },
  "returnpointstoragepath": "MyMap_returnpoint",
  "noprepend": true,
  "triggers": [
    { "kind": "regions" },
    { "kind": "level", "target": "/Game/ITR/Levels/Hub/L_Hub", "level": "/Game/Mods/MyMapHub/L_MyMapHub", "type": "grab", "object": "mydoorhandle1" },
    { "kind": "level", "target": "/Game/ITR/Levels/Hub/L_Hub", "level": "/Game/Mods/MyMapHub/L_MyMapHub", "type": "collision", "object": "myfield1" },
    { "kind": "exit", "type": "collision", "object": "myexitfield1" }
  ]
}
```
Everything except `schema` and `level` is optional. A map with no triggers at all is fine: it is registered, and one log line says it has no way in.

| Field | Rule |
|---|---|
| `schema` | Required, `1`. A higher number is refused with "needs a newer ITRMapLoader". |
| `name` | Default: the file name without `.json`. Letters, digits, `_`, `-`. Must be unique. |
| `displayName`, `description` | Optional. Shown on the Regions row (capitals; the description is a second line). |
| `level` | Required: the level package. **Its short name (`L_MyMap`) must be unique among all maps**, because the game finds the level by that name. A level that is not installed means the map gets no row, no registration and no triggers; the log says so. |
| `levelTag` | Default `Level.Zone.<name>`. The tag the game uses for the level. |
| `start` | Where the player arrives (x, y, z, yaw; cm and degrees). Optional: without it the game first picks a spot, possibly in another level, and the loader moves the player to the level's start marker (a TargetPoint tagged `itr:player_start`) with a long jump. Give a `start`. |
| `returnpointstoragepath` | Optional. A short key for the player's return point (see below). Letters, digits, `_`, `.`, `-`. Used **exactly as written**. |
| `noprepend` | Accepted and does nothing today. Later versions may put the map's name in front of your key; `true` asks for it to be left alone. Put it in; this behaviour may change in a future version. |
| `saves` | Default `true`: the map saves like a stock zone, so a save made inside it loads back into it. Needs the level tag registered (a small tag pak, see "Saving" below). `false` turns saving off while the player is in the map. |
| `rifts` | Optional: how many of your map's rifts the game keeps (a whole number, 0 or more). Default `99`. The donor zone keeps only 3 and the game removes the rest when the level loads, so a map with more rifts needs this. A bad value is logged and 99 is used. |
| `enter.command` | Optional. Only for a map that does its own loading: a Regions press then runs `<command> enter <name>` and that mod does the rest. The loader does not enter such a map itself. |
| `triggers` | Optional list, below. |
| `enabled` | `false` skips the file (one log line). |

Unknown fields and bad triggers are logged and skipped; the rest of the file and every other map carry on.

**Loot is not in this version for form maps:** there is no loot route for a form (a `.loot.json` next to a form is not read). Maps that need loot use the `config.lua` route (see "Loot" below).

### The triggers
| `kind` | What it is |
|---|---|
| `regions` | The map gets a row on the Hub computer's REGIONS page. Registering a map does **not** list it; you ask. |
| `level` | A way in that you built. `target` is the stock level it belongs to (any stock level: the Hub, or a zone); `level` is your small level, built in the target's world coordinates, holding the object; `type` is `collision` or `grab`; `object` is the object's name in your level (as in the Outliner; letters, digits, `_`, or a path ending in the name). ITRMapLoader asks ITRLevelAddons to stream your level in while the target is visible, then makes the object work. Several triggers with the same `level` and `target` are one request. |
| `exit` | A way out, in the map's own level: `type` and `object` as above. Firing it stores the return point (if the form has a key) and takes the player to the Hub, or where `to` says: another form map's name (its `start` or return point), or a stock level tag such as `Level.Zone.Buffer`. With a level tag, `at` says where: `{ "kind": "object", "value": "Gate.HubToBuffer" }` (a gate tag of that level) or `{ "kind": "coordinates", "value": [x, y, z, yaw] }` (`yaw` optional). `at` is one object (a list with one item is accepted; a longer list uses the first and logs it). `at` on a form map is ignored. A map that is not installed: the player stays and the log says so. |

* `collision`: the player's **body** walks into the object (a trigger box is the usual choice). It suits a new room or a new path out. The loader changes nothing on your object; a hand reaching in does not fire it; it fires once per entry and again only after the player has left. A player who arrives (or is moved) standing inside it does not trigger it. A solid mesh blocks the player, so it never overlaps: the log says so.
* `grab`: the player grabs the object. **Making it grabbable is your part**: place a `GrippableStaticMeshActor` (or a `GrippableActor` / `GrippableSkeletalMeshActor`), which needs the VRExpansion plugin in your project. Give it the grip tags `Grip.Trigger.IndexGrip` and `Grip.NoDistanceGrip` and a collision preset that overlaps the Hand channel, such as `Drawer` (`BlockAll` ignores the hand). Other tags are untested. If it is not grippable the log says "found but not grippable" and nothing happens; nothing is substituted. The hand's feel (pose, latch) has not been checked in VR.
* Both bind to your object without a Blueprint of yours. ITRMapLoader's helper pak (`ITRMapLoader_P.pak`, logic-only Blueprints with no mesh and no collision) does the binding and everything that follows a trigger.

### What goes wrong, and what you see
Nothing is shown to the player. Every case is one line in `Content/Paks/UE4SS.log`; look for `[ITRMapLoader]`:

| Case | Log line (shortened) | Result |
|---|---|---|
| Bad form | `form X.json refused: ...` | Not registered |
| Level not installed | `map X: level ... not installed: not listed` | No row, no triggers |
| Trigger level not installed | `map X trigger level ... not installed: ignored` | Others go on |
| Unknown `kind` or bad trigger | `form X.json: trigger 2: unknown kind 'x' ignored` | That trigger only |
| Object not in the level | `map X collision trigger 'o' : the object was not found in its level` | Does nothing |
| Found, but the player cannot touch it | `map X ... trigger 'o' : found, but the player cannot touch it (collision: no part overlaps the player; grab: every part ignores the hand)` | Bound, but it will not fire |
| ITRLevelAddons missing | `N trigger level request(s) waiting for ITRLevelAddons` | Trigger levels not streamed (they are placed if ITRLevelAddons starts later); Regions rows still work |
| A helper pak missing | `helper pak not found (zzz_ITRMap_ITRMapLoader_P.pak): form maps do nothing` | Nothing is spawned |
| No way in / out | `map X: no way in`, `map X: no exit trigger` | Registered anyway; test your map |
| Return point | `map X: no return point: using start` / `return point '...' not usable: using start` | Start is used |

### The return point
**Not proven: do not rely on it yet.** It is implemented and the log lines for writing and reading were seen, but the game crashed after some map entries in the
tests (see "What has been run"), so entering a map with a stored value has not been shown to work.

With `returnpointstoragepath` set, the loader keeps a value for that key in the player's **save** (the `CustomMarkers` list the game already
saves, as a plain text entry `ITRReturn:<key>=x,y,z,yaw`). It writes it when the player leaves through one of your `exit` triggers, and reads it
when they come back in, instead of using `start`. Each save slot has its own value; a new game has none. Other ways of leaving (death, a stock
gate) leave the last value. The key is yours: two maps given the same key share the value. If you moved things around and players now arrive
inside a rock, change the key (`MyMap_returnpoint2`); everyone then starts from `start` again. The old value stays in their save, unused.
Leave the field out and players always arrive at `start`. The `ITRReturn:` marker in front keeps your key apart from stock entries.

### Several maps, zones, the Hub
Any number of forms can be installed at once. `target` can be any stock level, a zone as well as the Hub: the trigger level is streamed in
while that level is visible and the player enters your map from wherever they stand. Regions lists only maps that ask for it, and only on the
Hub computer. A trigger that targets another custom map is not supported.

### What the player installs
- UE4SS (see "Installing" above) and the `ITRMapLoader` folder (this directory) in the UE4SS mods folder;
- [`prebuilt/ITRMapLoader_P.pak`](prebuilt/) in `<game>\IntoTheRadius\Content\Paks\~mods\` (the trigger helper; see [`build-from-source/`](build-from-source/));
- your map's pak(s) in `<game>\IntoTheRadius\Content\Paks\~mods\` and `MyMap.json` in `<game>\IntoTheRadius\Content\Paks\ITRMaps\`;
- for `level` triggers only: the `ITRLevelAddons` folder and [`../addons-ue4ss/prebuilt/ITRLevelAddons_P.pak`](../addons-ue4ss/prebuilt/) in `~mods` ([`../addons-ue4ss/`](../addons-ue4ss/)).

Without ITRMapLoader the form does nothing and nothing else changes.

### Saving
The default `"saves": true` copies a stock zone's autosave, save-on-load, save-on-exit and sleeping flags to the map's level row. A save made
inside the map keeps the level only if the level tag is registered: the game reads every tag ini under `IntoTheRadius/Config/Tags/` at startup, and
[`../example-map/build-tags.ps1`](../example-map/build-tags.ps1) packs a one-line tag ini into a small pak: run
`.\build-tags.ps1 -Engine "<your editor>\Engine" -Map MyMap` (add `-Tag <your levelTag>` when the form has a `levelTag`; the default tag is `Level.Zone.MyMap`) and install
`zzz_ITRMap_MyMap_Tags_P.pak` next to the map pak. A map that may be removed later should set `"saves": false` (progress is then kept by the Hub
autosave after the player returns), or a save made inside it would point at a level that no longer exists. When the game loads a saved map level
itself (Continue), the map's exit triggers bind when its level is shown, and nothing moves the player: a bad saved position is the game's to handle.
*Not run for form maps: a save made inside a map, then Continue, was not tried.*

## Regions (Hub mission computer)
The REGIONS row is optional and belongs to the maps that ask for it (`{ "kind": "regions" }`, or `Regions = true` on a `config.lua` map).
With one listed, the Hub mission computer's main page gets a REGIONS row, between MISSIONS and PLAY TAPE. Pressing it opens the stock Play tape page with one row per
listed map (name in capitals, a second line for the description), the stock Back button and the stock scroll bar. Pressing a map enters it, by the same function a trigger uses
(`BP_ITRMapEntry.Enter`). A `config.lua` map with `Regions = true` gets a row too: its press runs the config route's own command, `itrmap enter <name>` (the `ConsoleCommand`).
With no map listed, no Blueprint actor is made and no hook is attached: the computer's page is untouched.

How it is built: `BP_ITRRegions` (in the helper pak) does the page work. Lua's only part is one hook on the main page's `Construct` (a Blueprint cannot see that event), which hands the
page's spare row and its widget component to the Blueprint. The rows bind one handler and the pressed row is found with `IsPressed`.

Two controls are still a little awkward:
- Use the laser to select REGIONS. Touching the row with a finger lights it up but does not open it.
- Drag the scroll bar with the laser. The thumbstick does not scroll this list, just as on the tape page.

**Run in the game (emulated headset, 4 November 2026):** the page built after a transfer into the Hub, the REGIONS row shown, the list opened with the right number of rows, and a
row's press called by a test event (`BP_ITRRegions.PressRow`), which entered the map. **Not run: a laser press on the REGIONS row or on a map row**, so whether a real press reaches the
handler is unproven; and whether releasing a held laser press fixes the first click after an arrival is not shown either (a stuck press cannot be made with the emulated headset). A config map's
row (press runs `itrmap enter`) is offline-tested only.

## Timers
Nothing here polls. What each install runs in the background:

| Install | Timers / loops | Hooks and queued calls |
|---|---|---|
| ITRLevelAddons | none | none; one `ExecuteInGameThread`, made from the game mode notification |
| ITRMapLoader, form maps | none | one `ExecuteInGameThread` at the game mode notification (it does the work); one script hook, `WBP_MCPage_Main_C:Construct`, only when a map is listed. The Blueprints listen to the game's level events themselves |
| ITRMapLoader, a config map | the exit-marker check twice a second **only while such a map is loaded** (`LoopAsync`) | the six level-event hooks of the config route |
| Config `TriggerFile`, `AutoLoadInHub`, streaming mode | their own short timers (`LoopAsync`), as before | |

ITRMapLoader has no `ExecuteWithDelay` and ITRLevelAddons has none. The `BP_ITRMapManager` runs one console command (`itrmaps register`) at the first level change and the Blueprints run
`itrmaps log <text>` for the lines they print; nothing else crosses from Blueprint to Lua. At rest the form path runs no Lua, no tick and no timer. Checked on the six cooked Blueprints in the built paks (extracted with UnrealPak, read with UAssetGUI): no Tick function or name, tick not enabled, and no timer, delay or latent-action name (24 checks, all pass).

## Offline tests
With Lua 5.1 (`lua.exe`, `luac.exe`), from `tests\`: `luac -p ..\ITRMapLoader\Scripts\*.lua`, `lua test_forms.lua` (the form fields, 61 cases) and `lua test_boot.lua` (the form path's one step: what is
spawned, written and started, the handshake with ITRLevelAddons in both orders, config Regions rows, no queued call; 22 cases), against stand-ins of the UE4SS API. They prove the logic around the game, not the game.

## The Blueprints
The logic of a form map is in four Blueprints, provided built (`prebuilt/ITRMapLoader_P.pak`); `build-from-source/` has their specs and how to rebuild them.

## What has been run
Everything above that is not listed here as run has **not** been run. "Run" means: the game started with an emulated headset driving it (UE4SS 3.0.1, 4 November 2026) with the helper pak in
`Content/Paks/~mods`, or the person's session in the next section. The final build of the helper pak (`prebuilt/ITRMapLoader_P.pak`) and of `forms.lua` and `regions.lua` ran in one session; the
later offline changes (a config map's Regions row, `boot.lua` taking the config maps, the removal of `maps.lua` and `bind.lua`) were **not run in the game**.

| Claim in this README | Checked | Result |
|---|---|---|
| The form fields, `to` and `at` parse; bad ones are refused with one line | `tests/test_forms.lua` (61 cases) | Pass |
| The one step: entries, triggers, manager and Regions spawned and written; the handshake in both orders | `tests/test_boot.lua` (22 cases, stand-ins) | Pass; this is not the game |
| Registration of the maps at the first level change (the menu), before Continue | In the game | `registration (asked at the first level change): 2 ready, 0 failed, 0 waiting` |
| A `regions` row enters a map at its `start` (by test event) | In the game | Entered at `start` |
| `exit` trigger leaves; return point stored and used; exit `to` another map; A to B to A, no bounce | In the game, stick walk | Worked (four arrivals in a row: A, B, A, B) |
| Exit to a stock level by gate (`{ "kind": "object", ... }`) and by position (`{ "kind": "coordinates", ... }`) | In the game | Arrived in the Buffer zone at the gate; arrived at the position's x and y (the player then fell: the stock map has no floor there) |
| A hand-back form (`enter.command`) | Earlier runs only (before the Blueprint version) | **Not run in the final state** |
| `level` trigger (a Hub field) with ITRLevelAddons | Earlier runs; the Blueprint trigger streams through ITRLevelAddons in the last session | Add-on streamed; a `level` trigger firing in the final state: **not run** |
| `grab` | Not run | **Not run** (the hand could not be made to grip with the emulated headset) |
| Saves in a form map, a save made inside a map then Continue, quit to menu then Continue | Not run | **Not run** (a test would write a save) |
| Six visits in a row, ten forms at once | Planned for a last session that was stopped | **Not run** (four arrivals and two form maps were) |
| The config route (`config.lua` map) to its exit marker | Earlier runs only; not with the final build | **Not run in the final state** |
| Installing `prebuilt/ITRMapLoader_P.pak` into `Content/Paks/~mods/` | The pak was installed in `~mods` under the name `zzz_ITRMap_ITRMapLoader_P.pak`; the location is the one written here, the file name is not | Not run as written |
| `build-tags.ps1`, `build-map.ps1 -Install` | Not run after they were changed to install into `~mods` (a cook is needed) | **Not run** |

## Run by a person in VR (4 November 2026)

One session, about eight minutes, read from `UE4SS.log`. A person played it with a headset; the log is the only evidence used here. Installed: the `ITRMapLoader` folder under its own name with the shipped
`config.lua` (the log reads `ready: 0 map(s); key false`), `zzz_ITRMap_ITRMapLoader_P.pak`, a form `TestMap.json` with a `regions` trigger and an `exit` trigger (`collision`, object `exit1`)
for a small test level and its tag pak, plus the Showcase and its loader (a form `ItrShowcase.json` with `enter.command` and `regions`). ITRLevelAddons was not installed.
The test level was a floor, a start marker and one trigger box: it says nothing about a real map.

| What the log shows | Where it shows it |
|---|---|
| Both forms were read (`2 form map(s) accepted, 0 refused`), `TestMap` registered as the level `Level.Zone.TestMap` and its tag found (`REGISTERED in the gameplay tag tree`) | start-up lines |
| The Hub computer's REGIONS row was shown and opened (`page opened: 2 map(s)`) every time it was pressed | `regions:` lines |
| Four trips to the test map, each started by a press on its row (`entering TestMap from a Regions row`): `TransferToLevel` returned true, the player arrived 2.4 s later at the form's `start` position with the start marker found, and the helper bound `exit1` (`bound to exit1 (TriggerBox)`) | arrival lines, 12:36, 12:37, 12:38, 12:42 |
| In each of the four trips `exit trigger exit1 fired`, the loader left through `TransferToLevel(Level.Hub)` and the log says `back in Level.Hub` about 4 s later. The map was entered again after each exit | `exit trigger`, `native exit` lines |
| Two trips to the Showcase from its row: the form's `enter.command` ran (`itrshowcase enter ItrShowcase`), the Showcase's loader made the transfer (8 to 9 s), the player arrived at its exit point R0, and its exit marker led back to the Hub | `entering ItrShowcase (Regions)` lines |
| Both maps were entered in turn in one session: test map twice, Showcase, test map, Showcase, a save loaded in the Showcase, test map, Showcase (by its grab trigger) | the lines above |
| The game loaded the Showcase itself from a save made in it (the Showcase's loader logged `the game loaded Level.Zone.ItrShowcase itself (a save made in the map)`), and the player left it by the exit marker | 12:41 to 12:42 |
| The last test-map trip was followed by a Showcase entry through the Showcase's own grab trigger (the item `Liquid08_1`), not through a form | 12:43 |

What the log does not show, so it stays as the table above says: what physically fired `exit1` (the log says only that it fired); a `level` trigger; a `grab` trigger; a return point (the form had none);
`"saves"` or a save made inside a form map (the save in the log was made in the Showcase by its own loader); loot; ITRLevelAddons. The log ends at 12:43:12 on
`native exit (exit marker): TransferToLevel(Level.Hub) -> true` with no `back in Level.Hub` line after it. Whether the game was closed there or ended is not known from the log (no crash dump was looked for outside `Content/Paks`, where there is none).

