# Making maps for Into the Radius 1 (2.7.2)

This is how we got a custom map into ITR1 and walked around it in VR. Most of what you need is in this repo. The bits
that aren't are Unreal Engine itself, UE4SS, and the community ITR-SDK if you want to use the game's assets.

If you want to spawn things at runtime, mess with lighting from a mod and so on, that's in [`extended.md`](extended.md).

Where we say *tested* we've done it in game. *Untested* means written but never run, and *unexplored* means nobody
has tried it as far as we know.

## 0. Do you need the special editor?
Probably only if you want your own materials.

| You want | Use |
|---|---|
| A map made from the game's meshes and materials, plus Unreal's basic shapes | Route A: stock UE 4.27.2 from the Epic launcher |
| Your own materials, material instances with static switches or overridden base properties, or a landscape | Route B: the special editor (§3), which is Meta's Oculus fork of UE 4.27 with our layout patch on top |

So why do gun mods work fine in stock 4.27 when levels with custom materials don't? Gun mods reuse materials that
are already in the game, so they never compile a shader, and a level can do the same. Once you make a new material,
though, your editor compiles a shader for it. That shader reads things like the camera, the object's position and the
lighting from blocks of memory ("uniform buffers") laid out at fixed offsets, and those offsets are baked in when the
engine is built.

ITR runs on Meta's Oculus fork of UE 4.27, and the developers changed some of those layouts on top of that. We pulled
the real layouts out of the game's exe and compared:
- stock 4.27.2 is different in 9 of the buffers that material shaders use, and stores per-object data with a
  different stride (36 slots instead of 33);
- the plain Oculus fork gets the VR stereo layout right, but not the developers' changes.

A shader built against the wrong layout reads the wrong memory. In practice the game either crashes on the render
thread as soon as it's on screen, or draws it black.

Things that don't compile shaders, so route A is fine:
- meshes, textures, sounds, blueprints;
- plain instances of the game's materials where you only change parameters.

Things that do, so you need route B:
- any new material, even a flat colour;
- instances with static switches or overrides;
- landscapes (each landscape component gets its own material instance);
- probably particle, decal and post-process materials too, though we haven't tried those.

## 1. What you'll need
- Into the Radius 1 on PC VR, version **2.7.2**. The example's config script prints the version so you can check.
- Stock UE 4.27.2 (route A) or the special editor (route B, see §3).
- Python 3 for the scripts here.
- The **ITR-SDK** by ChuckSharts (Dec 2023), if you want the game's materials, meshes or prefabs in your map. It's
  linked from Pecho's Mods "The Basics" guide (pechomods.com). When we last looked, the link was
  https://drive.google.com/file/d/1yPFEPYuxcBEV3NKYOZnAxRIyEIQFFygn/view. One warning: its master materials are
  reconstructions, not the real graphs. Reference them, but don't cook your own copies.
- Something to load the map. The game can't enter custom maps yet, so we use UE4SS plus a small Lua script (§6).

## 2. Set up the project
1. Copy [`example-map/`](../example-map/) somewhere. It's a blueprint-only project called `IntoTheRadius`. Keep that
   name, since the `/Game/...` paths have to line up with the game's.
2. Grab the game's `DefaultEngine.ini`. It has the render settings, navmesh agents and collision channels, and it
   lives inside `pakchunk0`:
   ```powershell
   .\extract-game-config.ps1 -Engine "C:\Program Files\Epic Games\UE_4.27\Engine"   # or your special editor's Engine folder
   ```
   Under the hood that's just `UnrealPak.exe <pakchunk0> -Extract <tmp> "-Filter=*Config/Default*.ini"`. The editor
   will moan about missing game classes when it starts. You can ignore that.
3. `Config\DefaultGame.ini` is already set up like the game's packaging (`bShareMaterialShaderCode=False`,
   `bUseIoStore=False`).
4. Open `IntoTheRadius.uproject`. For route B, right-click it first and switch the engine version to your build.

