#!/usr/bin/env python3
"""Describe a cooked Into the Radius 1 (2.7.2) material or material instance as JSON.

The JSON is what `material_import_ue.py` (an Unreal editor Python script) uses to recreate a material instance in
your project: parent, parameter values, static switches, base property overrides and the settings of every texture
it uses. A cooked master material has no expression graph left in it (the cooker strips it), so for a master the
JSON holds its settings and its parameter names, defaults and referenced textures: enough to build a stand-in
master with the same parameters, not the original shader logic.

    python material_export.py export <file.uasset|dir> [...] --out out_dir [--content-root DIR] [--chain] [--textures]
    python material_export.py list   <dir> [--static] [--class MaterialInstanceConstant|Material]
    python material_export.py show   <file.uasset>            (one material, as readable text)

  --content-root DIR  the folder that is /Game/ (the unpacked game's IntoTheRadius/Content). Guessed from the path
                      if it contains a "Content" folder. Needed for --chain and --textures.
  --chain             also export every parent up to the master (the ones inside /Game/), as "chain" in the file,
                      plus "effective": the parameter values the instance ends up with after inheritance.
  --textures          read compression / sRGB / LOD group of every texture used, from the texture packages.

Reads .uasset + .uexp files you have unpacked yourself (repak, UnrealPak, ...). It writes only JSON: no game
assets are copied. Needs Python 3.8+ and nothing else.
Licence: AGPL-3.0 (see ../../LICENSE).
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ue4pkg  # noqa: E402

FORMAT = "itr-material-export"
VERSION = 1
CLASSES = ("MaterialInstanceConstant", "Material")
KINDS = (("scalar", "ScalarParameterValues", "ParameterValue"),
         ("vector", "VectorParameterValues", "ParameterValue"),
         ("texture", "TextureParameterValues", "ParameterValue"))
# order of FMaterialCachedParameters::RuntimeEntries in 4.27
CACHED_KINDS = ("scalar", "vector", "texture", "font", "runtimevirtualtexture")
_OVERRIDE_DEFAULT = {"BlendMode": "BLEND_Opaque", "ShadingModel": "MSM_DefaultLit", "TwoSided": False,
                     "DitheredLODTransition": False, "OpacityMaskClipValue": 0.3333}
SETTING_SKIP = ("StateId", "TextureStreamingData", "CachedExpressionData", "PhysMaterial", "ParameterGroupData")


def content_root_of(path, given=None):
    if given:
        return os.path.abspath(given)
    p = os.path.abspath(path)
    while True:
        parent, tail = os.path.split(p)
        if tail == "Content":
            return p
        if parent == p:
            return None
        p = parent


def game_path(path, root):
    """'/Game/Dir/Name' for a file below the content root."""
    rel = os.path.relpath(os.path.splitext(os.path.abspath(path))[0], root).replace("\\", "/")
    return "/Game/" + rel


def file_of(pkg_path, root):
    """Disk path of '/Game/Dir/Name[.Name]' below the content root (no extension), or None."""
    if not pkg_path or not pkg_path.startswith("/Game/") or not root:
        return None
    return os.path.join(root, pkg_path.split(".")[0][len("/Game/"):].replace("/", os.sep))


def _color(v):
    return [round(float(x), 6) for x in v] if isinstance(v, (tuple, list)) and len(v) == 4 else v


def _param_info(info):
    info = info if isinstance(info, dict) else {}
    return {"name": info.get("Name"), "association": info.get("Association", "GlobalParameter"),
            "index": info.get("Index", -1)}


def _entry(kind, st):
    out = _param_info(st.get("ParameterInfo"))
    v = st.get("ParameterValue")
    out["value"] = _color(v) if kind == "vector" else (round(float(v), 6) if kind == "scalar" else v)
    return out


def _cached_parameters(ced):
    """Defaults of a master's parameters from CachedExpressionData.Parameters (4.27 layout)."""
    params = ced.get("Parameters") or {}
    out, unmatched = {}, []
    values = {"scalar": params.get("ScalarValues"), "vector": params.get("VectorValues"),
              "texture": params.get("TextureValues")}
    for k, kind in enumerate(CACHED_KINDS):
        ent = params.get("RuntimeEntries" if k == 0 else f"RuntimeEntries[{k}]")
        if not isinstance(ent, dict):
            continue
        infos = ent.get("ParameterInfos") or []
        vals = values.get(kind) or []
        if kind not in values:
            if infos:
                unmatched.append(kind)
            continue
        rows = []
        for i, info in enumerate(infos):
            row = _param_info(info)
            if i < len(vals):
                row["value"] = _color(vals[i]) if kind == "vector" else (
                    round(float(vals[i]), 6) if kind == "scalar" else vals[i])
            rows.append(row)
        out[kind] = rows
    if unmatched:
        out["_unsupported"] = unmatched
    return out


