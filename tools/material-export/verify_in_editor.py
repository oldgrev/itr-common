"""Check what material_import_ue.py made against the exports it was given. Run it in a FRESH editor session, so the
assets are read back from the saved .uasset files:

    py "C:/path/verify_in_editor.py" "C:/path/to/exports" --dest /Game/Recreated

Per exported material it compares, with the recreated asset under --dest:
  instance: parent, every global scalar / vector / texture parameter value, static switches, base property overrides
            (the ones that were really on in the game, and that no others are on), and that no extra parameters crept in;
  master:   the parameter names and defaults of the stand-in, and the blend / shading / domain / two-sided settings;
  texture:  the placeholder's compression, sRGB and LOD group, for every texture in the export's textureSettings.
Layer / blend parameters, material layer stacks and static component masks aren't set by the importer, so aren't compared.
Writes <project>/Saved/matverify_report.json and logs a summary; mismatches are listed one per line as "MISMATCH".
Licence: AGPL-3.0 (see ../../LICENSE).
"""
import json
import os
import re
import sys

import unreal

DEST = "/Game/Recreated"
args = list(sys.argv[1:])
INPUT = ""
i = 0
while i < len(args):
    if args[i] == "--dest":
        DEST = args[i + 1]; i += 2
    else:
        INPUT = args[i]; i += 1

eal = unreal.EditorAssetLibrary
mel = unreal.MaterialEditingLibrary
OK, BAD, NOTE = [], [], []


