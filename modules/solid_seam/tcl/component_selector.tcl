proc ::SolidSeam::selectComponents {} {
    variable selectedComponentIds
    catch {*clearmark components 1}; catch {*clearmark comps 1}
    set prompt [::SolidSeam::txt "选择两个或更多 Solid/Shell Components" "Select two or more Solid/Shell Components"]
    set selected [::HWFlow::nativeMarkPanel components 1 $prompt]
    if {[llength $selected] == 0} { catch {set selected [hm_getmark comps 1]} }
    set selectedComponentIds [lsort -integer -unique $selected]
    ::SolidSeam::log INFO "selected_components=$selectedComponentIds"
    return $selectedComponentIds
}
