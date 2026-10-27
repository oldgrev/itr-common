"""Reads the Hub out of YOUR copy of Into the Radius 2.7.2 for the editor-only Hub reference (run with Python 3, outside the editor).

  python export_hub.py --cue4export <cue4export.exe> [--game-content <unpacked Content dir> | --engine <UE 4.27 Engine dir>]

What it writes (all under build/hubref/, which is gitignored and never published):
  levels/<L_Hub...>/level.json   every placed mesh of the Hub levels with its world transform (cue4export level)
  meshes/...fbx                  each mesh those levels use, LOD0, with the game's simple collision (cue4export mesh)
  hubref.json                    the list import_hub.py (inside the editor) builds the stand-ins and L_HubReference from
  unpacked/                      only without --game-content: the Hub levels and the mesh folders unpacked from the game paks

The game's files are read, never changed. A mesh path that starts with /Engine/ is engine content the editor has already, so
it is not exported. Nothing from here goes into the add-on pak (build-map.ps1 packs /Game/Mods/<Name> only).
"""
import argparse
import json
import os
import shutil
import stat
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
OUT = os.path.join(PROJECT, "build", "hubref")
GAME = r"C:\Program Files (x86)\Steam\steamapps\common\IntoTheRadius"
# The Hub's streaming levels (2.7.2). The light-scenario, sound and map-point levels hold no meshes worth seeing.
LEVELS = ["L_Hub", "L_Hub_BaseBuilding", "L_Hub_Container", "L_Hub_factory", "L_Hub_landscape", "L_Hub_Gameplay", "L_Hub_ShootingRange"]


def run(cmd, what):
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode != 0:
        sys.exit("%s failed (rc %d):\n%s\n%s" % (what, r.returncode, r.stdout[-2000:], r.stderr[-2000:]))
    return r.stdout


def move(src, to):
    """os.replace that also copes with a read-only or briefly locked target (a virus scanner reading the new file)"""
    for attempt in range(10):
        try:
            if os.path.exists(to):
                os.chmod(to, stat.S_IWRITE)
                os.remove(to)
            os.replace(src, to)
            return
        except PermissionError:
            if attempt == 9:
                raise
            time.sleep(0.5)


