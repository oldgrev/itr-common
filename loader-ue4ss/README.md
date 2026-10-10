# ITRMapLoader (UE4SS Lua)

A small UE4SS script that gets you into a custom map in Into the Radius 1 (2.7.2) and back out again. The game
can't load custom maps yet, so you need something like this to get into one.

When you arrive in the Hub (or press a key), it streams your map in and moves you to the map's start marker. When
you step on the map's exit marker, it takes you back to where you were in the Hub and unloads the map.

## What we've tested
We tested it in October 2026 with UE4SS 3.0.1 and the [example map](../example-map/):
- In VR (SteamVR), installed the way the Nexus page describes: the map loaded about 7 s after the Hub finished
  loading, we were moved to the start, enemies we spawned stood on the navmesh, and the exit pad took us back and
  unloaded the map.
- We got the same result with our first install layout (see the end of the install section).
- It runs fine next to a mod that uses an `XINPUT1_3.dll` proxy.

Not tested yet:
- The F7 key. It calls the same load and unload code, so it should be fine.
- Going into the Hub with the menu's Continue button. Our test used a shortcut into the Hub, and the script waits
  for the game's level manager to say it's ready, so Continue should work the same way.
- Installing UE4SS through Vortex. The mod page says the ITR extension expects this exact build.
- On desktop (`-nohmd`) the auto-load never fires. In that mode the game doesn't seem to finish moving you into the
  Hub, so the level manager never reports ready. It isn't a real way to play anyway.

## Installing
1. **UE4SS.** We used "UE4SS for ITR1" from Nexus Mods (https://www.nexusmods.com/intotheradiusvr/mods/359), a
   repack of UE4SS 3.0.1 by MerithXYZ, file `UE4SS-ITR-359-v3-0-1-321-gc62ada0`. Use Vortex with the Into the Radius
   extension, or do what the mod page says for a manual install:
   - put `dwmapi.dll` and `override.txt` in `<game>\IntoTheRadius\Binaries\Win64\`. `override.txt` just contains
     `../../Content/Paks`, which tells `dwmapi.dll` where to find `UE4SS.dll`;
   - put the **contents** of the zip's `ue4ss\` folder in `<game>\IntoTheRadius\Content\Paks\`, so `UE4SS.dll`,
     `UE4SS-settings.ini` and the `Mods` folder end up directly in `Paks`;
   - in `Paks`, rename `Mods` to `LuaMods`. This build's `UE4SS-settings.ini` has `ModsFolderPath = ./LuaMods`, and
     if you skip the rename, `UE4SS.log` shows a `directory_iterator` error and no Lua mods start at all.

   Our first layout also worked: `dwmapi.dll` and the whole `ue4ss` folder in `Binaries\Win64`, no `override.txt`,
   and `Mods` renamed to `LuaMods` inside the `ue4ss` folder.
2. Copy the `ITRMapLoader` folder into `LuaMods`. The empty `enabled.txt` inside it turns it on, so you don't need to
   touch `mods.txt`.
3. Edit `ITRMapLoader\Scripts\config.lua`:
   - `Maps` lists your maps (a name, the level path, and the start tag);
   - `AutoLoadInHub` is the map to load when you get to the Hub, which is what you want in VR;
   - `Key` is the keyboard key, F7 by default;
   - `ExitTag` is the exit marker's tag, `itr:exit` by default.

**If the game hangs at startup** (no window, around 12 MB of memory), there's a hidden "UE4SS Error: Failed to load
UE4SS.dll" message box behind it. It means `UE4SS.dll` isn't where `override.txt` points. We did that the
first time, by copying the `ue4ss` folder itself into `Paks` (so it ended up at `Paks\ue4ss\UE4SS.dll`) instead of
what's inside it.

To uninstall, delete `dwmapi.dll`, `override.txt` and the UE4SS files you copied (`UE4SS.dll`,
`UE4SS-settings.ini`, `LuaMods`, `LogicMods` and so on).

## Using it
- In VR, set `AutoLoadInHub = "Example"` (or whichever map name). Every time you go into the Hub the map loads once,
  and a few seconds later you're on it. To leave, walk onto the exit marker (you need to be within about 1.5 m).
- On a keyboard, F7 loads the next map in your list, and pressing it again takes you back and unloads it.
- It never loads anything from the main menu.
- `UE4SS.log` (next to `UE4SS.dll`) shows what it's doing. Look for lines starting with `[ITRMapLoader]`, like
  `streaming ...`, `teleport to ...: true`, `1 exit marker(s)`, `exit marker reached` and `returned to the Hub`.

## If you're making a map
- Put a `TargetPoint` tagged `itr:player_start` where people should arrive.
- Put another `TargetPoint` tagged `itr:exit` where they can leave, and put something visible there so they can
  find it. The example uses a small pad with a post.
- Please don't skip the exit. Without one, people in VR are stuck until they quit to the menu.

## How it works
Normally you'd call `LevelStreamingDynamic::LoadLevelInstance(World, Level, Location, Rotation, out bOutSuccess,
OptionalLevelNameOverride)`. UE4SS 3.0.1 can't make that call from Lua, though. After a non-struct out-parameter
like `bOutSuccess`, it leaves that parameter's table on the Lua stack, and the next argument gets read from the wrong
place. You get `[push_strproperty] StrProperty can only be set to a string or FString` in the log, and if you pass a
string where the out-parameter goes instead, it complains that "no table was on the stack".

So the script does what `LoadLevelInstance` does internally:
1. It calls `LevelStreaming::CreateInstance(<unique name>)` on an existing dynamic streaming entry, which makes a new
   entry and adds it to the world.
2. It sets that entry's `PackageNameToLoad` to your map's package.
3. It sets `LevelTransform` to identity.
4. It calls `SetShouldBeLoaded(true)` and `SetShouldBeVisible(true)`.

Your level will show up with a name like `/Game/ITR/Levels/Hub/ITRMap_Example_1`. That's just the instance name;
what actually gets loaded is your package.

Once the level is visible, the script looks for the tagged `TargetPoint`s in it and calls `K2_TeleportTo` on the
player.

"Are we in the Hub yet?" took a couple of goes to get right. While you're coming from the menu, the Hub level
already counts as visible even though you're still in the menu room. So the script also waits for
`LevelManager::IsReady()`, and checks twice, 2 s apart.

Anything that touches the game runs inside `ExecuteInGameThread`, and the timers use `LoopAsync`.
