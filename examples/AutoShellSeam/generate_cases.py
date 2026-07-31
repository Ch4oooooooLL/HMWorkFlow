"""Generate small, deterministic OptiStruct decks for auto-seam smoke tests."""
from pathlib import Path


def write_simple_t(path):
    lines=["$ AutoShellSeam Case 1: T path with existing target edge","BEGIN BULK"]
    nodes={1:(0,-1,0),2:(1,-1,0),3:(2,-1,0),4:(0,0,0),5:(1,0,0),6:(2,0,0),7:(0,1,0),8:(1,1,0),9:(2,1,0),11:(0,0,.2),12:(1,0,.2),13:(2,0,.2),14:(0,0,1.2),15:(1,0,1.2),16:(2,0,1.2)}
    for node_id,xyz in sorted(nodes.items()): lines.append("GRID,{},,{},{},{}".format(node_id,*xyz))
    for element_id,pid,node_ids in ((1,101,(1,2,5,4)),(2,101,(2,3,6,5)),(3,101,(4,5,8,7)),(4,101,(5,6,9,8)),(11,102,(11,12,15,14)),(12,102,(12,13,16,15))): lines.append("CQUAD4,{},{},{}".format(element_id,pid,",".join(str(value) for value in node_ids)))
    lines.extend(("PSHELL,101,1,8.0","PSHELL,102,1,6.0","MAT1,1,210000,,0.3","ENDDATA","")); Path(path).write_text("\n".join(lines),encoding="utf-8")


def write_adjusted_t(path):
    """Case 2: target edge exists but is offset enough to require V2 movement."""
    lines=["$ AutoShellSeam Case 2: guarded adjusted target edge","BEGIN BULK"]
    nodes={1:(0,-1,0),2:(1,-1,0),3:(2,-1,0),4:(0,.2,0),5:(1,.2,0),6:(2,.2,0),7:(0,1,0),8:(1,1,0),9:(2,1,0),11:(0,0,.2),12:(1,0,.2),13:(2,0,.2),14:(0,0,1.2),15:(1,0,1.2),16:(2,0,1.2)}
    for node_id,xyz in sorted(nodes.items()): lines.append("GRID,{},,{},{},{}".format(node_id,*xyz))
    for element_id,pid,node_ids in ((1,101,(1,2,5,4)),(2,101,(2,3,6,5)),(3,101,(4,5,8,7)),(4,101,(5,6,9,8)),(11,102,(11,12,15,14)),(12,102,(12,13,16,15))): lines.append("CQUAD4,{},{},{}".format(element_id,pid,",".join(str(value) for value in node_ids)))
    lines.extend(("PSHELL,101,1,8.0","PSHELL,102,1,6.0","MAT1,1,210000,,0.3","ENDDATA","")); Path(path).write_text("\n".join(lines),encoding="utf-8")


def write_local_split_t(path):
    """Case 3: one target quad crossed by a projected three-node source path."""
    lines=["$ AutoShellSeam Case 3: conservative single-shell local split","BEGIN BULK"]
    nodes={1:(0,0,0),2:(2,0,0),3:(2,1,0),4:(0,1,0),11:(0,.5,.2),12:(1,.5,.2),13:(2,.5,.2),14:(0,.5,1.2),15:(1,.5,1.2),16:(2,.5,1.2)}
    for node_id,xyz in sorted(nodes.items()): lines.append("GRID,{},,{},{},{}".format(node_id,*xyz))
    for element_id,pid,node_ids in ((1,101,(1,2,3,4)),(11,102,(11,12,15,14)),(12,102,(12,13,16,15))): lines.append("CQUAD4,{},{},{}".format(element_id,pid,",".join(str(value) for value in node_ids)))
    lines.extend(("PSHELL,101,1,8.0","PSHELL,102,1,6.0","MAT1,1,210000,,0.3","ENDDATA","")); Path(path).write_text("\n".join(lines),encoding="utf-8")


if __name__=="__main__":
    root=Path(__file__).resolve().parent
    outputs=[root/"case_01_simple_t.fem",root/"case_02_adjusted_t.fem",root/"case_03_local_split_t.fem"]
    for writer,output in zip((write_simple_t,write_adjusted_t,write_local_split_t),outputs): writer(output); print(output)
