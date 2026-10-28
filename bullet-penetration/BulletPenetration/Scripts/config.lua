-- BulletPenetration settings. Read once at game start; "bpen scale <x>" changes the scale for the running game only.
return {
    -- Global penetration scale on the energy budget. 0 = off, 1 = tuned, 10 / 50 = see the README.
    Scale = 1,

    -- Whose bullets penetrate. false = everyone (player and enemies), true = only the player's.
    PlayerOnly = false,

    -- Energy budget in resistance * cm: budget = AmmoInfo.Penetration * BudgetK * (v / v0)^2 * Scale.
    -- 30 = a 7.62x39 FMJ at full speed passes 15 cm of wood (resistance 2).
    BudgetK = 30,
    -- Longest thickness probe in cm, however high the scale is.
    ProbeCapCm = 500,
    -- Bullets slower than this (cm/s) are not looked at. A bullet whose speed reads 0 at the contact is given AssumedSpeed.
    MinSpeed = 2500,
    AssumedSpeed = 40000,
    -- A bullet that would leave slower than this (cm/s) is blocked.
    MinExitSpeed = 2000,
    -- Hits more glancing than this cosine of the angle to the normal are left to the game (ricochet).
    MinCos = 0.2,
    -- Most walls one shot may pass.
    MaxPenetrations = 4,
    -- The continuation bullet starts this far (cm) beyond the exit point; its cone is in degrees.
    ExitOffsetCm = 2,
    ConeDegrees = 0.5,
    -- Damage of the continuation = Damage * lerp(DamageFloor, 1, exit speed / spawn speed).
    DamageFloor = 0.25,
    -- An exit closer than MinThicknessCm to the entry is a one-sided sheet and counts as SheetThicknessCm (0 = it blocks).
    MinThicknessCm = 0.5,
    SheetThicknessCm = 1.0,
    -- Resistance per cm of a surface with no physical material in the table (unmarked / default): finite, = concrete.
    UnmarkedResistance = 15,
    -- Re-read the physical material of the entry point with a short component-only trace.
    EntryTrace = true,
    -- SpawnBulletProjectile multiplies the speed by AmmoInfo.VelocityMultiplier: divide the exit speed by it.
    DivideByVelocityMultiplier = true,
    -- Dispose the original bullet right after a pass.
    Retire = true,
}
