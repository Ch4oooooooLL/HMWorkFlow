proc ::SolidSeam::selectComponents {} {
    variable selectedComponentIds; variable primaryComponentIds; variable secondaryComponentIds
    catch {*clearmark components 1}; catch {*clearmark comps 1}
    set prompt [::SolidSeam::txt "选择待创建实体焊缝的 Components" "Select components for solid seam creation"]
    set primaryComponentIds [lsort -integer -unique [::HWFlow::nativeMarkPanel components 1 $prompt]]
    if {[llength $primaryComponentIds] == 0} { catch {set primaryComponentIds [lsort -integer -unique [hm_getmark comps 1]]} }
    if {[llength $primaryComponentIds] == 0} { return {} }
    set secondaryComponentIds {}
    if {[llength $primaryComponentIds] == 1} {
        catch {*clearmark components 2}; catch {*clearmark comps 2}
        set prompt [::SolidSeam::txt "选择需要连接上的另一个 Component" "Select the second component to connect"]
        set secondaryComponentIds [lsort -integer -unique [::HWFlow::nativeMarkPanel components 2 $prompt]]
        if {[llength $secondaryComponentIds] == 0} { catch {set secondaryComponentIds [lsort -integer -unique [hm_getmark comps 2]]} }
        if {[llength $secondaryComponentIds] == 0} { return {} }
        if {[llength $secondaryComponentIds] != 1} { error [::SolidSeam::txt "第二次只能选择一个 Component。" "Select exactly one component in the second panel."] }
        if {[lindex $secondaryComponentIds 0] == [lindex $primaryComponentIds 0]} { error [::SolidSeam::txt "两次不能选择同一个 Component。" "The two selections must be different components."] }
    }
    set selectedComponentIds [concat $primaryComponentIds $secondaryComponentIds]
    ::SolidSeam::log INFO "primary_components=$primaryComponentIds secondary_components=$secondaryComponentIds"
    return $selectedComponentIds
}
