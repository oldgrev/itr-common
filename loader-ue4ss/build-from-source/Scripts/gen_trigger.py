# Writes ../Specs/BP_ITRTrigger.json (the BPGen spec of ITRMapLoader's trigger Blueprint: one per trigger of a form). Plain Python 3, no editor:
#   python gen_trigger.py
# The bind, overlap and grip graph is the one the earlier trigger helper proved (collision: overlap events of every part of the object, only the player body fires, once per
# entry; grab: the object's own OnGripped). What is new: this actor starts itself, finds its object in the stream it names (retrying at the next level event while the stream
# is not there yet), and acts on its own: a way in calls Entry.Enter(); an exit stores the return point, then enters another map (Dest), or transfers to a stock level
# (To, with At), or to the Hub. No console command and no Lua at the moment of a trigger. No Tick, no timer.
import os

from bpb import B, write

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Specs", "BP_ITRTrigger.json")
DIR = "/Game/Mods/ITRMapLoader"
ENTRY = DIR + "/BP_ITRMapEntry.BP_ITRMapEntry_C"
EM = "/Script/IntoTheRadius.EventsManager"
LS = "/Script/Engine.LevelStreaming"
GRIP = "/Script/VRExpansionPlugin."
b = B()


def say(where_src, text, exec_from):
    """console 'itrmaps log <Where> <text>': Lua prints the line (a console command from a level event is heard)"""
    c1 = b.call("KismetStringLibrary:Concat_StrStr", A="itrmaps log ")
    b.link(where_src, c1 + ".B")
    c2 = b.call("KismetStringLibrary:Concat_StrStr", B=text)
    b.link(c1 + ".ReturnValue", c2 + ".A")
    run = b.call("KismetSystemLibrary:ExecuteConsoleCommand")
    b.link(c2 + ".ReturnValue", run + ".Command")
    b.link(b.me() + ".self", run + ".WorldContextObject")
    b.link(exec_from, run + ".execute")
    return run


def pawn():
    p = b.call("GameplayStatics:GetPlayerPawn", PlayerIndex=0)
    b.link(b.me() + ".self", p + ".WorldContextObject")
    return p


def is_pawn_overlap(other_actor_src, other_comp_src, ok_exec_from, ok_exec_pin):
    """branch: OtherActor is the player pawn AND OtherComp is the pawn's root component. Returns the second branch; its True runs on a match."""
    p = pawn()
    eq1 = b.call("KismetMathLibrary:EqualEqual_ObjectObject")
    b.link(other_actor_src, eq1 + ".A"); b.link(p + ".ReturnValue", eq1 + ".B")
    b1 = b.branch(); b.link(eq1 + ".ReturnValue", b1 + ".Condition"); b.link(ok_exec_from + "." + ok_exec_pin, b1 + ".execute")
    p2 = pawn()
    root = b.call("Actor:K2_GetRootComponent"); b.link(p2 + ".ReturnValue", root + ".self")
    eq2 = b.call("KismetMathLibrary:EqualEqual_ObjectObject")
    b.link(other_comp_src, eq2 + ".A"); b.link(root + ".ReturnValue", eq2 + ".B")
    b2 = b.branch(); b.link(eq2 + ".ReturnValue", b2 + ".Condition"); b.link(b1 + ".True", b2 + ".execute")
    return b2


def transfer(tag_src, gate_src, exec_from):
    gm = b.call("GameplayStatics:GetGameMode"); b.link(b.me() + ".self", gm + ".WorldContextObject")
    asG = b.add("cast", **{"class": "IPRGameMode"}); b.link(gm + ".ReturnValue", asG + ".Object"); b.link(exec_from, asG + ".execute")
    go = b.call("IPRGameMode:TransferToLevel"); b.link(asG + ".as", go + ".self"); b.link(tag_src, go + ".LevelTag"); b.link(asG + ".then", go + ".execute")
    if gate_src:
        b.link(gate_src, go + ".LocationTag")
    return go


