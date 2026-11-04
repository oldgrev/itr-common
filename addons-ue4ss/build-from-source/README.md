# Building the level watcher from source

`BP_ITRLevelWatch` is the one Blueprint ITRLevelAddons needs. It is logic only: no mesh, no collision, no component, no Tick, no timer.
ITRLevelAddons spawns one per watched streaming entry and calls `Watch(Entry, Id)`. The helper binds the entry's `OnLevelShown` and
`OnLevelHidden` and runs `itraddons shown <Id>` or `itraddons hidden <Id>`, so ITRLevelAddons' Lua runs only when a level really appears or goes.

Status: **not built yet.** The spec has not been through the editor, and ITRLevelAddons does not use the helper yet.

## Files
- `Specs/BP_ITRLevelWatch.json`: the BPGen spec (format: the plugin's `SPEC.md` in the ITR Showcase project).
- `Scripts/build_watch.py`: editor script. Deletes and regenerates the Blueprint, and makes the one-actor level `L_ITRLevelAddons` that keeps it in the pak.

## Build
You need a project with the BPGen plugin (`ItrShowcaseEditor`): the ITR Showcase project.
```
tools\itr\itr.cmd editor-run public\itr-common\addons-ue4ss\build-from-source\Scripts\build_watch.py --task <id> --allow-unsaved
tools\itr\itr.cmd cook --map ITRLevelAddons --task <id>
```
The editor log must show `BPGEN OK /Game/Mods/ITRLevelAddons/BP_ITRLevelWatch`. The cook writes `zzz_ITRMap_ITRLevelAddons_P.pak` (its defect check
reports rc 2 because the map has no master materials; the pak is still written). Do not use the `_Tags_` pak.
