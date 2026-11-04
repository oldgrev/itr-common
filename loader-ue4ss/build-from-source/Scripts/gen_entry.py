# Writes ../Specs/BP_ITRMapEntry.json and ../Specs/BP_ITRMapManager.json (BPGen specs of ITRMapLoader's map Blueprints). Plain Python 3, no editor:
#   python gen_entry.py
# BP_ITRMapEntry: one per form map. Enter() is the one way into the map (a Regions row and every trigger call it): hand-back, return point, saved arrival position, transfer.
#   It listens to the game's level events: it saves the position again on the transition and level-prepare events (the game overwrites it) and moves the player
#   to it on arrival when the game put them more than 30 m away. StoreReturn() writes the return point; no Tick, no timer.
# BP_ITRMapManager: one. It tells Lua once, at the first level change after the game started, that the game's level table may be grown (the registration), and
#   carries the add-on requests for ITRLevelAddons. Events only.
import os

from bpb import B, write

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Specs")
DIR = "/Game/Mods/ITRMapLoader"
EM = "/Script/IntoTheRadius.EventsManager"
GAMEDATA = "/Script/IntoTheRadius.PRGameData"
PREFIX = "ITRReturn:"


def console(b, text_src=None, literal=None):
    """ExecuteConsoleCommand; returns the node. text_src = a string pin ('node.pin'); literal = fixed text"""
    run = b.call("KismetSystemLibrary:ExecuteConsoleCommand")
    if text_src:
        b.link(text_src, run + ".Command")
    else:
        run_pins = {"Command": literal}
        b.nodes[-1]["pins"] = run_pins
    b.link(b.me() + ".self", run + ".WorldContextObject")
    return run


def concat(b, a_src=None, b_src=None, a=None, bl=None):
    c = b.call("KismetStringLibrary:Concat_StrStr", **({"A": a} if a is not None else {}), **({"B": bl} if bl is not None else {}))
    if a_src:
        b.link(a_src, c + ".A")
    if b_src:
        b.link(b_src, c + ".B")
    return c


def elog(b, text, tail_src=None):
    """console 'itrmaps log map <MapName> <text> [tail]': the line Lua prints. Returns the run node (exec in on .execute, out on .then)"""
    c1 = b.call("KismetStringLibrary:Concat_StrStr", A="itrmaps log map "); b.link(b.get("MapName") + ".MapName", c1 + ".B")
    c2 = b.call("KismetStringLibrary:Concat_StrStr", B=text); b.link(c1 + ".ReturnValue", c2 + ".A")
    last = c2
    if tail_src:
        c3 = b.call("KismetStringLibrary:Concat_StrStr"); b.link(c2 + ".ReturnValue", c3 + ".A"); b.link(tail_src, c3 + ".B"); last = c3
    run = b.call("KismetSystemLibrary:ExecuteConsoleCommand"); b.link(last + ".ReturnValue", run + ".Command"); b.link(b.me() + ".self", run + ".WorldContextObject")
    return run


def game_data(b):
    return b.call("PRGameData:GetGameData")


def not_in_transition(b, from_src, after_pin_src):
    """cast game mode to IPRGameModeNative, GetIsInTransition; returns the branch node. exec: from_src ('node.pin') into the cast; its False continues"""
    gm = b.call("GameplayStatics:GetGameMode"); b.link(b.me() + ".self", gm + ".WorldContextObject")
    asN = b.add("cast", **{"class": "IPRGameModeNative"}); b.link(gm + ".ReturnValue", asN + ".Object"); b.link(from_src, asN + ".execute")
    inTr = b.call("IPRGameModeNative:GetIsInTransition"); b.link(asN + ".as", inTr + ".self"); b.link(asN + ".then", inTr + ".execute")
    br = b.branch(); b.link(inTr + ".ReturnValue", br + ".Condition"); b.link(inTr + ".then", br + ".execute")
    return br


# =============================================================================================================== BP_ITRMapEntry
b = B()
# ---- Start: the level events
ev = b.event("Start")
em = b.call("EventsManager:GetEventsManager")
n1 = b.bind(ev, "then", em + ".ReturnValue", EM, "OnTransitionStart", "HTStart")
n2 = b.bind(n1, "then", em + ".ReturnValue", EM, "OnLevelPrepare", "HLPrepare")
n3 = b.bind(n2, "then", em + ".ReturnValue", EM, "OnTransitionEnd", "HTEnd")

