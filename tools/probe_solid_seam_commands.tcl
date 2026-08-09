# Probe the real CE_* connector command surface on the installed HyperMesh
# build, then exercise the official seam connector creation chain on a small
# two-plate fixture.  Run headless with:
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/probe_solid_seam_commands.tcl
#
# Results are written to runtime/solid_seam_probe_<version>.log as KEY=VALUE
# lines (English only, no non-ASCII so the file parses on any code page).

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "solid_seam_probe_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}

proc exists {name} {
    expr {[info commands $name] ne ""}
}

# --- 1. Command existence ------------------------------------------------
set ceCommands [lsort [info commands *CE_*]]
P "CE_COMMAND_COUNT" [llength $ceCommands]
P "CE_COMMANDS" [join $ceCommands { }]
foreach name {
    hm_ce_state hm_ce_info hm_ce_detailget hm_ce_getlinkentities
    *markdistance *CE_Realize *CE_DetailSetIntByMark *CE_DetailSetDoubleByMark
} {
    P "EXISTS $name" [expr {[info commands $name] ne ""}]
}

# --- 2. Two-plate fixture (T-style: horizontal plate A + vertical plate B
#        sharing the x=20 node line) ---------------------------------------
namespace eval ::Probe {}
proc ::Probe::component {name color} {
    *collectorcreateonly components $name "" $color
    set id [hm_getvalue comps name=$name dataname=id]
    *currentcollector component $name
    return $id
}
proc ::Probe::node {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
proc ::Probe::quad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    *createmark elems 1 -1
    return [lindex [hm_getmark elems 1] 0]
}

set compA [::Probe::component PROBE_PLATE_A 1]
set compB [::Probe::component PROBE_PLATE_B 2]

# Plate A: horizontal, z=0, x/y in {0,10,20}
array set na {}
foreach x {0 10 20} {
    foreach y {0 10 20} {
        set na($x,$y) [::Probe::node $x $y 0]
    }
}
foreach x0 {0 10} x1 {10 20} {
    foreach y0 {0 10} y1 {10 20} {
        ::Probe::quad [list $na($x0,$y0) $na($x1,$y0) $na($x1,$y1) $na($x0,$y1)]
    }
}

# Plate B: vertical, x=20 plane, y in {0,10,20}, z in {10,20}
array set nb {}
foreach y {0 10 20} {
    foreach z {10 20} {
        set nb($y,$z) [::Probe::node 20 $y $z]
    }
}
foreach y0 {0 10} y1 {10 20} {
    set nb0 [::Probe::node 20 $y0 10]
    set nb1 [::Probe::node 20 $y1 10]
    set nb2 [::Probe::node 20 $y1 20]
    set nb3 [::Probe::node 20 $y0 20]
    ::Probe::quad [list $nb0 $nb1 $nb2 $nb3]
}

catch {*clearmark nodes 1}
*createmark nodes 1 all
catch {*clearmark elems 1}
*createmark elems 1 all
P "FIXTURE_NODES_TOTAL" [llength [hm_getmark nodes 1]]
P "FIXTURE_ELEMS_TOTAL" [llength [hm_getmark elems 1]]

# --- 3. *markdistance semantics (junction nodes of the two plates) --------
# The shared line is x=20, z=0, y in {0,10,20}; plate A nodes there are
# within 0.5 of plate B's x=20 nodes.
catch {*clearmark nodes 1}
catch {*clearmark nodes 2}
*createmark nodes 1 "by comp" $compA
*createmark nodes 2 "by comp" $compB
P "MARKDISTANCE_BEFORE" "[llength [hm_getmark nodes 1]]/[llength [hm_getmark nodes 2]]"
if {[catch {*markdistance nodes 1 nodes 2 1.0} markDistanceError]} {
    P "MARKDISTANCE_ERROR" $markDistanceError
} else {
    P "MARKDISTANCE_AFTER" [llength [hm_getmark nodes 1]]
}

# --- 4. Official seam creation chain -------------------------------------
# Mirror the Altair MetadataToCAE seam usage:
#   *createmark nodes 1 <junction nodes>
#   *createmark comps 2 <plate A> <plate B>
#   *createstringarray N <options>
#   *CE_ConnectorCreateByMark nodes 1 "seam" 2 comps 2 1 N
set junctionNodes [list $na(20,0) $na(20,10) $na(20,20)]
catch {*clearmark nodes 1}
eval *createmark nodes 1 $junctionNodes
catch {*clearmark comps 2}
eval *createmark comps 2 $compA $compB

set seamOptions [list \
    "link_elems_geom=elems" \
    "link_rule=now" \
    "line_spacing=6.000000" \
    "line_density=0" \
    "seam_area_group=2" \
    "ce_fedepth=6.000000" \
    "ce_fe_height=5.000000" \
    "ce_fe_capangle=65.000000" \
    "ce_fe_runoffangle=10.000000" \
    "ce_fe_sharpcorner=0" \
    "ce_extralinknum=0" \
    "ce_hexaoffsetcheck=1" \
]
eval *createstringarray [llength $seamOptions] $seamOptions

if {[catch {
    *CE_ConnectorCreateByMark nodes 1 "seam" 2 comps 2 1 [llength $seamOptions]
} createError createOptions]} {
    P "CREATE_ERROR" $createError
} else {
    P "CREATE_OK" 1
    *createmark connectors 1 all
    set connectorIds [hm_getmark connectors 1]
    P "CONNECTORS_TOTAL" [llength $connectorIds]
    foreach connectorId $connectorIds {
        set state UNKNOWN
        catch {set state [hm_ce_state $connectorId]}
        P "CONNECTOR $connectorId STATE" $state
        catch {
            P "CONNECTOR $connectorId TYPE" [hm_ce_info $connectorId type]
            P "CONNECTOR $connectorId LINKS" [join [hm_ce_getlinkentities $connectorId comps] { }]
        }
    }

    # Set the FE config/type (125 = penta (mig), filter seam) and realize.
    catch {*clearmark connectors 1}
    eval *createmark connectors 1 $connectorIds
    if {[catch {*CE_DetailSetIntByMark 1 "ce_configval" 125 0 0} cfgErr]} { P "SET_CONFIGVAL_ERROR" $cfgErr }
    if {[catch {*CE_DetailSetIntByMark 1 "ce_fetype" 125 0 0} typeErr]} { P "SET_FETYPE_ERROR" $typeErr }
    if {[catch {*CE_Realize 1} realizeErr]} {
        P "REALIZE_ERROR" $realizeErr
    } else {
        P "REALIZE_OK" 1
        catch {*clearmark elems 1}
        *createmark elems 1 all
        set allElems [hm_getmark elems 1]
        set penta6 {}; set rbe3 {}
        foreach elemId $allElems {
            if {[catch {set config [hm_getvalue elems id=$elemId dataname=config]}]} { continue }
            if {[string trim $config] eq "206"} { lappend penta6 $elemId }
            if {[string trim $config] eq "56"} { lappend rbe3 $elemId }
        }
        P "PENTA6_COUNT" [llength $penta6]
        P "RBE3_COUNT" [llength $rbe3]
        catch {*clearmark connectors 1}
        *createmark connectors 1 all
        foreach connectorId [hm_getmark connectors 1] {
            set state UNKNOWN
            catch {set state [hm_ce_state $connectorId]}
            P "CONNECTOR_AFTER $connectorId STATE" $state
        }
    }
}

close $channel
puts "probe done: $reportPath"
exit 0
