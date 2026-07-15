from __future__ import annotations
import math

def median(values):
    values=sorted(values); n=len(values); return values[n//2] if n%2 else (values[n//2-1]+values[n//2])/2.0

def even_floor(value): return max(0,int(math.floor(value/2.0))*2)

def estimate(distances, settings):
    values=sorted(d for d in distances if d>settings["minBeamLength"])
    if not values:return 0
    r0=values[0]; tol=max(settings["radialAbsTol"],settings["radialRelTol"]*r0)
    return even_floor(2.0*median([d for d in values if d<=r0+tol]))

def choose(records):
    values=[r["diameter"] for r in records if r["diameter"]>0 and r["planar"]] or [r["diameter"] for r in records if r["diameter"]>0]
    if not values:return 0
    counts={v:values.count(v) for v in set(values)}
    return sorted(counts,key=lambda v:(-counts[v],v))[0]
