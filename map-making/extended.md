# Making maps for Into the Radius 1 (2.7.2): what a runtime mod adds

Companion to [`guide.md`](guide.md) (the native route: building, the special editor,
navmesh, packing, the loader). This document covers features that need **a mod running code in the game**, how each
was done, and how far it was validated. Our own mod isn't distributed. The descriptions are meant to let anyone
rebuild the parts they need, in any framework that can call engine functions (UFunctions) from a game-thread hook.

Validation levels: **VR** = tested in the headset; **desktop** = tested with `-nohmd` (loads, no crash, logged
results); **untested**.

## How our mod hooks the game (context)
- A proxy `XINPUT1_3.dll` next to `IntoTheRadius-Win64-Shipping.exe` (statically imported, ordinals 2 and 3) loads mod DLLs.
  `IntoTheRadius.exe` in the game root is only a launcher, so a proxy beside it never reaches the game.
- C++ SDK generated with Dumper-7. Code runs on the game thread from a `ProcessEvent` hook, throttled to 20 Hz.
- A UE4SS Lua mod could probably do most of the following, since almost everything is a UFunction call. **UE4SS on
  this game is untested.**

## Features
### Loading and placing the player — VR
`ULevelStreamingDynamic::LoadLevelInstance` at zero offset, then `K2_TeleportTo` on the player pawn to a tagged
`TargetPoint`. Load from the Hub: from the main menu the teleport "succeeds" but the VR player doesn't move. The
game's `IPRPlayerCharacter::TeleportPlayer` is a native event without a UFunction on the player class; calling it
through a generated interface wrapper dereferences null. A full loader recipe is in [`guide.md`](guide.md) §6; a UE4SS version (untested) is in [`loader-ue4ss/`](../loader-ue4ss/).

### Content from markers — desktop (items, stash, loot point, prefabs, trees)
`TargetPoint` tagged `spawn:<asset path>`. On load the mod resolves the asset with
`UKismetSystemLibrary::LoadAsset_Blocking`:
- a blueprint (`<path>.<Name>_C`) is spawned with `UGameplayStatics::BeginDeferredActorSpawnFromClass` +
  `FinishSpawningActor` at the marker transform;
- a static mesh becomes a `StaticMeshActor` with that mesh.

Spawned actors are destroyed on unload.

Limits:
- not part of the navmesh (NPCs walk through them);
- construction-only setup is lost;
- no stable save identity;
- loot from `BP_LootSpawnPoint` outside a zone is untested.

**This is a stop-gap.** Placing the game's blueprints natively ([`guide.md`](guide.md) §4, untested) would make it redundant for
spawners, stashes and loot.

Gotcha: in Dumper-7 SDKs `FName::ToString()` returns only the text after the last `/`. Use the raw string for tags
that hold paths.

### Enemies — VR (patrol, chase, sound lure on a custom map's navmesh); desktop (1.0 placements)
- **By gameplay tag:** `UInfosConfig::GetInfosConfig()->GetNPCClass(<tag>)` (e.g. `NPC.Monster.Mimic.AKM`) gives the
  class; spawn deferred, set `APRCharacter::IdleWalkRadius` before finishing.
- **By class path:** load `/Game/ITR/BPs/Chars/<Type>/BP_Char_<Type>.BP_Char_<Type>_C` directly. Fragment, transparent
  fragment, Shooter, Shooter_AK, Ring, Zombie and Harvester all ship in 2.7.2.
- **Placement:** project onto navmesh with `UNavigationSystemV1::K2_ProjectPointToNavigation` (extent 300, 300,
  1000), or fall back to `K2_GetRandomReachablePointInRadius`. Spawn 1 m above the projected point.
- **Squads:** call `AddSquadMember(Pawn)` on every member's AI controller for every other member, the way the game's
  `BP_CharSpawner` does.

Not done:
- registration with the save system;
- respawn timers;
- the game's own spawner actors (`BP_CharSpawner_C`) placed from markers.

