"""Recreate exported Into the Radius materials in an Unreal editor project (what was tested: see README.md).

Run inside the editor (UE 4.27, Python Editor Script Plugin on). Either from the Output Log console:

    py "C:/path/to/material_import_ue.py" "C:/path/to/exports" --dest /Game/Recreated

or File > Execute Python Script after setting the options at the top of this file, or from your own script:

    MATEXPORT_INPUT = r"C:/path/to/exports"; MATEXPORT_DEST = "/Game/Recreated"
    exec(open(r"C:/path/to/material_import_ue.py").read())

Input: one .json from `material_export.py export`, or a folder of them. Export with `--chain` to also get the
parent materials, and with `--textures` to get the texture settings.

What it does for each material instance:
  1. parent: the exported parent's path if the project has it (e.g. copied from the ITR-SDK), else a stand-in master
     built from the exported chain (same parameter names and defaults, the game's blend / shading / usage settings,
     NO expression graph: cooked packages don't have one), else --fallback-parent;
  2. creates a MaterialInstanceConstant under --dest, sets scalar, vector and texture parameters (global ones only),
     base property overrides, static switches, and updates it;
  3. a texture the project doesn't have is created as a small placeholder with the original's compression, sRGB
     and LOD group (so the sampler type matches), unless --no-placeholders.
Things the editor's Python API can't do (layer parameters, static component masks, material layer stacks) are
listed in the report instead. Static switches need the MaterialEditingLibrary function from our engine patch
(`set_material_instance_static_switch_parameter_value`, see ../../engine/); without it they are listed too.

Assets are created under --dest, not at the game's paths: an asset at the game's own path inside a pak would
shadow the game's original. Nothing is cooked or packed here.
A report goes to <project>/Saved/matexport_report.json and the Output Log.
Licence: AGPL-3.0 (see ../../LICENSE).
"""
import json
import os
import re
import struct
import sys
import tempfile
import zlib

import unreal

# ---- options (a MATEXPORT_* global set before exec() wins; command line arguments win over both) -------------------
INPUT = globals().get("MATEXPORT_INPUT", "")
DEST = globals().get("MATEXPORT_DEST", "/Game/Recreated")
FALLBACK_PARENT = globals().get("MATEXPORT_FALLBACK_PARENT", "")      # e.g. "/Game/MyMaster"
STUB_MASTERS = globals().get("MATEXPORT_STUB_MASTERS", True)
PLACEHOLDERS = globals().get("MATEXPORT_PLACEHOLDERS", True)
OVERWRITE = globals().get("MATEXPORT_OVERWRITE", False)
SAVE = globals().get("MATEXPORT_SAVE", True)

args = list(sys.argv[1:])
i = 0
rest = []
while i < len(args):
    a = args[i]
    if a == "--dest":
        DEST = args[i + 1]; i += 2
    elif a == "--fallback-parent":
        FALLBACK_PARENT = args[i + 1]; i += 2
    elif a == "--no-stubs":
        STUB_MASTERS = False; i += 1
    elif a == "--no-placeholders":
        PLACEHOLDERS = False; i += 1
    elif a == "--overwrite":
        OVERWRITE = True; i += 1
    elif a == "--no-save":
        SAVE = False; i += 1
    else:
        rest.append(a); i += 1
if rest:
    INPUT = rest[0]

eal = unreal.EditorAssetLibrary
mel = unreal.MaterialEditingLibrary
tools = unreal.AssetToolsHelpers.get_asset_tools()
SWITCHES = {}        # master package -> switch names the instances being imported set (see collect_switches)
REPORT = {"created": [], "reused": [], "stubs": [], "placeholders": [], "skipped": [], "unsupported": []}


def log(*a):
    unreal.log("[matexport] " + " ".join(str(x) for x in a))


