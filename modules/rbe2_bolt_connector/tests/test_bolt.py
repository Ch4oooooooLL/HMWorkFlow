import importlib.util,math,unittest
from pathlib import Path
from hmworkflow.core.mesh_model import Component,Element,MeshModel
from hmworkflow.rbe2_bolt_connector.rbe2_analyzer import analyze
from hmworkflow.rbe2_bolt_connector.grouping import build
from hmworkflow.rbe2_bolt_connector.pair_planner import plan
from hmworkflow.rbe2_bolt_connector.duplicate_detector import annotate
SPEC=importlib.util.spec_from_file_location("bolt_test_schema",str(Path(__file__).resolve().parents[1]/"python"/"schema.py")); M=importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(M)

def model(centers,axis="Z",spatial=False):
    nodes={}; elems={}; nid=1
    for eid,c in enumerate(centers,1):
        inode=nid; nodes[inode]=c; nid+=1; deps=[]
        for i in range(8):
            a=2*math.pi*i/8
            if axis=="Z":p=(c[0]+5*math.cos(a),c[1]+5*math.sin(a),c[2]+((i%2)*2 if spatial else 0))
            elif axis=="X":p=(c[0]+((i%2)*2 if spatial else 0),c[1]+5*math.cos(a),c[2]+5*math.sin(a))
            else:p=(c[0]+5*math.cos(a),c[1]+((i%2)*2 if spatial else 0),c[2]+5*math.sin(a))
            nodes[nid]=p; deps.append(nid); nid+=1
        elems[eid]=Element(eid,1,"RBE2",tuple([inode]+deps))
    return MeshModel({1:Component(1,"RBE2","RIGID")},nodes,elems)

class BoltTests(unittest.TestCase):
    def settings(self,**kw):d=dict(M.DEFAULTS); d.update(kw); return d
    def pipeline(self,m,s=None):
        s=s or self.settings(); records,_=analyze(m,s); groups=build(records,s); pairs,rejected=plan(groups,s); return records,groups,pairs,rejected
    def test_two_planar_z(self):self.assertEqual(len(self.pipeline(model([(0,0,0),(0,0,20)]))[2]),1)
    def test_three_centers_adjacent_only(self):self.assertEqual([(p["node_1"],p["node_2"]) for p in self.pipeline(model([(0,0,0),(0,0,20),(0,0,40)]))[2]],[(1,10),(10,19)])
    def test_offset_outside_tolerance(self):self.assertEqual(self.pipeline(model([(0,0,0),(6,0,20)]))[2],[])
    def test_gap_outside_tolerance(self):self.assertEqual(self.pipeline(model([(0,0,0),(0,0,120)]))[2],[])
    def test_wrong_forced_axis(self):self.assertEqual(self.pipeline(model([(0,0,0),(0,0,20)]),self.settings(axisMode="X"))[2],[])
    def test_x_axis_planar(self):self.assertEqual(self.pipeline(model([(0,0,0),(20,0,0)],"X"))[2][0]["axis"],"X")
    def test_y_axis_planar(self):self.assertEqual(self.pipeline(model([(0,0,0),(0,20,0)],"Y"))[2][0]["axis"],"Y")
    def test_spatial_only_skipped(self):self.assertEqual(self.pipeline(model([(0,0,0),(0,0,20)],spatial=True))[2],[])
    def test_diameter_even_floor(self):self.assertEqual(self.pipeline(model([(0,0,0),(0,0,20)]))[2][0]["diameter"],10)
    def test_duplicate_segment(self):
        p=self.pipeline(model([(0,0,0),(0,0,20)]))[2]; annotate(p,{(1,10):99}); self.assertEqual(p[0]["recommended_action"],"SKIP_EXISTING")
    def test_near_offset_connects(self):self.assertEqual(len(self.pipeline(model([(0,0,0),(4.9,4.9,20)]))[2]),1)
    def test_too_few_dependents_rejected(self):
        m=MeshModel({1:Component(1,"R","RIGID")},{1:(0,0,0),2:(1,0,0)},{1:Element(1,1,"RBE2",(1,2))}); self.assertEqual(analyze(m,self.settings())[0],[])
    def test_coincident_centers_do_not_pair(self):self.assertEqual(self.pipeline(model([(0,0,0),(0,0,0)]))[2],[])
    def test_different_diameters_use_group_mode(self):
        m=model([(0,0,0),(0,0,20)])
        for nid in range(11,19):
            x,y,z=m.nodes[nid]; m.nodes[nid]=(x*1.4,y*1.4,z)
        self.assertEqual(self.pipeline(m)[2][0]["recommended_diameter"],10)

if __name__=="__main__":unittest.main()