# ---- SavePos: the arrival position for this level (the game's own position slot, read first by TransferToLevel)
ev = b.event("SavePos")
brH = b.branch(); b.link(b.get("HasPos") + ".HasPos", brH + ".Condition"); b.link(ev + ".then", brH + ".execute")
gd = game_data(b)
mk = b.call("KismetMathLibrary:MakeTransform", Scale="1,1,1"); b.link(b.get("PosLoc") + ".PosLoc", mk + ".Location")
rt = b.call("KismetMathLibrary:MakeRotator", Roll=0, Pitch=0); b.link(b.get("PosYaw") + ".PosYaw", rt + ".Yaw"); b.link(rt + ".ReturnValue", mk + ".Rotation")
pd = b.add("get", var="PlayerData", **{"class": GAMEDATA}); b.link(gd + ".GameData", pd + ".self")
sp = b.call("PlayerGameData:SavePosition", Velocity="0,0,0")
b.link(pd + ".PlayerData", sp + ".self"); b.link(b.get("LevelTag") + ".LevelTag", sp + ".InLevel"); b.link(mk + ".ReturnValue", sp + ".Position")
b.link(brH + ".True", sp + ".execute")

# ---- HTStart / HLPrepare: save it again while a transfer to this map is pending
ev = b.event("HTStart")
brP = b.branch(); b.link(b.get("Pending") + ".Pending", brP + ".Condition"); b.link(ev + ".then", brP + ".execute")
c = b.call_me("SavePos"); b.link(brP + ".True", c + ".execute")
ev = b.event("HLPrepare", [{"name": "Value", "type": "struct:GameplayTag"}])
brP = b.branch(); b.link(b.get("Pending") + ".Pending", brP + ".Condition"); b.link(ev + ".then", brP + ".execute")
c = b.call_me("SavePos"); b.link(brP + ".True", c + ".execute")

# ---- HTEnd: arrived in this map? the game may have put the player far from the saved position: move them
ev = b.event("HTEnd")
brP = b.branch(); b.link(b.get("Pending") + ".Pending", brP + ".Condition"); b.link(ev + ".then", brP + ".execute")
gd2 = game_data(b)
ct = b.add("get", var="CurrentLevelTag", **{"class": GAMEDATA}); b.link(gd2 + ".GameData", ct + ".self")
eq = b.call("BlueprintGameplayTagLibrary:EqualEqual_GameplayTag"); b.link(ct + ".CurrentLevelTag", eq + ".A"); b.link(b.get("LevelTag") + ".LevelTag", eq + ".B")
brT = b.branch(); b.link(eq + ".ReturnValue", brT + ".Condition"); b.link(brP + ".True", brT + ".execute")
pw = b.call("GameplayStatics:GetPlayerPawn", PlayerIndex=0); b.link(b.me() + ".self", pw + ".WorldContextObject")
loc = b.call("Actor:K2_GetActorLocation"); b.link(pw + ".ReturnValue", loc + ".self")
dist = b.call("KismetMathLibrary:Vector_Distance"); b.link(loc + ".ReturnValue", dist + ".V1"); b.link(b.get("PosLoc") + ".PosLoc", dist + ".V2")
far = b.call("KismetMathLibrary:Greater_FloatFloat", B=3000.0); b.link(dist + ".ReturnValue", far + ".A")
both = b.call("KismetMathLibrary:BooleanAND"); b.link(far + ".ReturnValue", both + ".A"); b.link(b.get("HasPos") + ".HasPos", both + ".B")
brF = b.branch(); b.link(both + ".ReturnValue", brF + ".Condition"); b.link(brT + ".True", brF + ".execute")
rt2 = b.call("KismetMathLibrary:MakeRotator", Roll=0, Pitch=0); b.link(b.get("PosYaw") + ".PosYaw", rt2 + ".Yaw")
tp = b.call("Actor:K2_TeleportTo"); b.link(pw + ".ReturnValue", tp + ".self"); b.link(b.get("PosLoc") + ".PosLoc", tp + ".DestLocation"); b.link(rt2 + ".ReturnValue", tp + ".DestRotation")
b.link(brF + ".True", tp + ".execute")
vs = b.call("KismetStringLibrary:Conv_VectorToString"); b.link(loc + ".ReturnValue", vs + ".InVec")
lga = elog(b, ": arrived at ", vs + ".ReturnValue"); b.link(tp + ".then", lga + ".execute"); b.link(brF + ".False", lga + ".execute")
clr = b.setv("Pending", False); b.link(lga + ".then", clr + ".execute"); b.link(brT + ".False", clr + ".execute")

