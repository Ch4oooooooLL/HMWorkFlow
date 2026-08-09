# Audit probe: RBE2/RBE3 creation, component operations, display commands,
# query functions, hm_getvalue datanames, and the feoutput/feinput path used
# by the shell_washer_hole_rbe2 module.  Headless run:
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_shell_washer_hole_rbe2_create.tcl
#
# Results: runtime/audit_washer_create_<version>.log (KEY=VALUE, ASCII only)

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [string trim [hm_info -appinfo VERSION]]
set reportPath [file join $outputDir "audit_washer_create_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}
proc T {key script} {
    if {[catch {uplevel 1 $script} value options]} {
        P $key "ERROR: [string map {\n { } \r { }} $value]"
    } else {
        P $key [string trim $value]
    }
}

# ---- Fixture: 1 comp, 9 nodes, 8 trias, 1 RBE2 -----------------------------
proc mknode {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
catch {*clearmark comps 1}
*collectorcreateonly components AUDIT_SRC "" 1
*currentcollector component AUDIT_SRC
set center [mknode 0 0 0]
set ring {}
for {set i 0} {$i < 8} {incr i} {
    set a [expr {$i * 45.0 * 3.141592653589793 / 180.0}]
    lappend ring [mknode [expr {5.0 * cos($a)}] [expr {5.0 * sin($a)}] 0]
}
foreach pair {{0 1} {1 2} {2 3} {3 4} {4 5} {5 6} {6 7} {7 0}} {
    set i [lindex $pair 0]
    set j [lindex $pair 1]
    catch {*clearmark nodes 1}
    eval *createlist nodes 1 [list $center [lindex $ring $i] [lindex $ring $j]]
    *createelement 103 1 1 1
}
catch {*clearmark nodes 1}
catch {*clearmark elems 1}
*createmark elems 1 all
set allElems [hm_getmark elems 1]
set srcComp [hm_latestentityid comps]
P "VERSION" $version
P "SRC_COMP" $srcComp
P "SHELL_ELEMS" [llength $allElems]

catch {*clearmark nodes 2}
eval *createmark nodes 2 $ring
T "RIGIDLINK_CREATE" {*rigidlink $center 2 123456}
catch {*clearmark nodes 2}
*createmark elems 1 all
set rbe2Id 0
foreach eid [hm_getmark elems 1] {
    if {![catch {set cfg [hm_getvalue elems id=$eid dataname=config]}] && [string trim $cfg] eq "55"} { set rbe2Id $eid }
}
catch {*clearmark elems 1}
if {$rbe2Id == 0} { set rbe2Id [hm_latestentityid elems] }
P "RBE2_ID" $rbe2Id

# ---- Component creation forms ----------------------------------------------
T "CREATEENTITY_COMPS_INCLUDEID" {*createentity comps includeid=0 name=AUDIT_C1}
T "CREATEENTITY_COMPONENTS_INCLUDEID" {*createentity components includeid=0 name=AUDIT_C2}
T "COLLECTORCREATEONLY_COMPS" {*collectorcreateonly comps AUDIT_C3 "" 4}
T "COLLECTORCREATEONLY_COMPONENTS" {*collectorcreateonly components AUDIT_C4 "" 5}
T "CURRENTCOLLECTOR_COMPONENT" {*currentcollector component AUDIT_C1}
T "CURRENTCOLLECTOR_TCLFORM" {*currentcollector(component,AUDIT_C1)}
set c1 [hm_getvalue comps name=AUDIT_C1 dataname=id]
set c2 [hm_getvalue comps name=AUDIT_C2 dataname=id]
T "SETVALUE_COMPS_COLOR" {*setvalue comps id=$c2 color=7}
P "C1_ID" $c1
P "C2_ID" $c2
T "START_NOTE_HISTORY" {*startnotehistorystate "AUDIT note"}
T "END_NOTE_HISTORY" {*endnotehistorystate "AUDIT note"}

# ---- Move created RBE2 into AUDIT_C1 by component name (module movemark) ---
catch {*clearmark elems 1}
eval *createmark elems 1 [list $rbe2Id]
T "MOVEMARK_ELEMS_BY_NAME" {*movemark elems 1 AUDIT_C1}
catch {*clearmark elems 1}
T "RBE2_COMP_AFTER_MOVE" {hm_getvalue elems id=$rbe2Id dataname=collector.id}

# ---- Display commands (module showOutputComponent) -------------------------
catch {*clearmark comps 2}
eval *createmark comps 2 [list $c1 $c2]
T "MARKSUPPRESSACTIVE" {*marksuppressactive comps 2 0}
T "MARKSUPPRESSOUTPUT" {*marksuppressoutput comps 2 0}
T "DISPLAYCOLLECTORSBYMARK" {*displaycollectorsbymark comps 2 on 1 1}
T "DISPLAYCOLLECTORSALLBYMARK" {*displaycollectorsallbymark 2 on 1 1}
T "DISPLAYCOLLECTOR_COMPONENT" {*displaycollector component on AUDIT_C1 1 1}
T "DISPLAYCOLLECTORWITHFILTER" {*displaycollectorwithfilter component on AUDIT_C1 1 1}
T "SHOWENTITY_BY_ID" {*showentity comps "by id" $c1}
T "SHOWENTITY_BY_ID_COMPONENTS" {*showentity components "by id" $c1}
catch {*clearmark comps 2}
T "REDRAW" {hm_redraw}

# ---- RBE3 creation (module createRigidLink RBE3 branch) --------------------
set n [llength $ring]
catch {*clearmark nodes 2}
eval *createmark nodes 2 $ring
T "CREATEARRAY" {eval *createarray $n [lrepeat $n 123456]}
T "CREATEDOUBLEARRAY" {eval *createdoublearray $n [lrepeat $n 1.0]}
T "RBE3_CREATE" {*rbe3 2 1 $n 1 $n $center 123456 1.0}
catch {*clearmark nodes 2}
*createmark elems 1 all
set rbe3Count 0
set rbe3Id 0
foreach eid [hm_getmark elems 1] {
    if {![catch {set cfg [hm_getvalue elems id=$eid dataname=config]}] && [string trim $cfg] eq "56"} { incr rbe3Count; set rbe3Id $eid }
}
P "RBE3_COUNT" $rbe3Count
P "RBE3_ID" $rbe3Id
catch {*clearmark elems 1}

# ---- hm_getvalue datanames --------------------------------------------------
set shellId [lindex $allElems 0]
foreach dn {nodes config typename solverkeyword solvername cardimage \
            collector.id component.id comp.id name node1.id node2.id node3.id \
            node4.id node5.id node6.id node7.id node8.id dependentnodesmax id} {
    T "SHELL_DATANAME $dn" {hm_getvalue elems id=$shellId dataname=$dn}
}
foreach dn {id x y z globalx globaly globalz coordinates} {
    T "NODE_DATANAME $dn" {hm_getvalue nodes id=$center dataname=$dn}
}
foreach dn {nodes config typename solverkeyword solvername cardimage \
            independentnode.id independentnodes dependentnode.id dependentnodes \
            dependentnodesmax collector.id component.id id} {
    T "RBE2_DATANAME $dn" {hm_getvalue elems id=$rbe2Id dataname=$dn}
}

# ---- Query functions --------------------------------------------------------
T "GETIDPOOLS_ELEMS" {hm_getidpools elems name}
set pools {}
catch {set pools [hm_getidpools elems name]}
T "GETINTERNALID_POOL" {hm_getinternalid [lindex $pools 0] $rbe2Id -bypoolname}
T "GETINTERNALID_BADPOOL" {hm_getinternalid NO_SUCH_POOL $rbe2Id -bypoolname}
T "GETSOLVERID_BYID" {hm_getsolverid elems $rbe2Id -byid}
T "ENTITYINFO_EXIST_BYNAME" {hm_entityinfo exist components AUDIT_C1 -byname}
T "ENTITYINFO_ID_BYNAME" {hm_entityinfo id components AUDIT_C1 -byname}
T "ENTITYINFO_NAME_BYID" {hm_entityinfo name comps $c1 -byid}
T "GETCOLLECTORNAME" {hm_getcollectorname comps $c1}
T "NODEVALUE" {hm_nodevalue $center}
T "NODELIST" {hm_nodelist $shellId}
T "ENTITYINCOLLECTOR_BYID" {hm_entityincollector comps $c1 elems 0 0 -byid}
T "ENTITYINCOLLECTOR_BYNAME" {hm_entityincollector comps AUDIT_C1 elems 0 0 -byname}
T "INFO_APPINFO_VERSION" {hm_info -appinfo VERSION}
T "INFO_APPINFO_TEMPLATES_DIR" {hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR}
T "INFO_APPINFO_EXECUTABLEDIR" {hm_info -appinfo EXECUTABLEDIR}
foreach cmd {hm_callpanel hm_pushpanel hmbr_signals hwbrowsermanager hm_markclear hm_usermessage} {
    P "EXISTS $cmd" [expr {[llength [info commands $cmd]] > 0}]
}

# ---- FEM export via *feoutput_select (module exporter path) ----------------
set templatesDir ""
catch {set templatesDir [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR]}
set templatePath [file join $templatesDir feoutput optistruct optistruct]
P "TEMPLATE_EXISTS" [file isfile $templatePath]
set femPath [file join $outputDir "audit_washer_${version}.fem"]
file delete -force $femPath
catch {*clearmark elems 1}
catch {*clearmark nodes 1}
eval *createmark elems 1 [list "by component id"] $srcComp
eval *createmark nodes 1 [list "by component id"] $srcComp
P "EXPORT_MARK_ELEMS" [llength [hm_getmark elems 1]]
P "EXPORT_MARK_NODES" [llength [hm_getmark nodes 1]]
T "FEOUTPUT_SELECT" {*feoutput_select $templatePath $femPath 1 0 0}
catch {*clearmark elems 1}
catch {*clearmark nodes 1}
P "FEM_FILE_EXISTS" [file isfile $femPath]
P "FEM_FILE_SIZE" [expr {[file isfile $femPath] ? [file size $femPath] : 0}]

# ---- extra idpool entity-name forms (module tries elems and elements) ------
T "GETIDPOOLS_ELEMENTS" {hm_getidpools elements name}
T "GETIDPOOLS_NODES" {hm_getidpools nodes name}
T "GETIDPOOLS_COMPS" {hm_getidpools comps name}

close $channel
exit 0
