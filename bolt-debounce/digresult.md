# T-215 design: BoltDebounce (time debounce on bolt, slide and pump eject/feed)

Read-only research result. Nothing in the repo or the game was changed. Evidence paths are at the end (section 10);
`dis` = `build/work/T-214/scratch/bp/<BP>.dis.txt` (file line, then bytecode offset), `asm` = `build/work/T-214/scratch/asm/OnTick_141133570.asm`.

## 0. Summary

- One Blueprint manager actor per world (`BP_BoltDebounce_Manager`, spawned once by the Lua loader) binds once to the player's two
  `GripMotionControllerComponent.OnGrippedObject` / `OnDroppedObject`. When a player hand grips a weapon (the gun, its slide, its bolt), the manager
  adds one Blueprint component (`BPC_BoltDebounce`) to that weapon actor. The component does the debounce by writing values the stock code
  already reads every tick:
  - mag-fed (31 closed-bolt `BP_MagFirearmItem` children): the instance variable `BoltRealease_Ymin`;
  - Mosin / DVL: the native `UWeaponBoltComponent.StickToOpen` (public, Blueprint read/write);
  - IZ81: the pump variables `BoltMoved` and `BoltFullOut`.
- No class swap, no DataTable edit, no game asset in the pak, no save data. Player-only by construction (only player hands register a weapon).
- Signal: the "Opened" state (slide/bolt/pump at the rear). Rules:
  1. **Eject (entering Opened) is never delayed.** It fires exactly where stock fires it.
  2. **Hold:** once Opened, the weapon stays Opened until the slide has been forward of the stock line *continuously* for N ms,
     or has passed `ReleaseFraction` (default 0.5) of its travel. Each return into the stock band restarts the N ms.
  3. **Lockout:** after a feed (leaving Opened), re-entering Opened is blocked for N ms, or until the action has closed (a full stroke).
- Result: exactly one eject and one feed per real stroke; full strokes, fast clearing and short-strokes behave like stock (feed may come at
  mid-stroke instead of at the band edge). The jitter glitch (one live round per wobble) is gone.
- Limits: Mosin/DVL get rules 1 and 2 only. Rule 3 needs a lever on the native Opened entry, which has none (section 1.2). Rule 2 with the
  retrigger makes the residual a deliberate partial stroke. PPSh / PPSh_full (open-bolt) are excluded: no live-round loss there (T-214).
- Default N = 100 ms (9 frames at 90 Hz), tunable live; measurement mode logs every eject/feed with intervals.

## 1. Hook points (where a Blueprint can suppress a repeated transition)

### 1.1 Mag-fed: BP_MagFirearmItem ReceiveTick (33 children; 31 closed-bolt)
- Stock logic, only while `BoltHandled && !boltAnimated` (dis 429-431, off 11307-11374):
  - `Y = VRSlider.RelativeLocation.Y`; if `Y <= BoltRealease_Ymin` and `BoltState != 4` -> eject path 10250 (dis 433-438):
    `BoltState = 4`, `SetBoltState`, `Unjam` if `Jammed_bolt`, `ExtractRound(true, BulletFired_0, ShellEjector, 150, 450, tag)` (dis 378-389).
  - else if `Y >= BoltCloseY` -> close path 5228: `BoltState = 0`, no feed (dis 186-189, 6-9).
  - else if `BoltState == 4` -> `LoadCycle(false)` (dis 443-449; NonReciprocating guns only when `Bolt.Y` is within 1 of 0), then `BoltState = 3` (dis 450-456).
  - `LoadCycle` (dis 391-412, off 10560-11000): extract if chambered, then mag -> chamber (off 4864-5089) or chamber None if the mag is empty.
    `BP_SPAS` overrides `LoadCycle` (tube feed, `BP_SPAS.dis.txt` 48-52); the call is virtual, so calling it reaches the override.
- `BoltRealease_Ymin` is read in two places only: the tick (dis 433, off 11452) and the open-bolt release path (dis 228, off 6143, only when
  `OpenBoltOperation`). Excluding open-bolt guns makes it a tick-only lever.
