# Making maps for Into the Radius 1 (2.7.2)

This guide takes you from nothing to walking around your own map in the game. Everything it refers to is in this
repository (links below), except things others published (the ITR-SDK, UE4SS) and Unreal Engine itself.

What a mod running code in the game can add on top (spawning content, AI cover, lighting control) is in
[`extended.md`](extended.md).

**Status labels:** *tested* = done in the game by us; *untested* = written, never run; *unexplored* = nobody has tried.

## 0. Which route do you need?
| You want to | You need |
|---|---|
| A map built from the game's own meshes and materials (and Unreal's basic shapes) | **Route A:** stock Unreal Engine 4.27.2 from the Epic launcher |
| Anything with **new shaders**: your own materials, material instances with static switches or overridden base properties, a landscape | **Route B:** the special editor (§3): Meta's Oculus fork of UE 4.27 plus our layout patch |

**Why route B exists.** Weapon and prop mods work in stock 4.27, so why not levels? Because those mods reuse the
game's **compiled shaders** (they use the game's materials), and so can a level. A **new** shader is compiled by your
editor, and it reads its inputs (camera, object position, lighting) from memory blocks ("uniform buffers") at byte
offsets fixed when the engine was built. The game's engine is Meta's Oculus fork of UE 4.27 **plus changes by the
ITR developers**. We read the real layouts out of the game's exe and compared them:
- stock 4.27.2 differs in 9 of the blocks material shaders use, and stores per-object data with a different stride
  (36 vs 33 slots);
- the unmodified Oculus fork fixes the VR stereo layout but not the developers' changes.

A shader compiled against the wrong layout reads the wrong memory. The game crashes on the render thread as soon as
it's on screen, or draws it black. Only route B compiles shaders the game can use.

Doesn't compile shaders (route A is enough):
- meshes, textures, sounds, blueprints;
- **plain** instances of the game's materials that only change parameters.

Compiles shaders (route B):
- new material graphs, even a plain colour;
- instances with static switches or overrides;
- landscapes (every landscape component gets its own instance);
- probably also particle, decal and post-process materials of your own *(untested)*.

## 1. What you need
| Item | Where |
|---|---|
| Into the Radius 1, **2.7.2**, PC VR | Steam. `extract-game-config.ps1` (step 2.2) prints the version |
| Unreal Engine 4.27.2 (route A) | Epic Games launcher |
| The special editor (route B) | Build it yourself (§3) |
| Python 3 | For the scripts in this repository |
| The **ITR-SDK** (by ChuckSharts, Dec 2023) | Editor-format copies of the game's assets, to reference by path. Download link in Pecho's Mods "The Basics" guide (pechomods.com); at the time of writing: https://drive.google.com/file/d/1yPFEPYuxcBEV3NKYOZnAxRIyEIQFFygn/view . Only needed to use game materials, meshes or prefabs in your map. **Its master materials are reconstructions, not the game's graphs**: reference them, never cook your own copy |
| A loader for the map | The game can't enter custom maps by itself yet. UE4SS (Nexus Mods, "UE4SS for Into the Radius") plus our script: §6 |

## 2. Set up the project (both routes)
1. Copy [`example-map/`](../example-map/) somewhere. It's a blueprint-only project named `IntoTheRadius`. The name
   matters: `/Game/...` paths must match the game's.
