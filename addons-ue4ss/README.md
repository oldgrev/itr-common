# ITRLevelAddons (UE4SS Lua)

Adds small levels to a stock level of Into the Radius 1 (2.7.2), and hides things in it, without replacing the stock level.

An **add-on** is a small cooked level in its own pak (a ladder, a room, a few props) plus a manifest that says which stock
level it belongs to. While that level is visible in the game, the add-on is streamed in next to it; when the stock level
unloads (you go through the zone transfer, back to the main menu), the add-on unloads with it. Any number of add-ons from
any number of authors can be installed at once: each one is its own level, streamed in its own entry, so nobody needs a
modified copy of the Hub and nothing has to be merged.

The first target is the Hub. An example add-on (a Hub container room on a roof, with a working ladder up to it) is in
[`../example-addon/`](../example-addon/).

## What was tested
- Offline, October 2026: `luac -p` (Lua 5.1) on every script; the manifest parser against the example manifest and 18
  broken or unusual ones (29 cases) ([`tests/test_manifest.lua`](tests/test_manifest.lua)); and the whole script against a stand-in
  of the UE4SS API that plays main menu, Hub, zone transfer, Hub again and a new world
  ([`tests/test_main_sim.lua`](tests/test_main_sim.lua), 18 cases: two add-ons, one broken manifest, debounce, hiding,
  unload, re-entry without a second streaming entry, a level unloaded by another mod).
- In the game: **not yet**. The streaming call it uses (`LevelStreaming::CreateInstance` on an existing
  `LevelStreamingDynamic`, then loading it) is the one the map loader's streaming mode uses, which was tested in VR with
  UE4SS 3.0.1.