# ---- LoadReturn: the stored return point of ReturnKey (the last "ITRReturn:<key>=x,y,z,yaw" in the save's markers) into ReturnLoc / ReturnYaw / HasReturn
ev = b.event("LoadReturn")
s0 = b.setv("HasReturn", False); b.chain(ev, s0)
brK = b.branch(); ne = b.call("KismetStringLibrary:NotEqual_StriStri", B=""); b.link(b.get("ReturnKey") + ".ReturnKey", ne + ".A"); b.link(ne + ".ReturnValue", brK + ".Condition"); b.link(s0 + ".then", brK + ".execute")
gd3 = game_data(b)
cm = b.add("get", var="CustomMarkers", **{"class": GAMEDATA}); b.link(gd3 + ".GameData", cm + ".self")
pre = concat(b, b_src=None, a=PREFIX); b.link(b.get("ReturnKey") + ".ReturnKey", pre + ".B")
want = concat(b, a_src=pre + ".ReturnValue", bl="=")
lp = b.add("macro", macro="ForEachLoop"); b.link(cm + ".CustomMarkers", lp + ".Array"); b.link(brK + ".True", lp + ".Exec")
sw = b.call("KismetStringLibrary:StartsWith"); b.link(lp + ".ArrayElement", sw + ".SourceString"); b.link(want + ".ReturnValue", sw + ".InPrefix")
brS = b.branch(); b.link(sw + ".ReturnValue", brS + ".Condition"); b.link(lp + ".LoopBody", brS + ".execute")
ln = b.call("KismetStringLibrary:Len"); b.link(want + ".ReturnValue", ln + ".S")
rest = b.call("KismetStringLibrary:Mid", Count=200); b.link(lp + ".ArrayElement", rest + ".SourceString"); b.link(ln + ".ReturnValue", rest + ".Start")
pa = b.call("KismetStringLibrary:ParseIntoArray", Delimiter=",", CullEmptyStrings=True); b.link(rest + ".ReturnValue", pa + ".SourceString")
parts = b.setv("Parts"); b.link(pa + ".ReturnValue", parts + ".Parts"); b.link(brS + ".True", parts + ".execute")
def part(i):
    g = b.call("KismetArrayLibrary:Array_Get", Index=i); b.link(b.get("Parts") + ".Parts", g + ".TargetArray")
    f = b.call("KismetStringLibrary:Conv_StringToFloat"); b.link(g + ".Item", f + ".InString")
    return f
mkv = b.call("KismetMathLibrary:MakeVector"); b.link(part(0) + ".ReturnValue", mkv + ".X"); b.link(part(1) + ".ReturnValue", mkv + ".Y"); b.link(part(2) + ".ReturnValue", mkv + ".Z")
sL = b.setv("ReturnLoc"); b.link(mkv + ".ReturnValue", sL + ".ReturnLoc"); b.link(parts + ".then", sL + ".execute")
sY = b.setv("ReturnYaw"); b.link(part(3) + ".ReturnValue", sY + ".ReturnYaw"); b.link(sL + ".then", sY + ".execute")
sHR = b.setv("HasReturn", True); b.link(sY + ".then", sHR + ".execute")

