# Writes ../Specs/BP_ITRTriggerBind.json (the BPGen spec of ITRMapLoader's trigger helper). Plain Python 3, no editor:
#   python gen_spec.py
# The spec file is committed; this script is the readable source of it. See ../README.md for what the helper does.
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Specs", "BP_ITRTriggerBind.json")
# Diagnostic variant (ITR_NO_REF_BINDS=1, output ITR_SPEC_OUT): leaves out the two binds whose delegates take a const-reference struct
# (OnComponentBeginOverlap, OnGripped), which BPGen cannot give a matching custom event. Not the product.
NO_REF = os.environ.get("ITR_NO_REF_BINDS") == "1"
if os.environ.get("ITR_SPEC_OUT"):
    OUT = os.environ["ITR_SPEC_OUT"]

nodes, links = [], []
_n = [0]


def add(op, **kw):
    _n[0] += 1
    nid = kw.pop("id", "n%d" % _n[0])
    d = {"id": nid, "op": op}
    d.update(kw)
    nodes.append(d)
    return nid


def link(a, b):
    links.append([a, b])


def chain(*ids):
    """exec chain: a.then -> b.execute"""
    for a, b in zip(ids, ids[1:]):
        link(a + ".then", b + ".execute")


def me():
    return add("self")


def get(var):
    return add("get", var=var)


def setv(var, value=None):
    pins = {var: value} if value is not None else None
    return add("set", var=var, **({"pins": pins} if pins else {}))


def call(fn, **pins):
    return add("call", function=fn, **({"pins": pins} if pins else {}))


def branch():
    return add("branch")


def pawn():
    p = call("GameplayStatics:GetPlayerPawn", PlayerIndex=0)
    link(me() + ".self", p + ".WorldContextObject")
    return p


def run_cmd(prefix):
    """console command prefix + Id; returns the ExecuteConsoleCommand node"""
    cat = call("KismetStringLibrary:Concat_StrStr", A=prefix)
    link(get("Id") + ".Id", cat + ".B")
    run = call("KismetSystemLibrary:ExecuteConsoleCommand")
    link(cat + ".ReturnValue", run + ".Command")
    link(me() + ".self", run + ".WorldContextObject")
    return run


def delegate_ref(cls, member):
    return "(MemberParent=Class'%s',MemberName=\"%s\")" % (cls, member)


def bind(exec_from, exec_pin, target_pin_src, cls, member, handler):
    """AddDelegate on target_pin_src (a 'node.pin' output) for cls.member, bound to the custom event handler. Returns the node id."""
    if NO_REF and member in ("OnComponentBeginOverlap", "OnGripped"):
        b = setv("Busy", False)                       # pass-through node in place of the bind
        if exec_from:
            link(exec_from + "." + exec_pin, b + ".execute")
        return b
    dl = add("create_delegate", function=handler)
    b = add("node", **{"class": "K2Node_AddDelegate", "props": {"DelegateReference": delegate_ref(cls, member)}})
    link(target_pin_src, b + ".self")
    link(dl + ".OutputDelegate", b + ".delegate")
    if exec_from:
        link(exec_from + "." + exec_pin, b + ".execute")
    return b


def is_pawn_overlap(other_actor_src, other_comp_src, ok_exec_from, ok_exec_pin):
    """branch: OtherActor is the player pawn AND OtherComp is the pawn's root component. Returns (second branch id); its True runs on a match."""
    p = pawn()
    eq1 = call("KismetMathLibrary:EqualEqual_ObjectObject")
    link(other_actor_src, eq1 + ".A")
    link(p + ".ReturnValue", eq1 + ".B")
    b1 = branch()
    link(eq1 + ".ReturnValue", b1 + ".Condition")
    link(ok_exec_from + "." + ok_exec_pin, b1 + ".execute")
    p2 = pawn()
    root = call("Actor:K2_GetRootComponent")
    link(p2 + ".ReturnValue", root + ".self")
    eq2 = call("KismetMathLibrary:EqualEqual_ObjectObject")
    link(other_comp_src, eq2 + ".A")
    link(root + ".ReturnValue", eq2 + ".B")
    b2 = branch()
    link(eq2 + ".ReturnValue", b2 + ".Condition")
    link(b1 + ".True", b2 + ".execute")
    return b2


