# Example map

A small test map for Into the Radius 1 (2.7.2). It's an 80 m floor with a checker pattern, some walls and cover, a
hut, and a ramp up to a platform. It has a sky dome and Movable lights, a start marker, navmesh, and an exit pad about
8 m to the left of where you start, which takes you back to the Hub.

It is also the map the [loader](../loader-ue4ss/) is configured for out of the box. In the Hub, pick up the **sugar cube**
(the item with the static mesh `SM_Tea01D`) and you go through the game's transition onto this map; step on the exit pad
and you come back to the Hub the same way.

The floor uses `M_ExampleGrid`, a material your editor compiles, so it doubles as a check that your special editor
works. Built with the special editor, the checker shows up in game. Built with stock 4.27, the game would crash or
draw it black. If you only have stock 4.27, set `OWN_MATERIAL = False` in `Scripts/build_example.py` and it'll stick
to engine content.

The long explanation is in [`../map-making/guide.md`](../map-making/guide.md).

## Just want to try it?
[`prebuilt/zzz_ITRMap_Example_P.pak`](prebuilt/) is this map already built with the special editor (343 KB,
SHA-256 `a4b5eccd579f981e4d02ed7051d48e32c37d7ae1e017d3a7d9c37786e5b17dfc`). The steps for installing UE4SS, the
loader and the pak are at the top of [the main README](../README.md#example-map-test).

## Building it yourself
1. Copy this folder somewhere. It's a blueprint-only project, and `Content/` gets created in step 3.
2. Get the game's `DefaultEngine.ini` into the project:
   ```powershell
   .\extract-game-config.ps1 -Engine "C:\ue427\Engine"
   ```
3. Make the map. Either open `IntoTheRadius.uproject` and run `Scripts\build_example.py` from File, Execute Python
   Script, or run it headless:
   ```bat
   C:\ue427\Engine\Binaries\Win64\UE4Editor-Cmd.exe <path>\IntoTheRadius.uproject -run=pythonscript -script=<path>\Scripts\build_example.py -nullrhi
   ```
   That creates the material `/Game/Mods/Example/M_ExampleGrid`, an editor-only host level
   `/Game/Mods/Example/L_ExampleHost`, and the map itself, `/Game/Mods/Example/L_Example`.
4. Build the navmesh. This needs the full editor, a commandlet won't do it. Either run `Scripts\build_navmesh.py`
   from File, Execute Python Script, or start the editor unattended:
   ```bat
   C:\ue427\Engine\Binaries\Win64\UE4Editor.exe <path>\IntoTheRadius.uproject "-ExecCmds=py <path>\Scripts\build_navmesh.py" -ITRQuit
   ```
   You should see `navmesh built and saved ... ['RecastNavMesh-Default', 'RecastNavMesh-Big']` in the log. Don't use
   `-ExecutePythonScript=` for this one, it closes the editor before the build gets a chance to run.
5. Cook, pack and install it (with the game closed):
   ```powershell
   .\build-map.ps1 -Engine "C:\ue427\Engine" -Install
   ```
6. Load it with the [loader](../loader-ue4ss/): grab the sugar cube in the Hub (or press F10, the loader's default key).

To turn it into your own map, change `FOLDER`, `HOST` and `MAP` at the top of both scripts (or just build in the
editor by hand), and pass `-Map <Name>` to `build-map.ps1`.

## What we tested (October 2026)
- Steps 2 to 5 with the special editor. The material compiled to 30 shaders, the navmesh got saved into the map, and
  the pak came out at 343 KB.
- In VR, loaded from the Hub with the UE4SS script: the checker floor looks right, you land on the start marker, three
  enemies we spawned 40 m away stood on the navmesh, and the exit pad took us back to the Hub and unloaded the map.
- We haven't tried building it with stock 4.27.2 (`OWN_MATERIAL = False`).

## What a map needs for native entry
The example is entered natively (the loader registers it as a game level, then uses the game's level transfer). The map
itself needs very little for that, and everything the example has is already there:
- **A start marker:** a `TargetPoint` tagged `itr:player_start` (the example puts it 30 m from the middle of the map,
  8 m from the exit pad). The loader moves you there if the game puts you more than 30 m away.
- **An exit:** a `TargetPoint` tagged `itr:exit`, with a visible pad and post on it. Standing within 1.5 m of it takes you
  back to the Hub. Add `itr:exit_id:<ID>` to remember which exit you used, and a `TargetPoint` tagged `itr:arrive:<ID>` a few
  metres in front of it to arrive there next time.
- **The level's name:** the world is called `L_Example`, the `.umap` name. The loader registers that name as the level's main
  sublevel, so it must match the last part of `Level` in the config.
- **Built where it sits:** the map is built at world position (0, -600000, 0), clear of the game's navmesh volumes. The
  config's `NativeCenter` and `NativeStart` use those world coordinates.
- Nothing else: no gates, no level blueprint, no game mode, no save data. Loot and spawners are optional (see the loader README).

What the modder adds is the loader's `config.lua` entry. For this map:

```lua
{
    Name = "Example",
    Level = "/Game/Mods/Example/L_Example",
    StartTag = "itr:player_start",
    Native = true,
    DisplayName = "Example",
    NativeDonorTag = "Level.Zone.Buffer",                 -- a stock zone whose level rules are copied
    NativeSaves = false,                                  -- no save is written inside the map
    NativeRadius = 50000,
    NativeCenter = { X = 0, Y = -600000, Z = 0 },         -- the middle of the map, in world cm
    NativeStart = { X = -3000, Y = -600000, Z = 20, Yaw = 0 },   -- the itr:player_start marker
    NativeTriggerMesh = "SM_Tea01D",                      -- grab this Hub item to enter
}
```
To make your own map, change the folder, `Name`, `Level`, the centre and the start to your map's, and pick a Hub item that
no other loader uses (the loader README lists each field and a few Hub items).
