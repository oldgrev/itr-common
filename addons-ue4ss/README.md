# ITRLevelAddons (UE4SS Lua)

Want to add a room, ladder or a few props to an existing Into the Radius 1 (2.7.2) level? This loads those additions alongside the original level. It can also hide existing objects, without replacing the whole level.

An **add-on** is a small cooked level in its own pak (a ladder, a room, a few props) plus a manifest that says which stock
level it belongs to. While that level is visible in the game, the add-on is streamed in next to it; when the stock level
unloads (you go through the zone transfer, back to the main menu), the add-on unloads with it. You can install any number of add-ons from different authors at once. Each loads in and ends up merged,
so you do not need a modified copy of the Hub or a way to merge everyone's changes.

**It needs one small helper pak** ([`prebuilt/ITRLevelAddons_P.pak`](prebuilt/), two logic-only Blueprints; their specs and how to rebuild them are in [`build-from-source/`](build-from-source/)). The Blueprints do the work (the streaming entry, switching the add-on on and off with its target level, hiding stock actors); this Lua only lists the manifests, makes the manager once and hands it every add-on. Nothing polls: no timer, no loop, no hook, and the mod's one `ExecuteInGameThread` is made from the game mode notification. Without the pak the mod logs `helper pak not found` and does nothing.

The first target is the Hub. An example add-on (a Hub container room on a roof, with a working ladder up to it) is in
[`../example-addon/`](../example-addon/).

## What was tested
Offline: `luac -p` (Lua 5.1) on every script; `tests/test_manifest.lua` (34 cases, the manifest parser) and `tests/test_addons_main.lua` (18 cases: the one step, the arguments handed to the Blueprint, the handshake with ITRMapLoader, the console verbs, no timer, no loop, no hook), against stand-ins. These prove the logic, not the game.

In the game (an emulated headset driving the game, UE4SS 3.0.1, 4 November 2026), with the helper pak in `Content/Paks/~mods` and the mod under a test copy of its folder:
- A manifest add-on streamed in while the Hub was visible, was off in a zone, and was on again when the player returned to the Hub (five runs).
- A manifest `transform` with `location` `[100, 200, 300]` and `scale` `[1, 1, 2]`: the streaming entry read back that transform.
- Hide lists: an actor in the Hub level and an actor in a sublevel of the Hub (`L_Hub_BaseBuilding`) were hidden with collision off, and stayed hidden after returning from a zone.
- Together with ITRMapLoader in one session: the add-on and the loader's trigger-level requests both worked.

Not run: a manifest `rotation`, `scale` other than `[1, 1, 2]`, a second add-on, `itraddons place` from another mod's console, a target that is not a stock Hub level, and installing the helper pak under its documented name `ITRLevelAddons_P.pak` (the runs used `zzz_ITRMap_ITRLevelAddons_P.pak`; the folder is the one written here).

