# Writes ../Specs/BP_ITRLevelAddon.json and ../Specs/BP_ITRLevelAddons.json (the BPGen specs of ITRLevelAddons' Blueprints). Plain Python 3, no editor:
#   python gen_addons.py
# BP_ITRLevelAddon: one per add-on. It makes the streaming entry of the add-on level (off), listens to its target level (a stock level such as the Hub) and
#   switches the add-on on while the target is shown and off while it is hidden; it hides the stock actors the manifest names. Events only: no Tick, no timer.
# BP_ITRLevelAddons: the manager. Place(Name, Level, TargetName, Hides) makes one BP_ITRLevelAddon. Nothing here runs a console command.
import os

from bpb import B, write

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Specs")
DIR = "/Game/Mods/ITRLevelAddons"
ADDON = DIR + "/BP_ITRLevelAddon.BP_ITRLevelAddon_C"
EM = "/Script/IntoTheRadius.EventsManager"
LS = "/Script/Engine.LevelStreaming"
ZERO = {"X": 0, "Y": 0, "Z": 0}
ROT0 = {"Pitch": 0, "Yaw": 0, "Roll": 0}


def streaming_level(b, name_src):
    """GetStreamingLevel(self, Conv_StringToName(name_src)); returns the call node (ReturnValue = LevelStreaming)"""
    n = b.call("KismetStringLibrary:Conv_StringToName")
    b.link(name_src, n + ".InString")
    g = b.call("GameplayStatics:GetStreamingLevel")
    b.link(b.me() + ".self", g + ".WorldContextObject")
    b.link(n + ".ReturnValue", g + ".PackageName")
    return g


def set_flags(b, inst_get_src, on, exec_from_pin):
    """SetShouldBeLoaded(on) then SetShouldBeVisible(on) on inst; returns (first, last)"""
    l = b.call("LevelStreaming:SetShouldBeLoaded", bInShouldBeLoaded=on)
    b.link(inst_get_src, l + ".self")
    v = b.call("LevelStreaming:SetShouldBeVisible", bInShouldBeVisible=on)
    b.link(inst_get_src, v + ".self")
    b.link(l + ".then", v + ".execute")
    if exec_from_pin:
        b.link(exec_from_pin, l + ".execute")
    return l, v


# ------------------------------------------------------------------------------------------------ BP_ITRLevelAddon
b = B()
# Start: make the entry, flags off, bind the add-on's own OnLevelShown, then bind the target
ev = b.event("Start")
nm = b.call("KismetStringLibrary:Conv_StringToName")
ll = b.call("LevelStreamingDynamic:LoadLevelInstance")
b.link(b.get("Loc") + ".Loc", ll + ".Location"); b.link(b.get("Rot") + ".Rot", ll + ".Rotation")
b.link(b.me() + ".self", ll + ".WorldContextObject")
b.link(b.get("LevelPath") + ".LevelPath", ll + ".LevelName")
b.link(b.get("AddonName") + ".AddonName", ll + ".OptionalLevelNameOverride")
sI = b.setv("Inst"); b.link(ll + ".ReturnValue", sI + ".Inst")
brOk = b.branch(); b.link(ll + ".bOutSuccess", brOk + ".Condition")
b.chain(ev, ll, sI)
mkT = b.call("KismetMathLibrary:MakeTransform"); b.link(b.get("Loc") + ".Loc", mkT + ".Location"); b.link(b.get("Rot") + ".Rot", mkT + ".Rotation"); b.link(b.get("Scale") + ".Scale", mkT + ".Scale")
sLT = b.add("set", var="LevelTransform", **{"class": LS}); b.link(b.get("Inst") + ".Inst", sLT + ".self"); b.link(mkT + ".ReturnValue", sLT + ".LevelTransform")
b.link(sI + ".then", sLT + ".execute"); b.link(sLT + ".then", brOk + ".execute")
cat = b.call("KismetStringLibrary:Concat_StrStr", A="level could not be loaded: "); b.link(b.get("LevelPath") + ".LevelPath", cat + ".B")
rep = b.setv("Report"); b.link(cat + ".ReturnValue", rep + ".Report"); b.link(brOk + ".False", rep + ".execute")
f1, f2 = set_flags(b, b.get("Inst") + ".Inst", False, brOk + ".True")
bs = b.bind(f2, "then", b.get("Inst") + ".Inst", LS, "OnLevelShown", "HAddonShown")
bh = b.call_me("BindHides"); b.link(bs + ".then", bh + ".execute")
bt = b.call_me("BindTarget"); b.link(bh + ".then", bt + ".execute")