## 3. Route B: building the special editor
**Getting access.** The fork is at `github.com/Oculus-VR/UnrealEngine`. You'll only see it with a GitHub account
linked to an Epic account (on unrealengine.com: account, Apps and Accounts, GitHub, then accept the invite to the
EpicGames org). I don't remember linking a Meta developer account, so it may not be needed. If the links below 404,
it's an access problem.
- Release: https://github.com/Oculus-VR/UnrealEngine/releases/tag/oculus-4.27.1-release-1.67.0-v35.0
- Dependency fix branch: https://github.com/Oculus-VR/UnrealEngine/tree/4.27-gitdeps-fix

**Toolchain.** You need the **VS 2019 compiler (MSVC v142, 14.29)**. VS 2022's v143 compiler won't build it. VS 2019
works, or VS 2022 (Build Tools is enough) with "MSVC v142 – VS 2019 C++ x64/x86 build tools" added. You'll also want
the Windows 10 SDK 10.0.19041, the .NET Framework 4.6.2 targeting pack, Python 3, about 150 GB free, and a few hours.

You'll use three files from this repo: [`tools/merge_gitdeps.py`](../tools/merge_gitdeps.py),
[`tools/hashpatch.py`](../tools/hashpatch.py) and
[`engine/itr-ub-layouts.hashpatch.json`](../engine/itr-ub-layouts.hashpatch.json).

```bat
:: 1. Get the source at the release tag. Keep the path short, UnrealBuildTool falls over on paths
::    longer than 260 characters.
git clone --branch oculus-4.27.1-release-1.67.0-v35.0 --depth 1 https://github.com/Oculus-VR/UnrealEngine.git C:\ue427
cd /d C:\ue427

:: 2. Fix the dependency list. The tag's Commit.gitdeps.xml points at downloads Epic doesn't host any more, so
::    Setup.bat fails with HTTP 403. merge_gitdeps.py keeps the tag's file versions but takes the download
::    locations from the 4.27-gitdeps-fix branch.
git fetch --depth 1 origin 4.27-gitdeps-fix
git show FETCH_HEAD:Engine/Build/Commit.gitdeps.xml > Commit.gitdeps.fix.xml
copy Engine\Build\Commit.gitdeps.xml Engine\Build\Commit.gitdeps.v35-original.xml
python <itr-common>\tools\merge_gitdeps.py Engine\Build\Commit.gitdeps.v35-original.xml Commit.gitdeps.fix.xml Engine\Build\Commit.gitdeps.xml

:: 3. Apply the ITR layout patch. It checks every file first and won't apply twice.
python <itr-common>\tools\hashpatch.py apply <itr-common>\engine\itr-ub-layouts.hashpatch.json C:\ue427

:: 4. Build
Setup.bat
GenerateProjectFiles.bat
Engine\Build\BatchFiles\Build.bat UE4Editor Win64 Development -WaitMutex
Engine\Build\BatchFiles\Build.bat ShaderCompileWorker Win64 Development -WaitMutex
Engine\Build\BatchFiles\Build.bat UnrealPak Win64 Development -WaitMutex
```

When we ran the merge, it kept 63,981 files at their 4.27.1 versions. It took 146 from later 4.27 because the old
ones aren't hosted any more (localization, a few media DLLs, some plugin assets). It dropped 142 files nobody needs
for a build (CI configs, Dockerfiles, `.ps1`). If you want to compare your files with ours, here are the SHA-256s:

| File | SHA-256 |
|---|---|
| The tag's original `Commit.gitdeps.xml` | `9f429c5e93111d0992e2dfa1504e5037338d8b0d3546003101755c0dbcc23ee8` |
| `4.27-gitdeps-fix` manifest as we got it in October 2026 (the branch could change) | `bff2b4b6a4f008bf5dcf1f824b05ffd9dd1115da96e74c32395bcb6a393e123f` |
| The merged manifest | `b11e88d7ee76037e709d9d6f6977c96236efaa96f3021475a0f4068cd627e9c9` |

**Why a "hashpatch" instead of a normal patch?** A normal patch includes the engine lines it changes, and Epic's EULA
limits how engine code can be shared:
- sharing with other licensees is fine;
- public sharing is meant to go through a fork in Epic's GitHub network;
- snippets up to 30 lines are OK for discussion or "in connection with supporting patches and plug-ins".

So the patch doesn't contain any of Epic's lines. It points at the lines it replaces by line number and hash, and at
moved lines by where they are in your copy. The only text in it is what we wrote. Applying it to a clean checkout
came out the same as our patched engine. That's our reading of the EULA, not legal advice.