### Lighting, fog and exposure of the host level — VR
Custom maps stream into the Hub, so the Hub's sun, sky light, post-process volumes and height fog also light your map.
A mod can:
- hide the host's lights (`SetVisibility(false)`);
- disable the host's post-process volumes (`bEnabled = 0`);
- scale every `ExponentialHeightFogComponent` density;
- restore all of it on unload.

Baked lighting additionally needs the Hub's lighting-scenario level hidden ([`guide.md`](guide.md) §7).

**Dynamic time of day:** a mod can drive a level's directional light, sky light and fog from curves at runtime. VR:
ITR 1.0's own day/night and fog weather was reproduced this way, from 1.0's curve assets. Setting intensity and colour
needs no sky recapture. Gotcha: keep a loaded `USoundBase` referenced (or reload it at each use). An object loaded with
`LoadAsset_Blocking` and only held in a C++ pointer is garbage-collected, and the next use crashes.

### Materials by role — VR (a stop-gap from before the special editor)
Meshes tagged `mat:<role>` get a game material instance assigned at runtime (`SetMaterial`). No longer needed: with
the special editor, maps ship their own materials or reference game instances in the editor.

### Navmesh for content you can't bake in the editor — desktop
The game's navmesh mode is `DynamicModifiersOnly`. Two runtime approaches were tried:
- **Runtime generation: failed.** Switching `RecastNavMesh-Default` to Dynamic, adding a `NavMeshBoundsVolume` at
  runtime and repopulating the navigation octree produced no tiles. Without `bFixedTilePoolSize` it also **destroys
  the whole loaded navmesh** (Hub included), because the engine recreates a resizable navmesh on any bounds change. Don't.
- **Appending baked tiles to `L_Common`'s navmesh: works.** Recast tiles from another bake can be shifted by whole
  tiles (10 m) and appended to the navmesh serialized in 2.7.2's `L_Common`, with tile ref 0 (next free slot; the
  pool has 641,960 slots, about 40,000 used). Then pack the modified `L_Common` alone. Used for ITR 1.0's map. Cost:
  your pak overrides `L_Common`, so two mods doing this conflict. For new maps, prefer baking tiles into the map itself
  ([`guide.md`](guide.md) §4).

### AI cover data — not done
Mimics use `ACoverLoader` actors (baked `CoverPoints` and `ShootingPositions`) per level. A mod would need to spawn one
and fill its arrays (that needs the engine allocator, `FMemory::Malloc`, located by signature), from points generated
offline. How `UCoverRuntimeDataHolder` picks up loaders, and whether the game's generator is in the shipping exe,
is unknown.

### Runtime pak mounting — not done
Every pak change needs a game restart. Mounting at runtime (`FCoreDelegates::MountPak`, found by signature) is unexplored.

### Saves — not done
Save data is keyed by `"<Level>><Actor>"` names, so runtime-spawned actors can't persist. Autosave keeps running on a
custom map: protect the player's save while testing.

## Techniques from the ITR 1.0 port (beyond normal map making)
- **Foreign compiled materials:** shaders compiled by another engine build (1.0's UE 4.26) were made to render by
  rewriting their DXBC bytecode to 2.7.2's layouts: constant-buffer offsets, the GPUScene stride and matrix packing,
  resource slots. Validated in VR for the whole 1.0 map. Specific to porting cooked content, not needed for new maps.
- **Streaming a foreign world:** 1.0's 45 levels are streamed 10 km from the 2.7.2 world (offset (0, −1e6, 0) cm),
  with level radius limits lifted, sky boxes hidden and distance cvars adjusted.

## Pitfalls collected
- Stopping a background test script by killing its shell can orphan a child process that keeps relaunching the game.
- A crashed game leaves `CrashReportClient.exe` holding mod DLLs open; close it before redeploying.
- The editor starts SteamVR (its SteamVR plugin). Close it before testing with a different VR setup.
