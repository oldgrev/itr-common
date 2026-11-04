# Writes ../Specs/BP_ITRRegions.json (the Regions page on the Hub computer, as a Blueprint). Plain Python 3, no editor:
#   python gen_regions.py
# Lua does two things for this page: it writes the rows' text onto BP_ITRRegions (Rows) and calls PageBuilt from its one WBP_MCPage_Main_C:Construct hook
# (a Blueprint cannot see that event). Everything else is Blueprint: showing and renaming the stock spare row, releasing a held laser press, the press on it,
# the page switch (what the stock computer does for its Tapes page), the rows (the stock tape-row widget, created here), and a row's press.
# The stock widget classes are named by path; WBP_Element_TapeRecord (Text_RecordName, Button_TapeRecord) and WBP_MCPage_Tapes (SB_Tapes) are project stubs that are not packed.
# No Tick, no timer.
import os

from bpb import B, write

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Specs")
DIR = "/Game/Mods/ITRMapLoader"
ROW = "/Game/ITR/BPs/UI/PagesElements/WBP_Element_TapeRecord.WBP_Element_TapeRecord_C"
TAPES = "/Game/ITR/BPs/UI/ComputersPages/WBP_MCPage_Tapes.WBP_MCPage_Tapes_C"
ENTRY = DIR + "/BP_ITRMapEntry.BP_ITRMapEntry_C"
RS = "\u001e"      # between rows
US = "\u001f"      # between a row's map name and its text


def say(b, text, tail_src=None):
    """console 'itrmaps log regions: <text>[tail]': Lua prints the line. Returns the run node"""
    c1 = b.call("KismetStringLibrary:Concat_StrStr", A="itrmaps log regions: ", B=text)
    last = c1
    if tail_src:
        c2 = b.call("KismetStringLibrary:Concat_StrStr"); b.link(c1 + ".ReturnValue", c2 + ".A"); b.link(tail_src, c2 + ".B"); last = c2
    run = b.call("KismetSystemLibrary:ExecuteConsoleCommand"); b.link(last + ".ReturnValue", run + ".Command"); b.link(b.me() + ".self", run + ".WorldContextObject")
    return run


def press_row(b, name_src, exec_from):
    """find the BP_ITRMapEntry whose MapName is name_src and call Enter on it"""
    ga = b.call("GameplayStatics:GetAllActorsOfClass", ActorClass=ENTRY); b.link(b.me() + ".self", ga + ".WorldContextObject")
    lp = b.add("macro", macro="ForEachLoop"); b.link(ga + ".OutActors", lp + ".Array")
    b.link(exec_from, ga + ".execute"); b.link(ga + ".then", lp + ".Exec")
    cs = b.add("cast", **{"class": ENTRY, "pure": False}); b.link(lp + ".ArrayElement", cs + ".Object"); b.link(lp + ".LoopBody", cs + ".execute")
    mn = b.add("get", var="MapName", **{"class": ENTRY}); b.link(cs + ".as", mn + ".self")
    eq = b.call("KismetStringLibrary:EqualEqual_StriStri"); b.link(mn + ".MapName", eq + ".A"); b.link(name_src, eq + ".B")
    br = b.branch(); b.link(eq + ".ReturnValue", br + ".Condition"); b.link(cs + ".then", br + ".execute")
    en = b.add("call", function=ENTRY + ":Enter"); b.link(cs + ".as", en + ".self"); b.link(br + ".True", en + ".execute")


# =============================================================================================================== BP_ITRRegions
b = B()
# ---- PageBuilt(Btn, Txt, WcIn): the Hub page was built (Lua's Construct hook): show and rename the spare row, release a held laser press, bind the row once
ev = b.event("PageBuilt", [{"name": "Btn", "type": "object:/Script/UMG.Button"}, {"name": "Txt", "type": "object:/Script/UMG.TextBlock"},
                           {"name": "WcIn", "type": "object:/Script/UMG.WidgetComponent"}])
