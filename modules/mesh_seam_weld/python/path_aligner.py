from __future__ import annotations
def cost(source,target,coords):return sum(sum((coords[a][i]-coords[b][i])**2 for i in range(3)) for a,b in zip(source,target))
def rotate(items,n):return items[n:]+items[:n]
def align_with_metadata(source,target,coords,closed=False):
    if len(source)!=len(target):raise ValueError("source and target path counts differ")
    if not closed:
        reversed_path=list(reversed(target)); use_reverse=cost(source,reversed_path,coords)<cost(source,target,coords); path=reversed_path if use_reverse else list(target)
        return path,use_reverse,0,cost(source,path,coords)
    options=[]
    for rev,base in ((False,list(target)),(True,list(reversed(target)))):
        for i in range(len(base)):options.append((rotate(base,i),rev,i))
    path,rev,offset=min(options,key=lambda row:(cost(source,row[0],coords),row[0])); return path,rev,offset,cost(source,path,coords)
def align(source,target,coords,closed=False):return align_with_metadata(source,target,coords,closed)[0]