## Installing
1. **UE4SS** 3.0.1 (the build in [the loader README](../loader-ue4ss/README.md#installing) works; so does the standard
   layout).
2. Copy the [`ITRLevelAddons`](ITRLevelAddons/) folder into the UE4SS mods folder:
   - standard UE4SS 3 layout: `<game>\IntoTheRadius\Binaries\Win64\ue4ss\Mods\ITRLevelAddons`
   - the repack layout from the loader README: `<game>\IntoTheRadius\Content\Paks\LuaMods\ITRLevelAddons`

   The empty `enabled.txt` turns it on. If your `Mods\mods.txt` lists mods, you can add `ITRLevelAddons : 1` there too;
   a mod with `enabled.txt` that `mods.txt` doesn't mention is started anyway.
3. For each add-on: its manifest (`<Name>.json`) goes into `ITRLevelAddons\Addons\`, its pak (`zzz_ITRAddon_<Name>_P.pak`)
   into `<game>\IntoTheRadius\Content\Paks\`.
4. Start the game and Continue into the Hub.

To remove one add-on, delete its manifest and its pak. To remove all of them, delete the `ITRLevelAddons` folder and the
`zzz_ITRAddon_*` paks.

## The manifest
One JSON file per add-on in `Addons\`. Every `*.json` there is read when the game starts.

```json
{
  "name": "HubCozyCorner",
  "target": "/Game/ITR/Levels/Hub/L_Hub",
  "level": "/Game/Mods/HubCozyCorner/L_HubCozyCorner",
  "transform": { "location": [0, 0, 0], "rotation": [0, 0, 0] },
  "hide": [
    { "actor": "SM_Props_WoodenPallet_01_a6", "level": "/Game/ITR/Levels/Hub/L_Hub" }
  ]
}
```

| Field | | Meaning |
|---|---|---|
| `level` | required | The add-on level, a package path. It has to be in a pak under `/Game/Mods/...` |
| `target` | required | The stock level it belongs to. For the Hub: `/Game/ITR/Levels/Hub/L_Hub` (the Hub's main level; it is visible whenever you are in the Hub). Any stock level package works, for example a zone's main level |
| `name` | optional | Letters, digits, `_`, `-`. Defaults to the file name without `.json`. Must be unique; a second manifest with the same name is rejected |
| `transform` | optional | `location` [x, y, z] in cm, `rotation` [pitch, yaw, roll] in degrees, `scale` [x, y, z]. Moves the whole add-on. Leave it out (or at zero) when the add-on is built in the stock level's world coordinates, which is the easy way: you place things in the editor exactly where they go |
| `hide` | optional | Actors of the stock levels to hide, see below |
| `enabled` | optional | `false` keeps the file but skips the add-on |

A manifest that isn't valid JSON, or has a missing or wrong field, is rejected with a log line that names the file and the
field; the other add-ons still load. Unknown fields are logged and ignored.

## Hide lists
`hide` takes actor names, either as a plain string (an actor in the `target` level) or as
`{ "actor": "<name>", "level": "<package>" }` for an actor in another level of the same place (the Hub is several levels:
`L_Hub`, `L_Hub_BaseBuilding`, `L_Hub_Gameplay`, `L_Hub_factory` and more).

- The name is the actor's object name in the cooked level, for example `SM_Props_WoodenPallet_01_a6` or
  `Decal_Leaves_01_a10`. The example project's Hub reference shows every Hub mesh under that name (see the
  [example README](../example-addon/README.md#placing-things-by-hand)).
- A hidden actor is hidden in game and its collision is turned off. It is not destroyed, so two add-ons hiding the same
  actor is fine, and the stock level is untouched when the add-on is removed.
- It is done every time the stock level is (re)loaded, so it survives the zone transfer and back.
- A name that doesn't exist is logged once (`NOT FOUND (check the name)`), nothing else happens.
- Hide static things: meshes, decals, props. Don't hide items or physics objects you can pick up (without collision a
  physics object falls through the floor), and don't hide gameplay objects (traders, doors, the mission board).

## Building an add-on
Make it like a custom map ([`../map-making/guide.md`](../map-making/guide.md)), with three differences:
- **Build it in the stock level's world coordinates.** The add-on is streamed in at the origin (unless `transform` says
  otherwise), so an actor at (-34150, -665, -25) in your level is at that spot in the Hub. The example project has a
  reference copy of the Hub you can see in the editor while you place things.
- **Make every mesh Movable.** The Hub's lighting is baked into the Hub's levels. A Movable mesh in an add-on is lit by
  the Hub's volumetric lightmap (the baked indirect and sky light at that spot) and by its stationary lights, with dynamic
  shadows. A Static mesh would need a lightmap baked for the add-on, which it doesn't have, and renders unlit or black.
  Movable lights you add work as usual.
- **Pack only `/Game/Mods/<Name>`**: [`../example-addon/build-map.ps1`](../example-addon/build-map.ps1) does that and
  names the pak `zzz_ITRAddon_<Name>_P.pak`. Game meshes the add-on places are referenced by their paths and the game
  loads its copies.

The game has no ladder Blueprint: in 2.7.2 a ladder is a static mesh whose collision is the `Climbable` profile (it
overlaps the `Climbing` channel, which the climbing check uses). `SM_Ladder_Metal_350_01_a` has that profile as its default, and a
`StaticMeshActor` keeps the mesh's default collision as long as you leave its Collision Presets alone. So placing that mesh
gives a climbable ladder; changing the ladder's collision preset in the editor breaks climbing.

## How it works
Once a second (`PollMs` in `config.lua`), on the game thread:
1. Is the `target` level visible? After two checks in a row (`Debounce`), the add-on is streamed in: a streaming entry
   named `ITRAddon_<name>` is made with `LevelStreaming::CreateInstance` from one of the world's `LevelStreamingDynamic`
   entries (UE4SS 3.0.1 Lua can't call `LoadLevelInstance`), pointed at the add-on package, placed at `transform`, and
   loaded. The entry is made once per world and reused on every later visit, so going back to the Hub never makes a second
   copy.
2. Once the add-on is visible, the `hide` actors are hidden.
3. When the `target` level is gone for two checks (the zone transfer unloads the Hub), the add-on is unloaded.
4. If something else unloads the add-on while the target stays visible (the map loader's Hub teardown unloads every
   streaming level), the mod waits about ten seconds before asking for it again, instead of fighting over it.
5. A new world (main menu, then Continue) starts over with fresh entries.

## Log lines
In `UE4SS.log`, tagged `[ITRLevelAddons]`:
```
Addons folder ...\ITRLevelAddons\Addons: 1 manifest(s) (listed with IterateGameDirectories ...)
add-on HubCozyCorner: /Game/Mods/HubCozyCorner/L_HubCozyCorner into /Game/ITR/Levels/Hub/L_Hub, 1 actor(s) to hide
ready: 1 add-on(s); checking every 1000 ms
new world: the add-on streaming entries of the old one are gone
add-on HubCozyCorner: streaming entry /Game/ITR/Levels/Hub/ITRAddon_HubCozyCorner made (package /Game/Mods/HubCozyCorner/L_HubCozyCorner)
add-on HubCozyCorner: /Game/ITR/Levels/Hub/L_Hub is visible; streaming /Game/Mods/HubCozyCorner/L_HubCozyCorner in
add-on HubCozyCorner: /Game/Mods/HubCozyCorner/L_HubCozyCorner visible after 0.5 s
add-on HubCozyCorner: hidden: SM_Props_WoodenPallet_01_a6 in /Game/ITR/Levels/Hub/L_Hub
add-on HubCozyCorner: /Game/ITR/Levels/Hub/L_Hub is gone; /Game/Mods/HubCozyCorner/L_HubCozyCorner unloaded
```
Problems show as `manifest REJECTED: <file>: <reason>`, `NOT FOUND (check the name)`, `not visible after 60 s (is the pak
installed? the package path right?)` and `CreateInstance failed`.

## Limits
- Gameplay actors in an add-on (loot spawns, stashes, enemy spawners) get none of the level-start events the game sends
  when it loads its levels, so they sit idle. Meshes, lights, decals, collision and ladders don't need them.
- Nothing in an add-on is saved: what you pick up from one is kept by the normal save, but the add-on itself is the same
  every time.
- The add-on follows the stock level's visibility, not your position: it is loaded whenever you are in the Hub.
- Two add-ons can put things in the same spot; nothing checks for overlaps.

## Offline tests
With Lua 5.1 (`lua.exe`, `luac.exe`), from `tests\`:
```
luac -p ..\ITRLevelAddons\Scripts\main.lua ..\ITRLevelAddons\Scripts\manifest.lua ..\ITRLevelAddons\Scripts\config.lua
lua test_manifest.lua
lua test_main_sim.lua
```