def snake_upper(s):
    """'TwoSidedFoliage' -> 'TWO_SIDED_FOLIAGE', 'DitheredLODTransition' -> 'DITHERED_LOD_TRANSITION'."""
    return re.sub(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", "_", s).upper()


def snake(s):
    return snake_upper(s).lower()


def enum_value(enum_cls, text):
    """unreal.BlendMode.BLEND_MASKED for 'BLEND_Masked', unreal.MaterialShadingModel.MSM_TWO_SIDED_FOLIAGE ..."""
    text = str(text).split("::")[-1]
    prefix, _, rest_ = text.partition("_")
    for cand in (prefix + "_" + snake_upper(rest_), prefix + "_" + rest_.upper(), text.upper()):
        if hasattr(enum_cls, cand):
            return getattr(enum_cls, cand)
    return None


def dest_of(game_path):
    """Where an exported /Game/... object path goes under DEST (package path, no object name)."""
    pkg = game_path.split(".")[0]
    return DEST.rstrip("/") + pkg[len("/Game"):] if pkg.startswith("/Game/") else DEST.rstrip("/") + "/" + pkg.strip("/")


def exists(path):
    return eal.does_asset_exist(path.split(".")[0])


def load(path):
    return eal.load_asset(path.split(".")[0])


def ensure_folder(pkg_path):
    folder = pkg_path.rsplit("/", 1)[0]
    if not eal.does_directory_exist(folder):
        eal.make_directory(folder)


def create(pkg_path, cls, factory):
    ensure_folder(pkg_path)
    folder, name = pkg_path.rsplit("/", 1)
    return tools.create_asset(name, folder, cls, factory)


# ---- placeholder textures ---------------------------------------------------------------------------------------------
def png_bytes(rgb, size=4):
    raw = b"".join(b"\0" + bytes(rgb) * size for _ in range(size))
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def make_placeholder(tex_path, settings):
    pkg = tex_path.split(".")[0]
    if pkg.startswith("/Engine/") or exists(pkg):
        return load(pkg) if exists(pkg) else None
    settings = settings or {}
    comp = settings.get("compression", "TC_Default")
    rgb = (128, 128, 255) if comp == "TC_Normalmap" else (255, 255, 255)
    tmp = os.path.join(tempfile.gettempdir(), "matexport_placeholder_%d_%d_%d.png" % rgb)
    open(tmp, "wb").write(png_bytes(rgb))
    dest_pkg = dest_of(pkg)
    ensure_folder(dest_pkg)
    task = unreal.AssetImportTask()
    task.set_editor_property("filename", tmp)
    task.set_editor_property("destination_path", dest_pkg.rsplit("/", 1)[0])
    task.set_editor_property("destination_name", dest_pkg.rsplit("/", 1)[1])
    task.set_editor_property("automated", True)
    task.set_editor_property("replace_existing", True)
    task.set_editor_property("save", False)
    tools.import_asset_tasks([task])
    tex = eal.load_asset(dest_pkg)
    if not tex:
        REPORT["skipped"].append({"texture": tex_path, "why": "placeholder import failed"})
        return None
    cs = enum_value(unreal.TextureCompressionSettings, comp)
    if cs is not None:
        tex.set_editor_property("compression_settings", cs)
    tex.set_editor_property("srgb", bool(settings.get("srgb", True)))
    lg = enum_value(unreal.TextureGroup, settings.get("lod_group", "TEXTUREGROUP_World"))
    if lg is not None:
        tex.set_editor_property("lod_group", lg)
    REPORT["placeholders"].append(dest_pkg)
    return tex


def texture_for(tex_path, tex_settings):
    """The project's own texture at the exported path, a DEST mirror, or a placeholder."""
    if not tex_path:
        return None
    pkg = tex_path.split(".")[0]
    for cand in (pkg, dest_of(pkg)):
        if exists(cand):
            return load(cand)
    return make_placeholder(tex_path, (tex_settings or {}).get(tex_path)) if PLACEHOLDERS else None


# ---- masters ------------------------------------------------------------------------------------------------------------
def apply_master_settings(mat, st):
    pairs = (("BlendMode", "blend_mode", unreal.BlendMode), ("ShadingModel", "shading_model", unreal.MaterialShadingModel),
             ("MaterialDomain", "material_domain", unreal.MaterialDomain),
             ("TranslucencyLightingMode", "translucency_lighting_mode", unreal.TranslucencyLightingMode))
    for key, prop, enum_cls in pairs:
        if key in st:
            v = enum_value(enum_cls, st[key])
            try:
                if v is not None:
                    mat.set_editor_property(prop, v)
                else:
                    raise ValueError("enum value not found")
            except Exception as ex:
                REPORT["unsupported"].append({"setting": key, "value": st[key], "why": str(ex)[:80]})
    for key in ("TwoSided", "DitheredLODTransition", "bUsedWithStaticLighting", "bUsedWithInstancedStaticMeshes",
                "bUsedWithSplineMeshes", "bUsedWithSkeletalMesh", "bUsedWithParticleSprites", "bUseMaterialAttributes",
                "bFullyRough", "bCastRayTracedShadows"):
        if key in st:
            prop = snake(key[1:] if key.startswith("b") and key[1].isupper() else key)
            try:
                mat.set_editor_property(prop, bool(st[key]))
            except Exception as ex:
                REPORT["unsupported"].append({"setting": key, "value": st[key], "why": str(ex)[:80]})
    if "OpacityMaskClipValue" in st:
        mat.set_editor_property("opacity_mask_clip_value", float(st["OpacityMaskClipValue"]))


def build_stub_master(link, tex_settings):
    """A Material with the exported parameters (names and defaults) and settings; the graph is not recoverable."""
    out_pkg = dest_of(link["package"])
    if exists(out_pkg) and not OVERWRITE:
        return load(out_pkg)
    mat = load(out_pkg) if exists(out_pkg) else create(out_pkg, unreal.Material, unreal.MaterialFactoryNew())
    mel.delete_all_material_expressions(mat)
    apply_master_settings(mat, link.get("settings") or {})
    X = lambda cls, x, y: mel.create_material_expression(mat, cls, x, y)
    row = 0
    params = link.get("parameters") or {}
    for r in params.get("scalar", []):
        if r.get("association", "GlobalParameter") != "GlobalParameter":
            continue
        n = X(unreal.MaterialExpressionScalarParameter, -400, row * 80)
        n.set_editor_property("parameter_name", r["name"])
        n.set_editor_property("default_value", float(r.get("value", 0.0)))
        row += 1
    for r in params.get("vector", []):
        if r.get("association", "GlobalParameter") != "GlobalParameter":
            continue
        n = X(unreal.MaterialExpressionVectorParameter, -700, row * 80)
        n.set_editor_property("parameter_name", r["name"])
        v = r.get("value") or [0, 0, 0, 1]
        n.set_editor_property("default_value", unreal.LinearColor(*[float(c) for c in v]))
        row += 1
    for r in params.get("texture", []):
        if r.get("association", "GlobalParameter") != "GlobalParameter":
            continue
        n = X(unreal.MaterialExpressionTextureObjectParameter, -1000, row * 80)
        n.set_editor_property("parameter_name", r["name"])
        tex = texture_for(r.get("value"), tex_settings)
        if tex:
            n.set_editor_property("texture", tex)
        row += 1
    # Static switches are not in a cooked master's parameter list; the instances' own switch lists tell us the names.
    # An instance can only keep a switch its parent declares, so the stand-in declares them (default False: unknown).
    for sw in sorted(SWITCHES.get(link["package"], ())):
        n = X(unreal.MaterialExpressionStaticSwitchParameter, -1300, row * 80)
        n.set_editor_property("parameter_name", sw)
        n.set_editor_property("default_value", False)
        row += 1
    mel.recompile_material(mat)
    REPORT["stubs"].append(out_pkg)
    return mat


# ---- instances ----------------------------------------------------------------------------------------------------------
OVERRIDE_PROPS = {"BlendMode": ("blend_mode", unreal.BlendMode), "ShadingModel": ("shading_model", unreal.MaterialShadingModel),
                  "TwoSided": ("two_sided", None), "DitheredLODTransition": ("dithered_lod_transition", None),
                  "OpacityMaskClipValue": ("opacity_mask_clip_value", None)}
# Other overrides the game's files carry (ShouldDoForwardSSR, ...) have no property on the editor's struct and are reported.


def apply_overrides(mi, active, name):
    if not active:
        return
    bp = mi.get_editor_property("base_property_overrides")
    for key, value in active.items():
        spec = OVERRIDE_PROPS.get(key)
        if not spec:
            REPORT["unsupported"].append({"asset": name, "override": key})
            continue
        prop, enum_cls = spec
        try:
            bp.set_editor_property("override_" + prop, True)
            if value is not None:
                bp.set_editor_property(prop, enum_value(enum_cls, value) if enum_cls else value)
        except Exception as ex:
            REPORT["unsupported"].append({"asset": name, "override": key, "why": str(ex)[:80]})
    mi.set_editor_property("base_property_overrides", bp)


# EMaterialParameterAssociation as the engine numbers it: LayerParameter 0, BlendParameter 1, GlobalParameter 2
# (the patched function's own default of 0 is the LAYER one, so always pass the association).
ASSOCIATION = {"LayerParameter": 0, "BlendParameter": 1, "GlobalParameter": 2}


def set_switches(mi, switches, name):
    fn = getattr(mel, "set_material_instance_static_switch_parameter_value", None)
    for s in switches:
        if not s.get("override", True):
            continue
        if fn is None:
            REPORT["unsupported"].append({"asset": name, "switch": s["name"], "value": s["value"],
                                          "why": "no set_material_instance_static_switch_parameter_value (needs the engine patch)"})
            continue
        assoc = s.get("association", "GlobalParameter")
        try:
            ok = fn(mi, s["name"], bool(s["value"]), ASSOCIATION.get(assoc, 2), int(s.get("index", -1)))
        except Exception as ex:
            ok = False
            why = str(ex)[:80]
        else:
            why = "the parent has no switch %s (%s %s)" % (s["name"], assoc, s.get("index", -1))
        if not ok:
            REPORT["unsupported"].append({"asset": name, "switch": s["name"], "why": why})


def build_instance(link, parent, tex_settings):
    out_pkg = dest_of(link["package"])
    if exists(out_pkg) and not OVERWRITE:
        REPORT["reused"].append(out_pkg)
        return load(out_pkg)
    mi = load(out_pkg) if exists(out_pkg) else create(out_pkg, unreal.MaterialInstanceConstant,
                                                      unreal.MaterialInstanceConstantFactoryNew())
    mel.set_material_instance_parent(mi, parent)
    mel.clear_all_material_instance_parameters(mi)
    params = link.get("parameters") or {}
    for kind, rows in params.items():
        for r in rows:
            if r.get("association", "GlobalParameter") != "GlobalParameter":
                REPORT["unsupported"].append({"asset": out_pkg, "param": r["name"], "why": r["association"]})
                continue
            v = r.get("value")
            if kind == "scalar":
                mel.set_material_instance_scalar_parameter_value(mi, r["name"], float(v))
            elif kind == "vector" and v:
                mel.set_material_instance_vector_parameter_value(mi, r["name"], unreal.LinearColor(*[float(c) for c in v]))
            elif kind == "texture":
                tex = texture_for(v, tex_settings)
                if tex:
                    mel.set_material_instance_texture_parameter_value(mi, r["name"], tex)
                elif v:
                    REPORT["skipped"].append({"asset": out_pkg, "param": r["name"], "texture": v})
    apply_overrides(mi, link.get("activeOverrides"), out_pkg)
    set_switches(mi, link.get("staticSwitches") or [], out_pkg)
    for kind in ("staticComponentMasks", "materialLayers"):
        if link.get(kind):
            REPORT["unsupported"].append({"asset": out_pkg, "what": kind, "count": len(link[kind])})
    mel.update_material_instance(mi)
    REPORT["created"].append(out_pkg)
    return mi


def collect_switches(x):
    """Remember, per master, the global static switches set by this export's instance and its parents."""
    chain_by_pkg = {c["package"]: c for c in x.get("chain", [])}
    for link in [x] + list(x.get("chain", [])):
        master, hops = link, 0
        while master.get("class") != "Material" and hops < 20:
            hops += 1
            master = chain_by_pkg.get((master.get("parent") or "").split(".")[0])
            if master is None:
                break
        if master is not None and link.get("class") != "Material":
            for sw in link.get("staticSwitches") or []:
                if sw.get("association", "GlobalParameter") == "GlobalParameter":
                    SWITCHES.setdefault(master["package"], set()).add(sw["name"])


def resolve_parent(link, chain_by_pkg, tex_settings):
    """Parent asset for an instance export: the project's own, else something built from the chain, else the fallback."""
    ppath = link.get("parent")
    if not ppath:
        return None
    pkg = ppath.split(".")[0]
    if exists(pkg):
        return load(pkg)
    if exists(dest_of(pkg)):
        return load(dest_of(pkg))
    up = chain_by_pkg.get(pkg)
    if up and STUB_MASTERS:
        if up["class"] == "Material":
            return build_stub_master(up, tex_settings)
        return build_instance(up, resolve_parent(up, chain_by_pkg, tex_settings), tex_settings)
    if FALLBACK_PARENT and exists(FALLBACK_PARENT):
        REPORT["skipped"].append({"asset": link["package"], "why": f"parent {ppath} not in project, used the fallback"})
        return load(FALLBACK_PARENT)
    return None


def import_one(x):
    tex_settings = x.get("textureSettings") or {}
    chain_by_pkg = {c["package"]: c for c in x.get("chain", [])}
    if x["class"] == "Material":
        return build_stub_master(x, tex_settings) if STUB_MASTERS else None
    parent = resolve_parent(x, chain_by_pkg, tex_settings)
    if parent is None:
        REPORT["skipped"].append({"asset": x["package"], "why": "no parent (not in the project; chain not exported or "
                                  "stubs off; no --fallback-parent)"})
        return None
    return build_instance(x, parent, tex_settings)


def main():
    if not INPUT:
        raise SystemExit("set MATEXPORT_INPUT or pass the export .json / folder as the first argument")
    files = [INPUT] if os.path.isfile(INPUT) else sorted(
        os.path.join(INPUT, f) for f in os.listdir(INPUT) if f.lower().endswith(".json"))
    exports = [json.load(open(f, encoding="utf-8")) for f in files]
    exports = [x for x in exports if x.get("format") == "itr-material-export"]
    for x in exports:
        collect_switches(x)
    assets = []
    for x in exports:
        a = import_one(x)
        if a:
            assets.append(a)
    if SAVE and assets:
        eal.save_directory(DEST, only_if_is_dirty=True, recursive=True)
    report = os.path.join(unreal.Paths.project_saved_dir(), "matexport_report.json")
    json.dump(REPORT, open(report, "w"), indent=1)
    log({k: len(v) for k, v in REPORT.items()}, "report:", report)


main()