**What the patch changes** (20 files):
- the `View` / `InstancedView` buffers: 5 `Prev*` matrices taken out, contact-shadow members added;
- `Primitive`: the spherical-harmonic lighting moves in from `IndirectLightingCache`, and there are 5 custom-data slots;
- the shared base pass (stereo screen-space reflections) and scene textures;
- the per-object (GPUScene) stride goes to 33, with 3 float4s per matrix. Without this one everything renders black.

There's also one editor scripting helper in there,
`MaterialEditingLibrary.SetMaterialInstanceStaticSwitchParameterValue`. The game doesn't need it; we used it for
tooling.

**Checking your build.** It's worth doing before you make anything. This compares the uniform buffers your editor
builds with the game's (`pip install pefile capstone` first):
```bat
cd <itr-common>\tools
for %d in (Engine Renderer RenderCore Landscape) do python ub_extract_exe.py C:\ue427\Engine\Binaries\Win64\UE4Editor-%d.dll --dump my_%d.json
python ub_material_diff.py ..\data\ub\game-2.7.2.json my_Engine.json my_Renderer.json my_RenderCore.json my_Landscape.json
```
A good build shows `IDENTICAL` for 24 buffers. You'll also see `TranslucentDepthPass: missing in game`, which is
fine, because the game exe doesn't have a separate copy of that one. The game's layouts in
[`data/ub/game-2.7.2.json`](../data/ub/game-2.7.2.json) came out of `IntoTheRadius-Win64-Shipping.exe` via
`ub_extract_exe.py`. If the game updates, run it again to see if anything moved. `shadermap_dump.py` and
`dxbc_disasm.py` are for poking at compiled shaders in cooked packages.

**Making materials with it.** Tick **Used with Static Lighting** and **Used with Instanced Static Meshes**. If you
don't, the cook leaves out shader variants the game asks for, and you get the default material instead. We've
tested opaque materials. Translucent, masked foliage, decals and landscape materials haven't been tried yet.

## 4. Building the map
The easiest way to start is the example. In the editor, go to File, Execute Python Script, and pick
[`example-map/Scripts/build_example.py`](../example-map/Scripts/build_example.py). It makes the two levels and the
material `M_ExampleGrid`, and places everything listed below. Because the editor compiles that material, it's also a
quick check that route B works: if the floor shows a checker pattern in game, your editor is good. After that, build
the navmesh (below). The script is short and worth reading alongside this. The example's
[README](../example-map/README.md) has the commands, including how to run things headless.

A few rules we worked out:
- **Where it goes.** Put the map at `/Game/Mods/<Name>/L_<Name>`. Sublevels are fine.
- **Where it sits in the world.** Build it where it'll actually be in game, and keep it away from the game's navmesh
  volumes (X −435,000 to 698,000, Y −219,000 to 646,000 cm). The example sits at (0, −600,000, 0) cm. The loader
  streams it in at zero offset because navmesh tiles are stored in absolute coordinates.
- **Start and exit.** Put a `TargetPoint` tagged `itr:player_start` where players should arrive (Details, Actor,
  Tags). Add another tagged `itr:exit`, with something visible on it. Stepping onto that one takes you back to the
  Hub (§6).
- **Sky.** The game turns sky atmosphere off (`r.SupportSkyAtmosphere=False`), so use the engine sky dome instead:
  mesh `/Engine/EngineSky/SM_SkySphere`, material `/Engine/EngineSky/M_Sky_Panning_Clouds2`. Both are under Engine
  Content in any editor, and the game has them too. Turn off collision and shadows on it.
- **Lighting.** Movable lights work. Exposure is EV100 with auto exposure off. From the Hub, roughly a 2-lux sun and
  a 0.6 sky light looked about right. For baked lighting see §7.
- **Fog.** Height fog is global, so the Hub's fog also covers your map.
- **Using the game's materials and meshes.** Copy the asset and whatever it references from the SDK's `Content` into
  your project at the **same path**, use it, and only pack `/Game/Mods/<Name>`. In game, the game's copy gets loaded
  instead of yours. Only plain material instances work this way (see §0). We've tried static meshes, foliage meshes
  and the `Prefab_Zone_*` blueprints (which are just engine components). Anything you place this way is included in
  your navmesh.
