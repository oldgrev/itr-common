# Example map

A small test map for Into the Radius 1 (2.7.2):
- an 80 m floor with a 1 m checker, walls, cover, a hut, and a ramp up to a platform;
- a sky dome and Movable lights;
- a start marker, navmesh, and an exit pad (8 m to the left of the start) that takes you back to the Hub.

The floor's material, `M_ExampleGrid`, is compiled by **your** editor. It's the proof that the special editor
works: built with it, the checker renders in the game; built with stock 4.27, the game would crash or draw it black.
Set `OWN_MATERIAL = False` in `Scripts/build_example.py` to build with stock 4.27 instead (engine content only).

The full explanation is in [`../map-making/guide.md`](../map-making/guide.md).

## Try it without building
[`prebuilt/zzz_ITRMap_Example_P.pak`](prebuilt/) (343 KB, SHA-256 `a4b5eccd579f981e4d02ed7051d48e32c37d7ae1e017d3a7d9c37786e5b17dfc`)
is this map, built with the special editor. To use it, follow the five steps in
[the repository README](../README.md#try-the-example-map-10-minutes-no-editor): install
UE4SS and the loader, copy the pak, Continue into the Hub, and leave by stepping on the exit pad.

## Build it
1. Copy this folder somewhere. It's a blueprint-only project; `Content/` is created by step 3.
2. Get the game's config. The project's `DefaultEngine.ini` must be the game's own:
   ```powershell
   .\extract-game-config.ps1 -Engine "C:\ue427\Engine"
   ```
3. Generate the map. Either open `IntoTheRadius.uproject` in the editor and run **File → Execute Python Script →
   `Scripts\build_example.py`**, or headless:
   ```bat
   C:\ue427\Engine\Binaries\Win64\UE4Editor-Cmd.exe <path>\IntoTheRadius.uproject -run=pythonscript -script=<path>\Scripts\build_example.py -nullrhi
   ```
   It creates:
   - the material `/Game/Mods/Example/M_ExampleGrid`;
   - the editor-only host level `/Game/Mods/Example/L_ExampleHost`;
   - the map `/Game/Mods/Example/L_Example`.
4. Build the navmesh. It has to run in the editor, not a commandlet. Either run **File → Execute Python Script →
   `Scripts\build_navmesh.py`** in the open editor, or unattended:
   ```bat
   C:\ue427\Engine\Binaries\Win64\UE4Editor.exe <path>\IntoTheRadius.uproject "-ExecCmds=py <path>\Scripts\build_navmesh.py" -ITRQuit
   ```
   The log should read `navmesh built and saved ... ['RecastNavMesh-Default', 'RecastNavMesh-Big']`.
   Don't use `-ExecutePythonScript=`: that closes the editor as soon as the script returns, before the build.
5. Cook, pack and install (game closed):
   ```powershell
   .\build-map.ps1 -Engine "C:\ue427\Engine" -Install
   ```
6. Enter it with the [loader](../loader-ue4ss/). Go to the Hub first.

To make your own map, change `FOLDER`, `HOST` and `MAP` at the top of both scripts (or build by hand), and pass
`-Map <Name>` to `build-map.ps1`.

## What has been tested (October 2026)
- **Build:** steps 2–5 with the special editor: material compiled to 30 shaders, navmesh saved into the map, pak 343 KB.
- **In the game (VR through SteamVR, and desktop):** the UE4SS loader streamed the map in from the Hub and
  teleported the player to the start. The checker floor renders correctly. The navmesh works: three enemies spawned
  40 m ahead stood on it, and a 15 m path resolved. Stepping on the exit pad returned the player to the Hub and
  unloaded the map.
- **Not tested:** building with stock 4.27.2 (`OWN_MATERIAL = False`).
