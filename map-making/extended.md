# Making maps for Into the Radius 1 (2.7.2): extra things a mod can do

This goes with [`guide.md`](guide.md), which covers building and loading a map. This page is about things that need
a mod running code inside the game: spawning stuff, enemies, lighting and so on. For each one we've written down how
we did it and how far we tested it.

We did all of this with our C++ mod, which we're not releasing. The idea is that anyone can rebuild the bits they
want in whatever framework they like, as long as it can call engine functions (UFunctions) on the game thread.

When we say **VR** we tested it in the headset. **Desktop** means we ran the game with `-nohmd` and checked that it
loaded, didn't crash and logged the right things. **Harness** is the same `-nohmd` run, but driven by a script that
sends commands and asserts on the game's state and log (see "Testing without a headset" below), so the checks are
real ones and repeatable. **Offline** means we checked files or ran tools, never the game. **Untested** means just that.

## How our mod hooks in
- A proxy `XINPUT1_3.dll` sits next to `IntoTheRadius-Win64-Shipping.exe` and loads our DLLs. The game imports
  `XINPUT1_3.dll` directly (ordinals 2 and 3). Don't put a proxy next to `IntoTheRadius.exe` in the game folder,
  because that's only a launcher and the proxy never reaches the game.
- We generated a C++ SDK with Dumper-7. Our code runs on the game thread from a `ProcessEvent` hook, about 20 times a
  second.
- A UE4SS Lua mod can do most of this too, since nearly all of it is UFunction calls. Our map loader is a UE4SS
  script and works in VR (native mode) ([`loader-ue4ss/`](../loader-ue4ss/)). Watch out for functions with non-struct
  out-parameters though, UE4SS 3.0.1 gets the arguments after them wrong.

## Getting the player onto the map (VR)
The recommended way is the loader's native mode: it registers the map as a game level (a streaming entry, a level-table row
and a map centre, all at runtime) and enters it with the game mode's `TransferToLevel`, so the game itself runs the
transition, the Hub unload and the level start events described below. Everything in this file that says "by hand" is what
the streaming mode, the fallback, has to do because the game doesn't know the map is a level. See
[`loader-ue4ss/`](../loader-ue4ss/) and [`guide.md`](guide.md) §6.

The streaming way: stream the level in at zero offset with `ULevelStreamingDynamic::LoadLevelInstance`, then `K2_TeleportTo` the player
pawn to a tagged `TargetPoint`. Do it from the Hub. From the main menu the teleport says it worked, but the VR player
stays where they are. The game has `IPRPlayerCharacter::TeleportPlayer`, but it's a native event with no UFunction
on the player class, and calling it through a generated interface wrapper crashes on a null pointer. The full recipe
is in [`guide.md`](guide.md) §6, and the UE4SS version is in [`loader-ue4ss/`](../loader-ue4ss/).

### Replacing the Hub while your map is loaded (harness)
If the map is west of about X −30,000 (or you want the Hub's fog and lighting gone), unload all the Hub's streaming
levels once the player is standing on your map, and bring the Hub back with the game's
`LevelManager::LoadLevel(Level.Hub)` on the way out. The sequence, and why, is in [`guide.md`](guide.md) §4 and §6.
Our C++ mod does it and it passed the harness: the player stayed put for 20 s and all the teleport points across a
2.5 km map held; the exit left the player in `Level.Hub` with the Hub levels visible. Two details from that:
- The Hub's main level shows as visible well before it's ready, and in a `-nohmd` launch `LevelManager::IsReady()`
  never goes true. "Ready" there means the level manager's state is 0, the Hub's nine streaming levels are loaded and
  visible, and the player stands on Hub ground.
- The game's Hub load doesn't unload your map. We ask it, wait, and unload the map ourselves.

In VR the first version of this failed: the snap-back fired within half a second of the teleport, before the teardown
had a chance to run, and the exit unloaded the map under the player. The staging point is what fixed the first, and
never unloading under the player the second. We haven't redone it in VR.

## Spawning content from markers (desktop)
We tried items, a stash, a loot point, prefabs and trees. You put a `TargetPoint` tagged `spawn:<asset path>` in the
map, and when the map loads the mod looks the asset up with `UKismetSystemLibrary::LoadAsset_Blocking`:
- if it's a blueprint (`<path>.<Name>_C`), it gets spawned at the marker with
  `UGameplayStatics::BeginDeferredActorSpawnFromClass` and `FinishSpawningActor`;
- if it's a static mesh, it becomes a `StaticMeshActor` using that mesh.

Everything spawned this way gets destroyed when the map unloads. There are a few downsides:
- spawned things aren't part of the navmesh, so NPCs walk straight through them;
- anything set up only in the construction script is lost;
- they don't have stable names, so they can't be saved;
- we never checked whether `BP_LootSpawnPoint` actually produces loot outside a zone.

Honestly this is a stop-gap. Placing the game's blueprints in the editor works (see [`guide.md`](guide.md) §4,
harness-tested), so for spawners, stashes and loot use that and the activation below instead.