# BindHides: every level named by a hide (other than the target) is listened to as well
ev = b.event("BindHides")
paH = b.call("KismetStringLibrary:ParseIntoArray", Delimiter=",", CullEmptyStrings=True); b.link(b.get("HideLevels") + ".HideLevels", paH + ".SourceString")
lpH = b.add("macro", macro="ForEachLoop"); b.link(paH + ".ReturnValue", lpH + ".Array"); b.link(ev + ".then", lpH + ".Exec")
bhc = b.add("call", function="BindHide"); b.link(b.me() + ".self", bhc + ".self"); b.link(lpH + ".ArrayElement", bhc + ".Nm"); b.link(lpH + ".LoopBody", bhc + ".execute")
ev = b.event("BindHide", [{"name": "Nm", "type": "string"}])
gH = streaming_level(b, ev + ".Nm")
vH = b.valid(gH + ".ReturnValue")
brH = b.branch(); b.link(vH + ".ReturnValue", brH + ".Condition"); b.link(ev + ".then", brH + ".execute")
b.bind(brH, "True", gH + ".ReturnValue", LS, "OnLevelShown", "HAddonShown")

# BindTarget: resolve the target's streaming entry; bind its shown / hidden; when it is not there yet, try again at the next level event (one bind, once)
ev = b.event("BindTarget")
g = streaming_level(b, b.get("TargetName") + ".TargetName")
sT = b.setv("Target"); b.link(g + ".ReturnValue", sT + ".Target")
vT = b.valid(b.get("Target") + ".Target")
brT = b.branch(); b.link(vT + ".ReturnValue", brT + ".Condition")
b.chain(ev, sT)
b.link(sT + ".then", brT + ".execute")
b1 = b.bind(brT, "True", b.get("Target") + ".Target", LS, "OnLevelShown", "HTargetShown")
b2 = b.bind(b1, "then", b.get("Target") + ".Target", LS, "OnLevelHidden", "HTargetHidden")
vis = b.call("LevelStreaming:IsLevelVisible"); b.link(b.get("Target") + ".Target", vis + ".self")
brV = b.branch(); b.link(vis + ".ReturnValue", brV + ".Condition"); b.link(b2 + ".then", brV + ".execute")
c = b.call_me("HTargetShown"); b.link(brV + ".True", c + ".execute")
brR = b.branch()
nR = b.call("KismetMathLibrary:Not_PreBool"); b.link(b.get("Retrying") + ".Retrying", nR + ".A"); b.link(nR + ".ReturnValue", brR + ".Condition")
b.link(brT + ".False", brR + ".execute")
sR = b.setv("Retrying", True); b.link(brR + ".True", sR + ".execute")
em = b.call("EventsManager:GetEventsManager")
b.bind(sR, "then", em + ".ReturnValue", EM, "OnLevelStarted", "HRetry")

# HRetry(Value): the target may exist now
ev = b.event("HRetry", [{"name": "Value", "type": "struct:GameplayTag"}])
vT2 = b.valid(b.get("Target") + ".Target")
nT2 = b.call("KismetMathLibrary:Not_PreBool"); b.link(vT2 + ".ReturnValue", nT2 + ".A")
brT2 = b.branch(); b.link(nT2 + ".ReturnValue", brT2 + ".Condition"); b.link(ev + ".then", brT2 + ".execute")
c = b.call_me("BindTarget"); b.link(brT2 + ".True", c + ".execute")

