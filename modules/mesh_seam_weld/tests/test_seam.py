import unittest
from free_edge_path import closed_loop
from mesh_topology import adjacency,edges
from path_aligner import align,cost
from path_matcher import match
from path_validator import validate_ordered
from seam_planner import plan
from mesh_model import Component,Element,MeshModel

class SeamTests(unittest.TestCase):
    def coords(self):return {1:(0,0,0),2:(1,0,0),3:(2,0,0),4:(0,1,0),11:(0,0,1),12:(1,0,1),13:(2,0,1),14:(0,1,1)}
    def test_open_valid(self):self.assertEqual(validate_ordered([1,2,3],{1:{2},2:{1,3},3:{2}}),[1,2,3])
    def test_open_disconnected(self):
        with self.assertRaises(ValueError):validate_ordered([1,3],{1:{2},2:{1,3},3:{2}})
    def test_duplicate_path_node(self):
        with self.assertRaises(ValueError):validate_ordered([1,2,1],{1:{2},2:{1}})
    def test_closed_loop(self):self.assertEqual(closed_loop(1,{1:{2,4},2:{1,3},3:{2,4},4:{1,3}}),[1,2,3,4])
    def test_branched_loop_rejected(self):
        with self.assertRaises(ValueError):closed_loop(1,{1:{2,3,4}})
    def test_nearest_match(self):self.assertEqual(match([1,2,3],[13,11,12],self.coords()),[11,12,13])
    def test_not_enough_targets(self):
        with self.assertRaises(ValueError):match([1,2,3],[11,12],self.coords())
    def test_open_reverse_alignment(self):self.assertEqual(align([1,2,3],[13,12,11],self.coords()),[11,12,13])
    def test_closed_rotation_alignment(self):self.assertEqual(align([1,2,3,4],[13,14,11,12],self.coords(),True),[11,12,13,14])
    def test_open_plan_segments(self):self.assertEqual(len(plan([1,2,3],[11,12,13],False)),2)
    def test_closed_plan_segments(self):self.assertEqual(len(plan([1,2,3,4],[11,12,13,14],True)),4)
    def test_degenerate_element_rejected(self):
        with self.assertRaises(ValueError):plan([1,2],[1,12],False)
    def test_free_edges_from_shell(self):
        m=MeshModel({1:Component(1,"S","SHELL")},self.coords(),{1:Element(1,1,"CQUAD4",(1,2,3,4))}); self.assertEqual(len([k for k,v in edges(m.elements.values()).items() if len(v)==1]),4)
if __name__=="__main__":unittest.main()
