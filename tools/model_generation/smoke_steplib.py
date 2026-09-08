"""Smoke test for steplib: solids, shells, naming, readback."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import steplib as S

outdir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_smoke_out")
os.makedirs(outdir, exist_ok=True)

parts = [
    ("V01_PLATE_T1.5", S.flat_plate(200, 120, 1.5, holes=[(-60, -30, 10), (0, 0, 12), (60, 30, 8)])),
    ("V02_LBRACKET_T2.0", S.l_bracket(150, 100, 80, 2.0, holes=[(-30, 20, 8), (30, 20, 8)])),
    ("V03_CHANNEL_T1.0", S.channel(120, 60, 200, 1.0, holes=[(0, 15, 10)])),
    ("V04_HATRIB_T1.2", S.hat_rib(250, 40, 80, 25, 1.2, holes=[(0, 12, 8)])),
    ("V05_ARC_T1.0", S.arc_bracket(100, 120, 60, 1.0, holes=[(90, 8), (120, 8)])),
    ("V06_RIBPLATE_T1.5", S.panel_with_ribs(300, 200, 1.5, 12, 6, 5, holes=[(-100, 0, 10), (100, 0, 10)])),
    ("V07_STEP_T1.0", S.stepped_bracket([(80, 30, 3), (60, 10, 3), (40, 10, 2)], 60, 1.0)),
    ("V08_FLANGE_T2.0", S.plate_with_flanges(180, 120, 2.0, 30, holes=[(30, 90, 10), (90, 90, 10)],
                                             flange_holes=[(60, 16, 6), (120, 16, 6)])),
    ("V09_POCKET_T5", S.pocket_plate(200, 150, 5.0,
                                     pockets=[(-50, -30, 8, 16, 1.5), (0, 0, 10, 20, 2.0), (50, 30, 6, 12, 1.0)])),
    ("V10_CHAMFER_T8", S.chamfer_block(120, 90, 8.0, fillets=[("|Z", 2.0)], chamfers=[("|Z", 1.5)],
                                       holes=[(0, 0, 10)])),
    ("S01_SEAM_SHELL", S.shell_rect(300, 100, holes=[(0, 0, 12), (80, 0, 8)])),
    ("S02_SEAM_POLY", S.shell_poly([(0, 0), (200, 0), (200, 60), (140, 60), (140, 30), (0, 30)])),
]

for name, part in parts:
    path = os.path.join(outdir, name + ".step")
    S.export_step(part, path, name)
    info = S.verify_step(path)
    print(name, info)

# verify product-name injection
txt = open(os.path.join(outdir, "V01_PLATE_T1.5.step"), encoding="latin-1").read()
assert "PRODUCT('V01_PLATE_T1.5'" in txt, "product name not injected"
print("SMOKE OK")
