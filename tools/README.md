# Tools

- **`merge_gitdeps.py <old Commit.gitdeps.xml> <new Commit.gitdeps.xml> <out>`**
  Gets `Setup.bat` working again on an old UE 4.27 source drop. It keeps the file versions from the old manifest
  and takes the download locations from the new one. Files that aren't hosted any more come from the new manifest
  instead, or get dropped if they aren't needed for a build. The guide (§3) shows how we used it.

- **`hashpatch.py make|apply|check`**
  Engine patches that don't contain any engine source. `apply <json> <engine root>` (the engine root is the folder
  with `Engine\` in it) checks every file's hash first, and won't apply if anything doesn't match or it's already
  been applied.

- **`ub_extract_exe.py [exe or dll] --dump out.json`** (or `--find <member>`)
  Pulls every shader parameter struct out of a UE 4.27 shipping exe or a Development editor DLL: member names,
  offsets, types, rows and columns, array sizes. With no path it reads the game's exe from the usual Steam folder.
  Needs `pefile` and `capstone`.

- **`ub_material_diff.py <game.json> <your dll jsons...>`**
  Compares the uniform buffers that material shaders use, and prints `IDENTICAL` or the members that differ.

- **`shadermap_dump.py <pkg.uexp> [-v]`** (or `--diff <a> <b>`)
  Lists the compiled shaders in a cooked package, which uniform buffers each one binds and their layout hashes.
  `--diff` compares two cooks of the same material. Needs `lz4`.

- **`dxbc_disasm.py <pkg.uexp> [--freq VS] [--grep RE] [--out DIR]`**
  Disassembles the compiled shaders in a cooked package using Windows' `d3dcompiler_47.dll`.

## Where `data/ub` came from
We made it with:
```
python ub_extract_exe.py "<game>\IntoTheRadius\Binaries\Win64\IntoTheRadius-Win64-Shipping.exe" --dump game.json
```
If the game gets updated, run that again to see whether anything changed.

In a shipping build, each struct member is registered by a tiny compiled function. The tool steps through those
functions with capstone to read the member lists back out. Dump an editor build the same way, compare the two with
`ub_material_diff.py`, and you get the list of things that engine would need changing.