def snake_upper(s):
    return re.sub(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", "_", s).upper()


def enum_value(enum_cls, text):
    text = str(text).split("::")[-1]
    prefix, _, rest_ = text.partition("_")
    for cand in (prefix + "_" + snake_upper(rest_), prefix + "_" + rest_.upper(), text.upper()):
        if hasattr(enum_cls, cand):
            return getattr(enum_cls, cand)
    return None


def dest_of(game_path):
    pkg = game_path.split(".")[0]
    return DEST.rstrip("/") + pkg[len("/Game"):] if pkg.startswith("/Game/") else DEST.rstrip("/") + "/" + pkg.strip("/")


def want_tex(path):
    """/Engine textures stay where they are; the importer mirrors game textures under --dest."""
    return path.split(".")[0] if path.startswith("/Engine/") else dest_of(path)


def pkg_of(obj):
    return obj.get_path_name().split(".")[0] if obj else None


def check(what, want, got, tol=0.0):
    if isinstance(want, float) or isinstance(got, float):
        good = abs(float(want) - float(got)) <= max(tol, 1e-6 * abs(float(want)))
    else:
        good = want == got
    (OK if good else BAD).append("%s: want %r got %r" % (what, want, got) if not good else what)
    if not good:
        unreal.log_warning("[matverify] MISMATCH %s: want %r got %r" % (what, want, got))


def is_global(r):
    return r.get("association", "GlobalParameter") == "GlobalParameter"


def verify_instance(x):
    name = x["package"]
    mi = eal.load_asset(dest_of(name))
    if not mi:
        check(name + " exists", True, False)
        return
    check(name + " parent", dest_of(x["parent"]) if x.get("parent") else None, pkg_of(mi.get_editor_property("parent")))
    P = x.get("parameters") or {}
    gl = {k: [r for r in P.get(k, []) if is_global(r)] for k in ("scalar", "vector", "texture")}
    for r in gl["scalar"]:
        got = mel.get_material_instance_scalar_parameter_value(mi, r["name"])
        got = got[1] if isinstance(got, tuple) else got
        check("%s scalar %s" % (name, r["name"]), float(r["value"]), got)
    for r in gl["vector"]:
        got = mel.get_material_instance_vector_parameter_value(mi, r["name"])
        got = got[1] if isinstance(got, tuple) else got
        for ch, w, g in zip("rgba", r["value"], (got.r, got.g, got.b, got.a)):
            check("%s vector %s.%s" % (name, r["name"], ch), float(w), g)
    for r in gl["texture"]:
        got = mel.get_material_instance_texture_parameter_value(mi, r["name"])
        got = got[1] if isinstance(got, tuple) else got
        check("%s texture %s" % (name, r["name"]), want_tex(r["value"]) if r.get("value") else None, pkg_of(got))
    for kind, prop in (("scalar", "scalar_parameter_values"), ("vector", "vector_parameter_values"),
                       ("texture", "texture_parameter_values")):
        check("%s number of %s overrides" % (name, kind), len(gl[kind]), len(mi.get_editor_property(prop)))
    for s in x.get("staticSwitches") or []:
        if not is_global(s) or not s.get("override", True):
            continue
        got = mel.get_material_instance_static_switch_parameter_value(mi, s["name"])
        got = got[-1] if isinstance(got, tuple) else got
        check("%s switch %s" % (name, s["name"]), bool(s["value"]), bool(got))
    bp = mi.get_editor_property("base_property_overrides")
    active = x.get("activeOverrides") or {}
    for key, prop, cls in (("BlendMode", "blend_mode", unreal.BlendMode),
                           ("ShadingModel", "shading_model", unreal.MaterialShadingModel),
                           ("TwoSided", "two_sided", None), ("DitheredLODTransition", "dithered_lod_transition", None),
                           ("OpacityMaskClipValue", "opacity_mask_clip_value", None)):
        on = bool(bp.get_editor_property("override_" + prop))
        check("%s override %s on" % (name, key), key in active, on)
        if key in active and on:
            want = enum_value(cls, active[key]) if cls else active[key]
            check("%s override %s value" % (name, key), want, bp.get_editor_property(prop))
    for key in active:
        if key not in ("BlendMode", "ShadingModel", "TwoSided", "DitheredLODTransition", "OpacityMaskClipValue"):
            NOTE.append("%s override %s: not settable from Python" % (name, key))


def verify_master(x):
    name = x["package"]
    m = eal.load_asset(dest_of(name))
    if not m:
        check(name + " exists", True, False)
        return
    P = x.get("parameters") or {}
    for kind, names_fn, default_fn in (
            ("scalar", mel.get_scalar_parameter_names, mel.get_material_default_scalar_parameter_value),
            ("vector", mel.get_vector_parameter_names, mel.get_material_default_vector_parameter_value),
            ("texture", mel.get_texture_parameter_names, mel.get_material_default_texture_parameter_value)):
        rows = [r for r in P.get(kind, []) if is_global(r)]
        got_names = set(str(n) for n in names_fn(m))
        want_names = set(r["name"] for r in rows)
        # a stand-in also carries parameters the instances use but the master's cached list doesn't have
        check("%s %s parameters missing" % (name, kind), [], sorted(want_names - got_names))
        for r in rows:
            if r["name"] not in got_names:
                continue
            d = default_fn(m, r["name"])
            d = d[1] if isinstance(d, tuple) else d
            if kind == "scalar":
                check("%s default %s" % (name, r["name"]), float(r["value"]), d)
            elif kind == "vector" and r.get("value"):
                for ch, w, g in zip("rgba", r["value"], (d.r, d.g, d.b, d.a)):
                    check("%s default %s.%s" % (name, r["name"], ch), float(w), g)
            elif kind == "texture" and r.get("value"):
                if not r["value"].startswith("/Engine/") or eal.does_asset_exist(r["value"]):
                    check("%s default %s" % (name, r["name"]), want_tex(r["value"]), pkg_of(d))
    st = x.get("settings") or {}
    for key, prop, cls in (("BlendMode", "blend_mode", unreal.BlendMode),
                           ("ShadingModel", "shading_model", unreal.MaterialShadingModel),
                           ("MaterialDomain", "material_domain", unreal.MaterialDomain),
                           ("TranslucencyLightingMode", "translucency_lighting_mode", unreal.TranslucencyLightingMode)):
        if key in st:
            check("%s %s" % (name, key), enum_value(cls, st[key]), m.get_editor_property(prop))
    if "TwoSided" in st:
        check(name + " TwoSided", bool(st["TwoSided"]), m.get_editor_property("two_sided"))
    if "OpacityMaskClipValue" in st:
        check(name + " OpacityMaskClipValue", float(st["OpacityMaskClipValue"]), m.get_editor_property("opacity_mask_clip_value"), 1e-5)


def verify_texture(path, s):
    if not s or "error" in s or s.get("class") != "Texture2D":
        return
    t = eal.load_asset(dest_of(path)) if eal.does_asset_exist(dest_of(path)) else None
    if not t:
        return                                                      # the project had a texture there
    check("%s compression" % path, enum_value(unreal.TextureCompressionSettings, s["compression"]), t.get_editor_property("compression_settings"))
    check("%s sRGB" % path, bool(s["srgb"]), bool(t.get_editor_property("srgb")))
    check("%s lod group" % path, enum_value(unreal.TextureGroup, s["lod_group"]), t.get_editor_property("lod_group"))


def main():
    files = [INPUT] if os.path.isfile(INPUT) else sorted(
        os.path.join(INPUT, f) for f in os.listdir(INPUT) if f.lower().endswith(".json"))
    seen = set()
    for f in files:
        x = json.load(open(f, encoding="utf-8"))
        if x.get("format") != "itr-material-export":
            continue
        for link in [x] + list(x.get("chain", [])):
            if link["package"] in seen:
                continue
            seen.add(link["package"])
            (verify_master if link["class"] == "Material" else verify_instance)(link)
        for t, s in (x.get("textureSettings") or {}).items():
            if t not in seen:
                seen.add(t)
                verify_texture(t, s)
    report = os.path.join(unreal.Paths.project_saved_dir(), "matverify_report.json")
    json.dump({"ok": len(OK), "mismatch": BAD, "notes": NOTE, "checked": sorted(seen)},
              open(report, "w"), indent=1)
    unreal.log("[matverify] %d checks match, %d mismatch, %d notes. report: %s" % (len(OK), len(BAD), len(NOTE), report))


main()