## Installing
1. **UE4SS** 3.0.1 (the build in [the loader README](../loader-ue4ss/README.md#installing) works; so does the standard
   layout).
2. Copy the [`ITRLevelAddons`](ITRLevelAddons/) folder into the UE4SS mods folder:
   - standard UE4SS 3 layout: `<game>\IntoTheRadius\Binaries\Win64\ue4ss\Mods\ITRLevelAddons`
   - the repack layout from the loader README: `<game>\IntoTheRadius\Content\Paks\LuaMods\ITRLevelAddons`

   The empty `enabled.txt` turns it on. If your `Mods\mods.txt` lists mods, you can add `ITRLevelAddons : 1` there too;
   a mod with `enabled.txt` that `mods.txt` doesn't mention is started anyway.
3. Put the helper pak [`prebuilt/ITRLevelAddons_P.pak`](prebuilt/) into `<game>\IntoTheRadius\Content\Paks\~mods\` (create `~mods` if it isn't there).
4. For each add-on: its manifest (`<Name>.json`) goes into `ITRLevelAddons\Addons\`, its pak (`zzz_ITRAddon_<Name>_P.pak`)
   into `<game>\IntoTheRadius\Content\Paks\~mods\`.
5. Start the game and Continue.

To remove one add-on, delete its manifest and its pak. To remove all of them, delete the `ITRLevelAddons` folder and the
`zzz_ITRAddon_*` paks.

## The manifest

The manifest is a small JSON file that tells the mod what to load and where it belongs. Put one file per
add-on in `Addons\`; the mod reads every `*.json` in that folder when the game starts.

Here is an example that adds a level to the Hub and hides one existing pallet:

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

| Field | Required? | Meaning |
|---|---|---|
| `level` | required | The add-on level, a package path. It has to be in a pak under `/Game/Mods/...` |
| `target` | required | The stock level it belongs to. For the Hub: `/Game/ITR/Levels/Hub/L_Hub` (the Hub's main level; it is visible whenever you are in the Hub). Any stock level package works, for example a zone's main level |
| `name` | optional | Letters, digits, `_`, `-`. Defaults to the file name without `.json`. Must be unique; a second manifest with the same name is rejected |
| `transform` | optional | `location` [x, y, z] in cm, `rotation` [pitch, yaw, roll] in degrees, `scale` [x, y, z]. Moves the whole add-on. Leave it out (or at zero) when the add-on is built in the stock level's world coordinates, which is the easy way: you place things in the editor exactly where they go |
| `hide` | optional | Actors of the stock levels to hide, see below |
| `enabled` | optional | `false` keeps the file but skips the add-on |

If the JSON is invalid, or a field is missing or incorrect, the mod skips that manifest and logs the file name
and problem field. Other add-ons still load. Unknown fields are logged and ignored.

## Hide lists

Use `hide` when an existing object is in the way of your addition.

`hide` takes actor names, either as a plain string (an actor in the `target` level) or as
`{ "actor": "<name>", "level": "<package>" }` for an actor in another level of the same place (the Hub is several levels:
`L_Hub`, `L_Hub_BaseBuilding`, `L_Hub_Gameplay`, `L_Hub_factory` and more).

- The name is the actor's object name in the cooked level, for example `SM_Props_WoodenPallet_01_a6` or
  `Decal_Leaves_01_a10`. The example project's Hub reference shows every Hub mesh under that name (see the
  [example README](../example-addon/README.md#placing-things-by-hand)).
- A hidden actor is hidden in game and its collision is turned off. It is not destroyed, so two add-ons hiding the same
  actor is fine, and the stock level is untouched when the add-on is removed.
- The mod reapplies the hide list whenever the stock level loads, including after a trip to another zone and back.
- If an actor name cannot be found, the mod logs `NOT FOUND (check the name)` once and carries on.
- Hide static things: meshes, decals, props. Don't hide items or physics objects you can pick up (without collision a
  physics object falls through the floor), and don't hide gameplay objects (traders, doors, the mission board).

## Building an add-on
The [custom map guide](../map-making/guide.md) covers the general process. For an add-on, there are three
extra details to get right:
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

For ladders, you do not need to find a ladder Blueprint: the game has none. In 2.7.2, a ladder is a static
mesh with the `Climbable` collision profile. That profile overlaps the `Climbing` channel used by the climbing check. `SM_Ladder_Metal_350_01_a` has that profile as its default, and a
`StaticMeshActor` keeps the mesh's default collision as long as you leave its Collision Presets alone. So placing that mesh
gives a climbable ladder; changing the ladder's collision preset in the editor breaks climbing.

## Placing an add-on from another mod: `itraddons place`
If you are writing another mod, you can place an add-on directly with a console command instead of creating a manifest file. Keep spaces out of the values:
```
itraddons place name=MyAddon_1 level=/Game/Mods/MyMod/L_MyAddon target=/Game/ITR/Levels/Hub/L_Hub
```
`name`, `level` and `target` are required and checked like a manifest's. The command places the same add-on a manifest does. A name already in use, or the same level and target under
another name, is refused and logged. Send it after the game has started (at a level event), not at mod start. There is no `notify` any more: a mod that needs to know when its level is
shown can bind its own Blueprint to the level's streaming entry (`ITRAddon_<name>`) instead.

ITRMapLoader does not use this command: when both are installed, whichever starts second hands the add-on requests to the other directly, so start order does not matter.

## How it works
At the game mode notification (the real `BP_PRGameMode_C`, once), this mod's Lua spawns the manager Blueprint and calls `Place(name, level, target, hides, hideLevels, location, rotation, scale)` for every manifest.
For each add-on the manager makes one `BP_ITRLevelAddon` actor. It makes the add-on's streaming entry (named `ITRAddon_<name>`, switched off), sets the entry's transform, and listens to the
target level's own events: while the target is shown the add-on is switched on, while it is hidden the add-on is switched off. When the target is not there yet it tries again at the next level
event. The stock actors named in `hide` are hidden (hidden in game, collision off, never destroyed) every time the add-on or the level that holds them is shown. After this step the Lua does nothing.

## Log lines
In `UE4SS.log`, tagged `[ITRLevelAddons]`:
```
Addons folder ...\ITRLevelAddons\Addons: 1 manifest(s) (listed with IterateGameDirectories ...)
add-on HubCozyCorner: /Game/Mods/HubCozyCorner/L_HubCozyCorner into /Game/ITR/Levels/Hub/L_Hub, 1 actor(s) to hide
add-on HubCozyCorner placed
ready: 1 add-on(s) placed
```
If something is missing or does not load, look for these messages:

- `manifest REJECTED: <file>: <reason>`: check the named manifest and field.
- `add-on <name>: hide <level>:PersistentLevel.<actor> matches no actor of its level`: check the actor name (said once, only when the hide's level is shown).
- `add-on <name>: already placed (...): ignored`: a repeated name, or the same level and target as another add-on.
- `add-on <name>: level could not be loaded: <package>`: the add-on's pak is not installed or the package path is wrong.
- `helper pak not found`: install `ITRLevelAddons_P.pak` in `Content/Paks/~mods`.

## Limits
- A `target` that never appears is **not logged**: without a timer a target that is not there yet cannot be told from one that never will be, so the add-on just waits and binds when the target's streaming entry exists. Check the `target` against `/Game/ITR/Levels/...` yourself.
- 
Add-ons work well for scenery and climbable structures, but they do not behave like full game levels:

- Gameplay actors in an add-on (loot spawns, stashes, enemy spawners) get none of the level-start events the game sends
  when it loads its levels, so they do not start their gameplay behaviour. Meshes, lights, decals, collision and ladders don't need them.
- Nothing in an add-on is saved: what you pick up from one is kept by the normal save, but the add-on itself is the same
  every time.
- The add-on follows the stock level's visibility, not your position: it is loaded whenever you are in the Hub.
- Two add-ons can put things in the same spot; nothing checks for overlaps.

## Offline tests
If you want to run the offline checks yourself, use Lua 5.1 (`lua.exe`, `luac.exe`) and run these from `tests\`:
```
luac -p ..\ITRLevelAddons\Scripts\main.lua ..\ITRLevelAddons\Scripts\manifest.lua ..\ITRLevelAddons\Scripts\config.lua
lua test_manifest.lua
lua test_addons_main.lua
```
`build-from-source/` has the Blueprints' BPGen specs and the editor script that builds them; it needs the map-making setup described there.
