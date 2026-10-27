# Example level add-on: a room on a Hub roof

A small add-on for the Hub of Into the Radius 1 (2.7.2), loaded by [`../addons-ue4ss`](../addons-ue4ss/) (ITRLevelAddons):

- a Hub container room (the stock container shell `SM_Industrial_Container_Hub_Room_01_a`, the room interior
  `SM_Hub_Room_Interior_01_a` and a window `SM_Hub_Room_Window_01_b`, put together the way the Hub's rooms are) standing
  on the roof of the Hub container room `SM_ContainerClosed_33`, in the yard beside the factory hall. Its door opens onto
  a 1.7 m strip of that roof;
- the stock ladder `SM_Ladder_Metal_350_01_a` from the floor slab beside the room up to that strip, leaning on the room's +Y wall at 7 degrees
  like the leaning ladder at the Hub shelter;
- two invisible boxes (BlockAll collision, hidden in game) under the room and the strip, so you can't fall through
  where the roof below has no collision;
- a `hide` entry for the wooden pallet that lies on that roof (`SM_Props_WoodenPallet_01_a6` in `L_Hub`), which the new
  room's floor would cut through.

Everything is placed in Hub world coordinates and streamed in at the origin.

| | World position (cm) |
|---|---|
| Room (shell + interior), yaw -90 | (-34055, -1105, 340) |
| Window | (-33830, -879, 489) |
| Door (opening in the +Y wall) | about (-34245, -877, 345) |
| Ladder foot (pivot), pitch 7, yaw 90, scale Z 0.8854 | (-34150, -678, 85); top at z 394, 54 cm above the roof |
| Roof strip you land on | X -34283 .. -33826, Y -877 .. -707, z 340 |

Why there: the Hub's housing units are containers. The candidates were the player's shelter (its roof already has
handrails, a stair and the tutorial ladder, so it is reachable), the two-high container stack next to the shelter (a
catwalk and stairs lead onto it), the third container on the stack at the other side of the shelter (235 cm wide,
narrower than the room), the container piles in the yard (junk heaps, no flat roof) and the factory hall roof (21 m up). The Hub room
`SM_ContainerClosed_33` is a housing unit with a flat roof at 3.4 m, nothing on it but a pallet, nothing above it up to the
hall's windows at 7 m, and free floor (the hall's floor slab at z 85) along its +Y wall for the ladder.

