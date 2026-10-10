"""Recover every shader parameter / uniform buffer struct layout compiled into a UE 4.27 shipping exe.

Each struct member is registered by a small generated function (ShaderParameterMacros.h,
INTERNAL_SHADER_PARAMETER_EXPLICIT): it builds an FMember on the stack and appends it, then returns the previous
member's function. FMember (ShaderParameterMetadata.h): Name +0, ShaderType +8, Offset +0x10, BaseType +0x14 (u8),
Precision +0x18, NumRows +0x1c, NumColumns +0x20, NumElements +0x24, Struct +0x28. The stack copy sits at
rsp+0x20, so the stores go to [rsp+0x20..0x48]. Following the returned pointers from a chain's last member gives
the struct's members in reverse declaration order.

    python tools/ub_extract_exe.py [exe] --find TranslatedWorldToClip     print the struct containing a member
    python tools/ub_extract_exe.py [exe] --dump out.json                  every chain

The game exe's layouts are the ground truth for making our engine's uniform buffers match.
"""
import json
import re
import sys

import capstone
import pefile

EXE = r"C:\Program Files (x86)\Steam\steamapps\common\IntoTheRadius\IntoTheRadius\Binaries\Win64\IntoTheRadius-Win64-Shipping.exe"
BASETYPE = ["INVALID", "BOOL", "INT32", "UINT32", "FLOAT32", "TEXTURE", "SRV", "UAV", "SAMPLER", "RDG_TEXTURE",
            "RDG_TEXTURE_ACCESS", "RDG_TEXTURE_SRV", "RDG_TEXTURE_UAV", "RDG_BUFFER", "RDG_BUFFER_ACCESS",
            "RDG_BUFFER_SRV", "RDG_BUFFER_UAV", "RDG_UNIFORM_BUFFER", "NESTED_STRUCT", "INCLUDED_STRUCT",
            "REFERENCED_STRUCT", "RENDER_TARGET_BINDING_SLOTS"]
# FMember field offsets, relative to the stack copy, which sits at entry rsp - 0x38 in both the shipping exe
# (rsp+0x20 after push + sub 0x50) and the Development editor DLLs ([r11-0x38], r11 = entry rsp)
FIELDS = {0x00: "name", 0x08: "shader_type", 0x10: "offset", 0x14: "base_type", 0x18: "precision",
          0x1c: "rows", 0x20: "cols", 0x24: "elements", 0x28: "struct"}
FMEMBER_AT = -0x38


class Image:
    def __init__(self, path):
        self.pe = pefile.PE(path, fast_load=True)
        self.data = open(path, "rb").read()
        self.base = self.pe.OPTIONAL_HEADER.ImageBase
        t = [s for s in self.pe.sections if s.Name.startswith(b".text")][0]
        self.text_rva, self.text = t.VirtualAddress, self.data[t.PointerToRawData:t.PointerToRawData + t.SizeOfRawData]
        self.md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
        self.md.detail = True

    def off(self, rva):
        for s in self.pe.sections:
            if s.VirtualAddress <= rva < s.VirtualAddress + max(s.Misc_VirtualSize, s.SizeOfRawData):
                return rva - s.VirtualAddress + s.PointerToRawData
        return None

    def u16(self, rva):
        o = self.off(rva)
        if o is None:
            return None
        e = o
        while e < len(self.data) - 1 and self.data[e:e + 2] != b"\0\0":
            e += 2
        try:
            s = self.data[o:e].decode("utf-16-le")
        except UnicodeDecodeError:
            return None
        return s if s and s.isprintable() and len(s) < 200 else None


