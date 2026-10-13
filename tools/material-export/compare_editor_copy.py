#!/usr/bin/env python3
"""Compare a material export with an editor (uncooked) copy of the same asset, e.g. the one in the ITR-SDK.

    python compare_editor_copy.py <export.json | cooked .uasset> <editor-copy .uasset> --uassetgui UAssetGUI.exe
        [--content-root DIR]

The editor copy can't be read by ue4pkg.py (it is a versioned, uncooked package), so it is converted with
UAssetGUI's command line (`UAssetGUI tojson <uasset> <json> VER_UE4_27`; get UAssetGUI from
https://github.com/atenfyr/UAssetGUI). Prints one line per difference and a MATCH / DIFFERENT verdict.

Compared: class, parent, scalar / vector / texture parameter values (by name, association and index), static
switches, active base property overrides; for masters: the parameter names the master declares. Not compared:
GUIDs, the expression graph (cooked packages don't have one), texture streaming data.
Licence: AGPL-3.0 (see ../../LICENSE).
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import material_export as me  # noqa: E402

TOL = 1e-4


def _props(lst):
    return {p["Name"]: p for p in lst or []}


def _import_path(d, idx):
    if not isinstance(idx, int) or idx == 0:
        return None
    if idx > 0:
        return d["Exports"][idx - 1]["ObjectName"]
    imp = d["Imports"][-idx - 1]
    if imp["OuterIndex"] == 0:
        return imp["ObjectName"]
    outer = d["Imports"][-imp["OuterIndex"] - 1]
    if outer["OuterIndex"] == 0:
        return outer["ObjectName"] + "." + imp["ObjectName"]
    return _import_path(d, imp["OuterIndex"]) + ":" + imp["ObjectName"]


def _info(st):
    f = _props(st["Value"])
    i = _props(f["ParameterInfo"]["Value"])
    return f, (i["Name"]["Value"], (i["Association"].get("EnumValue") or "GlobalParameter").split("::")[-1],
               i["Index"]["Value"])


def _color(o):
    if isinstance(o, dict):
        if all(k in o for k in "RGBA"):
            return [float(o[k]) for k in "RGBA"]
        for v in o.values():
            c = _color(v)
            if c:
                return c
    elif isinstance(o, list):
        for v in o:
            c = _color(v)
            if c:
                return c
    return None


def canon_uassetgui(d):
    e = next(x for x in d["Exports"] if x.get("bIsAsset") or x is d["Exports"][0])
    P = _props(e["Data"])
    cls = d["Imports"][-e["ClassIndex"] - 1]["ObjectName"] if e["ClassIndex"] < 0 else "?"
    out = {"class": cls, "parent": _import_path(d, P["Parent"]["Value"]) if "Parent" in P else None,
           "scalar": {}, "vector": {}, "texture": {}, "switches": {}, "overrides": {}}
    for kind, arr in (("scalar", "ScalarParameterValues"), ("vector", "VectorParameterValues"),
                      ("texture", "TextureParameterValues")):
        for st in (P.get(arr) or {}).get("Value") or []:
            f, key = _info(st)
            v = f["ParameterValue"]
            if kind == "scalar":
                out[kind][key] = float(str(v["Value"]).replace("+", ""))
            elif kind == "vector":
                out[kind][key] = _color(v)
            else:
                out[kind][key] = _import_path(d, v["Value"])
    sp = _props((P.get("StaticParameters") or {}).get("Value"))
    for st in (sp.get("StaticSwitchParameters") or {}).get("Value") or []:
        f, key = _info(st)
        out["switches"][key[0]] = bool(f["Value"]["Value"])
    bo = {q["Name"]: q.get("EnumValue", q.get("Value")) for q in (P.get("BasePropertyOverrides") or {}).get("Value") or []}
    for k, v in bo.items():
        if k.startswith("bOverride_") and v is True:
            out["overrides"][k[10:]] = bo.get(k[10:], me._OVERRIDE_DEFAULT.get(k[10:]))   # a missing value = default
    if cls == "Material":
        # the expression graph is in the editor copy: its parameter expressions give the declared names
        names = {"scalar": set(), "vector": set(), "texture": set()}
        for x in d["Exports"]:
            c = d["Imports"][-x["ClassIndex"] - 1]["ObjectName"] if x.get("ClassIndex", 0) < 0 else ""
            kind = ("texture" if "Texture" in c else "vector" if "Vector" in c else "scalar" if "Scalar" in c else None)
            if kind and c.startswith("MaterialExpression") and c.endswith("Parameter") or c.endswith("Parameter2D"):
                pn = _props(x["Data"]).get("ParameterName")
                if pn and kind:
                    names[kind].add(pn["Value"])
        out["declared"] = names
        out["settings"] = {k: v.get("EnumValue", v.get("Value")) for k, v in P.items()
                           if k in ("BlendMode", "ShadingModel", "TwoSided", "MaterialDomain", "bUsedWithStaticLighting",
                                    "bUsedWithInstancedStaticMeshes", "bUsedWithSplineMeshes", "DitheredLODTransition")}
        out["settings"] = {k: (v.split("::")[-1] if isinstance(v, str) else v) for k, v in out["settings"].items()}
    return out


def canon_export(x):
    out = {"class": x["class"], "parent": x.get("parent"), "scalar": {}, "vector": {}, "texture": {}, "switches": {},
           "overrides": dict(x.get("activeOverrides") or {})}
    for kind in ("scalar", "vector", "texture"):
        rows = x["parameters"].get(kind, []) if isinstance(x.get("parameters"), dict) else []
        for r in rows:
            out[kind][(r["name"], r["association"], r["index"])] = r.get("value")
    for s in x.get("staticSwitches", []):
        out["switches"][s["name"]] = s["value"]
    if x["class"] == "Material":
        out["declared"] = {k: {r["name"] for r in x["parameters"].get(k, [])} for k in ("scalar", "vector", "texture")}
        out["settings"] = dict(x.get("settings") or {})
    return out


def _eq(a, b):
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_eq(x, y) for x, y in zip(a, b))
    if isinstance(a, float) or isinstance(b, float):
        try:
            return abs(float(a) - float(b)) <= TOL
        except (TypeError, ValueError):
            return False
    if isinstance(a, str) and isinstance(b, str):
        return a == b
    return a == b


def diff(a, b):
    """a = cooked export, b = editor copy: list of difference strings."""
    out = []
    for k in ("class", "parent"):
        if a[k] != b[k]:
            out.append(f"{k}: cooked {a[k]} / editor {b[k]}")
    for kind in ("scalar", "vector", "texture"):
        for key in sorted(set(a[kind]) | set(b[kind]), key=str):
            if key not in b[kind]:
                out.append(f"{kind} {key[0]}: only in cooked ({a[kind][key]})")
            elif key not in a[kind]:
                out.append(f"{kind} {key[0]}: only in editor copy ({b[kind][key]})")
            elif not _eq(a[kind][key], b[kind][key]):
                out.append(f"{kind} {key[0]}: cooked {a[kind][key]} / editor {b[kind][key]}")
    for key in sorted(set(a["switches"]) | set(b["switches"])):
        if a["switches"].get(key) != b["switches"].get(key):
            out.append(f"switch {key}: cooked {a['switches'].get(key)} / editor {b['switches'].get(key)}")
    for key in sorted(set(a["overrides"]) | set(b["overrides"])):
        if not _eq(a["overrides"].get(key), b["overrides"].get(key)):
            out.append(f"override {key}: cooked {a['overrides'].get(key)} / editor {b['overrides'].get(key)}")
    return out


def diff_master(a, b):
    out = []
    for kind in ("scalar", "vector", "texture"):
        ca, eb = a["declared"][kind], b["declared"][kind]
        for n in sorted(ca - eb):
            out.append(f"{kind} {n}: declared by the cooked master only")
        for n in sorted(eb - ca):
            out.append(f"{kind} {n}: in the editor copy's graph only")
    # settings: a key missing on one side means the engine default
    dflt = {"BlendMode": "BLEND_Opaque", "ShadingModel": "MSM_DefaultLit", "TwoSided": False, "MaterialDomain": "MD_Surface",
            "bUsedWithStaticLighting": False, "bUsedWithInstancedStaticMeshes": False, "bUsedWithSplineMeshes": False,
            "DitheredLODTransition": False}
    for k, dv in dflt.items():
        va, vb = a["settings"].get(k, dv), b["settings"].get(k, dv)
        if va != vb:
            out.append(f"setting {k}: cooked {va} / editor {vb}")
    return out


def uassetgui_json(exe, uasset, ver="VER_UE4_27"):
    out = os.path.join(tempfile.gettempdir(), "matexport_" + str(abs(hash(uasset))) + ".json")
    subprocess.run([exe, "tojson", uasset, out, ver], capture_output=True, check=False)
    return json.load(open(out, encoding="utf-8"))


def compare(cooked, editor_uasset, exe, content_root=None):
    x = cooked if isinstance(cooked, dict) else (
        json.load(open(cooked)) if cooked.endswith(".json") else me.export_one(cooked, me.content_root_of(cooked, content_root)))
    b = canon_uassetgui(uassetgui_json(exe, editor_uasset))
    a = canon_export(x)
    if x["class"] == "Material":                # masters: declared parameter names and settings
        return diff_master(a, b)
    return diff(a, b)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cooked")
    ap.add_argument("editor")
    ap.add_argument("--uassetgui", required=True)
    ap.add_argument("--content-root")
    a = ap.parse_args()
    d = compare(a.cooked, a.editor, a.uassetgui, a.content_root)
    for line in d:
        print(line)
    print("MATCH" if not d else f"DIFFERENT ({len(d)} differences)")
    sys.exit(1 if d else 0)


if __name__ == "__main__":
    main()