- **Lever:** write the instance `BoltRealease_Ymin` (declared on BP_MagFirearmItem, float, Edit|BlueprintVisible):
  - hold = `OpenY + ReleaseFraction * (CloseY - OpenY)` (mid-stroke): the stock in-between branch (the feed) and the close branch are not
    reached until the slide passes mid-stroke; the eject branch is a no-op because `BoltState` is already 4;
  - lockout = `OpenY - 100` (unreachable; the slider stops at `BoltOpenY`): the eject branch cannot fire;
  - restore = the value read at first grip (per-class default, `magtable.txt`).
- No event exists for the eject or the feed (both inline in the tick; the only side effects are an item spawn and the native
  `UInventoryItem::SetBoltState`), so the component must look at `BoltState` once per tick while the slide is handled (cost in 2.4).
- Children: all 33 have the same function list from the parents; `BP_M14` adds a ReceiveTick override and `BP_SPAS` a LoadCycle override
  (`build/work/T-215/scratch/ownfns.py` on `bp2/*.json`). The worker checks that BP_M14's ReceiveTick calls the parent (gate G3).

### 1.2 Mosin / DVL: native UWeaponBoltComponent + BPA_Firearm_BoltAction handler
- Native `OnTick` (asm 297-349): slide position integrates hand delta, clamped to cached `front` (+0x5c4) / `rear` (+0x5c8);
  `|Y-front| <= 0.01` -> HalfWay (2) **unconditionally, also from Opened** (asm 319-329); `|Y-rear| <= 0.01` -> Opened (4) (asm 330-337);
  otherwise Sliding (3), but from Opened only when `|Y-rear| > StickToOpen` (+0x560, read live every tick: asm 338-345).
  Each change broadcasts `OnBoltStateChanged(prevState)` (asm 346-349).
- Stock handler `BndEvt__WeaponBolt_...` (BPA dis 293-297 -> ubergraph 5385, dis 189-241) reads `WeaponBolt.GetCurrentState()`:
  - 4: `Cue_BoltOut`, `ExtractRound(IsRoundChambered, Is Bullet Fired, ...)`, clear jam, `SetLoadingLock(false)` (dis 228-241);
  - 3 with prevState 4: `SetLoadingLock(true)`, `Can Load Round` -> `LoadRound`, `bJammed = Is Going to Jam` (dis 218-227);
  - 2: sounds only (dis 207-217). So a 4 -> 2 jump skips the feed.
- **Lever:** `StickToOpen` (SDK `IntoTheRadius_classes.hpp:11433`, `Edit, BlueprintVisible`; npc-lab stub `BlueprintReadWrite`).
  Hold = `ReleaseFraction * |SlideLimit|` (Mosin 5 cm, DVL 7 cm): the native tick itself keeps Opened until the bolt passes mid-stroke;
  restore = the stock value (1.0) after the retrigger time (component tick, only while holding).
- **Event, not polling:** `OnBoltStateChanged` is `BlueprintAssignable` (SDK :11427). Our binding is added after the stock one and multicast
  delegates run in list order (`C:/ue427/Engine/Source/Runtime/Core/Public/UObject/ScriptDelegates.h:479-501`, `Add` appends :559), so our
  handler runs right after the stock handler, inside the same native tick, before the next one. It cannot pre-empt the stock handler.
