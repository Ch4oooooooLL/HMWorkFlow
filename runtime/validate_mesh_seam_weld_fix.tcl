set reportPath {C:/Users/Chao/Desktop/DOC/CODE/HW/runtime/validate_mesh_seam_weld_fix.log}
set report [open $reportPath w]
fconfigure $report -encoding utf-8 -translation lf
set code [catch {
    source {C:/Users/Chao/Desktop/DOC/CODE/HW/modules/mesh_seam_weld.tcl}
    ::MeshSeamWeld::resetRunCaches
    set sourceNodes {40891 40890 40889 40888 40887 40886 40885 40884 40883 40882 40921 40920 40919 40918 40917 40916 40915 40914 40913 40912 40911 40910 40909 40908 40907 40906 40905 40904 40903 40902 40901 40900 40899 40898 40897 40896 40895 40894 40893 40892}
    set job [lindex [::MeshSeamWeld::prepareWeldJobs [list $sourceNodes] {2}] 0]
    set result [::MeshSeamWeld::processWeldPath $sourceNodes {2} 1 0 1 1 \
        [dict get $job source_component_ids] [dict get $job seam_component] [dict get $job target_elements]]
    puts $report "SUCCESS"
    puts $report $result
} err opts]
if {$code} {
    puts $report "ERROR: $err"
    if {[dict exists $opts -errorinfo]} { puts $report [dict get $opts -errorinfo] }
}
close $report
