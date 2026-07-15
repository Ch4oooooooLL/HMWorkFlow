from __future__ import annotations

def detect(center, points, settings):
    ranges=[max(p[i] for p in points)-min(p[i] for p in points) for i in range(3)]
    order=sorted(range(3),key=lambda i:ranges[i]); minimum,maximum=ranges[order[0]],ranges[order[-1]]
    planar=maximum>0 and (minimum<=settings["planeAbsTol"] or minimum/maximum<=settings["planeFlatRatio"])
    return planar, ("XYZ"[order[0]] if planar else ""), ranges
