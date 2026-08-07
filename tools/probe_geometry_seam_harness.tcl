# Geometry seam full-function alignment harness (headless hmbatch).
# Drives the REAL module code from the repo against the installed HyperMesh.
#
# Usage (PowerShell, from an isolated empty workdir; one strategy per run so
# every strategy starts from a fresh fixture):
#   $env:HM_REPO   = 'C:\path\to\HW'
#   $env:HM_STRATEGY = 'T_PATH'   # or T_LIST|L_LIST|L_SURF|CONNECT|PROJECT|
#                                 # SPLIT|EXTEND|COMBINE|DISTRIBUTE_POINTS|
#                                 # REPLACE_POINT|DELETE|ALL
#   & '<Altair>\<year>\hm\bin\win64\hmbatch.exe' -nocommand -nouserprofiledialog -tcl probe_geometry_seam_harness.tcl
# The harness sources the repository modules headless (browser/Tk surface
# stubbed) and exercises the module's own executor dispatch. Results are
# written to seam_harness_out.txt; see
# docs/geometry_seam_dual_version_alignment_2026-08-07.md.
set repo [file normalize [expr {[info exists ::env(HM_REPO)] ? $::env(HM_REPO) : [pwd]}]]
set seamDir [file join $repo modules seam_surface]
set out [open seam_harness_out.txt w]
proc log {msg} {
    global out
    puts $out $msg
    flush $out
    catch {puts $msg}
}
proc log_result {label r} {
    set success [dict get $r success]
    set message [expr {[dict exists $r message] ? [dict get $r message] : ""}]
    set created [expr {[dict exists $r created_points] && [llength [dict get $r created_points]] > 0 ? [dict get $r created_points] : [dict exists $r created_surfs] ? [dict get $r created_surfs] : [dict exists $r deleted_surfs] ? [dict get $r deleted_surfs] : ""}]
    set warnings [expr {[dict exists $r warnings] ? [dict get $r warnings] : ""}]
    log [format "%-16s success=%s created={%s}" $label $success $created]
    if {$message ne ""} { log [format "%-16s message: %s" $label $message] }
    if {[llength $warnings] > 0} { log [format "%-16s warnings: %s" $label [join $warnings "; "]] }
    if {![string equal $success 1]} {
        set err [expr {[dict exists $r error_code] ? [dict get $r error_code] : ""}]
        log [format "%-16s FAILURE code=%s detail: %s" $label $err $message]
    }
}

log "===== HARNESS START [clock format [clock seconds] -format %Y-%m-%d_%H:%M:%S] ====="
catch {log "VERSION [hm_info -appinfo VERSION] DISPLAY [hm_info -appinfo DISPLAYVERSION]"}
log "REPO $repo"

source -encoding utf-8 [file join $repo modules workflow_common.tcl]
# Headless overrides (browser/Tk surface kept out of the batch path).
proc ::HWFlow::configDir {} { return [file join [pwd] hmwflow_cfg] }
proc ::HWFlow::syncComponentInBrowser {args} { return 0 }
proc ::HWFlow::resetBrowserBlocks {} { return 0 }
proc ::HWFlow::rememberComponent {args} { return 0 }
proc ::HWFlow::activateAndShowComponent {args} { return 0 }
proc ::HWFlow::refreshBrowserNow {args} { return [dict create touchedComponents {} touchedCount 0 modelComponents {} modelCount 0] }
proc ::HWFlow::scheduleBrowserRefresh {args} { return 0 }
catch {file mkdir [::HWFlow::configDir]}

foreach f {config.tcl log.tcl entity.tcl native_compat.tcl temp.tcl state.tcl validation.tcl candidate.tcl executor.tcl} {
    ::HWFlow::sourceUtf8 [file join $seamDir $f]
}
catch {::hmtoolkit::seam::config::load}
log "extend_offset_distance=[::hmtoolkit::seam::config::get extend_offset_distance] point_spacing=[::hmtoolkit::seam::config::get point_spacing]"

log "--- command existence ---"
foreach name {*startnotehistorystate *endnotehistorystate *undohistorystate *createentity \
    *createpoint *surfaceprimitivefrompoints *createmark hm_getmark *clearmark *duplicatemark \
    *movemark *deletemark *edgesmarkuntrim *edgesmarkaddpoints *connect_surfaces_11 \
    *linearsurfacebetweenlines *multi_surfs_lines_merge *selfstitchcombine \
    *surfacemarksplitwithlines *offset_surfaces_and_modify *projectpointstoedges \
    *verticescombine *solid_offset_from_surfs *boolean_merge_solids *trim_solids_by_surfaces \
    *deletesolidswithelems *displaycollectorsbymark *currentcollector hm_getcurrentcollector \
    hm_info hm_getvalue hm_getthickness hm_getoption *setoption hm_getsurfaceedges \
    hm_getsurfacesfromedge hm_linelength hm_getareaofsurface hm_getvolumeofsolid \
    hm_entityinfo hm_getcollectorname hm_private_frwk} {
    set pat [string map {* {\*} ? {\?} [ {\[} ] {\]} \\ {\\\\}} $name]
    set has [expr {[llength [info commands $pat]] > 0}]
    log [format "  %-36s %s" $name [expr {$has ? "EXIST" : "MISS"}]]
}

