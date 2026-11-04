# Builds BP_ITRTriggerBind (logic only) and the one-actor level that keeps it in the pak, in a project that has the ItrShowcaseEditor
# plugin (BPGen): the ITR Showcase project. Run in the editor (its Python 3.7):
#   tools\itr\itr.cmd editor-run <this file> --task <id> --foreground --allow-unsaved
# The Blueprint is deleted and generated again each run (BPGen cannot rebuild one in place that has components; this one has none, but
# placed copies of an older version are not worth keeping). A Map asset cannot be deleted, so a rerun keeps the level.
import json
import os
import sys

import unreal

sys.path.insert(0, os.environ["ITR_TOOLS"])
import editor_lib as L  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = os.environ.get("ITR_SPEC_FILE") or os.path.abspath(os.path.join(HERE, "..", "Specs", "BP_ITRTriggerBind.json"))   # ITR_SPEC_FILE: a variant spec
LEVEL = "/Game/Mods/ITRMapLoader/L_ITRMapLoader"
ACTOR_NAME = "ITRTriggerBind"
eal = unreal.EditorAssetLibrary
ell = unreal.EditorLevelLibrary


def main():
    spec = json.load(open(SPEC))
    asset = spec["asset"]
    if eal.does_asset_exist(asset):
        if not eal.delete_asset(asset):
            raise RuntimeError("cannot delete " + asset)
        unreal.SystemLibrary.collect_garbage()
    report = unreal.ItrShowcaseBPGen.generate_blueprint_from_spec(SPEC)
    for line in report.splitlines()[:120]:
        L.log("BPGEN", line)
    if not report.startswith("OK"):
        raise RuntimeError("generation failed: " + report.splitlines()[0])
    bp = unreal.load_asset(asset)
    if eal.does_asset_exist(LEVEL):
        ell.load_level(LEVEL)
        for a in ell.get_all_level_actors():
            if str(a.get_actor_label()) == ACTOR_NAME:
                a.rename("DEAD_bind")
                ell.destroy_actor(a)
        unreal.SystemLibrary.collect_garbage()
    else:
        if not ell.new_level(LEVEL):
            raise RuntimeError("cannot create " + LEVEL)
    a = ell.spawn_actor_from_object(bp, unreal.Vector(0, 0, 0), unreal.Rotator(0, 0, 0))
    if a is None:
        raise RuntimeError("spawn failed")
    a.set_actor_label(ACTOR_NAME)
    if not ell.save_current_level():
        raise RuntimeError("save of " + LEVEL + " failed")
    L.log("BIND", "built", asset, "and", LEVEL)


main()
