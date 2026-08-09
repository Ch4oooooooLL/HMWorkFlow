# Audit probe A: command surface and lightweight semantics for the
# batch_mesher module.  Run headless on the real machine with:
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_batch_mesher_commands.tcl
#
# Results are written to runtime/audit_batch_mesher_commands_<version>.log
# as KEY=VALUE ASCII lines.  The probe creates a two-plane fixture (no
# meshing), exercises marks, by-attached, review/isolation commands,
# template/criteria loading and native model I/O roundtrips.  The report is
# always finalized (status PASS or FAIL); the process always exits 0.

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set versionRaw [string trim [hm_info -appinfo VERSION]]
set versionTag [regsub -all {[^0-9A-Za-z]} $versionRaw {_}]
set reportPath [file join $outputDir "audit_batch_mesher_commands_${versionTag}.log"]
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

# Exact match: glob-prefix matching in [info commands $name] can falsely
# match suffix commands (e.g. pattern "*getboundingbox" also matches
# "hm_getboundingbox").
proc exists {name} {
    expr {[lsearch -exact [info commands] $name] >= 0}
}

proc countEntities {entityType} {
    if {[catch {*createmark $entityType 2 all} err]} { return -1 }
    set count [llength [hm_getmark $entityType 2]]
    catch {*clearmark $entityType 2}
    return $count
}

set reportDir [file join $root runtime "audit_batch_mesher_work_${versionTag}"]
file mkdir $reportDir
cd $reportDir

