# Tools

| Script | Use |
|---|---|
| `merge_gitdeps.py <old Commit.gitdeps.xml> <new Commit.gitdeps.xml> <out>` | Makes an old UE 4.27 source drop's `Setup.bat` work again. File versions come from the old manifest, download locations from the new one. Files no longer hosted take the new manifest's version, or are dropped if they aren't build files. See the guide §3 |
| `hashpatch.py make|apply|check` | Engine patches without engine source lines. `apply <json> <engine root>` (the folder containing `Engine\`) checks every file's hash first and refuses a mismatch or a second application |
| `ub_extract_exe.py [exe or dll] --dump out.json` / `--find <member>` | Recovers every shader parameter struct (member name, offset, type, rows × columns, array size) from a UE 4.27 shipping exe or a Development editor DLL. Without a path it reads the game's exe from the default Steam location. Needs `pefile`, `capstone` |
| `ub_material_diff.py <game.json> <your dll jsons...>` | Compares the uniform buffers that material shaders use: `IDENTICAL`, or the members that differ |
| `shadermap_dump.py <pkg.uexp> [-v]` / `--diff <a> <b>` | Lists the compiled shaders in a cooked package (types, the uniform buffers each binds and their layout hashes); `--diff` compares two cooks of the same material. Needs `lz4` |
| `dxbc_disasm.py <pkg.uexp> [--freq VS] [--grep RE] [--out DIR]` | Disassembles the compiled shaders in a cooked package with Windows' `d3dcompiler_47.dll` |

How the layout table in `../data/ub/` was made, and how to redo it for a new game version:
`python ub_extract_exe.py "<game>\IntoTheRadius\Binaries\Win64\IntoTheRadius-Win64-Shipping.exe" --dump game.json`.
Each struct member is registered by a small compiled function. The tool simulates those functions (with capstone)
to read the member tables back. Comparing the result with the same dump from an editor build
(`ub_material_diff.py`) lists exactly what that engine would have to change.
