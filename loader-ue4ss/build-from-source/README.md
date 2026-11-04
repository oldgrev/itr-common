# Building the trigger helper from source

`BP_ITRTriggerBind` is the one Blueprint ITRMapLoader needs. It is logic only: no mesh, no collision, no component the player can meet, no Tick.
ITRMapLoader spawns one per trigger in a map's form and hands it the author's named object. The helper listens to that object and changes
nothing on it.

- `collision`: listens to overlaps on every part of the object. Only the player's body fires it (a hand reaching in does not), once per entry; the
  player has to leave before it can fire again.
- `grab`: listens to the grip event of the author's own grippable actor, lets the hand go after 0.2 s and fires.
- Firing runs the console command `itrmapbind fire <id>`. That is the only Lua that runs when a trigger fires.
- The object's end of play destroys the helper, so nothing outlasts the author's level.

Status: **not built yet.** The spec has not been through the editor.

## Files
- `Specs/BP_ITRTriggerBind.json`: the BPGen spec (format: the plugin's `SPEC.md` in the ITR Showcase project).
- `Scripts/gen_spec.py`: the readable source of that spec. `python gen_spec.py` rewrites the JSON.
- `Scripts/build_bind.py`: editor script. Deletes and regenerates the Blueprint, and makes the one-actor level `L_ITRMapLoader` that keeps it in the pak.

## Build
You need a project with the BPGen plugin (`ItrShowcaseEditor`) and VRExpansion: the ITR Showcase project.
```
tools\itr\itr.cmd editor-run public\itr-common\loader-ue4ss\build-from-source\Scripts\build_bind.py --task <id> --allow-unsaved
tools\itr\itr.cmd cook --map ITRMapLoader --task <id>
```
The editor log must show `BPGEN OK /Game/Mods/ITRMapLoader/BP_ITRTriggerBind`. The cook writes `zzz_ITRMap_ITRMapLoader_P.pak` (its defect check
reports rc 2 because the map has no master materials; the pak is still written). Do not use the `_Tags_` pak.
