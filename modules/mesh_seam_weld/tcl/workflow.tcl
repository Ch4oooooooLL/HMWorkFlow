proc ::MeshSeamWeld::processWeldPath {sourceNodes targetComps closedLoop {progressOpened 0} {pathIndex 1} {pathTotal 1}} {
    return [::MeshSeamWeld::processWeldPathPython \
        $sourceNodes $targetComps $closedLoop $progressOpened $pathIndex $pathTotal]
}
