"""BPGen spec builder used by gen_penbullet.py: the B node/link builder and write(). Spec format: the ItrShowcaseEditor plugin's SPEC.md (BPGen)."""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SPECS = os.path.normpath(os.path.join(HERE, "..", "Specs"))

class B:
    def __init__(self):
        self.nodes, self.links, self.n = [], [], 0

    def add(self, op, **kw):
        nid = kw.pop("id", None) or "%s%d" % (op[:3], self.n)
        self.n += 1
        d = {"id": nid, "op": op}
        d.update(kw)
        self.nodes.append(d)
        return nid

    def link(self, a, b):
        self.links.append([a, b])

    def call(self, fn, pins=None, **kw):
        d = {"function": fn}
        if pins:
            d["pins"] = pins
        d.update(kw)
        return self.add("call", **d)

    def get(self, var, cls=None, target=None):
        d = {"var": var}
        if cls:
            d["class"] = cls
        nid = self.add("get", **d)
        if target:
            self.link(target, nid + ".self")
        return nid + "." + var

    def set(self, var, value=None, lit=None, cls=None, target=None):
        d = {"var": var}
        if cls:
            d["class"] = cls
        if lit is not None:
            d["pins"] = {var: lit}
        nid = self.add("set", **d)
        if value:
            self.link(value, nid + "." + var)
        if target:
            self.link(target, nid + ".self")
        return nid

    def flow(self, *items):
        """chain exec: each item is a node id (uses .then) or a (id, outpin) tuple; the next node's .execute is the target"""
        for a, b in zip(items, items[1:]):
            src = a if isinstance(a, tuple) else (a, "then")
            dst = b[0] if isinstance(b, tuple) else b
            self.link("%s.%s" % src, dst + ".execute")

    def to(self, src_id, pin, dst_id):
        self.link("%s.%s" % (src_id, pin), dst_id + ".execute")


def write(name, spec):
    os.makedirs(SPECS, exist_ok=True)
    p = os.path.join(SPECS, name + ".json")
    with open(p, "w") as f:
        json.dump(spec, f, indent=1)
    return p

