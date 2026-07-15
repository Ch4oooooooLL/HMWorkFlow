from hybrid_schema import SchemaError


def validate(candidates, model):
    seen = set()
    known_nodes = set(model.nodes)
    for row in candidates:
        if row["candidate_id"] in seen: raise SchemaError("duplicate candidate_id")
        seen.add(row["candidate_id"])
        missing = set(row["dependent_node_ids"]) - known_nodes
        if missing: raise SchemaError("candidate references missing nodes {}".format(sorted(missing)))
