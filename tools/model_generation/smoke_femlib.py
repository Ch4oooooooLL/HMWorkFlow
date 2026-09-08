"""Smoke test for femlib: build a washer hole cell + hexa block with holes."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import femlib as F

m = F.Model("smoke")
mat = m.add_material("STEEL")
pshell = m.add_property("PSHELL", "P1_PSHELL", mat.mid, thickness=1.5)
psolid = m.add_property("PSOLID", "S1_PSOLID", mat.mid)
c1 = m.add_component("V01_PLATE_T1.5", 3, pshell)
c2 = m.add_component("V02_BLOCK_T10", 4, psolid)

# shell washer cell
hole = F.washer_hole_cell(m, c1, (60.0, 60.0, 0.0), 12.0, 10, (4.0, 6.0))
print("washer cell elems:", len(c1.element_ids))

# hexa block with 2 holes
F.hex_block_with_holes(m, c2, (0.0, 0.0, 0.0), 360.0, 120.0, 30.0,
                       holes=[(60.0, 60.0, 6.0, 12), (180.0, 60.0, 6.0, 12), (300.0, 60.0, 6.0, 12)],
                       nz=6)
print("block elems:", len(c2.element_ids))
stats = m.stats()
print(stats)

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_smoke_out", "smoke.fem")
m.write_fem(out)
print("wrote", out, os.path.getsize(out), "bytes")

# verify: free edge loops on the plate (1 outer + 1 hole)
loops = F.free_edge_loops(m, c1)
print("plate free-edge loops:", len(loops))
assert len(loops) == 2, loops

# quality sanity: hexa count and no degenerate shells
q = F.mesh_quality_stats(m, c1)
print("plate quality:", q)
assert q["degenerate"] == 0

# verify written file
info = F.verify_fem_file(out)
print("written counts:", info["counts"])
assert info["counts"]["GRID"] == stats["node_count"]
assert info["counts"]["CQUAD4"] == stats["element_cards"]["CQUAD4"]
assert info["counts"]["CHEXA"] == stats["element_cards"]["CHEXA"]
print("SMOKE OK")
