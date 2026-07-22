proc ::hmtoolkit::seam::open_panel {} {
    set context [::hmtoolkit::seam::selector::capture_preselection]
    return [::hmtoolkit::seam::ui::show 0 $context]
}

proc ::hmtoolkit::seam::open_settings {} {
    return [::hmtoolkit::seam::ui::show 1]
}

# Existing toolkit module callbacks remain stable while using the new module.
namespace eval ::SeamSurf {}
proc ::SeamSurf::run {} { return [::hmtoolkit::seam::open_panel] }
proc ::SeamSurf::runAction {} { return [::hmtoolkit::seam::open_panel] }
proc ::SeamSurf::runShortcut {} { return [::hmtoolkit::seam::ui::run_shortcut] }
proc ::SeamSurf::runSettings {} { return [::hmtoolkit::seam::open_settings] }
