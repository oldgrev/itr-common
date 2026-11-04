# A small builder for BPGen specs (plain Python 3, no editor). The same file sits in loader-ue4ss/build-from-source/Scripts/.
# A spec is nodes + links: B().add(...) makes a node, link("a.pin", "b.pin") joins pins, chain(a, b, c) joins exec pins a.then -> b.execute -> c.execute.
import json


class B(object):
    def __init__(self):
        self.nodes, self.links, self.n = [], [], 0

    def add(self, op, **kw):
        self.n += 1
        nid = kw.pop("id", "n%d" % self.n)
        d = {"id": nid, "op": op}
        d.update(kw)
        self.nodes.append(d)
        return nid

    def link(self, a, b):
        self.links.append([a, b])

    def chain(self, *ids):
        for a, b in zip(ids, ids[1:]):
            self.link(a + ".then", b + ".execute")

    def me(self):
        return self.add("self")

    def get(self, var, **kw):
        return self.add("get", var=var, **kw)

    def setv(self, var, value=None, **kw):
        d = {"var": var}
        d.update(kw)
        if value is not None:
            d["pins"] = {var: value}
        return self.add("set", **d)

    def call(self, fn, **pins):
        for k, v in pins.items():
            if isinstance(v, (dict, list)) or (isinstance(v, str) and v.startswith("(")):
                raise ValueError("%s.%s: a pin default must be a plain string, number or bool (a vector is '1,1,1', an FKey the bare name): %r" % (fn, k, v))
        d = {"function": fn}
        if pins:
            d["pins"] = pins
        return self.add("call", **d)

    def branch(self):
        return self.add("branch")

    def event(self, name, params=None):
        d = {"name": name}
        if params:
            d["params"] = params
        return self.add("custom_event", **d)

    def call_me(self, name):
        """call a custom event of this Blueprint on self"""
        c = self.add("call", function=name)
        self.link(self.me() + ".self", c + ".self")
        return c

    def bind(self, exec_from, exec_pin, target_src, cls, member, handler):
        """AddDelegate on target_src ('node.pin') for cls.member, bound to the custom event handler"""
        dl = self.add("create_delegate", function=handler)
        node = self.add("node", **{"class": "K2Node_AddDelegate", "props": {"DelegateReference": "(MemberParent=Class'%s',MemberName=\"%s\")" % (cls, member)}})
        self.link(target_src, node + ".self")
        self.link(dl + ".OutputDelegate", node + ".delegate")
        self.link(exec_from + "." + exec_pin, node + ".execute")
        return node

    def valid(self, obj_src):
        v = self.call("KismetSystemLibrary:IsValid")
        self.link(obj_src, v + ".Object")
        return v

    def spec(self, asset, parent, variables, doc, once=False, requires=None):
        s = {"once": once, "_doc": doc, "asset": asset, "parent": parent, "components": [], "variables": variables,
             "cdo": {"PrimaryActorTick": "(bCanEverTick=False)"}, "nodes": self.nodes, "links": self.links}
        if requires:
            s["requires"] = requires
        return s


def write(path, spec):
    with open(path, "w") as f:
        json.dump(spec, f, indent=1)
    print("wrote", path, len(spec["nodes"]), "nodes")
