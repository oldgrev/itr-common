"""Editor script (UE4Editor-Cmd -run=pythonscript, Python 3.7): builds /Game/Mods/BulletPenetration/BP_PenBulletProjectile (and its stand-in parent
/Game/ITR/BPs/Misc/Projectiles/BP_RadiusBulletProjectile, never packed) from PB_SPECS. Env: PB_SPECS (folder gen_penbullet.py wrote), PB_OUT (result json).
Prints the generator report and a "=== PB OK|FAIL" line (the marker a job runner can look for)."""
import json
import os
import traceback
import unreal

eal = unreal.EditorAssetLibrary
SPECS = os.environ.get("PB_SPECS", "")
OUT = os.environ.get("PB_OUT", "")
ASSET = "/Game/Mods/BulletPenetration/BP_PenBulletProjectile"
PARENT = "/Game/ITR/BPs/Misc/Projectiles/BP_RadiusBulletProjectile"
res = {}
ok = True
try:
    rep = unreal.ItrShowcaseBPGen.generate_blueprint_from_spec(os.path.join(SPECS, "BP_PenBulletProjectile.json"))
    res["report"] = rep.split("\n")[:120]
    unreal.log("PB REPORT " + rep[:6000])
    assert rep.startswith("OK"), "BPGen: " + rep[:3000]
    for p in (PARENT, ASSET):
        d = json.loads(unreal.ItrShowcaseBPGen.dump_blueprint(p))
        res[p] = {"status": d.get("status"), "parent": d.get("parentClass"), "variables": [v.get("name") if isinstance(v, dict) else v for v in d.get("variables", [])][:80]}
        assert d.get("status") in ("UpToDate", "UpToDateWithWarnings"), "%s status %s" % (p, d.get("status"))
    # a variable written to the class defaults must stick (the UE4SS mod does the same at run time)
    try:
        cdo = unreal.get_default_object(eal.load_blueprint_class(ASSET))
        res["cdo_scale"] = cdo.get_editor_property("scale")
        res["cdo_budget_k"] = cdo.get_editor_property("budget_k")
    except Exception as e:  # noqa: BLE001
        res["cdo_note"] = "class default read failed: " + str(e)[:200]
    eal.save_directory("/Game/Mods/BulletPenetration", only_if_is_dirty=False, recursive=True)
    eal.save_directory("/Game/ITR/BPs/Misc/Projectiles", only_if_is_dirty=False, recursive=True)
except Exception as e:  # noqa: BLE001
    ok = False
    res["error"] = str(e)
    res["trace"] = traceback.format_exc()
    unreal.log_error("PB FAILED: " + str(e)[:1500])
res["ok"] = ok
if OUT:
    with open(OUT, "w") as f:
        json.dump(res, f, indent=1)
unreal.log("PB RESULT " + json.dumps(res)[:5000])
print("=== PB " + ("OK" if ok else "FAIL"))
