# ITRMapLoader (UE4SS Lua)

Streams a custom map into Into the Radius 1 (2.7.2), puts the player at its start marker, and takes them back to the
Hub when they step on an exit marker. The game can't enter custom maps by itself yet, so this is the one piece of
runtime code a map needs.

## Tested (October 2026)
Tested with UE4SS 3.0.1 and the [example map](../example-map/), in VR (SteamVR) and on desktop:
- **Load:** auto-load fires about 7 s after the Hub finishes loading, then streams the map and teleports the player
  to the start marker. The player stays on the map, and the navmesh works (enemies stood on it).
- **Exit:** stepping onto the exit marker returns you to where you stood before the map loaded, and unloads the map.
- **Coexistence:** works alongside a mod that uses an `XINPUT1_3.dll` proxy.

Not tested:
- the F7 key (it calls the same load/unload functions);
- entering the Hub through the menu's Continue button. Our test used a shortcut into the Hub, and the auto-load waits
  for the game's level manager to report ready, so Continue should behave the same;
- installing UE4SS with Vortex.

## Install
1. **UE4SS:** "UE4SS for ITR1" on Nexus Mods, https://www.nexusmods.com/intotheradiusvr/mods/359 (a repack of UE4SS
   3.0.1 by MerithXYZ; we used file `UE4SS-ITR-359-v3-0-1-321-gc62ada0`). Manual install:
   - copy `dwmapi.dll` and the `ue4ss` folder from the zip into `<game>\IntoTheRadius\Binaries\Win64\`, next to
     `IntoTheRadius-Win64-Shipping.exe`;
   - **don't copy `override.txt`.** It points UE4SS at `Content\Paks`, and when the game is started normally that
     path doesn't resolve. The game then hangs at startup (about 12 MB of memory, no window) behind a hidden message
     box, "UE4SS Error: Failed to load UE4SS.dll".
2. **Rename `ue4ss\Mods` to `ue4ss\LuaMods`.** This build's `UE4SS-settings.ini` has `ModsFolderPath = ./LuaMods`.
   Without the rename, `UE4SS.log` shows a `directory_iterator` error and no Lua mod (this one included) starts.
3. Copy the `ITRMapLoader` folder into `ue4ss\LuaMods\`. Its empty `enabled.txt` turns it on; no `mods.txt` edit is
   needed.
4. Edit `ITRMapLoader\Scripts\config.lua`:
   - `Maps`: one entry per map (name, level path, start tag);
   - `AutoLoadInHub`: the map to load in the Hub (VR);
   - `Key`: the keyboard key (default F7);
   - `ExitTag`: the exit marker's tag (default `itr:exit`).

To uninstall, delete `dwmapi.dll` and the `ue4ss` folder.

## Use
- **VR:** set `AutoLoadInHub = "Example"` (a map's `Name`). Each time you enter the Hub, the map loads once, and
  you're moved to its start a few seconds later. To leave, walk onto the map's exit marker (within 1.5 m).
- **Keyboard:** F7 loads the next map in the list; pressing it again unloads it and returns you.
- The script never loads from the main menu.
- `ue4ss\UE4SS.log` shows `[ITRMapLoader]` lines, e.g. `streaming ...`, `teleport to ...: true`,
  `1 exit marker(s)`, `exit marker reached`, `returned to the Hub`.

## For map makers
- Place a `TargetPoint` tagged `itr:player_start` where the player should arrive.
- Place a `TargetPoint` tagged `itr:exit` where they can leave; give it something visible (the example uses a small
  pad and a post).
- Without an exit marker, players in VR have no way back. They'd have to quit to the menu.

## How it works, and a UE4SS 3.0.1 limitation
The native call would be `LevelStreamingDynamic::LoadLevelInstance(World, Level, Location, Rotation, out bOutSuccess,
OptionalLevelNameOverride)`. UE4SS 3.0.1 can't make it from Lua: after a non-struct out-parameter (`bOutSuccess`) it
leaves that parameter's table on the Lua stack, and the next parameter reads the table instead of its own argument.
The log then shows `[push_strproperty] StrProperty can only be set to a string or FString`; passing a string in the
out-parameter's place fails with "no table was on the stack".

So the script does what `LoadLevelInstance` does internally:
1. Call `LevelStreaming::CreateInstance(<unique name>)` on an existing dynamic streaming entry. This makes a new entry
   and adds it to the world.
2. Set its `PackageNameToLoad` to the map's package.
3. Set `LevelTransform` to identity.
4. Call `SetShouldBeLoaded(true)` and `SetShouldBeVisible(true)`.

The loaded level appears under a name like `/Game/ITR/Levels/Hub/ITRMap_Example_1`. That's only the instance's
name; the content is your package.

Other details:
- The script waits until the streaming level reports `IsLevelVisible()`, finds the tagged `TargetPoint`s whose outer
  is that level, and calls `K2_TeleportTo`.
- "In the Hub" means the Hub level is visible and `LevelManager::IsReady()`, on two checks 2 s apart. During the
  transition the Hub level is already visible while the player is still in the menu room.
- Calls into the game run inside `ExecuteInGameThread`; the timers use `LoopAsync`.
