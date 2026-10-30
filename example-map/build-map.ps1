<#
.SYNOPSIS
  Cooks a map from this project, packs only the /Game/Mods/<Map> packages into zzz_ITRMap_<Map>_P.pak and
  (optionally) installs it into the game.
.EXAMPLE
  .\build-map.ps1 -Engine "C:\ue427\Engine"                       # cook + pak /Game/Mods/Example/L_Example
  .\build-map.ps1 -Engine "C:\ue427\Engine" -Map MyMap -Install   # /Game/Mods/MyMap/L_MyMap, then copy into the game
#>
param(
    [Parameter(Mandatory)][string]$Engine,           # ...\Engine of the editor that built the map
    [string]$Map = "Example",
    [string]$Tag = "",                               # the loader's NativeTag for the map; default Level.Zone.<Map>
    [string]$GameDir = "C:\Program Files (x86)\Steam\steamapps\common\IntoTheRadius",
    [switch]$Install
)
$ErrorActionPreference = "Stop"
$Project = Join-Path $PSScriptRoot "IntoTheRadius.uproject"
$OutDir  = Join-Path $PSScriptRoot "build"
$Cooked  = Join-Path $PSScriptRoot "Saved\Cooked\WindowsNoEditor\IntoTheRadius\Content\Mods\$Map"
$PakName = "zzz_ITRMap_$($Map)_P.pak"
$Pak     = Join-Path $OutDir $PakName
New-Item -ItemType Directory -Force $OutDir | Out-Null

# 1. Cook. -unversioned: the game's packages are unversioned. Old cooked files are removed first so assets the
#    map no longer uses aren't packed.
Remove-Item $Cooked -Recurse -Force -ErrorAction SilentlyContinue
$log = Join-Path $OutDir "cook_$Map.log"
Write-Host "Cooking /Game/Mods/$Map/L_$Map (log: $log)"
& (Join-Path $Engine "Binaries\Win64\UE4Editor-Cmd.exe") $Project -run=cook -targetplatform=WindowsNoEditor `
    "-map=/Game/Mods/$Map/L_$Map" -unversioned -unattended -NoLogTimes -abslog="$log" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Cook failed ($LASTEXITCODE); see $log" }

# 2. Response file: one line per file, "<file on disk>" "<path inside the game>". Only /Game/Mods/<Map>: anything
#    else in the cook output (engine content, game assets copied from the ITR-SDK) would override the game's files.
#    The stand-in host level (L_*Host) is editor-only and is left out.
$resp = Join-Path $OutDir "pak_$Map.txt"
$files = Get-ChildItem $Cooked -Recurse -File | Where-Object { $_.Name -notlike "L_*Host.*" }
$files | ForEach-Object {
    $rel = $_.FullName.Substring($Cooked.Length + 1) -replace '\\', '/'
    "`"$($_.FullName)`" `"../../../IntoTheRadius/Content/Mods/$Map/$rel`""
} | Set-Content -Encoding ASCII $resp
# e.g.  "C:\...\Saved\Cooked\...\Mods\Example\L_Example.umap" "../../../IntoTheRadius/Content/Mods/Example/L_Example.umap"

# 3. Pak (unsigned, uncompressed: the game loads unsigned paks)
& (Join-Path $Engine "Binaries\Win64\UnrealPak.exe") $Pak "-create=$resp" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "UnrealPak failed ($LASTEXITCODE)" }
Write-Host "Packed $($files.Count) files -> $Pak"

# 4. The level tag pak: registers the level's gameplay tag so a save made in the map keeps its level (matters when the
#    loader has NativeSaves = true; harmless otherwise). Pass -Tag if the map's NativeTag is not Level.Zone.<Map>.
& (Join-Path $PSScriptRoot "build-tags.ps1") -Engine $Engine -Map $Map -Tag $Tag

if ($Install) {
    if (Get-Process "IntoTheRadius-Win64-Shipping" -ErrorAction SilentlyContinue) { throw "Close the game first (paks are mounted at startup)." }
    Copy-Item $Pak (Join-Path $GameDir "IntoTheRadius\Content\Paks") -Force
    Write-Host "Installed -> $GameDir\IntoTheRadius\Content\Paks\$PakName"
    Copy-Item (Join-Path $OutDir "zzz_ITRMap_$($Map)_Tags_P.pak") (Join-Path $GameDir "IntoTheRadius\Content\Paks") -Force
    Write-Host "Installed -> $GameDir\IntoTheRadius\Content\Paks\zzz_ITRMap_$($Map)_Tags_P.pak"
}
