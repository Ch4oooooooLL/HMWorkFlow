# ============================================================================
# washer_test.tcl - standalone first-phase entry for the Mesh Add Washer tool
#
# Run in HyperMesh 2019/2022 via File > Run > Tcl/Tk Script, then pick ONE
# node on a hole free edge. The tool finds the component, traces the closed
# free-edge hole loop, reports the current hole-ring node count, and calls
# the native *add_multi_washer_elements with the fixed configuration below.
#
# Density-reduction verification matrix (first-phase acceptance):
#   8 -> 12, 12 -> 12, 16 -> 12, 16 -> 8
# Adjust ::WasherTool::holeDensity / ::WasherTool::layerWidths in
# modules/mesh_add_washer.tcl between runs and compare the reported
# "old -> new" density in the result dialog and hm command stream.
# ============================================================================

set washerTestDir [file dirname [file normalize [info script]]]
source -encoding utf-8 [file join $washerTestDir "modules" "mesh_add_washer.tcl"]
::WasherTool::run
