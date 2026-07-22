# Compatibility names only. The previous implementations were removed; every
# entry now delegates to the single selector/executor pipeline.
namespace eval ::altair {}
namespace eval ::altair::pmgr {}
namespace eval ::altair::pmgr::pm_common {}

set ::hmtoolkit_seam_legacy_map {
    Create_seam_surface_T_path create_t_path
    Create_seam_surface_T_list create_t_list
    Create_seam_surface_L_surf create_l_surface
    Create_seam_surface_L_list create_l_list
    Create_seam_combine combine_surfaces
    Create_seam_connect connect_edges
    Create_seam_project project_lines
    Create_seam_dist_points distribute_points
    Create_seam_replace replace_point
    Create_seam_extend extend_surface
    Del_seam_surf delete_seam_surface
    Split_surface split_surface
}
foreach {::hmtoolkit_seam_old ::hmtoolkit_seam_new} $::hmtoolkit_seam_legacy_map {
    proc ::$::hmtoolkit_seam_old {} [format {return [::hmtoolkit::seam::interactive::%s]} $::hmtoolkit_seam_new]
    proc ::altair::pmgr::pm_common::$::hmtoolkit_seam_old {} [format {return [::hmtoolkit::seam::interactive::%s]} $::hmtoolkit_seam_new]
}
unset ::hmtoolkit_seam_old
unset ::hmtoolkit_seam_new
unset ::hmtoolkit_seam_legacy_map