# ---- Fire: a way in enters the map; an exit stores the return point, then enters another map, goes to a stock level, or to the Hub ----------------------------------------
ev = b.event("Fire")
lgF = say(b.get("Where") + ".Where", " fired", ev + ".then")
brKind = b.branch(); eqK = b.call("KismetMathLibrary:EqualEqual_IntInt", B=1)
b.link(b.get("Kind") + ".Kind", eqK + ".A"); b.link(eqK + ".ReturnValue", brKind + ".Condition"); b.link(lgF + ".then", brKind + ".execute")
enterA = b.add("call", function=ENTRY + ":Enter"); b.link(b.get("Entry") + ".Entry", enterA + ".self"); b.link(brKind + ".True", enterA + ".execute")
brMiss = b.branch(); b.link(b.get("ToMissing") + ".ToMissing", brMiss + ".Condition"); b.link(brKind + ".False", brMiss + ".execute")
cm1 = b.call("KismetStringLibrary:Concat_StrStr", A="itrmaps log "); b.link(b.get("Note") + ".Note", cm1 + ".B")
rm = b.call("KismetSystemLibrary:ExecuteConsoleCommand"); b.link(cm1 + ".ReturnValue", rm + ".Command"); b.link(b.me() + ".self", rm + ".WorldContextObject"); b.link(brMiss + ".True", rm + ".execute")
store = b.add("call", function=ENTRY + ":StoreReturn"); b.link(b.get("Entry") + ".Entry", store + ".self"); b.link(brMiss + ".False", store + ".execute")
vD = b.valid(b.get("Dest") + ".Dest")
brD = b.branch(); b.link(vD + ".ReturnValue", brD + ".Condition"); b.link(store + ".then", brD + ".execute")
enterB = b.add("call", function=ENTRY + ":Enter"); b.link(b.get("Dest") + ".Dest", enterB + ".self"); b.link(brD + ".True", enterB + ".execute")
brTo = b.branch(); b.link(b.get("HasTo") + ".HasTo", brTo + ".Condition"); b.link(brD + ".False", brTo + ".execute")
brAt = b.branch(); b.link(b.get("HasAtPos") + ".HasAtPos", brAt + ".Condition"); b.link(brTo + ".True", brAt + ".execute")
sPA = b.setv("PendingAt", True); b.link(brAt + ".True", sPA + ".execute")
svA = b.call_me("SaveAt"); b.link(sPA + ".then", svA + ".execute")
goTo = transfer(b.get("ToTag") + ".ToTag", b.get("AtGate") + ".AtGate", svA + ".then")
# at a position the saved position is used; without one the exit goes by the gate (or the game's choice)
asG2 = b.add("cast", **{"class": "IPRGameMode"})
gm2 = b.call("GameplayStatics:GetGameMode"); b.link(b.me() + ".self", gm2 + ".WorldContextObject"); b.link(gm2 + ".ReturnValue", asG2 + ".Object"); b.link(brAt + ".False", asG2 + ".execute")
go2 = b.call("IPRGameMode:TransferToLevel"); b.link(asG2 + ".as", go2 + ".self"); b.link(b.get("ToTag") + ".ToTag", go2 + ".LevelTag"); b.link(b.get("AtGate") + ".AtGate", go2 + ".LocationTag"); b.link(asG2 + ".then", go2 + ".execute")
goHub = transfer(b.get("HubTag") + ".HubTag", None, brTo + ".False")

