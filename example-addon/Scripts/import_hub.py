# Builds the editor-only Hub reference from build/hubref/hubref.json (written by export_hub.py). Run it in the editor:
# File > Execute Python Script > this file, or headless:
#   UE4Editor-Cmd.exe <path>\IntoTheRadius.uproject -run=pythonscript -script=<path>\Scripts\import_hub.py -nullrhi -unattended
#
#   1. Stand-ins: every game mesh the Hub uses is imported at its /Game path (for example
#      /Game/ART2/Environment/Hub/Room/SM_Hub_Room_Interior_01_a) from the exported FBX: the game's shape, simple collision and
#      material slot names, with the engine's grid material. Each is tagged itr_standin=1. An asset that is already there without
#      that tag (a copy you made from an SDK) is left alone. The add-on level uses the stand-ins of the meshes it places; in the game
#      the real meshes load instead, because the pak holds only /Game/Mods/<Name>.
#   2. /Game/HubReference/L_HubReference: one StaticMeshActor per placed Hub mesh, at its cooked world transform, labelled with
#      the Hub actor's name (that is the name a "hide" entry needs) and filed under the Hub level it comes from in the Outliner.
#
# Everything this makes is rebuilt from your copy of the game and lives in Content/ (gitignored): never publish it.
import json
import os
import time

import unreal

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
HUBREF = os.path.join(PROJECT, "build", "hubref", "hubref.json")
REF_LEVEL = "/Game/HubReference/L_HubReference"
TAG = "itr_standin"
GRID = "/Engine/EngineMaterials/WorldGridMaterial"
SKIP_MESHES = ("EditorSkySphere", "SM_GodRays")      # editor helpers and light-shaft cards: nothing to align against

eal = unreal.EditorAssetLibrary
ell = unreal.EditorLevelLibrary


def log(msg):
    unreal.log("HUBREF " + msg)


def is_standin(asset):
    try:
        return eal.get_metadata_tag(asset, TAG) == "1"
    except Exception:
        return False


def save_asset(asset):
    if not eal.save_loaded_asset(asset, False):
        raise RuntimeError("save failed: " + asset.get_path_name())


def import_mesh(gp, m, grid):
    folder, name = gp.rsplit("/", 1)
    if eal.does_asset_exist(gp):
        a = eal.load_asset(gp)
        if not is_standin(a):
            return "kept (not a stand-in)"
    ui = unreal.FbxImportUI()
    ui.set_editor_property("import_mesh", True)
    ui.set_editor_property("import_materials", False)
    ui.set_editor_property("import_textures", False)
    ui.set_editor_property("import_as_skeletal", False)
    ui.set_editor_property("automated_import_should_detect_type", False)
    ui.set_editor_property("mesh_type_to_import", unreal.FBXImportType.FBXIT_STATIC_MESH)
    sd = ui.static_mesh_import_data
    sd.set_editor_property("combine_meshes", True)
    sd.set_editor_property("generate_lightmap_u_vs", False)
    sd.set_editor_property("auto_generate_collision", False)      # the FBX carries the game's simple collision (UCX_ nodes)
    sd.set_editor_property("remove_degenerates", False)
    t = unreal.AssetImportTask()
    for k, v in (("filename", os.path.normpath(m["fbx"])), ("destination_path", folder), ("destination_name", name),
                 ("automated", True), ("replace_existing", True), ("save", False), ("options", ui)):
        t.set_editor_property(k, v)
    unreal.AssetToolsHelpers.get_asset_tools().import_asset_tasks([t])
    sm = eal.load_asset(gp)
    if sm is None or not list(t.get_editor_property("imported_object_paths")):
        return "import failed"
    for i in range(len(sm.get_editor_property("static_materials"))):
        sm.set_material(i, grid)
    try:
        ag = sm.get_editor_property("body_setup").get_editor_property("agg_geom")
        prims = sum(len(ag.get_editor_property(k)) for k in ("convex_elems", "box_elems", "sphere_elems", "sphyl_elems"))
        if prims == 0:   # no simple collision in the game mesh: collide with the triangles so surface snapping still works
            sm.get_editor_property("body_setup").set_editor_property("collision_trace_flag", unreal.CollisionTraceFlag.CTF_USE_COMPLEX_AS_SIMPLE)
    except Exception:
        pass
    eal.set_metadata_tag(sm, TAG, "1")
    eal.set_metadata_tag(sm, "itr_standin_src", "export_hub.py from the installed game")
    save_asset(sm)
    b = m.get("bounds")
    if b:
        bb = sm.get_bounds()
        o, e = bb.origin, bb.box_extent
        got = [o.x - e.x, o.y - e.y, o.z - e.z, o.x + e.x, o.y + e.y, o.z + e.z]
        want = b["min"] + b["max"]
        size = max(1.0, max(want[3 + i] - want[i] for i in range(3)))
        if max(abs(got[i] - want[i]) for i in range(6)) > 0.01 * size + 1.0:
            return "imported, bounds differ %s vs %s" % ([round(v) for v in got], [round(v) for v in want])
    return "imported"