# ---------------- fixture ----------------
proc point_coords {pid} {
    set x ""; set y ""; set z ""
    catch {set x [hm_getvalue points id=$pid dataname=x]}
    catch {set y [hm_getvalue points id=$pid dataname=y]}
    catch {set z [hm_getvalue points id=$pid dataname=z]}
    return [list $x $y $z]
}
proc line_midpoint {lineId} {
    set got ""
    if {![catch {set got [hm_getcoordinatesofpointsonline $lineId [list 0.5]]}] && [llength $got] == 1} {
        return [lindex $got 0]
    }
    foreach dn {points vertices endpoint_ids} {
        set eps ""
        if {![catch {set eps [hm_getvalue lines id=$lineId dataname=$dn]}] && [llength $eps] == 2} {
            break
        }
    }
    if {[llength $eps] != 2} { return {} }
    lassign [point_coords [lindex $eps 0]] x1 y1 z1
    lassign [point_coords [lindex $eps 1]] x2 y2 z2
    if {$x1 eq "" || $x2 eq ""} { return {} }
    return [list [expr {($x1+$x2)/2.0}] [expr {($y1+$y2)/2.0}] [expr {($z1+$z2)/2.0}]]
}
proc dist3 {a b} {
    set dx [expr {[lindex $a 0]-[lindex $b 0]}]
    set dy [expr {[lindex $a 1]-[lindex $b 1]}]
    set dz [expr {[lindex $a 2]-[lindex $b 2]}]
    return [expr {sqrt($dx*$dx+$dy*$dy+$dz*$dz)}]
}
proc find_line_near {lineIds target} {
    set best ""; set bestD 1e30
    foreach lid $lineIds {
        set mid [line_midpoint $lid]
        if {[llength $mid] < 3} { continue }
        set d [dist3 $mid $target]
        if {$d < $bestD} { set bestD $d; set best $lid }
    }
    return [list $best $bestD]
}
proc surface_vertex_near {surfId target} {
    set lines {}
    if {![catch {set loops [hm_getsurfaceedges $surfId]}]} {
        foreach loop $loops { set lines [concat $lines $loop] }
    }
    foreach lid $lines {
        foreach dn {points vertices} {
            set eps ""
            if {![catch {set eps [hm_getvalue lines id=$lid dataname=$dn]}] && [llength $eps] >= 1} {
                foreach pid $eps {
                    lassign [point_coords $pid] px py pz
                    if {$px ne "" && [dist3 [list $px $py $pz] $target] < 1e-6} { return $pid }
                }
            }
        }
    }
    set best ""
    *createmark points 1 all
    foreach pid [hm_getmark points 1] {
        lassign [point_coords $pid] px py pz
        if {$px ne "" && [dist3 [list $px $py $pz] $target] < 1e-6} { set best $pid }
    }
    return $best
}
proc build_fixture {} {
    foreach {x y z} {
        5 0 2  5 10 2  5 10 7  5 0 7
        -2 0 0  8 0 0  8 10 0  -2 10 0
        2 0 1  4 0 1  4 10 1  2 10 1
        2 0 -2  4 0 -2  4 10 -2  2 10 -2
        1 3 0  3 3 0  3 5 0  1 5 0
    } {
        catch {*createpoint $x $y $z 0}
    }
    *createmark points 1 all
    set allPts [lsort -integer [hm_getmark points 1]]
    foreach start {0 4 8 12 16} {
        *createmark points 1 "by id" [lindex $allPts $start] [lindex $allPts [expr {$start+1}]] \
            [lindex $allPts [expr {$start+2}]] [lindex $allPts [expr {$start+3}]]
        catch {*surfaceprimitivefrompoints points 1 1 0 0}
    }
    *createmark surfs 1 all
    set surfs [lsort -integer [hm_getmark surfs 1]]
    *createmark lines 1 all
    set lines [lsort -integer [hm_getmark lines 1]]
    set replacePt [surface_vertex_near [lindex $surfs 4] {1 3 0}]
    log "fixture surfs=[join $surfs ,] lines=[join $lines ,] replace_point=$replacePt"
    set lineMap [dict create]
    foreach surfId $surfs {
        set sLines {}
        if {![catch {set loops [hm_getsurfaceedges $surfId]}]} {
            foreach loop $loops { set sLines [concat $sLines $loop] }
        }
        set sLines [lsort -integer -unique $sLines]
        dict set lineMap $surfId $sLines
    }
    set seamLine [lindex [find_line_near [dict get $lineMap 1] {5 5 2}] 0]
    set connectA [lindex [find_line_near [dict get $lineMap 2] {3 0 0}] 0]
    set connectB [lindex [find_line_near [dict get $lineMap 1] {5 0 4.5}] 0]
    set splitLine [lindex [find_line_near [dict get $lineMap 3] {2 5 1}] 0]
    log "seamLine=$seamLine connectA=$connectA connectB=$connectB splitLine=$splitLine"
    return [dict create surfs $surfs lines $lines seam_line $seamLine connect_a $connectA \
        connect_b $connectB split_line $splitLine replace_point $replacePt]
}

