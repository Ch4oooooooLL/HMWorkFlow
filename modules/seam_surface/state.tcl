namespace eval ::hmtoolkit::seam::state {}
namespace eval ::hmtoolkit::seam::transaction {}

proc ::hmtoolkit::seam::state::capture {} {
    # Only components that exist before the transaction may be restored later.
    # Newly created seam components must never be hidden by the restore step.
    set existing [::hmtoolkit::seam::entity::snapshot_ids comps]
    set display [dict create]
    foreach compId $existing {
        set geometry [::hmtoolkit::seam::native::geometry_visible $compId]
        set elements [::hmtoolkit::seam::native::elements_visible $compId]
        if {$geometry ne "" || $elements ne ""} {
            dict set display $compId [list $geometry $elements]
        }
    }
    set result [dict create \
        current_component [::hmtoolkit::seam::native::current_component] \
        existing_components $existing \
        display_states $display]
    return $result
}

proc ::hmtoolkit::seam::state::restore {state} {
    set warnings {}
    set display [dict get $state display_states]
    # Restore the geometry/elements display state only for components that
    # already existed when the transaction started. Components created by the
    # operation are deliberately left untouched.
    if {[dict size $display] > 0} {
        foreach compId [dict keys $display] {
            if {![::hmtoolkit::seam::entity::exists comps $compId]} { continue }
            lassign [dict get $display $compId] geometry elements
            if {$geometry ne ""} {
                catch {
                    ::hmtoolkit::seam::entity::mark comps 1 [list $compId]
                    *displaycollectorsbymark comps 1 [expr {$geometry ? "on" : "off"}] 1 0
                }
            }
            if {$elements ne ""} {
                catch {
                    ::hmtoolkit::seam::entity::mark comps 1 [list $compId]
                    *displaycollectorsbymark comps 1 [expr {$elements ? "on" : "off"}] 0 1
                }
            }
        }
    } else {
        lappend warnings "Component visibility state was not readable on this profile; visibility was not forced."
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
    ::hmtoolkit::seam::native::history_from_tcl 1
    if {![catch {*startnotehistorystate $label}]} { set historyStarted 1 }
    set code [catch {uplevel 1 $scriptBody} value options]
    set preserve [expr {[::hmtoolkit::seam::config::get diagnostic_preserve_failed_geometry] > 0}]
    if {!$code || !$preserve} {
        # Cleanup belongs to the same undo unit as the geometry operation.
        catch {::hmtoolkit::seam::temp::cleanup $tempToken}
    }
    if {$historyStarted} { catch {*endnotehistorystate $label} }
    ::hmtoolkit::seam::native::history_from_tcl 0
    set runtime(active_temp_token) ""
    if {$code && $historyStarted && !$preserve} { catch {*undohistorystate 1} }
    set restoreWarnings [::hmtoolkit::seam::state::restore $state]
    if {$code && $preserve} {
        lappend restoreWarnings \
            "diagnostic_preserve_failed_geometry=1: rollback skipped, temp scope $tempToken was kept for inspection"
    }
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