def build_reference(data):
    content = unreal.Paths.convert_relative_path_to_full(unreal.Paths.project_content_dir())
    if os.path.isfile(os.path.join(content, REF_LEVEL[len("/Game/"):] + ".umap")):     # (does_asset_exist warns on maps)
        ell.load_level(REF_LEVEL)
        for a in ell.get_all_level_actors():
            if "hubref" in [str(t) for t in a.tags]:
                ell.destroy_actor(a)
    elif not ell.new_level(REF_LEVEL):
        raise RuntimeError("new_level failed: " + REF_LEVEL)
    cache, n, missing = {}, 0, set()
    for e in data["actors"]:
        if e.get("hidden") or any(s in e["mesh"] for s in SKIP_MESHES):
            continue
        mesh = cache.get(e["mesh"])
        if mesh is None:
            mesh = eal.load_asset(e["mesh"]) if eal.does_asset_exist(e["mesh"]) or e["mesh"].startswith("/Engine/") else None
            cache[e["mesh"]] = mesh or False
        if not mesh:
            missing.add(e["mesh"])
            continue
        l, r, s = e["loc"], e["rot"], e["scale"]
        a = ell.spawn_actor_from_object(mesh, unreal.Vector(l[0], l[1], l[2]), unreal.Rotator(r[2], r[0], r[1]))   # Rotator(roll, pitch, yaw)
        a.set_actor_scale3d(unreal.Vector(s[0], s[1], s[2]))
        label = e["actor"] if e["component"] in ("StaticMeshComponent0", "") and e["k"] == 0 else "%s.%s%s" % (
            e["actor"], e["component"], ("#%d" % e["k"]) if e["k"] else "")
        a.set_actor_label(label)
        a.set_folder_path("%s/%s" % (e["level"], e["class"]))
        a.tags = ["hubref", "hub_level:" + e["level"], "hub_actor:" + e["actor"]]
        smc = a.static_mesh_component
        smc.set_editor_property("cast_shadow", False)
        n += 1
    world = ell.get_editor_world()
    try:
        ws = world.get_world_settings()
        ws.set_editor_property("enable_world_bounds_checks", False)
    except Exception:
        pass
    if not ell.save_current_level():
        raise RuntimeError("save_current_level failed for " + REF_LEVEL)
    return n, sorted(missing)


def main():
    t0 = time.time()
    data = json.load(open(HUBREF))
    grid = eal.load_asset(GRID)
    stats = {}
    odd = []
    for i, (gp, m) in enumerate(sorted(data["meshes"].items())):
        try:
            r = import_mesh(gp, m, grid)
        except Exception as ex:                                     # noqa: BLE001
            r = "error %s" % ex
        k = r.split(",")[0].split(" (")[0]
        stats[k] = stats.get(k, 0) + 1
        if r not in ("imported", "kept (not a stand-in)"):
            odd.append("%s: %s" % (gp, r))
        if i % 50 == 0:
            log("mesh %d/%d %s" % (i + 1, len(data["meshes"]), gp))
    for o in odd[:40]:
        log("  " + o)
    log("stand-ins: %s" % json.dumps(stats))
    n, missing = build_reference(data)
    for m in missing[:20]:
        log("  no mesh for " + m)
    log("reference level %s: %d actors, %d meshes missing, %.0f s" % (REF_LEVEL, n, len(missing), time.time() - t0))
    log("hub reference built; next: Scripts/build_addon.py")


main()
