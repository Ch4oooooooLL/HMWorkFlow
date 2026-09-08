proc ::MeshSeamWeld::processWeldPath {sourceNodes targetComps closedLoop {progressOpened 0} {pathIndex 1} {pathTotal 1} {sourceCompIds {}} {seamComp ""} {targetElemIds {}} {imprintClosedLoop ""}} {
    return [::MeshSeamWeld::processWeldPathNativePatch \
        $sourceNodes $targetComps $closedLoop $progressOpened $pathIndex $pathTotal $sourceCompIds $seamComp $targetElemIds $imprintClosedLoop]
}
