#!/usr/bin/env python
"""Writes the BPGen specs for BP_PenBulletProjectile (bullet penetration, entirely in a Blueprint) and its stand-in parent.
  Specs/BP_RadiusBulletProjectile.json   stand-in for the game's /Game/ITR/BPs/Misc/Projectiles/BP_RadiusBulletProjectile (native parent only; never packed)
  Specs/BP_PenBulletProjectile.json      /Game/Mods/BulletPenetration/BP_PenBulletProjectile, child of the stand-in (this is what is packed)
Use --lean for the build in prebuilt/ (no records, counters or self-check). Without it the spec also carries the debug records the development build used.
Every tunable is a Blueprint variable read per hit; the Lua mod writes the class defaults and the live bullets."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpspec as G  # noqa: E402

LEAN = False   # --lean: the player-facing build (no Rec / RecShot / counters / self-check / debug records); the default keeps the dev build byte for byte
LEAN_DROP_TUNABLES = {"DebugOn", "SelfCheckOn"}
LEAN_DROP_VARS = {"HandlerSeq", "HitCount", "SelfDone", "SelfCheck", "Recent", "Reasons", "DecSeq", "ShotSeq", "TNearP", "TDirSrc", "TPm", "THitComp", "TMeshName"}

MOD = "/Game/Mods/BulletPenetration"
ASSET = MOD + "/BP_PenBulletProjectile"
CLS = ASSET + ".BP_PenBulletProjectile_C"
PARENT_ASSET = "/Game/ITR/BPs/Misc/Projectiles/BP_RadiusBulletProjectile"
PARENT_CLS = PARENT_ASSET + ".BP_RadiusBulletProjectile_C"
PM = "/Game/Impacts/Materials/Physical_Materials/"
OBJ = lambda c: "object:/Script/Engine." + c  # noqa: E731
PHYSMAT = "object:/Script/PhysicsCore.PhysicalMaterial"   # UPhysicalMaterial lives in PhysicsCore since 4.26

# physical material asset -> resistance per cm (a name that is not here gets UnmarkedResistance)
RESISTANCE = [
    ("Leaves", 0.3), ("Grass", 0.3), ("Cardboard", 0.3),
    ("Glass", 1), ("Cloth", 1), ("Carpet", 1), ("Plastic", 1),
    ("Wood", 2),
    ("smallMetal", 6),
    ("Plaster", 4), ("Tile", 4), ("Clay", 4), ("Dirt", 4), ("Sand", 4),
    ("Brick", 8), ("Asphalt", 8),
    ("Concrete", 15), ("Rock", 15),
    ("Metal", 20),
]
PM_PATHS = [(PM + n + "." + n, r) for n, r in RESISTANCE] + [("/Game/ITR_art/Physical_Materials/Wood.Wood", 2)]

# class-default tunables (name, type, default, tooltip); config.lua is the source of the numbers, the Lua mod rewrites them at start
TUNABLES = [
    ("Scale", "float", "1.0", "Global penetration scale on the energy budget. 0 = off."),
    ("DebugOn", "bool", "false", "Print one line per decision (game log) and the first-run self-check."),
    ("SelfCheckOn", "bool", "false", "First-run self-check: each bullet describes its first hit once (SelfCheck variable, game log)."),
    ("PlayerOnly", "bool", "false", "Only bullets whose instigator is the player pawn."),
    ("BudgetK", "float", "30.0", "budget = Penetration * BudgetK * (v / v0)^2 * Scale"),
    ("ProbeCapCm", "float", "500.0", "Longest thickness probe (cm)."),
    ("MinSpeed", "float", "2500.0", "Bullets slower than this (cm/s) are not looked at."),
    ("MinExitSpeed", "float", "2000.0", "A bullet that would leave slower than this is blocked."),
    ("MinCos", "float", "0.2", "Hits more glancing than this cosine are left to the game (ricochet)."),
    ("MaxPenetrations", "int", "4", "Most walls one chain of continuation bullets may pass."),
    ("ExitOffsetCm", "float", "2.0", "The continuation bullet spawns this far beyond the exit point."),
    ("ConeDegrees", "float", "0.5", "Cone of the continuation bullet."),
    ("DamageFloor", "float", "0.25", "Damage of the continuation = Damage * lerp(DamageFloor, 1, exit speed / spawn speed)."),
    ("MinThicknessCm", "float", "0.5", "An exit closer than this to the entry is ambiguous and blocks."),
    ("UnmarkedResistance", "float", "15.0", "Resistance per cm of a surface with no physical material in the table (unmarked / default): finite, = concrete (config.lua). Landscape and pawns still block."),
    ("AssumedSpeed", "float", "40000.0", "Speed (cm/s) used when the contact velocity reads 0 (physics zeroes it at the contact; the Blueprint handler runs before the native one)."),
    ("SheetThicknessCm", "float", "1.0", "0 = an ambiguous (thinner than MinThicknessCm) exit blocks; > 0 = it counts as a sheet of this thickness (a one-sided steel shell)."),
    ("EntryTrace", "bool", "true", "Re-read the physical material of the entry point with a short component-only complex trace."),
    ("DivideByVelocityMultiplier", "bool", "true", "Divide the exit speed by AmmoInfo.VelocityMultiplier before SpawnBulletProjectile."),
    ("Retire", "bool", "true", "Dispose the original bullet on the next tick after a pass, unless the game already hid it."),
    ("ChainTimeoutSec", "float", "4.0", "A continuation bullet's chain data expires after this many seconds."),
]

INSTANCE_VARS = [
    ("PhysMap", "map:%s=float" % PHYSMAT, None, "physical material -> resistance per cm (built at BeginPlay)"),
    ("Retired", "bool", "false", ""),
    ("ChainN", "int", "0", "walls passed by the chain this bullet continues (0 = a fresh shot)"),
    ("ChainV0", "float", "0.0", "speed at the chain's first hit"),
    ("ChainVi", "float", "0.0", "this bullet's spawn speed"),
    ("ChainT", "float", "0.0", "time the chain data was written"),
    ("HandlerSeq", "int", "0", "hits seen by the handler (self-check: read from Lua to learn the order against the native handler)"),
    ("HitCount", "int", "0", "hits since this instance was spawned"),
    ("SelfDone", "bool", "false", ""),
    ("SelfCheck", "string", "", "text of this instance's first-run self-check"),
    ("TComp", "object:/Script/Engine.PrimitiveComponent", None, ""),
    ("TChainN", "int", "0", ""), ("TCV0", "float", "0.0", ""), ("TCVi", "float", "0.0", ""),
    ("TRes", "float", "0.0", ""), ("TVel", "vector", None, ""), ("TV", "float", "0.0", ""), ("TFwd", "vector", None, ""),
    ("TNrm", "vector", None, ""), ("TCos", "float", "0.0", ""), ("TDir", "vector", None, ""),
    ("TV0", "float", "0.0", ""), ("TVi", "float", "0.0", ""), ("TBudget", "float", "0.0", ""), ("TProbe", "float", "0.0", ""),
    ("TEntry", "vector", None, ""), ("TXp", "vector", None, ""), ("TTh", "float", "0.0", ""), ("TCost", "float", "0.0", ""),
    ("TVx", "float", "0.0", ""), ("TVp", "float", "0.0", ""), ("TDmg", "float", "0.0", ""), ("TPen", "float", "0.0", ""),
    ("TPm", "object:/Script/PhysicsCore.PhysicalMaterial", None, "physical material of the last hit (for the decision record)"),
    ("THitComp", "object:/Script/Engine.PrimitiveComponent", None, "component of the last hit (for the decision record)"),
    ("TMeshName", "string", "", ""),
    ("Recent", "string[]", None, "last 8 decisions of this bullet instance (read by the UE4SS mod while debug is on)"),
    ("Reasons", "map:string=int", None, "decision reason -> count for this instance"),
    ("DecSeq", "int", "0", "decisions recorded by this instance"),
    ("ShotSeq", "int", "0", "shot-at-player lines recorded by this instance (ring in Recent)"),
    ("DirRec", "bool", "false", "set on a continuation bullet by the bullet that spawned it: LaunchFwd / LaunchT are valid"),
    ("LaunchLoc", "vector", None, "continuation bullet: its start point"),
    ("TLaunch", "vector", None, "launch point of a fresh shot = the shooter's location at the hit"),
    ("THaveL", "bool", "false", ""),
    ("TW", "vector", None, "barrel axis of the weapon that fired (its actor +Y)"),
    ("TNearP", "bool", "false", "debug: this hit is on / near the player"),
    ("TDirSrc", "string", "", "debug: which direction source was used"),
    ("LaunchFwd", "vector", None, "continuation bullet: the direction it was spawned with"),
    ("LaunchT", "float", "0.0", ""),
]


def parent_spec():
    return {"asset": PARENT_ASSET, "parent": "/Script/IntoTheRadius.RadiusBulletProjectile", "lenient": True,
            "variables": [], "nodes": [], "links": []}


def pen_spec():
    b = G.B()
    ME = b.add("self", id="me") + ".self"
    # Get Class Defaults read Scale 1.0 after the UE4SS mod had written 50 to the CDO, so the tunables are read from the bullet's variables instead
    # (op class_defaults stays in BPGen). The mod writes the CDO (bullets spawned later) and every live / prefilled bullet.
    def cd(name):
        return b.get(name)

    def fo(fn, *inputs, lib="KismetMathLibrary", **pins):
        """library function with positional pins A, B, C: a literal number/bool or an output pin ref; returns the ReturnValue ref"""
        names = ["A", "B", "C"]
        lits = dict(pins)
        links = []
        for nm, v in zip(names, inputs):
            if v is None:
                continue
            if isinstance(v, (int, float, bool)):
                lits[nm] = v
            else:
                links.append((v, nm))
        n = b.call(lib + ":" + fn, lits or None)
        for v, nm in links:
            b.link(v, n + "." + nm)
        return n + ".ReturnValue"

    def gv(var, cls=None, target=None):
        return b.get(var, cls=cls, target=target)

    def sv(var, value=None, lit=None, **kw):
        return b.set(var, value=value, lit=lit, **kw)

    def vsub(x, y): return fo("Subtract_VectorVector", x, y)
    def vadd(x, y): return fo("Add_VectorVector", x, y)
    def vmul(x, k): return fo("Multiply_VectorFloat", x, k)
    def fadd(x, y): return fo("Add_FloatFloat", x, y)
    def fsub(x, y): return fo("Subtract_FloatFloat", x, y)
    def fmul(x, y): return fo("Multiply_FloatFloat", x, y)
    def fdiv(x, y): return fo("Divide_FloatFloat", x, y)
    def fmin(x, y): return fo("FMin", x, y)
    def gt(x, y): return fo("Greater_FloatFloat", x, y)
    def ge(x, y): return fo("GreaterEqual_FloatFloat", x, y)
    def lt(x, y): return fo("Less_FloatFloat", x, y)
    def le(x, y): return fo("LessEqual_FloatFloat", x, y)
    def band(x, y): return fo("BooleanAND", x, y)
    def bnot(x): return fo("Not_PreBool", x)

    def tostr(fn, pin, inp):
        n = b.call("KismetStringLibrary:" + fn)
        b.link(pin, n + "." + inp)
        return n + ".ReturnValue"

    def fstr(p): return tostr("Conv_FloatToString", p, "InFloat")
    def istr(p): return tostr("Conv_IntToString", p, "InInt")
    def bstr(p): return tostr("Conv_BoolToString", p, "InBool")

    def sc(*parts):
        """concatenate: a 1-tuple is a literal, anything else is an output pin of a string"""
        acc = None
        for p in parts:
            if isinstance(p, tuple):
                n = b.call("KismetStringLibrary:Concat_StrStr")
                if acc is None:
                    b.nodes[-1].setdefault("pins", {})["A"] = p[0]
                else:
                    b.link(acc, n + ".A")
                    b.nodes[-1].setdefault("pins", {})["B"] = p[0]
                acc = n + ".ReturnValue"
            elif acc is None:
                acc = p
            else:
                n = b.call("KismetStringLibrary:Concat_StrStr")
                b.link(acc, n + ".A")
                b.link(p, n + ".B")
                acc = n + ".ReturnValue"
        return acc

    def print_pin(text_pin):
        ps = b.call("KismetSystemLibrary:PrintString", {"bPrintToScreen": False, "bPrintToLog": True})
        b.link(text_pin, ps + ".InString")
        return ps

    def branch(cond):
        n = b.add("branch")
        b.link(cond, n + ".Condition")
        return n

    now = b.call("GameplayStatics:GetTimeSeconds") + ".ReturnValue"

    # ---------------------------------------------------------------- exec cursor: the exec outputs that flow into the next node
    cur = []

    def go(node):
        for i, p in cur:
            b.link("%s.%s" % (i, p), node + ".execute")
        cur[:] = [(node, "then")]
        return node

    def dbg_on():
        # the class default reaches bullets spawned later; the UE4SS mod also writes the variable of every live instance: either switches it on
        return gv("DebugOn")

    def dbg_end(src, pin, text):
        """a decision that ends the hit: with debug on it is recorded by the custom event Rec in this instance's Recent / Reasons (the shipping game has no log)"""
        if LEAN:
            return
        rc = b.call("Rec", {"Reason": text})
        b.link("%s.%s" % (src, pin), rc + ".execute")

    def guard(cond, why):
        n = branch(cond)
        go(n)
        dbg_end(n, "False", why)
        cur[:] = [(n, "True")]
        return n

    # ================================================================ EVENT: OnComponentHit of SphereCollider (native property of the parent)
    H = b.add("component_event", id="Hit", component="SphereCollider", delegate="OnComponentHit")
    cur.append((H, "then"))
    BR = b.call("GameplayStatics:BreakHitResult")
    b.link(H + ".Hit", BR + ".Hit")

    # 0. counters
    if not LEAN:
        go(sv("HandlerSeq", value=fo("Add_IntInt", gv("HandlerSeq"), 1)))
        go(sv("HitCount", value=fo("Add_IntInt", gv("HitCount"), 1)))
    mlen = b.call("BlueprintMapLibrary:Map_Length"); b.link(gv("PhysMap"), mlen + ".TargetMap")
    br_ml = branch(fo("EqualEqual_IntInt", mlen + ".ReturnValue", 0))
    go(br_ml)
    bt_h = b.call("BuildTable")
    b.to(br_ml, "True", bt_h)
    cur[:] = [(bt_h, "then"), (br_ml, "False")]
    # what the decision record needs (cheap pointer copies) and a clean slate for the figures it prints
    if not LEAN:
        go(sv("TPm", value=BR + ".PhysMat"))
        go(sv("THitComp", value=BR + ".HitComponent"))
        for zv in ("TRes", "TV", "TTh", "TBudget", "TProbe", "TVx"):
            go(sv(zv, lit=0.0))

    # ammo: BulletComponent._ammoInfo (private in the game, read-only in the stub) -> Penetration, VelocityMultiplier
    bc = gv("BulletComponent")
    ai = gv("_ammoInfo", cls="RadiusBulletComponent", target=bc)
    bs = b.add("node", **{"class": "K2Node_BreakStruct", "props": {"StructType": "/Script/IntoTheRadius.AmmoInfo"}})
    b.link(ai, bs + ".AmmoInfo")
    PEN, VM = bs + ".Penetration", bs + ".VelocityMultiplier"

    # first-run self-check (debug): FIRST thing the handler does, before any reject (the first run only described hits that survived the rejects, so it never printed):
    # state of the bullet when the handler runs, the _ammoInfo values, velocity versus forward, the scale read through class defaults
    if not LEAN:
        br_sc = branch(band(gv("SelfCheckOn"), bnot(gv("SelfDone"))))
        go(br_sc)
        ten = b.call("Actor:IsActorTickEnabled"); b.link(ME, ten + ".self")
        ow = b.call("Actor:GetOwner"); b.link(ME, ow + ".self")
        owv = b.call("KismetSystemLibrary:IsValid"); b.link(ow + ".ReturnValue", owv + ".Object")
        gl0 = b.call("PrimitiveComponent:GetPhysicsLinearVelocity", {"BoneName": "None"}); b.link(H + ".HitComponent", gl0 + ".self")
        fw0 = b.call("Actor:GetActorForwardVector"); b.link(ME, fw0 + ".self")
        vdf = fo("Dot_VectorVector", fo("Normal", gl0 + ".ReturnValue"), fw0 + ".ReturnValue")
        pmn = b.call("KismetSystemLibrary:GetObjectName"); b.link(BR + ".PhysMat", pmn + ".Object")
        txt = sc(("hitCount=",), istr(gv("HitCount")), (" handlerSeq=",), istr(gv("HandlerSeq")),
                 (" hidden=",), bstr(gv("bHidden")), (" tick=",), bstr(ten + ".ReturnValue"), (" ownerValid=",), bstr(owv + ".ReturnValue"),
                 (" | ammo: pen=",), fstr(PEN), (" velMult=",), fstr(VM), (" bounceMax=",), istr(bs + ".BounceMax"), (" armorPierce=",), fstr(bs + ".ArmorPiercing"),
                 (" dmgMod=",), fstr(bs + ".DamageModifier"), (" baseDamage=",), fstr(gv("BaseDamage")),
                 (" | speed=",), fstr(fo("VSize", gl0 + ".ReturnValue")), (" vel.fwd=",), fstr(vdf), (" | scaleRead=",), fstr(cd("Scale")),
                 (" physMapLen=",), istr(mlen + ".ReturnValue"), (" hitPhysmat=",), pmn + ".ReturnValue")
        s_txt = sv("SelfCheck", value=txt)
        s_done = sv("SelfDone", lit=True)
        b.to(br_sc, "True", gl0); b.flow(gl0, s_txt, s_done)
        cur[:] = [(br_sc, "False"), (s_done, "then")]

    # 1. chain data of a continuation bullet is read and consumed first (a stale value must not outlive its first hit)
    active = band(fo("Greater_IntInt", gv("ChainN"), 0), le(fsub(now, gv("ChainT")), cd("ChainTimeoutSec")))
    br_act = branch(active)
    go(br_act)
    t1 = sv("TChainN", value=gv("ChainN")); t2 = sv("TCV0", value=gv("ChainV0")); t3 = sv("TCVi", value=gv("ChainVi"))
    b.to(br_act, "True", t1); b.flow(t1, t2, t3)
    f1 = sv("TChainN", lit=0); f2 = sv("TCV0", lit=0.0); f3 = sv("TCVi", lit=0.0)
    b.to(br_act, "False", f1); b.flow(f1, f2, f3)
    clr = sv("ChainN", lit=0)
    b.flow(t3, clr); b.flow(f3, clr)
    cur[:] = [(clr, "then")]

    # 1b. debug: per-shooter counter for every hit; a hit on the player (pawn, its children, or within 150 cm of the camera) is also written to the Recent ring
    insn = b.call("Actor:GetInstigator"); b.link(ME, insn + ".self")
    ownn = b.call("Actor:GetOwner"); b.link(ME, ownn + ".self")
    if not LEAN:
        inm = b.call("KismetSystemLibrary:GetObjectName"); b.link(insn + ".ReturnValue", inm + ".Object")
        onm = b.call("KismetSystemLibrary:GetObjectName"); b.link(ownn + ".ReturnValue", onm + ".Object")
        go(sv("TNearP", lit=False))
        br_dg = branch(dbg_on())
        go(br_dg)
        r_sh = b.call("Rec", {})
        b.link(sc(("shooter:",), inm + ".ReturnValue"), r_sh + ".Reason")
        b.to(br_dg, "True", r_sh)
        ppw = b.call("GameplayStatics:GetPlayerPawn", {"PlayerIndex": 0})
        cmn = b.call("GameplayStatics:GetPlayerCameraManager", {"PlayerIndex": 0})
        cml = b.call("PlayerCameraManager:GetCameraLocation"); b.link(cmn + ".ReturnValue", cml + ".self")
        dcam = fo("VSize", vsub(BR + ".ImpactPoint", cml + ".ReturnValue"))
        oap = b.call("Actor:GetAttachParentActor"); b.link(H + ".OtherActor", oap + ".self")
        oow = b.call("Actor:GetOwner"); b.link(H + ".OtherActor", oow + ".self")
        on_player = fo("BooleanOR", fo("BooleanOR", fo("EqualEqual_ObjectObject", H + ".OtherActor", ppw + ".ReturnValue"),
                                       fo("EqualEqual_ObjectObject", oap + ".ReturnValue", ppw + ".ReturnValue")),
                       fo("BooleanOR", fo("EqualEqual_ObjectObject", oow + ".ReturnValue", ppw + ".ReturnValue"), lt(dcam, 150.0)))
        br_pl = branch(on_player)
        b.flow(r_sh, br_pl)
        np_true = sv("TNearP", lit=True)
        oan = b.call("KismetSystemLibrary:GetObjectName"); b.link(H + ".OtherActor", oan + ".Object")
        ocn = b.call("KismetSystemLibrary:GetObjectName"); b.link(H + ".OtherComp", ocn + ".Object")
        pmn2 = b.call("KismetSystemLibrary:GetObjectName"); b.link(BR + ".PhysMat", pmn2 + ".Object")
        shot_txt = sc(("instigator=",), inm + ".ReturnValue", (" owner=",), onm + ".ReturnValue", (" dmg=",), fstr(gv("BaseDamage")),
                      (" continuation=",), bstr(fo("Greater_IntInt", gv("TChainN"), 0)), (" chain=",), istr(gv("TChainN")),
                      (" hit=",), oan + ".ReturnValue", (" comp=",), ocn + ".ReturnValue", (" pm=",), pmn2 + ".ReturnValue", (" dist=",), fstr(dcam))
        rs = b.call("RecShot", {})
        b.link(shot_txt, rs + ".Text")
        b.to(br_pl, "True", np_true); b.flow(np_true, rs)
        cur[:] = [(br_dg, "False"), (br_pl, "False"), (rs, "then")]
    # a bullet with no instigator and no owner, or with 0 base damage, is a probe and not a weapon shot: it behaves exactly like stock
    iv1 = b.call("KismetSystemLibrary:IsValid"); b.link(insn + ".ReturnValue", iv1 + ".Object")
    iv2 = b.call("KismetSystemLibrary:IsValid"); b.link(ownn + ".ReturnValue", iv2 + ".Object")
    guard(fo("BooleanOR", iv1 + ".ReturnValue", iv2 + ".ReturnValue"), "stock-no-shooter")
    guard(gt(gv("BaseDamage"), 0.0), "stock-zero-damage")

    # 2. cheap rejects, cheapest first
    guard(gt(cd("Scale"), 0.0), "off")
    guard(bnot(gv("Retired")), "retired")
    isv = b.call("KismetSystemLibrary:IsValid"); b.link(BR + ".PhysMat", isv + ".Object")
    br_v = branch(isv + ".ReturnValue")
    go(br_v)
    find = b.call("BlueprintMapLibrary:Map_Find")
    b.link(gv("PhysMap"), find + ".TargetMap"); b.link(BR + ".PhysMat", find + ".Key")
    br_f = branch(find + ".ReturnValue")
    b.to(br_v, "True", br_f)
    rA = sv("TRes", value=find + ".Value")                 # in the table
    rB = sv("TRes", value=cd("UnmarkedResistance"))        # not in the table / no physical material: finite (= concrete), no longer blocks
    b.to(br_f, "True", rA); b.to(br_f, "False", rB); b.to(br_v, "False", rB)
    cur[:] = [(rA, "then"), (rB, "then")]
    # the component the bullet touched: OtherComp, else the hit's component
    isv2 = b.call("KismetSystemLibrary:IsValid"); b.link(H + ".OtherComp", isv2 + ".Object")
    br_oc = branch(isv2 + ".ReturnValue")
    go(br_oc)
    sa = sv("TComp", value=H + ".OtherComp"); sb = sv("TComp", value=BR + ".HitComponent")
    b.to(br_oc, "True", sa); b.to(br_oc, "False", sb)
    cur[:] = [(sa, "then"), (sb, "then")]
    isv3 = b.call("KismetSystemLibrary:IsValid"); b.link(gv("TComp"), isv3 + ".Object")
    guard(isv3 + ".ReturnValue", "no-component")
    cs = b.add("cast", **{"class": "StaticMeshComponent"})
    b.link(gv("TComp"), cs + ".Object")
    go(cs)
    dbg_end(cs, "CastFailed", "component-class")
    # chain length cap
    guard(fo("Less_IntInt", gv("TChainN"), cd("MaxPenetrations")), "pen-cap")
    # player only
    br_po = branch(cd("PlayerOnly"))
    go(br_po)
    ins = b.call("Actor:GetInstigator"); b.link(ME, ins + ".self")
    pp = b.call("GameplayStatics:GetPlayerPawn", {"PlayerIndex": 0})
    eq = fo("EqualEqual_ObjectObject", ins + ".ReturnValue", pp + ".ReturnValue")
    br_pm = branch(eq)
    b.to(br_po, "True", br_pm)
    dbg_end(br_pm, "False", "not-player")
    cur[:] = [(br_po, "False"), (br_pm, "True")]

    # 3. speed and direction
    gl = b.call("PrimitiveComponent:GetPhysicsLinearVelocity", {"BoneName": "None"})
    b.link(H + ".HitComponent", gl + ".self")
    go(gl)
    go(sv("TVel", value=gl + ".ReturnValue"))
    go(sv("TV", value=fo("VSize", gv("TVel"))))
    # a contact velocity of 0 is not a slow bullet: a continuation uses the speed it was spawned with, a fresh shot the assumed muzzle speed
    br_z = branch(lt(gv("TV"), 1.0))
    go(br_z)
    br_zc = branch(fo("Greater_IntInt", gv("TChainN"), 0))
    b.to(br_z, "True", br_zc)
    z1 = sv("TV", value=gv("TCVi"))
    z2 = sv("TV", value=fmul(cd("AssumedSpeed"), VM))
    b.to(br_zc, "True", z1); b.to(br_zc, "False", z2)
    cur[:] = [(br_z, "False"), (z1, "then"), (z2, "then")]
    guard(ge(gv("TV"), cd("MinSpeed")), "slow")
    fw = b.call("Actor:GetActorForwardVector"); b.link(ME, fw + ".self")
    go(sv("TFwd", value=fw + ".ReturnValue"))
    go(sv("TNrm", value=BR + ".ImpactNormal"))
    # flight direction, in this order (contact velocity reads 0; Hit.TraceStart / TraceEnd are never set; the sphere cannot spin, so its forward is the launch direction):
    #   continuation bullet            the direction it was spawned with                                  -> dir-launch
    #   fresh shot, owner is a weapon  the weapon's barrel axis = its actor +Y (FirePoint is at +Y with yaw 90 on BP_SKS / BP_Weapon_M9) -> dir-weapon
    #   actor forward, into the surface                                                                    -> dir-fwd
    #   impact - shooter location, when the shooter is more than 100 cm away                               -> dir-launch
    #   -ImpactNormal, only when nothing else exists                                                       -> dir-normal
    go(sv("THaveL", lit=False))
    ol = b.call("Actor:K2_GetActorLocation"); b.link(ownn + ".ReturnValue", ol + ".self")
    il = b.call("Actor:K2_GetActorLocation"); b.link(insn + ".ReturnValue", il + ".self")
    br_ov = branch(iv2 + ".ReturnValue")
    go(br_ov)
    s_o = sv("TLaunch", value=ol + ".ReturnValue"); h_o = sv("THaveL", lit=True)
    b.to(br_ov, "True", s_o); b.flow(s_o, h_o)
    br_iv = branch(iv1 + ".ReturnValue")
    b.to(br_ov, "False", br_iv)
    s_i = sv("TLaunch", value=il + ".ReturnValue"); h_i = sv("THaveL", lit=True)
    b.to(br_iv, "True", s_i); b.flow(s_i, h_i)
    cur[:] = [(h_o, "then"), (h_i, "then"), (br_iv, "False")]
    dvec = vsub(BR + ".ImpactPoint", gv("TLaunch"))
    far = gt(fo("VSize", dvec), 100.0)

    # sinks: each source sets TDir, counts itself and names itself in TDirSrc
    def src(name, value):
        s1 = sv("TDir", value=value)
        if LEAN:
            return s1, s1
        s2 = b.call("Rec", {"Reason": name}); s3 = sv("TDirSrc", lit=name)
        b.flow(s1, s2, s3)
        return s1, s3

    f_in, f_out = src("dir-fwd", gv("TFwd"))
    n_in, n_out = src("dir-normal", vmul(gv("TNrm"), -1.0))
    w_in, w_out = src("dir-weapon", gv("TW"))
    c_in, c_out = src("dir-launch", gv("LaunchFwd"))
    o_in, o_out = src("dir-launch", fo("Normal", dvec))

    # forward / launch / normal tail
    br_f = branch(lt(fo("Dot_VectorVector", gv("TFwd"), gv("TNrm")), -0.05))
    b.to(br_f, "True", f_in)
    br_hl = branch(band(gv("THaveL"), far))
    b.to(br_f, "False", br_hl)
    b.to(br_hl, "True", o_in); b.to(br_hl, "False", n_in)

    # fresh shot from a weapon: owner valid and not a pawn
    br_lc = branch(fo("Greater_IntInt", gv("TChainN"), 0))
    go(br_lc)
    br_fr = branch(band(gv("DirRec"), le(fsub(now, gv("LaunchT")), 4.5)))
    b.to(br_lc, "True", br_fr)
    b.to(br_fr, "True", c_in); b.to(br_fr, "False", br_f)
    br_ow = branch(iv2 + ".ReturnValue")
    b.to(br_lc, "False", br_ow)
    b.to(br_ow, "False", br_f)
    cpw = b.add("cast", **{"class": "Pawn"})
    b.link(ownn + ".ReturnValue", cpw + ".Object")
    b.to(br_ow, "True", cpw)
    b.to(cpw, "then", br_f)                       # the owner is a pawn (an NPC that fires without a weapon actor): no barrel axis
    rv = b.call("Actor:GetActorRightVector"); b.link(ownn + ".ReturnValue", rv + ".self")
    w_set = sv("TW", value=rv + ".ReturnValue")
    b.to(cpw, "CastFailed", w_set)
    br_wd = branch(lt(fo("Dot_VectorVector", gv("TW"), gv("TNrm")), -0.05))
    b.flow(w_set, br_wd)
    b.to(br_wd, "True", w_in); b.to(br_wd, "False", br_f)
    cur[:] = [(f_out, "then"), (n_out, "then"), (w_out, "then"), (c_out, "then"), (o_out, "then")]

    # debug: a hit on / near the player also records which source gave which direction (and the actor forward) - no counters needed for a close-range test
    if not LEAN:
        br_dn = branch(band(dbg_on(), gv("TNearP")))
        go(br_dn)
        def vstr(pin):
            n = b.call("KismetStringLibrary:Conv_VectorToString"); b.link(pin, n + ".InVec"); return n + ".ReturnValue"
        dtx = b.call("RecShot", {})
        b.link(sc(("dir src=",), gv("TDirSrc"), (" dir=",), vstr(gv("TDir")), (" fwd=",), vstr(gv("TFwd")), (" normal=",), vstr(gv("TNrm"))), dtx + ".Text")
        b.to(br_dn, "True", dtx)
        cur[:] = [(br_dn, "False"), (dtx, "then")]
    go(sv("TCos", value=fo("Dot_VectorVector", gv("TDir"), gv("TNrm"))))
    guard(ge(fmul(gv("TCos"), -1.0), cd("MinCos")), "grazing")

    # 4. the ammo values (read at the top of the handler, see the self-check)
    go(sv("TPen", value=PEN))

    # 5. budget and probe length
    br_ch = branch(fo("Greater_IntInt", gv("TChainN"), 0))
    go(br_ch)
    v1 = sv("TV0", value=gv("TCV0")); v2 = sv("TVi", value=gv("TCVi"))
    b.to(br_ch, "True", v1); b.flow(v1, v2)
    w1 = sv("TV0", value=gv("TV")); w2 = sv("TVi", value=gv("TV"))
    b.to(br_ch, "False", w1); b.flow(w1, w2)
    cur[:] = [(v2, "then"), (w2, "then")]
    rat = fdiv(gv("TV"), gv("TV0"))
    go(sv("TBudget", value=fmul(fmul(fmul(fmul(gv("TPen"), cd("BudgetK")), rat), rat), cd("Scale"))))
    go(sv("TProbe", value=fmin(fdiv(gv("TBudget"), gv("TRes")), cd("ProbeCapCm"))))
    guard(ge(gv("TProbe"), 0.5), "budget")
    go(sv("TEntry", value=BR + ".ImpactPoint"))

    # 6. entry material of the triangle (component-only complex trace around the contact point)
    br_et = branch(cd("EntryTrace"))
    go(br_et)
    lte = b.call("PrimitiveComponent:K2_LineTraceComponent", {"bTraceComplex": True, "bShowTrace": False, "bPersistentShowTrace": False})
    b.link(gv("TComp"), lte + ".self")
    b.link(vsub(gv("TEntry"), vmul(gv("TDir"), 3.0)), lte + ".TraceStart")
    b.link(vadd(gv("TEntry"), vmul(gv("TDir"), 3.0)), lte + ".TraceEnd")
    b.to(br_et, "True", lte)
    br_eh = branch(lte + ".ReturnValue")
    b.flow(lte, br_eh)
    BR2 = b.call("GameplayStatics:BreakHitResult"); b.link(lte + ".OutHit", BR2 + ".Hit")
    isv4 = b.call("KismetSystemLibrary:IsValid"); b.link(BR2 + ".PhysMat", isv4 + ".Object")
    g1 = branch(isv4 + ".ReturnValue")
    b.to(br_eh, "True", g1)
    find2 = b.call("BlueprintMapLibrary:Map_Find")
    b.link(gv("PhysMap"), find2 + ".TargetMap"); b.link(BR2 + ".PhysMat", find2 + ".Key")
    g2 = branch(find2 + ".ReturnValue")
    b.to(g1, "True", g2)
    e1 = sv("TRes", value=find2 + ".Value")
    e2 = sv("TEntry", value=BR2 + ".ImpactPoint")
    e3 = sv("TProbe", value=fmin(fdiv(gv("TBudget"), gv("TRes")), cd("ProbeCapCm")))
    b.to(g2, "True", e1); b.flow(e1, e2, e3)
    b.to(g1, "False", e2); b.to(g2, "False", e2)       # unknown entry material: keep the contact resistance, still use the entry point
    g3 = branch(ge(gv("TProbe"), 0.5))
    b.flow(e3, g3)
    dbg_end(g3, "False", "budget-entry")
    cur[:] = [(br_et, "False"), (br_eh, "False"), (g3, "True")]

    # 7. thickness: complex trace on this component only, from the far end back to the entry
    lx = b.call("PrimitiveComponent:K2_LineTraceComponent", {"bTraceComplex": True, "bShowTrace": False, "bPersistentShowTrace": False})
    b.link(gv("TComp"), lx + ".self")
    b.link(vadd(gv("TEntry"), vmul(gv("TDir"), gv("TProbe"))), lx + ".TraceStart")
    b.link(vsub(gv("TEntry"), gv("TDir")), lx + ".TraceEnd")
    go(lx)
    gx = branch(lx + ".ReturnValue")
    b.flow(lx, gx)
    dbg_end(gx, "False", "no-exit")
    cur[:] = [(gx, "True")]
    BR3 = b.call("GameplayStatics:BreakHitResult"); b.link(lx + ".OutHit", BR3 + ".Hit")
    go(sv("TXp", value=BR3 + ".ImpactPoint"))
    go(sv("TTh", value=fo("VSize", vsub(gv("TXp"), gv("TEntry")))))
    br_zt = branch(ge(gv("TTh"), cd("MinThicknessCm")))
    go(br_zt)
    br_sh = branch(gt(cd("SheetThicknessCm"), 0.0))
    b.to(br_zt, "False", br_sh)
    dbg_end(br_sh, "False", "zero-thickness")
    s_sh = sv("TTh", value=cd("SheetThicknessCm"))
    b.to(br_sh, "True", s_sh)
    cur[:] = [(br_zt, "True"), (s_sh, "then")]
    go(sv("TCost", value=fmul(gv("TRes"), gv("TTh"))))
    guard(lt(gv("TCost"), gv("TBudget")), "too-thick")
    sq = fo("Sqrt", fsub(1.0, fdiv(gv("TCost"), gv("TBudget"))))
    go(sv("TVx", value=fmul(gv("TV"), sq)))
    guard(ge(gv("TVx"), cd("MinExitSpeed")), "exit-slow")

    # 8. pass: continuation bullet beyond the exit (same ammo, owner and instigator), exit FX, retire the original
    br_dv = branch(band(cd("DivideByVelocityMultiplier"), gt(VM, 0.0)))
    go(br_dv)
    p1 = sv("TVp", value=fdiv(gv("TVx"), VM)); p2 = sv("TVp", value=gv("TVx"))
    b.to(br_dv, "True", p1); b.to(br_dv, "False", p2)
    cur[:] = [(p1, "then"), (p2, "then")]
    fl = cd("DamageFloor")
    frac = fmin(1.0, fdiv(gv("TVx"), gv("TVi")))
    go(sv("TDmg", value=fmul(gv("BaseDamage"), fadd(fl, fmul(fsub(1.0, fl), frac)))))
    rot = b.call("KismetMathLibrary:MakeRotFromX"); b.link(gv("TDir"), rot + ".X")
    mt = b.call("KismetMathLibrary:MakeTransform")
    b.link(vadd(gv("TXp"), vmul(gv("TDir"), cd("ExitOffsetCm"))), mt + ".Location"); b.link(rot + ".ReturnValue", mt + ".Rotation")
    own = b.call("Actor:GetOwner"); b.link(ME, own + ".self")
    ins2 = b.call("Actor:GetInstigator"); b.link(ME, ins2 + ".self")
    rad = fo("DegreesToRadians", cd("ConeDegrees"))
    sp = b.call("FLFirearmProjectiles:SpawnBulletProjectile", {"IsForceTrace": False})
    b.link(mt + ".ReturnValue", sp + ".Transform"); b.link(ai, sp + ".AmmoInfo"); b.link(gv("TDmg"), sp + ".Damage"); b.link(gv("TVp"), sp + ".Velocity")
    b.link(rad, sp + ".AccuracyRadians"); b.link(own + ".ReturnValue", sp + ".Owner"); b.link(ins2 + ".ReturnValue", sp + ".Instigator")
    go(sp)
    fx = b.call("FLSpawn:SpawnImpactFromHit", {"ParticleScale": 1.0, "DecalScale": 1.0, "Distance": 100.0})
    b.link(ME, fx + ".WorldContextObject"); b.link(lx + ".OutHit", fx + ".Hit")
    go(fx)
    # chain data for the continuation bullet (an instance of this class; the game's pool hands out our class for every shot)
    cc = b.add("cast", **{"class": CLS})
    b.link(sp + ".Actor", cc + ".Object")
    go(cc)
    k1 = b.set("ChainN", value=fo("Add_IntInt", gv("TChainN"), 1), cls=CLS, target=cc + ".as")
    k2 = b.set("ChainV0", value=gv("TV0"), cls=CLS, target=cc + ".as")
    k3 = b.set("ChainVi", value=gv("TVx"), cls=CLS, target=cc + ".as")
    k4 = b.set("ChainT", value=now, cls=CLS, target=cc + ".as")
    k5 = b.set("LaunchFwd", value=gv("TDir"), cls=CLS, target=cc + ".as")
    k6 = b.set("LaunchLoc", value=vadd(gv("TXp"), vmul(gv("TDir"), cd("ExitOffsetCm"))), cls=CLS, target=cc + ".as")
    k7 = b.set("LaunchT", value=now, cls=CLS, target=cc + ".as")
    k8 = b.set("DirRec", lit=True, cls=CLS, target=cc + ".as")
    b.flow(cc, k1, k2, k3, k4, k5, k6, k7, k8)
    k4 = k8
    # debug line for a pass
    if LEAN:
        ps_p = k4
    else:
        ps_p = b.call("Rec", {"Reason": "pass"})
        b.flow(k4, ps_p)
    # retire the original on the next tick unless the game already hid it
    br_rt = branch(cd("Retire"))
    b.flow(ps_p, br_rt)
    r1 = sv("Retired", lit=True)
    tm = b.call("KismetSystemLibrary:K2_SetTimer", {"FunctionName": "RetireSelf", "Time": 0.02, "bLooping": False})
    b.link(ME, tm + ".Object")
    b.to(br_rt, "True", r1); b.flow(r1, tm)

    # ================================================================ RetireSelf (timer): Dispose the original unless it is already hidden
    rs = b.add("custom_event", id="RetireSelf", name="RetireSelf")
    br_h = branch(bnot(gv("bHidden")))
    b.flow(rs, br_h)
    disp = b.call("RadiusProjectile:Dispose"); b.link(ME, disp + ".self")
    b.to(br_h, "True", disp)
    r0 = sv("Retired", lit=False)
    b.flow(disp, r0); b.to(br_h, "False", r0)

    # ================================================================ BeginPlay: the material table (physical material object -> resistance), no strings at hit time
    bp = b.add("event", id="BeginPlay", event="ReceiveBeginPlay")
    bt_call = b.call("BuildTable")                                  # BeginPlay builds the table; the hit handler builds it too when it is still empty (BeginPlay not run)
    b.flow(bp, bt_call)
    bt = b.add("custom_event", id="BuildTable", name="BuildTable")
    prevs = [(bt, "then")]
    for i, (path, res) in enumerate(PM_PATHS):
        ld = b.call("KismetSystemLibrary:LoadAsset_Blocking", {"Asset": path})
        ct = b.add("cast", **{"class": "PhysicalMaterial"})      # a cast with exec pins (a pure one was pruned by the compiler); a failed cast skips the entry
        b.link(ld + ".ReturnValue", ct + ".Object")
        ad = b.call("BlueprintMapLibrary:Map_Add", {"Value": res})
        b.link(gv("PhysMap"), ad + ".TargetMap"); b.link(ct + ".as", ad + ".Key")
        for s, p in prevs:
            b.link("%s.%s" % (s, p), ld + ".execute")
        b.flow(ld, ct)
        b.to(ct, "then", ad)
        prevs = [(ad, "then"), (ct, "CastFailed")]

    if not LEAN:
        # ================================================================ Rec(Reason): the decision record (debug only). The shipping game writes no log and PrintString is stripped, so the
        # Blueprint keeps its last 8 decisions (Recent) and per-reason counters (Reasons) in variables the UE4SS mod reads.
        rv = b.add("custom_event", id="Rec", name="Rec", params=[{"name": "Reason", "type": "string"}])
        rf = b.call("BlueprintMapLibrary:Map_Find"); b.link(gv("Reasons"), rf + ".TargetMap"); b.link(rv + ".Reason", rf + ".Key")
        rad = b.call("BlueprintMapLibrary:Map_Add"); b.link(gv("Reasons"), rad + ".TargetMap"); b.link(rv + ".Reason", rad + ".Key")
        b.link(fo("Add_IntInt", rf + ".Value", 1), rad + ".Value")
        b.flow(rv, rad)
        b.flow(rad, sv("DecSeq", value=fo("Add_IntInt", gv("DecSeq"), 1)))

        # ================================================================ RecShot(Text): a hit on / near the player, into the Recent ring (the UE4SS mod prints it as shot-at-player)
        rsv = b.add("custom_event", id="RecShot", name="RecShot", params=[{"name": "Text", "type": "string"}])
        ra2 = b.call("KismetArrayLibrary:Array_Add"); b.link(gv("Recent"), ra2 + ".TargetArray"); b.link(rsv + ".Text", ra2 + ".NewItem")
        b.flow(rsv, ra2)
        rl2 = b.call("KismetArrayLibrary:Array_Length"); b.link(gv("Recent"), rl2 + ".TargetArray")
        br_r2 = branch(fo("Greater_IntInt", rl2 + ".ReturnValue", 8))
        b.flow(ra2, br_r2)
        rr2 = b.call("KismetArrayLibrary:Array_Remove", {"IndexToRemove": 0}); b.link(gv("Recent"), rr2 + ".TargetArray")
        b.to(br_r2, "True", rr2)
        ss = sv("ShotSeq", value=fo("Add_IntInt", gv("ShotSeq"), 1))
        b.flow(rr2, ss); b.to(br_r2, "False", ss)

    variables = []
    for name, typ, dflt, tip in TUNABLES:
        if LEAN and name in LEAN_DROP_TUNABLES:
            continue
        variables.append({"name": name, "type": typ, "default": dflt, "editable": True, "category": "Penetration", "tooltip": tip})
    for name, typ, dflt, tip in INSTANCE_VARS:
        if LEAN and name in LEAN_DROP_VARS:
            continue
        v = {"name": name, "type": typ, "category": "State"}
        if dflt is not None:
            v["default"] = dflt
        if tip:
            v["tooltip"] = tip
        variables.append(v)
    return {"asset": ASSET, "parent": PARENT_CLS, "requires": ["BP_RadiusBulletProjectile.json"], "no_default_root": True,
            "nativeOverrides": [{"name": "SphereCollider", "props": {"BodyInstance": {"bOverrideMaxAngularVelocity": True, "MaxAngularVelocity": 0.0, "AngularDamping": 1000.0}}}],
            "variables": variables, "nodes": b.nodes, "links": b.links}


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="writes the BPGen specs of BP_PenBulletProjectile")
    ap.add_argument("--lean", action="store_true", help="player-facing build: no Rec / RecShot / counters / self-check / debug records")
    ap.add_argument("--out", default="", help="write the specs here instead of ../Specs")
    a = ap.parse_args()
    LEAN = a.lean
    if a.out:
        G.SPECS = os.path.abspath(a.out)
    print(G.write("BP_RadiusBulletProjectile", parent_spec()))
    print(G.write("BP_PenBulletProjectile", pen_spec()))
