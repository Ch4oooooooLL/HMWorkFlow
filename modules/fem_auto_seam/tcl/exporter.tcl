proc ::FemAutoSeam::optistructExportTemplate {} {
    set candidates {}
    if {![catch {set root [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR]}]} { lappend candidates [file join $root feoutput optistruct optistruct] }
    if {![catch {set root [hm_info -appinfo EXECUTABLEDIR]}]} { lappend candidates [file join $root .. .. .. templates feoutput optistruct optistruct] }
    foreach candidate $candidates { set path [file normalize $candidate]; if {[file isfile $path]} { return $path } }
    error "Could not locate the HyperMesh OptiStruct FEM export template."
}

proc ::FemAutoSeam::exportFemBundle {dir runId componentIds {stem selected_components}} {
    set output [file join $dir ${stem}.fem]
    catch {*clearmark elems 1}; catch {*clearmark nodes 1}
    set code [catch {
        eval *createmark elems 1 [list "by component id"] $componentIds
        eval *createmark nodes 1 [list "by component id"] $componentIds
        if {![llength [hm_getmark elems 1]]} { error "Selected components contain no shell elements." }
        ::HWFlow::runHyperMeshIo export [list *feoutput_select [::FemAutoSeam::optistructExportTemplate] $output 1 0 0] $output
    } err opts]
    catch {*clearmark elems 1}; catch {*clearmark nodes 1}
    if {$code} { return -options $opts $err }
    set entries {}
    foreach componentId $componentIds {
        lappend entries "    {\"component_id\": $componentId, \"component_name\": [::HybridCore::jsonString [::FemAutoSeam::componentExportName $componentId]], \"role\": \"selected\", \"element_ids\": [::HybridCore::jsonIntArray [::FemAutoSeam::componentElementIds $componentId]]}"
    }
    set manifest [file join $dir ${stem}_manifest.json]
    ::HybridCore::writeTextFile $manifest "{\n  \"schema_version\": \"1.0\",\n  \"format\": \"hm_selected_components_fem\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"fem_path\": [::HybridCore::jsonString [file tail $output]],\n  \"components\": \[\n[join $entries ,\n]\n  \]\n}\n"
    return [dict create fem $output manifest $manifest]
}

proc ::FemAutoSeam::exportWholeModelFemBundle {dir runId {stem model}} {
    # The backend now edits the FEM file itself and HyperMesh reopens it with
    # File > Open semantics, so the input FEM must be the complete model and
    # the manifest must map every component (including empty ones).
    set output [file join $dir ${stem}.fem]
    catch {*clearmark elems 1}; catch {*clearmark nodes 1}
    set code [catch {
        *createmark elems 1 all
        *createmark nodes 1 all
        if {![llength [hm_getmark elems 1]]} { error "Current model contains no elements to export." }
        ::HWFlow::runHyperMeshIo export [list *feoutput_select [::FemAutoSeam::optistructExportTemplate] $output 1 0 0] $output
    } err opts]
    catch {*clearmark elems 1}; catch {*clearmark nodes 1}
    if {$code} { return -options $opts $err }
    set entries {}
    foreach componentId [::HybridCore::allComponentIds] {
        lappend entries "    {\"component_id\": $componentId, \"component_name\": [::HybridCore::jsonString [::FemAutoSeam::componentExportName $componentId]], \"role\": \"model\", \"element_ids\": [::HybridCore::jsonIntArray [::FemAutoSeam::componentElementIds $componentId]]}"
    }
    set manifest [file join $dir ${stem}_manifest.json]
    ::HybridCore::writeTextFile $manifest "{\n  \"schema_version\": \"1.0\",\n  \"format\": \"hm_model_fem\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"fem_path\": [::HybridCore::jsonString [file tail $output]],\n  \"components\": \[\n[join $entries ,\n]\n  \]\n}\n"
    return [dict create fem $output manifest $manifest]
}

proc ::FemAutoSeam::writeExistingSeams {path} {
    variable cfg
    set rows {}
    if {$cfg(exclude_existing_welds)} {
        foreach componentId [::HybridCore::allComponentIds] {
            set name [::FemAutoSeam::componentExportName $componentId]
            if {![string match -nocase "SEAM*" $name]} { continue }
            foreach elementId [::FemAutoSeam::componentElementIds $componentId] {
                set center ""; catch {set center [hm_getvalue elems id=$elementId dataname=center]}
                if {[llength $center] < 3} { continue }
                lappend rows "    {\"element_id\": $elementId, \"component_id\": $componentId, \"center\": \[[join $center ,]\]}"
            }
        }
    }
    ::HybridCore::writeTextFile $path "{\n  \"schema_version\": \"1.0\",\n  \"seams\": \[\n[join $rows ,\n]\n  \]\n}\n"
    return $path
}
