<#
.SYNOPSIS
  Packs the cooked Content/Mods/BulletPenetration of the UE project (this folder is copied into it) into build\BulletPenetration_P.pak (only that folder: the stand-in parent
  /Game/ITR/BPs/Misc/Projectiles/BP_RadiusBulletProjectile and every other game path the cook wrote are NOT packed). -Install copies it into the game's
  Content\Paks\~mods (refused while the game runs).
#>
param(
    [string]$Name = 'BulletPenetration_P.pak',
    [string]$Engine = 'C:\ue427\Engine',
    [string]$GameDir = 'C:\Program Files (x86)\Steam\steamapps\common\IntoTheRadius',
    [switch]$Install
)
$ErrorActionPreference = 'Stop'
$Out = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Force $Out | Out-Null
$CookedContent = Join-Path $PSScriptRoot 'Saved\Cooked\WindowsNoEditor\IntoTheRadius\Content'
$dir = Join-Path $CookedContent 'Mods\BulletPenetration'
if (-not (Test-Path $dir)) { throw "no cooked content at $dir" }
$lines = @()
foreach ($f in Get-ChildItem $dir -Recurse -File) {
    if ($f.Extension -notin '.uasset', '.umap', '.uexp', '.ubulk', '.uptnl') { continue }
    $rel = $f.FullName.Substring($CookedContent.Length + 1) -replace '\\', '/'
    $lines += "`"$($f.FullName)`" `"../../../IntoTheRadius/Content/$rel`""
}
if (-not $lines.Count) { throw 'nothing to pack' }
$resp = Join-Path $Out ($Name -replace '\.pak$', '.txt')
$lines | Set-Content -Encoding ASCII $resp
$Pak = Join-Path $Out $Name
& (Join-Path $Engine 'Binaries\Win64\UnrealPak.exe') $Pak "-create=$resp" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "UnrealPak failed ($LASTEXITCODE)" }
Write-Host "Packed $($lines.Count) files -> $Pak"
if ($Install) {
    if (Get-Process 'IntoTheRadius-Win64-Shipping' -ErrorAction SilentlyContinue) { throw 'The game is running; close it first (paks mount at startup).' }
    $dst = Join-Path $GameDir 'IntoTheRadius\Content\Paks\~mods'
    Copy-Item $Pak $dst -Force
    Write-Host "Installed -> $dst\$Name"
}