# ---- StoreReturn: remove the old markers of the key, write the player's place now
ev = b.event("StoreReturn")
brK2 = b.branch(); ne2 = b.call("KismetStringLibrary:NotEqual_StriStri", B=""); b.link(b.get("ReturnKey") + ".ReturnKey", ne2 + ".A"); b.link(ne2 + ".ReturnValue", brK2 + ".Condition"); b.link(ev + ".then", brK2 + ".execute")
gd4 = game_data(b)
cm2 = b.add("get", var="CustomMarkers", **{"class": GAMEDATA}); b.link(gd4 + ".GameData", cm2 + ".self")
pre2 = concat(b, a=PREFIX); b.link(b.get("ReturnKey") + ".ReturnKey", pre2 + ".B")
want2 = concat(b, a_src=pre2 + ".ReturnValue", bl="=")
lp2 = b.add("macro", macro="ForEachLoop"); b.link(cm2 + ".CustomMarkers", lp2 + ".Array"); b.link(brK2 + ".True", lp2 + ".Exec")
sw2 = b.call("KismetStringLibrary:StartsWith"); b.link(lp2 + ".ArrayElement", sw2 + ".SourceString"); b.link(want2 + ".ReturnValue", sw2 + ".InPrefix")
brS2 = b.branch(); b.link(sw2 + ".ReturnValue", brS2 + ".Condition"); b.link(lp2 + ".LoopBody", brS2 + ".execute")
um1 = b.call("PRGameData:UpdateMarker", bRemove=True); b.link(gd4 + ".GameData", um1 + ".self"); b.link(lp2 + ".ArrayElement", um1 + ".Marker"); b.link(brS2 + ".True", um1 + ".execute")
pw2 = b.call("GameplayStatics:GetPlayerPawn", PlayerIndex=0); b.link(b.me() + ".self", pw2 + ".WorldContextObject")
l2 = b.call("Actor:K2_GetActorLocation"); b.link(pw2 + ".ReturnValue", l2 + ".self")
r2 = b.call("Actor:K2_GetActorRotation"); b.link(pw2 + ".ReturnValue", r2 + ".self")
def fstr(src):
    f = b.call("KismetStringLibrary:Conv_FloatToString"); b.link(src, f + ".InFloat"); return f + ".ReturnValue"
bx = b.call("KismetMathLibrary:BreakVector"); b.link(l2 + ".ReturnValue", bx + ".InVec")
br_ = b.call("KismetMathLibrary:BreakRotator"); b.link(r2 + ".ReturnValue", br_ + ".InRot")
c_a = concat(b, a_src=want2 + ".ReturnValue", b_src=fstr(bx + ".X"))
c_b = concat(b, a_src=c_a + ".ReturnValue", bl=","); c_c = concat(b, a_src=c_b + ".ReturnValue", b_src=fstr(bx + ".Y"))
c_d = concat(b, a_src=c_c + ".ReturnValue", bl=","); c_e = concat(b, a_src=c_d + ".ReturnValue", b_src=fstr(bx + ".Z"))
c_f = concat(b, a_src=c_e + ".ReturnValue", bl=","); c_g = concat(b, a_src=c_f + ".ReturnValue", b_src=fstr(br_ + ".Yaw"))
um2 = b.call("PRGameData:UpdateMarker", bRemove=False); b.link(gd4 + ".GameData", um2 + ".self"); b.link(c_g + ".ReturnValue", um2 + ".Marker")
b.link(lp2 + ".Completed", um2 + ".execute")
lgs = elog(b, ": return point saved: ", c_g + ".ReturnValue"); b.link(um2 + ".then", lgs + ".execute")

# ---- Enter
ev = b.event("Enter")
brT0 = not_in_transition(b, ev + ".then", None)
brHb = b.branch(); b.link(brT0 + ".False", brHb + ".execute"); b.link(b.get("Handback") + ".Handback", brHb + ".Condition")
c1 = concat(b, bl=" enter "); b.link(b.get("Command") + ".Command", c1 + ".A")
c2 = concat(b, a_src=c1 + ".ReturnValue"); b.link(b.get("MapName") + ".MapName", c2 + ".B")
run = console(b, text_src=c2 + ".ReturnValue"); b.link(brHb + ".True", run + ".execute")
lr = b.call_me("LoadReturn"); b.link(brHb + ".False", lr + ".execute")
brR = b.branch(); b.link(b.get("HasReturn") + ".HasReturn", brR + ".Condition"); b.link(lr + ".then", brR + ".execute")
sA = b.setv("PosLoc"); b.link(b.get("ReturnLoc") + ".ReturnLoc", sA + ".PosLoc"); b.link(brR + ".True", sA + ".execute")
sB = b.setv("PosYaw"); b.link(b.get("ReturnYaw") + ".ReturnYaw", sB + ".PosYaw"); b.link(sA + ".then", sB + ".execute")
sC = b.setv("HasPos", True); b.link(sB + ".then", sC + ".execute")
sD = b.setv("PosLoc"); b.link(b.get("StartLoc") + ".StartLoc", sD + ".PosLoc"); b.link(brR + ".False", sD + ".execute")
sE = b.setv("PosYaw"); b.link(b.get("StartYaw") + ".StartYaw", sE + ".PosYaw"); b.link(sD + ".then", sE + ".execute")
sF = b.setv("HasPos"); b.link(b.get("HasStart") + ".HasStart", sF + ".HasPos"); b.link(sE + ".then", sF + ".execute")
sv = b.call_me("SavePos"); b.link(sC + ".then", sv + ".execute"); b.link(sF + ".then", sv + ".execute")
gm = b.call("GameplayStatics:GetGameMode"); b.link(b.me() + ".self", gm + ".WorldContextObject")
asG = b.add("cast", **{"class": "IPRGameMode"}); b.link(gm + ".ReturnValue", asG + ".Object"); b.link(sv + ".then", asG + ".execute")
go = b.call("IPRGameMode:TransferToLevel"); b.link(asG + ".as", go + ".self"); b.link(b.get("LevelTag") + ".LevelTag", go + ".LevelTag"); b.link(asG + ".then", go + ".execute")
rb = b.call("KismetStringLibrary:Conv_BoolToString"); b.link(go + ".ReturnValue", rb + ".InBool")
lg = elog(b, ": TransferToLevel -> ", rb + ".ReturnValue"); b.link(go + ".then", lg + ".execute")
brG = b.branch(); b.link(go + ".ReturnValue", brG + ".Condition"); b.link(lg + ".then", brG + ".execute")
sPd = b.setv("Pending", True); b.link(brG + ".True", sPd + ".execute")

