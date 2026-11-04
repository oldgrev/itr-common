# ITRMapLoader's Blueprints

The form path of ITRMapLoader is Blueprint first: logic-only Blueprints (no mesh, no collision, nothing the player can meet, no Tick, no timer) own every trigger, entry, exit, arrival, return point
and the Regions page. Lua reads the forms (no Blueprint can read a file), spawns the Blueprints once and writes their values. The built pak is provided; this folder is for rebuilding or changing it.

| Blueprint | What it does |
|---|---|
| `BP_ITRMapEntry` | One per form map. `Enter()` is the one way into the map: hand-back (`<command> enter <name>`), return point, arrival position, transfer, move the player on arrival if the game put them far away. `StoreReturn()` writes the return point. |
| `BP_ITRTrigger` | One per `level` or `exit` trigger. Finds the author's object in the stream it names and binds it (`collision`: overlap events of every part, only the player body fires, once per entry; `grab`: the object's own `OnGripped`). Firing a way in calls `Entry.Enter()`; an exit stores the return point, then enters another map, or goes to a stock level (`to`, `at`), or to the Hub. |
| `BP_ITRMapManager` | One. Asks Lua, once at the first level change, to register the maps with the game; carries the add-on requests for ITRLevelAddons. |
| `BP_ITRRegions` | The Regions page on the Hub computer: `PageBuilt` (called from Lua's one `Construct` hook), the page switch, one stock row per map, `HRowPressed`, and the test events `OpenList` and `PressRow`. |

| File | What it is |
|---|---|
| [`../prebuilt/ITRMapLoader_P.pak`](../prebuilt/) | The four Blueprints and a level that keeps them in the pak, built. Install it in `<game>\IntoTheRadius\Content\Paks\~mods\`. |
| `Specs/BP_ITRMapEntry.json`, `BP_ITRTrigger.json`, `BP_ITRMapManager.json`, `BP_ITRRegions.json` | The Blueprints as BPGen specs. Format: [`SPEC.md`](../../../itr-showcase/project/Plugins/ItrShowcaseEditor/SPEC.md). |
| `Scripts/gen_entry.py`, `gen_trigger.py`, `gen_regions.py` | The readable sources of the specs (`bpb.py` is their helper). Any Python 3, nothing else needed. |
| `Scripts/build_loader.py` | An editor script that turns the specs into the Blueprints and the level `/Game/Mods/ITRMapLoader/L_ITRMapLoader`. |

Without the pak the loader logs `helper pak not found` and form maps do nothing. The stock widgets `WBP_Element_TapeRecord` and `WBP_MCPage_Tapes` are named by path; the project holds stubs of them that are **not** packed (the editor script for the stubs is part of the project's Blueprint tooling: see the plugin's `SPEC.md`, the note on Widget Blueprints).

## Rebuilding
This needs the full map-making setup in the [map-making guide](../../map-making/guide.md) (section 3, "Route B"): the special editor, the [ITR Showcase project](../../../itr-showcase/project/) built with it, its `ItrShowcaseEditor` plugin (it must be the version in this repository: it understands the `&` by-reference type and Widget Blueprints), and the `VRExpansionPlugin` (the Showcase project does not contain it: you copy it from the community SDK, as [`READMEBORING.MD`](../../../itr-showcase/READMEBORING.MD) describes), because the trigger casts to its grippable classes.
1. `python Scripts/gen_entry.py`, `python Scripts/gen_trigger.py`, `python Scripts/gen_regions.py`.
2. Open the project in the editor and run `Scripts/build_loader.py` (File > Execute Python Script). The editor log shows `BPGEN OK` for each Blueprint.
3. Close the editor, then in the project folder run `.\build-map.ps1 -Engine "<your editor>\Engine" -Map ITRMapLoader`. It writes `build\zzz_ITRMap_ITRMapLoader_P.pak`. Install it in `~mods`.

## What has been checked (4 November 2026)
| Step | How | Result |
|---|---|---|
| The three `gen_*.py` | Run with a plain Python 3 | Wrote the specs (entry 173, trigger 271, manager 11, regions 112 nodes) |
| `build_loader.py` in the editor | The ITR Showcase project in this repository (`VRExpansionPlugin` already in it, plugin compiled), run **headless** (`UE4Editor-Cmd.exe ... -run=pythonscript -nullrhi -unattended -nohmd`) | `OK` for all four Blueprints, 0 errors |
| `build-map.ps1 -Map ITRMapLoader` | Run through the repository's cook tool | Wrote the pak (96,516 bytes); `prebuilt/ITRMapLoader_P.pak` is a copy |
| What the Blueprints do in the game | See "What has been run" in [`../README.md`](../README.md) | Entries, exits, return points, `to`/`at`, Regions page and rows (by test event): seen. A laser press and a hand grab: not run |
| Installing the pak in `~mods` as `ITRMapLoader_P.pak` | The runs used the name `zzz_ITRMap_ITRMapLoader_P.pak` in `~mods` | Not run as written (the name) |
| Setting up the project (special editor, plugin build, `VRExpansionPlugin`) | Not run: the project used here was already set up | Not tried |
