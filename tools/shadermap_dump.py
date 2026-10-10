"""Decode the inline material shader maps in a cooked UE 4.27 package (D3D SM5, bShareMaterialShaderCode=False).

    python tools/shadermap_dump.py <pkg.uexp|.uasset> [-v]       summary (+ every shader with -v)
    python tools/shadermap_dump.py --diff <game pkg> <our pkg>     compare uniform-buffer layouts and type layouts

What it reads (UE 4.27 source: Material.cpp SerializeInlineShaderMaps, MaterialShared.cpp
FMaterialResourceMemoryWriter, ShaderMap.cpp FShaderMapBase::Serialize, ShaderResource.cpp
FShaderMapResourceCode::Serialize, D3DShaderCompiler.inl):
  int32 NumResources | name table (FString + 2x uint16 hash) | Locs (u32 offset, u8 FL, u8 QL) | int32 NumBytes | bytes
  per resource: bCooked, bValid, id (QL, FL, CookedShaderMapIdHash, layout params), frozen content (skipped),
  type-layout dependencies (NameHash, LayoutSize, LayoutHash), bShareCode, code:
  ResourceHash, ShaderHashes[N], ShaderEntries[N] = (LZ4 code, uncompressed size, frequency).
  Uncompressed D3D code: SRT (bits, SRV/sampler/UAV maps, ResourceTableLayoutHashes, texture map) | DXBC |
  optional data ('u' = uniform buffer names by slot) | int32 optional data size.
The frozen content is located but not decoded. The code block is found by its count signature
(N, 20*N bytes of hashes, N again) and the dependency list by walking back from it.

A uniform buffer's layout hash (per slot, from the SRT) changes whenever its member table changes, so the
same name with a different hash between two cooks means the shaders bind a differently laid-out buffer.
"""
import struct, sys, collections
import lz4.block

FREQ = ['VS', 'HS', 'DS', 'PS', 'GS', 'CS', 'RayGen', 'RayMiss', 'RayHit', 'RayCallable']
FL = {0: 'ES2', 1: 'ES3_1', 2: 'SM4', 3: 'SM5'}
QL = {0: 'Low', 1: 'High', 2: 'Medium', 3: 'Epic', 4: 'Num'}


class R:
    def __init__(s, d, p=0): s.d, s.p = d, p
    def u8(s): v = s.d[s.p]; s.p += 1; return v
    def u16(s): v = struct.unpack_from('<H', s.d, s.p)[0]; s.p += 2; return v
    def u32(s): v = struct.unpack_from('<I', s.d, s.p)[0]; s.p += 4; return v
    def i32(s): v = struct.unpack_from('<i', s.d, s.p)[0]; s.p += 4; return v
    def u64(s): v = struct.unpack_from('<Q', s.d, s.p)[0]; s.p += 8; return v
    def raw(s, n):
        if n < 0 or s.p + n > len(s.d): raise ValueError('read past end')
        v = s.d[s.p:s.p + n]; s.p += n; return v
    def fstr(s):
        n = s.i32()
        if n == 0: return ''
        if n < 0: return s.raw(-2 * n).decode('utf-16-le').rstrip('\0')
        if n > 1024: raise ValueError('string too long')
        b = s.raw(n)
        if b[-1] != 0: raise ValueError('unterminated')
        return b[:-1].decode('latin1')
    def arr_u32(s):
        n = s.i32()
        if not 0 <= n < 1 << 16: raise ValueError('bad array')
        return [s.u32() for _ in range(n)]


def read_pkg(path):
    if path.endswith('.uasset') or path.endswith('.umap'):
        path = path.rsplit('.', 1)[0] + '.uexp'
    return open(path, 'rb').read()


