# Builds the example level add-on in the Unreal editor: File > Execute Python Script > this file, or headless:
#   UE4Editor-Cmd.exe <path>\IntoTheRadius.uproject -run=pythonscript -script=<path>\Scripts\build_addon.py -nullrhi -unattended
# Run import_hub.py first: the meshes placed here are its stand-ins of the game's meshes (same /Game paths).
#
#   /Game/Mods/HubCozyCorner/L_HubCozyCornerHost  editor-only persistent level: two Movable lights to see by, and the two levels
#                                                 below as sublevels. Never packed.
#   /Game/Mods/HubCozyCorner/L_HubCozyCorner      the add-on (streamed into the Hub at the origin, so it is built in Hub
#                                                 world coordinates). This is the only level that goes into the pak.
#   /Game/HubReference/L_HubReference             the Hub, for lining things up (made by import_hub.py). Never packed.
#
# What the add-on holds (each actor tagged "addon_example", so a rerun rebuilds only these; anything you add by hand stays):
#   a Hub container room (the stock shell, room interior and window, as the Hub assembles them) standing on the roof of the Hub
#   container room SM_ContainerClosed_33 (roof at z 340, in the yard beside the factory hall), turned so its door opens onto the free strip
#   of that roof; the stock ladder SM_Ladder_Metal_350_01_a from the hall's floor slab (z 85) to 50 cm above that roof, leaning on
#   the +Y wall like the leaning ladder at the Hub shelter; two invisible BlockAll boxes under the room and the strip, in case the
#   roof below has no collision there. Every mesh is Movable: the Hub's lighting is baked, and a Movable mesh is lit by the
#   Hub's volumetric lightmap and its stationary lights (a Static one would have no lightmap baked for it and render unlit).
import os
import sys
import time

import unreal

NAME = "HubCozyCorner"
FOLDER = "/Game/Mods/" + NAME
HOST = FOLDER + "/L_" + NAME + "Host"
ADDON = FOLDER + "/L_" + NAME
REF = "/Game/HubReference/L_HubReference"
TAG = "addon_example"

SHELL = "/Game/ART2/Environment/Industrial/Container/SM_Industrial_Container_Hub_Room_01_a"
ROOM = "/Game/ART2/Environment/Hub/Room/SM_Hub_Room_Interior_01_a"
WINDOW = "/Game/ART2/Environment/Hub/Door/SM_Hub_Room_Window_01_b"
LADDER = "/Game/ART2/Environment/Buildings/Ladder_Metal/SM_Ladder_Metal_350_01_a"
CUBE = "/Engine/BasicShapes/Cube"

# Hub world coordinates (cm, UE axes). The room below: SM_ContainerClosed_33 in L_Hub, shell at (-34055, -1020, 85) yaw 180,
# 456 x 626 cm, roof at z 340. The new room: same shell, room interior and window as the Hub's rooms, yaw -90 (door side facing
# +Y), its -Y face flush with the room below; the 1.7 m strip on the +Y side (Y -877 .. -707) is the landing.
ROOM_LOC = (-34055.0, -1105.0, 340.0)
ROOM_YAW = -90.0
WINDOW_LOCAL = (-226.0, 225.0, 149.0)        # window offset in the room's local frame (from the Hub's SM_ContainerClosed_33)
# Ladder: rails face +Y (yaw 90), leaning 7 degrees into the wall (pitch 7) like the Hub's SM_Ladder_Metal_350_01_a_18,
# 3.5 m x 0.8854 (the stock leaning ladder's scale) = 3.1 m: from the floor slab at z 85 to z 394, 54 cm above the roof edge;
# top rail 3 cm off the wall (Y -707).
LADDER_LOC = (-34150.0, -678.0, 85.0)
LADDER_ROT = (7.0, 90.0, 0.0)                # pitch, yaw, roll
LADDER_SCALE_Z = 0.8854
# Invisible floor boxes (min x, min y, max x, max y), top at the roof (z 340), 10 cm thick
FLOORS = [("Floor_Room", (-34367.0, -1333.0, -33743.0, -877.0)), ("Floor_Strip", (-34283.0, -877.0, -33826.0, -707.0))]
FLOOR_TOP, FLOOR_THICK = 340.0, 10.0

eal = unreal.EditorAssetLibrary
ell = unreal.EditorLevelLibrary
elu = unreal.EditorLevelUtils

try:                                             # run through `itr editor-run` (private workspace): its save-and-check helper
    sys.path.insert(0, os.environ.get("ITR_TOOLS", ""))
    import editor_lib
except Exception:                                # noqa: BLE001
    editor_lib = None


def log(msg):
    unreal.log("ADDON " + msg)


def need(path):
    a = eal.load_asset(path)
    if a is None:
        raise RuntimeError("%s is missing: run Scripts/import_hub.py first (it makes the stand-ins of the game meshes)" % path)
    return a