GRIP = "/Script/VRExpansionPlugin."
variables = [
    {"name": "Target", "type": "object:/Script/Engine.Actor", "tooltip": "the author's object this helper listens to"},
    {"name": "Id", "type": "string", "default": "", "tooltip": "trigger id handed back to ITRMapLoader in 'itrmapbind fire <Id>'"},
    {"name": "Armed", "type": "bool", "default": "true", "tooltip": "collision: fires on entering, not again until the player has left"},
    {"name": "Busy", "type": "bool", "default": "false", "tooltip": "grab: a grab is being handled"},
    {"name": "Grabber", "type": "object:" + GRIP + "GripMotionControllerComponent"},
    {"name": "Result", "type": "int", "default": "0", "tooltip": "read by Lua after Attach*: 0 nothing bound, 1 bound and usable, 2 bound but nothing can be touched (collision: no primitive has Overlap for Pawn; grab: every primitive ignores Hand)"},
    {"name": "Primitives", "type": "int", "default": "0"},
    {"name": "Touchable", "type": "int", "default": "0"},
    {"name": "Delay", "type": "float", "default": "0.2", "tooltip": "seconds between the grab and the fire (the hand lets go first)"},
]

# ---- shared pieces ------------------------------------------------------------------------------------------------------------------------
# Fire: console command 'itrmapbind fire <Id>'
ev = add("custom_event", id="evFire", name="Fire")
r = run_cmd("itrmapbind fire ")
chain(ev, r)

# EndTarget(Actor, EndPlayReason): the author's object leaves (its level streams out): this helper goes with it
ev = add("custom_event", id="evEnd", name="EndTarget", params=[{"name": "EndedActor", "type": "object:/Script/Engine.Actor"}, {"name": "Reason", "type": "byte"}])
d = call("Actor:K2_DestroyActor")
link(me() + ".self", d + ".self")
chain(ev, d)

# BindEnd: Target.OnEndPlay -> EndTarget
ev = add("custom_event", id="evBindEnd", name="BindEnd")
b = bind(ev, "then", get("Target") + ".Target", "/Script/Engine.Actor", "OnEndPlay", "EndTarget")

