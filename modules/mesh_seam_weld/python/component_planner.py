"""Plan component-level seam welds without HyperMesh/Tcl topology traversal."""
from __future__ import annotations

from collections import Counter, defaultdict, deque


def _centroid(node_ids, coordinates):
    count = float(len(node_ids))
    return tuple(sum(coordinates[node_id][axis] for node_id in node_ids) / count for axis in range(3))


class _KdNode:
    __slots__ = ("point", "element_id", "component_id", "axis", "left", "right")

    def __init__(self, row, axis, left, right):
        self.point, self.element_id, self.component_id = row
        self.axis, self.left, self.right = axis, left, right


def _build_kd(rows, depth=0):
    if not rows:
        return None
    axis = depth % 3
    rows.sort(key=lambda row: (row[0][axis], row[1]))
    middle = len(rows) // 2
    return _KdNode(
        rows[middle], axis,
        _build_kd(rows[:middle], depth + 1),
        _build_kd(rows[middle + 1 :], depth + 1),
    )


def _nearest(root, point, allowed_component=None):
    best = [None, float("inf")]

    def visit(node):
        if node is None:
            return
        distance = sum((point[index] - node.point[index]) ** 2 for index in range(3))
        if (allowed_component is None or node.component_id == allowed_component) and distance < best[1]:
            best[:] = [node, distance]
        delta = point[node.axis] - node.point[node.axis]
        first, second = (node.left, node.right) if delta <= 0 else (node.right, node.left)
        visit(first)
        if delta * delta < best[1] or best[0] is None:
            visit(second)

    visit(root)
    if best[0] is None:
        raise ValueError("no target shell element is available for projection")
    return best[0], best[1]


def _closed_free_edge_loops(elements):
    owners = defaultdict(int)
    ends = {}
    for element in elements:
        node_ids = element.node_ids
        if len(node_ids) < 3:
            continue
        for first, second in zip(node_ids, node_ids[1:] + node_ids[:1]):
            key = tuple(sorted((first, second)))
            owners[key] += 1
            ends[key] = (first, second)
    graph = defaultdict(set)
    for key, owner_count in owners.items():
        if owner_count == 1:
            first, second = ends[key]
            graph[first].add(second)
            graph[second].add(first)

    loops = []
    visited = set()
    for seed in sorted(graph):
        if seed in visited:
            continue
        region = []
        queue = deque([seed])
        while queue:
            node_id = queue.popleft()
            if node_id in visited:
                continue
            visited.add(node_id)
            region.append(node_id)
            queue.extend(graph[node_id] - visited)
        if len(region) < 3 or any(len(graph[node_id]) != 2 for node_id in region):
            continue
        start = min(region)
        path = [start]
        previous = None
        current = start
        while True:
            choices = sorted(node_id for node_id in graph[current] if node_id != previous)
            next_node = choices[0]
            if next_node == start:
                break
            if next_node in path:
                path = []
                break
            path.append(next_node)
            previous, current = current, next_node
        if len(path) >= 3:
            loops.append(path)
    return loops


def _connected_elements_at_node(elements, selected_node_id):
    """Return the shell island containing the selected node."""
    by_id = {element.element_id: element for element in elements}
    node_to_elements = defaultdict(set)
    for element in elements:
        for node_id in element.node_ids:
            node_to_elements[node_id].add(element.element_id)
    seeds = set(node_to_elements.get(selected_node_id, ()))
    if not seeds:
        raise ValueError("selected internal node is not present in the exported shell component")
    visited = set()
    queue = deque(sorted(seeds))
    while queue:
        element_id = queue.popleft()
        if element_id in visited:
            continue
        visited.add(element_id)
        for node_id in by_id[element_id].node_ids:
            queue.extend(node_to_elements[node_id] - visited)
    return [by_id[element_id] for element_id in sorted(visited)]


def plan_internal_component_boundaries(model, source_component_id, selected_node_id):
    """Find every closed free boundary on the selected node's shell island."""
    source_component_id = int(source_component_id)
    selected_node_id = int(selected_node_id)
    component_elements = [
        element for element in model.elements.values()
        if element.component_id == source_component_id and len(element.node_ids) in (3, 4)
    ]
    if not component_elements:
        raise ValueError("exported source component contains no shell elements")
    region_elements = _connected_elements_at_node(component_elements, selected_node_id)
    loops = _closed_free_edge_loops(region_elements)
    if not loops:
        raise ValueError("selected node's shell region contains no closed free-edge boundaries")
    return [{
        "plan_id": "I{:06d}".format(index),
        "source_node_ids": loop,
        "source_component_ids": [source_component_id],
        "center": list(_centroid(loop, model.nodes)),
        "closed_loop": True,
        "projection_mode": "TCL_LOCAL_TARGET",
    } for index, loop in enumerate(loops, 1)]