def parse_member_func(img, rva):
    """Simulate one member function. Returns dict of FMember fields + 'prev' (rva or 0), or None.
    Stack slots are tracked relative to the entry rsp (push/sub rsp, and r11 = rsp copies)."""
    X = capstone.x86
    o = rva - img.text_rva
    regs, mem, prev, sp, n = {}, {}, None, 0, 0
    frame = {"rsp": 0}
    for ins in img.md.disasm(img.text[o:o + 0x300], rva):
        n += 1
        if n > 90:
            return None
        m, ops = ins.mnemonic, ins.operands
        if m == "ret":
            prev = regs.get("rax")
            break
        if m == "jmp":
            return None
        if m == "push":
            frame["rsp"] -= 8
            continue
        if m == "sub" and ops[0].type == X.X86_OP_REG and ins.reg_name(ops[0].reg) == "rsp" and ops[1].type == X.X86_OP_IMM:
            frame["rsp"] -= ops[1].imm
            continue
        if m == "add" and ops[0].type == X.X86_OP_REG and ins.reg_name(ops[0].reg) == "rsp":
            continue
        if m == "mov" and ops[0].type == X.X86_OP_REG and ops[1].type == X.X86_OP_REG and ins.reg_name(ops[1].reg) == "rsp":
            frame[ins.reg_name(ops[0].reg)] = frame["rsp"]
            continue
        if m == "call":
            regs["rax"] = None
            continue
        dst = ins.reg_name(ops[0].reg) if ops and ops[0].type == X.X86_OP_REG else None
        full = ("r" + dst[1:]) if dst and dst.startswith("e") and len(dst) == 3 else dst
        if m == "lea" and ops[1].type == X.X86_OP_MEM and ops[1].mem.base == X.X86_REG_RIP:
            regs[full] = ins.address + ins.size + ops[1].mem.disp
            continue
        if m == "xor" and len(ops) == 2 and dst and ops[1].type == X.X86_OP_REG and ops[0].reg == ops[1].reg:
            regs[full] = 0
            continue
        if m == "mov" and dst and ops[1].type == X.X86_OP_IMM:
            regs[full] = ops[1].imm
            continue
        if m == "mov" and ops[0].type == X.X86_OP_MEM:
            base = ins.reg_name(ops[0].mem.base) if ops[0].mem.base else None
            if base in frame and ops[0].mem.index == 0:
                slot = frame[base] + ops[0].mem.disp
                if ops[1].type == X.X86_OP_IMM:
                    mem[slot] = ops[1].imm
                elif ops[1].type == X.X86_OP_REG:
                    r = ins.reg_name(ops[1].reg)
                    mem[slot] = regs.get(("r" + r[1:]) if r.startswith("e") and len(r) == 3 else r)
            continue
        if full and m not in ("cmp", "test"):
            regs.pop(full, None)
            frame.pop(full, None) if full != "rsp" else None
    if prev is None or FMEMBER_AT not in mem:
        return None
    f = {name: mem.get(FMEMBER_AT + d) for d, name in FIELDS.items()}
    f["name"] = img.u16(f["name"]) if isinstance(f["name"], int) else None
    if not f["name"] or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", f["name"]):
        return None
    f["shader_type"] = img.u16(f["shader_type"]) if isinstance(f["shader_type"], int) and f["shader_type"] else None
    bt = f["base_type"]
    f["base_type"] = BASETYPE[bt] if isinstance(bt, int) and bt < len(BASETYPE) else bt
    f["prev"] = prev if isinstance(prev, int) else None
    f["rva"] = rva
    return f


# movsxd rdi, dword ptr [rdx+8] / [rbx+8]: Members->Num() at the start of TArray::Add
NUM_LOAD = re.compile(rb"\x48\x63\x7a\x08|\x48\x63\x7b\x08")


def all_members(img):
    funcs, tried = {}, set()
    for m in NUM_LOAD.finditer(img.text):
        # function start: 16-byte aligned, right after int3/ret padding, closest first within 0x180 bytes
        # (Development builds have an int3 after an inlined assert call inside the function)
        i = m.start()
        for p in range(i - (img.text_rva + i) % 16, max(0, i - 0x180), -16):
            if img.text[p - 1] not in (0xCC, 0xC3):
                continue
            start = img.text_rva + p
            if start in tried:
                break
            tried.add(start)
            f = parse_member_func(img, start)
            if f:
                funcs[start] = f
                break
    return funcs


def chains(funcs):
    prevs = {f["prev"] for f in funcs.values() if f["prev"]}
    out = []
    for rva, f in funcs.items():
        if rva in prevs:
            continue                    # not the last member of its struct
        chain, cur = [], rva
        while cur in funcs:
            chain.append(funcs[cur])
            cur = funcs[cur]["prev"]
        out.append(list(reversed(chain)))
    return out


def fmt(f):
    t = f["base_type"]
    if f["rows"] or f["cols"]:
        t += "%sx%s" % (f["rows"], f["cols"])
    if f["elements"]:
        t += "[%s]" % f["elements"]
    return "%6d  %-34s %s %s" % (f["offset"] or 0, f["name"], t, f["shader_type"] or "")


if __name__ == "__main__":
    args = sys.argv[1:]
    exe = args[0] if args and not args[0].startswith("--") else EXE
    img = Image(exe)
    funcs = all_members(img)
    cs = chains(funcs)
    print("%d member functions, %d chains" % (len(funcs), len(cs)), file=sys.stderr)
    if "--find" in args:
        key = args[args.index("--find") + 1]
        for c in cs:
            if any(f["name"] == key for f in c):
                print("--- chain of %d members (last at rva 0x%x)" % (len(c), c[-1]["rva"]))
                for f in c:
                    print(fmt(f))
    if "--dump" in args:
        json.dump([[{k: v for k, v in f.items() if k != "prev"} for f in c] for c in cs],
                  open(args[args.index("--dump") + 1], "w"), indent=0)
