proc ::SolidSeam::selectComponents {} {
    variable selectedComponentIds; variable primaryComponentIds; variable secondaryComponentIds
    catch {*clearmark components 1}; catch {*clearmark comps 1}
    # Component order is part of the realization contract: weld location
    # nodes always come from the FIRST component; the SECOND component is
    # geometry/link reference only. A multi-select mark cannot express click
    # order reliably, so collect the two roles in separate native panels.
    set prompt [::SolidSeam::txt "选择第一个 Component（焊缝节点来源）" "Select the first component (weld-node source)"]
    set primaryComponentIds [lsort -integer -unique [::HWFlow::nativeMarkPanel components 1 $prompt]]
    if {[llength $primaryComponentIds] == 0} { catch {set primaryComponentIds [lsort -integer -unique [hm_getmark comps 1]]} }
    if {[llength $primaryComponentIds] == 0} { return {} }
    if {[llength $primaryComponentIds] != 1} { error [::SolidSeam::txt "第一次只能选择一个 Component；焊缝节点将取自该组件。" "Select exactly one first component; weld nodes come from it."] }

    set secondaryComponentIds {}
    catch {*clearmark components 2}; catch {*clearmark comps 2}
    set prompt [::SolidSeam::txt "选择第二个 Component（几何参照与连接目标）" "Select the second component (geometry/link target)"]
    set secondaryComponentIds [lsort -integer -unique [::HWFlow::nativeMarkPanel components 2 $prompt]]
    if {[llength $secondaryComponentIds] == 0} { catch {set secondaryComponentIds [lsort -integer -unique [hm_getmark comps 2]]} }
    if {[llength $secondaryComponentIds] == 0} { return {} }
    if {[llength $secondaryComponentIds] != 1} { error [::SolidSeam::txt "第二次只能选择一个 Component。" "Select exactly one component in the second panel."] }
    if {[lindex $secondaryComponentIds 0] == [lindex $primaryComponentIds 0]} { error [::SolidSeam::txt "两次不能选择同一个 Component。" "The two selections must be different components."] }

    set selectedComponentIds [concat $primaryComponentIds $secondaryComponentIds]
    ::SolidSeam::log INFO "primary_components=$primaryComponentIds secondary_components=$secondaryComponentIds"
    return $selectedComponentIds
}
