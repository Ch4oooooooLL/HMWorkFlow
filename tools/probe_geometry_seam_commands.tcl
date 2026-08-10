# Parametric geometry-seam command probe for installed HyperMesh builds.
#
# Run one test per hmbatch invocation (fresh model per test). Every test
# rebuilds the same fixture, so results are directly comparable across
# HyperMesh 2019.0.0.70 and 2022.0.0.33 (see
# docs/geometry_seam_dual_version_alignment_2026-08-07.md).
#
# Usage (PowerShell, from an isolated empty workdir):
#   $env:HM_PROBE_TEST = 'marks'   # version|marks|connect_tsurface|connect_tlist|connect_extend2|
#                                  # connect_extend1|offset_docs_cont|offset_docs_disjoint|
#                                  # offset_repo|project_repo|project_alt|ruled|splitlines|
#                                  # merge|vertices|readonly|coords_probe|offset_repo_coords|
#                                  # offset_docs_coords
#   & '<Altair>\<year>\hm\bin\win64\hmbatch.exe' -nocommand -nouserprofiledialog -tcl probe_geometry_seam_commands.tcl
set chan [open probe_out.txt w]
proc log {msg} {
    global chan
    puts $chan $msg
    flush $chan
    catch {puts $msg}
}
proc trycmd {label args} {
    set code [catch {uplevel #0 {*}$args} value options]
    if {$code} {
        log [format "%-50s ERR: %s" $label $value]
    } else {
        log [format "%-50s OK: {%s}" $label $value]
    }
}

proc fresh_model {} {
    foreach {x y z} {0 0 0  10 0 0  10 10 0  0 10 0  10 0 0  20 0 0  20 10 0  10 10 0} {
        catch {*createpoint $x $y $z 0}
    }
    *createmark points 1 all
    catch {*surfaceprimitivefrompoints points 1 1 0 0}
    *createmark points 1 all
    catch {*surfaceprimitivefrompoints points 1 1 0 0}
    *createmark surfs 1 all
    set surfs [hm_getmark surfs 1]
    *createmark lines 1 all
    set lines [hm_getmark lines 1]
    log "fresh model: surfs=[join $surfs ,] lines=[join $lines ,] points=[join [hm_getmark points 1] ,]"
    return [list $surfs $lines]
}

proc model_state {tag} {
    *createmark surfs 1 all
    set surfs [hm_getmark surfs 1]
    *createmark lines 1 all
    set lines [hm_getmark lines 1]
    *createmark points 1 all
    set pts [hm_getmark points 1]
    log "$tag state: surfs=[join $surfs ,] lines=[join $lines ,] points=[join $pts ,]"
}

set test [expr {[info exists ::env(HM_PROBE_TEST)] ? $::env(HM_PROBE_TEST) : "version"}]
log "===== TEST=$test [clock format [clock seconds] -format %Y-%m-%d_%H:%M:%S] ====="
catch {log "VERSION [hm_info -appinfo VERSION] DISPLAY [hm_info -appinfo DISPLAYVERSION]"}

switch $test {
    connect_tsurface {
        # Surface-to-surface extend route used by the T Surface action. The
        # fixture is intentionally gapped so a seam strip has room to form.
        foreach {x y z} {
            0 0 2  10 0 2  10 0 12  0 0 12
            0 -5 0  10 -5 0  10 5 0  0 5 0
        } { catch {*createpoint $x $y $z 0} }
        *createmark points 1 1 2 3 4
        *surfaceprimitivefrompoints points 1 1 0 0
        *createmark points 1 5 6 7 8
        *surfaceprimitivefrompoints points 1 1 0 0
        *createmark surfs 1 all
        set surfs [hm_getmark surfs 1]
        set src [lindex $surfs 0]; set tgt [lindex $surfs 1]
        *createmark surfs 1 $src
        *createmark surfs 2 $tgt
        trycmd "connect_surfaces_11 1 2 1 1 50 15 30 1 0 2 30 59 0" \
            {*connect_surfaces_11 1 2 1 1 50 15 30 1 0 2 30 59 0}
        model_state after_tsurface
    }
    marks {
        fresh_model
        log "--- mark slot sweep (with entities) ---"
        foreach slot {1 2 3 4 5 6 7 8 9 10 20 99} {
            set ok 1; set detail ""
            set e1 ""
            if {[catch {*createmark surfs $slot all} e1]} { set ok 0; set detail "createmark: $e1" }
            set e2 ""
            if {$ok} {
                set got ""
                if {[catch {set got [hm_getmark surfs $slot]} e2]} { set ok 0; set detail "getmark: $e2" }
                if {$ok} { set detail "got [llength $got] surfs" }
            }
            catch {*clearmark surfs $slot}
            log [format "mark %-3s %s" $slot [expr {$ok ? "OK ($detail)" : "ERR ($detail)"}]]
        }
    }
    connect_tlist {
        lassign [fresh_model] surfs lines
        set src [lindex $surfs 0]; set tgt [lindex $surfs 1]
        set seam [lindex $lines 1]
        catch {*createmark lines 1 $seam}
        catch {*createmark surfs 1 $src}
        catch {*createmark surfs 2 $tgt}
        trycmd "connect_surfaces_11 1 2 3 1 0 15 30 1 0 2 30 59 0" \
            {*connect_surfaces_11 1 2 3 1 0 15 30 1 0 2 30 59 0}
        model_state after_tlist
    }
    connect_extend2 {
        lassign [fresh_model] surfs lines
        set src [lindex $surfs 0]
        set seam [lindex $lines 1]
        catch {*createmark lines 1 $seam}
        catch {*createmark surfs 1 $src}
        trycmd "connect_surfaces_11 1 1 3 2 0 15 30 1 0 2 30 3 0" \
            {*connect_surfaces_11 1 1 3 2 0 15 30 1 0 2 30 3 0}
        model_state after_extend2
    }
    connect_extend1 {
        lassign [fresh_model] surfs lines
        set src [lindex $surfs 0]
        set seam [lindex $lines 1]
        catch {*createmark lines 1 $seam}
        catch {*createmark surfs 1 $src}
        trycmd "connect_surfaces_11 1 1 3 1 0 15 30 1 0 2 30 3 0" \
            {*connect_surfaces_11 1 1 3 1 0 15 30 1 0 2 30 3 0}
        model_state after_extend1
    }
    offset_docs_cont {
        lassign [fresh_model] surfs lines
        set tgt [lindex $surfs 1]
        catch {*createmark surfs 2 $tgt}
        trycmd "offset docs-cont surfaces 2 0 1 -3 -12" \
            {*offset_surfaces_and_modify surfaces 2 0 1 -3 -12}
        model_state after_docs_cont
    }
    offset_docs_disjoint {
        lassign [fresh_model] surfs lines
        set tgt [lindex $surfs 1]
        catch {*createmark surfs 2 $tgt}
        trycmd "offset docs-disjoint surfaces 2 0 1 2 -12" \
            {*offset_surfaces_and_modify surfaces 2 0 1 2 -12}
        model_state after_docs_disjoint
    }
    offset_repo {
        lassign [fresh_model] surfs lines
        set tgt [lindex $surfs 1]
        catch {*createmark surfs 2 $tgt}
        trycmd "offset repo surfaces 2 2 1 -12 2" \
            {*offset_surfaces_and_modify surfaces 2 2 1 -12 2}
        model_state after_repo
    }
    project_repo {
        lassign [fresh_model] surfs lines
        set pt [lindex [hm_getmark points 1] 0]
        set seam [lindex $lines 1]
        catch {*createmark points 1 $pt}
        catch {*createmark lines 2 $seam}
        trycmd "projectpointstoedges 2 1 -1 0" {*projectpointstoedges 2 1 -1 0}
        model_state after_project_repo
    }
    project_alt {
        lassign [fresh_model] surfs lines
        set pt [lindex [hm_getmark points 1] 0]
        set seam [lindex $lines 1]
        catch {*createmark points 1 $pt}
        catch {*createmark lines 2 $seam}
        trycmd "projectpointstoedges 2 1 1e6 0" {*projectpointstoedges 2 1 1e6 0}
        model_state after_project_alt
    }
    ruled {
        lassign [fresh_model] surfs lines
        set a [lindex $lines 0]; set b [lindex $lines 4]
        catch {*createlist lines 1 $a}
        catch {*createlist lines 2 $b}
        trycmd "linearsurfacebetweenlines 1 1 2 2 1" {*linearsurfacebetweenlines 1 1 2 2 1}
        model_state after_ruled
    }
    splitlines {
        lassign [fresh_model] surfs lines
        set src [lindex $surfs 0]
        set seam [lindex $lines 1]
        catch {*createmark surfs 1 $src}
        catch {*createmark lines 2 $seam}
        trycmd "surfacemarksplitwithlines 1 2 0 13 0" {*surfacemarksplitwithlines 1 2 0 13 0}
        model_state after_splitlines
    }
    merge {
        lassign [fresh_model] surfs lines
        catch {*createmark surfs 1 all}
        trycmd "multi_surfs_lines_merge 1 0 0" {*multi_surfs_lines_merge 1 0 0}
        model_state after_merge
    }
    vertices {
        lassign [fresh_model] surfs lines
        set pt [lindex [hm_getmark points 1] 0]
        trycmd "verticescombine $pt 1" [list *verticescombine $pt 1]
        model_state after_vertices
    }
    coords_probe {
        lassign [fresh_model] surfs lines
        *createmark points 1 all
        set pts [hm_getmark points 1]
        foreach dn {x y z globalx globaly globalz locx locy locz coords xyz} {
            set got ""
            if {![catch {set got [hm_getvalue points id=[lindex $pts 8] dataname=$dn]}]} {
                log "dataname $dn -> {$got}"
            } else {
                log "dataname $dn -> ERR"
            }
        }
    }
    offset_repo_coords {
        lassign [fresh_model] surfs lines
        set tgt [lindex $surfs 1]
        catch {*createmark surfs 2 $tgt}
        trycmd "offset repo" {*offset_surfaces_and_modify surfaces 2 2 1 -12 2}
        *createmark points 1 all
        set pts [hm_getmark points 1]
        log "points after repo offset: [join $pts ,]"
        foreach pid {9 17} {
            foreach dn {x y z} {
                set got ""
                if {![catch {set got [hm_getvalue points id=$pid dataname=$dn]}]} {
                    log "point $pid $dn = $got"
                }
            }
        }
    }
    offset_docs_coords {
        lassign [fresh_model] surfs lines
        set tgt [lindex $surfs 1]
        catch {*createmark surfs 2 $tgt}
        trycmd "offset docs-cont" {*offset_surfaces_and_modify surfaces 2 0 1 -3 -12}
        *createmark points 1 all
        set pts [hm_getmark points 1]
        log "points after docs offset: [join $pts ,]"
        foreach pid {9 17} {
            foreach dn {x y z} {
                set got ""
                if {![catch {set got [hm_getvalue points id=$pid dataname=$dn]}]} {
                    log "point $pid $dn = $got"
                }
            }
        }
    }
    readonly {
        lassign [fresh_model] surfs lines
        trycmd "hm_getvalue comps dataname=surfaces" {hm_getvalue comps id=1 dataname=surfaces}
        trycmd "hm_getvalue comps dataname=surfs" {hm_getvalue comps id=1 dataname=surfs}
        trycmd "hm_getvalue surfs dataname=collector.id" {hm_getvalue surfs id=1 dataname=collector.id}
        trycmd "hm_getoption cleanup_tolerance" {hm_getoption cleanup_tolerance}
        trycmd "hm_getthickness comps 1" {hm_getthickness comps 1}
        trycmd "hm_getsurfaceedges 1" {hm_getsurfaceedges 1}
        trycmd "hm_getlinesfromsurface 1" {hm_getlinesfromsurface 1}
        trycmd "hm_getedgesfromsurface 1" {hm_getedgesfromsurface 1}
        trycmd "hm_getsurfacesfromedge 1" {hm_getsurfacesfromedge 1}
        trycmd "hm_getsurfacesfromline 1" {hm_getsurfacesfromline 1}
        trycmd "hm_linelength 1" {hm_linelength 1}
        trycmd "hm_getareaofsurface surfs 1" {hm_getareaofsurface surfs 1}
        trycmd "hm_info currentcomponent" {hm_info currentcomponent}
        trycmd "*currentcollector component dummy" {*currentcollector component dummy}
        trycmd "mark3 by-id createmark" {*createmark surfs 3 "by id" 1}
        trycmd "mark3 getmark" {hm_getmark surfs 3}
        trycmd "mark3 by-comp-id createmark" {*createmark surfs 3 "by comp id" 1}
        trycmd "mark5 by-id createmark" {*createmark surfs 5 "by id" 1}
        trycmd "list5 createlist" {*createlist lines 5 1}
        trycmd "hm_getlist lines 5" {hm_getlist lines 5}
    }
    default {
        log "unknown test: $test"
    }
}
log "===== TEST $test DONE ====="
close $chan
exit