def rot_xy(x, y, yaw):
    import math
    c, s = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    return x * c - y * s, x * s + y * c


def place(mesh, label, role, loc, rot=(0.0, 0.0, 0.0), scale=(1.0, 1.0, 1.0)):
    a = ell.spawn_actor_from_object(mesh, unreal.Vector(*loc), unreal.Rotator(rot[2], rot[0], rot[1]))   # Rotator(roll, pitch, yaw)
    a.set_actor_scale3d(unreal.Vector(*scale))
    a.set_actor_label(label)
    a.tags = [TAG, "addon:" + role]
    a.root_component.set_mobility(unreal.ComponentMobility.MOVABLE)
    return a


def map_exists(pkg):
    # a file check: EditorAssetLibrary.does_asset_exist warns on a map that is already loaded
    content = unreal.Paths.convert_relative_path_to_full(unreal.Paths.project_content_dir())
    return os.path.isfile(os.path.join(content, pkg[len("/Game/"):] + ".umap"))


def open_levels():
    if map_exists(HOST):
        ell.load_level(HOST)
    elif not ell.new_level(HOST):
        raise RuntimeError("new_level failed: " + HOST)
    world = ell.get_editor_world()
    have = [l.get_outermost().get_name() for l in elu.get_levels(world)]
    if not map_exists(ADDON):
        elu.create_new_streaming_level(unreal.LevelStreamingAlwaysLoaded, ADDON, False)
    elif ADDON not in have:
        elu.add_level_to_world(world, ADDON, unreal.LevelStreamingAlwaysLoaded)
    if map_exists(REF) and REF not in have:
        elu.add_level_to_world(world, REF, unreal.LevelStreamingAlwaysLoaded)
    elif not map_exists(REF):
        log("no %s yet: run import_hub.py to see the Hub around the add-on" % REF)
    # host: two Movable lights to see by in the editor (the host level is never packed)
    ell.set_current_level_by_name("L_" + NAME + "Host")
    if not [a for a in ell.get_all_level_actors() if "addon_host" in [str(t) for t in a.tags]]:
        sun = ell.spawn_actor_from_class(unreal.DirectionalLight, unreal.Vector(-34000, -1000, 3000), unreal.Rotator(0, -50, 35))
        sun.root_component.set_mobility(unreal.ComponentMobility.MOVABLE)
        sun.tags = ["addon_host"]
        sun.set_actor_label("EditorSun")
        sky = ell.spawn_actor_from_class(unreal.SkyLight, unreal.Vector(-34000, -1000, 2500), unreal.Rotator(0, 0, 0))
        sky.root_component.set_mobility(unreal.ComponentMobility.MOVABLE)
        sky.light_component.set_intensity(1.0)
        sky.tags = ["addon_host"]
        sky.set_actor_label("EditorSky")
    ell.set_current_level_by_name("L_" + NAME)
    return world


def build():
    t0 = time.time()
    shell, room, window, ladder, cube = need(SHELL), need(ROOM), need(WINDOW), need(LADDER), need(CUBE)
    world = open_levels()
    for a in ell.get_all_level_actors():
        if TAG in [str(t) for t in a.tags]:
            ell.destroy_actor(a)

    x, y, z = ROOM_LOC
    rot = (0.0, ROOM_YAW, 0.0)
    place(shell, "Room_Shell", "shell", (x, y, z), rot)
    place(room, "Room_Interior", "room", (x, y, z), rot)
    wx, wy = rot_xy(WINDOW_LOCAL[0], WINDOW_LOCAL[1], ROOM_YAW)
    place(window, "Room_Window", "window", (x + wx, y + wy, z + WINDOW_LOCAL[2]), rot)
    # the ladder keeps the mesh's default collision (Climbable): never call set_collision_profile_name on it
    place(ladder, "Ladder", "ladder", LADDER_LOC, LADDER_ROT, (1.0, 1.0, LADDER_SCALE_Z))
    for label, (x0, y0, x1, y1) in FLOORS:
        f = place(cube, label, "floor", ((x0 + x1) / 2, (y0 + y1) / 2, FLOOR_TOP - FLOOR_THICK / 2),
                  scale=((x1 - x0) / 100.0, (y1 - y0) / 100.0, FLOOR_THICK / 100.0))
        f.set_actor_hidden_in_game(True)
        smc = f.static_mesh_component
        smc.set_collision_profile_name("BlockAll")
        smc.set_editor_property("cast_shadow", False)

    if editor_lib:
        actors = [a for a in ell.get_all_level_actors() if TAG in [str(t) for t in a.tags]]
        editor_lib.mark_and_save(actors[0])
    elif not ell.save_all_dirty_levels():
        raise RuntimeError("save_all_dirty_levels failed")
    log("example add-on built in %s (%.0f s); next: build-map.ps1 -Install" % (ADDON, time.time() - t0))


build()