def describe(pkg, path, root=None):
    """The JSON description of the asset export of a package."""
    idx = next((i for i, e in enumerate(pkg.exports) if e.is_asset), 0)
    e = pkg.exports[idx]
    cls = pkg.class_name(e)
    if cls not in CLASSES:
        raise ValueError(f"{os.path.basename(path)}: a {cls}, not a Material or MaterialInstanceConstant")
    P = pkg.properties(idx)
    pkgpath = game_path(path, root) if root else None
    out = {"format": FORMAT, "version": VERSION, "package": pkgpath, "name": e.name, "class": cls}
    out["parent"] = P.get("Parent") if cls == "MaterialInstanceConstant" else None
    out["physMaterial"] = P.get("PhysMaterial")
    notes = []
    if cls == "MaterialInstanceConstant":
        out["hasStaticPermutation"] = bool(P.get("bHasStaticPermutationResource"))
        bo = dict(P.get("BasePropertyOverrides") or {})
        out["baseOverrides"] = bo
        # Only a bOverride_X flag that is true makes X an override; the stored values next to it are not
        # overrides on their own (the cooker writes a few non-default values, e.g. BlendMode, either way).
        out["activeOverrides"] = {k[len("bOverride_"):]: bo.get(k[len("bOverride_"):], _OVERRIDE_DEFAULT.get(k[len("bOverride_"):]))
                                  for k, v in bo.items() if k.startswith("bOverride_") and v is True}
        out["parameters"] = {kind: [_entry(kind, st) for st in P.get(arr) or []] for kind, arr, _ in KINDS}
        sp = P.get("StaticParameters") or {}
        out["staticSwitches"] = [dict(_param_info(s.get("ParameterInfo")), value=bool(s.get("Value")),
                                      override=bool(s.get("bOverride", True)))
                                 for s in sp.get("StaticSwitchParameters") or []]
        out["staticComponentMasks"] = [
            dict(_param_info(s.get("ParameterInfo")), r=bool(s.get("R")), g=bool(s.get("G")), b=bool(s.get("B")),
                 a=bool(s.get("A")), override=bool(s.get("bOverride", True)))
            for s in sp.get("StaticComponentMaskParameters") or []]
        out["materialLayers"] = [dict(_param_info(m.get("ParameterInfo")), layers=(m.get("Value") or {}).get("Layers", []),
                                      blends=(m.get("Value") or {}).get("Blends", []),
                                      states=(m.get("Value") or {}).get("LayerStates", []))
                                 for m in sp.get("MaterialLayersParameters") or []]
        if out["materialLayers"]:
            notes.append("material layer stack: exported for reference; the import script can't set it (no Python API)")
        if sp.get("TerrainLayerWeightParameters"):
            notes.append("TerrainLayerWeightParameters present, not exported")
        for extra in ("FontParameterValues", "RuntimeVirtualTextureParameterValues"):
            if P.get(extra):
                notes.append(f"{extra}: present, not exported")
        if isinstance(P.get("CachedLayerParameters"), dict):
            out["cachedLayerParameters"] = _cached_parameters({"Parameters": P["CachedLayerParameters"]})
        out["referencedTextures"] = P.get("CachedReferencedTextures") or []
    else:
        out["settings"] = {k: v for k, v in P.items()
                           if k not in SETTING_SKIP and isinstance(v, (bool, int, float, str))}
        ced = P.get("CachedExpressionData") or {}
        out["parameters"] = _cached_parameters(ced) if isinstance(ced, dict) else {}
        out["referencedTextures"] = ced.get("ReferencedTextures") or [] if isinstance(ced, dict) else []
        out["functions"] = sorted({i["Function"] for i in (ced.get("FunctionInfos") or [])
                                   if isinstance(i, dict) and isinstance(i.get("Function"), str)})             if isinstance(ced, dict) else []
        notes.append("master material: expression graph is not in cooked packages; settings and parameter "
                     "defaults only")
    if notes:
        out["notes"] = notes
    return out