def find_blocks(d):
    """Yield (offset, names, locs, bytes_start, bytes_end) for each inline shader map block."""
    p = 0
    while p < len(d) - 16:
        nres, nnames = struct.unpack_from('<ii', d, p)
        if 0 < nres <= 16 and 0 < nnames <= 8192:
            try:
                r = R(d, p + 8)
                names = []
                for _ in range(nnames):
                    t = r.fstr()
                    if not t or not t.isprintable(): raise ValueError('bad name')
                    r.u16(); r.u16()
                    names.append(t)
                nloc = r.i32()
                if not 0 < nloc <= 64: raise ValueError('bad locs')
                locs = [(r.u32(), r.u8(), r.u8()) for _ in range(nloc)]
                if locs[0][0] != 0: raise ValueError('loc0')
                nbytes = r.i32()
                if not 0 < nbytes <= len(d) - r.p: raise ValueError('bytes')
                yield p, names, locs, r.p, r.p + nbytes
                p = r.p + nbytes
                continue
            except (ValueError, struct.error, IndexError, UnicodeDecodeError):
                pass
        p += 1


def find_code(d, lo, hi):
    """Offset of FShaderMapResourceCode (its ResourceHash) inside [lo, hi), else None.
    The block is the last thing in a cooked resource, so all N entries must parse and end exactly at hi."""
    for q in range(lo + 20, hi - 8):
        n = struct.unpack_from('<i', d, q)[0]
        if 0 < n <= 50000:
            e = q + 4 + 20 * n
            if e + 4 <= hi and struct.unpack_from('<i', d, e)[0] == n:
                try:
                    r = R(d, e + 4)
                    for _ in range(n):
                        ln = r.i32()
                        if not 0 < ln <= hi - r.p: raise ValueError
                        r.raw(ln); r.i32()
                        if r.u8() >= len(FREQ): raise ValueError
                    if r.p == hi:
                        return q - 20
                except (ValueError, struct.error):
                    pass
    return None


def parse_code_entry(code, usize):
    raw = code if len(code) == usize else lz4.block.decompress(code, uncompressed_size=usize)
    r = R(raw)
    bits = r.u32()
    srv, smp, uav, hashes, tex = r.arr_u32(), r.arr_u32(), r.arr_u32(), r.arr_u32(), r.arr_u32()
    dx = r.p
    if raw[dx:dx + 4] != b'DXBC':
        dx = raw.find(b'DXBC')
    dxsize = struct.unpack_from('<I', raw, dx + 24)[0]
    opt_size = struct.unpack_from('<i', raw, len(raw) - 4)[0]
    opt = {}
    o, end = len(raw) - opt_size, len(raw) - 4
    while o < end:
        k = raw[o]; sz = struct.unpack_from('<I', raw, o + 1)[0]
        opt[chr(k)] = raw[o + 5:o + 5 + sz]; o += 5 + sz
    ubnames = []
    if 'u' in opt:
        ur = R(opt['u']); ubnames = [ur.fstr() for _ in range(ur.i32())]
    return dict(bits=bits, layout_hashes=hashes, ubnames=ubnames, cbuffers=dxbc_cbuffers(raw[dx:dx + dxsize]),
                dxbc=raw[dx:dx + dxsize], opt_keys=sorted(opt))


def dxbc_cbuffers(dx):
    """{slot: size in float4s} from the dcl_constantbuffer declarations in SHEX/SHDR."""
    out = {}
    nch = struct.unpack_from('<I', dx, 28)[0]
    for k in range(nch):
        co = struct.unpack_from('<I', dx, 32 + 4 * k)[0]
        if dx[co:co + 4] not in (b'SHEX', b'SHDR'): continue
        toks = struct.unpack_from('<%dI' % (struct.unpack_from('<I', dx, co + 12)[0]), dx, co + 8)
        i = 2
        while i < len(toks):
            op = toks[i] & 0x7ff
            ln = toks[i + 1] if op == 0x35 else (toks[i] >> 24) & 0x7f
            if op == 0x59:  # dcl_constantbuffer: opcode, operand, slot, size
                out[toks[i + 2]] = toks[i + 3]
            if ln == 0: break
            i += ln
    return out


