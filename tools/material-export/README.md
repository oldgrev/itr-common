# material-export

This tool copies material settings from **Into the Radius 1 (2.7.2)** into a form you can use in your own editor
project. It reads the game's cooked files (the packaged versions of its assets) and exports JSON containing the
parent, parameters, static switches, base property overrides and texture settings such as compression and sRGB.
An Unreal editor script then uses that JSON to rebuild the material instance in your project.

Use it when you want a game material in your map but the ITR-SDK's copy is missing, stale or has its parameters
stripped, or you want to see exactly what a material instance sets.

There's one important catch: cooking strips the expression graph from a master material. That graph is the logic
that gives the material its appearance, and this tool can't bring it back. It can recover the master's settings and
parameters (names, defaults and textures), along with everything a material instance sets.

What you can do with that depends on whether you already have the master:
- **You have the master**, from the ITR-SDK or your own work: the rebuilt instance uses the game's values with that master.
- **You don't have the master:** the script creates a **stand-in master** with the same parameter names and defaults.
  This gives the instances somewhere to store their values, but it won't look like the original material.

## Files

| File | What it is | Needs |
|---|---|---|
| [`material_export.py`](material_export.py) | `export` / `list` / `show` for cooked packages | Python 3.8+, nothing else |
| [`ue4pkg.py`](ue4pkg.py) | The cooked package reader (header and tagged properties) the export uses | |
| [`material_import_ue.py`](material_import_ue.py) | Editor script: JSON to material instances (and stand-in masters) | UE 4.27 editor with Python on |
| [`verify_in_editor.py`](verify_in_editor.py) | Editor script: checks the recreated assets against the exports (parent, every parameter value, switches, overrides, placeholder texture settings). Run it in a fresh session so it reads the saved files | UE 4.27 editor with Python on |
| [`compare_editor_copy.py`](compare_editor_copy.py) | Checks an export against an editor copy of the same asset, e.g. the SDK's | [UAssetGUI](https://github.com/atenfyr/UAssetGUI) |

## Use

### 1. Export the settings

First, unpack the game's paks (`repak unpack` or UnrealPak; this repo doesn't include any game data), so you have
a folder like `<unpacked>\IntoTheRadius\Content\...` holding `.uasset` + `.uexp` files.

```bat
set C=E:\itr27\pak\IntoTheRadius\Content

:: find instances: --static = ones with static switches or overrides
python material_export.py list %C%\ART2\WorldMaterials --static

:: export one, with its parents and the settings of its textures
python material_export.py export %C%\ART2\WorldMaterials\MaterialInstans\Mi_LandscapeV6_Swamp.uasset ^
    --out exports --content-root %C% --chain --textures

:: a whole folder (anything that isn't a material is skipped)
python material_export.py export %C%\ART\Envir\Nature\Pine01 --out exports --content-root %C% --chain --textures
```
`--content-root` is the folder that is `/Game/`; it's guessed from the path if there's a `Content` folder in it.
Each JSON has `parent`, `parameters` (scalar / vector / texture, with association and index), `staticSwitches`,
`activeOverrides` (the base property overrides that are really switched on), `materialLayers` (reference only),
and with `--chain`: `chain` (every parent up to the master) and `effective` (the values after inheritance).
With `--textures`: `textureSettings`. The format is `"itr-material-export"`, version 1.

### 2. Rebuild the assets in the editor

Run this in the editor's Output Log console. You can also use File > Execute Python Script after setting the options
at the top of the script:
```
py "C:/path/material_import_ue.py" "C:/path/exports" --dest /Game/Recreated
```
Use `--fallback-parent /Game/MyMaster` if the parent is missing from your project and you haven't exported its chain.
Other options are `--no-stubs`, `--no-placeholders`, `--overwrite` and `--no-save`.

Assets are created under `--dest`. Keeping them away from the game's original paths matters: an asset packed at one
of those paths would replace the original when the game loads it.

You'll find a report at `<project>\Saved\matexport_report.json` listing what was created, skipped or couldn't be set.

### 3. Check the saved result

Restart the editor before this check, so it reads the files from disk rather than the assets still in memory:
```
py "C:/path/verify_in_editor.py" "C:/path/exports" --dest /Game/Recreated
```
**Static switches need the engine patch.** The importer uses our patched
`MaterialEditingLibrary.SetMaterialInstanceStaticSwitchParameterValue` (see [the guide](../../map-making/guide.md) §3).
Stock 4.27 lets Python read switches but not set them. Without the patch, check the report and set those switches by hand.

If you call that function yourself, there are two details to watch:

- The parent must declare the parameter.
- `Association` uses the engine's enum numbers: **2 is global**, 0 is layer and 1 is blend. The function defaults to 0,
  so leaving it out for a global switch makes the call return `False`.

### Optional: compare with an existing editor copy