- **Gameplay blueprints** (spawners, stashes, loot points, items). Their C++ parents live in the game's
  `IntoTheRadius` code module, and a blueprint-only project can't load that. The ITR-SDK has a recreation of the
  module (`Source/IntoTheRadius`, built for stock 4.27). Building that into your project should let you place the
  SDK's gameplay blueprints directly, and placed actors get stable names, which the save system needs. Nobody has
  tried that yet as far as we know. In the meantime, [`extended.md`](extended.md) covers spawning them at runtime.

### Navmesh (tested)
NPCs can only walk on navmesh, and the game never builds any at runtime (`RuntimeGeneration=DynamicModifiersOnly`).
So you bake it into your map.

The game bakes its whole navmesh into `L_Common`, the level that's always loaded. It's two navmeshes,
`RecastNavMesh-Default` and `RecastNavMesh-Big`, and their agents are set in `DefaultEngine.ini`. Since you copied
that file, your editor uses the same settings: Default is radius 20, height 140, step 40; Big is radius 400, height
200; cell size 20 and 10 m tiles.

A streamed level can carry its own navmesh tiles. When it streams in, they get added to the persistent level's navmesh
with the same name. You can't open `L_Common` in the editor because it only exists cooked (the SDK copy too). So the
example uses a small editor-only stand-in, `L_ExampleHost`. Your map is a sublevel of it, and its navmesh actors
get the same names as the game's.

There's one catch that took us a while. The game's `DefaultEngine.ini` sets `bAutoCreateNavigationData=False`, so the
editor never creates the navmesh actors and Build Paths quietly does nothing. You have to switch auto-create on for
the session and re-register the bounds volumes, and then it creates both navmeshes.
[`build_navmesh.py`](../example-map/Scripts/build_navmesh.py) does all that, builds, waits for it to finish and saves.

If you'd rather do it by hand:
1. Open the host level.
2. In the Python console, run:
   ```python
   nav = unreal.NavigationSystemV1.get_navigation_system(unreal.EditorLevelLibrary.get_editor_world())
   nav.set_editor_property("auto_create_navigation_data", True)
   nav.on_navigation_bounds_updated(<your bounds volume>)
   ```
3. Build, Build Paths.
4. File, Save All.

The tiles get saved into your map. The host level only holds the navmesh actors, and it shouldn't be packed
(`build-map.ps1` skips anything called `L_*Host`).

This has to happen in the full editor. Building from a commandlet (`-run=ResavePackages -BuildNavigationData`) didn't
save tiles into the sublevel when we tried it. If you want to run it unattended, start the editor with
`"-ExecCmds=py <script>"`. Don't use `-ExecutePythonScript=`, because that closes the editor as soon as the script
returns, before the build has run.

## 5. Cook, pack and install
```powershell
.\build-map.ps1 -Engine "C:\ue427\Engine" -Map Example -Install
```
[`example-map/build-map.ps1`](../example-map/build-map.ps1) does four things:
1. Cooks the map:
   `UE4Editor-Cmd.exe IntoTheRadius.uproject -run=cook -targetplatform=WindowsNoEditor -map=/Game/Mods/<Name>/L_<Name> -unversioned`.
   The game's packages are unversioned, hence `-unversioned`.
2. Writes a response file, one line per cooked file, in the form `"<file on disk>" "<path inside the game>"`. Only
   files under `Saved/Cooked/WindowsNoEditor/IntoTheRadius/Content/Mods/<Name>/` go in. Anything else from the cook
   (engine content, SDK copies) would replace the game's files, which you don't want. A line looks like:
   `"C:\...\Saved\Cooked\WindowsNoEditor\IntoTheRadius\Content\Mods\Example\L_Example.umap" "../../../IntoTheRadius/Content/Mods/Example/L_Example.umap"`
3. Packs it: `UnrealPak.exe zzz_ITRMap_<Name>_P.pak -create=<response file>`. The game happily loads unsigned paks
   (there are no `.sig` files). The `_P` suffix makes it a patch pak, so it mounts after the game's.