# ---- SaveAt: the arrival position in the destination level (the game's position slot, read first by TransferToLevel); saved again on the transition events while PendingAt
ev = b.event("SaveAt")
gdS = b.call("PRGameData:GetGameData")
mkS = b.call("KismetMathLibrary:MakeTransform", Scale="1,1,1"); b.link(b.get("AtLoc") + ".AtLoc", mkS + ".Location")
rtS = b.call("KismetMathLibrary:MakeRotator", Roll=0, Pitch=0); b.link(b.get("AtYaw") + ".AtYaw", rtS + ".Yaw"); b.link(rtS + ".ReturnValue", mkS + ".Rotation")
pdS = b.add("get", var="PlayerData", **{"class": "/Script/IntoTheRadius.PRGameData"}); b.link(gdS + ".GameData", pdS + ".self")
spS = b.call("PlayerGameData:SavePosition", Velocity="0,0,0")
b.link(pdS + ".PlayerData", spS + ".self"); b.link(b.get("ToTag") + ".ToTag", spS + ".InLevel"); b.link(mkS + ".ReturnValue", spS + ".Position"); b.link(ev + ".then", spS + ".execute")
for name, params in (("HTStartAt", None), ("HLPrepAt", [{"name": "Value", "type": "struct:GameplayTag"}])):
    ev = b.event(name, params)
    brPA = b.branch(); b.link(b.get("PendingAt") + ".PendingAt", brPA + ".Condition"); b.link(ev + ".then", brPA + ".execute")
    c = b.call_me("SaveAt"); b.link(brPA + ".True", c + ".execute")
ev = b.event("HTEndAt")
b.chain(ev, b.setv("PendingAt", False))

# ---- EndTarget: the author's object leaves (its level streams out): forget it; this actor stays for the next time the level is shown ---------------------------------------
ev = b.event("EndTarget", [{"name": "EndedActor", "type": "object:/Script/Engine.Actor"}, {"name": "Reason", "type": "byte"}])
b.chain(ev, b.setv("Target"))

# ---- BindEnd: Target.OnEndPlay -> EndTarget
ev = b.event("BindEnd")
b.bind(ev, "then", b.get("Target") + ".Target", "/Script/Engine.Actor", "OnEndPlay", "EndTarget")

# ---- FindByName(ObjPath): the actor whose path name is ObjPath into Found (the engine walks its own actor list; StaticFindObject misses actors of an add-on level)
ev = b.event("FindByName", [{"name": "ObjPath", "type": "string"}])
sF0 = b.setv("Found")
ga = b.call("GameplayStatics:GetAllActorsOfClass", ActorClass="/Script/Engine.Actor"); b.link(b.me() + ".self", ga + ".WorldContextObject")
lp = b.add("macro", macro="ForEachLoop"); b.link(ga + ".OutActors", lp + ".Array")
b.chain(ev, sF0, ga); b.link(ga + ".then", lp + ".Exec")
nm = b.call("KismetSystemLibrary:GetPathName"); b.link(lp + ".ArrayElement", nm + ".Object")
eqn = b.call("KismetStringLibrary:EqualEqual_StriStri"); b.link(nm + ".ReturnValue", eqn + ".A"); b.link(ev + ".ObjPath", eqn + ".B")
bN = b.branch(); b.link(eqn + ".ReturnValue", bN + ".Condition"); b.link(lp + ".LoopBody", bN + ".execute")
sFound = b.setv("Found"); b.link(lp + ".ArrayElement", sFound + ".Found"); b.link(bN + ".True", sFound + ".execute")

