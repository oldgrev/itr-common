# Builds ITRMapLoader's Blueprints (BP_ITRMapEntry, BP_ITRMapManager, BP_ITRTrigger, later BP_ITRRegions) and the level L_ITRMapLoader that keeps them in the pak. Run it inside the
# editor of the ITR Showcase project (the project that has the ItrShowcaseEditor plugin, BPGen): File > Execute Python Script, or `py "<full path of this file>"` in the Python console.
# Run `python gen_entry.py`, `python gen_trigger.py` (and `python gen_regions.py`) first: they write ../Specs. An existing /Game/Mods/ITRMapLoader is rebuilt in place.
import os

import unreal

HERE = os.path.dirname(os.path.abspath(__file__))
SPECS = os.path.abspath(os.path.join(HERE, "..", "Specs"))
DIR = "/Game/Mods/ITRMapLoader"
LEVEL = DIR + "/L_ITRMapLoader"
NAMES = ["BP_ITRMapEntry", "BP_ITRMapManager", "BP_ITRTrigger"] + [n for n in ("BP_ITRRegions",) if os.path.exists(os.path.join(SPECS, n + ".json"))]
eal = unreal.EditorAssetLibrary
ell = unreal.EditorLevelLibrary


def gen(name):
    report = unreal.ItrShowcaseBPGen.generate_blueprint_from_spec(SPECS + "/" + name + ".json")
    for line in report.splitlines()[:150]:
        unreal.log("BPGEN " + line)
    if not report.startswith("OK"):
        raise RuntimeError("generation failed for " + name + ": " + report.splitlines()[0])


def main():
    if eal.does_asset_exist(DIR + "/BP_ITRTriggerBind"):
        eal.delete_asset(DIR + "/BP_ITRTriggerBind")
    for n in NAMES:
        gen(n)
    if eal.does_asset_exist(LEVEL):
        ell.load_level(LEVEL)
        for old in ell.get_all_level_actors():
            ell.destroy_actor(old)
    elif not ell.new_level(LEVEL):
        raise RuntimeError("cannot create " + LEVEL)
    for n in NAMES:
        a = ell.spawn_actor_from_object(unreal.load_asset(DIR + "/" + n), unreal.Vector(0, 0, 0), unreal.Rotator(0, 0, 0))
        if a is None:
            raise RuntimeError("spawn failed for " + n)
        a.set_actor_label(n)
    if not ell.save_current_level():
        raise RuntimeError("save of " + LEVEL + " failed")
    unreal.log("LOADER built " + ", ".join(NAMES))


main()