def texture_settings(tex_path, root):
    """{compression, srgb, lod_group, mip_gen, ...} from a cooked Texture2D package, or None if not found."""
    f = file_of(tex_path, root)
    if not f or not os.path.exists(f + ".uasset"):
        return None
    try:
        pkg = ue4pkg.Package(f + ".uasset")
        idx = next(i for i, e in enumerate(pkg.exports) if e.is_asset)
        cls = pkg.class_name(pkg.exports[idx])
        P = pkg.properties(idx)
    except Exception as ex:                                        # a texture type we can't read
        return {"error": str(ex)[:100]}
    return {"class": cls, "compression": P.get("CompressionSettings", "TC_Default"),
            "srgb": P.get("SRGB", True), "lod_group": P.get("LODGroup", "TEXTUREGROUP_World"),
            "mip_gen": P.get("MipGenSettings"), "address_x": P.get("AddressX"), "address_y": P.get("AddressY"),
            "never_stream": P.get("NeverStream", False), "flip_green": P.get("bFlipGreenChannel", False)}


def used_textures(d):
    s = set(d.get("referencedTextures") or [])
    for row in (d.get("parameters") or {}).get("texture", []) if isinstance(d.get("parameters"), dict) else []:
        if isinstance(row.get("value"), str):
            s.add(row["value"])
    return {t for t in s if t and not t.startswith("/Engine/")}


def effective(chain):
    """Parameter values after inheritance: master defaults first, then each instance from the master down."""
    eff = {"scalar": {}, "vector": {}, "texture": {}}
    for d in reversed(chain):
        params = d.get("parameters") or {}
        for kind in eff:
            for row in params.get(kind, []):
                if "value" in row and row.get("name") is not None:
                    key = (row["name"], row.get("association", "GlobalParameter"), row.get("index", -1))
                    eff[kind]["%s|%s|%s" % key] = {"name": row["name"], "association": key[1], "index": key[2],
                                                   "value": row["value"], "from": d.get("name")}
    switches = {}
    for d in reversed(chain):
        for s in d.get("staticSwitches", []):
            if s.get("override", True):
                switches[s["name"]] = {"value": s["value"], "from": d.get("name")}
    overrides = {}
    for d in reversed(chain):
        for k, v in (d.get("activeOverrides") or {}).items():
            overrides[k] = {"value": v, "from": d.get("name")}
    return {"parameters": {k: list(v.values()) for k, v in eff.items()}, "staticSwitches": switches,
            "baseOverrides": overrides}


