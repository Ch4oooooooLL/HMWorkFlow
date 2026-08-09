# Audit probe B: production BatchMesh path for the batch_mesher module.
# Run headless on the real machine with:
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_batch_mesher_batchmesh2.tcl
#
# Results are written to runtime/audit_batch_mesher_batchmesh2_<version>.log
# as KEY=VALUE ASCII lines.  Exercises in one process: meshing with and
# without profile/criteria preload, the string-array parameter override
# variant of *hm_batchmesh2, both *feoutputwithdata argument shapes used by
# the module, element/component dataname fallbacks, and the native I/O
# roundtrip (*writefile / *readfile / *mergefile / *feinputwithdata2).
# The report is always finalized (status PASS or FAIL); exit 0 at the end.

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set versionRaw [string trim [hm_info -appinfo VERSION]]
set versionTag [regsub -all {[^0-9A-Za-z]} $versionRaw {_}]
set reportPath [file join $outputDir "audit_batch_mesher_batchmesh2_${versionTag}.log"]
set channel [open $reportPath w]
fconfigure $channel -encoding utf-8 -translation lf

proc P {key value} {
    variable channel
    set clean [string map [list "\n" { | } "\r" {} "\t" { }] $value]
    puts $channel "${key}=${clean}"
}

# Record outcome of a native call; never re-raise.
proc TRY {key script} {
    if {[catch {uplevel 1 $script} value options]} {
        set detail $value
        if {[dict exists $options -errorinfo]} { append detail " | " [dict get $options -errorinfo] }
        P "${key}_ERROR" $detail
        return 0
    }
    P "${key}_OK" $value
    return 1
}

proc countElems {} {
    if {[catch {*createmark elems 2 all} err]} { return -1 }
    set ids [hm_getmark elems 2]
    catch {*clearmark elems 2}
    return [llength $ids]
}

proc countSurfaces {} {
    if {[catch {*createmark surfs 2 all} err]} { return -1 }
    set ids [hm_getmark surfs 2]
    catch {*clearmark surfs 2}
    return [llength $ids]
}

set reportDir [file join $root runtime "audit_batch_mesher_work_${versionTag}"]
file mkdir $reportDir
cd $reportDir

