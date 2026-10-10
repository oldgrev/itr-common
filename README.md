# itr-common

Shared material for modding **Into the Radius 1** (PC VR, game version 2.7.2): custom maps, and the tools and data
behind them.

## Example map test
1. **UE4SS:** Example used was "UE4SS for ITR1" from Nexus Mods for no particular reason.
   (https://www.nexusmods.com/intotheradiusvr/mods/359; we used `UE4SS-ITR-359-v3-0-1-321-gc62ada0`). Then:
   - copy `dwmapi.dll` and the `ue4ss` folder into `<game>\IntoTheRadius\Binaries\Win64\`;
   - maybe don't copy `override.txt` (the game hung at startup for me);
   - I had to rename `ue4ss\Mods` to `ue4ss\LuaMods` mentioned on the install instructions. Not sure why I had that issue since I assumed the version included was the experimental version and that the folder structure would line up but someone can correct me here.
2. **The loader:** copy [`loader-ue4ss/ITRMapLoader`](loader-ue4ss/) into `ue4ss\LuaMods\`. In
   `ITRMapLoader\Scripts\config.lua`, set `AutoLoadInHub = "Example",`.
3. **The map:** copy [`example-map/prebuilt/zzz_ITRMap_Example_P.pak`](example-map/prebuilt/) into
   `<game>\IntoTheRadius\Content\Paks\`.
4. **Play:** start the game and Continue into the Hub. A few seconds after the Hub has loaded, you're moved onto the
   example map: a checker floor, walls, a hut and a ramp.
5. **Leave:** walk onto the small pad with a post, about 8 m to your left. You're taken back to where you stood in
   the Hub. On a keyboard, F7 does the same.

To undo it all: delete the pak, `dwmapi.dll` and the `ue4ss` folder. Details and troubleshooting:
[`loader-ue4ss/README.md`](loader-ue4ss/README.md).

## Make your own
**Start here: [`map-making/guide.md`](map-making/guide.md)**. It goes from nothing to walking around your own map.

It's long and a pain in the neck because it involves building a specific unreal editor version to be able to make the materials and shaders work. If you're not using new materials then you can probably just use the normal version. Not sure, untested.

| Path | What | State |
|---|---|---|
| [`map-making/guide.md`](map-making/guide.md) | Making a map with the game's own systems: which editor, project setup, building, navmesh, cook and pack, entering the map | Tested in game unless marked |
| [`map-making/extended.md`](map-making/extended.md) | What a mod running code in the game can add (spawning content and enemies, lighting, navmesh tricks), with how far each was tested | Mixed, labelled |
| [`example-map/`](example-map/) | A worked example: project skeleton, a script that builds a small test map, config extraction, cook/pack/install script | Tested in VR, including a material compiled by our editor; prebuilt pak included |
| [`loader-ue4ss/`](loader-ue4ss/) | UE4SS Lua mod that streams a custom map in and moves the player to its start | Tested (VR and desktop) |
| [`engine/itr-ub-layouts.hashpatch.json`](engine/) | The engine change that makes the Oculus UE 4.27 fork compile shaders the game can use, in a format with no Epic source lines (apply with `tools/hashpatch.py`) | Tested (result identical to our patched engine) |
| [`tools/`](tools/) | `merge_gitdeps.py` (make the fork's dependency download work), `hashpatch.py`, `ub_extract_exe.py` / `ub_material_diff.py` (recover and compare uniform-buffer layouts), `shadermap_dump.py` / `dxbc_disasm.py` (inspect compiled shaders in cooked packages) | Used throughout |
| [`data/ub/game-2.7.2.json`](data/ub/) | The game's shader parameter layouts, recovered from `IntoTheRadius-Win64-Shipping.exe` 2.7.2 | |

Notes:
- Nothing here contains Unreal Engine source code. The engine patch identifies the original lines it changes by hash
  and line number, and carries only new lines. You need your own licensed copy of the engine source to apply it.
- `data/ub` is metadata (member names, offsets, sizes) read from the game's executable. No game assets are included.
- Python tools need Python 3. Some need packages: `pip install pefile capstone lz4`.

## Licence
- Everything in this repository is licensed under the **GNU Affero General Public License v3.0** ([`LICENSE`](LICENSE)),
  **except:**
  - [`engine/`](engine/): **MIT** ([`engine/LICENSE`](engine/LICENSE)). The patch's lines are compiled into Unreal
    Engine, and the Unreal Engine EULA doesn't allow engine code to be combined with copyleft licences such as the
    AGPL. MIT keeps the patch usable by every engine licensee.
  - [`example-map/prebuilt/`](example-map/prebuilt/): a cooked package built with Unreal Engine. It contains shader
    code compiled from Epic's engine shaders, so it's governed by the Unreal Engine EULA, not by this repository's
    licence.
  - [`data/ub/`](data/ub/): metadata read from the game's executable; no licence is claimed over it.
- Maps you build with the example scripts are your own work; the AGPL covers the scripts, but I've no idea how it all accumulates for your own maps etc.