# HTargetShown / HTargetHidden: the add-on follows its target
for name, on in (("HTargetShown", True), ("HTargetHidden", False)):
    ev = b.event(name)
    v = b.valid(b.get("Inst") + ".Inst")
    br = b.branch(); b.link(v + ".ReturnValue", br + ".Condition"); b.link(ev + ".then", br + ".execute")
    set_flags(b, b.get("Inst") + ".Inst", on, br + ".True")

# HAddonShown: hide the stock actors of the manifest (every time the add-on is shown: the target may have been streamed in again)
ev = b.event("HAddonShown")
pa = b.call("KismetStringLibrary:ParseIntoArray", Delimiter=",", CullEmptyStrings=True)
b.link(b.get("Hides") + ".Hides", pa + ".SourceString")
lp = b.add("macro", macro="ForEachLoop"); b.link(pa + ".ReturnValue", lp + ".Array")
b.link(ev + ".then", lp + ".Exec")
h = b.add("call", function="HideOne"); b.link(b.me() + ".self", h + ".self"); b.link(lp + ".ArrayElement", h + ".Nm"); b.link(lp + ".LoopBody", h + ".execute")

# HideOne(Nm): the actor whose path ends in Nm (Lua writes each entry as "<level>:PersistentLevel.<actor>")
ev = b.event("HideOne", [{"name": "Nm", "type": "string"}])
ga = b.call("GameplayStatics:GetAllActorsOfClass", ActorClass="/Script/Engine.Actor"); b.link(b.me() + ".self", ga + ".WorldContextObject")
lp2 = b.add("macro", macro="ForEachLoop"); b.link(ga + ".OutActors", lp2 + ".Array")
sM0 = b.setv("Matched", False)
b.chain(ev, sM0, ga); b.link(ga + ".then", lp2 + ".Exec")
pn = b.call("KismetSystemLibrary:GetPathName"); b.link(lp2 + ".ArrayElement", pn + ".Object")
ew = b.call("KismetStringLibrary:EndsWith"); b.link(pn + ".ReturnValue", ew + ".SourceString"); b.link(ev + ".Nm", ew + ".InSuffix")
brE = b.branch(); b.link(ew + ".ReturnValue", brE + ".Condition"); b.link(lp2 + ".LoopBody", brE + ".execute")
hd = b.call("Actor:SetActorHiddenInGame", bNewHidden=True); b.link(lp2 + ".ArrayElement", hd + ".self"); b.link(brE + ".True", hd + ".execute")
co = b.call("Actor:SetActorEnableCollision", bNewActorEnableCollision=False); b.link(lp2 + ".ArrayElement", co + ".self"); b.link(hd + ".then", co + ".execute")
sM1 = b.setv("Matched", True); b.link(co + ".then", sM1 + ".execute")
# after the loop: the hide's level is shown, nobody matched, not said yet -> say it once
idx = b.call("KismetStringLibrary:FindSubstring", Substring=":"); b.link(ev + ".Nm", idx + ".SearchIn")
lvn = b.call("KismetStringLibrary:Left"); b.link(ev + ".Nm", lvn + ".SourceString"); b.link(idx + ".ReturnValue", lvn + ".Count")
gW = streaming_level(b, lvn + ".ReturnValue")
vW = b.valid(gW + ".ReturnValue")
visW = b.call("LevelStreaming:IsLevelVisible"); b.link(gW + ".ReturnValue", visW + ".self")
nM = b.call("KismetMathLibrary:Not_PreBool"); b.link(b.get("Matched") + ".Matched", nM + ".A")
nW = b.call("KismetMathLibrary:Not_PreBool"); b.link(b.get("HideWarned") + ".HideWarned", nW + ".A")
a1 = b.call("KismetMathLibrary:BooleanAND"); b.link(vW + ".ReturnValue", a1 + ".A"); b.link(visW + ".ReturnValue", a1 + ".B")
a2 = b.call("KismetMathLibrary:BooleanAND"); b.link(a1 + ".ReturnValue", a2 + ".A"); b.link(nM + ".ReturnValue", a2 + ".B")
a3 = b.call("KismetMathLibrary:BooleanAND"); b.link(a2 + ".ReturnValue", a3 + ".A"); b.link(nW + ".ReturnValue", a3 + ".B")
brW = b.branch(); b.link(a3 + ".ReturnValue", brW + ".Condition"); b.link(lp2 + ".Completed", brW + ".execute")
sHW = b.setv("HideWarned", True); b.link(brW + ".True", sHW + ".execute")
w1 = b.call("KismetStringLibrary:Concat_StrStr", A="itraddons log add-on "); b.link(b.get("AddonName") + ".AddonName", w1 + ".B")
w2 = b.call("KismetStringLibrary:Concat_StrStr", B=": hide "); b.link(w1 + ".ReturnValue", w2 + ".A")
w3 = b.call("KismetStringLibrary:Concat_StrStr"); b.link(w2 + ".ReturnValue", w3 + ".A"); b.link(ev + ".Nm", w3 + ".B")
w4 = b.call("KismetStringLibrary:Concat_StrStr", B=" matches no actor of its level"); b.link(w3 + ".ReturnValue", w4 + ".A")
wr = b.call("KismetSystemLibrary:ExecuteConsoleCommand"); b.link(w4 + ".ReturnValue", wr + ".Command"); b.link(b.me() + ".self", wr + ".WorldContextObject"); b.link(sHW + ".then", wr + ".execute")