def unpack(engine, filters, dest):
    """UnrealPak -Extract with one wildcard filter per call, over every pakchunk of the game. The paks have different mount
    points (pakchunk0 lists IntoTheRadius/Content/ART2/..., pakchunk1 lists ART2/...), so each pak is extracted into its own
    folder and the files are then moved into one Content tree: <dest>/IntoTheRadius/Content."""
    pak_tool = os.path.join(engine, "Binaries", "Win64", "UnrealPak.exe")
    paks_dir = os.path.join(GAME, "IntoTheRadius", "Content", "Paks")
    paks = sorted(os.path.join(paks_dir, f) for f in os.listdir(paks_dir) if f.startswith("pakchunk") and f.endswith(".pak"))
    content = os.path.join(dest, "IntoTheRadius", "Content")
    for i, flt in enumerate(filters):
        for pak in paks:
            tmp = os.path.join(dest, "_" + os.path.splitext(os.path.basename(pak))[0])
            subprocess.run([pak_tool, pak, "-Extract", tmp, "-Filter=" + flt], capture_output=True)
            if not os.path.isdir(tmp):
                continue
            root = os.path.join(tmp, "IntoTheRadius", "Content")
            root = root if os.path.isdir(root) else tmp
            for d, _sub, files in os.walk(root):
                for f in files:
                    to = os.path.join(content, os.path.relpath(os.path.join(d, f), root))
                    os.makedirs(os.path.dirname(to), exist_ok=True)
                    move(os.path.join(d, f), to)
            shutil.rmtree(tmp, ignore_errors=True)
        print("  unpacked %d/%d %s" % (i + 1, len(filters), flt), flush=True)
    return content


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cue4export", required=True, help="cue4export.exe (a CUE4Parse-based exporter: level and mesh commands)")
    ap.add_argument("--game-content", help="an unpacked copy of the game's Content folder (has ITR/Levels/Hub/L_Hub.umap)")
    ap.add_argument("--engine", default=r"C:\ue427\Engine", help="UE 4.27 Engine dir, for UnrealPak when --game-content is not given")
    ap.add_argument("--extra", nargs="*", default=[
        "/Game/ART2/Environment/Hub/Room/SM_Hub_Room_Interior_01_a",
        "/Game/ART2/Environment/Industrial/Container/SM_Industrial_Container_Hub_Room_01_a",
        "/Game/ART2/Environment/Hub/Door/SM_Hub_Room_Window_01_b",
        "/Game/ART2/Environment/Buildings/Ladder_Metal/SM_Ladder_Metal_350_01_a",
        "/Game/ART2/Environment/Buildings/Ladder_Metal/SM_Ladder_Metal_end_01_a"],
        help="more game meshes to make stand-ins of (default: what the example add-on places)")
    a = ap.parse_args()
    cue = a.cue4export
    os.makedirs(OUT, exist_ok=True)

    content = a.game_content
    if not content:
        print("unpacking the Hub levels from the game paks (read only) ...", flush=True)
        content = unpack(a.engine, ["*ITR/Levels/Hub/*"], os.path.join(OUT, "unpacked"))
    if not os.path.isfile(os.path.join(content, "ITR", "Levels", "Hub", "L_Hub.umap")):
        sys.exit("no ITR/Levels/Hub/L_Hub.umap under %s" % content)
    if not a.game_content:
        # Blueprint prefabs placed in the Hub (the factory hall, gates, shelves...) keep their meshes in the Blueprint
        # package: unpack those, and their parent Blueprints, before reading the levels
        todo = ["/Game/ITR/Levels/Hub/" + lv for lv in LEVELS]
        seen, done_dirs = set(todo), set()
        for _round in range(6):
            bps = set()
            for pkg in todo:
                rel = pkg[len("/Game/"):]
                if not any(os.path.isfile(os.path.join(content, rel + e)) for e in (".umap", ".uasset")):
                    continue
                out = subprocess.run([cue, "imports", "Content/" + rel, "--root", content], capture_output=True, text=True,
                                     encoding="utf-8", errors="replace").stdout
                for line in out.splitlines():
                    if line.startswith("BlueprintGeneratedClass /Game/"):
                        bps.add(line.split()[1].split(".")[0])
            todo = sorted(bps - seen)
            seen |= bps
            if not todo:
                break
            dirs = sorted({p.rsplit("/", 1)[0] for p in todo} - done_dirs)
            done_dirs |= set(dirs)
            print("Blueprint classes, round %d: %d new, unpacking %d folders" % (_round + 1, len(todo), len(dirs)), flush=True)
            unpack(a.engine, ["*%s/*" % d[len("/Game/"):] for d in dirs], os.path.join(OUT, "unpacked"))

    actors, used = [], set(a.extra)
    for lv in LEVELS:
        if not os.path.isfile(os.path.join(content, "ITR", "Levels", "Hub", lv + ".umap")):
            print("  %s: not in this game version, skipped" % lv)
            continue
        out_dir = os.path.join(OUT, "levels")
        run([cue, "level", "Content/ITR/Levels/Hub/" + lv, "--out", out_dir, "--root", content], "cue4export level " + lv)
        j = json.load(open(os.path.join(out_dir, lv, "level.json"), encoding="utf-8"))
        n = 0
        for act in j["actors"]:
            for c in act.get("components", []):
                m = c.get("mesh")
                if not m:
                    continue
                if m.startswith("/Game/Engine/"):                   # cue4export names engine content /Game/Engine/...
                    m = "/Engine/" + m[len("/Game/Engine/"):]
                used.add(m)
                for k, t in enumerate(c.get("instances") or [c["world"]]):
                    actors.append({"level": lv, "actor": act["name"], "class": act["class"], "component": c["name"], "k": k, "mesh": m,
                                   "loc": t["loc"], "rot": t["rot_pyr"], "scale": t["scale"],
                                   "hidden": (not c.get("visible", True)) or bool(c.get("hiddenInGame"))})
                    n += 1
        print("  %s: %d placed meshes" % (lv, n), flush=True)

    game_meshes = sorted(m for m in used if m.startswith("/Game/"))
    if not a.game_content:
        folders = sorted({m.rsplit("/", 1)[0] for m in game_meshes})
        print("unpacking %d mesh folders (read only) ..." % len(folders), flush=True)
        unpack(a.engine, ["*%s/*" % f[len("/Game/"):] for f in folders], os.path.join(OUT, "unpacked"))
    lst = os.path.join(OUT, "meshes.txt")
    open(lst, "w", encoding="utf-8").write("\n".join(game_meshes) + "\n")
    mesh_out = os.path.join(OUT, "meshes")
    # cue4export mesh <paths...>: write in batches (command line length)
    for i in range(0, len(game_meshes), 150):
        run([cue, "mesh"] + game_meshes[i:i + 150] + ["--level", "hub", "--out", mesh_out, "--root", content], "cue4export mesh")
    mf = json.load(open(os.path.join(mesh_out, "hub", "manifest.json"), encoding="utf-8"))
    meshes, failed = {}, []
    for m in game_meshes:
        e = mf.get(m) or {}
        if not e.get("file"):
            failed.append("%s (%s)" % (m, e.get("error", "not exported")))
            continue
        meshes[m] = {"fbx": os.path.join(mesh_out, "hub", e["file"]).replace("\\", "/"), "slots": e.get("slots", []),
                     "bounds": e.get("bounds"), "lightmap_index": (e.get("meta") or {}).get("lightMapCoordinateIndex", 1)}
    json.dump({"levels": LEVELS, "content": content, "meshes": meshes, "actors": actors}, open(os.path.join(OUT, "hubref.json"), "w"), indent=0)
    print("hubref.json: %d placed meshes, %d stand-in meshes, %d engine meshes, %d failed" % (
        len(actors), len(meshes), len([m for m in used if m.startswith("/Engine/")]), len(failed)))
    for f in failed:
        print("  FAILED " + f)
    print("next: in the editor, Scripts/import_hub.py")


if __name__ == "__main__":
    main()