# ---- AttachCollision(Target, Id) ----------------------------------------------------------------------------------------------------------
# (K2_GetComponentsByClass is const, so pure in the editor: no exec link; ForEachLoop continues by itself after its body.)
# Binds OnComponentBeginOverlap / EndOverlap on every primitive of Target (nothing on Target changes), then Armed = not already overlapping
# the pawn, then Result.
ev = add("custom_event", id="evAC", name="AttachCollision", params=[{"name": "TargetActor", "type": "object:/Script/Engine.Actor"}, {"name": "TriggerId", "type": "string"}])
s1 = setv("Target"); link(ev + ".TargetActor", s1 + ".Target")
s2 = setv("Id"); link(ev + ".TriggerId", s2 + ".Id")
s3 = setv("Result", 0)
s4 = setv("Primitives", 0)
s5 = setv("Touchable", 0)
chain(ev, s1, s2, s3, s4, s5)
comps = call("Actor:K2_GetComponentsByClass", ComponentClass="/Script/Engine.PrimitiveComponent")
link(get("Target") + ".Target", comps + ".self")
loop = add("macro", macro="ForEachLoop")
link(comps + ".ReturnValue", loop + ".Array")
link(s5 + ".then", loop + ".Exec")
cast = add("cast", **{"class": "PrimitiveComponent", "pure": False})
link(loop + ".LoopBody", cast + ".execute")
link(loop + ".ArrayElement", cast + ".Object")
incP = call("KismetMathLibrary:Add_IntInt", B=1)
link(get("Primitives") + ".Primitives", incP + ".A")
sP = setv("Primitives"); link(incP + ".ReturnValue", sP + ".Primitives")
link(cast + ".then", sP + ".execute")
resp = call("PrimitiveComponent:GetCollisionResponseToChannel", Channel="ECC_Pawn")
link(cast + ".as", resp + ".self")
ne = call("KismetMathLibrary:EqualEqual_ByteByte", B=1)          # ECR_Overlap: a Block response stops the player, so it never overlaps
link(resp + ".ReturnValue", ne + ".A")
bT = branch(); link(ne + ".ReturnValue", bT + ".Condition")
link(sP + ".then", bT + ".execute")
incT = call("KismetMathLibrary:Add_IntInt", B=1)
link(get("Touchable") + ".Touchable", incT + ".A")
sT = setv("Touchable"); link(incT + ".ReturnValue", sT + ".Touchable")
link(bT + ".True", sT + ".execute")
b1 = bind(sT, "then", cast + ".as", "/Script/Engine.PrimitiveComponent", "OnComponentBeginOverlap", "OnBegin")
b2 = bind(b1, "then", cast + ".as", "/Script/Engine.PrimitiveComponent", "OnComponentEndOverlap", "OnEnd")
link(bT + ".False", b1 + ".execute")
# after the loop: arm, end binding, result
ov = call("Actor:IsOverlappingActor")
link(get("Target") + ".Target", ov + ".self")
pw = pawn()
link(pw + ".ReturnValue", ov + ".Other")
nt = call("KismetMathLibrary:Not_PreBool")
link(ov + ".ReturnValue", nt + ".A")
sA = setv("Armed"); link(nt + ".ReturnValue", sA + ".Armed")
link(loop + ".Completed", sA + ".execute")
be = add("call", function="BindEnd")
link(sA + ".then", be + ".execute")
link(me() + ".self", be + ".self")
# Result: Primitives == 0 -> 0 (already 0); Touchable > 0 -> 1; else 2
gt0 = call("KismetMathLibrary:Greater_IntInt", B=0)
link(get("Primitives") + ".Primitives", gt0 + ".A")
bP = branch(); link(gt0 + ".ReturnValue", bP + ".Condition")
link(be + ".then", bP + ".execute")
gtT = call("KismetMathLibrary:Greater_IntInt", B=0)
link(get("Touchable") + ".Touchable", gtT + ".A")
bU = branch(); link(gtT + ".ReturnValue", bU + ".Condition")
link(bP + ".True", bU + ".execute")
sR1 = setv("Result", 1); sR2 = setv("Result", 2)
link(bU + ".True", sR1 + ".execute"); link(bU + ".False", sR2 + ".execute")

# OnBegin(OverlappedComponent, OtherActor, OtherComp, OtherBodyIndex, bFromSweep, SweepResult)
ev = add("custom_event", id="evBegin", name="OnBegin", params=[
    {"name": "OverlappedComponent", "type": "object:/Script/Engine.PrimitiveComponent"}, {"name": "OtherActor", "type": "object:/Script/Engine.Actor"},
    {"name": "OtherComp", "type": "object:/Script/Engine.PrimitiveComponent"}, {"name": "OtherBodyIndex", "type": "int"},
    {"name": "bFromSweep", "type": "bool"}, {"name": "SweepResult", "type": "struct:HitResult&"}])
m = is_pawn_overlap(ev + ".OtherActor", ev + ".OtherComp", ev, "then")
bArm = branch(); link(get("Armed") + ".Armed", bArm + ".Condition"); link(m + ".True", bArm + ".execute")
sDis = setv("Armed", False); link(bArm + ".True", sDis + ".execute")
gm = call("GameplayStatics:GetGameMode"); link(me() + ".self", gm + ".WorldContextObject")
asN = add("cast", **{"class": "IPRGameModeNative"})
link(gm + ".ReturnValue", asN + ".Object")
link(sDis + ".then", asN + ".execute")
inTr = call("IPRGameModeNative:GetIsInTransition"); link(asN + ".as", inTr + ".self")
link(asN + ".then", inTr + ".execute")
bTr = branch(); link(inTr + ".ReturnValue", bTr + ".Condition"); link(inTr + ".then", bTr + ".execute")
fireC = add("call", function="Fire"); link(me() + ".self", fireC + ".self")
link(bTr + ".False", fireC + ".execute")

# OnEnd(OverlappedComponent, OtherActor, OtherComp, OtherBodyIndex): armed again once the player no longer overlaps Target
ev = add("custom_event", id="evEndOv", name="OnEnd", params=[
    {"name": "OverlappedComponent", "type": "object:/Script/Engine.PrimitiveComponent"}, {"name": "OtherActor", "type": "object:/Script/Engine.Actor"},
    {"name": "OtherComp", "type": "object:/Script/Engine.PrimitiveComponent"}, {"name": "OtherBodyIndex", "type": "int"}])
