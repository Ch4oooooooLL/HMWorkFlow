proc ::MeshSeamWeld::processWeldPath {sourceNodes targetComps closedLoop {progressOpened 0} {pathIndex 1} {pathTotal 1} {sourceCompIds {}} {seamComp ""} {targetElemIds {}} {imprintClosedLoop ""}} {
    # Manual and automatic T/PATCH creation share the proven native Create
    # Patch implementation.  Recognition only supplies source nodes and the
    # target scope; it must not select a different mesh-creation mechanism.
    return [::MeshSeamWeld::processWeldPathNativePatch \
        $sourceNodes $targetComps $closedLoop $progressOpened $pathIndex $pathTotal $sourceCompIds $seamComp $targetElemIds $imprintClosedLoop]
}
