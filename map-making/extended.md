# Making maps for Into the Radius 1 (2.7.2): extra things a mod can do

This goes with [`guide.md`](guide.md), which covers building and loading a map. This page is about things that need
a mod running code inside the game: spawning stuff, enemies, lighting and so on. For each one we've written down how
we did it and how far we tested it.

We did all of this with our own C++ mod, which we're not releasing. The idea is that anyone can rebuild the bits they
want in whatever framework they like, as long as it can call engine functions (UFunctions) on the game thread.

When we say **VR** we tested it in the headset. **Desktop** means we ran the game with `-nohmd` and checked that it
loaded, didn't crash and logged the right things. **Untested** means just that.

## How our mod hooks in
- A proxy `XINPUT1_3.dll` sits next to `IntoTheRadius-Win64-Shipping.exe` and loads our DLLs. The game imports
  `XINPUT1_3.dll` directly (ordinals 2 and 3). Don't put a proxy next to `IntoTheRadius.exe` in the game folder,
  because that's only a launcher and the proxy never reaches the game.
- We generated a C++ SDK with Dumper-7. Our code runs on the game thread from a `ProcessEvent` hook, about 20 times a
  second.
- A UE4SS Lua mod can do most of this too, since nearly all of it is UFunction calls. Our map loader is a UE4SS
  script and works in VR ([`loader-ue4ss/`](../loader-ue4ss/)). Watch out for functions with non-struct
  out-parameters though, UE4SS 3.0.1 gets the arguments after them wrong.

## Getting the player onto the map (VR)
Stream the level in at zero offset with `ULevelStreamingDynamic::LoadLevelInstance`, then `K2_TeleportTo` the player
pawn to a tagged `TargetPoint`. Do it from the Hub. From the main menu the teleport says it worked, but the VR player
stays where they are. The game has `IPRPlayerCharacter::TeleportPlayer`, but it's a native event with no UFunction
on the player class, and calling it through a generated interface wrapper crashes on a null pointer. The full recipe
is in [`guide.md`](guide.md) §6, and the UE4SS version is in [`loader-ue4ss/`](../loader-ue4ss/).

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

Honestly this is a stop-gap. If placing the game's blueprints in the editor works (see [`guide.md`](guide.md) §4,
untested so far), it'd make this unnecessary for spawners, stashes and loot.

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

## Lighting, fog and exposure (VR)
Custom maps stream into the Hub, so the Hub's sun, sky light, post-process volumes and height fog all affect your map
too. A mod can hide the Hub's lights (`SetVisibility(false)`), switch off its post-process volumes (`bEnabled = 0`),
scale every `ExponentialHeightFogComponent`'s density, and put it all back when the map unloads.

Maps with baked lighting also need the Hub's lighting-scenario level hidden (see [`guide.md`](guide.md) §7).

You can also drive a level's directional light, sky light and fog from curves at runtime for a day/night cycle. We
did this in VR to bring back ITR 1.0's own day/night and fog weather, using 1.0's curve assets. Changing intensity and
colour doesn't need a sky recapture.

One thing that bit us: if you load a `USoundBase` (or anything else) with `LoadAsset_Blocking` and only keep it in a
C++ pointer, the garbage collector frees it and the next time you use it the game crashes. Keep a proper reference,
or just load it again each time.

## Swapping materials by role (VR, but you probably don't need it)
Meshes tagged `mat:<role>` get one of the game's material instances assigned at runtime with `SetMaterial`. We used
this before we had the special editor. Now maps can use their own materials, or reference the game's in the editor.

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

## AI cover data (not done)
Mimics take cover using `ACoverLoader` actors, which hold baked `CoverPoints` and `ShootingPositions` for each level.
A mod would have to spawn one and fill in those arrays from points worked out offline. That needs the engine's
allocator (`FMemory::Malloc`, found by signature scanning). We don't know how `UCoverRuntimeDataHolder` picks up
loaders, or whether the game's cover generator is even in the shipping exe.

## Loading paks at runtime (not done)
Right now you have to restart the game every time a pak changes. Mounting paks at runtime
(`FCoreDelegates::MountPak`, found by signature) is something nobody's tried yet as far as we know.

## Saves (not done)
Save data is keyed by `"<Level>><Actor>"` names, so anything spawned at runtime can't be saved. Autosave keeps going
while you're on a custom map, so back up your save while you're testing.

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
