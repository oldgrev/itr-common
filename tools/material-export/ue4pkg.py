"""Minimal reader for cooked Unreal Engine 4.26 / 4.27 packages (.uasset + .uexp), as shipped in Into the Radius 1.

Reads the package header (name map, imports, exports) and the tagged properties of an export. That is all
`material_export.py` needs. It does not read bulk data, textures, meshes, compressed packages or unversioned
properties, and it has only been tried on ITR 2.7.2's materials.

    pkg = Package("E:/itr27/pak/IntoTheRadius/Content/ART2/Foo/MI_Foo.uasset")
    for i, e in enumerate(pkg.exports):
        print(pkg.class_name(e), pkg.name_of(e))
    props = pkg.properties(0)            # {property name: value}, object references already turned into paths

Cooked layout (FPackageFileSummary of a 4.26 / 4.27 cooked package, LegacyFileVersion -7, FilterEditorOnly):
the summary, the name map, imports (28 bytes each), exports (104 bytes each) and a few small tables live in the
.uasset. Export data is in the .uexp, right after the header: an export's SerialOffset counts from the start of the
.uasset, so its position in the .uexp is SerialOffset - TotalHeaderSize.

Licence: AGPL-3.0 like the rest of itr-common (see ../../LICENSE).
"""
import os
import struct

# Structs the engine writes as plain binary instead of tagged properties
NATIVE_STRUCTS = {"Vector": "<3f", "Vector4": "<4f", "Rotator": "<3f", "Quat": "<4f", "Vector2D": "<2f",
                  "IntPoint": "<2i", "LinearColor": "<4f", "Color": "<4B", "Box": "<6fB", "Guid": "<4I",
                  "IntVector": "<3i"}


def fstring(b, p):
    n = struct.unpack_from("<i", b, p)[0]
    p += 4
    if n == 0:
        return "", p
    if n < 0:
        return b[p:p - 2 * n].decode("utf-16-le")[:-1], p - 2 * n
    return b[p:p + n - 1].decode("latin1"), p + n


class Import:
    def __init__(self, names, b, p):
        # layout: ClassPackage (FName), ClassName (FName), OuterIndex (int32), ObjectName (FName)
        cp = struct.unpack_from("<ii", b, p)
        cn = struct.unpack_from("<ii", b, p + 8)
        self.outer = struct.unpack_from("<i", b, p + 16)[0]
        on = struct.unpack_from("<ii", b, p + 20)
        self.class_package = _fname(names, cp)
        self.class_name = _fname(names, cn)
        self.name = _fname(names, on)


class Export:
    def __init__(self, names, b, p):
        self.cls = struct.unpack_from("<i", b, p)[0]          # FPackageIndex of the class
        self.super = struct.unpack_from("<i", b, p + 4)[0]
        self.template = struct.unpack_from("<i", b, p + 8)[0]
        self.outer = struct.unpack_from("<i", b, p + 12)[0]
        self.name = _fname(names, struct.unpack_from("<ii", b, p + 16))
        self.serial_size, self.serial_offset = struct.unpack_from("<qq", b, p + 28)
        self.is_asset = bool(struct.unpack_from("<i", b, p + 80)[0])


def _fname(names, pair):
    i, n = pair
    s = names[i] if 0 <= i < len(names) else f"?{i}"
    return s if n == 0 else f"{s}_{n - 1}"


