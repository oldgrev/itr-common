# Builds the example map in the Unreal editor: in the editor, File > Execute Python Script... > this file
# (needs the Python Editor Script Plugin and Editor Scripting Utilities, both enabled in IntoTheRadius.uproject).
#
#   /Game/Mods/Example/L_ExampleHost  stand-in persistent level: holds the two navmesh actors under the names the game's
#                                     L_Common uses. Never packed.
#   /Game/Mods/Example/L_Example      the map itself (streamed into the game), built at ORIGIN.
#
# Only engine content that comes with the game is used (BasicShapes, the engine sky dome), so no new shaders: this map
# cooks in stock Epic 4.27 as well as in the special editor. Everything placed is tagged "example" so a rerun rebuilds it.
import unreal

# True: the floor gets M_ExampleGrid, a material compiled by YOUR editor (a 1 m world-aligned checker). This needs the
# special editor (guide section 3): a stock 4.27 build of it crashes the game or renders black. False: engine content
# only, which also builds in stock 4.27.
OWN_MATERIAL = True

ORIGIN = unreal.Vector(0.0, -600000.0, 0.0)    # clear of the game's navmesh volumes (X -435k..698k, Y -219k..646k cm)
FOLDER = "/Game/Mods/Example"
HOST = FOLDER + "/L_ExampleHost"
MAP = FOLDER + "/L_Example"
HALF = 4000.0                                   # floor half size: 80 x 80 m

eal = unreal.EditorAssetLibrary
ell = unreal.EditorLevelLibrary
elu = unreal.EditorLevelUtils
CUBE = unreal.load_asset("/Engine/BasicShapes/Cube")
SHAPE_MAT = unreal.load_asset("/Engine/BasicShapes/BasicShapeMaterial")


def grid_material():
    """/Game/Mods/Example/M_ExampleGrid: alternating 1 m squares in world space (two greys), rough."""
    path = FOLDER + "/M_ExampleGrid"
    mel = unreal.MaterialEditingLibrary
    if eal.does_asset_exist(path):
        mat = unreal.load_asset(path)
        mel.delete_all_material_expressions(mat)
    else:
        mat = unreal.AssetToolsHelpers.get_asset_tools().create_asset(
            "M_ExampleGrid", FOLDER, unreal.Material, unreal.MaterialFactoryNew())
    # The game draws static meshes with static-lighting shader variants: without these flags the cook leaves them
    # out and the game falls back to its default material.
    mat.set_editor_property("used_with_static_lighting", True)
    mat.set_editor_property("used_with_instanced_static_meshes", True)
    E = lambda cls, x, y: mel.create_material_expression(mat, cls, x, y)
    wp = E(unreal.MaterialExpressionWorldPosition, -1200, 0)
    div = E(unreal.MaterialExpressionDivide, -1000, 0)
    div.set_editor_property("const_b", 100.0)                  # 1 m cells
    flo = E(unreal.MaterialExpressionFloor, -850, 0)
    rx = E(unreal.MaterialExpressionComponentMask, -700, -60)
    gy = E(unreal.MaterialExpressionComponentMask, -700, 60)
    for m, ch in ((rx, "r"), (gy, "g")):                         # new masks don't start all-false: set every channel
        for c in "rgba":
            m.set_editor_property(c, c == ch)
    add = E(unreal.MaterialExpressionAdd, -550, 0)
    fm = E(unreal.MaterialExpressionFmod, -400, 0)
    two = E(unreal.MaterialExpressionConstant, -550, 120)
    two.set_editor_property("r", 2.0)
    a = E(unreal.MaterialExpressionConstant3Vector, -400, -200)
    a.set_editor_property("constant", unreal.LinearColor(0.18, 0.18, 0.17, 1))
    b = E(unreal.MaterialExpressionConstant3Vector, -400, 200)
    b.set_editor_property("constant", unreal.LinearColor(0.32, 0.30, 0.26, 1))
    lerp = E(unreal.MaterialExpressionLinearInterpolate, -200, 0)
    rough = E(unreal.MaterialExpressionConstant, -200, 200)
    rough.set_editor_property("r", 0.9)
    mel.connect_material_expressions(wp, "", div, "A")
    mel.connect_material_expressions(div, "", flo, "")
    mel.connect_material_expressions(flo, "", rx, "")
    mel.connect_material_expressions(flo, "", gy, "")
    mel.connect_material_expressions(rx, "", add, "A")
    mel.connect_material_expressions(gy, "", add, "B")
    mel.connect_material_expressions(add, "", fm, "A")
    mel.connect_material_expressions(two, "", fm, "B")
    mel.connect_material_expressions(a, "", lerp, "A")
    mel.connect_material_expressions(b, "", lerp, "B")
    mel.connect_material_expressions(fm, "", lerp, "Alpha")
    mel.connect_material_property(lerp, "", unreal.MaterialProperty.MP_BASE_COLOR)
    mel.connect_material_property(rough, "", unreal.MaterialProperty.MP_ROUGHNESS)
    mel.recompile_material(mat)
    eal.save_loaded_asset(mat)
    return mat


def tagged(actor, label, *extra):
    actor.set_actor_label(label)
    actor.tags = ["example"] + list(extra)
    return actor


def box(label, x, y, z, sx, sy, sz, yaw=0.0, pitch=0.0, mat=None):
    """Cube centred at ORIGIN + (x, y, z) cm with size (sx, sy, sz) cm."""
    a = ell.spawn_actor_from_object(CUBE, ORIGIN + unreal.Vector(x, y, z), unreal.Rotator(0.0, pitch, yaw))
    a.set_actor_scale3d(unreal.Vector(sx / 100.0, sy / 100.0, sz / 100.0))
    a.static_mesh_component.set_material(0, mat or SHAPE_MAT)
    return tagged(a, label)