# ---- the variables
entry_vars = [
    {"name": "MapName", "type": "string", "default": ""}, {"name": "Display", "type": "string", "default": ""}, {"name": "LevelTag", "type": "struct:GameplayTag"},
    {"name": "HasStart", "type": "bool", "default": "false"}, {"name": "StartLoc", "type": "vector", "default": "0,0,0"}, {"name": "StartYaw", "type": "float", "default": "0"},
    {"name": "ReturnKey", "type": "string", "default": ""}, {"name": "Command", "type": "string", "default": ""}, {"name": "Handback", "type": "bool", "default": "false"},
    {"name": "Pending", "type": "bool", "default": "false"}, {"name": "HasPos", "type": "bool", "default": "false"}, {"name": "PosLoc", "type": "vector", "default": "0,0,0"},
    {"name": "PosYaw", "type": "float", "default": "0"}, {"name": "HasReturn", "type": "bool", "default": "false"}, {"name": "ReturnLoc", "type": "vector", "default": "0,0,0"},
    {"name": "ReturnYaw", "type": "float", "default": "0"}, {"name": "Parts", "type": "string[]"},
]
write(os.path.join(OUT, "BP_ITRMapEntry.json"), b.spec(DIR + "/BP_ITRMapEntry", "/Script/Engine.Actor", entry_vars,
      "ITRMapLoader: one form map. Enter() is the one way into the map. Hand-back forms run '<Command> enter <MapName>'. Otherwise it reads the return point, saves the arrival position, "
      "transfers, and on arrival moves the player to the saved position if the game put them more than 30 m away. StoreReturn() writes the return point. No Tick, no timer."))

# =============================================================================================================== BP_ITRMapManager
b = B()
ev = b.event("Start")
em = b.call("EventsManager:GetEventsManager")
b.bind(ev, "then", em + ".ReturnValue", EM, "OnTransitionEnd", "HTEnd")
ev = b.event("HTEnd")
brG = b.branch(); nR = b.call("KismetMathLibrary:Not_PreBool"); b.link(b.get("Registered") + ".Registered", nR + ".A"); b.link(nR + ".ReturnValue", brG + ".Condition"); b.link(ev + ".then", brG + ".execute")
sR = b.setv("Registered", True); b.link(brG + ".True", sR + ".execute")
run = b.call("KismetSystemLibrary:ExecuteConsoleCommand", Command="itrmaps register"); b.link(b.me() + ".self", run + ".WorldContextObject"); b.link(sR + ".then", run + ".execute")
write(os.path.join(OUT, "BP_ITRMapManager.json"), b.spec(DIR + "/BP_ITRMapManager", "/Script/Engine.Actor",
      [{"name": "Registered", "type": "bool", "default": "false"}, {"name": "Requests", "type": "string", "default": ""}],
      "ITRMapLoader manager: at the first level change after it started it runs the console command 'itrmaps register' once (Lua grows the game's level table then); Requests carries the add-on "
      "requests ('name|level|target;...') for ITRLevelAddons. No Tick, no timer."))
