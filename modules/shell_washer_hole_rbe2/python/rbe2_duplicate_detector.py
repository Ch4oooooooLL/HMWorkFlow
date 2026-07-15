def annotate(candidate, existing_index):
    value = existing_index.get(tuple(candidate["dependent_node_ids"]))
    candidate["existing_rbe2_id"] = value
    candidate["recommended_action"] = "SKIP_EXISTING" if value is not None else "CREATE"
    return candidate


def index(existing):
    return {tuple(row["dependent_node_ids"]): row["element_id"] for row in existing}


def duplicate_groups(rows):
    by_key = {}
    for row in rows:
        dep_key = tuple(sorted(int(v) for v in row.get("dependent_node_ids", [])))
        by_key.setdefault(dep_key, []).append(int(row["element_id"]))
    result = []
    for dep_key, element_ids in sorted(by_key.items()):
        element_ids = sorted(element_ids)
        if len(element_ids) > 1:
            result.append({"dependent_node_key": ",".join(str(v) for v in dep_key), "keep_element_id": element_ids[0], "delete_element_ids": element_ids[1:], "reason": "SAME_DEPENDENT_NODE_SET"})
    return result