def open_host():
    if eal.does_asset_exist(HOST):
        ell.load_level(HOST)
    else:
        ell.new_level(HOST)
    return ell.get_editor_world()


def open_map(world):
    if not eal.does_asset_exist(MAP):
        elu.create_new_streaming_level(unreal.LevelStreamingAlwaysLoaded, MAP, False)
    elif not any(l.get_outermost().get_name() == MAP for l in elu.get_levels(world)):
        elu.add_level_to_world(world, MAP, unreal.LevelStreamingAlwaysLoaded)
    ell.set_current_level_by_name("L_Example")
    for a in ell.get_all_level_actors():
        if "example" in [str(t) for t in a.tags]:
            ell.destroy_actor(a)


def build():
    grid = grid_material() if OWN_MATERIAL else None   # before the levels: never recompile a material the open level draws
    world = open_host()
    open_map(world)

    # ground, perimeter walls, cover, a small hut, a ramp up to a platform
    box("Floor", 0, 0, -10, HALF * 2, HALF * 2, 20, mat=grid)
    for i, (x, y, sx, sy) in enumerate([(HALF, 0, 100, HALF * 2), (-HALF, 0, 100, HALF * 2),
                                         (0, HALF, HALF * 2, 100), (0, -HALF, HALF * 2, 100)]):
        box("Wall%d" % i, x, y, 150, sx, sy, 300)
    for i, (x, y) in enumerate([(-1500, 1000), (-500, 2000), (600, 800), (1600, 2200)]):
        box("Cover%d" % i, x, y, 50, 40, 250, 100)
    hx, hy = 2000.0, -1200.0                       # 6 x 6 m hut, door gap on the -X side
    box("Hut_Roof", hx, hy, 310, 640, 640, 20)
    box("Hut_WallPX", hx + 300, hy, 150, 20, 580, 300)
    box("Hut_WallPY", hx, hy + 300, 150, 620, 20, 300)
    box("Hut_WallNY", hx, hy - 300, 150, 620, 20, 300)
    box("Hut_WallNX_a", hx - 300, hy + 180, 150, 20, 220, 300)
    box("Hut_WallNX_b", hx - 300, hy - 180, 150, 20, 220, 300)
    box("Platform", -2000, -2500, 100, 600, 400, 200)
    box("Ramp", -2000 + 580, -2500, 100, 600, 400, 20, pitch=-19.5)

    # lights: Movable, so nothing depends on a lighting build. ~2 lux sun + 0.6 sky light look right under the Hub.
    sun = ell.spawn_actor_from_class(unreal.DirectionalLight, ORIGIN + unreal.Vector(0, 0, 1000), unreal.Rotator(0, -50, 35))
    sun.root_component.set_mobility(unreal.ComponentMobility.MOVABLE)
    sun.light_component.set_intensity(2.0)
    tagged(sun, "Sun")
    sky = ell.spawn_actor_from_class(unreal.SkyLight, ORIGIN + unreal.Vector(0, 0, 800), unreal.Rotator(0, 0, 0))
    sky.root_component.set_mobility(unreal.ComponentMobility.MOVABLE)
    sky.light_component.set_intensity(0.6)
    tagged(sky, "SkyLight")

    # sky: the game sets r.SupportSkyAtmosphere=False, so use the engine sky dome (comes with the game)
    dome = ell.spawn_actor_from_object(unreal.load_asset("/Engine/EngineSky/SM_SkySphere"), ORIGIN, unreal.Rotator(0, 0, 0))
    dome.set_actor_scale3d(unreal.Vector(4.0, 4.0, 4.0))
    smc = dome.static_mesh_component
    smc.set_material(0, unreal.load_asset("/Engine/EngineSky/M_Sky_Panning_Clouds2"))
    smc.set_collision_profile_name("NoCollision")
    smc.set_editor_property("cast_shadow", False)
    smc.set_editor_property("can_ever_affect_navigation", False)
    tagged(dome, "SkyDome")

    # the start marker the loader teleports the player to
    tp = ell.spawn_actor_from_class(unreal.TargetPoint, ORIGIN + unreal.Vector(-3000, 0, 20), unreal.Rotator(0, 0, 0))
    tagged(tp, "PlayerStart", "itr:player_start")

    # the way out: step onto this pad (8 m to the left of the start) and the loader returns you to the Hub
    box("ExitPad", -3000, -800, 5, 150, 150, 10)
    box("ExitPost", -3000, -880, 110, 10, 10, 200)
    ex = ell.spawn_actor_from_class(unreal.TargetPoint, ORIGIN + unreal.Vector(-3000, -800, 20), unreal.Rotator(0, 0, 0))
    tagged(ex, "Exit", "itr:exit")

    # navmesh bounds (88 x 88 x 20 m); build_navmesh.py builds the tiles into L_Example
    nav = ell.spawn_actor_from_class(unreal.NavMeshBoundsVolume, ORIGIN + unreal.Vector(0, 0, 500), unreal.Rotator(0, 0, 0))
    nav.set_actor_scale3d(unreal.Vector(HALF * 2.2 / 200.0, HALF * 2.2 / 200.0, 2000 / 200.0))
    tagged(nav, "NavBounds")

    ell.save_all_dirty_levels()
    print("example map built; next: Scripts/build_navmesh.py (navmesh), then build-map.ps1 (cook and pack)")


build()