def parse_resource(d, lo, hi, names):
    r = R(d, lo)
    res = dict(cooked=r.u32(), valid=r.u32())
    if not res['valid']:
        return res
    res.update(ql=r.i32(), fl=r.i32(), idhash=r.raw(20).hex(), layout=(r.u32(), r.u32()), frozen=r.u32())
    res['frozen_at'] = r.p
    c = find_code(d, r.p + res['frozen'], hi)
    if c is None:
        res['error'] = 'code block not found'; return res
    # dependencies: int32 n, n x (u64 NameHash, u32 LayoutSize, 20B LayoutHash), then bShareCode (u32), then code
    res['share_code'] = struct.unpack_from('<I', d, c - 4)[0]
    deps = None
    for k in range(1, 4096):
        at = c - 8 - 32 * k
        if at < lo: break
        if struct.unpack_from('<i', d, at)[0] == k:
            dr = R(d, at + 4); deps = [(dr.u64(), dr.u32(), dr.raw(20).hex()) for _ in range(k)]; break
    res['deps'] = deps or []
    r = R(d, c)
    res['resource_hash'] = r.raw(20).hex()
    n = r.i32(); hashes = [r.raw(20).hex() for _ in range(n)]
    assert r.i32() == n
    shaders = []
    for h in hashes:
        code = r.raw(r.i32()); usize = r.i32(); freq = r.u8()
        s = dict(hash=h, freq=FREQ[freq], csize=len(code), usize=usize)
        try:
            s.update(parse_code_entry(code, usize))
        except Exception as e:
            s['error'] = repr(e)
        shaders.append(s)
    res['shaders'] = shaders
    res['end'] = r.p
    return res


def scan_code_blocks(d):
    """Every FShaderMapResourceCode block in d, without knowing the container format (for
    GlobalShaderCache-*.bin): N, N hashes, N again, then N entries that all parse."""
    out, q = [], 4
    while q < len(d) - 8:
        n = struct.unpack_from('<i', d, q)[0]
        if 0 < n <= 50000:
            e = q + 4 + 20 * n
            if e + 4 <= len(d) and struct.unpack_from('<i', d, e)[0] == n:
                try:
                    r = R(d, e + 4)
                    for _ in range(n):
                        ln = r.i32()
                        if not 0 < ln <= len(d) - r.p: raise ValueError
                        r.raw(ln); r.i32()
                        if r.u8() >= len(FREQ): raise ValueError
                    out.append((q - 20, r.p))
                    q = r.p
                    continue
                except (ValueError, struct.error):
                    pass
        q += 1
    return out


def load_scan(path):
    """Shaders of every code block in an arbitrary file, as one pseudo block."""
    d = open(path, 'rb').read()
    shaders = []
    for c, end in scan_code_blocks(d):
        r = R(d, c + 20)
        n = r.i32(); hashes = [r.raw(20).hex() for _ in range(n)]; r.i32()
        for h in hashes:
            code = r.raw(r.i32()); usize = r.i32(); freq = r.u8()
            s = dict(hash=h, freq=FREQ[freq], usize=usize)
            try:
                s.update(parse_code_entry(code, usize))
            except Exception as e:
                s['error'] = repr(e)
            shaders.append(s)
    return [dict(offset=0, names=[], locs=[], resources=[dict(valid=1, shaders=shaders, deps=[])])]


def load(path):
    if path.endswith('.bin'):
        return load_scan(path)
    d = read_pkg(path)
    blocks = []
    for off, names, locs, b0, b1 in find_blocks(d):
        starts = [b0 + l[0] for l in locs] + [b1]
        ress = [parse_resource(d, starts[i], starts[i + 1], names) for i in range(len(locs))]
        blocks.append(dict(offset=off, names=names, locs=locs, resources=ress))
    return blocks


def ub_table(blocks):
    """{ub name: {(layout hash, cbuffer float4s), ...}} over every shader."""
    t = collections.defaultdict(collections.Counter)
    for b in blocks:
        for res in b['resources']:
            for s in res.get('shaders', []):
                if 'ubnames' not in s: continue
                for slot, name in enumerate(s['ubnames']):
                    if not name: continue
                    h = s['layout_hashes'][slot] if slot < len(s['layout_hashes']) else None
                    t[name][('%08x' % h if h is not None else '-', s['cbuffers'].get(slot))] += 1
    return t