One gotcha: in Dumper-7 SDKs, `FName::ToString()` only gives you the part after the last `/`. For tags that hold
paths, use the raw string.

## Enemies (VR on a custom map: patrolling, chasing, being lured by sound; desktop for 1.0's placements)
- **By gameplay tag.** `UInfosConfig::GetInfosConfig()->GetNPCClass(<tag>)` (for example `NPC.Monster.Mimic.AKM`)
  gives you the class. Spawn it deferred and set `APRCharacter::IdleWalkRadius` before finishing the spawn.
- **By class path.** Load `/Game/ITR/BPs/Chars/<Type>/BP_Char_<Type>.BP_Char_<Type>_C` directly. Fragment,
  transparent Fragment, Shooter, Shooter_AK, Ring, Zombie and Harvester are all still in 2.7.2.
- **Placing them.** Project the spot onto the navmesh with `UNavigationSystemV1::K2_ProjectPointToNavigation`
  (extent 300, 300, 1000), or fall back to `K2_GetRandomReachablePointInRadius`, then spawn 1 m above it.
- **Squads.** On each member's AI controller, call `AddSquadMember(Pawn)` for every other member. That's how the
  game's `BP_CharSpawner` does it.

What we haven't done: hooking them into the save system, respawn timers, and spawning the game's spawner actors
(`BP_CharSpawner_C`) from markers.

## Level activation: making placed gameplay actors work (harness)
Spawners, rifts, loot points, stashes and anomalies you placed in the editor ([`guide.md`](guide.md) §4) do nothing on
a streamed map. Every one of them derives from `APRBasicActor`, which has `OnLevelPrepare(LevelTag)`,
`OnLevelStarted(LevelTag)`, `OnGameStarted()` and `OnTransitionEnd()`. The actors bind those to the game's events
manager, and the game mode fires them once per level load. Your map streams in after the Hub already went through them.

So do it by hand, on the actors whose level is your streamed one, about 3 s after they've had BeginPlay. Call each
function **on the actor** so blueprint overrides run (`BPA_Stash` and the anomalies override `OnLevelStarted`):
1. `OnLevelPrepare(<level tag>)` on every `APRBasicActor`. Spawner generators check here whether they're excluded in
   the save and destroy themselves if so, so check the actor is still valid afterwards.
2. On loot points (`BP_LootSpawnPoint_C` and everything below it, stashes included): `GenerateLoot()` and then
   `SpawnLoot()`. This stands in for the game mode's loot pass.
