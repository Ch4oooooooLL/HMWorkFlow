proc ::RB2Bolt::runCreateFromSelection {} {
    set elemIds [::RB2Bolt::selectedElementIdsInteractive]
    if {[llength $elemIds] == 0} {
        ::RB2Bolt::msg "No RBE2 candidate elements were found."
        return
    }

    set progressOpened 0
    if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
        set progressOpened [::HWFlow::progressOpen "RBE2 Bolt Connector" "Preparing Python analysis..." 0]
    }
    set code [catch {
        set run [::RB2Bolt::runPythonPlanning $elemIds 8.0 65.0]
        set stat [::RB2Bolt::executePythonPlans [dict get $run payload] 65.0 96.0]
    } err opts]
    ::HybridCore::closeLog
    ::RB2Bolt::clearSelectionMarks
    if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose [expr {$code ? "RBE2 Bolt Connector failed." : "RBE2 Bolt Connector finished."}] 100.0}
    }
    if {$code} {
        return -options $opts $err
    }
    ::RB2Bolt::msg "Python bolt planning finished: pairs=[dict get $stat pair_count], created=[dict get $stat created], existing=[dict get $stat skipped_existing], failed=[dict get $stat skipped]"
    return $stat
}