def summary(path, verbose=False):
    blocks = load(path)
    print(path)
    if not blocks:
        print('  no inline shader maps'); return
    for b in blocks:
        print('  block @0x%x: %d resources, %d names' % (b['offset'], len(b['resources']), len(b['names'])))
        print('    names:', ', '.join(b['names']))
        for (lo, fl, ql), res in zip(b['locs'], b['resources']):
            if not res.get('valid'):
                print('    [%s/%s] invalid' % (FL.get(fl, fl), QL.get(ql, ql))); continue
            sh = res.get('shaders', [])
            fc = collections.Counter(s['freq'] for s in sh)
            print('    [%s/%s] id %s  layout %s  frozen %d B  deps %d  shaders %d %s%s' % (
                FL.get(res['fl']), QL.get(res['ql']), res['idhash'][:16], res['layout'], res['frozen'],
                len(res.get('deps', [])), len(sh), dict(fc), '  ERROR ' + res['error'] if 'error' in res else ''))
            if verbose:
                for s in sh:
                    if 'error' in s:
                        print('      %s %s %s' % (s['freq'], s['hash'][:12], s['error'])); continue
                    ubs = ' '.join('%s=%s:%08x/%s' % (i, n, s['layout_hashes'][i] if i < len(s['layout_hashes']) else 0,
                                                       s['cbuffers'].get(i)) for i, n in enumerate(s['ubnames']) if n)
                    print('      %s %s %6dB cb%s  %s' % (s['freq'], s['hash'][:12], s['usize'], dict(sorted(s['cbuffers'].items())), ubs))
    print('  uniform buffers (name: (layout hash, float4s) x shaders):')
    for name, c in sorted(ub_table(blocks).items()):
        print('    %-28s %s' % (name, dict(c)))


def diff(a, b):
    A, B = load(a), load(b)
    ta, tb = ub_table(A), ub_table(B)
    print('A =', a); print('B =', b)
    print('\nUniform buffers (layout hash, float4s):')
    for name in sorted(set(ta) | set(tb)):
        ka, kb = set(ta.get(name, {})), set(tb.get(name, {}))
        tag = 'same' if ka == kb else ('only A' if not kb else 'only B' if not ka else 'DIFFERENT')
        print('  %-28s %-9s A=%s B=%s' % (name, tag, sorted(ka, key=str), sorted(kb, key=str)))
    da = {h: (sz, lh) for blk in A for res in blk['resources'] for h, sz, lh in res.get('deps', [])}
    db = {h: (sz, lh) for blk in B for res in blk['resources'] for h, sz, lh in res.get('deps', [])}
    common = set(da) & set(db)
    print('\nFrozen type layouts: A %d, B %d, common %d, same layout %d' % (
        len(da), len(db), len(common), sum(da[h] == db[h] for h in common)))
    for h in sorted(common):
        if da[h] != db[h]: print('  differs: namehash %016x A=%s B=%s' % (h, da[h], db[h]))
    for blk in A + B:
        pass
    sa = {s['hash'] for blk in A for res in blk['resources'] for s in res.get('shaders', [])}
    sb = {s['hash'] for blk in B for res in blk['resources'] for s in res.get('shaders', [])}
    print('\nShader code hashes: A %d, B %d, identical %d' % (len(sa), len(sb), len(sa & sb)))
    na = set(n for blk in A for n in blk['names']); nb = set(n for blk in B for n in blk['names'])
    print('Names only in A:', sorted(na - nb)); print('Names only in B:', sorted(nb - na))


if __name__ == '__main__':
    args = [x for x in sys.argv[1:] if not x.startswith('-')]
    if '--diff' in sys.argv:
        diff(*args[:2])
    else:
        for p in args:
            summary(p, '-v' in sys.argv)
