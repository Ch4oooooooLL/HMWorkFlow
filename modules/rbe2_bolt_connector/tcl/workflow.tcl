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
    if {$code} {
        catch {::HybridCore::log ERROR "RBE2 Bolt Connector failed error={$err}"}
    }
    ::HybridCore::closeLog
    ::RB2Bolt::clearSelectionMarks
    if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose [expr {$code ? "RBE2 Bolt Connector failed." : "RBE2 Bolt Connector finished."}] 100.0}
    }
    if {$code} {
        set diagnostic "$err\n\nThe task workspace is retained under runtime/tasks for debugging. Inspect selection.fem, bolt_import.fem, request.json, and operation.log when present."
        ::RB2Bolt::msg $diagnostic
        catch {tk_messageBox -icon error -title "RBE2 Bolt Connector" -message $diagnostic}
        dict set opts -errorinfo "$diagnostic\n[dict get $opts -errorinfo]"
        return -options $opts $diagnostic
    }
    ::RB2Bolt::msg "Python bolt planning finished: pairs=[dict get $stat pair_count], created=[dict get $stat created], existing=[dict get $stat skipped_existing], failed=[dict get $stat skipped]"
    return $stat
}
