# Tools

These are the small tools we used to get the editor building and track down the shader differences between it and
the game. You don't need to learn all of them before making a map; the [map-making guide](../map-making/guide.md)
points you to them when they're needed.

They use Python 3. The extra packages needed by individual tools are noted below.

- **`merge_gitdeps.py <old Commit.gitdeps.xml> <new Commit.gitdeps.xml> <out>`**
  Gets `Setup.bat` working again on an old UE 4.27 source drop. It keeps the file versions from the old manifest
  and takes the download locations from the new one. Files that aren't hosted any more come from the new manifest
  instead, or get dropped if they aren't needed for a build. The guide (§3) shows how we used it.

- **`hashpatch.py make|apply|check`**
  Creates, applies or checks engine patches without including engine source in the patch.
  Use `apply <json> <engine root>`, where the engine root is the folder containing `Engine\`. It checks every file's
  hash before changing anything, so a mismatch or an already-applied patch stops the operation. A patch can also create new files (stored with `"create": true`); `apply` refuses if such a file
  already exists. `engine/itr-contactshadowimpostor.hashpatch.json` is one of those.

- **`ub_extract_exe.py [exe or dll] --dump out.json`** (or `--find <member>`)
  Pulls every shader parameter struct out of a UE 4.27 shipping exe or a Development editor DLL: member names,
  offsets, types, rows and columns, array sizes. With no path it reads the game's exe from the usual Steam folder.
  Needs `pefile` and `capstone`.

- **`ub_material_diff.py <game.json> <your dll jsons...>`**
  Checks whether the game and your editor agree on the uniform buffers used by material shaders. These are the
  layouts of the data passed into a shader. It prints `IDENTICAL` when they match, or lists the members that differ.

- **`shadermap_dump.py <pkg.uexp> [-v]`** (or `--diff <a> <b>`)
  Lists the compiled shaders in a cooked package, which uniform buffers each one binds and their layout hashes.
  `--diff` compares two cooks of the same material. Needs `lz4`.

- **`dxbc_disasm.py <pkg.uexp> [--freq VS] [--grep RE] [--out DIR]`**
  Disassembles the compiled shaders in a cooked package using Windows' `d3dcompiler_47.dll`.

- **[`material-export/`](material-export/)**
  Exports a cooked material or material instance to JSON and rebuilds it in the editor. Start with its separate
  README: material instances can keep their settings, but a cooked master's original shader graph cannot be recovered.

## Where `data/ub` came from

The files in `data/ub` record the game's shader parameter layouts. We generated them with:
```
python ub_extract_exe.py "<game>\IntoTheRadius\Binaries\Win64\IntoTheRadius-Win64-Shipping.exe" --dump game.json
```
If the game gets updated, run that again to see whether anything changed.

In a shipping build, each struct member is registered by a tiny compiled function. The tool steps through those
functions with capstone to read the member lists back out. Dump an editor build the same way, compare the two with
`ub_material_diff.py`, and the differences show which parts of the engine need changing.