2. Get the game's `DefaultEngine.ini` (render settings, navmesh agents, collision channels). It's inside the game's
   `pakchunk0`:
   ```powershell
   .\extract-game-config.ps1 -Engine "C:\Program Files\Epic Games\UE_4.27\Engine"   # or your special editor's Engine folder
   ```
   It runs `UnrealPak.exe <game>\IntoTheRadius\Content\Paks\pakchunk0-WindowsNoEditor.pak -Extract <tmp>
   "-Filter=*Config/Default*.ini"` and copies `DefaultEngine.ini` into `Config\`. Warnings about missing game classes
   when the editor starts are harmless.
3. `Config\DefaultGame.ini` (included) matches the game's packaging: `bShareMaterialShaderCode=False`,
   `bUseIoStore=False`.
4. Open `IntoTheRadius.uproject` with your editor (route B: right-click → Switch Unreal Engine version → your build).

## 3. Route B: build the special editor
**Access.** The fork lives on `github.com/Oculus-VR/UnrealEngine`, which is visible only to GitHub accounts linked to
an Epic Games account (Unreal source access: unrealengine.com → account → Apps and Accounts → GitHub, then accept
the invitation to the EpicGames organisation). We're not sure a Meta developer account is also needed. Without
access the links return 404.
- Release: https://github.com/Oculus-VR/UnrealEngine/releases/tag/oculus-4.27.1-release-1.67.0-v35.0
- Dependency fix branch: https://github.com/Oculus-VR/UnrealEngine/tree/4.27-gitdeps-fix

**Toolchain.** The **Visual Studio 2019 compiler (MSVC v142, 14.29)**: VS 2022's own v143 compiler doesn't build
this engine. Either install VS 2019, or VS 2022 (Build Tools is enough) with the component "MSVC v142 – VS 2019 C++
x64/x86 build tools". Also needed: Windows 10 SDK 10.0.19041, .NET Framework 4.6.2 targeting pack, Python 3, about
150 GB of disk, and a few hours.

**Files from this repository:** [`tools/merge_gitdeps.py`](../tools/merge_gitdeps.py),
[`tools/hashpatch.py`](../tools/hashpatch.py), [`engine/itr-ub-layouts.hashpatch.json`](../engine/itr-ub-layouts.hashpatch.json).

```bat
:: 1. Source at the exact release tag. Keep the path short: UnrealBuildTool fails on paths over 260 characters.
git clone --branch oculus-4.27.1-release-1.67.0-v35.0 --depth 1 https://github.com/Oculus-VR/UnrealEngine.git C:\ue427
cd /d C:\ue427

:: 2. Dependencies. The tag's Engine\Build\Commit.gitdeps.xml points at download packs Epic no longer hosts
::    (Setup.bat fails with HTTP 403). merge_gitdeps.py keeps the tag's exact file versions and takes the working
::    download locations from branch 4.27-gitdeps-fix.
git fetch --depth 1 origin 4.27-gitdeps-fix
git show FETCH_HEAD:Engine/Build/Commit.gitdeps.xml > Commit.gitdeps.fix.xml
copy Engine\Build\Commit.gitdeps.xml Engine\Build\Commit.gitdeps.v35-original.xml
python <itr-common>\tools\merge_gitdeps.py Engine\Build\Commit.gitdeps.v35-original.xml Commit.gitdeps.fix.xml Engine\Build\Commit.gitdeps.xml

:: 3. The ITR layout patch (checks every file first, refuses to apply twice)
python <itr-common>\tools\hashpatch.py apply <itr-common>\engine\itr-ub-layouts.hashpatch.json C:\ue427