set strategy [expr {[info exists ::env(HM_STRATEGY)] ? $::env(HM_STRATEGY) : "ALL"}]
log "STRATEGY=$strategy"

proc run_strategy {name} {
    set fx [build_fixture]
    set surfs [dict get $fx surfs]
    set seamLine [dict get $fx seam_line]
    set connectA [dict get $fx connect_a]
    set connectB [dict get $fx connect_b]
    set splitLine [dict get $fx split_line]
    set replacePt [dict get $fx replace_point]
    set src1 [lindex $surfs 0]
    set tgt [lindex $surfs 1]
    set lapTgt [lindex $surfs 3]
    set thickness 12.0
    set r ""
    switch -- $name {
        T_PATH {
            set data [dict create seam_lines [list $seamLine] source_surfs [list $src1] \
                target_surfs [list $tgt] thickness $thickness]
            set r [::hmtoolkit::seam::executor::dispatch T_PATH $data]
        }
        T_LIST {
            set data [dict create seam_lines [list $seamLine] source_surfs [list $src1] \
                target_surfs [list $tgt] thickness $thickness]
            set r [::hmtoolkit::seam::executor::dispatch T_LIST $data]
        }
        L_LIST {
            set data [dict create seam_lines [list $seamLine] source_surfs [list $src1] \
                target_surfs [list $tgt] thickness $thickness]
            set r [::hmtoolkit::seam::executor::dispatch L_LIST $data]
        }
        L_SURF {
            set data [dict create source_surfs [list $tgt] target_surfs [list $lapTgt] thickness $thickness]
            set r [::hmtoolkit::seam::executor::dispatch L_SURF $data]
        }
        CONNECT {
            set data [dict create first_lines [list $connectA] second_lines [list $connectB] thickness $thickness]
            set r [::hmtoolkit::seam::executor::dispatch CONNECT $data]
        }
        PROJECT {
            set data [dict create seam_lines [list $splitLine] target_surfs [list $tgt]]
            set r [::hmtoolkit::seam::executor::dispatch PROJECT $data]
        }
        SPLIT {
            set data [dict create seam_lines [list $splitLine] target_surfs [list $tgt]]
            set r [::hmtoolkit::seam::executor::dispatch SPLIT $data]
        }
        EXTEND {
            ::hmtoolkit::seam::config::set_value extend_offset_distance 2.0
            set data [dict create seam_lines [list $seamLine] target_surfs [list $tgt]]
            set r [::hmtoolkit::seam::executor::dispatch EXTEND $data]
        }
        COMBINE {
            set data [dict create surfaces [list $src1 $tgt]]
            set r [::hmtoolkit::seam::executor::dispatch COMBINE $data]
        }
        DISTRIBUTE_POINTS {
            set data [dict create seam_lines [list $splitLine] spacing 2.0]
            set r [::hmtoolkit::seam::executor::dispatch DISTRIBUTE_POINTS $data]
        }
        REPLACE_POINT {
            set data [dict create points [list $replacePt] seam_lines [list $splitLine]]
            set r [::hmtoolkit::seam::executor::dispatch REPLACE_POINT $data]
        }
        DELETE {
            set data [dict create surfaces [list $lapTgt]]
            set r [::hmtoolkit::seam::executor::dispatch DELETE $data]
        }
        default {
            log "unknown strategy: $name"
        }
    }
    log_result $name $r
    *createmark surfs 1 all
    log "final surfs: [join [hm_getmark surfs 1] ,]"
}

if {$strategy eq "ALL"} {
    foreach name {T_PATH T_LIST L_LIST L_SURF CONNECT PROJECT SPLIT EXTEND COMBINE DISTRIBUTE_POINTS REPLACE_POINT DELETE} {
        log "----- $name -----"
        run_strategy $name
    }
} else {
    log "----- $strategy -----"
    run_strategy $strategy
}
log "===== HARNESS DONE ====="
close $out
exit
