-- ITRLevelAddons settings. The add-ons themselves are the *.json files in ../Addons (one per add-on, see README.md);
-- nothing here needs changing for them.
return {
    LogTag = "ITRLevelAddons",   -- the [tag] of the log lines in UE4SS.log
    ModName = "ITRLevelAddons",  -- this mod's folder name (used to find ../Addons); change it only if you rename the folder
    PollMs = 1000,               -- how often the visibility of the target levels is checked
    Debounce = 2,                -- checks in a row before an add-on is streamed in or out
    -- AddonsDir = "C:/path/to/Addons",   -- optional: read the manifests from another folder
}
