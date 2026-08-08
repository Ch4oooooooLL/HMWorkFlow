# ============================================================================
# diagnose.tcl - Geometry seam command diagnostic
#
# Probes every HyperMesh Tcl command the geometry seam module relies on and
# prints a compact report that fits a phone photo. Read-only commands are
# exercised with safe arguments; destructive / panel commands are only
# checked for existence so the diagnostic never modifies the user model.
# ============================================================================

namespace eval ::hmtoolkit::seam::diagnose {}

# ---------------------------------------------------------------------------
# Existence check without glob interpretation (command names may start with *).
# ---------------------------------------------------------------------------
proc ::hmtoolkit::seam::diagnose::exists {name} {
    set pattern [string map {* {\*} ? {\?} [ {\[} ] {\]} \\ {\\\\}} $name]
    return [expr {[llength [info commands $pattern]] > 0}]
}

# ---------------------------------------------------------------------------
# One probe row. mode: probe (safe call) or exists (destructive/panel only).
# ---------------------------------------------------------------------------
proc ::hmtoolkit::seam::diagnose::probe_row {name args mode} {
    if {![::hmtoolkit::seam::diagnose::exists $name]} {
        return [format "%-4s %-34s %s" "MISS" $name "command not found"]
    }
    if {$mode eq "exists"} {
        return [format "%-4s %-34s %s" "EXIST" $name "not probed (side effects)"]
    }
    set code [catch {uplevel #0 [list $name {*}$args]} value options]
    if {$code} {
        set detail [string range $value 0 34]
        return [format "%-4s %-34s %s" "ERR" $name "probe error: $detail"]
    }
    if {$value eq ""} {
        return [format "%-4s %-34s %s" "OK" $name "returned empty"]
    }
    set detail [string range $value 0 30]
    return [format "%-4s %-34s %s" "OK" $name "returned: $detail"]
}

# ---------------------------------------------------------------------------
# Run every probe and return the report text.
# ---------------------------------------------------------------------------
proc ::hmtoolkit::seam::diagnose::run {} {
    set rows {}
    lappend rows "===== GEOMETRY SEAM DIAGNOSTIC ====="
    set version ""
    if {[::hmtoolkit::seam::diagnose::exists hm_info]} {
        catch {set version [hm_info -appinfo VERSION]}
    }
    lappend rows "HyperMesh: $version   Module: [set ::hmtoolkit::seam::VERSION]"
    lappend rows "Time: [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
    lappend rows "--- read-only probes ---"

    # Read-only queries, exercised with harmless arguments.
    set readOnly {
        {hm_getmark {surfs 5}}
        {hm_getvalue {comps id=1 dataname=name}}
        {hm_getvalue {comps id=1 dataname=surfaces}}
        {hm_getvalue {comps id=1 dataname=surfs}}
        {hm_getvalue {surfs id=1 dataname=collector.id}}
        {hm_getcurrentcollector {components}}
        {hm_info {-appinfo VERSION}}
        {hm_info {currentcomponent}}
        {hm_getoption {cleanup_tolerance}}
        {hm_getthickness {comps 1}}
        {hm_getsurfaceedges {1}}
        {hm_getlinesfromsurface {1}}
        {hm_getedgesfromsurface {1}}
        {hm_getsurfacesfromedge {1}}
        {hm_getsurfacesfromline {1}}
        {hm_getcoordinatesofpointsonline {1 0 0.5 1}}
        {hm_findclosestpointonsurface {0 0 0 1}}
        {hm_getcoordinatesfromnearestsurface {0 0 0 1}}
        {hm_linelength {1}}
        {hm_getareaofsurface {surfs 1}}
        {hm_getvolumeofsolid {solids 1}}
        {*clearmark {surfs 5}}
        {*createmark {surfs 5 all}}
        {*createlist {lines 5}}
        {hm_getlist {lines 5}}
    }
    set readOk 0; set readFail 0
    foreach row $readOnly {
        set line [::hmtoolkit::seam::diagnose::probe_row \
            [lindex $row 0] [lindex $row 1] probe]
        lappend rows $line
        if {[string match "OK*" $line]} { incr readOk } else { incr readFail }
    }

    lappend rows "--- mark slot probes (createmark+getmark+clearmark) ---"
    set markOk 0; set markBad 0
    foreach slot {1 2 3 5 9 10 20 99} {
        set ok 1
        set detail ""
        if {[catch {*createmark surfs $slot all}]} { set ok 0; set detail "createmark failed" }
        if {$ok && [catch {set got [hm_getmark surfs $slot]}]} { set ok 0; set detail "getmark failed" }
        if {$ok && [llength $got] == 0} { set detail "empty model mark (allowed)" }
        catch {*clearmark surfs $slot}
        set tag [expr {$ok ? "OK" : "ERR"}]
        if {$ok} { incr markOk } else { incr markBad }
        lappend rows [format "%-4s %-34s %s" $tag "mark slot $slot" $detail]
    }

    lappend rows "--- existence only (destructive / panels / state) ---"
    set existOnly {
        *createmarkpanel *createlistpanel *createlistbypathpanel *editmarkpanel
        *currentcollector *startnotehistorystate *endnotehistorystate *undohistorystate
        hm_private_frwk *setoption *createentity *collectorcreateonly *setvalue
        *assemblymodifyhierarchy *assemblymodify *displaycollectorsbymark
        *displaycollector *displaycollectorwithfilter *displaycollectorsallbymark
        *showentity *marksuppressactive *marksuppressoutput
        *connect_surfaces_11 *linearsurfacebetweenlines *multi_surfs_lines_merge
        *selfstitchcombine *surfacemarksplitwithlines *duplicatemark
        *solid_offset_from_surfs *boolean_merge_solids *trim_solids_by_surfaces
        *deletesolidswithelems *offset_surfaces_and_modify *projectpointstoedges
        *verticescombine *edgesmarkaddpoints *edgesmarkuntrim *deletemark *movemark
        hm_errormessage hm_redraw
    }
    set existOk 0; set existMiss 0
    foreach name $existOnly {
        set line [::hmtoolkit::seam::diagnose::probe_row $name {} exists]
        lappend rows $line
        if {[string match "EXIST*" $line]} { incr existOk } else { incr existMiss }
    }

    set total [expr {[llength $readOnly] + [llength $existOnly] + [llength {1 2 3 5 9 10 20 99}]}]
    set ok [expr {$readOk + $existOk + $markOk}]
    lappend rows [format "===== %s/%s available, %s missing/error =====" $ok $total [expr {$total-$ok}]]
    return [join $rows "\n"]
}

# ---------------------------------------------------------------------------
# Persist the report next to the session logs and return its path.
# ---------------------------------------------------------------------------
proc ::hmtoolkit::seam::diagnose::save {report} {
    set dir [file join [file dirname [::HWFlow::configDir]] "logs"]
    catch {file mkdir $dir}
    set path [file join $dir "geometry_seam_diagnose_[clock format [clock seconds] -format %Y%m%d_%H%M%S].log"]
    if {![catch {set chan [open $path w]}]} {
        fconfigure $chan -encoding utf-8 -translation lf
        puts -nonewline $chan $report
        close $chan
    }
    return $path
}

# ---------------------------------------------------------------------------
# Compact Tk window sized for a phone photo, plus console echo.
# ---------------------------------------------------------------------------
proc ::hmtoolkit::seam::diagnose::show_report {report} {
    variable window .geometry_seam_diagnose
    catch {destroy $window}
    ::HWFlow::createTopLevel $window diagnostic
    wm title $window [::HWFlow::windowTitle \
        [::HWFlow::txt "几何焊缝诊断报告" "Geometry Seam Diagnostic"] \
        "Geometry Seam Diagnostic"]
    wm resizable $window 0 0
    frame $window.body -padx 8 -pady 6
    pack $window.body -fill both -expand 1
    text $window.body.text -width 68 -height 30 -wrap none -font [::HWFlow::uiFont fixed] \
        -state disabled \
        -background [::HWFlow::uiColors inputBg] \
        -foreground [::HWFlow::uiColors inputFg]
    scrollbar $window.body.scroll -orient vertical -command "$window.body.text yview"
    $window.body.text configure -yscrollcommand "$window.body.scroll set"
    grid $window.body.text -row 0 -column 0 -sticky nsew
    grid $window.body.scroll -row 0 -column 1 -sticky ns
    $window.body.text configure -state normal
    $window.body.text insert end $report
    $window.body.text configure -state disabled
    frame $window.buttons -padx 8 -pady 6
    pack $window.buttons -fill x
    button $window.buttons.close -text [::HWFlow::txt "关闭" "Close"] \
        -command "catch {destroy $window}"
    pack $window.buttons.close -side right -padx 4
    ::hmtoolkit::seam::ui::center $window
    raise $window
    return $window
}

proc ::hmtoolkit::seam::diagnose::run_and_show {} {
    ::hmtoolkit::seam::ui::set_status [::HWFlow::txt "正在探测命令……" "Probing commands..."]
    catch {update idletasks}
    set report [::hmtoolkit::seam::diagnose::run]
    set path [::hmtoolkit::seam::diagnose::save $report]
    catch {puts $report}
    ::hmtoolkit::seam::diagnose::show_report $report
    ::hmtoolkit::seam::ui::set_status \
        [::HWFlow::txt "诊断完成，报告已保存：$path" "Diagnostic complete, report saved: $path"]
    return $report
}
