# bullet-penetration

Bullets go through stuff.

How far a bullet gets through things? It varies. 

How fast is it coming out the other side? Slower?

How does materials affect it? Yes.

It is a UE4SS Lua mod plus a small Blueprint pak. Because it's faster that way but it could all be lua but then who has 1ms to spare?

## Install
You need UE4SS in the "UE4SS For ITR1" layout described in the [top-level README](../README.md) (`UE4SS.dll` in `Content\Paks`, Lua mods in `Content\Paks\LuaMods`).

Or you have a different version you have set up the way you like in which case you can probably just skim.

1. Copy [`prebuilt/BulletPenetration_P.pak`](prebuilt/) into `<game>\IntoTheRadius\Content\Paks\~mods\` (create `~mods` if it isn't there).
2. Copy the [`BulletPenetration`](BulletPenetration/) folder into `<game>\IntoTheRadius\Content\Paks\LuaMods\`. The `enabled.txt` in it turns the mod on.
3. Start the game. `UE4SS.log` gets one line from the mod: `[BulletPenetration] active`, or `[BulletPenetration] failed: <reason>`.

## How it works
The pak has `BP_PenBulletProjectile` (`/Game/Mods/BulletPenetration/`), which is a biological child of the game's `BP_RadiusBulletProjectile`. We have no idea who the father is, and all we know is that no game asset is overridden.

The game reads `DA_AmmoConfig.BulletClassActor` every time it spawns a bullet. The Lua script writes that property after the data asset is loaded (and again after a map load, or if the asset is reloaded), so every bullet from then on is a `BP_PenBulletProjectile`. After that the Lua script does nothing per shot and nothing per hit because Lua is fast but also slower that you'd want when shooting at things.

The Blueprint binds `OnComponentHit` of the bullet's sphere. On a hit it:
1. Lets the game have the hit unchanged when it should: no shooter, zero damage, the scale is 0, the bullet is too slow, the surface is not a static mesh (pawns, armour and landscape never pass), the hit is glancing (the game's ricochet), or the shot has already passed `MaxPenetrations` walls.
2. Works out the flight direction. In order: the direction a continuation bullet was spawned with; the weapon's barrel axis; the bullet's forward; impact point minus the shooter; the surface normal.
3. Looks up the resistance of the material at the entry point (a short trace against that mesh only) and works out a budget: `Penetration * BudgetK * (v / v0)^2 * Scale`. The longest probe is `budget / resistance`.
4. Traces the mesh from the far end of the probe back to the entry to get the thickness. A one-sided surface with no second face counts as a sheet of `SheetThicknessCm`.
5. If `resistance * thickness` is under the budget, the bullet passes. The exit speed is `v * sqrt(1 - cost / budget)`; below `MinExitSpeed` it is blocked. A new bullet is spawned just beyond the exit with the same ammo, owner and instigator, damage scaled between `DamageFloor` and 1 by the speed it kept, and the exit impact effect plays. The bullet that hit is disposed.

The sphere is set so it cant so then the bullet keeps going in the launch direction.

## Material table
Resistance per cm, by the physical material of the surface. The budget at scale 1 is 30 for a 7.62x39 FMJ at full speed, so it passes 15 cm of wood and nothing of concrete.

| Resistance | Physical materials |
|---|---|
| 0.3 | Leaves, Grass, Cardboard |
| 1 | Glass, Cloth, Carpet, Plastic |
| 2 | Wood |
| 4 | Plaster, Tile, Clay, Dirt, Sand |
| 6 | smallMetal |
| 8 | Brick, Asphalt |
| 15 | Concrete, Rock |
| 20 | Metal |
| 15 | anything unmarked (no physical material, or one not listed): same as concrete |

Rubber, water and blood are not in the table either, so they count as unmarked.

We'll see how that all works out anyway.

## Tuning
Everything is in [`BulletPenetration/Scripts/config.lua`](BulletPenetration/Scripts/config.lua) and is read at game start. `Scale` multiplies the budget; the rest are the numbers above (`BudgetK`, `MinSpeed`, `MinExitSpeed`, `MaxPenetrations`, `DamageFloor`, `SheetThicknessCm`, `UnmarkedResistance` and so on), each commented. `PlayerOnly = true` limits it to your bullets.

In the game console (UE4SS console command), for the running game only:
- `bpen scale <x>` sets the scale; `bpen up` doubles it, `bpen down` halves it, `bpen off` sets it to 0.

Scale 1 is the tuned setting. 10 and 50 are for seeing the effect: at 50 nearly everything short of a thick concrete wall passes, which is handy for checking it works without hunting for a thin wall.

## Speed
Pop quiz hotshot, a blueprint adds about **0.05 ms** to the mean frame time over stock at 10 shots per second (single run, 18.47 ms stock against 18.52 ms with the mod at scale 1; 0.5 ms at scale 50). Once the bus goes 50 miles an hour, if it drops below 50. What do you do? What do you do? An earlier version that was Lua only on every hit measured +0.84 ms in the same test. So if you're thinking of shooting the hostage, you've got an extra 1 ms.

## Known limits
- Mesh are judged by the material at the point of entry only.
- Unmarked surfaces count as concrete. Many props have no physical material, so most of them stop a bullet at scale 1. Maybe in the future I need an override table.
- Rubber, water and blood are not special-cased. They count as unmarked (concrete resistance), so at scale 1 they stop a bullet and at a high scale they let it through. That's tough blood.
- Walls built from separate meshes per side are two walls, so it can get messy.
- The exit direction was changed to use the weapon's barrel axis because this is still early days.

## Uninstall
Delete `Content\Paks\~mods\BulletPenetration_P.pak` and `Content\Paks\LuaMods\BulletPenetration`. Shift delete them, purge them from existence. Make them sorry they were ever born.

## Rebuilding the pak **we have bullet penetration at home**
[`build-from-source/`](build-from-source/) has the generator that writes the Blueprint (`Tools/gen_penbullet.py --lean`), the editor script that builds it (`Scripts/pb_build.py`) and the pak step (`build-pak-pb.ps1`). It is not self-contained. You also need:
- the Blueprint generator (BPGen), the `ItrShowcaseEditor` editor plugin that provides `unreal.ItrShowcaseBPGen`, which is not in this repo;
- a UE 4.27 project named `IntoTheRadius` with C++ stubs of the game's `RadiusBulletProjectile`, `RadiusBulletComponent` (with `_ammoInfo`), `AmmoInfo`, `FLFirearmProjectiles`, `FLSpawn` and `RadiusProjectile`. They're not in the repo. I want to make it easy for people to build, but I also don't want to get it dmca'd because they are extracted the game;
- the engine at `C:\ue427\Engine` (edit the paths in the scripts).

The steps are: `python Tools/gen_penbullet.py --lean --out <specs dir>`; run `Scripts/pb_build.py` in the editor with `PB_SPECS=<specs dir>` and `PB_OUT=<result.json>`; cook `Content/Mods/BulletPenetration`; run `build-pak-pb.ps1`.

The parent `BP_RadiusBulletProjectile` is a stand-in used only. It's like the stubs we all know and love that don't get packed. The pak holds `BP_PenBulletProjectile` alone.
