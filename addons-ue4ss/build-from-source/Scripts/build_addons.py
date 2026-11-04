# Builds BP_ITRLevelAddon and BP_ITRLevelAddons (logic only) and the level L_ITRLevelAddons that keeps them in the pak. Run it inside the editor of the ITR Showcase project
# (the project that has the ItrShowcaseEditor plugin, BPGen): File > Execute Python Script, or `py "<full path of this file>"` in the Python console.
# Run `python gen_addons.py` first (it writes ../Specs). If /Game/Mods/ITRLevelAddons exists, its two Blueprints and the level are rebuilt in place.
import os

import unreal

HERE = os.path.dirname(os.path.abspath(__file__))
SPECS = os.path.abspath(os.path.join(HERE, "..", "Specs"))
LEVEL = "/Game/Mods/ITRLevelAddons/L_ITRLevelAddons"
DIR = "/Game/Mods/ITRLevelAddons"
eal = unreal.EditorAssetLibrary
ell = unreal.EditorLevelLibrary


def gen(name):
    report = unreal.ItrShowcaseBPGen.generate_blueprint_from_spec(SPECS + "/" + name + ".json")
    for line in report.splitlines()[:150]:
        unreal.log("BPGEN " + line)
    if not report.startswith("OK"):
        raise RuntimeError("generation failed for " + name + ": " + report.splitlines()[0])


def main():
    if eal.does_asset_exist(DIR + "/BP_ITRLevelWatch"):
        eal.delete_asset(DIR + "/BP_ITRLevelWatch")
    gen("BP_ITRLevelAddon")
    gen("BP_ITRLevelAddons")
    if eal.does_asset_exist(LEVEL):
        ell.load_level(LEVEL)
        for old in ell.get_all_level_actors():
            ell.destroy_actor(old)
    elif not ell.new_level(LEVEL):
        raise RuntimeError("cannot create " + LEVEL)
    for name in ("BP_ITRLevelAddon", "BP_ITRLevelAddons"):
        a = ell.spawn_actor_from_object(unreal.load_asset(DIR + "/" + name), unreal.Vector(0, 0, 0), unreal.Rotator(0, 0, 0))
        if a is None:
            raise RuntimeError("spawn failed for " + name)
        a.set_actor_label(name)
    if not ell.save_current_level():
        raise RuntimeError("save of " + LEVEL + " failed")
    unreal.log("ADDONS built")


main()