sW = b.setv("Wc"); b.link(ev + ".WcIn", sW + ".Wc")
own = b.call("ActorComponent:GetOwner"); b.link(ev + ".WcIn", own + ".self")
sC = b.setv("Computer"); b.link(own + ".ReturnValue", sC + ".Computer")
vis = b.call("Widget:SetVisibility", InVisibility="Visible"); b.link(ev + ".Btn", vis + ".self")
ct = b.call("KismetTextLibrary:Conv_StringToText", InString="REGIONS")
st = b.call("TextBlock:SetText"); b.link(ev + ".Txt", st + ".self"); b.link(ct + ".ReturnValue", st + ".InText")
ru = b.call("WidgetComponent:RequestRenderUpdate"); b.link(ev + ".WcIn", ru + ".self")
rel = b.call_me("ReleaseHeld")
b.chain(ev, sW, sC, vis, st, ru, rel)
lgP = say(b, "page built: the REGIONS row is shown, a held laser press is released"); b.link(rel + ".then", lgP + ".execute")
eqB = b.call("KismetMathLibrary:EqualEqual_ObjectObject"); b.link(ev + ".Btn", eqB + ".A"); b.link(b.get("BoundBtn") + ".BoundBtn", eqB + ".B")
nB = b.call("KismetMathLibrary:Not_PreBool"); b.link(eqB + ".ReturnValue", nB + ".A")
brB = b.branch(); b.link(nB + ".ReturnValue", brB + ".Condition"); b.link(lgP + ".then", brB + ".execute")
sBB = b.setv("BoundBtn"); b.link(ev + ".Btn", sBB + ".BoundBtn"); b.link(brB + ".True", sBB + ".execute")
b.bind(sBB, "then", ev + ".Btn", "/Script/UMG.Button", "OnPressed", "HLog")

# ---- ReleaseHeld: a laser press still down when a level change began never gets its release (the player only releases with a widget hovered): release on every laser
ev = b.event("ReleaseHeld")
pw = b.call("GameplayStatics:GetPlayerPawn", PlayerIndex=0); b.link(b.me() + ".self", pw + ".WorldContextObject")
comps = b.call("Actor:K2_GetComponentsByClass", ComponentClass="/Script/UMG.WidgetInteractionComponent"); b.link(pw + ".ReturnValue", comps + ".self")
lp = b.add("macro", macro="ForEachLoop"); b.link(comps + ".ReturnValue", lp + ".Array"); b.link(ev + ".then", lp + ".Exec")
cs = b.add("cast", **{"class": "/Script/UMG.WidgetInteractionComponent", "pure": False}); b.link(lp + ".ArrayElement", cs + ".Object"); b.link(lp + ".LoopBody", cs + ".execute")
rp = b.call("WidgetInteractionComponent:ReleasePointerKey", Key="LeftMouseButton"); b.link(cs + ".as", rp + ".self"); b.link(cs + ".then", rp + ".execute")

# ---- HLog: the REGIONS row was pressed: show the Tapes page the way the stock computer does, and fill it with one row per map
ev = b.event("HLog")
b.chain(ev, b.call_me("SwitchPage"))

ev = b.event("SwitchPage")
gc = b.call("Actor:K2_GetComponentsByClass", ComponentClass="/Script/UMG.WidgetComponent"); b.link(b.get("Computer") + ".Computer", gc + ".self")
lp = b.add("macro", macro="ForEachLoop"); b.link(gc + ".ReturnValue", lp + ".Array"); b.link(ev + ".then", lp + ".Exec")
cw = b.add("cast", **{"class": "/Script/UMG.WidgetComponent", "pure": False}); b.link(lp + ".ArrayElement", cw + ".Object"); b.link(lp + ".LoopBody", cw + ".execute")
nm = b.call("KismetSystemLibrary:GetObjectName"); b.link(cw + ".as", nm + ".Object")
isPage = b.call("KismetStringLibrary:StartsWith", InPrefix="WC_Page_"); b.link(nm + ".ReturnValue", isPage + ".SourceString")
isBg = b.call("KismetStringLibrary:Contains", Substring="Background"); b.link(nm + ".ReturnValue", isBg + ".SearchIn")
notBg = b.call("KismetMathLibrary:Not_PreBool"); b.link(isBg + ".ReturnValue", notBg + ".A")
both = b.call("KismetMathLibrary:BooleanAND"); b.link(isPage + ".ReturnValue", both + ".A"); b.link(notBg + ".ReturnValue", both + ".B")
brP = b.branch(); b.link(both + ".ReturnValue", brP + ".Condition"); b.link(cw + ".then", brP + ".execute")
hide = b.call("SceneComponent:SetHiddenInGame", NewHidden=True, bPropagateToChildren=False); b.link(cw + ".as", hide + ".self"); b.link(brP + ".True", hide + ".execute")
noc = b.call("PrimitiveComponent:SetCollisionEnabled", NewType="NoCollision"); b.link(cw + ".as", noc + ".self"); b.link(hide + ".then", noc + ".execute")
isT = b.call("KismetStringLibrary:Contains", Substring="Tapes"); b.link(nm + ".ReturnValue", isT + ".SearchIn")
brT = b.branch(); b.link(isT + ".ReturnValue", brT + ".Condition"); b.link(noc + ".then", brT + ".execute")
show = b.call("SceneComponent:SetHiddenInGame", NewHidden=False, bPropagateToChildren=False); b.link(cw + ".as", show + ".self"); b.link(brT + ".True", show + ".execute")
qo = b.call("PrimitiveComponent:SetCollisionEnabled", NewType="QueryOnly"); b.link(cw + ".as", qo + ".self"); b.link(show + ".then", qo + ".execute")
sTc = b.setv("TapesWc"); b.link(cw + ".as", sTc + ".TapesWc"); b.link(qo + ".then", sTc + ".execute")
fl = b.call_me("FillRows"); b.link(lp + ".Completed", fl + ".execute")

