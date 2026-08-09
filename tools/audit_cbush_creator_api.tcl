# Audit probe A: API surface used by modules/cbush_creator.tcl.
# Checks command existence, hm_getvalue datanames on nodes/elems, createmark
# selectors, hm_nodevalue, hm_latestentityid, cleanup commands.
# Run headless:
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_cbush_creator_api.tcl
# Results: runtime/audit_cbush_api_<version>.log (KEY=VALUE, ASCII only).

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_cbush_api_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}
proc exists {name} {
    expr {[info commands $name] ne ""}
}
proc tryResult {label script} {
    set code [catch {uplevel 1 $script} result]
    if {$code} {
        P $label "ERROR: $result"
    } else {
        P $label "OK: $result"
    }
    return $code
}

P "VERSION" $version

# --- 1. Command existence --------------------------------------------------
foreach name {
    *springos *spring *springcreate *createspring *elementtype
    *createnode *createmark *clearmark *deletemark *setvalue
    *currentcollector *numbersmark *createmarkpanel *createentity
    *createelement *createlist *collectorcreateonly *setprofile
    hm_getvalue hm_getmark hm_nodevalue hm_latestentityid
    hm_entityrecorder hm_redraw hm_info
} {
    P "EXISTS $name" [exists $name]
}
foreach name {*springos *spring *elementtype *createnode *setvalue *numbersmark} {
    if {[exists $name]} {
        catch {P "ARGS $name" [info args $name]}
        catch {P "ARGLIST $name" [info arglist $name]}
    }
}

# --- 2. Profile ------------------------------------------------------------
tryResult "PROFILE_QUERY" {hm_info -appinfo PROFILE}
catch {*setprofile OptiStruct}
tryResult "PROFILE_AFTER_SET" {hm_info -appinfo PROFILE}

# --- 3. Fixture: 4 nodes + 1 quad in PROBE_COMP ----------------------------
catch {*clearmark nodes 1}
catch {*clearmark elems 1}
if {[catch {*createentity comps includeid=0 name=PROBE_COMP}]} {
    catch {*createentity components includeid=0 name=PROBE_COMP}
}
catch {*currentcollector component PROBE_COMP}
catch {*currentcollector components PROBE_COMP}

set nids {}
set prevNode [hm_latestentityid nodes]
foreach pt {{0 0 0} {10 0 0} {10 10 0} {0 10 0}} {
    set code [catch {eval *createnode $pt 0 0 0} err]
    P "CREATENODE_6ARG" [expr {$code ? "ERROR: $err" : "OK"}]
    set latest [hm_latestentityid nodes]
    lappend nids $latest
}
set srcNode [lindex $nids 0]
P "NODE_IDS" [join $nids { }]
P "LATESTENTITYID_NODES_BEFORE" $prevNode
P "LATESTENTITYID_NODES_AFTER" [hm_latestentityid nodes]

# hm_latestentityid semantics: create a node with a larger id pool? Just report max vs latest.
catch {*createmark nodes 1 all}
P "LATEST_VS_MAX" "[hm_latestentityid nodes]/[lindex [lsort -integer [hm_getmark nodes 1]] end]"

eval *createlist nodes 1 $nids
tryResult "CREATE_QUAD" {*createelement 104 1 1 1}
catch {*createmark elems 1 all}
set eids [hm_getmark elems 1]
P "ELEM_IDS" [join $eids { }]
set srcElem [lindex $eids 0]

# --- 4. hm_getvalue datanames on nodes -------------------------------------
foreach dn {x y z xyz collector.id component.id comp.id collector component elems elements} {
    set code [catch {set v [hm_getvalue nodes id=$srcNode dataname=$dn]} err]
    if {$code} {
        P "NODE_DATANAME $dn" "ERROR: $err"
    } else {
        P "NODE_DATANAME $dn" "OK: $v"
    }
}

# --- 5. hm_getvalue datanames on elems -------------------------------------
foreach dn {config type collector collector.id component.id comp.id component STATUS CID property.id} {
    set code [catch {set v [hm_getvalue elems id=$srcElem dataname=$dn]} err]
    if {$code} {
        P "ELEM_DATANAME $dn" "ERROR: $err"
    } else {
        P "ELEM_DATANAME $dn" "OK: $v"
    }
}

# --- 6. hm_nodevalue --------------------------------------------------------
tryResult "HM_NODEVALUE" {hm_nodevalue $srcNode}

# --- 7. createmark selectors -------------------------------------------------
foreach sel {"by node id" "by node" "by nodes" "by id only"} {
    catch {*clearmark elems 2}
    if {[catch {eval *createmark elems 2 [list $sel $srcNode]} err]} {
        P "CREATEMARK_ELEMS $sel" "ERROR: $err"
    } else {
        catch {set ids [hm_getmark elems 2]}
        P "CREATEMARK_ELEMS $sel" "OK: [llength $ids]"
    }
    catch {*clearmark elems 2}
}
catch {*clearmark nodes 2}
tryResult "CREATEMARK_NODES_BYIDONLY" {*createmark nodes 2 "by id only" $srcNode}
catch {set ids [hm_getmark nodes 2]}
P "CREATEMARK_NODES_BYIDONLY_COUNT" [llength $ids]
catch {*clearmark nodes 2}

# --- 8. numbersmark / entityrecorder / redraw -------------------------------
catch {*clearmark elems 1}
catch {*createmark elems 1 "by id only" $srcElem}
tryResult "NUMBERSMARK_ELEMS" {*numbersmark elems 1 1}
tryResult "NUMBERSMARK_ELEMS_OFF" {*numbersmark elems 1 0}
tryResult "ENTITYRECORDER_ELEMS_OFF" {hm_entityrecorder elems off}
tryResult "HM_REDRAW" {hm_redraw}
catch {*clearmark elems 1}

# --- 9. cleanup semantics: delete node -> attached element also gone? --------
catch {*clearmark nodes 2}
tryResult "CREATEMARK_NODES_CLEANUP" {*createmark nodes 2 "by id only" $srcNode}
set before [llength [hm_getmark elems 1]]
catch {*createmark elems 1 all}
set elemsBeforeDelete [llength [hm_getmark elems 1]]
catch {*clearmark elems 1}
tryResult "DELETEMARK_NODES" {*deletemark nodes 2}
catch {*createmark elems 1 all}
P "ELEMS_AFTER_NODE_DELETE" [llength [hm_getmark elems 1]]
P "ELEMS_BEFORE_NODE_DELETE" $elemsBeforeDelete
catch {*clearmark nodes 2}
catch {*clearmark elems 1}

close $channel
exit 0
