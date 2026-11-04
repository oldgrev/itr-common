# Example: a map form with plain objects

A map, a way in and a way out, with no mod, no Lua and no Blueprint of yours. [`MyMap.json`](MyMap.json) is everything you hand over next to your pak;
the fields are explained in [the loader README](../loader-ue4ss/README.md#map-forms-a-pak-and-a-text-file).

What you place in the editor (the names are what you write in the form; letters, digits and `_`):

1. **Your map's level**, `/Game/Mods/MyMap/L_MyMap`: a `TargetPoint` tagged `itr:player_start` at the form's `start`, and inside it a trigger box named `myexitfield1`
   where the player leaves. Build it like [`../example-map/`](../example-map/) (its `Scripts/build_example.py` shows a finished one). The level's short name
   (`L_MyMap`) must be unique among all maps.
2. **A small level for the Hub**, `/Game/Mods/MyMapHub/L_MyMapHub`, built in the Hub's world coordinates the way [`../example-addon/`](../example-addon/) builds its add-on:
   - `myfield1`: a trigger box. The player walks into it to enter the map. Nothing on it is changed; a hand reaching in does not fire it.
   - `mydoorhandle1`: a `GrippableStaticMeshActor` from the `VRExpansionPlugin`. The example projects here do not contain that plugin: copy it from the community SDK as the
     [map-making guide](../map-making/guide.md) (section 3, "Compiling it") and [`../../itr-showcase/READMEBORING.MD`](../../itr-showcase/READMEBORING.MD) describe. Give the actor the tags
     `Grip.Trigger.IndexGrip` and `Grip.NoDistanceGrip` and a collision preset that overlaps the Hand channel, such as `Drawer` (not `BlockAll`). The player grabs it to enter.
     Making it grabbable is your part; if it is not, the log says "found but not grippable" and nothing happens.
3. **Pack them.** In `example-map/` run `.\build-map.ps1 -Engine "<your editor>\Engine" -Map MyMap` (pak `zzz_ITRMap_MyMap_P.pak`) and in `example-addon/`
   `.\build-map.ps1 -Engine "<your editor>\Engine" -Map MyMapHub` (pak `zzz_ITRAddon_MyMapHub_P.pak`); both scripts pack only `/Game/Mods/<Map>`. Put the paks in `<game>\IntoTheRadius\Content\Paks\~mods\`.
4. **Install what makes it work** (all in [`loader-ue4ss/`](../loader-ue4ss/) and [`addons-ue4ss/`](../addons-ue4ss/)): the `ITRMapLoader` and `ITRLevelAddons` folders into the UE4SS mods
   folder, and `loader-ue4ss/prebuilt/ITRMapLoader_P.pak` and `addons-ue4ss/prebuilt/ITRLevelAddons_P.pak` into `<game>\IntoTheRadius\Content\Paks\~mods\`.
   Put `MyMap.json` into `<game>\IntoTheRadius\Content\Paks\ITRMaps\`.
5. Start the game and go to the Hub. `<game>\IntoTheRadius\Content\Paks\UE4SS.log`, lines starting `[ITRMapLoader]`, say what was found and what was not.

The `regions` trigger also lists the map on the Hub computer's REGIONS page. Take it out and the map has only the ways in you built. `returnpointstoragepath` makes the player
come back where they left (the exit field); leave it out and they always arrive at `start`.

## What has been checked
- `MyMap.json` was read by the loader's `forms.lua`: it parses with no warnings (levels 1, exits 1, regions on, key `MyMap_returnpoint`). It was not installed in the game as written: the map levels do not exist.
- Steps 1 to 3 (building the two levels and packing them with `example-map/build-map.ps1` and `example-addon/build-map.ps1`) were **not run** from this example: neither project here contains levels
  called `MyMap` or `MyMapHub`. Both scripts exist and take `-Engine` and `-Map`; `build-map.ps1` in the Showcase project was run by hand for another map name and worked.
- Step 4 (installing the loader, ITRLevelAddons and the two prebuilt paks in `Content/Paks/~mods`) was not run as written; see the "What has been run" table in [`../loader-ue4ss/README.md`](../loader-ue4ss/README.md#what-has-been-run). It says what was run with other test maps (entries, exits, return points, the Regions page by test event) and what was not: a `grab` trigger, a laser press on the Regions row, saves inside a map, and the config route with the final build.
- `MyMap.json` does not use `to` or `at` (an exit to another map or to a stock level); the loader README's form section describes them and what was run.
