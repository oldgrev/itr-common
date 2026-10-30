<#
.SYNOPSIS
  Packs a level gameplay tag into a tiny pak, zzz_ITRMap_<Map>_Tags_P.pak, so the game keeps it when it reads a save.
.DESCRIPTION
  A save stores every gameplay tag as its name, and turns the name back into a tag when it loads. A tag the game has not
  registered comes back as None. For a map with NativeSaves = true that means a save made inside the map has lost its level
  when it loads: Continue opens the Hub and whatever you left in the map is gone.

  The game reads every tag ini under IntoTheRadius/Config/Tags/ at startup. So this writes a one-line tag ini and packs it
  with the mount point ../../../IntoTheRadius/Config/Tags/. Put the pak next to the map pak (Content\Paks or
  Content\Paks\~mods). The tag must be the loader's NativeTag for the map (default Level.Zone.<Name>).

  The ini's file name is <Map>LevelTags.ini on purpose. A pak file at the same path as a game file replaces it, so never
  call it LevelGameplayTags.ini: that is the game's list of level tags, and replacing it would unregister every level.
.EXAMPLE
  .\build-tags.ps1 -Engine "C:\ue427\Engine" -Map MyMap                         # tag Level.Zone.MyMap -> build\zzz_ITRMap_MyMap_Tags_P.pak
  .\build-tags.ps1 -Engine "C:\ue427\Engine" -Map MyMap -Tag Level.Zone.Mine -Install
#>
param(
    [Parameter(Mandatory)][string]$Engine,           # ...\Engine of any 4.27 editor (only UnrealPak.exe is used)
    [Parameter(Mandatory)][string]$Map,              # the loader's Name for the map
    [string]$Tag = "",                               # default Level.Zone.<Map>, the loader's default NativeTag
    [string]$OutDir = "",                            # default: .\build next to this script
    [string]$GameDir = "C:\Program Files (x86)\Steam\steamapps\common\IntoTheRadius",
    [switch]$Install
)
$ErrorActionPreference = "Stop"
if (-not $Tag) { $Tag = "Level.Zone.$Map" }
if ($Tag -notmatch '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$') { throw "Not a gameplay tag name: '$Tag'" }
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot "build" }
$IniName = "${Map}LevelTags.ini"
$PakName = "zzz_ITRMap_${Map}_Tags_P.pak"
$TagDir  = Join-Path $OutDir "tags"
$Ini     = Join-Path $TagDir $IniName
$Pak     = Join-Path $OutDir $PakName
$resp    = Join-Path $OutDir "pak_tags_$Map.txt"
New-Item -ItemType Directory -Force $OutDir, $TagDir | Out-Null

# the tag ini: ASCII, LF, no BOM
$text = "[/Script/GameplayTags.GameplayTagsList]`nGameplayTagList=(Tag=`"$Tag`",DevComment=`"$Map level; registered so a save made in the map keeps its level`")`n"
[IO.File]::WriteAllBytes($Ini, [Text.Encoding]::ASCII.GetBytes($text))

# "<file on disk>" "<path inside the game>"
"`"$Ini`" `"../../../IntoTheRadius/Config/Tags/$IniName`"" | Set-Content -Encoding ASCII $resp
& (Join-Path $Engine "Binaries\Win64\UnrealPak.exe") $Pak "-create=$resp" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "UnrealPak failed ($LASTEXITCODE)" }
Write-Host "Tag $Tag -> $Pak"

if ($Install) {
    if (Get-Process "IntoTheRadius-Win64-Shipping" -ErrorAction SilentlyContinue) { throw "Close the game first (paks are mounted at startup)." }
    Copy-Item $Pak (Join-Path $GameDir "IntoTheRadius\Content\Paks") -Force
    Write-Host "Installed -> $GameDir\IntoTheRadius\Content\Paks\$PakName"
}