# ---- AttachCollision(TargetActor): overlap events on every primitive of the object (nothing on it changes), Armed = not already overlapping the pawn, Result -------------
ev = b.event("AttachCollision", [{"name": "TargetActor", "type": "object:/Script/Engine.Actor"}])
s1 = b.setv("Target"); b.link(ev + ".TargetActor", s1 + ".Target")
s3 = b.setv("Result", 0); s4 = b.setv("Primitives", 0); s5 = b.setv("Touchable", 0)
b.chain(ev, s1, s3, s4, s5)
comps = b.call("Actor:K2_GetComponentsByClass", ComponentClass="/Script/Engine.PrimitiveComponent"); b.link(b.get("Target") + ".Target", comps + ".self")
loop = b.add("macro", macro="ForEachLoop"); b.link(comps + ".ReturnValue", loop + ".Array"); b.link(s5 + ".then", loop + ".Exec")
cast = b.add("cast", **{"class": "PrimitiveComponent", "pure": False}); b.link(loop + ".LoopBody", cast + ".execute"); b.link(loop + ".ArrayElement", cast + ".Object")
incP = b.call("KismetMathLibrary:Add_IntInt", B=1); b.link(b.get("Primitives") + ".Primitives", incP + ".A")
sP = b.setv("Primitives"); b.link(incP + ".ReturnValue", sP + ".Primitives"); b.link(cast + ".then", sP + ".execute")
resp = b.call("PrimitiveComponent:GetCollisionResponseToChannel", Channel="ECC_Pawn"); b.link(cast + ".as", resp + ".self")
ne = b.call("KismetMathLibrary:EqualEqual_ByteByte", B=1); b.link(resp + ".ReturnValue", ne + ".A")
bT = b.branch(); b.link(ne + ".ReturnValue", bT + ".Condition"); b.link(sP + ".then", bT + ".execute")
incT = b.call("KismetMathLibrary:Add_IntInt", B=1); b.link(b.get("Touchable") + ".Touchable", incT + ".A")
sT = b.setv("Touchable"); b.link(incT + ".ReturnValue", sT + ".Touchable"); b.link(bT + ".True", sT + ".execute")
b1 = b.bind(sT, "then", cast + ".as", "/Script/Engine.PrimitiveComponent", "OnComponentBeginOverlap", "OnBegin")
b2 = b.bind(b1, "then", cast + ".as", "/Script/Engine.PrimitiveComponent", "OnComponentEndOverlap", "OnEnd")
b.link(bT + ".False", b1 + ".execute")
pw = pawn(); rt = b.call("Actor:K2_GetRootComponent"); b.link(pw + ".ReturnValue", rt + ".self")
asP = b.add("cast", **{"class": "PrimitiveComponent", "pure": False}); b.link(rt + ".ReturnValue", asP + ".Object"); b.link(loop + ".Completed", asP + ".execute")
ov = b.call("PrimitiveComponent:IsOverlappingActor"); b.link(asP + ".as", ov + ".self"); b.link(b.get("Target") + ".Target", ov + ".Other")
nt = b.call("KismetMathLibrary:Not_PreBool"); b.link(ov + ".ReturnValue", nt + ".A")
sA = b.setv("Armed"); b.link(nt + ".ReturnValue", sA + ".Armed"); b.link(asP + ".then", sA + ".execute"); b.link(asP + ".CastFailed", sA + ".execute")
be = b.call_me("BindEnd"); b.link(sA + ".then", be + ".execute")
gt0 = b.call("KismetMathLibrary:Greater_IntInt", B=0); b.link(b.get("Primitives") + ".Primitives", gt0 + ".A")
bP = b.branch(); b.link(gt0 + ".ReturnValue", bP + ".Condition"); b.link(be + ".then", bP + ".execute")
gtT = b.call("KismetMathLibrary:Greater_IntInt", B=0); b.link(b.get("Touchable") + ".Touchable", gtT + ".A")
bU = b.branch(); b.link(gtT + ".ReturnValue", bU + ".Condition"); b.link(bP + ".True", bU + ".execute")
sR1 = b.setv("Result", 1); sR2 = b.setv("Result", 2)
b.link(bU + ".True", sR1 + ".execute"); b.link(bU + ".False", sR2 + ".execute")

# OnBegin
ev = b.event("OnBegin", [
    {"name": "OverlappedComponent", "type": "object:/Script/Engine.PrimitiveComponent"}, {"name": "OtherActor", "type": "object:/Script/Engine.Actor"},
    {"name": "OtherComp", "type": "object:/Script/Engine.PrimitiveComponent"}, {"name": "OtherBodyIndex", "type": "int"},
    {"name": "bFromSweep", "type": "bool"}, {"name": "SweepResult", "type": "struct:HitResult&"}])