:: 4. Build
Setup.bat
GenerateProjectFiles.bat
Engine\Build\BatchFiles\Build.bat UE4Editor Win64 Development -WaitMutex
Engine\Build\BatchFiles\Build.bat ShaderCompileWorker Win64 Development -WaitMutex
Engine\Build\BatchFiles\Build.bat UnrealPak Win64 Development -WaitMutex
```
Expected merge result: 63,981 files kept at their 4.27.1 versions, 146 taken from later 4.27 (localization, a few media
DLLs and plugin assets no longer hosted), 142 non-build files dropped (CI configs, Dockerfiles, `.ps1`).

| Check (SHA-256) | Value |
|---|---|
| Tag's original `Commit.gitdeps.xml` | `9f429c5e93111d0992e2dfa1504e5037338d8b0d3546003101755c0dbcc23ee8` |
| `4.27-gitdeps-fix` manifest as we downloaded it (October 2026; the branch may move) | `bff2b4b6a4f008bf5dcf1f824b05ffd9dd1115da96e74c32395bcb6a393e123f` |
| Merged manifest | `b11e88d7ee76037e709d9d6f6977c96236efaa96f3021475a0f4068cd627e9c9` |

**Why the patch is a "hashpatch".** Our changes touch Epic engine source, and the Unreal Engine EULA restricts sharing
engine code:
- to other licensees: allowed;
- publicly: only through a fork in Epic's GitHub network;
- snippets up to 30 lines: allowed, for discussion or "in connection with supporting patches and plug-ins".

So the patch contains **no original engine lines**. It names each line it replaces by line number and SHA-256, and
each line it moves by a reference into your own copy of the source. Only the lines we wrote are carried as text.
`hashpatch.py apply` rebuilds the change from your checkout; we verified that the result is identical to our patched
tree. (Our reading of the EULA, not legal advice.)

**What the patch changes** (20 files):
- the `View` / `InstancedView` buffers: 5 `Prev*` matrices removed, contact-shadow members added;
- `Primitive`: spherical-harmonic lighting moved in from `IndirectLightingCache`, 5 custom-data slots;
- the shared base pass (stereo screen-space reflections) and scene textures;
- the per-object (GPUScene) stride, 33, and its packing of 3 float4s per matrix. Without that, materials render black.

Plus one editor-scripting helper, `MaterialEditingLibrary.SetMaterialInstanceStaticSwitchParameterValue`, which the
game doesn't need.

**Verify your build** (recommended before you make anything): compare the uniform buffers your editor compiles with
the game's. Needs `pip install pefile capstone`.
```bat
cd <itr-common>\tools
for %d in (Engine Renderer RenderCore Landscape) do python ub_extract_exe.py C:\ue427\Engine\Binaries\Win64\UE4Editor-%d.dll --dump my_%d.json
python ub_material_diff.py ..\data\ub\game-2.7.2.json my_Engine.json my_Renderer.json my_RenderCore.json my_Landscape.json
```
A correct build prints `IDENTICAL` for 24 buffers. `TranslucentDepthPass: missing in game` is expected; the game exe
has no separate copy of it. [`data/ub/game-2.7.2.json`](../data/ub/game-2.7.2.json) is the game's layout table,
recovered from `IntoTheRadius-Win64-Shipping.exe` with `ub_extract_exe.py`. Re-run that tool on a new game version to
see whether the layouts changed. `shadermap_dump.py` and `dxbc_disasm.py` inspect compiled shaders in cooked
packages.

**Materials you make with it:** tick **Used with Static Lighting** and **Used with Instanced Static Meshes**.
Without them the cook leaves out shader variants the game asks for, and the mesh draws with the default material.
- *Tested:* opaque materials.
- *Untested:* translucent, masked foliage, decals, landscape materials.

## 4. Build the map
The worked example: in the editor, **File → Execute Python Script →
[`example-map/Scripts/build_example.py`](../example-map/Scripts/build_example.py)**. It creates the two levels below,
places everything described in this section, and creates the material `M_ExampleGrid`. That material is compiled by
your editor, so it's the proof that route B works: the floor's checker renders in the game. Then build the navmesh
(below). Read the script alongside this section; it's short. The example's
[README](../example-map/README.md) has the exact commands, including headless ones.

| Topic | Rule |
|---|---|
| Location | `/Game/Mods/<Name>/L_<Name>`. Sublevels of it are fine |
| World position | Build the map **where it will be in the game**, clear of the game's own navmesh volumes (X −435,000…698,000, Y −219,000…646,000 cm). The example uses origin (0, −600,000, 0) cm. The loader streams the map at zero offset because navmesh tiles are stored in absolute coordinates |
| Player start and exit | A `TargetPoint` tagged `itr:player_start` (Details → Actor → Tags), and one tagged `itr:exit` with something visible on it: stepping there takes the player back to the Hub (§6) |
| Sky | The game turns sky atmosphere off (`r.SupportSkyAtmosphere=False`). Use the engine's sky dome: mesh `/Engine/EngineSky/SM_SkySphere`, material `/Engine/EngineSky/M_Sky_Panning_Clouds2`. Both are engine content (in every editor, under Engine Content) and ship with the game. Turn collision and shadows off |
| Lighting | Movable lights work. Exposure is in EV100 (auto exposure off). Seen from the Hub, about a 2-lux sun and a 0.6 sky light look normal. Baked (static) lighting: §7 |
| Fog | Height fog is global: the Hub's fog also covers your map |
| Game materials and meshes (from the ITR-SDK) | Copy each asset, with what it references, from the SDK's `Content` into your project's `Content` **at the same path**. Assign or place it, and pack only `/Game/Mods/<Name>`. In the game, the game's own cooked copies load. Plain material instances only (§0). *Tested:* static meshes, foliage meshes, `Prefab_Zone_*` blueprints (built from engine components). Placed meshes are part of your navmesh |
| Gameplay blueprints (spawners, stashes, loot points, items) | Their C++ parents are in the game's `IntoTheRadius` code module, which a blueprint-only project can't load. The ITR-SDK includes a recreation of that module (`Source/IntoTheRadius`, built for stock 4.27). Building it into your project should let you place the SDK's gameplay blueprints (and, being placed, they get stable names, which the save system needs) — *untested*. Until then, [`extended.md`](extended.md) describes spawning them at runtime |

### Navmesh (*tested*)
NPCs walk only on navmesh, and the game never generates navmesh at runtime (`RuntimeGeneration=DynamicModifiersOnly`).
Bake it into your map:
- **How the game does it:** the whole navmesh is baked into the always-loaded level `L_Common`, as two navmeshes:
  `RecastNavMesh-Default` and `RecastNavMesh-Big`. Their agents are defined in `DefaultEngine.ini`, which you copied,
  so your editor uses the same settings: Default radius 20, height 140, step 40; Big radius 400, height 200; cell
  size 20, 10 m tiles.
- **How a custom map does it:** a streamed level can carry navmesh tiles. When it streams in, they join the
  persistent level's navmesh **of the same name**. `L_Common` only exists cooked (the SDK's copy too), so the editor
  can't open it. Instead, the example uses a small editor-only **host** level, `L_ExampleHost`, as a stand-in: the
  map is its sublevel, and the host's navmesh actors get the game's names.
- **The catch:** the game's `DefaultEngine.ini` has `bAutoCreateNavigationData=False`, so with it the editor
  creates no navmesh actors and Build Paths does nothing. For the editor session, turn auto-create on and
  re-register the bounds volumes; the editor then creates `RecastNavMesh-Default` and `RecastNavMesh-Big`.
  [`build_navmesh.py`](../example-map/Scripts/build_navmesh.py) does this, builds, waits, and saves.
- **Steps:**
  1. With your map's `NavMeshBoundsVolume` in place, run `build_navmesh.py` in the editor (File → Execute Python
     Script). By hand, the same steps are:
     - open the host level;
     - in the Python console, `nav = unreal.NavigationSystemV1.get_navigation_system(unreal.EditorLevelLibrary.get_editor_world())`,
       then `nav.set_editor_property("auto_create_navigation_data", True)`, then `nav.on_navigation_bounds_updated(<volume>)`;
     - Build → Build Paths;
     - File → Save All.
  2. The tiles are saved into your map; the host level only holds the navmesh actors. Don't pack the host level
     (`build-map.ps1` skips `L_*Host`).
- Must run in the editor: a commandlet (`-run=ResavePackages -BuildNavigationData`) didn't save tiles into the
  sublevel in our test. For an unattended run, start the editor with `"-ExecCmds=py <script>"`, not
  `-ExecutePythonScript=` (that closes the editor as soon as the script returns, before the build).

## 5. Cook, pack, install
```powershell
.\build-map.ps1 -Engine "C:\ue427\Engine" -Map Example -Install
```
[`example-map/build-map.ps1`](../example-map/build-map.ps1) does the following:
1. Cook: `UE4Editor-Cmd.exe IntoTheRadius.uproject -run=cook -targetplatform=WindowsNoEditor
   -map=/Game/Mods/<Name>/L_<Name> -unversioned` (`-unversioned`: the game's own packages are unversioned).
2. Response file: one line per cooked file, `"<file on disk>" "<path inside the game>"`. **Only** files under
   `Saved/Cooked/WindowsNoEditor/IntoTheRadius/Content/Mods/<Name>/`. Anything else in the cook output (engine
   content, SDK copies) would replace the game's own files. Example line:
   `"C:\...\Saved\Cooked\WindowsNoEditor\IntoTheRadius\Content\Mods\Example\L_Example.umap" "../../../IntoTheRadius/Content/Mods/Example/L_Example.umap"`
3. `UnrealPak.exe zzz_ITRMap_<Name>_P.pak -create=<response file>`. The game loads unsigned paks (it ships no `.sig`
   files). The `_P` suffix makes it a patch pak, mounted after the game's own.
4. Copy the pak to `<game>\IntoTheRadius\Content\Paks\`. Restart the game after every change.

*Tested with the example (October 2026), special editor:*
- **Build:** map generated headless, navmesh built by `build_navmesh.py`, cook and pack in 13 s; the pak holds
  the map and the material (30 compiled shaders).
- **In the game (VR, loaded by the UE4SS loader from the Hub):** the checker floor renders correctly, the player
  starts at the marker, and enemies spawned on the map stand on its navmesh.

The result is [`example-map/prebuilt/zzz_ITRMap_Example_P.pak`](../example-map/prebuilt/).

Pitfalls:
- After an engine or shader change, delete `Saved/Cooked` first: `-iterate` cooks don't notice.
- Once, in the special editor, a script changed a material's usage flags while the open level drew it, and the
  editor hit a render-thread assertion. Seen once, not investigated.

## 6. Entering the map: the loader
The game's level list, gates and map screen don't know custom maps, so something has to stream the map in. That's
the only code a native map needs.
- **UE4SS script (*tested*, VR and desktop):** [`loader-ue4ss/`](../loader-ue4ss/). It loads automatically each time
  the Hub appears (for VR) or on a key. Its README has the install steps. Two of them differ from what the UE4SS zip
  suggests: don't copy `override.txt`, and rename `ue4ss\Mods` to `ue4ss\LuaMods`.
- **What any loader must do** (all blueprint-callable engine functions):
  1. In the Hub (not the main menu: there the teleport reports success but the VR player doesn't move), call
     `LevelStreamingDynamic::LoadLevelInstance(World, "/Game/Mods/<Name>/L_<Name>", (0,0,0), (0,0,0), bSuccess)`.
     UE4SS 3.0.1 Lua can't make this call (an out-parameter bug). The script instead does what it does internally:
     - `LevelStreaming::CreateInstance(<unique name>)` on an existing dynamic streaming entry;
     - set `PackageNameToLoad` to your map's package;
     - set `LevelTransform` to identity;
     - `SetShouldBeLoaded(true)` and `SetShouldBeVisible(true)`.
  2. When the streaming level reports `IsLevelVisible()`, find the `TargetPoint` tagged `itr:player_start` in its
     loaded level and call `K2_TeleportTo` on the player pawn. (The game's own `TeleportPlayer` event can't be
     called this way.)
  3. Baked lighting only: hide the Hub's lighting-scenario level (§7).
  4. A way out: the script remembers where the player stood and, when they step within 1.5 m of a `TargetPoint`
     tagged `itr:exit` (or press the key), teleports them back there, then unloads. **Put an exit marker in every
     map**: in VR there's no other way back short of quitting to the menu.
  5. To unload: `SetShouldBeVisible(false)` and `SetShouldBeLoaded(false)` on the streaming level, after moving the
     player off it.
- "In the Hub" needs care: during the transition from the menu, the Hub level is already visible while the player is
  still in the menu room. The script also waits for `LevelManager::IsReady()`, on two checks 2 s apart.

## 7. What works, what doesn't
| Feature | State |
|---|---|
| Geometry, collision, game meshes and plain game materials | Works (route A or B) |
| Your own materials | Works with route B (opaque tested) |
| Landscape of your own | Untested (route B) |
| Movable lights, sky dome, post-process volumes | Works. Fog is shared with the Hub |
| Baked lighting | Loads (tested with a rebuilt level). The loader must hide the Hub's lighting-scenario level: while that level is visible, the engine reads every level's lightmaps from it. Find it in `World.StreamingLevels` (its loaded level has `bIsLightingScenario` set), `SetShouldBeVisible(false)`, restore on unload. Quality not yet judged |
| Navmesh | Works (§4) |
| Placed gameplay blueprints | Untested (§4) |
| Entering the map | Needs a loader (§6) |
| Gates and travel, map screen, missions, loot tables, saves | Not available. These are per-zone data assets (`DA_SystemConfig.LevelConfigurations`, `DA_MapPointsConfig`, `/Game/ITR/Configurations/Missions`, `/Game/ITR/Configurations/Loot/<Zone>`). Registering a map there (a level config entry, streaming entry, gates, map points) could let the game load it like any zone, with saves and travel; it means overriding the game's data assets. Unexplored |
| AI cover (mimics taking cover) | Not available. Zones carry baked cover data; how the game generates it is unknown |

## 8. Troubleshooting
- Crash reports: `%LOCALAPPDATA%\IntoTheRadius\Saved\Crashes\` (`CrashContext.runtime-xml`, minidump). The shipping
  game writes no log.
- Render-thread crash or black surfaces as soon as the map is in view: a shader compiled by the wrong engine (§0).
- "Serialization Error: Corrupt data found": a package cooked by a different engine version.
- The loader says the level failed to load: the pak isn't in `Content\Paks`, the name lacks `_P`, or the path is
  wrong (`/Game/Mods/<Name>/L_<Name>`, no extension).
- The game hangs at startup with UE4SS installed (no window, about 12 MB of memory): `override.txt` was copied. A
  hidden "UE4SS Error: Failed to load UE4SS.dll" box is waiting. Delete `override.txt` and keep `ue4ss\` next to the
  exe ([loader README](../loader-ue4ss/README.md)).
- UE4SS runs but the loader never logs: `ue4ss\Mods` wasn't renamed to `ue4ss\LuaMods`.

### Pitfalls we hit (and how the scripts avoid them)
| Symptom | Cause | Fix |
|---|---|---|
| Python script works in the editor, but headless (`-run=pythonscript`) fails with "could not be found in the Content Browser" | `EditorAssetLibrary.load_asset` looks assets up in the asset registry, which a commandlet hasn't scanned | Use `unreal.load_asset(path)` (loads by path) |
| Build Paths creates no `RecastNavMesh` actors | The game's `DefaultEngine.ini` sets `bAutoCreateNavigationData=False` | Turn it on for the session and call `on_navigation_bounds_updated` for each volume (`build_navmesh.py`) |
| Navmesh tiles missing from the map after a headless build | `-run=ResavePackages -BuildNavigationData` builds, but doesn't save tiles into the sublevel | Build in the editor (it can be started unattended, next row) |
| Editor started with `-ExecutePythonScript=` closes before the build | That switch (Editor Scripting Utilities) quits as soon as the script returns | Use `"-ExecCmds=py <script>"`; the script quits itself when done |
| Every material on our map renders black | GPUScene matrix packing differs from the game's | The layout patch (§3) |
| A material of ours renders with the default material | The cook left out the static-lighting variants the game draws with | Tick Used with Static Lighting and Used with Instanced Static Meshes |
| `/Game/...` arguments turn into `C:/Program Files/Git/Game/...` | Git Bash rewrites arguments that look like paths | Run from PowerShell or cmd, or set `MSYS_NO_PATHCONV=1` |
| UnrealBuildTool stops with exit code 6 | Output paths over 260 characters | Keep the engine at a short path (`C:\ue427`) |
| The editor starts SteamVR | Its SteamVR plugin | Close SteamVR before testing with another VR setup, or add `-nohmd` to unattended runs |
| A crashed game keeps mod DLLs locked | `CrashReportClient.exe` holds them | Close it before copying files |
| UE4SS: `StrProperty can only be set to a string or FString` | UE4SS 3.0.1 mis-reads the argument after a non-struct out-parameter | Avoid such functions; the loader uses `CreateInstance` instead of `LoadLevelInstance` |
| Map loads too early, while the player is still in the menu room | The Hub level is visible during the transition | Wait for `LevelManager::IsReady()` (the loader does) |

## Repository map
| Path | What |
|---|---|
| [`example-map/`](../example-map/) | Project skeleton, map and navmesh scripts, config extraction, cook/pack script, prebuilt pak |
| [`loader-ue4ss/`](../loader-ue4ss/) | UE4SS loader (tested) |
| [`engine/`](../engine/) | The layout patch (hashpatch format) |
| [`tools/`](../tools/) | `merge_gitdeps.py`, `hashpatch.py`, layout and shader inspection tools |
| [`data/ub/`](../data/ub/) | The game's uniform-buffer layouts (from the 2.7.2 exe) |
| [`extended.md`](extended.md) | What a runtime mod adds |
