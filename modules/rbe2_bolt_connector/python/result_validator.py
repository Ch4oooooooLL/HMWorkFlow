try:
    from hmworkflow.core.hybrid_schema import SchemaError
except ImportError:  # Standalone HM2019 entry compatibility.
    from hybrid_schema import SchemaError
def validate(plans,model):
    for p in plans:
        if p["node_1"] not in model.nodes or p["node_2"] not in model.nodes: raise SchemaError("pair references missing node")
        if p["node_1"]==p["node_2"]: raise SchemaError("zero length node pair")