m = is_pawn_overlap(ev + ".OtherActor", ev + ".OtherComp", ev, "then")
bArm = b.branch(); b.link(b.get("Armed") + ".Armed", bArm + ".Condition"); b.link(m + ".True", bArm + ".execute")
sDis = b.setv("Armed", False); b.link(bArm + ".True", sDis + ".execute")
gm = b.call("GameplayStatics:GetGameMode"); b.link(b.me() + ".self", gm + ".WorldContextObject")
asN = b.add("cast", **{"class": "IPRGameModeNative"}); b.link(gm + ".ReturnValue", asN + ".Object"); b.link(sDis + ".then", asN + ".execute")
inTr = b.call("IPRGameModeNative:GetIsInTransition"); b.link(asN + ".as", inTr + ".self"); b.link(asN + ".then", inTr + ".execute")
bTr = b.branch(); b.link(inTr + ".ReturnValue", bTr + ".Condition"); b.link(inTr + ".then", bTr + ".execute")
fireC = b.call_me("Fire"); b.link(bTr + ".False", fireC + ".execute")

# OnEnd: armed again once the player no longer overlaps Target
ev = b.event("OnEnd", [
    {"name": "OverlappedComponent", "type": "object:/Script/Engine.PrimitiveComponent"}, {"name": "OtherActor", "type": "object:/Script/Engine.Actor"},
    {"name": "OtherComp", "type": "object:/Script/Engine.PrimitiveComponent"}, {"name": "OtherBodyIndex", "type": "int"}])
m = is_pawn_overlap(ev + ".OtherActor", ev + ".OtherComp", ev, "then")
ov2 = b.call("PrimitiveComponent:IsOverlappingActor"); b.link(ev + ".OtherComp", ov2 + ".self"); b.link(b.get("Target") + ".Target", ov2 + ".Other")
bStill = b.branch(); b.link(ov2 + ".ReturnValue", bStill + ".Condition"); b.link(m + ".True", bStill + ".execute")
sRe = b.setv("Armed", True); b.link(bStill + ".False", sRe + ".execute")

# ---- AttachGrab(TargetActor): OnGripped of the author's GrippableActor / GrippableStaticMeshActor / GrippableSkeletalMeshActor ---------------------------------------------
ev = b.event("AttachGrab", [{"name": "TargetActor", "type": "object:/Script/Engine.Actor"}])
g1 = b.setv("Target"); b.link(ev + ".TargetActor", g1 + ".Target"); g3 = b.setv("Result", 0)
b.chain(ev, g1, g3)
prev = g3
after = b.call_me("BindEnd"); chk = b.call_me("CheckHand"); b.chain(after, chk)
for cname in ("GrippableActor", "GrippableStaticMeshActor", "GrippableSkeletalMeshActor"):
    c = b.add("cast", **{"class": GRIP + cname, "pure": False})
    b.link(b.get("Target") + ".Target", c + ".Object")
    b.link(prev + (".then" if prev == g3 else ".CastFailed"), c + ".execute")
    bd = b.bind(c, "then", c + ".as", GRIP + cname, "OnGripped", "OnGripped")
    b.link(bd + ".then", after + ".execute")
    prev = c

ev = b.event("CheckHand")
t0 = b.setv("Touchable", 0); b.chain(ev, t0)
comps2 = b.call("Actor:K2_GetComponentsByClass", ComponentClass="/Script/Engine.PrimitiveComponent"); b.link(b.get("Target") + ".Target", comps2 + ".self")
loop2 = b.add("macro", macro="ForEachLoop"); b.link(comps2 + ".ReturnValue", loop2 + ".Array"); b.link(t0 + ".then", loop2 + ".Exec")
cast2 = b.add("cast", **{"class": "PrimitiveComponent", "pure": False}); b.link(loop2 + ".LoopBody", cast2 + ".execute"); b.link(loop2 + ".ArrayElement", cast2 + ".Object")
resp2 = b.call("PrimitiveComponent:GetCollisionResponseToChannel", Channel="ECC_GameTraceChannel3"); b.link(cast2 + ".as", resp2 + ".self")
ne2 = b.call("KismetMathLibrary:NotEqual_ByteByte", B=0); b.link(resp2 + ".ReturnValue", ne2 + ".A")
bH = b.branch(); b.link(ne2 + ".ReturnValue", bH + ".Condition"); b.link(cast2 + ".then", bH + ".execute")
incH = b.call("KismetMathLibrary:Add_IntInt", B=1); b.link(b.get("Touchable") + ".Touchable", incH + ".A")
sH = b.setv("Touchable"); b.link(incH + ".ReturnValue", sH + ".Touchable"); b.link(bH + ".True", sH + ".execute")
gtH = b.call("KismetMathLibrary:Greater_IntInt", B=0); b.link(b.get("Touchable") + ".Touchable", gtH + ".A")
bR = b.branch(); b.link(gtH + ".ReturnValue", bR + ".Condition"); b.link(loop2 + ".Completed", bR + ".execute")
rH1 = b.setv("Result", 1); rH2 = b.setv("Result", 2)
b.link(bR + ".True", rH1 + ".execute"); b.link(bR + ".False", rH2 + ".execute")

