from hybrid_schema import SchemaError
def validate(path,model):
    missing=set(path)-set(model.nodes.keys())
    if missing:raise SchemaError("path references missing nodes {}".format(sorted(missing)))
