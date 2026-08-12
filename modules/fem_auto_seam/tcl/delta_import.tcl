proc ::FemAutoSeam::saveAutoSnapshot {path} {
    file mkdir [file dirname $path]
    if {[file exists $path]} { file delete -force $path }
    catch {hm_answernext yes}
    if {[catch {uplevel #0 [list *writefile [file nativename $path] 1]} err opts]} { return -options $opts $err }
    if {![file isfile $path] || [file size $path] == 0} { error "HyperMesh did not create a valid auto-seam snapshot" }
    return $path
}

proc ::FemAutoSeam::restoreAutoSnapshot {path} {
    if {![file isfile $path]} { error "auto-seam recovery snapshot is missing: $path" }
    catch {hm_answernext yes}
    uplevel #0 [list *readfile [file nativename $path] 0]
    catch {::HWFlow::refreshBrowser}
}

proc ::FemAutoSeam::openAutoResultModel {resultFem} {
    if {![file isfile $resultFem] || [file size $resultFem] == 0} {
        error "modified result FEM is missing or empty: $resultFem"
    }
    # File > Open semantics for a solver deck require an empty model followed
    # by the OptiStruct reader.  *readfile only accepts a HyperMesh database
    # and reports a valid .fem as "not a HyperMesh database" in HM2019.
    # The task-level before.hm backup created by the caller remains the single
    # rollback point; clearing first prevents any import/merge behavior.
    catch {hm_answernext yes}
    *deletemodel
    ::HWFlow::runHyperMeshIo import [list *feinputwithdata2 "#optistruct/optistruct" [file nativename $resultFem] 0 0 0 0 0 1 2 1 0]
    catch {::HWFlow::refreshBrowser}
    return $resultFem
}

proc ::FemAutoSeam::validateAutoModelContents {plans} {
    set verified 0
    foreach plan $plans {
        if {[dict get $plan status] ne "READY"} { continue }
        # OptiStruct has no native component field on shell cards. HM2019 may
        # initially collect newly imported seam shells by their reused source
        # PID even though the FEM contains $HMCOMP markers. Reapply the plan's
        # explicit ownership before verification and remeshing.
        set weldIds {}
        foreach element [dict get $plan weld_elements] { lappend weldIds [dict get $element element_id] }
        if {[llength $weldIds]} {
            set outputComponentId [dict get $plan output_component_id]
            set outputComponentName [::HybridCore::componentName $outputComponentId]
            if {$outputComponentName eq ""} {
                error "opened result FEM is missing output component $outputComponentId for candidate=[dict get $plan candidate_id]"
            }
            ::HybridCore::moveIdsToComponent {elems elements} $weldIds $outputComponentName
        }
        set expected {}
        foreach element [concat [dict get $plan replacement_elements] [dict get $plan weld_elements]] { lappend expected [dict get $element element_id] }
        set missingNodes {}
        foreach node [dict get $plan new_nodes] {
            set nodeId [dict get $node node_id]
            if {[llength [::HybridCore::existingEntityIds {nodes} [list $nodeId]]] == 0} {
                lappend missingNodes $nodeId
                continue
            }
            if {![::HybridCore::coordinatesMatch [::HybridCore::nodeCoordinates $nodeId] [dict get $node coordinates] 1.0e-7]} {
                error "opened model GRID $nodeId coordinates mismatch: candidate=[dict get $plan candidate_id]"
            }
        }
        set missing {}
        foreach element [concat [dict get $plan replacement_elements] [dict get $plan weld_elements]] {
            set elementId [dict get $element element_id]
            if {[llength [::HybridCore::existingEntityIds {elems elements} [list $elementId]]] == 0} {
                lappend missing $elementId
                continue
            }
            set actual [lsort -integer [::FemAutoSeam::elemNodes $elementId]]
            if {$actual ne [lsort -integer [dict get $element node_ids]]} {
                error "opened model shell $elementId connectivity mismatch: candidate=[dict get $plan candidate_id]"
            }
            set actualComponent [::FemAutoSeam::autoElementComponentId $elementId]
            if {$actualComponent ne "" && $actualComponent != [dict get $element component_id]} {
                error "opened model shell $elementId component mismatch: candidate=[dict get $plan candidate_id]"
            }
        }
        # Mother shells were removed by the offline planner.  Their absence is
        # what proves the model was replaced rather than merged.
        set staleMothers {}
        foreach elementId [dict get $plan delete_element_ids] {
            if {[llength [::HybridCore::existingEntityIds {elems elements} [list $elementId]]]} {
                lappend staleMothers $elementId
            }
        }
        if {[llength $missingNodes] || [llength $missing]} {
            error "opened result FEM is incomplete: candidate=[dict get $plan candidate_id] missing_grids={$missingNodes} missing_elements={$missing}"
        }
        if {[llength $staleMothers]} {
            error "opened result FEM still contains replaced mother shells: candidate=[dict get $plan candidate_id] elements={$staleMothers}"
        }
        incr verified [llength $expected]
    }
    return $verified
}