# OnGripped: no delay. The hand lets go, then Fire.
ev = b.event("OnGripped", [
    {"name": "GrippingController", "type": "object:" + GRIP + "GripMotionControllerComponent"}, {"name": "GripInformation", "type": "struct:BPActorGripInformation&"}])
bBusy = b.branch(); b.link(b.get("Busy") + ".Busy", bBusy + ".Condition"); b.link(ev + ".then", bBusy + ".execute")
gm2 = b.call("GameplayStatics:GetGameMode"); b.link(b.me() + ".self", gm2 + ".WorldContextObject")
asN2 = b.add("cast", **{"class": "IPRGameModeNative"}); b.link(gm2 + ".ReturnValue", asN2 + ".Object"); b.link(bBusy + ".False", asN2 + ".execute")
inTr2 = b.call("IPRGameModeNative:GetIsInTransition"); b.link(asN2 + ".as", inTr2 + ".self"); b.link(asN2 + ".then", inTr2 + ".execute")
bTr2 = b.branch(); b.link(inTr2 + ".ReturnValue", bTr2 + ".Condition"); b.link(inTr2 + ".then", bTr2 + ".execute")
sBusy = b.setv("Busy", True); b.link(bTr2 + ".False", sBusy + ".execute")
drop = b.call("GripMotionControllerComponent:DropObjectByInterface"); b.link(ev + ".GrippingController", drop + ".self"); b.link(b.get("Target") + ".Target", drop + ".ObjectToDrop")
b.link(sBusy + ".then", drop + ".execute")
fireG = b.call_me("Fire"); b.link(drop + ".then", fireG + ".execute")
sFree = b.setv("Busy", False); b.link(fireG + ".then", sFree + ".execute")

# ---- Start: find the stream, bind its OnLevelShown (retry at the next level event while it is not there); HShown binds the object ------------------------------------
ev = b.event("Start")
brSt = b.branch(); b.link(b.get("HasAtPos") + ".HasAtPos", brSt + ".Condition"); b.link(ev + ".then", brSt + ".execute")
emA = b.call("EventsManager:GetEventsManager")
bA1 = b.bind(brSt, "True", emA + ".ReturnValue", EM, "OnTransitionStart", "HTStartAt")
bA2 = b.bind(bA1, "then", emA + ".ReturnValue", EM, "OnLevelPrepare", "HLPrepAt")
bA3 = b.bind(bA2, "then", emA + ".ReturnValue", EM, "OnTransitionEnd", "HTEndAt")
c = b.call_me("BindStream"); b.link(bA3 + ".then", c + ".execute"); b.link(brSt + ".False", c + ".execute")

