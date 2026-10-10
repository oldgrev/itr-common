"""Disassemble the DXBC shaders in a cooked material (or GlobalShaderCache .bin) with Windows' d3dcompiler_47.

    python tools/dxbc_disasm.py <pkg.uexp|.bin> [--freq VS] [--grep REGEX] [--out DIR]

Without --out, prints the lines matching --grep (default: dcl_ and imul/ishl lines) for each shader.
"""
import ctypes
import os
import re
import sys

sys.path.insert(0, os.path.dirname(__file__))
import shadermap_dump as sd  # noqa: E402

_d3d = ctypes.WinDLL("d3dcompiler_47.dll")


class _Blob(ctypes.Structure):
    pass


def disasm(dxbc):
    blob = ctypes.c_void_p()
    hr = _d3d.D3DDisassemble(ctypes.c_char_p(dxbc), ctypes.c_size_t(len(dxbc)), 0, None, ctypes.byref(blob))
    if hr != 0:
        return "D3DDisassemble failed %08x" % (hr & 0xFFFFFFFF)
    vt = ctypes.cast(blob, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents
    get_ptr = ctypes.WINFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p)(vt[3])
    get_size = ctypes.WINFUNCTYPE(ctypes.c_size_t, ctypes.c_void_p)(vt[4])
    release = ctypes.WINFUNCTYPE(ctypes.c_ulong, ctypes.c_void_p)(vt[2])
    text = ctypes.string_at(get_ptr(blob), get_size(blob)).decode("latin1")
    release(blob)
    return text


def shaders(path):
    for b in sd.load(path):
        for res in b["resources"]:
            for s in res.get("shaders", []):
                if "dxbc" in s:
                    yield s


if __name__ == "__main__":
    args = sys.argv[1:]
    path = args[0]
    freq = args[args.index("--freq") + 1] if "--freq" in args else None
    pat = re.compile(args[args.index("--grep") + 1] if "--grep" in args else r"dcl_|imul|ishl")
    out = args[args.index("--out") + 1] if "--out" in args else None
    for s in shaders(path):
        if freq and s["freq"] != freq:
            continue
        text = disasm(s["dxbc"])
        if out:
            os.makedirs(out, exist_ok=True)
            open(os.path.join(out, "%s_%s.asm" % (s["freq"], s["hash"][:12])), "w").write(text)
            continue
        print("=== %s %s  ubs %s" % (s["freq"], s["hash"][:12], [n for n in s["ubnames"] if n]))
        for line in text.splitlines():
            if pat.search(line):
                print("   ", line.strip())
