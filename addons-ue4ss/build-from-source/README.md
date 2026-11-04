# The add-on Blueprints (`BP_ITRLevelAddons`, `BP_ITRLevelAddon`)

ITRLevelAddons' work is done by two logic-only Blueprints (no mesh, no collision, nothing the player can meet, no Tick, no timer): `BP_ITRLevelAddons` is the manager (`Place(...)` makes one add-on),
`BP_ITRLevelAddon` is one add-on (its streaming entry, switching with its target level, hiding stock actors). Lua only hands them the add-ons. The built pak is provided; this folder is for rebuilding or changing it.

| File | What it is |
|---|---|
| [`../prebuilt/ITRLevelAddons_P.pak`](../prebuilt/) | The two Blueprints and a level that keeps them in the pak, built. Install it in `<game>\IntoTheRadius\Content\Paks\~mods\`. |
| `Specs/BP_ITRLevelAddon.json`, `Specs/BP_ITRLevelAddons.json` | The Blueprints as BPGen specs (nodes and links as data). Format: [`SPEC.md`](../../../itr-showcase/project/Plugins/ItrShowcaseEditor/SPEC.md). |
| `Scripts/gen_addons.py` | The readable source of the specs. `python gen_addons.py` (any Python 3; `bpb.py` beside it is its helper) rewrites both. |
| `Scripts/build_addons.py` | An editor script that turns the specs into the Blueprints and the level `/Game/Mods/ITRLevelAddons/L_ITRLevelAddons`. |

Without the pak the mod logs `helper pak not found` and does nothing.

## Rebuilding
This needs the full map-making setup in the [map-making guide](../../map-making/guide.md) (section 3, "Route B"): the special editor, the [ITR Showcase project](../../../itr-showcase/project/) built with it, its `ItrShowcaseEditor` plugin (it holds the BPGen generator).
1. `python Scripts/gen_addons.py`.
2. Open the project in the editor and run `Scripts/build_addons.py` (File > Execute Python Script). The editor log shows `BPGEN OK /Game/Mods/ITRLevelAddons/BP_ITRLevelAddons (... 0 errors)`.
3. Close the editor, then in the project folder run `.\build-map.ps1 -Engine "<your editor>\Engine" -Map ITRLevelAddons`. It writes `build\zzz_ITRMap_ITRLevelAddons_P.pak` (and a tags pak you do not need). Install the first one in `~mods`.

## What has been checked (4 November 2026)
| Step | How | Result |
|---|---|---|
| `python gen_addons.py` | Run with a plain Python 3 | Wrote both specs (131 and 34 nodes) |
| `build_addons.py` in the editor | The ITR Showcase project in this repository, run **headless** (`UE4Editor-Cmd.exe ... -run=pythonscript -nullrhi -unattended -nohmd`); not through the menu | `OK` for both Blueprints, 0 errors |
| `build-map.ps1 -Map ITRLevelAddons` | Run through the repository's cook tool | Wrote the pak; `prebuilt/ITRLevelAddons_P.pak` is a copy of it |
| What the Blueprints do in the game | See "What was tested" in [`../README.md`](../README.md) | Streaming, switching, transform, hides: seen |
| Installing the pak in `~mods` as `ITRLevelAddons_P.pak` | The runs used the name `zzz_ITRMap_ITRLevelAddons_P.pak` in `~mods` | Not run as written (the name) |
| Setting up the project (special editor, plugin build) | Not run: the project used here was already set up | Not tried |
