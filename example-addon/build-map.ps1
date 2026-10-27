<#
.SYNOPSIS
  Cooks a level add-on from this project, packs only the /Game/Mods/<Map> packages into zzz_ITRAddon_<Map>_P.pak and
  (optionally) installs it into the game. Same steps as example-map/build-map.ps1; only the pak name differs.
.EXAMPLE
  .\build-map.ps1 -Engine "C:\ue427\Engine"                          # cook + pak /Game/Mods/HubCozyCorner/L_HubCozyCorner
  .\build-map.ps1 -Engine "C:\ue427\Engine" -Map MyAddon -Install    # /Game/Mods/MyAddon/L_MyAddon, then copy into the game
#>
param(
    [Parameter(Mandatory)][string]$Engine,           # ...\Engine of the editor that built the add-on
    [string]$Map = "HubCozyCorner",
    [string]$GameDir = "C:\Program Files (x86)\Steam\steamapps\common\IntoTheRadius",
    [switch]$Install
)
$ErrorActionPreference = "Stop"
$Project = Join-Path $PSScriptRoot "IntoTheRadius.uproject"
$OutDir  = Join-Path $PSScriptRoot "build"
$Cooked  = Join-Path $PSScriptRoot "Saved\Cooked\WindowsNoEditor\IntoTheRadius\Content\Mods\$Map"
$PakName = "zzz_ITRAddon_$($Map)_P.pak"
$Pak     = Join-Path $OutDir $PakName
New-Item -ItemType Directory -Force $OutDir | Out-Null

# 1. Cook. -unversioned: the game's packages are unversioned. Old cooked files are removed first so assets the
#    add-on no longer uses aren't packed. The stand-ins of game meshes the level uses get cooked too (into Saved\Cooked\...\ART2
#    and so on); step 2 leaves them out, so the game loads the real meshes.
Remove-Item $Cooked -Recurse -Force -ErrorAction SilentlyContinue
$log = Join-Path $OutDir "cook_$Map.log"
Write-Host "Cooking /Game/Mods/$Map/L_$Map (log: $log)"
& (Join-Path $Engine "Binaries\Win64\UE4Editor-Cmd.exe") $Project -run=cook -targetplatform=WindowsNoEditor `
    "-map=/Game/Mods/$Map/L_$Map" -unversioned -unattended -NoLogTimes -abslog="$log" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Cook failed ($LASTEXITCODE); see $log" }

# 2. Response file: one line per file, "<file on disk>" "<path inside the game>". Only /Game/Mods/<Map>. The editor-only
#    levels (L_*Host, the Hub reference) are left out; the reference lives outside /Game/Mods anyway.
$resp = Join-Path $OutDir "pak_$Map.txt"
$files = Get-ChildItem $Cooked -Recurse -File | Where-Object { $_.Name -notlike "L_*Host.*" -and $_.Name -notlike "L_*Reference.*" }
$files | ForEach-Object {
    $rel = $_.FullName.Substring($Cooked.Length + 1) -replace '\\', '/'
    "`"$($_.FullName)`" `"../../../IntoTheRadius/Content/Mods/$Map/$rel`""
} | Set-Content -Encoding ASCII $resp

# 3. Pak (unsigned, uncompressed: the game loads unsigned paks)
& (Join-Path $Engine "Binaries\Win64\UnrealPak.exe") $Pak "-create=$resp" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "UnrealPak failed ($LASTEXITCODE)" }
Write-Host "Packed $($files.Count) files -> $Pak"

if ($Install) {
    if (Get-Process "IntoTheRadius-Win64-Shipping" -ErrorAction SilentlyContinue) { throw "Close the game first (paks are mounted at startup)." }
    Copy-Item $Pak (Join-Path $GameDir "IntoTheRadius\Content\Paks") -Force
    Write-Host "Installed -> $GameDir\IntoTheRadius\Content\Paks\$PakName"
}