m = is_pawn_overlap(ev + ".OtherActor", ev + ".OtherComp", ev, "then")
ov2 = call("Actor:IsOverlappingActor"); link(get("Target") + ".Target", ov2 + ".self")
pw2 = pawn(); link(pw2 + ".ReturnValue", ov2 + ".Other")
bStill = branch(); link(ov2 + ".ReturnValue", bStill + ".Condition"); link(m + ".True", bStill + ".execute")
sRe = setv("Armed", True); link(bStill + ".False", sRe + ".execute")

# ---- AttachGrab(Target, Id) -----------------------------------------------------------------------------------------------------------------
# Binds OnGripped on the author's grippable actor (GrippableActor, GrippableStaticMeshActor or GrippableSkeletalMeshActor). Result 0 if it is
# none of them; else CheckHand sets 1, or 2 when no primitive answers the Hand channel.
ev = add("custom_event", id="evAG", name="AttachGrab", params=[{"name": "TargetActor", "type": "object:/Script/Engine.Actor"}, {"name": "TriggerId", "type": "string"}])
g1 = setv("Target"); link(ev + ".TargetActor", g1 + ".Target")
g2 = setv("Id"); link(ev + ".TriggerId", g2 + ".Id")
g3 = setv("Result", 0)
chain(ev, g1, g2, g3)
prev = g3
after = add("call", function="BindEnd", id="afterBind")        # shared tail: BindEnd, then CheckHand
link(me() + ".self", after + ".self")
chk = add("call", function="CheckHand", id="callCheck")
link(me() + ".self", chk + ".self")
chain(after, chk)
for cname in ("GrippableActor", "GrippableStaticMeshActor", "GrippableSkeletalMeshActor"):
    c = add("cast", **{"class": GRIP + cname, "pure": False})
    link(get("Target") + ".Target", c + ".Object")
    link(prev + (".then" if prev == g3 else ".CastFailed"), c + ".execute")
    bd = bind(c, "then", c + ".as", GRIP + cname, "OnGripped", "OnGripped")
    link(bd + ".then", after + ".execute")
    prev = c

# CheckHand: does any primitive of Target answer the Hand channel (ECC_GameTraceChannel3)?
ev = add("custom_event", id="evCH", name="CheckHand")
t0 = setv("Touchable", 0)
chain(ev, t0)
comps2 = call("Actor:K2_GetComponentsByClass", ComponentClass="/Script/Engine.PrimitiveComponent")
link(get("Target") + ".Target", comps2 + ".self")
loop2 = add("macro", macro="ForEachLoop")
link(comps2 + ".ReturnValue", loop2 + ".Array")
link(t0 + ".then", loop2 + ".Exec")
cast2 = add("cast", **{"class": "PrimitiveComponent", "pure": False})
link(loop2 + ".LoopBody", cast2 + ".execute")
link(loop2 + ".ArrayElement", cast2 + ".Object")
resp2 = call("PrimitiveComponent:GetCollisionResponseToChannel", Channel="ECC_GameTraceChannel3")
link(cast2 + ".as", resp2 + ".self")
ne2 = call("KismetMathLibrary:NotEqual_ByteByte", B=0)
link(resp2 + ".ReturnValue", ne2 + ".A")
bH = branch(); link(ne2 + ".ReturnValue", bH + ".Condition"); link(cast2 + ".then", bH + ".execute")
incH = call("KismetMathLibrary:Add_IntInt", B=1)
link(get("Touchable") + ".Touchable", incH + ".A")
sH = setv("Touchable"); link(incH + ".ReturnValue", sH + ".Touchable")
link(bH + ".True", sH + ".execute")
gtH = call("KismetMathLibrary:Greater_IntInt", B=0)
link(get("Touchable") + ".Touchable", gtH + ".A")
bR = branch(); link(gtH + ".ReturnValue", bR + ".Condition"); link(loop2 + ".Completed", bR + ".execute")
rH1 = setv("Result", 1); rH2 = setv("Result", 2)
link(bR + ".True", rH1 + ".execute"); link(bR + ".False", rH2 + ".execute")