ev = b.event("BindStream")
n = b.call("KismetStringLibrary:Conv_StringToName"); b.link(b.get("StreamName") + ".StreamName", n + ".InString")
g = b.call("GameplayStatics:GetStreamingLevel"); b.link(b.me() + ".self", g + ".WorldContextObject"); b.link(n + ".ReturnValue", g + ".PackageName")
sS = b.setv("Stream"); b.link(g + ".ReturnValue", sS + ".Stream")
vS = b.valid(b.get("Stream") + ".Stream")
brS = b.branch(); b.link(vS + ".ReturnValue", brS + ".Condition")
b.chain(ev, sS); b.link(sS + ".then", brS + ".execute")
bx = b.bind(brS, "True", b.get("Stream") + ".Stream", LS, "OnLevelShown", "HShown")
vis = b.call("LevelStreaming:IsLevelVisible"); b.link(b.get("Stream") + ".Stream", vis + ".self")
brV = b.branch(); b.link(vis + ".ReturnValue", brV + ".Condition"); b.link(bx + ".then", brV + ".execute")
c = b.call_me("HShown"); b.link(brV + ".True", c + ".execute")
brR = b.branch(); nR = b.call("KismetMathLibrary:Not_PreBool"); b.link(b.get("Retrying") + ".Retrying", nR + ".A"); b.link(nR + ".ReturnValue", brR + ".Condition"); b.link(brS + ".False", brR + ".execute")
sR = b.setv("Retrying", True); b.link(brR + ".True", sR + ".execute")
em = b.call("EventsManager:GetEventsManager")
b.bind(sR, "then", em + ".ReturnValue", EM, "OnLevelStarted", "HRetry")

ev = b.event("HRetry", [{"name": "Value", "type": "struct:GameplayTag"}])
vS2 = b.valid(b.get("Stream") + ".Stream"); nS2 = b.call("KismetMathLibrary:Not_PreBool"); b.link(vS2 + ".ReturnValue", nS2 + ".A")
brS2 = b.branch(); b.link(nS2 + ".ReturnValue", brS2 + ".Condition"); b.link(ev + ".then", brS2 + ".execute")
c = b.call_me("BindStream"); b.link(brS2 + ".True", c + ".execute")

# HShown: the stream is shown: find the object in its loaded level and attach
ev = b.event("HShown")
bAlready = b.valid(b.get("Target") + ".Target")                  # a live target is bound already
nA = b.call("KismetMathLibrary:Not_PreBool"); b.link(bAlready + ".ReturnValue", nA + ".A")
brA = b.branch(); b.link(nA + ".ReturnValue", brA + ".Condition"); b.link(ev + ".then", brA + ".execute")
lv = b.call("LevelStreaming:GetLoadedLevel"); b.link(b.get("Stream") + ".Stream", lv + ".self")
pn = b.call("KismetSystemLibrary:GetPathName"); b.link(lv + ".ReturnValue", pn + ".Object")
c1 = b.call("KismetStringLibrary:Concat_StrStr", B="."); b.link(pn + ".ReturnValue", c1 + ".A")
c2 = b.call("KismetStringLibrary:Concat_StrStr"); b.link(c1 + ".ReturnValue", c2 + ".A"); b.link(b.get("ObjectName") + ".ObjectName", c2 + ".B")
fb = b.call_me("FindByName"); b.link(c2 + ".ReturnValue", fb + ".ObjPath"); b.link(brA + ".True", fb + ".execute")
vF = b.valid(b.get("Found") + ".Found")
brF = b.branch(); b.link(vF + ".ReturnValue", brF + ".Condition"); b.link(fb + ".then", brF + ".execute")
say(b.get("Where") + ".Where", " : the object was not found in its level", brF + ".False")
brG = b.branch(); b.link(b.get("Grab") + ".Grab", brG + ".Condition"); b.link(brF + ".True", brG + ".execute")
ac = b.add("call", function="AttachCollision"); b.link(b.me() + ".self", ac + ".self"); b.link(b.get("Found") + ".Found", ac + ".TargetActor"); b.link(brG + ".False", ac + ".execute")
ag = b.add("call", function="AttachGrab"); b.link(b.me() + ".self", ag + ".self"); b.link(b.get("Found") + ".Found", ag + ".TargetActor"); b.link(brG + ".True", ag + ".execute")
# a result of 2 (bound, but nothing can be touched) is said
gt = b.call("KismetMathLibrary:EqualEqual_IntInt", B=2); b.link(b.get("Result") + ".Result", gt + ".A")
brQ = b.branch(); b.link(gt + ".ReturnValue", brQ + ".Condition")
ri = b.call("KismetStringLibrary:Conv_IntToString"); b.link(b.get("Result") + ".Result", ri + ".InInt")
cb1 = b.call("KismetStringLibrary:Concat_StrStr", A="itrmaps log "); b.link(b.get("Where") + ".Where", cb1 + ".B")
cb2 = b.call("KismetStringLibrary:Concat_StrStr", B=" : bound, result "); b.link(cb1 + ".ReturnValue", cb2 + ".A")
cb3 = b.call("KismetStringLibrary:Concat_StrStr"); b.link(cb2 + ".ReturnValue", cb3 + ".A"); b.link(ri + ".ReturnValue", cb3 + ".B")
lgB = b.call("KismetSystemLibrary:ExecuteConsoleCommand"); b.link(cb3 + ".ReturnValue", lgB + ".Command"); b.link(b.me() + ".self", lgB + ".WorldContextObject")
b.link(ac + ".then", lgB + ".execute"); b.link(ag + ".then", lgB + ".execute"); b.link(lgB + ".then", brQ + ".execute")
say(b.get("Where") + ".Where", " : found, but the player cannot touch it (collision: no part overlaps the player; grab: every part ignores the hand)", brQ + ".True")