3. `OnLevelStarted(<level tag>)` (stash doors, anomalies), `OnGameStarted()` (the lightning anomaly's effects),
   `OnTransitionEnd()` (spawners and generators go live).

Don't fire the events manager's global `FireOnLevelStarted`/`FireOnLevelPrepare` instead. The game mode, the player
pawn, the UI and the autosave listen to those too. The level tag was `Level.Hub` throughout, because a streamed map
doesn't change it.

Harness result (C++ mod, 10 actors: a rift, a Mimic spawner, 4 random-loot points, a stash, 3 anomalies): every call
found its function, 2 live Mimics showed up 8 s later 7 to 9 m from the spawner and stood on the navmesh, and the 5 loot
nodes made 7 items that physically sat next to them. What we haven't separated: whether the Mimics came from the
spawner's `Wild` proximity logic or from the generator. With `Wild` off and our generator ID, nothing spawned
in the 25 s we watched, so the generator path is *not* shown. Also untested: the tide (do these actors reset?), and
anything in VR. The UE4SS loader has a Lua port of this which hasn't been run
([`loader-ue4ss/`](../loader-ue4ss/README.md)).

Generators have an ID tag (`NPC.Generator.*`). We first reused a vanilla one, `Buffer01`. That shares the save's
generator entries with the real one, and kills itself if the save excluded it. Use your own IDs. We did, and the
generator survived `OnLevelPrepare` and stayed alive, but nobody has checked that it can actually call spawners with an
unregistered ID (the game may log "Generator ID is invalid").

## Loot: budgets, your own tags and tables
How loot is chosen, from the blueprints and the exe, and then checked in the harness where it says so:
- A loot node (`BP_RandomLoot`, stashes, corpses) has a `LootTable` gameplay tag and a `LootPoints` cap.
- `DA_GameConfig.LootArray` maps tag to `{DataTable, LootPoints, Conditions}`. `LootPoints` there is the tag's
  **budget**: nodes using the tag draw rows from its DataTable until the budget's spent. That's why a big map with few
  tags comes out sparse. The lookup is by tag only; there's no level in it, so it works on a streamed map (harness).
- Points already spent are saved with the game, in `USpawnerGameData.LootTablePoints`. **The key is the DataTable's
  name** (`DT_Loot_Buffer_Valuables`), not the tag, and has no zone part (harness). Two tags that share a DataTable
  share their spent points, and so does your tag with a vanilla one if you borrow its table. We saw the real Buffer
  tables' used points change when ours borrowed them. The tags' budgets didn't change.
- `GenerateLoot` saves its result per node (`InstanceID`), so reloading doesn't re-roll. Give your nodes unique IDs
  with your own prefix; vanilla uses `RandomLoot-NNNN`.

**Registering your own tags at load** (harness, C++ mod; the same thing in UE4SS Lua is untested). Add entries to
`LootArray` before any of your nodes generates. A tag in a cooked asset keeps its name even if nobody registered it, and
the lookup is a plain map find, so you don't need a tag ini (which a late mod pak couldn't add anyway). In Lua that's
`TMap:Add` on `GC.LootArray` with the donor's `LootTable` pointer. We added 31 tags this way and the map grew from 89
to 120 entries. In C++ you have to write the map's memory by hand, because we haven't found the engine's allocator.
Nodes on those tags got items on the Hub-streamed map.

What the budget does, as measured: a tag with budget 1 and a node asking for 4 points hid the node and spent 1, so it
holds. A tag with budget **0** still gave one item (1 point used of 0), so 0 isn't a way to switch a tag off, and we don't
know why. Which of "hidden" or "falls back to the current level's loot" happens when a budget runs out isn't settled.

**Including your own DataTables** *(in progress)*. Because the spent points are keyed by table name, giving each tag a
DataTable (a copy of a donor's rows under `/Game/Mods/<Name>/Loot/`) keeps you off the vanilla budgets. Our
generator makes 31 of them from the game's tables (1,211 rows). They build in the editor; we have not yet cooked them and
run them in the game, so we can't say yet that the game accepts them. One risk is that the table is read and cached
the first time its tag is used, so point the entry at it before then.

Two ways with no budget at all, both untested: nodes with baked `CustomLootConfigs` (the game's "find the stash"
mission does this from a runtime-spawned stash), or your own blueprint child of `BP_RandomLoot` that builds items itself.

## Testing without a headset: the `-nohmd` harness (works for us)
We got tired of hours in VR for each question, so most of the checks above ran unattended. It's a technique, not a
tool you can download; ours sits on top of our private mod. The shape of it:
1. Start the game with `-nohmd`. The mod's small web panel (localhost) takes commands and returns JSON state.
2. A `-nohmd` start has no main menu, so you can't press Continue. What does work is asking the game mode to
   `TransferToLevel(Level.Hub)`, which is what the Hub's gates do. (`LevelManager::LoadLevel` for the Hub from the
   startup world left the level tag at `None` and the pawn fell forever.)
3. Wait for the Hub to be really there (see above), then run a scenario: load the map, teleport to markers, wait,
   and check `GET /state` (level tag, loaded levels, player position and ground, hold times) and the game's log.
4. Quit the game cleanly at the end (close the window; kill after 30 s) and write a PASS/FAIL line per check.