# ---- FillRows: clear the Tapes page's scroll box, then one row (the stock tape-row widget) per map
ev = b.event("FillRows")
uw = b.call("WidgetComponent:GetUserWidgetObject"); b.link(b.get("TapesWc") + ".TapesWc", uw + ".self")
pg = b.add("cast", **{"class": TAPES, "pure": False}); b.link(uw + ".ReturnValue", pg + ".Object"); b.link(ev + ".then", pg + ".execute")
sb = b.add("get", var="SB_Tapes", **{"class": TAPES}); b.link(pg + ".as", sb + ".self")
cl = b.call("PanelWidget:ClearChildren"); b.link(sb + ".SB_Tapes", cl + ".self"); b.link(pg + ".then", cl + ".execute")
# the rows of the last time are forgotten (their buttons are gone with the page's children)
clr = b.call("KismetArrayLibrary:Array_Clear"); b.link(b.get("RowButtons") + ".RowButtons", clr + ".TargetArray"); b.link(cl + ".then", clr + ".execute")
clr2 = b.call("KismetArrayLibrary:Array_Clear"); b.link(b.get("RowNames") + ".RowNames", clr2 + ".TargetArray"); b.link(clr + ".then", clr2 + ".execute")
rows = b.call("KismetStringLibrary:ParseIntoArray", Delimiter=RS, CullEmptyStrings=True); b.link(b.get("Rows") + ".Rows", rows + ".SourceString")
rl = b.add("macro", macro="ForEachLoop"); b.link(rows + ".ReturnValue", rl + ".Array"); b.link(clr2 + ".then", rl + ".Exec")
mk = b.call_me("MakeRow"); b.link(rl + ".ArrayElement", mk + ".Rec"); b.link(rl + ".LoopBody", mk + ".execute")
nRows = b.call("KismetArrayLibrary:Array_Length"); b.link(b.get("RowNames") + ".RowNames", nRows + ".TargetArray")
nStr = b.call("KismetStringLibrary:Conv_IntToString"); b.link(nRows + ".ReturnValue", nStr + ".InInt")
rd = b.call("WidgetComponent:RequestRenderUpdate"); b.link(b.get("TapesWc") + ".TapesWc", rd + ".self"); b.link(rl + ".Completed", rd + ".execute")
lgO = say(b, "page opened: rows ", nStr + ".ReturnValue"); b.link(rd + ".then", lgO + ".execute")
vis = b.call("SceneComponent:IsVisible"); b.link(b.get("Wc") + ".Wc", vis + ".self")
vs = b.call("KismetStringLibrary:Conv_BoolToString"); b.link(vis + ".ReturnValue", vs + ".InBool")
lgV = say(b, "main page visible after the switch: ", vs + ".ReturnValue"); b.link(lgO + ".then", lgV + ".execute")
# MakeRow(Rec): "<MapName><US><row text>"
ev = b.event("MakeRow", [{"name": "Rec", "type": "string"}])
parts = b.call("KismetStringLibrary:ParseIntoArray", Delimiter=US, CullEmptyStrings=False); b.link(ev + ".Rec", parts + ".SourceString")
g0 = b.call("KismetArrayLibrary:Array_Get", Index=0); b.link(parts + ".ReturnValue", g0 + ".TargetArray")
g1 = b.call("KismetArrayLibrary:Array_Get", Index=1); b.link(parts + ".ReturnValue", g1 + ".TargetArray")
cr = b.call("WidgetBlueprintLibrary:Create", WidgetType=ROW); b.link(b.me() + ".self", cr + ".WorldContextObject")
pcw = b.call("GameplayStatics:GetPlayerController", PlayerIndex=0); b.link(b.me() + ".self", pcw + ".WorldContextObject"); b.link(pcw + ".ReturnValue", cr + ".OwningPlayer")
cr_ = b.add("cast", **{"class": ROW, "pure": False}); b.link(cr + ".ReturnValue", cr_ + ".Object"); b.link(ev + ".then", cr + ".execute"); b.link(cr + ".then", cr_ + ".execute")
txt = b.add("get", var="Text_RecordName", **{"class": ROW}); b.link(cr_ + ".as", txt + ".self")
tt = b.call("KismetTextLibrary:Conv_StringToText"); b.link(g1 + ".Item", tt + ".InString")
sT = b.call("TextBlock:SetText"); b.link(txt + ".Text_RecordName", sT + ".self"); b.link(tt + ".ReturnValue", sT + ".InText"); b.link(cr_ + ".then", sT + ".execute")
btn = b.add("get", var="Button_TapeRecord", **{"class": ROW}); b.link(cr_ + ".as", btn + ".self")
ab = b.call("KismetArrayLibrary:Array_Add"); b.link(b.get("RowButtons") + ".RowButtons", ab + ".TargetArray"); b.link(btn + ".Button_TapeRecord", ab + ".NewItem"); b.link(sT + ".then", ab + ".execute")
an = b.call("KismetArrayLibrary:Array_Add"); b.link(b.get("RowNames") + ".RowNames", an + ".TargetArray"); b.link(g0 + ".Item", an + ".NewItem"); b.link(ab + ".then", an + ".execute")
bnode = b.bind(an, "then", btn + ".Button_TapeRecord", "/Script/UMG.Button", "OnPressed", "HRowPressed")
sbg = b.add("get", var="SB_Tapes", **{"class": TAPES})
pgg = b.add("cast", **{"class": TAPES, "pure": False})
uw2 = b.call("WidgetComponent:GetUserWidgetObject"); b.link(b.get("TapesWc") + ".TapesWc", uw2 + ".self"); b.link(uw2 + ".ReturnValue", pgg + ".Object"); b.link(bnode + ".then", pgg + ".execute")
b.link(pgg + ".as", sbg + ".self")
ac = b.call("PanelWidget:AddChild"); b.link(sbg + ".SB_Tapes", ac + ".self"); b.link(cr + ".ReturnValue", ac + ".Content"); b.link(pgg + ".then", ac + ".execute")