set probeCode [catch {
    P "status" STARTED
    P "pid" [pid]
    P "version" $versionRaw
    P "executable" [info nameofexecutable]
    P "working_directory" [pwd]

    # --- 0. Locate install-provided criteria/param and OptiStruct template ----
    set executableDir [file dirname [info nameofexecutable]]
    set templatePath ""
    set candidate [file join $executableDir .. .. .. templates feoutput optistruct optistruct]
    if {![catch {set normalized [file normalize $candidate]}] && [file isfile $normalized]} {
        set templatePath $normalized
    }
    set criteriaPath ""
    foreach candidate [list \
        [file join $executableDir .. .. .. hm batchmesh general_8mm.criteria] \
        [file join [file dirname $executableDir] batchmesh general_8mm.criteria]] {
        set normalized [file normalize $candidate]
        if {[file isfile $normalized]} { set criteriaPath $normalized; break }
    }
    set paramPath ""
    if {$criteriaPath ne ""} {
        set paramPath [string map {.criteria .param} $criteriaPath]
        if {![file isfile $paramPath]} { set paramPath "" }
    }
    P "TEMPLATE_RESOLVED" [expr {$templatePath eq "" ? "MISSING" : $templatePath}]
    P "CRITERIA_RESOLVED" [expr {$criteriaPath eq "" ? "MISSING" : $criteriaPath}]
    P "PARAM_RESOLVED" [expr {$paramPath eq "" ? "MISSING" : $paramPath}]

    catch {hm_answernext yes}
    TRY "DELETEMODEL" {*deletemodel}

    # --- 1. Fixture: one 100 x 100 planar surface in a dedicated component ----
    TRY "CREATEENTITY_COMP" {*createentity comps name=AUDIT_BATCHMESH_PROBE}
    TRY "CURRENTCOLLECTOR" {*currentcollector comps AUDIT_BATCHMESH_PROBE}
    TRY "SURFACEMODE_4" {*surfacemode 4}
    TRY "CREATEPLANE" {*createplane 1 0.0 0.0 1.0 0.0 0.0 0.0}
    TRY "SURFACEPLANE" {*surfaceplane 1 100.0}
    P "FIXTURE_SURFACES" [countSurfaces]

    # --- 2. Mesh WITHOUT profile/criteria preload (HM2019 worker path) -------
    set elementsBefore [countElems]
    P "ELEMENTS_BEFORE_MESH_NO_PROFILE" $elementsBefore
    set started [clock milliseconds]
    if {$criteriaPath ne "" && $paramPath ne ""} {
        if {[catch {
            *createmark surfs 1 all
            *hm_batchmesh2 surfs 1 1 0 [file nativename $criteriaPath] [file nativename $paramPath]
        } meshError meshOptions]} {
            set detail $meshError
            if {[dict exists $meshOptions -errorinfo]} { append detail " | " [dict get $meshOptions -errorinfo] }
            P "HM_BATCHMESH2_NO_PROFILE_ERROR" $detail
        } else {
            P "HM_BATCHMESH2_NO_PROFILE_OK" 1
        }
    }
    P "ELEMENTS_AFTER_MESH_NO_PROFILE" [countElems]
    P "MESH_NO_PROFILE_ELAPSED_MS" [expr {[clock milliseconds] - $started}]
    catch {*clearmark surfs 1}

    # --- 3. Profile + criteria preload, then mesh again (2022 worker path) ----
    if {$templatePath ne ""} {
        TRY "TEMPLATEFILESET" [list *templatefileset [file nativename $templatePath]]
    }
    if {$criteriaPath ne ""} {
        TRY "READQUALITYCRITERIA" [list *readqualitycriteria [file nativename $criteriaPath]]
        TRY "READBATCHPARAMSFILE" [list *readbatchparamsfile [file nativename $paramPath]]
    }
    P "ELEMENTS_BEFORE_MESH_WITH_PROFILE" [countElems]
    set started [clock milliseconds]
    if {$criteriaPath ne "" && $paramPath ne ""} {
        if {[catch {
            *createmark surfs 1 all
            *hm_batchmesh2 surfs 1 1 0 [file nativename $criteriaPath] [file nativename $paramPath]
        } meshError meshOptions]} {
            set detail $meshError
            if {[dict exists $meshOptions -errorinfo]} { append detail " | " [dict get $meshOptions -errorinfo] }
            P "HM_BATCHMESH2_WITH_PROFILE_ERROR" $detail
        } else {
            P "HM_BATCHMESH2_WITH_PROFILE_OK" 1
        }
    }
    P "ELEMENTS_AFTER_MESH_WITH_PROFILE" [countElems]
    P "MESH_WITH_PROFILE_ELAPSED_MS" [expr {[clock milliseconds] - $started}]
    catch {*clearmark surfs 1}

    # --- 4. String-array parameter override variant (string_array=1) ----------
    P "ELEMENTS_BEFORE_MESH_OVERRIDE" [countElems]
    set started [clock milliseconds]
    if {$criteriaPath ne "" && $paramPath ne ""} {
        if {[catch {
            *createmark surfs 1 all
            *createstringarray 1 "element_size=4"
            *hm_batchmesh2 surfs 1 1 1 [file nativename $criteriaPath] [file nativename $paramPath]
        } overrideError overrideOptions]} {
            set detail $overrideError
            if {[dict exists $overrideOptions -errorinfo]} { append detail " | " [dict get $overrideOptions -errorinfo] }
            P "HM_BATCHMESH2_STRINGARRAY_ERROR" $detail
        } else {
            P "HM_BATCHMESH2_STRINGARRAY_OK" 1
        }
    }
    P "ELEMENTS_AFTER_MESH_OVERRIDE" [countElems]
    P "MESH_OVERRIDE_ELAPSED_MS" [expr {[clock milliseconds] - $started}]
    catch {*clearmark surfs 1}

    # --- 5. *feoutputwithdata both argument shapes used by the module ----------
    proc femCardCounts {path} {
        set channel [open $path r]
        set text [read $channel]
        close $channel
        set grids [regexp -all {\nGRID\s} $text]
        set quads [regexp -all {\nCQUAD4\s} $text]
        set trias [regexp -all {\nCTRIA3\s} $text]
        return [list GRID=$grids CQUAD4=$quads CTRIA3=$trias BYTES=[string length $text]]
    }

    set resultFemWorker [file join $reportDir "audit_worker_shape_${versionTag}.fem"]
    set resultFemMerge [file join $reportDir "audit_merge_shape_${versionTag}.fem"]
    if {[countElems] > 0 && $templatePath ne ""} {
        # Worker export shape: *allsuppressoutput + custom component output.
        if {[catch {
            *allsuppressoutput 1
            foreach entityType {comps props mats} {
                *createmark $entityType 1 all
                set ids [hm_getmark $entityType 1]
                if {[llength $ids] > 0} { *marksuppressoutput $entityType 1 0 }
            }
            catch {*feoutputmergeincludefiles 1}
            catch {hm_answernext yes}
            *feoutputwithdata [file nativename $templatePath] [file nativename $resultFemWorker] 0 0 2 1 0
            *allsuppressoutput 0
        } exportError exportOptions]} {
            set detail $exportError
            if {[dict exists $exportOptions -errorinfo]} { append detail " | " [dict get $exportOptions -errorinfo] }
            P "FEOUTPUTWITH_DATA_WORKER_SHAPE_ERROR" $detail
        } else {
            P "FEOUTPUTWITH_DATA_WORKER_SHAPE_OK" 1
            P "FEOUTPUTWITH_DATA_WORKER_SHAPE_CARDS" [femCardCounts $resultFemWorker]
            P "FEOUTPUTWITH_DATA_WORKER_SHAPE_BYTES" [file size $resultFemWorker]
        }
        # Merge worker export shape.
        if {[catch {
            catch {hm_answernext yes}
            catch {*feoutputmergeincludefiles 1}
            *feoutputwithdata [file nativename $templatePath] [file nativename $resultFemMerge] 0 0 1 1 0
        } exportError2 exportOptions2]} {
            set detail $exportError2
            if {[dict exists $exportOptions2 -errorinfo]} { append detail " | " [dict get $exportOptions2 -errorinfo] }
            P "FEOUTPUTWITH_DATA_MERGE_SHAPE_ERROR" $detail
        } else {
            P "FEOUTPUTWITH_DATA_MERGE_SHAPE_OK" 1
            P "FEOUTPUTWITH_DATA_MERGE_SHAPE_CARDS" [femCardCounts $resultFemMerge]
            P "FEOUTPUTWITH_DATA_MERGE_SHAPE_BYTES" [file size $resultFemMerge]
        }
    }

    # --- 6. Element/component dataname fallbacks used by the module ------------
    if {[countElems] > 0} {
        *createmark elems 2 all
        set elementIds [hm_getmark elems 2]
        *clearmark elems 2
        set elementId [lindex $elementIds 0]
        foreach dataname {nodes collector.id collectorid component.id comp.id property.id propertyid prop.id} {
            TRY "GETVALUE_ELEM_$dataname" [list hm_getvalue elems id=$elementId dataname=$dataname]
        }
        foreach entityType {comps props mats} {
            *createmark $entityType 2 all
            set ids [hm_getmark $entityType 2]
            *clearmark $entityType 2
            if {[llength $ids] > 0} {
                foreach dataname {name id} {
                    TRY "GETVALUE_${entityType}_$dataname" [list hm_getvalue $entityType id=[lindex $ids 0] dataname=$dataname]
                }
            }
        }
        *createmark comps 2 all
        set compIds [hm_getmark comps 2]
        *clearmark comps 2
        foreach compId $compIds {
            foreach dataname {property.id propertyid prop.id} {
                set value ""
                if {![catch {set value [hm_getvalue comps id=$compId dataname=$dataname]}] && [string is integer -strict $value] && $value > 0} {
                    P "GETVALUE_COMPS_PROPERTY_LINK" "$dataname -> $value"
                    break
                }
            }
        }
    }

    # --- 7. Native model roundtrip: writefile / readfile ----------------------
    set modelPath [file join $reportDir "audit_meshed_${versionTag}.hm"]
    if {[catch {*writefile [file nativename $modelPath] 1} writeError]} {
        P "WRITEFILE_MESHED_ERROR" $writeError
    } else {
        P "WRITEFILE_MESHED_OK" 1
        P "WRITEFILE_MESHED_BYTES" [file size $modelPath]
    }
    catch {hm_answernext yes}
    catch {*deletemodel}
    TRY "READFILE_MESHED_FLAG_0" [list *readfile [file nativename $modelPath] 0]
    P "READFILE_MESHED_FLAG_0_ELEMS" [countElems]

    # --- 8. *feinputwithdata2 re-import of the worker-shaped FEM ---------------
    if {[file isfile $resultFemWorker] && [file size $resultFemWorker] > 0} {
        catch {hm_answernext yes}
        catch {*deletemodel}
        set elementsBeforeImport [countElems]
        if {[catch {
            *feinputwithdata2 "#optistruct/optistruct" [file nativename $resultFemWorker] 0 0 0 0 0 1 0 1 0
        } importError importOptions]} {
            set detail $importError
            if {[dict exists $importOptions -errorinfo]} { append detail " | " [dict get $importOptions -errorinfo] }
            P "FEINPUTWITHDATA2_ERROR" $detail
        } else {
            P "FEINPUTWITHDATA2_OK" 1
        }
        P "FEINPUTWITHDATA2_BEFORE" $elementsBeforeImport
        P "FEINPUTWITHDATA2_AFTER" [countElems]
    }

    # --- 9. *mergefile 0 1 (module main-session import path) -------------------
    if {[file isfile $modelPath] && [file size $modelPath] > 0} {
        catch {hm_answernext yes}
        catch {*deletemodel}
        if {[catch {*mergefile [file nativename $modelPath] 0 1} mergeError]} {
            P "MERGEFILE_0_1_ERROR" $mergeError
        } else {
            P "MERGEFILE_0_1_OK" 1
            P "MERGEFILE_0_1_SURFACES" [countSurfaces]
            P "MERGEFILE_0_1_ELEMS" [countElems]
        }
    }

    P "status" PASS
} probeError probeOptions]

if {$probeCode} {
    set detail $probeError
    if {[dict exists $probeOptions -errorinfo]} { append detail " | " [dict get $probeOptions -errorinfo] }
    P "status" FAIL
    P "probe_error" $detail
}
close $channel
exit 0