def export_one(path, root, chain=False, textures=False):
    pkg = ue4pkg.Package(path)
    d = describe(pkg, path, root)
    if chain:
        links, seen, cur = [d], {d["package"]}, d
        while cur.get("parent"):
            ppkg = cur["parent"].split(".")[0]
            f = file_of(ppkg, root)
            if ppkg in seen or not f or not os.path.exists(f + ".uasset"):
                cur_missing = ppkg
                d.setdefault("notes", []).append(f"parent not found below the content root: {cur_missing}")
                break
            seen.add(ppkg)
            cur = describe(ue4pkg.Package(f + ".uasset"), f + ".uasset", root)
            links.append(cur)
        d["chain"] = links[1:]
        d["effective"] = effective(links)
        all_links = links
    else:
        all_links = [d]
    if textures:
        tex = {}
        for link in all_links:
            for t in used_textures(link):
                if t not in tex:
                    tex[t] = texture_settings(t, root)
        d["textureSettings"] = tex
    return d


def find_assets(paths):
    for p in paths:
        if os.path.isdir(p):
            for dp, _, fs in os.walk(p):
                for f in sorted(fs):
                    if f.lower().endswith(".uasset"):
                        yield os.path.join(dp, f)
        else:
            yield p


def cmd_export(a):
    files = list(find_assets(a.paths))
    out_dir = a.out
    single_file = out_dir and out_dir.lower().endswith(".json") and len(files) == 1
    if out_dir and not single_file:
        os.makedirs(out_dir, exist_ok=True)
    n = bad = 0
    for f in files:
        root = content_root_of(f, a.content_root)
        if (a.chain or a.textures) and not root:
            sys.exit("--chain / --textures need --content-root (no 'Content' folder found in the path)")
        try:
            d = export_one(f, root, a.chain, a.textures)
        except ValueError as ex:
            if a.skip_errors or os.path.isdir(a.paths[0]):
                bad += 1
                continue
            sys.exit(str(ex))
        text = json.dumps(d, indent=1, default=repr)
        if not out_dir:
            print(text)
        else:
            target = out_dir if single_file else os.path.join(out_dir, os.path.splitext(os.path.basename(f))[0] + ".json")
            open(target, "w", encoding="utf-8").write(text)
        n += 1
    print(f"{n} exported, {bad} skipped (not materials)", file=sys.stderr)


def cmd_list(a):
    for f in find_assets(a.paths):
        try:
            pkg = ue4pkg.Package(f)
            e = next(e for e in pkg.exports if e.is_asset)
            cls = pkg.class_name(e)
            if cls not in CLASSES or (a.cls and cls != a.cls):
                continue
            if a.static and "bHasStaticPermutationResource" not in pkg.names:
                continue
            P = pkg.properties(pkg.exports.index(e))
            parent = (P.get("Parent") or "").split(".")[-1]
            sw = len((P.get("StaticParameters") or {}).get("StaticSwitchParameters") or [])
            counts = "/".join(str(len(P.get(k) or [])) for k in
                              ("ScalarParameterValues", "VectorParameterValues", "TextureParameterValues"))
            print(f"{cls:26s} {e.name:48s} parent={parent:32s} s/v/t={counts} switches={sw} {f}")
        except Exception:
            continue


def cmd_show(a):
    root = content_root_of(a.path, a.content_root)
    d = export_one(a.path, root, chain=bool(root), textures=False)
    print(json.dumps(d, indent=1, default=repr))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("export")
    e.add_argument("paths", nargs="+")
    e.add_argument("--out")
    e.add_argument("--content-root")
    e.add_argument("--chain", action="store_true")
    e.add_argument("--textures", action="store_true")
    e.add_argument("--skip-errors", action="store_true")
    e.set_defaults(fn=cmd_export)
    l = sub.add_parser("list")
    l.add_argument("paths", nargs="+")
    l.add_argument("--static", action="store_true", help="only instances with a static permutation")
    l.add_argument("--class", dest="cls", choices=CLASSES)
    l.set_defaults(fn=cmd_list)
    s = sub.add_parser("show")
    s.add_argument("path")
    s.add_argument("--content-root")
    s.set_defaults(fn=cmd_show)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
