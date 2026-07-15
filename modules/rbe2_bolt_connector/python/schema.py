from __future__ import annotations
from hybrid_schema import SchemaError, validate_request as validate_common

DEFAULTS={"axisMode":"AUTO","gapTol":100.0,"offsetTol":5.0,"minGroupSize":2,"minBeamLength":0.001,"planeAbsTol":0.5,"planeFlatRatio":0.12,"radialAbsTol":0.5,"radialRelTol":0.08,"elemType":"CBEAM","compPrefix":"BOLT","propName":"","dryRun":False}

def validate_request(data):
    data=validate_common(data,"rbe2_bolt_connector"); settings=dict(DEFAULTS); settings.update(data["settings"])
    settings["axisMode"]=str(settings["axisMode"]).upper()
    if settings["axisMode"] not in ("AUTO","X","Y","Z"): raise SchemaError("axisMode must be AUTO/X/Y/Z")
    for key in ("gapTol","offsetTol","minBeamLength","planeAbsTol","planeFlatRatio","radialAbsTol","radialRelTol"): settings[key]=float(settings[key])
    settings["minGroupSize"]=int(settings["minGroupSize"]); settings["dryRun"]=bool(settings["dryRun"])
    if settings["gapTol"] <= settings["minBeamLength"] or settings["offsetTol"] <= 0: raise SchemaError("invalid grouping tolerances")
    data["settings"]=settings; return data

def validate_existing(data):
    rows=data.get("beam_segments",[]) if isinstance(data,dict) else []
    return {tuple(sorted((int(r["node_1"]),int(r["node_2"])))):int(r.get("element_id",0)) for r in rows}