# OnGripped(GrippingController, GripInformation)
ev = add("custom_event", id="evGr", name="OnGripped", params=[
    {"name": "GrippingController", "type": "object:" + GRIP + "GripMotionControllerComponent"}, {"name": "GripInformation", "type": "struct:BPActorGripInformation&"}])
bBusy = branch(); link(get("Busy") + ".Busy", bBusy + ".Condition"); link(ev + ".then", bBusy + ".execute")
gm2 = call("GameplayStatics:GetGameMode"); link(me() + ".self", gm2 + ".WorldContextObject")
asN2 = add("cast", **{"class": "IPRGameModeNative"})
link(gm2 + ".ReturnValue", asN2 + ".Object"); link(bBusy + ".False", asN2 + ".execute")
inTr2 = call("IPRGameModeNative:GetIsInTransition"); link(asN2 + ".as", inTr2 + ".self"); link(asN2 + ".then", inTr2 + ".execute")
bTr2 = branch(); link(inTr2 + ".ReturnValue", bTr2 + ".Condition"); link(inTr2 + ".then", bTr2 + ".execute")
sBusy = setv("Busy", True); link(bTr2 + ".False", sBusy + ".execute")
sGr = setv("Grabber"); link(ev + ".GrippingController", sGr + ".Grabber")
tm = call("KismetSystemLibrary:K2_SetTimer", FunctionName="DoFire", bLooping=False)
link(me() + ".self", tm + ".Object")
link(get("Delay") + ".Delay", tm + ".Time")
chain(sBusy, sGr, tm)

# DoFire: drop the grip, fire, ready again (a refused transfer can be tried again)
ev = add("custom_event", id="evDF", name="DoFire")
valid = call("KismetSystemLibrary:IsValid"); link(get("Grabber") + ".Grabber", valid + ".Object")
bV = branch(); link(valid + ".ReturnValue", bV + ".Condition"); link(ev + ".then", bV + ".execute")
drop = call("GripMotionControllerComponent:DropObjectByInterface")
link(get("Grabber") + ".Grabber", drop + ".self")
link(get("Target") + ".Target", drop + ".ObjectToDrop")
link(bV + ".True", drop + ".execute")
fireG = add("call", function="Fire"); link(me() + ".self", fireG + ".self")
link(drop + ".then", fireG + ".execute"); link(bV + ".False", fireG + ".execute")
sFree = setv("Busy", False); link(fireG + ".then", sFree + ".execute")

spec = {
    "once": True,
    "_doc": "ITRMapLoader's trigger helper: logic only, no mesh, no collision, no component the player can meet, no Tick. ITRMapLoader's Lua spawns one per trigger and calls AttachCollision(Target, Id) or AttachGrab(Target, Id) with the author's named actor, then reads Result. It changes nothing on the author's object. collision: binds OnComponentBeginOverlap / EndOverlap on every primitive of the object; only the player pawn's root component fires it, and only once per entry (Armed; the player must leave before it can fire again); a hand reaching in does nothing. grab: binds OnGripped on the author's GrippableActor / GrippableStaticMeshActor / GrippableSkeletalMeshActor; 0.2 s after the grab it drops the grip and fires. Fire runs the console command 'itrmapbind fire <Id>': the only Lua that runs at the moment of a trigger. The object's OnEndPlay destroys the helper (its level streaming out). Result (read from Lua): 0 nothing bound, 1 usable, 2 bound but cannot be touched (collision: no primitive overlaps Pawn, e.g. a solid mesh; grab: Hand is ignored). A Blueprint function stub cannot return a value in BPGen, so Result is a variable.",
    "asset": "/Game/Mods/ITRMapLoader/BP_ITRTriggerBind",
    "parent": "/Script/Engine.Actor",
    "components": [],
    "variables": variables,
    "cdo": {"PrimaryActorTick": "(bCanEverTick=False)"},
    "nodes": nodes,
    "links": links,
}
with open(OUT, "w") as f:
    json.dump(spec, f, indent=1)
print("wrote", os.path.abspath(OUT), len(nodes), "nodes", len(links), "links")
