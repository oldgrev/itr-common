-- ITRMapLoader settings. Edit this file; main.lua reads it.
return {
    -- Your maps: the level package path (as cooked, under /Game/Mods/) and the start marker's actor tag.
    Maps = {
        {
            Name = "Example",
            Level = "/Game/Mods/Example/L_Example",
            StartTag = "itr:player_start",
            -- true only for maps with baked lighting: hides the Hub's lighting-scenario level while loaded
            HideLightingScenario = false,
        },
    },

    -- Keyboard key that loads the next map (or unloads the current one and returns you to the Hub).
    -- See UE4SS's Key table for names.
    Key = "F7",

    -- Standing within 1.5 m of a TargetPoint with this tag (in the loaded map) unloads it and returns you to where you
    -- were in the Hub. The way out in VR.
    ExitTag = "itr:exit",

    -- Load this map automatically each time the Hub becomes visible (a map Name from above), or nil.
    -- Useful in VR, away from the keyboard.
    AutoLoadInHub = nil,
}