addon_vars = [
    {"name": "AddonName", "type": "string", "default": ""}, {"name": "LevelPath", "type": "string", "default": ""}, {"name": "TargetName", "type": "string", "default": ""},
    {"name": "Hides", "type": "string", "default": ""}, {"name": "Loc", "type": "vector", "default": "0,0,0"}, {"name": "Rot", "type": "rotator"}, {"name": "Scale", "type": "vector", "default": "1,1,1"},
    {"name": "HideLevels", "type": "string", "default": ""}, {"name": "Matched", "type": "bool", "default": "false"}, {"name": "HideWarned", "type": "bool", "default": "false"}, {"name": "Report", "type": "string", "default": ""}, {"name": "Retrying", "type": "bool", "default": "false"},
    {"name": "Inst", "type": "object:/Script/Engine.LevelStreamingDynamic"}, {"name": "Target", "type": "object:/Script/Engine.LevelStreaming"},
]
write(os.path.join(OUT, "BP_ITRLevelAddon.json"), b.spec(DIR + "/BP_ITRLevelAddon", "/Script/Engine.Actor", addon_vars,
      "ITRLevelAddons: one add-on level. Start makes its streaming entry (switched off) and listens to the target level; while the target is shown the add-on is switched on, "
      "while it is hidden, off; the stock actors named in Hides are hidden when the add-on is shown. Report is read by Lua after Start. No Tick, no timer, no console command."))

# ------------------------------------------------------------------------------------------------ BP_ITRLevelAddons (the manager)
b = B()
ev = b.event("Place", [{"name": "AddonName", "type": "string"}, {"name": "LevelPath", "type": "string"}, {"name": "TargetName", "type": "string"}, {"name": "Hides", "type": "string"},
                {"name": "HideLevels", "type": "string"}, {"name": "Loc", "type": "vector"}, {"name": "Rot", "type": "rotator"}, {"name": "Scale", "type": "vector"}])