4. Copies the pak into `<game>\IntoTheRadius\Content\Paks\`. You need to restart the game whenever it changes.

We built the example this way with the special editor in October 2026. Generating the map headless, building the
navmesh and cooking took a couple of minutes, and the pak has the map plus the material (30 compiled shaders). In VR,
loaded by the UE4SS script from the Hub, the checker floor rendered properly, you start at the marker, and enemies we
spawned stood on the navmesh. The result is [`example-map/prebuilt/zzz_ITRMap_Example_P.pak`](../example-map/prebuilt/).

A couple of things to watch:
- After any engine or shader change, delete `Saved/Cooked` first. `-iterate` cooks don't notice those.
- Once, a script changed a material's usage flags while the open level was drawing it, and the editor hit a
  render-thread assert. We only saw it once and didn't dig into it.

## 6. Getting into the map
The game's level list, gates and map screen don't know about custom maps, so something has to stream the map in.
That's the only runtime code a map like this needs.

We use a UE4SS Lua script, [`loader-ue4ss/`](../loader-ue4ss/). It loads your map automatically when you arrive in
the Hub (handy in VR) or when you press a key. Its README covers installing it. Follow the manual install on the
Nexus page: the **contents** of the zip's `ue4ss` folder go into `Content\Paks`, and `Mods` gets renamed to
`LuaMods` there. We tested it in VR.

If you want to write your own loader, this is what it has to do. Everything here is a blueprint-callable engine
function.
1. In the Hub, call
   `LevelStreamingDynamic::LoadLevelInstance(World, "/Game/Mods/<Name>/L_<Name>", (0,0,0), (0,0,0), bSuccess)`.
   Don't do it from the main menu, because the teleport claims it worked but the VR player doesn't actually move.
   UE4SS 3.0.1 can't make this particular call from Lua (there's an out-parameter bug), so our script copies what it
   does internally:
   - call `LevelStreaming::CreateInstance(<unique name>)` on any existing dynamic streaming entry;
   - set `PackageNameToLoad` to your map's package;
   - set `LevelTransform` to identity;
   - call `SetShouldBeLoaded(true)` and `SetShouldBeVisible(true)`.
2. Once the streaming level says `IsLevelVisible()`, find the `TargetPoint` tagged `itr:player_start` in its level and
   call `K2_TeleportTo` on the player pawn. The game has its own `TeleportPlayer` event, but you can't call it this way.
3. For maps with baked lighting, hide the Hub's lighting-scenario level (see §7).
4. Give people a way out. Our script remembers where you were, and when you step within 1.5 m of a `TargetPoint`
   tagged `itr:exit` (or press the key), it moves you back there and then unloads the map. Put an exit in every map,
   because in VR there's no other way back apart from quitting to the menu.
5. To unload, call `SetShouldBeVisible(false)` and `SetShouldBeLoaded(false)` on the streaming level, after you've
   moved the player off it.

Working out when you're really in the Hub is fiddlier than it sounds. While you're coming from the menu, the Hub level
shows as visible even though you're still standing in the menu room. Our script also waits for
`LevelManager::IsReady()`, and checks twice, 2 s apart.

## 7. What works and what doesn't
| Feature | Status |
|---|---|
| Geometry, collision, game meshes, plain game materials | Works with either route |
| Your own materials | Works with route B (we've tested opaque ones) |
| Your own landscape | Untested |
| Movable lights, sky dome, post-process volumes | Works. Fog is shared with the Hub |
| Baked lighting | Loads (we tried it with a rebuilt level), but the loader has to hide the Hub's lighting-scenario level. While that's visible, the engine reads every level's lightmaps from it. Find it in `World.StreamingLevels` (its loaded level has `bIsLightingScenario` set), call `SetShouldBeVisible(false)`, and put it back when you unload. We haven't judged how good it looks yet |
| Navmesh | Works (§4) |
| Placing gameplay blueprints in the editor | Untested (§4) |
| Getting into the map | Needs a loader (§6) |
| Gates and travel, map screen, missions, loot tables, saves | Not available. These are all per-zone data assets (`DA_SystemConfig.LevelConfigurations`, `DA_MapPointsConfig`, `/Game/ITR/Configurations/Missions`, `/Game/ITR/Configurations/Loot/<Zone>`). Registering a map there (a level config entry, a streaming entry, gates, map points) might let the game treat it like a normal zone, saves and travel included. That would mean overriding the game's data assets. Unexplored |
| AI cover (mimics taking cover) | Not available. Zones come with baked cover data and we don't know how the game generates it |

## 8. When things go wrong
- Crash reports end up in `%LOCALAPPDATA%\IntoTheRadius\Saved\Crashes\` (`CrashContext.runtime-xml` plus a
  minidump). The shipping game doesn't write a log.
- If the game crashes on the render thread or things go black as soon as your map is in view, a shader was most
  likely built with the wrong engine (§0).
- "Serialization Error: Corrupt data found" usually means a package was cooked with a different engine version.
- If the loader says the level failed to load, check that the pak is in `Content\Paks`, that its name ends in `_P`,
  and that the path is right (`/Game/Mods/<Name>/L_<Name>`, no extension).
- If the game hangs at startup with UE4SS installed (no window, about 12 MB of memory), there's a hidden "UE4SS
  Error: Failed to load UE4SS.dll" box. `UE4SS.dll` isn't where `override.txt` says it is. We did this by copying the
  `ue4ss` folder itself into `Content\Paks` rather than what's inside it. See the [loader README](../loader-ue4ss/README.md).
- If UE4SS runs but the loader never logs anything, `Mods` probably wasn't renamed to `LuaMods`.

### Things that tripped us up
| What happened | Why | What to do |
|---|---|---|
| A Python script works in the editor but fails headless (`-run=pythonscript`) with "could not be found in the Content Browser" | `EditorAssetLibrary.load_asset` goes through the asset registry, which a commandlet hasn't scanned | Use `unreal.load_asset(path)` instead |
| Build Paths doesn't create any `RecastNavMesh` actors | The game's `DefaultEngine.ini` has `bAutoCreateNavigationData=False` | Turn it on for the session and re-register each bounds volume (`build_navmesh.py` does this) |
| No navmesh tiles in the map after a headless build | `-run=ResavePackages -BuildNavigationData` builds them but doesn't save them into the sublevel | Build in the editor (you can still run it unattended, see the next row) |
| The editor closes before the navmesh is built | `-ExecutePythonScript=` quits as soon as the script returns | Use `"-ExecCmds=py <script>"` and have the script quit when it's done |
| Every material on the map renders black | The GPUScene matrix packing doesn't match the game's | The layout patch (§3) |
| A material shows up as the default material | The cook skipped the static-lighting variants the game uses | Tick Used with Static Lighting and Used with Instanced Static Meshes |
| `/Game/...` arguments turn into `C:/Program Files/Git/Game/...` | Git Bash rewrites anything that looks like a path | Use PowerShell or cmd, or set `MSYS_NO_PATHCONV=1` |
| UnrealBuildTool exits with code 6 | Output paths over 260 characters | Keep the engine somewhere short like `C:\ue427` |
| The editor starts SteamVR | Its SteamVR plugin | Close SteamVR afterwards, or use `-nohmd` for unattended runs |
| Mod DLLs stay locked after a crash | `CrashReportClient.exe` is holding them | Close it before copying files |
| UE4SS logs `StrProperty can only be set to a string or FString` | UE4SS 3.0.1 reads the wrong argument after a non-struct out-parameter | Avoid those functions. Our loader uses `CreateInstance` instead of `LoadLevelInstance` |
| The map loads while you're still in the menu room | The Hub level counts as visible during the transition | Wait for `LevelManager::IsReady()` (our loader does) |

## What's in the repo
| Path | What |
|---|---|
| [`example-map/`](../example-map/) | Project skeleton, map and navmesh scripts, config extraction, cook/pack script, prebuilt pak |
| [`loader-ue4ss/`](../loader-ue4ss/) | The UE4SS loader |
| [`engine/`](../engine/) | The layout patch |
| [`tools/`](../tools/) | `merge_gitdeps.py`, `hashpatch.py`, and the layout and shader tools |
| [`data/ub/`](../data/ub/) | The game's uniform buffer layouts, from the 2.7.2 exe |
| [`extended.md`](extended.md) | What you can add with a runtime mod |
