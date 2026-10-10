"""Full member diffs for the uniform buffers that material shaders bind, game exe vs our engine build.

    python ub_material_diff.py <game.json> <your build's json>...
    e.g. python ub_material_diff.py ../data/ub/game-2.7.2.json ue_Engine.json ue_Renderer.json ue_RenderCore.json ue_Landscape.json
    (your build's files come from ub_extract_exe.py --dump on UE4Editor-{Engine,Renderer,RenderCore,Landscape}.dll)

Each uniform buffer is identified by a member that only it has (ANCHORS). Nested structs (Shared, Forward, ...)
are listed separately. Prints game-only (+), fork-only (-) and changed (~) members, in game order.
"""
import json
import sys


# uniform buffer (shader name) -> a member unique to it; elements distinguish View from InstancedView
ANCHORS = {
    "View": ("TranslatedWorldToClip", None), "InstancedView": ("TranslatedWorldToClip", 2),
    "Primitive": ("LocalToWorld", None), "IndirectLightingCache": ("IndirectLightingCachePrimitiveAdd", None),
    "PrecomputedLightingBuffer": ("LightMapCoordinateScaleBias", None),
    "LightmapResourceCluster": ("LightMapTexture", None), "ReflectionCapture": ("PositionAndRadius", None),
    "OpaqueBasePass": ("UseForwardScreenSpaceShadowMask", None), "SharedBasePass": ("SSProfilesTexture", None),
    "TranslucentBasePass": ("SceneColorCopyTexture", None), "ForwardLightData": ("NumLocalLights", None),
    "ReflectionStruct": ("SkyLightCubemap", None), "PlanarReflectionStruct": ("ReflectionPlane", None),
    "FogStruct": ("ExponentialFogParameters", None), "SceneTexturesStruct": ("SceneDepthPackedSamplesTexture", None),
    "ShadowDepthPass": ("ProjectionMatrix", None), "TranslucentDepthPass": ("TranslucencyProjectionParameters", None),
    "DistortionPass": ("DistortionParams", None), "DecalPass": ("PreIntegratedGFTexture", None),
    "LightmapDensityPass": ("LightMapDensity", None), "LocalVF": ("VertexFetch_Parameters", None),
    "InstanceVF": ("VertexFetch_InstanceOriginBuffer", None),
    "LandscapeParameters": ("HeightmapUVScaleBias", None), "LandscapeFixedGrid": ("LodValues", None),
    "LandscapeContinuousLOD": ("Min", None),
}


def key(f):
    return (f["offset"], f["base_type"], f["rows"], f["cols"], f["elements"], f["precision"])


def find(chains, anchor, elements, exclude=()):
    best = None
    for c in chains:
        names = [f["name"] for f in c]
        if anchor in names and id(c) not in exclude:
            a = c[names.index(anchor)]
            if elements is not None and a["elements"] != elements:
                continue
            if elements is None and a["elements"] == 2 and anchor == "TranslatedWorldToClip":
                continue
            if best is None or len(c) > len(best):
                best = c
    return best


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    game = json.load(open(sys.argv[1]))
    fork = [c for p in sys.argv[2:] for c in json.load(open(p))]
    for ub, (anchor, el) in ANCHORS.items():
        g, f = find(game, anchor, el), find(fork, anchor, el)
        if not g or not f:
            print("\n== %s: %s" % (ub, "missing in game" if not g else "missing in fork")); continue
        gk = {m["name"]: key(m) for m in g}
        fk = {m["name"]: key(m) for m in f}
        lines = []
        for m in g:
            n = m["name"]
            if n not in fk:
                lines.append("  + %-44s %s" % (n, gk[n]))
            elif gk[n] != fk[n]:
                same_but_offset = gk[n][1:] == fk[n][1:]
                lines.append("  ~ %-44s game %s fork %s" % (n, gk[n][0] if same_but_offset else gk[n],
                                                          fk[n][0] if same_but_offset else fk[n]))
        for m in f:
            if m["name"] not in gk:
                lines.append("  - %-44s %s" % (m["name"], fk[m["name"]]))
        last_g, last_f = g[-1], f[-1]
        print("\n== %s: game %d members (last %s @%s), fork %d members%s" % (
            ub, len(g), last_g["name"], last_g["offset"], len(f), "  IDENTICAL" if not lines else ""))
        print("\n".join(lines))


if __name__ == "__main__":
    main()