key = b.call("KismetStringLibrary:Concat_StrStr", A="|"); b.link(ev + ".AddonName", key + ".B")
key2 = b.call("KismetStringLibrary:Concat_StrStr", B="|"); b.link(key + ".ReturnValue", key2 + ".A")
ct = b.call("KismetStringLibrary:Contains"); b.link(b.get("Names") + ".Names", ct + ".SearchIn"); b.link(key2 + ".ReturnValue", ct + ".Substring")
lk1 = b.call("KismetStringLibrary:Concat_StrStr", A="|"); b.link(ev + ".LevelPath", lk1 + ".B")
lk2 = b.call("KismetStringLibrary:Concat_StrStr", B=">"); b.link(lk1 + ".ReturnValue", lk2 + ".A")
lk3 = b.call("KismetStringLibrary:Concat_StrStr"); b.link(lk2 + ".ReturnValue", lk3 + ".A"); b.link(ev + ".TargetName", lk3 + ".B")
lk4 = b.call("KismetStringLibrary:Concat_StrStr", B="|"); b.link(lk3 + ".ReturnValue", lk4 + ".A")
ct2 = b.call("KismetStringLibrary:Contains"); b.link(b.get("Keys") + ".Keys", ct2 + ".SearchIn"); b.link(lk4 + ".ReturnValue", ct2 + ".Substring")
orD = b.call("KismetMathLibrary:BooleanOR"); b.link(ct + ".ReturnValue", orD + ".A"); b.link(ct2 + ".ReturnValue", orD + ".B")
brD = b.branch(); b.link(orD + ".ReturnValue", brD + ".Condition"); b.link(ev + ".then", brD + ".execute")
sDup = b.setv("LastReport", "already placed (the same name, or the same level and target as another add-on): ignored"); b.link(brD + ".True", sDup + ".execute")
mk = b.call("KismetMathLibrary:MakeTransform", Scale="1,1,1")
sp = b.add("node", **{"class": "K2Node_SpawnActorFromClass", "pins": {"CollisionHandlingOverride": "AlwaysSpawn", "Class": ADDON}})
b.link(mk + ".ReturnValue", sp + ".SpawnTransform")
b.link(brD + ".False", sp + ".execute")
cs = b.add("cast", **{"class": ADDON, "pure": False}); b.link(sp + ".ReturnValue", cs + ".Object"); b.link(sp + ".then", cs + ".execute")
prev = cs
for var, src in (("AddonName", "AddonName"), ("LevelPath", "LevelPath"), ("TargetName", "TargetName"), ("Hides", "Hides"), ("HideLevels", "HideLevels"), ("Loc", "Loc"), ("Rot", "Rot"), ("Scale", "Scale")):
    s = b.add("set", var=var, **{"class": ADDON}); b.link(cs + ".as", s + ".self"); b.link(ev + "." + src, s + "." + var)
    b.link(prev + ".then", s + ".execute")
    prev = s
st = b.add("call", function=ADDON + ":Start"); b.link(cs + ".as", st + ".self"); b.link(prev + ".then", st + ".execute")
rp = b.setv("LastReport"); gr = b.add("get", var="Report", **{"class": ADDON}); b.link(cs + ".as", gr + ".self"); b.link(gr + ".Report", rp + ".LastReport")
b.link(st + ".then", rp + ".execute")
nm = b.setv("Names"); cn = b.call("KismetStringLibrary:Concat_StrStr"); b.link(b.get("Names") + ".Names", cn + ".A"); b.link(key2 + ".ReturnValue", cn + ".B")
b.link(cn + ".ReturnValue", nm + ".Names"); b.link(rp + ".then", nm + ".execute")
kk = b.setv("Keys"); ck = b.call("KismetStringLibrary:Concat_StrStr"); b.link(b.get("Keys") + ".Keys", ck + ".A"); b.link(lk4 + ".ReturnValue", ck + ".B")
b.link(ck + ".ReturnValue", kk + ".Keys"); b.link(nm + ".then", kk + ".execute")
mgr_vars = [{"name": "Names", "type": "string", "default": "|"}, {"name": "Keys", "type": "string", "default": "|"}, {"name": "LastReport", "type": "string", "default": ""}]
write(os.path.join(OUT, "BP_ITRLevelAddons.json"), b.spec(DIR + "/BP_ITRLevelAddons", "/Script/Engine.Actor", mgr_vars,
      "ITRLevelAddons manager. Place(AddonName, LevelPath, TargetName, Hides, HideLevels, Loc, Rot, Scale) makes one BP_ITRLevelAddon (a name already placed is ignored) and leaves its Report in LastReport.",
      requires=["BP_ITRLevelAddon.json"]))