class Package:
    def __init__(self, path):
        path = os.fspath(path)
        base, ext = os.path.splitext(path)
        if ext.lower() not in (".uasset", ".umap"):
            raise ValueError("expected a .uasset or .umap path")
        self.path = path
        self.header = open(path, "rb").read()
        uexp = base + ".uexp"
        self.data = open(uexp, "rb").read() if os.path.exists(uexp) else None
        b = self.header
        if struct.unpack_from("<I", b, 0)[0] != 0x9E2A83C1:
            raise ValueError("not an Unreal package (bad magic)")
        p = 4
        legacy = struct.unpack_from("<i", b, p)[0]
        if legacy != -7:
            raise ValueError(f"LegacyFileVersion {legacy}: only 4.26 / 4.27 packages (-7) are supported")
        p += 4 + 4 + 8                                             # legacy, LegacyUE3Version, UE4 + licensee version
        p += 4 + struct.unpack_from("<i", b, p)[0] * 20            # custom versions
        self.total_header_size = struct.unpack_from("<i", b, p)[0]
        p += 4
        _, p = fstring(b, p)                                       # FolderName
        flags = struct.unpack_from("<I", b, p)[0]
        if not flags & 0x80000000:                                 # PKG_FilterEditorOnly: set in cooked packages
            raise ValueError("not a cooked package (saved by an editor): the reader only handles cooked game files")
        p += 4                                                     # PackageFlags
        (name_count, name_off, _gc, _go, export_count, export_off, import_count, import_off) = \
            struct.unpack_from("<8i", b, p)
        self.names, q = [], name_off
        for _ in range(name_count):
            s, q = fstring(b, q)
            self.names.append(s)
            q += 4                                                 # two uint16 name hashes
        self.imports = [Import(self.names, b, import_off + i * 28) for i in range(import_count)]
        self.exports = [Export(self.names, b, export_off + i * 104) for i in range(export_count)]

    # ---- object references -------------------------------------------------------------------------------------
    def name_of(self, e):
        return e.name

    def class_name(self, e):
        return self.ref_class(e.cls)

    def ref_class(self, idx):
        if idx < 0:
            return self.imports[-idx - 1].name
        if idx > 0:
            return self.exports[idx - 1].name
        return None

    def object_path(self, idx):
        """'/Game/Dir/Pkg.Name' for an import, '<this package>.Name' style for an export, None for 0."""
        if idx == 0:
            return None
        if idx > 0:
            e = self.exports[idx - 1]
            outer = self.object_path(e.outer) if e.outer else None
            return (outer + ":" if outer else "") + e.name
        imp = self.imports[-idx - 1]
        if imp.outer == 0:
            return imp.name                                         # a package: '/Game/Dir/Pkg'
        outer = self.imports[-imp.outer - 1]
        if outer.outer == 0:
            return outer.name + "." + imp.name                      # '/Game/Dir/Pkg.Name'
        return self.object_path(imp.outer) + ":" + imp.name

    # ---- export data -------------------------------------------------------------------------------------------
    def export_bytes(self, i):
        e = self.exports[i]
        if self.data is None:
            return self.header, e.serial_offset
        return self.data, e.serial_offset - self.total_header_size

    def properties(self, i):
        """Tagged properties of export i: {name: value}. Object references become path strings."""
        buf, pos = self.export_bytes(i)
        end = pos + self.exports[i].serial_size
        props, _ = read_props(buf, self.names, pos, end, self.object_path)
        return props

    def properties_at(self, i):
        """Like properties(), but also returns the position after the property block (for data that follows it)."""
        buf, pos = self.export_bytes(i)
        end = pos + self.exports[i].serial_size
        return read_props(buf, self.names, pos, end, self.object_path) + (buf,)


# ---- tagged properties ---------------------------------------------------------------------------------------------
class _R:
    def __init__(self, b, names, p):
        self.b, self.names, self.p = b, names, p

    def i32(self):
        v = struct.unpack_from("<i", self.b, self.p)[0]
        self.p += 4
        return v

    def u8(self):
        v = self.b[self.p]
        self.p += 1
        return v

    def name(self):
        i, n = struct.unpack_from("<ii", self.b, self.p)
        self.p += 8
        return _fname(self.names, (i, n))