A full run of the showcase scenario takes about 4.7 minutes. Hard timeouts everywhere, because a hung game would
otherwise hang the test. An attempt at doing the same *with* a (fake) VR headset, so that Continue can be pressed with
a laser, wasn't reliable: the SteamVR dashboard sits on top of the game and takes the laser.
This is **harness**, not VR: it can't tell you what things look like, whether it's comfortable, or whether something
only breaks with a real headset.

## Lighting, fog and exposure (VR)
Custom maps stream into the Hub, so the Hub's sun, sky light, post-process volumes and height fog all affect your map
too. A mod can hide the Hub's lights (`SetVisibility(false)`), switch off its post-process volumes (`bEnabled = 0`),
scale every `ExponentialHeightFogComponent`'s density, and put it all back when the map unloads.

Maps with baked lighting also need the Hub's lighting-scenario level hidden (see [`guide.md`](guide.md) §7).

You can also drive a level's directional light, sky light and fog from curves at runtime for a day/night cycle. We
did this in VR to bring back ITR 1.0's day/night and fog weather, using 1.0's curve assets. Changing intensity and
colour doesn't need a sky recapture.

One thing that bit us: if you load a `USoundBase` (or anything else) with `LoadAsset_Blocking` and only keep it in a
C++ pointer, the garbage collector frees it and the next time you use it the game crashes. Keep a proper reference,
or just load it again each time.

## Swapping materials by role (VR, but you probably don't need it)
Meshes tagged `mat:<role>` get one of the game's material instances assigned at runtime with `SetMaterial`. We used
this before we had the special editor. Now maps can use custom materials, or reference the game's in the editor.

## Gameplay without a mod: generated blueprints (cooks fine, untested in game)
If all you want is a teleport pad, a light that follows something, or a trigger, you don't need a runtime mod: a
blueprint in your own pak can do it, as long as it only references engine classes. Clicking those together by hand is
miserable, so we wrote a small editor plugin (`ItrShowcaseEditor`, in the showcase repo) that builds a blueprint asset
from a JSON spec: components, variables, event-graph nodes and the links between them. It compiles and saves it and
prints the compiler messages and the bytecode size of each function. Python calls it with
`unreal.ItrShowcaseBPGen.generate_blueprint_from_spec(path)`, and regenerating an existing one rebuilds it in place so
placed instances keep working. Pins are looked up by name, any K2 node class can be named, and latent calls like `Delay`
work.

Status: three blueprints (a teleport pad, a light event and a light follower) compile with 0 errors and 0 warnings and
cook with `-unversioned` with imports from `/Script/Engine`, `CoreUObject` and `NavigationSystem` only (plus an engine
basic-shape mesh that's in the game too). Four pads are placed in the showcase map, each sending you back to its start
area. **Nobody has run any of it in the game**, so whether those unversioned engine imports resolve at load is exactly
what's untested. Lights in the generated blueprints need to be Movable.

## Navmesh for stuff you can't bake in the editor (desktop)
The game's navmesh is set to `DynamicModifiersOnly`. We tried two things at runtime:
- **Generating navmesh at runtime didn't work.** We switched `RecastNavMesh-Default` to Dynamic, added a
  `NavMeshBoundsVolume` at runtime and repopulated the navigation octree, and got no tiles. Worse, if
  `bFixedTilePoolSize` isn't set, any change to the bounds makes the engine rebuild the whole navmesh from scratch,
  and you lose the Hub's navmesh too. Don't do this.
- **Adding pre-baked tiles to `L_Common`'s navmesh worked.** You can take Recast tiles from another bake, shift them
  by whole 10 m tiles, and append them to the navmesh saved in 2.7.2's `L_Common`, using tile ref 0 (the next free
  slot; the pool has 641,960 slots and about 40,000 are used). Then you put the modified `L_Common` in a pak by itself. We did
  this for ITR 1.0's map. The catch is that your pak replaces `L_Common`, so two mods doing this would clash. For new
  maps, just bake the navmesh into the map ([`guide.md`](guide.md) §4).

## AI cover data (offline only: the data, a generator and a placed loader; no mimic has used it yet)
Mimics take cover using `ACoverLoader` actors. What we found by reading cooked data and the exe:
- Each zone has exactly one loader, in its **persistent** level (the Hub has none). It holds `CoverSettings`,
  `CoverPoints` and `ShootingPositions`. The two arrays are plain `TArray<FVector>` in world-space cm and nothing else:
  no facing, no navmesh references, no IDs. So nothing ties the data to a level and it can be generated offline.