variables = [
    {"name": "Target", "type": "object:/Script/Engine.Actor", "tooltip": "the author's object this trigger listens to"},
    {"name": "Armed", "type": "bool", "default": "true", "tooltip": "collision: fires on entering, not again until the player has left"},
    {"name": "Busy", "type": "bool", "default": "false", "tooltip": "grab: a grab is being handled"},
    {"name": "Result", "type": "int", "default": "0", "tooltip": "0 nothing bound, 1 bound and usable, 2 bound but nothing can be touched"},
    {"name": "Primitives", "type": "int", "default": "0"}, {"name": "Touchable", "type": "int", "default": "0"},
    {"name": "Found", "type": "object:/Script/Engine.Actor", "tooltip": "FindByName: the actor with that path name, or None"},
    {"name": "Kind", "type": "int", "default": "0", "tooltip": "0 exit, 1 way in"}, {"name": "Grab", "type": "bool", "default": "false", "tooltip": "false collision, true grab"},
    {"name": "ObjectName", "type": "string", "default": ""}, {"name": "StreamName", "type": "string", "default": "", "tooltip": "the streaming entry the object lives in"},
    {"name": "Where", "type": "string", "default": "", "tooltip": "log text prefix"},
    {"name": "Entry", "type": "object:" + ENTRY}, {"name": "Dest", "type": "object:" + ENTRY},
    {"name": "ToMissing", "type": "bool", "default": "false"}, {"name": "Note", "type": "string", "default": ""},
    {"name": "HasTo", "type": "bool", "default": "false"}, {"name": "ToTag", "type": "struct:GameplayTag"}, {"name": "AtGate", "type": "struct:GameplayTag"},
    {"name": "HasAtPos", "type": "bool", "default": "false"}, {"name": "PendingAt", "type": "bool", "default": "false"}, {"name": "AtLoc", "type": "vector", "default": "0,0,0"}, {"name": "AtYaw", "type": "float", "default": "0"},
    {"name": "HubTag", "type": "struct:GameplayTag", "default": "(TagName=\"Level.Hub\")"},
    {"name": "Stream", "type": "object:" + LS}, {"name": "Retrying", "type": "bool", "default": "false"},
]
write(OUT, b.spec(DIR + "/BP_ITRTrigger", "/Script/Engine.Actor", variables,
      "ITRMapLoader's trigger Blueprint: logic only, no mesh, no collision, no component the player can meet, no Tick, no timer. One per trigger of a form. It finds the author's object in the stream "
      "it names and binds it (collision: overlap events of every part, only the player body fires, once per entry; grab: the object's own OnGripped, no delay). Fire: a way in calls Entry.Enter(); "
      "an exit stores the return point, then enters another map (Dest), or transfers to a stock level (ToTag, AtGate or a saved position), or to the Hub. It changes nothing on the author's object.",
      requires=["BP_ITRMapEntry.json"]))