def read_props(b, names, pos=0, limit=None, resolve=None):
    """({name: value}, end position). `resolve(package index) -> str` turns object references into paths.

    Values: ints/floats/bools/strings; names as str; enums as str; LinearColor etc. as tuples; tagged structs as
    dicts; arrays as lists; anything unknown stays raw bytes. A repeated name (array index > 0) is keyed 'Name[i]'.
    """
    resolve = resolve or (lambda i: i)
    r = _R(b, names, pos)
    out = {}
    end = limit if limit is not None else len(b)
    while r.p + 8 <= end:
        name = r.name()
        if name == "None":
            break
        t = r.name()
        size = r.i32()
        idx = r.i32()
        extra = None
        if t == "StructProperty":
            extra = r.name()
            r.p += 16
        elif t == "BoolProperty":
            extra = r.u8()
        elif t in ("ByteProperty", "EnumProperty", "ArrayProperty", "SetProperty"):
            extra = r.name()
        elif t == "MapProperty":
            extra = (r.name(), r.name())
        if r.u8():                                   # HasPropertyGuid
            r.p += 16
        vstart = r.p
        raw = b[vstart:vstart + size]
        try:
            if t == "BoolProperty":
                val = bool(extra)
            elif t == "StructProperty":
                if extra in NATIVE_STRUCTS:
                    val = struct.unpack_from(NATIVE_STRUCTS[extra], raw)
                else:
                    val, _ = read_props(b, names, vstart, vstart + size, resolve)
            elif t == "ArrayProperty":
                val = _array(b, names, vstart, size, extra, resolve)
            elif t in ("ByteProperty", "EnumProperty"):
                if size == 1:
                    val = raw[0]
                else:
                    i, n = struct.unpack_from("<ii", raw)
                    val = _fname(names, (i, n))
            else:
                val = _scalar(t, raw, names, resolve)
        except (struct.error, IndexError, ValueError):
            val = raw                                # a struct we can't parse (e.g. stripped expression inputs)
        out[name if idx == 0 else f"{name}[{idx}]"] = val
        r.p = vstart + size
    return out, r.p


def _scalar(t, b, names, resolve):
    if t == "IntProperty":
        return struct.unpack("<i", b[:4])[0]
    if t == "UInt32Property":
        return struct.unpack("<I", b[:4])[0]
    if t == "Int64Property":
        return struct.unpack("<q", b[:8])[0]
    if t == "UInt64Property":
        return struct.unpack("<Q", b[:8])[0]
    if t == "Int16Property":
        return struct.unpack("<h", b[:2])[0]
    if t == "UInt16Property":
        return struct.unpack("<H", b[:2])[0]
    if t == "Int8Property":
        return struct.unpack("<b", b[:1])[0]
    if t == "FloatProperty":
        return struct.unpack("<f", b[:4])[0]
    if t == "DoubleProperty":
        return struct.unpack("<d", b[:8])[0]
    if t == "ObjectProperty":
        return resolve(struct.unpack("<i", b[:4])[0])
    if t == "NameProperty":
        return _fname(names, struct.unpack("<ii", b[:8]))
    if t == "StrProperty":
        return fstring(b, 0)[0]
    if t == "SoftObjectProperty":                    # FSoftObjectPath: asset path name + sub-path string
        asset = _fname(names, struct.unpack("<ii", b[:8]))
        return asset
    return b


def _array(b, names, p, size, inner, resolve):
    n = struct.unpack_from("<i", b, p)[0]
    q = p + 4
    if inner == "StructProperty":
        r = _R(b, names, q)
        r.name(); r.name(); r.i32(); r.i32()         # inner tag: name, type, size, index
        sname = r.name()
        r.p += 16
        if r.u8():
            r.p += 16
        q = r.p
        vals = []
        if sname in NATIVE_STRUCTS:
            fmt = NATIVE_STRUCTS[sname]
            sz = struct.calcsize(fmt)
            for _ in range(n):
                vals.append(struct.unpack_from(fmt, b, q))
                q += sz
        else:
            for _ in range(n):
                v, q = read_props(b, names, q, p + size, resolve)
                vals.append(v)
        return vals
    fixed = {"IntProperty": "<i", "UInt32Property": "<I", "FloatProperty": "<f", "Int64Property": "<q",
             "UInt64Property": "<Q", "ObjectProperty": "<i", "UInt16Property": "<H", "Int16Property": "<h"}
    if inner in fixed:
        sz = struct.calcsize(fixed[inner])
        vals = [struct.unpack_from(fixed[inner], b, q + sz * k)[0] for k in range(n)]
        return [resolve(v) for v in vals] if inner == "ObjectProperty" else vals
    if inner == "NameProperty":
        return [_fname(names, struct.unpack_from("<ii", b, q + 8 * k)) for k in range(n)]
    if inner == "ByteProperty":
        return list(b[q:q + n])
    if inner == "BoolProperty":
        return [bool(x) for x in b[q:q + n]]
    if inner == "StrProperty":
        out = []
        for _ in range(n):
            s, q = fstring(b, q)
            out.append(s)
        return out
    return b[p:p + size]