- **Cannot cover: the lockout (rule 3).** Re-entry to Opened is `|Y-rear| <= 0.01` against the cached rear; no public property moves the rear
  or blocks the entry (`SlideCoeff` would freeze the bolt for the hand, which changes handling). The only routes are overriding `ExtractRound`
  in a child class (section 1.5) or the aiMod ProcessEvent hook (not shareable because people shouldn't have to download an additional dll that does proxy dll etc etc). With rule 2's retrigger the residual needs a forward move past
  1 cm held for N ms, or past mid-stroke, then a pull back within N: a deliberate partial stroke.
- Corner: a 4 -> 2 jump during a hold (only on a frame hitch: mid-stroke to the front in one frame) skips the stock feed. The component then
  does it: `SetLoadingLock(true)` (IAmmoContainer message on the internal mag), `LoadRound()` if the chamber is empty, `bJammed = Is Going to Jam`.

### 1.3 IZ81: BP_Firearm_PumpAction ReceiveTick
- Stock (dis 269-295, off 6959-7545), only while `BoltUnlocked && SecondaryHand` (dis 234-236):
  - `progress <= 0 && !BoltFullOut` -> `BoltOUT`: eject, `BoltFullOut = true`, `BoltMoved = false`, 0.2 s timer `LoadRoundDelayed` (dis 354-356, 331-341, 110-116);
  - `!BoltFullInn && progress >= 1` -> `BoltInn`: `BoltFullOut = false`, `BoltFullInn = true`, `BoltMoved = false`, jam roll (dis 351-353, 342-350);
  - `!BoltMoved && 0.05 < progress <= 0.95` -> re-arm: `BoltMoved = true`, `BoltFullOut = false`, `LoadRound` now if the timer is still running (dis 281-295).
  - `LoadRound` (dis 154-165, off 4224) feeds only into an empty chamber. The feed is the timer or the re-arm; the eject is BoltOUT.
- Glitch: BoltOUT, wobble past 5 % (0.57 cm) re-arms, wobble back -> BoltOUT ejects the live round fed by the timer or the re-arm.
- **Levers:** `BoltMoved = true` blocks the re-arm (hold); `BoltFullOut = true` blocks BoltOUT (lockout). Both read only in the tick
  (`BoltMoved` read at dis 281 only). Both declared on BP_Firearm_PumpAction (bool, Edit|BlueprintVisible).
- Registration: the pump is a secondary grip on the held shotgun, so the component is added on the primary grip of the IZ81 and ticks while
  the weapon is held (cheap when `SecondaryHand` is not valid).

### 1.4 How it gets in without overriding game assets
- Pak `BoltDebounce_P.pak` holds only `/Game/Mods/BoltDebounce/BP_BoltDebounce_Manager` and `/Game/Mods/BoltDebounce/BPC_BoltDebounce`.
  They reference the game classes by path; the build project has never-packed stand-ins of `BPA_BaseItem`, `BP_FirearmItem`,
  `BP_MagFirearmItem`, `BPA_Firearm_BoltAction`, `BP_Firearm_PumpAction` with only the touched variables/functions, each declared on the class
  that declares it in the game (`declaredIn` in the T-214 bp JSON), the same pattern as bullet-penetration's stand-in parent.
- Lua (load time only): find/load the manager class, `World:SpawnActor` it once per world (npc-lab precedent `npc-lab/lua/NpcLab/Scripts/main.lua:119-137`)  ```I don't like npc-lab being a reference as it's not performant and testing only! - grev```,
  write the tunables into the manager and its class defaults, register the console command `bdb`. A 2 s loop only checks that the cached manager
  is still valid in the current world (no FindAllOf). In measurement mode only, a 500 ms loop copies new log lines.
- The manager gets the hands as `VRBaseCharacter.LeftMotionController / RightMotionController` of the player pawn (npc-lab precedent
  `npc-lab/Tools/gen_specs.py:504-506, 2089-2100`), binds `OnGrippedObject(GripInformation)` / `OnDroppedObject(GripInformation, bWasSocketed)`  ```I don't like npc-lab being a reference as it's not performant and testing only! - grev```
  (SDK `VRExpansionPlugin_classes.hpp:341-342`), and on start registers whatever the hands already hold (`GetGrippedActors`/`GetGrippedComponents`, :398-399).
  A 2 s Blueprint timer rebinds if the pawn changed.

### 1.5 Routes considered
| Route | Covers | Why not chosen |
|---|---|---|
| Component + instance-value writes (chosen) | mag-fed all rules; IZ81 all rules; Mosin/DVL rules 1-2 | - |
| Child class per weapon, swapped in `DT_ItemInfos` (`/Game/ITR/Configurations/Infos/DT_ItemInfos`, row `FPRItemInfo.ActorClass`) | everything, incl. Mosin lockout by overriding `ExtractRound` (BPA dis 282-291 shows it is overridable) | 36 children + stand-ins per weapon; placed level weapons keep the stock class; only the Mosin lockout needs it. Save-safe: saves hold `UInventoryItem.ItemId` (a tag) and the class comes from the DataTable row by `ItemTypeID` (SDK `IntoTheRadius_classes.hpp:4344-4363`, `IntoTheRadius_structs.hpp:1740-1746`; inferred from the layout, not from a save file). Kept as an optional phase 2 for Mosin/DVL only. |
| Dispatcher binding alone | observation | runs after the stock handler (ScriptDelegates.h:479-501), cannot suppress |
| Lua hooks per tick/event | all | slow path, and UE4SS native errors are not caught by pcall (gotchas, T-133/T-146) |
| aiMod DLL ProcessEvent | all | not shareable because people shouldn't have to download an additional dll that does proxy dll etc etc |

## 2. Debounce logic per system (Blueprint terms)

Common: `N = Mgr.DebounceMs / 1000` (0 = component does nothing but optional logging), `RF = Mgr.ReleaseFraction`, `now = GetRealTimeSeconds`.
Component `BPC_BoltDebounce` (ActorComponent, tick off by default, `SetTickGroup(TG_PostPhysics)` + `AddTickPrerequisiteActor(owner)` so it
runs after the weapon's ReceiveTick in the same frame). Per-weapon state lives in the component: `Kind`, `StockYmin`, `HoldY`, `LockY`,
`StockStick`, `HoldStick`, `RearY`, `PrevState`, `PrevOut`, `Holding`, `Locked`, `OutSince` (-1 = inside the stock band), `LockUntil`,
`SelfWroteOut`, `LastE`, `LastF`, `ClosedSinceE`, `PrevChamber`.

### 2.1 Mag-fed (tick, only while registered; does nothing unless `BoltHandled && !boltAnimated`)
```
on register: if OpenBoltOperation -> do not attach. StockYmin = BoltRealease_Ymin; OpenY = BoltOpenY; CloseY = BoltCloseY
             HoldY = OpenY + RF*(CloseY-OpenY); LockY = OpenY - 100; PrevState = BoltState
tick:
  if !(BoltHandled && !boltAnimated) or Jammed_bolt: EndHoldLock(); PrevState = BoltState; return     // firing animation, release, jam
  S = BoltState
  if S != PrevState:
    if S == 4:                         E (stock just ejected): if N>0 { BoltRealease_Ymin = HoldY; Holding = true; OutSince = -1 }
    elif PrevState == 4 and S == 3:    F (stock just fed):     Holding = false; if N>0 { BoltRealease_Ymin = LockY; Locked = true; LockUntil = now+N }
    elif PrevState == 4 and S == 0:    if Holding (hold skipped the feed: one-frame slam or hitch) and chamber empty: LoadCycle(false); log F(corner)
                                       EndHoldLock()
    if S == 0: EndHoldLock()           (a closed action ends the lockout: full strokes are never gated)
    PrevState = S
  if Holding:                          (retrigger)
    Y = VRSlider.RelativeLocation.Y
    if Y <= StockYmin: OutSince = -1
    elif OutSince < 0: OutSince = now
    elif now - OutSince >= N: BoltRealease_Ymin = StockYmin; Holding = false      (stock tick feeds next frame)
  if Locked and now >= LockUntil: BoltRealease_Ymin = StockYmin; Locked = false   (if still at the rear, stock ejects now: late, not lost)
EndHoldLock: BoltRealease_Ymin = StockYmin; Holding = Locked = false
on unregister (last hand released): EndHoldLock(); tick off
```
### 2.2 Mosin / DVL (event + tick only while holding)
```
on register: bind WeaponBolt.OnBoltStateChanged -> OnBolt (AddUnique, once per weapon). StockStick = WeaponBolt.StickToOpen
             HoldStick = RF * abs(WeaponBolt.SlideLimit)
OnBolt(prevState):   (runs right after the stock handler, same native tick)
  cur = WeaponBolt.GetCurrentState()
  if cur == 4:                         E: if N>0 { WeaponBolt.StickToOpen = HoldStick; RearY = WeaponBolt.RelativeLocation.Y; Holding = true; OutSince = -1; tick on }
  elif prevState == 4 and cur == 3:    F: Holding = false; WeaponBolt.StickToOpen = StockStick; tick off
  elif prevState == 4 and cur == 2 and Holding:   corner: WeaponBolt.StickToOpen = StockStick; Holding = false; tick off
                                       if chamber empty: IAmmoContainer.SetLoadingLock(internal mag, true); LoadRound(); bJammed = Is Going to Jam
tick (only while Holding):
  d = abs(WeaponBolt.RelativeLocation.Y - RearY)
  if d <= StockStick: OutSince = -1  elif OutSince < 0: OutSince = now
  elif now - OutSince >= N: WeaponBolt.StickToOpen = StockStick   (native leaves Opened next tick -> stock feed -> OnBolt F)
on unregister: WeaponBolt.StickToOpen = StockStick; Holding = false; tick off
```
### 2.3 IZ81 (tick while the shotgun is held; does nothing unless `BoltUnlocked && IsValid(SecondaryHand)`)
```
tick:
  Out = BoltFullOut; Inn = BoltFullInn; p = VRSlider.CurrentSliderProgress
  if Out and !PrevOut and !SelfWroteOut:   E (BoltOUT): if N>0 { BoltMoved = true; Holding = true; OutSince = -1 }
  if Holding:
    if Inn: Holding = false                                    (BoltInn ran; stock reset BoltMoved)
    elif p <= 0.05: OutSince = -1; BoltMoved = true
    elif p > RF or (OutSince >= 0 and now - OutSince >= N): BoltMoved = false; Holding = false   (stock re-arm runs this/next frame)
    elif OutSince < 0: OutSince = now
  if PrevOut and !Out and !Inn and !SelfWroteOut:   R (stock re-arm): if N>0 { BoltFullOut = true; SelfWroteOut = true; Locked = true; LockUntil = now+N }
  if Locked and (Inn or now >= LockUntil): if !Inn { BoltFullOut = false }; Locked = false; SelfWroteOut = false   (PrevOut updated after the write; no E/R detected for our writes)
  chamber None -> tag: F (log only)
  PrevOut = BoltFullOut
on unregister: if Holding { BoltMoved = false }; if SelfWroteOut and !BoltFullInn { BoltFullOut = false }; clear flags
```
### 2.4 Cost
- Per event (E, F, R, corner): 10-25 Blueprint nodes, a few microseconds; at most a few per second while racking. Logging (string build) only in measurement mode.
- Per tick, mag-fed and IZ81, per weapon in a player hand: steady state about 8 nodes (read `BoltState`/flags, compare, return); during a hold about
  18 nodes. Estimate 2-8 microseconds per frame per held weapon, under 0.1 % of an 11.1 ms frame; nothing runs for weapons not in a hand.
  Mosin/DVL: no tick except during a hold (at most a few hundred ms per stroke). These are estimates; measure with the VR frame-time tool in the test pass.
- Unavoidable: mag-fed (no event for eject/feed, 1.1). IZ81 the same (BoltOUT/re-arm are inline).

## 3. Which N is safe
| Quantity | Value | Source |
|---|---|---|
| VR tick | 90 Hz = 11.1 ms; transitions are sampled once per tick, so an out-and-back glitch takes at least 2 ticks (22 ms) | - |
| Stock bands | pistols 0.1 cm (G17, M9, PM, PX4, PL14, TT, OC33, Gsh18), Deagle 0.36, G18c 0.39, rifles 0.5-2.0 cm; Mosin/DVL 1.0 cm of bolt (DVL 0.83 cm of hand, SlideCoeff 1.2); IZ81 5 % of 11.38 cm = 0.57 cm | magtable.txt, T-214 findings 1 |
| Jitter time scale | hand rebound at a hard stop: estimated 2-5 ticks (22-55 ms); tremor 8-12 Hz, half period 40-60 ms; a 0.1 cm band is crossed by tremor or tracking noise alone | estimate; measured by the log at N = 0 |
| Real stroke | full travel 4-7 cm pistols, 8-16 cm rifles, 10/14 cm Mosin/DVL, 11.4 cm IZ81; at 1-2 m/s forward plus back takes at least 50-140 ms (pistol) to 100-300 ms (rifle) | estimate |
- E-to-F inside a real fast stroke can be 1-2 ticks, the same as jitter, so it cannot separate the two; that is why rule 1 never delays the eject
  and rule 2 waits for "forward of the band for N" (jitter keeps returning) or "past mid-stroke" (jitter never gets there).
- Lower bound: N above the longest bounce and above half a tremor period: about 60-70 ms.
- Upper bound with ReleaseFraction and the close reset: full strokes are never gated, so only partial strokes and the feed delay of a slow small
  forward move see N; up to about 150-200 ms stays unnoticeable.
- Pure time (ReleaseFraction = 1, no close reset): one stroke needs hold N + lockout N, so nothing is dropped while N <= (shortest real
  eject-to-eject) / 2. That is exactly the user's "halve the shortest real interval" rule, so the rule stays safe even with the refinements off.
- Default 100 ms (9 ticks) is inside both bounds.

## 4. Risks
- **Jams.** Mag-fed: the eject unjams (dis 382-384, off 10372-10386) and is never held; jams are rolled at firing (dis 339-345, off 9425-9556) with
  the slide closed, so no lockout is active; the component also ends hold/lock whenever `Jammed_bolt`. Mosin: the jam roll is at the feed
  (dis 225-226) and is cleared at Opened (dis 235-237); the hold only delays the roll; the corner path rolls it too (needs the stand-in
  "Is Going to Jam" with its output; if BPGen cannot stub outputs, the rare corner feed skips the roll: open question 2). IZ81: roll at BoltInn,
  cleared at BoltOUT: unchanged.
- **Misfires / dry shots:** not touched (firing path).
- **Empty magazine:** the feed with an empty mag sets the chamber to None (dis 410-411); counts identical; slide-lock-on-empty is the animation
  path (`BoltHandled` false), not touched.
- **Saves with the bolt open:** the bolt state is in `UInventoryItem` (`SetBoltState` dis 381, 456; read back on reconfigure dis 549-551).
  Our writes are actor instance values (`BoltRealease_Ymin`, `StickToOpen`, `BoltMoved`, `BoltFullOut`) and an added component, none of them in
  `UInventoryItem`, so nothing is saved (inferred from the SDK layout). Saved during a hold: state 4 with an empty chamber is saved; on load the
  slide is placed open (dis 137-140) and the next forward stroke feeds. No round lost. Removing the mod leaves nothing behind.
- **Dropped with the bolt open:** the last hand release ends hold/lock and restores the values. Mag-fed release path (dis 225-243, off 6005-6583)
  is untouched (it feeds if state 4 and the chamber is empty). Mosin: the native tick stops when the bolt is not held; state stays Opened.
  Unknown: whether a released Mosin bolt moves by itself (`SnapPercent`, `AutoCloseRotateOnRelease`) - VR item.
- **NPC weapons:** `BP_FirearmItem` carries bot variables (`MaxBotAmmo`, `BotFireTimer`, `Bot Owner`, `OnBotFired`: `build/work/T-215/scratch/listvars.py`
  on the T-214 JSON), so NPCs may use these classes. The component is only added when a player hand grips the weapon and only acts while the
  slide/bolt/pump is hand-operated (`BoltHandled`, bolt grip, `SecondaryHand`), so NPC behaviour is unchanged.
- **Firing while the slide is held / animations:** transitions while `boltAnimated` or not `BoltHandled` are ignored and resync `PrevState`, so the
  per-shot 0 -> 4 -> 0 animation (dis 17-28) is never taken for a hand stroke.
- **Other mods** that edit BP_MagFirearmItem / BPA_Firearm_BoltAction / BP_Firearm_PumpAction and rename the touched variables would break the
  component's property links at load (no effect on the game assets themselves). Compatibility note for the README.
- **Frame hitch** during a hold can skip a stock state (mag-fed rear -> closed, Mosin rear -> front); the corner paths feed once. Outside a hold the
  stock behaviour (which also skips the feed on such a jump) is left as is.

## 5. Chamber and magazine counts (start: live round chambered, magazine M)
| Case | Stock | BoltDebounce |
|---|---|---|
| Full stroke, slow or fast | 1 live out, chamber 1, M-1 | same; the feed comes at mid-stroke or N ms after leaving the band |
| Fast clearing, M strokes, each fully forward | M+1 out, chamber 0, mag 0 | same at any speed (the close ends the lockout) |
| Wobble at the rear, k crossings | up to k extra live rounds out | 1 out, then as a full stroke |
| Short-stroke that never reaches the band | nothing | nothing |
| Pull back, push 1 cm (Mosin 1.5 cm, IZ81 1 cm), pull back, all within N | 2 out, chamber 1, M-2 | 1 out, chamber 1, M-1 (no feed until the final forward stroke) |
| Same, but the 1 cm push held longer than N | 2 out, M-2 | feed after N; pull back within N of the feed is held: if the slide is still back when the lockout ends, eject (late, = stock); if it went forward, no second eject (round stays chambered, M-1) |
| Rebound, then hold at the rear (seconds) | mag-fed: 1 extra out; IZ81: timer feeds, then every wobble ejects | 1 out, nothing while held, feed on the forward stroke |
| Release the slide at the rear | release path feeds, slide closes | identical (hold/lock end on release) |
| Rear to closed in one frame during a hold | n/a | corner feed once: chamber 1, M-1 |
| Mosin/DVL: feed, then back to the rear within N (deliberate partial stroke) | eject | eject (no lockout for Mosin/DVL) |

## 6. Delivery (bullet-penetration pattern)
- `BoltDebounce_P.pak` -> `Content/Paks/~mods/`; Lua folder `BoltDebounce/` (`enabled.txt`, `Scripts/main.lua`, `Scripts/config.lua`) -> `Content/Paks/LuaMods/`.
- `config.lua`: `DebounceMs = 100` (0 = stock), `ReleaseFraction = 0.5` (1.0 = time only), `Log = false` (measurement mode), `LogFile = true`,
  `Systems = { MagFed = true, BoltAction = true, Pump = true }`.
- Console (UE4SS console, live): `bdb ms <n>`, `bdb off` (= ms 0), `bdb release <f>`, `bdb log on|off`, `bdb stats`, `bdb clear`.
  Lua writes the manager instance and its class defaults and rewrites `LuaMods/BoltDebounce/state.txt` (`ms=`, `release=`, `log=`, `active=`).
- `UE4SS.log` gets one line: `[BoltDebounce] active` or `[BoltDebounce] failed: <reason>`.
- Measurement mode: the component appends `t;weapon;class;event;dt_same_ms;dt_prev_ms;full;chamber;note` lines to a 32-line ring string on the
  manager (`LogSeq`, `LogBuf`; the packaged game has no game log and strips PrintString, gotchas T-133). Events: `E`, `F`, `R` (IZ81 re-arm),
  `F*` (corner feed), `xE` / `xF` (a stock transition the debounce held back). `full` = the action closed since the previous eject.
  Lua (500 ms loop, measurement mode only) prints new lines to UE4SS.log and appends them to `LuaMods/BoltDebounce/measure.csv`.
  `bdb stats`: per class, shortest full-stroke eject-to-eject, shortest held-back interval, count of held-back transitions, suggested N = half the shortest full-stroke interval.
- Optional aiMod panel (not shareable because people shouldn't have to download an additional dll that does proxy dll etc etc, the mod does not need it): like the bullet-penetration tab (`aiMod/Menu.cpp:269-345`): buttons send
  `bdb ...` console commands, the panel reads `state.txt` and the tail of `measure.csv` once a second, shows N, the last 8 intervals, the shortest
  full-stroke interval and the suggestion.

## 7. Measurement and tuning (in-game wording)
1. Start the game. In UE4SS.log check the line "[BoltDebounce] active".
2. Open the UE4SS console (or the aiMod tab) and type `bdb off`, then `bdb log on`. The filter is now off and every eject and feed is logged.
3. Take a Glock, an AK (or SKS), the Mosin and the IZ81, each fully loaded. With each one: work the slide / bolt / pump as fast as you can,
   full strokes, until it is empty. Do not shake on purpose.
4. Type `bdb stats`. For each weapon it prints the shortest eject-to-eject time of a full stroke and the suggested value (half of it).
5. Take the smallest suggestion of the four weapons, type `bdb ms <that value>`, and write the same number into `config.lua` as `DebounceMs`.
6. Type `bdb log off` (or leave it on for the check in step 7).
7. Check: load each weapon again and clear it as fast as you can. Every stroke throws exactly one round; `bdb stats` shows no held-back
   transitions for full strokes. Then pull back, wiggle at the rear and hold: one round only.

## 8. VR test list (one check per item)
1. Glock: rack slowly once: one round comes out, the next is chambered (fire it).
2. Glock: clear a full magazine as fast as you can: rounds on the floor = magazine + 1, gun empty.
3. Glock: pull the slide fully back and wiggle it at the rear for two seconds: one round comes out.
4. Glock: pull back, push about 1 cm, pull back quickly, then let go: one round on the floor, the gun fires.
5. Glock: pull back and let go of the slide at the rear: it snaps forward and the gun fires.
6. AK: same as 2 and 3.
7. M4 (charging handle): same as 2 and 3.
8. SPAS-12: same as 2 and 3.
9. Mosin: work the bolt slowly once: one round out, next round fires.
10. Mosin: work the bolt as fast as you can until empty: rounds on the floor = rounds loaded.
11. Mosin: pull the bolt back and wiggle it at the rear: one round comes out.
12. Mosin: pull back and push the bolt forward hard in one go, close it, fire: it fires.
13. Mosin: open the bolt, let go of it at the rear, grab it again, close it: the next round fires.
14. IZ81: pump slowly once: one shell out, the next fires.
15. IZ81: pump as fast as you can until empty: shells on the floor = shells loaded.
16. IZ81: pull the pump back and hold it there two seconds with a shaky hand: one shell comes out.
17. Any rifle: fire until it jams, clear it by racking: it fires again.
18. Glock with an empty magazine: rack: nothing is chambered, the gun clicks.
19. Open the Mosin bolt, save, quit, load: close the bolt, it fires; round count matches.
20. Drop the AK with the charging handle held back, pick it up, rack: it chambers and fires.
21. Enemies shoot and reload as before.
22. Grabbing a gun causes no hitch or stutter.
23. Remove the mod, load the save from item 19: it loads, the Mosin is there.

## 9. Open questions
1. BPGen: binding a dispatcher of another object (`K2Node_AddDelegate` on the hands and on `WeaponBolt`) is untested (SPEC.md:59 says
   create_delegate is untested). Gate G1 in the brief; fallback is a small `bind` op in the npc-lab BPGen copy. Main to confirm that change is allowed. ```I don't like npc-lab being a reference as it's not performant and testing only! - grev```
2. BPGen function stand-ins have inputs only (`ItrShowcaseBPGen.cpp:983-1047`); `Is Going to Jam` needs its output, `BoltState` needs an enum
   variable type. Extend BPGen, or accept that the rare Mosin corner feed skips the jam roll.
3. ReleaseFraction (end the hold at mid-stroke) is a refinement over a pure time debounce; it keeps fast strokes stock-like. Keep it (default 0.5)?
4. Mosin/DVL lockout: accept rule 2 only, or add phase 2 (child classes of BP_Mosin / BP_DVL overriding `ExtractRound`, swapped in `DT_ItemInfos` by Lua)?
5. Console verb and mod name (`bdb`, `BoltDebounce`) are proposals.
6. Does VRExpansion broadcast `OnDroppedObject` on force-drops (single-hand fire drop)? The component also restores whenever the stock "handled"
   flag goes false, so a missed drop only delays the restore.
7. The aiMod panel: wanted now or later?

## 10. Evidence index
- T-214 findings: `build/work/T-214/findings.txt`; disassembly `build/work/T-214/scratch/bp/{BP_MagFirearmItem,BPA_Firearm_BoltAction,BP_Firearm_PumpAction,BP_FirearmItem,BP_SPAS,BP_Mosin}.dis.txt`;
  native tick `build/work/T-214/scratch/asm/OnTick_141133570.asm` lines 297-349; bands `build/work/T-214/scratch/magtable.txt`.
- Variable owners and types: `build/work/T-215/scratch/varown.py` and `fnsig.py` on `build/work/T-214/scratch/bp/*.json` (`declaredIn`, `specType`).
- Child overrides: `build/work/T-215/scratch/ownfns.py` on `build/work/T-214/scratch/bp2/*.json` (BP_M14 ReceiveTick, BP_SPAS LoadCycle).
- Base ExtractRound does nothing for an empty chamber: `BP_FirearmItem.dis.txt:828` (off 23185).
- SDK: `SDK/SDK/IntoTheRadius_classes.hpp:11424-11445` (UWeaponBoltComponent), `:4344-4410` (UInventoryItem), `IntoTheRadius_structs.hpp:1717-1722, 1740-1746`
  (FAmmoContainerData, FPRItemInfo), `VRExpansionPlugin_classes.hpp:302, 341-342, 398-399`.
- npc-lab stand-ins: `npc-lab/Source/IntoTheRadius/Public/WeaponBoltComponent.h`, `IAmmoContainer.h`; BPGen `npc-lab/Plugins/ItrShowcaseEditor/SPEC.md`  ```I don't like npc-lab being a reference as it's not performant and testing only! - grev```,
  `.../Private/ItrShowcaseBPGen.cpp:480-611, 983-1047`.
- Delegate order: `C:/ue427/Engine/Source/Runtime/Core/Public/UObject/ScriptDelegates.h:479-501, 559`.
- Bullet-penetration pattern: `public/itr-common/bullet-penetration/README.md`, `BulletPenetration/Scripts/main.lua`, `build-from-source/`; `docs/agents/where.md:76`.