To compare the export with an editor asset, such as the ITR-SDK's copy, run:
```bat
python compare_editor_copy.py exports\Mi_LandscapeV6_Swamp.json <sdk>\Content\ART2\WorldMaterials\MaterialInstans\Mi_LandscapeV6_Swamp.uasset --uassetgui UAssetGUI.exe
```

## What's tested

| Part | Tested? |
|---|---|
| Reading 2.7.2 instances and masters: parent, scalar / vector / texture parameters, static switches, overrides, material layer stacks, master settings and cached parameters, texture settings | **Yes, offline.** 230 instances and 70 masters from the unpacked 2.7.2 game that also exist in the ITR-SDK were compared with the SDK's editor copies (see below) |
| Same on the 1.0 game (UE 4.26) | No. The reader is written for 4.26 and 4.27 headers but only 2.7.2 was run through this version |
| `material_import_ue.py` in the editor | **Yes, headless** (`UE4Editor-Cmd -run=pythonscript -nullrhi`, our fork 4.27). 10 real 2.7.2 instances (+ 9 masters/parents, 57 placeholder textures) were recreated, saved, and read back in a fresh session with `verify_in_editor.py`: 828 checks, **0 mismatches**. Cases: instance with 6 to 8 static switches; instances with base property overrides (Masked + two-sided; Masked + TwoSidedFoliage + dithered LOD + clip value; Unlit masked); a landscape instance; a foliage instance with `Tint`; a plain prop instance; an instance of an instance (`M_Yarrow_PP_Wind_Inst`); a decal instance; a master. Exact on: parents, all global scalar / vector / texture parameter values, switch values, override flags and values, stand-in master parameter names and defaults, master blend / shading / domain / two-sided / clip settings, placeholder compression / sRGB / LOD group |
| Stand-in masters keep their parameters | **Yes.** Unconnected scalar, vector and texture parameter nodes do show up in `get_*_parameter_names` and instances accept values for them. Static switches have to be declared on the master too (the importer adds them, taken from the instances' switch lists, default off) or the instance can't hold them |
| Every enum value the game uses maps to the editor's Python enum (blend, shading model, domain, translucency lighting, texture compression, LOD group) | **Yes**, checked against all values in 3,064 textures and 1,633 materials |
| Rebuilt instances render the same as the game's | **No.** Not byte-for-byte (a recreated instance has a new shader map from *your* master), not visually. A stand-in master has no graph, so an instance on it is only a container for the numbers. A rendered editor screenshot was not obtained (the shader compile of a fresh scratch project did not finish inside the time limit) |
| Layer stacks, layer / blend parameters, static component masks | Exported, not imported: the Python API can't set them (listed in the report). `ShouldDoForwardSSR`-style overrides that the editor struct doesn't have are listed too |

**Offline comparison with the ITR-SDK** (300 randomly picked materials that exist in both the unpacked 2.7.2 game and
the SDK; compared by value with `compare_editor_copy.py`):
- **Parameters:** 1,824 scalar and 596 vector parameter values in 230 instances: **no differences in any value** the
  SDK copy has. 4 scalars (one instance) are in the cooked file but not the SDK's.
- **Textures:** 855 texture parameters. The SDK copy has no texture set on 530 of them (its textures are stripped); of
  the rest 1 differs by file and 1 by letter case only.
- **Parent:** 41 SDK instances point at the engine's `WorldGridMaterial` instead of the real master. The cooked file has it.
- **Static switches:** 1,815 in the cooked files. The SDK is missing 50 and disagrees on 5 values (the SDK copy is
  the one that's wrong or older there: the game runs the cooked values).
- **Masters:** 63 of 70 declare exactly the parameters (and have the settings) of the SDK's rebuild. The other 7 declare
  parameters the SDK's rebuild doesn't, which fits the SDK's masters being reconstructions.

These comparisons give us confidence in the exported values. Where the SDK keeps a value, the cooked data largely
agrees with it; the cooked files also retain settings that the SDK copies are missing.

## Limits

- We've only tested ITR 2.7.2 packages. Other versions, including 4.26 and other engines, are untried.
- Properties the reader doesn't know come out as raw bytes or are left out. Expression inputs on masters are skipped.
- The reader expects cooked game files. If you give it a package saved by an editor, its different header is
  recognised and the tool explains why it can't read it.
- Texture parameters point at game textures. The script uses a texture already in the project (SDK copy) at the same
  path, else makes a 4x4 flat placeholder with the original's compression and sRGB. It doesn't extract real textures.
- Per-layer parameters (`LayerParameter` / `BlendParameter` association, used by the `ML_`/`MLI_` layered materials)
  are exported but can't be set from Python.

## Licence

AGPL-3.0 like the rest of itr-common ([`../../LICENSE`](../../LICENSE)). The scripts contain no game data and the
exports contain only names, numbers and asset paths, but treat an export as derived from the game: don't publish a
folder of them as if it were yours.
