try:
    from hmworkflow.core.hybrid_schema import SchemaError
except ImportError:  # Standalone HM2019 entry compatibility.
    from hybrid_schema import SchemaError
def validate(path,model):
    missing=set(path)-set(model.nodes.keys())
    if missing:raise SchemaError("path references missing nodes {}".format(sorted(missing)))
