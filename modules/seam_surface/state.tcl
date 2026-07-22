namespace eval ::hmtoolkit::seam::state {}
namespace eval ::hmtoolkit::seam::transaction {}

proc ::hmtoolkit::seam::state::capture {} {
    set result [dict create current_component "" visible_components {} visibility_readable 0]
    foreach command {{hm_info currentcomponent} {hm_getcurrentcollector components}} {
        if {![catch {set value [eval $command]}] && $value ne ""} {
            dict set result current_component $value
            break
        }
    }
    set visible {}
    set readable 0
    foreach compId [::hmtoolkit::seam::entity::snapshot_ids comps] {
        foreach dataname {visible displayed} {
            if {![catch {set value [hm_getvalue comps id=$compId dataname=$dataname]}]} {
                set readable 1
                if {$value} { lappend visible $compId }
                break
            }
        }
    }
    dict set result visible_components $visible
    dict set result visibility_readable $readable
    return $result
}

proc ::hmtoolkit::seam::state::restore {state} {
    set warnings {}
    if {[dict get $state visibility_readable]} {
        set all [::hmtoolkit::seam::entity::snapshot_ids comps]
        catch {::hmtoolkit::seam::entity::mark comps 1 $all; *displaycollectorsbymark comps 1 off 1 1}
        set visible [dict get $state visible_components]
        if {[llength $visible] > 0} { catch {::hmtoolkit::seam::entity::mark comps 1 $visible; *displaycollectorsbymark comps 1 on 1 1} }
    } else {
        lappend warnings "HyperMesh 2019 did not expose a readable component visibility state; visibility was not forced."
    }
    set current [dict get $state current_component]
    if {$current ne ""} {
        if {[string is integer -strict $current]} { set current [::HWFlow::componentName $current] }
        if {$current ne ""} { catch {*currentcollector component $current} }
    }
    foreach type {lines surfs solids points comps} {
        foreach markId {1 2} { catch {*clearmark $type $markId} }
    }
    return $warnings
}

proc ::hmtoolkit::seam::transaction::run {label scriptBody} {
    variable ::hmtoolkit::seam::runtime
    set state [::hmtoolkit::seam::state::capture]
    set tempToken [::hmtoolkit::seam::temp::new_scope]
    set runtime(active_temp_token) $tempToken
    set historyStarted 0
    catch {hm_private_frwk enablehistoryfromtcl 1}
    if {![catch {*startnotehistorystate $label}]} { set historyStarted 1 }
    set code [catch {uplevel 1 $scriptBody} value options]
    # Cleanup belongs to the same undo unit as the geometry operation.
    catch {::hmtoolkit::seam::temp::cleanup $tempToken}
    if {$historyStarted} { catch {*endnotehistorystate $label} }
    catch {hm_private_frwk enablehistoryfromtcl 0}
    set runtime(active_temp_token) ""
    if {$code && $historyStarted} { catch {*undohistorystate 1} }
    set restoreWarnings [::hmtoolkit::seam::state::restore $state]
    if {$code} {
        set info ""
        if {[dict exists $options -errorinfo]} { set info [dict get $options -errorinfo] }
        set result [dict create success 0 error_code EXECUTION_FAILED message $value warnings $restoreWarnings error_info $info]
        ::hmtoolkit::seam::log::result $result
        return $result
    }
    if {![dict exists $value success]} { set value [dict create success 1 value $value warnings {}] }
    if {[dict exists $value warnings]} {
        dict set value warnings [concat [dict get $value warnings] $restoreWarnings]
    } else {
        dict set value warnings $restoreWarnings
    }
    ::hmtoolkit::seam::log::result $value
    return $value
}
