proc ::FemAutoSeam::autoNativeQualityFailures {elementIds} {
    if {![llength $elementIds]} { return {} }
    if {[llength [info commands hm_getelementsqualityinfo]] == 0} { error "HyperMesh native quality command is unavailable" }
    catch {*clearmark elems 1}; catch {*clearmark elems 2}; eval *createmark elems 1 $elementIds
    if {[catch {hm_getelementsqualityinfo 1 1 2} qualityErr]} { error "HyperMesh native quality check failed: $qualityErr" }
    set failed {}; catch {set failed [hm_getmark elems 2]}; return [lsort -integer -unique $failed]
}