def _expanded_patch(seed_elements, component_id, layers, elements, node_to_elements):
    visited = set(seed_elements)
    frontier = set(seed_elements)
    for _ in range(max(0, int(layers)) + 3):
        following = set()
        for element_id in frontier:
            for node_id in elements[element_id].node_ids:
                following.update(
                    candidate for candidate in node_to_elements[node_id]
                    if elements[candidate].component_id == component_id and candidate not in visited
                )
        visited.update(following)
        frontier = following
        if not frontier:
            break
    return sorted(visited)


def _target_search(model, target_component_ids):
    target_ids = sorted(set(int(value) for value in target_component_ids))
    if not target_ids:
        raise ValueError("target component selection must not be empty")
    node_to_target_elements = defaultdict(set)
    kd_rows = []
    for element in model.elements.values():
        if element.component_id not in target_ids or len(element.node_ids) not in (3, 4):
            continue
        kd_rows.append((_centroid(element.node_ids, model.nodes), element.element_id, element.component_id))
        for node_id in element.node_ids:
            node_to_target_elements[node_id].add(element.element_id)
    if not kd_rows:
        raise ValueError("selected target components contain no shell elements")
    return target_ids, _build_kd(kd_rows), node_to_target_elements


def _target_patch_for_path(source_nodes, model, target_ids, tree, node_to_target_elements, layers):
    nearest_rows = [_nearest(tree, model.nodes[node_id]) for node_id in source_nodes]
    component_votes = Counter(row[0].component_id for row in nearest_rows)
    target_component_id = min(
        component_votes,
        key=lambda component_id: (-component_votes[component_id], sum(
            distance for node, distance in nearest_rows if node.component_id == component_id
        ), component_id),
    )
    if target_component_id not in target_ids:
        raise ValueError("nearest target component is outside the selected target set")
    target_seeds = {
        _nearest(tree, model.nodes[node_id], target_component_id)[0].element_id
        for node_id in source_nodes
    }
    target_patch = _expanded_patch(
        target_seeds, target_component_id, layers,
        model.elements, node_to_target_elements,
    )
    return target_component_id, target_patch


def plan_internal_component_welds(
    model, source_component_id, selected_node_id, target_component_ids, patch_expand_layers
):
    """Return ordered source loops and Python-planned local target patches."""
    plans = plan_internal_component_boundaries(model, source_component_id, selected_node_id)
    target_ids, tree, node_to_target_elements = _target_search(model, target_component_ids)
    for plan in plans:
        target_component_id, target_patch = _target_patch_for_path(
            plan["source_node_ids"], model, target_ids, tree,
            node_to_target_elements, patch_expand_layers,
        )
        plan["target_component_ids"] = [target_component_id]
        plan["target_element_ids"] = target_patch
        plan["projection_mode"] = "LOCAL_ELEMENTS"
    return plans


def plan_component_welds(model, source_component_ids, target_component_ids, weld_mesh_size, patch_expand_layers, selected_node_ids=None):
    del weld_mesh_size  # Reserved for distance filtering without changing the wire protocol.
    source_ids = sorted(set(int(value) for value in source_component_ids))
    target_ids = sorted(set(int(value) for value in target_component_ids))
    selected_nodes = set(int(value) for value in (selected_node_ids or []))
    if not source_ids or not target_ids:
        raise ValueError("source and target component selections must not be empty")
    if set(source_ids) & set(target_ids):
        raise ValueError("source and target components must be different")

    source_elements = defaultdict(list)
    for element in model.elements.values():
        if element.component_id in source_ids:
            source_elements[element.component_id].append(element)
    target_ids, tree, node_to_target_elements = _target_search(model, target_ids)

    plans = []
    for source_component_id in source_ids:
        component_elements = source_elements[source_component_id]
        component_nodes = {node_id for element in component_elements for node_id in element.node_ids}
        component_seeds = selected_nodes & component_nodes
        component_loops = _closed_free_edge_loops(component_elements)
        if component_seeds:
            matched_loops = [loop for loop in component_loops if component_seeds & set(loop)]
            seeds_on_loops = {seed for loop in matched_loops for seed in component_seeds if seed in loop}
            if seeds_on_loops == component_seeds:
                component_loops = matched_loops
        for source_nodes in component_loops:
            target_component_id, target_patch = _target_patch_for_path(
                source_nodes, model, target_ids, tree,
                node_to_target_elements, patch_expand_layers,
            )
            plans.append({
                "plan_id": "W{:06d}".format(len(plans) + 1),
                "source_node_ids": source_nodes,
                "source_component_ids": [source_component_id],
                "target_component_ids": [target_component_id],
                "target_element_ids": target_patch,
                "closed_loop": True,
                "projection_mode": "LOCAL_ELEMENTS",
            })
    if not plans:
        raise ValueError("selected source components contain no closed free-edge loops")
    return plans