# ---- HRowPressed: a row's button was pressed (OnPressed has no parameter, and IsPressed is still true while it broadcasts): enter the map of the row that is pressed
ev = b.event("HRowPressed")
lpR = b.add("macro", macro="ForEachLoop"); b.link(b.get("RowButtons") + ".RowButtons", lpR + ".Array"); b.link(ev + ".then", lpR + ".Exec")
ip = b.call("Button:IsPressed"); b.link(lpR + ".ArrayElement", ip + ".self")
brIP = b.branch(); b.link(ip + ".ReturnValue", brIP + ".Condition"); b.link(lpR + ".LoopBody", brIP + ".execute")
gn = b.call("KismetArrayLibrary:Array_Get"); b.link(b.get("RowNames") + ".RowNames", gn + ".TargetArray"); b.link(lpR + ".ArrayIndex", gn + ".Index")
lgR = say(b, "row pressed: ", gn + ".Item"); b.link(brIP + ".True", lgR + ".execute")
pr = b.add("call", function="PressRow"); b.link(b.me() + ".self", pr + ".self"); b.link(gn + ".Item", pr + ".Name"); b.link(lgR + ".then", pr + ".execute")

# ---- test events (no laser needed): OpenList = a press on REGIONS; PressRow(Name) = a press on that map's row
ev = b.event("OpenList")
b.chain(ev, b.call_me("SwitchPage"))
ev = b.event("PressRow", [{"name": "Name", "type": "string"}])
press_row(b, ev + ".Name", ev + ".then")

variables = [
    {"name": "Computer", "type": "object:/Script/Engine.Actor"}, {"name": "Wc", "type": "object:/Script/UMG.WidgetComponent"}, {"name": "TapesWc", "type": "object:/Script/UMG.WidgetComponent"},
    {"name": "BoundBtn", "type": "object:/Script/UMG.Button"}, {"name": "Rows", "type": "string", "default": "", "tooltip": "<MapName> US <row text> RS ..., written by Lua at the one step"},
    {"name": "RowButtons", "type": "object:/Script/UMG.Button[]"}, {"name": "RowNames", "type": "string[]"},
]
write(os.path.join(OUT, "BP_ITRRegions.json"), b.spec(DIR + "/BP_ITRRegions", "/Script/Engine.Actor", variables,
      "ITRMapLoader's Regions page on the Hub computer. PageBuilt (from Lua's one Construct hook) shows and renames the stock spare row and binds its press; the press switches the computer to its "
      "Tapes page and fills it with one stock row per map; a row's press enters the map (HRowPressed finds the pressed row). OpenList and PressRow are test events. No Tick, no timer.",
      requires=["BP_ITRMapEntry.json"]))