set probeCode [catch {
    P "status" STARTED
    P "pid" [pid]
    P "version" $versionRaw
    P "executable" [info nameofexecutable]
    P "tcl_patchlevel" [info patchlevel]
    P "working_directory" [pwd]

    # --- 1. Command existence -----------------------------------------------
    set moduleCommands {
        *hm_batchmesh2 *hm_batchmesh *batchmesh_mc *readqualitycriteria
        *readbatchparamsfile *templatefileset *feoutputwithdata
        *feoutputmergeincludefiles *feinputwithdata2 *mergefile *readfile *writefile
        *deletemodel *createmark *appendmark *clearmark *deletemark
        *createmarkpanel *editmarkpanel *createlist *createstringarray
        *allsuppressoutput *marksuppressoutput *displayimporterrors
        *isolateentitybymark *setreviewbymark *setreviewcolormode
        *setreviewtransparentmode *setreviewmode *window_entitymark
        *surfacemode *createplane *surfaceplane *createentity *currentcollector
        *collectorcreateonly *createnode *createelement *entitypreviewempty
        hm_getmark hm_getvalue hm_getsurfaceedges hm_getverticesfromedge
        hm_info hm_answernext hm_redraw
        hm_jobs_canSubmit hm_jobs_getJobStatus hm_jobs_setCurrentServer
        hm_jobs_submitBatchmeshJob hm_getboundingbox *getboundingbox *bboxget
    }
    foreach name $moduleCommands {
        P "EXISTS $name" [expr {[exists $name] ? 1 : 0}]
    }

    # --- 2. hm_info application info ----------------------------------------
    P "hm_info_appinfo_VERSION_OK" [string trim [hm_info -appinfo VERSION]]
    TRY "hm_info_appinfo_SPECIFIEDPATH_TEMPLATES_DIR" {string trim [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR]}
    TRY "hm_info_appinfo_EXECUTABLEDIR" {string trim [hm_info -appinfo EXECUTABLEDIR]}
    TRY "hm_info_appinfo_CURRENTFILE" {string trim [hm_info -appinfo CURRENTFILE]}
    TRY "hm_info_currentfile" {hm_info currentfile}
    TRY "hm_info_displayimporterrors" {hm_info displayimporterrors}

    # --- 3. Two-plane fixture (planes share the x=100 edge) ------------------
    set surfaceIds {}
    if {[catch {
        *surfacemode 4
        *createplane 1 0.0 0.0 1.0 0.0 0.0 0.0
        *surfaceplane 1 100.0
        *createplane 2 0.0 0.0 1.0 100.0 0.0 0.0
        *surfaceplane 2 100.0
        *createmark surfs 2 all
        set surfaceIds [hm_getmark surfs 2]
        *clearmark surfs 2
    } fixtureError fixtureOptions]} {
        set detail $fixtureError
        if {[dict exists $fixtureOptions -errorinfo]} { append detail " | " [dict get $fixtureOptions -errorinfo] }
        P "FIXTURE_CREATE_ERROR" $detail
    } else {
        P "FIXTURE_SURFACE_COUNT" [llength $surfaceIds]
        P "FIXTURE_SURFACE_IDS" [join $surfaceIds {,}]
        catch {*clearmark surfs 2}
    }

    # --- 4. createmark / getmark roundtrips ----------------------------------
    if {[llength $surfaceIds] >= 1} {
        set seedId [lindex $surfaceIds 0]
        catch {*clearmark surfs 1}
        TRY "CREATEMARK_SINGLE" [list *createmark surfs 1 $seedId]
        P "GETMARK_SINGLE" [join [hm_getmark surfs 1] {,}]
        catch {*clearmark surfs 1}

        TRY "CREATEMARK_ALL" {*createmark surfs 2 all}
        P "GETMARK_ALL_COUNT" [llength [hm_getmark surfs 2]]
        catch {*clearmark surfs 2}

        TRY "CREATEMARK_DISPLAYED" {*createmark surfs 2 displayed}
        P "GETMARK_DISPLAYED_COUNT" [llength [hm_getmark surfs 2]]
        catch {*clearmark surfs 2}

        # --- 5. by attached semantics ---------------------------------------
        catch {*clearmark surfs 1}
        *createmark surfs 1 $seedId
        if {[catch {*appendmark surfs 1 "by attached"} attachedError]} {
            P "APPENDMARK_BY_ATTACHED_SINGLE_ERROR" $attachedError
        } else {
            P "APPENDMARK_BY_ATTACHED_SINGLE_COUNT" [llength [hm_getmark surfs 1]]
        }
        catch {*clearmark surfs 1}

        # Module loop: repeat until stable.
        catch {*clearmark surfs 1}
        *createmark surfs 1 $seedId
        set previousCount -1
        set iterations 0
        while {1} {
            set current [llength [hm_getmark surfs 1]]
            if {$current == $previousCount} { break }
            set previousCount $current
            incr iterations
            if {[catch {*appendmark surfs 1 "by attached"} loopError]} {
                P "APPENDMARK_BY_ATTACHED_LOOP_ERROR" $loopError
                break
            }
            if {$iterations > 20} { P "APPENDMARK_LOOP_DID_NOT_CONVERGE" 1; break }
        }
        P "APPENDMARK_BY_ATTACHED_LOOP_ITERATIONS" $iterations
        P "APPENDMARK_BY_ATTACHED_LOOP_COUNT" [llength [hm_getmark surfs 1]]
        catch {*clearmark surfs 1}

        # Direct *createmark "by attached" (alternative candidate).
        catch {*clearmark surfs 1}
        *createmark surfs 1 $seedId
        if {[catch {*createmark surfs 1 "by attached"} directError]} {
            P "CREATEMARK_DIRECT_BY_ATTACHED_ERROR" $directError
        } else {
            P "CREATEMARK_DIRECT_BY_ATTACHED_COUNT" [llength [hm_getmark surfs 1]]
        }
        catch {*clearmark surfs 1}

        # --- 6. review / isolation commands ----------------------------------
        catch {*clearmark surfs 1}
        *createmark surfs 1 $seedId
        TRY "SETREVIEWBYMARK_4" {*setreviewbymark surfs 1 4}
        TRY "SETREVIEWCOLORMODE_0" {*setreviewcolormode 0}
        TRY "SETREVIEWTRANSPARENTMODE_1" {*setreviewtransparentmode 1}
        TRY "SETREVIEWMODE_1" {*setreviewmode 1}
        TRY "WINDOW_ENTITYMARK" {*window_entitymark surfs 1}
        TRY "ISOLATEENTITYBYMARK_1_1_0" {*isolateentitybymark 1 1 0}
        catch {*clearmark surfs 1}

        # --- 7. geometry query datanames -------------------------------------
        TRY "GETSURFACEEDGES" [list hm_getsurfaceedges $seedId]
        set edgeId ""
        if {![catch {set loops [hm_getsurfaceedges $seedId]}] && [llength $loops] > 0 && [llength [lindex $loops 0]] > 0} {
            set edgeId [lindex [lindex $loops 0] 0]
            P "EDGE_FIRST" $edgeId
            TRY "GETVERTICESFROMEDGE" [list hm_getverticesfromedge $edgeId]
            if {![catch {set pointIds [hm_getverticesfromedge $edgeId]}] && [llength $pointIds] > 0} {
                set probePointId [lindex $pointIds 0]
                TRY "GETVALUE_POINT_COORDINATES" [list hm_getvalue points id=$probePointId dataname=coordinates]
                foreach dataname {x y z} {
                    TRY "GETVALUE_POINT_$dataname" [list hm_getvalue points id=$probePointId dataname=$dataname]
                }
            }
        }
        foreach dataname {collector.id collectorid component.id comp.id} {
            TRY "GETVALUE_SURF_$dataname" [list hm_getvalue surfs id=$seedId dataname=$dataname]
        }

        # Bounding-box alternative for the module's geometry-span walk.
        # Candidate signatures are probed; record whatever each returns.
        catch {*clearmark surfs 1}
        *createmark surfs 1 $seedId
        TRY "HM_GETBOUNDINGBOX_MARK" {hm_getboundingbox surfs 1}
        TRY "HM_GETBOUNDINGBOX_IDS" [list hm_getboundingbox surfs $seedId]
        TRY "STAR_GETBOUNDINGBOX" [list *getboundingbox surfs 1]
        catch {*clearmark surfs 1}
    }

    # --- 8. createlist (ordered list; module does not use it) -----------------
    if {[llength $surfaceIds] >= 2} {
        TRY "CREATELIST_ORDERED" [list *createlist surfs 1 {*}[lrange $surfaceIds 0 1]]
        catch {*clearmark surfs 1}
    }

    # --- 9. template / criteria / param loading -------------------------------
    set executableDir [file dirname [info nameofexecutable]]
    set templateCandidates [list \
        [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
    if {![catch {set templatesDir [string trim [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR]]}] && $templatesDir ne ""} {
        lappend templateCandidates [file join $templatesDir feoutput optistruct optistruct]
    }
    set templatePath ""
    foreach candidate $templateCandidates {
        set normalized [file normalize $candidate]
        if {[file isfile $normalized]} { set templatePath $normalized; break }
    }
    P "TEMPLATE_CANDIDATES" [join $templateCandidates { ; }]
    P "TEMPLATE_RESOLVED" [expr {$templatePath eq "" ? "MISSING" : $templatePath}]
    if {$templatePath ne ""} {
        TRY "TEMPLATEFILESET" [list *templatefileset [file nativename $templatePath]]
    }
    set criteriaPath ""
    foreach candidate [list \
        [file join $executableDir .. .. .. hm batchmesh general_8mm.criteria] \
        [file join [file dirname $executableDir] batchmesh general_8mm.criteria]] {
        set normalized [file normalize $candidate]
        if {[file isfile $normalized]} { set criteriaPath $normalized; break }
    }
    P "CRITERIA_RESOLVED" [expr {$criteriaPath eq "" ? "MISSING" : $criteriaPath}]
    if {$criteriaPath ne ""} {
        TRY "READQUALITYCRITERIA" [list *readqualitycriteria [file nativename $criteriaPath]]
        TRY "READBATCHPARAMSFILE" [list *readbatchparamsfile [file nativename [string map {.criteria .param} $criteriaPath]]]
    }

    # --- 10. output suppression switches --------------------------------------
    TRY "ALLSUPPRESSOUTPUT_1" {*allsuppressoutput 1}
    TRY "MARKSUPPRESSOUTPUT_COMPS" {*marksuppressoutput comps 1 0}
    TRY "ALLSUPPRESSOUTPUT_0" {*allsuppressoutput 0}
    TRY "FEOUTPUTMERGEINCLUDEFILES_1" {*feoutputmergeincludefiles 1}

    # --- 11. model I/O roundtrips ---------------------------------------------
    set fixtureModel [file join $reportDir "audit_fixture_${versionTag}.hm"]
    if {[llength $surfaceIds] >= 1} {
        TRY "WRITEFILE_FIXTURE" [list *writefile [file nativename $fixtureModel] 1]
        P "WRITEFILE_FIXTURE_BYTES" [file size $fixtureModel]
    }
    catch {hm_answernext yes}
    TRY "DELETEMODEL" {*deletemodel}
    P "AFTER_DELETEMODEL_SURFACES" [countEntities surfs]

    if {[file isfile $fixtureModel]} {
        TRY "MERGEFILE_0_1" [list *mergefile [file nativename $fixtureModel] 0 1]
        P "MERGEFILE_0_1_SURFACES" [countEntities surfs]
        P "MERGEFILE_0_1_ELEMS" [countEntities elems]

        catch {hm_answernext yes}
        catch {*deletemodel}
        TRY "MERGEFILE_1_1" [list *mergefile [file nativename $fixtureModel] 1 1]
        P "MERGEFILE_1_1_SURFACES" [countEntities surfs]

        catch {hm_answernext yes}
        catch {*deletemodel}
        TRY "READFILE_FLAG_0" [list *readfile [file nativename $fixtureModel] 0]
        P "READFILE_FLAG_0_SURFACES" [countEntities surfs]

        catch {hm_answernext yes}
        catch {*deletemodel}
        TRY "READFILE_NO_FLAG" [list *readfile [file nativename $fixtureModel]]
        P "READFILE_NO_FLAG_SURFACES" [countEntities surfs]
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