## Lighting
All add-on meshes are Movable (the rule for add-ons, see the [mod README](../addons-ue4ss/README.md#building-an-add-on)).
They are lit by the Hub's volumetric lightmap at that spot and by the Hub's stationary lights, with dynamic shadows. The
volumetric lightmap there was baked with open air in place of the room, so the inside of the room is lit about as
brightly as the yard around it, evenly, with no darker corners. It is readable without a lamp; a Movable point light
inside (warm, low intensity, small radius) is what would make it look lived in.

## Building it
You need the special editor from the [map-making guide](../map-making/guide.md) (or stock 4.27: the add-on has no
new material), Python 3 and a copy of the game.

1. Copy this folder somewhere. `Content/` gets made by the scripts.
2. Get the game's `DefaultEngine.ini` (render settings, collision profiles such as `Climbable`):
   ```powershell
   .\extract-game-config.ps1 -Engine "C:\ue427\Engine"
   ```
3. Read the Hub out of your game files (about 6 minutes; read only):
   ```powershell
   python Scripts\export_hub.py --cue4export <path>\cue4export.exe --engine "C:\ue427\Engine"
   ```
   It unpacks only the Hub levels, the Blueprints placed in them and the folders of the meshes they use (with the
   engine's UnrealPak, about 5 GB into `build\hubref\unpacked`, which you can delete afterwards), lists every placed mesh
   with its world transform (about 2700) and writes each mesh as an FBX (about 570, 250 MB).
   It uses cue4export, a small command-line exporter built on CUE4Parse (`level` and `mesh` commands); it isn't
   in this repo yet. If you already have the game unpacked, pass `--game-content <unpacked>\IntoTheRadius\Content` instead
   of `--engine`.
4. Build the stand-ins and the Hub reference, then the add-on (in the editor with File, Execute Python Script, or headless):
   ```bat
   C:\ue427\Engine\Binaries\Win64\UE4Editor-Cmd.exe <path>\IntoTheRadius.uproject -run=pythonscript -script=<path>\Scripts\import_hub.py -nullrhi -unattended
   C:\ue427\Engine\Binaries\Win64\UE4Editor-Cmd.exe <path>\IntoTheRadius.uproject -run=pythonscript -script=<path>\Scripts\build_addon.py -nullrhi -unattended
   ```
   `import_hub.py` imports every Hub mesh as a stand-in at its game path (the game's shape and collision, a grid
   material, tagged `itr_standin=1`) and builds `/Game/HubReference/L_HubReference`. `build_addon.py` makes
   `/Game/Mods/HubCozyCorner/L_HubCozyCornerHost` (editor only) with the add-on `L_HubCozyCorner` and the reference as
   its sublevels, and places the room, the ladder and the floor boxes (tagged `addon_example`; a rerun rebuilds only those).
5. Cook, pack and install (game closed):
   ```powershell
   .\build-map.ps1 -Engine "C:\ue427\Engine" -Install
   ```
   This packs only `/Game/Mods/HubCozyCorner` into `zzz_ITRAddon_HubCozyCorner_P.pak`. The stand-ins get cooked too (the
   level uses them) but stay out of the pak, and the Hub reference is never cooked: the game loads its real meshes.
6. Install the mod ([`../addons-ue4ss`](../addons-ue4ss/)) and copy [`addon/HubCozyCorner.json`](addon/HubCozyCorner.json)
   into its `Addons` folder.

**The Hub reference is made from your copy of the game and stays on your machine.** `Content/` and `build/` are in
`.gitignore`; don't publish them or a copy of them.

## Placing things by hand
1. Open `IntoTheRadius.uproject`, then the level `Content/Mods/HubCozyCorner/L_HubCozyCornerHost`.
2. Window, Levels: you see `L_HubCozyCorner` (the add-on) and `L_HubReference` (the Hub). Double-click
   `L_HubCozyCorner` to make it the current level (new actors go there), and click the padlock next to `L_HubReference`
   so the Hub can't be moved by accident. The eye icon hides the reference when you want to look at the add-on alone.
3. The Hub shows as grey grid meshes at their cooked positions, with their collision. In the World Outliner they are in
   folders per Hub level (`L_Hub/StaticMeshActor`, `L_Hub_factory/...`), labelled with the Hub actor's name: click a Hub
   mesh and its label is the name a `hide` entry takes (a label like `Actor.Component` is one part of a bigger Hub actor;
   use the part before the dot).
4. Exact coordinates: the add-on is streamed in at the origin, so the Location in Details is the Hub world position.
   Click a Hub mesh to read its position, right-click the Location field, Copy, and Paste it on your actor.
5. Snapping:
   - **Surface snapping** (the curved-arrow toggle in the viewport toolbar, next to the grid snap): dragging an actor
     slides it over the surface under the mouse; tick "Rotate to Surface Normal" for walls.
   - **End** drops the selected actors onto whatever is below them.
   - **Vertex snapping**: hold **V** while dragging the move gizmo; the pivot jumps to vertices of other meshes.
   - **Pivot**: **Alt + middle mouse drag** moves the pivot for this edit only; right-click, Pivot, Set as Pivot Offset
     keeps it. Put the pivot on a corner of the room, vertex-snap it to the corner of the roof below.
   - Grid snap 1 or 5 cm for fine moves, rotation snap 1 or 5 degrees; or type values into Location and Rotation.
   - Move the room as a group: select `Room_Shell`, `Room_Interior`, `Room_Window` and the two `Floor_*` boxes together.
6. Keep every add-on mesh **Movable** (Details, Transform, Mobility). Leave the ladder's **Collision Presets on Default**:
   that is what makes it climbable in the game.
7. Save (File, Save All), then cook and install again with the game closed:
   ```powershell
   .\build-map.ps1 -Engine "C:\ue427\Engine" -Install
   ```
   Then start the game. A rerun of `build_addon.py` puts the example's actors back where the script has them; to keep
   your changes, don't rerun it (or remove the `addon_example` tag from the actors you moved).

## Making your own add-on
Copy the folder, change `NAME` in `Scripts/build_addon.py` (and its contents), pass `-Map <Name>` to `build-map.ps1`,
and write a manifest `addon/<Name>.json` with `"level": "/Game/Mods/<Name>/L_<Name>"`. The manifest fields are in the
[mod README](../addons-ue4ss/README.md#the-manifest).

## What was tested (October 2026)
- Steps 2 to 5 with the special editor, headless: `export_hub.py` through UnrealPak (6 minutes, 2724 placed meshes, 566
  meshes exported, none failed), `import_hub.py` (566 stand-ins, every one within 1 % of the game mesh's bounds, and 2640
  reference actors, in about 3 minutes), `build_addon.py` and `build-map.ps1` (a 9.5 KB pak with the level only; its
  six imports are four game meshes and two engine assets, all present in the game).
- Against the reference's collision (the game's simple collision shapes): the strip and the room floor are solid at the
  roof height, a line walked into the door reaches the far wall of the room, there is body-sized free space on the strip
  and in the room, the room's top is under the hall roof (about 0.9 m clearance), the ladder foot stands on the floor
  slab and its climbing side is free up to the roof.
- **Not yet in VR**: the climb, standing on the roof, walking into the room and the hidden pallet are the first in-game
  test.