- `CoverSettings` is the same in every zone: `CoverPointMinDistance 120`, `CoverPointGroundOffset 50`,
  `DistanceToCoverObject 100`, `ShootingPositionOffset 100`, `MinCoverWidth 40`, `OpenPointsGridCellSize 700`,
  `bAddCoversToFreePoints true`.
- A cover point is a navmesh spot about 1 m from the side of something solid at least 40 cm wide (a thin tree trunk
  counts), at ground level + 50 cm, never closer than 120 cm to another. `ShootingPositions` is three things merged:
  every cover point raised 2 cm, a 700 cm grid of open points across the whole walkable area, and side-step points
  10 to 180 cm from a cover point. The numbers are 3,900 to 18,700 cover points and 14,700 to 45,200 shooting positions
  per zone.
- The shipping exe has the query side (`UCoverRuntimeDataHolder`, `UNpcPointQueryManager::FindCoverPoint`, the
  `FindCoverBTTask` nodes in the Mimic behaviour trees) but **no generator**: no strings for one. We think it's
  editor-only, so you have to write your own.

Our generator (`cover_gen.py`, in the showcase repo) works offline from the placed obstacles plus the terrain, in about a
second, and gave 5,750 cover points and 53,177 shooting positions for the showcase blockout (3 to 10 times sparser
than the real zones, because a blockout has few things to hide behind). With 50,000 forest trees added as obstacles it
makes 41,306 and 157,110, which is nearer the zones. A loader with those arrays is placed in the showcase map in the
editor. We placed it through a blueprint subclass because spawning the native class crashed our headless editor. The
class's properties are editable in the SDK's module, and tagged serialisation matches them by name and type.

What we don't know, and why it's still "unproven":
- How `UCoverRuntimeDataHolder` finds a loader. It clears per level (a binding to `OnLevelUnloaded`), and the loader
  probably registers from `BeginPlay` or `OnLevelStarted`. If it's `OnLevelStarted`, a streamed map has missed it, and
  the fix would be a blueprint subclass of the loader whose `BeginPlay` calls `OnLevelStarted(Level.Hub)`, or calling it
  from your activation pass (above).
- Whether the points are good enough. The test is that a Mimic's `CoverLocation` blackboard value lands on one of our
  points, against a control with no loader. Not run.
- `SmallestAgentHeight` is never written in the game's data, so we left it at its default.

## Loading paks at runtime (not done)
Right now you have to restart the game every time a pak changes. Mounting paks at runtime
(`FCoreDelegates::MountPak`, found by signature) is something nobody's tried yet as far as we know.

## Saves (not done)
Save data is keyed by `"<Level>><Actor>"` names, so anything spawned at runtime can't be saved. Editor-placed actors
have stable names (guide §4), but we haven't checked that those keys behave for a level streamed in as a dynamic
instance, or what the tide does to your placed spawners and loot (the game kills and re-prepares the actors of levels
flagged to reload on the tide, and a streamed map keeps the Hub's level tag, so the Hub's flags apply). Both unknown.
Autosave keeps going while you're on a custom map, so back up your save while you're testing.

## Things from the ITR 1.0 port (not needed for normal maps)
- **Using another engine's compiled materials.** We got shaders compiled by a different engine build (1.0's UE 4.26)
  to render by rewriting their DXBC bytecode to match 2.7.2's layouts: constant-buffer offsets, the GPUScene stride and
  matrix packing, and resource slots. It works in VR for the whole 1.0 map. You'd only need this to port cooked
  content.
- **Streaming in a whole other world.** We stream 1.0's 45 levels in 10 km away from the 2.7.2 world (offset (0, −1e6,
  0) cm), with the level radius limits lifted, the sky boxes hidden and a few distance cvars changed.

## Other things that tripped us up
- If you stop a background test script by killing its shell, a child process can survive and keep relaunching the
  game.
- After a crash, `CrashReportClient.exe` keeps the mod DLLs locked. Close it before you copy new ones in.
- The editor starts SteamVR through its SteamVR plugin. Close it before testing with a different VR setup.
