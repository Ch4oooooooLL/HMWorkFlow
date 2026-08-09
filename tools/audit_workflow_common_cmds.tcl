# Audit probe for modules/workflow_common.tcl native HyperMesh commands.
# Covers every `*`/hm_/hmbr_/hwbrowsermanager command the file invokes.
#
# Run headless, once per installed HyperMesh:
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand \
#       -nouserprofiledialog -tcl tools/audit_workflow_common_cmds.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe" -nocommand \
#       -nouserprofiledialog -tcl tools/audit_workflow_common_cmds.tcl
#
# hmbatch has no stdout channel: results go to
# runtime/audit_workflow_common_<version>.log as ASCII KEY=VALUE lines.
# Script always exits 0.

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_workflow_common_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    # Keep the log pure ASCII so any code page can parse it.
    set clean [regsub -all {[^\x20-\x7E]} $value {?}]
    puts $channel "${key}=${clean}"
}

proc T {key script} {
    # Run a command, record OK/ERR and the (ASCII-sanitized) error text.
    set code [catch {uplevel 1 $script} result]
    if {$code} {
        P $key "ERR [regsub -all {[^\x20-\x7E]} $result {?}]"
    } else {
        P $key "OK $result"
    }
}

P "VERSION" $version

# --- 1. Command existence ------------------------------------------------
set allCmds [lsort [info commands {*}{*}]]
P "TOTAL_COMMANDS" [llength $allCmds]
foreach name {
    *clearmark *createmark *createmarkpanel *editmarkpanel
    *displayimporterrors *assemblyaddmark *assemblymodify *assemblymodifyhierarchy
    *createentity *currentcollector *displaycollector *displaycollectorwithfilter
    *displaycollectorsallbymark *displaycollectorsbymark *marksuppressactive
    *marksuppressoutput *setvalue *showentity *renamecollector
    *collectorcreateonly *startnotehistorystate *endnotehistorystate *setoption
    hm_info hm_getmark hm_getvalue hm_getcollectorname hm_entityinfo
    hm_answernext hm_redraw hm_usermessage
    hm_blockbrowserupdate hm_blockredraw hm_blockmessages hm_blockerrormessages
    hm_commandfilestate hmbr_signals hwbrowsermanager
} {
    P "EXISTS $name" [expr {[llength [info commands $name]] > 0}]
}
P "EXISTS ::hmbr::operation" [expr {[llength [info commands ::hmbr::operation]] > 0}]
P "EXISTS ::hmbr::createonly" [expr {[llength [info commands ::hmbr::createonly]] > 0}]

# --- 2. Fixture: two components + one element -----------------------------
T "CREATE_COMP_A" {*createentity comps includeid=0 name=PROBE_A}
T "CREATE_COMP_B" {*createentity comps includeid=0 name=PROBE_B}
P "ID_A_ENTITYINFO" [hm_entityinfo id comps PROBE_A -byname]
P "ID_B_ENTITYINFO" [hm_entityinfo id comps PROBE_B -byname]
P "ID_A_GETVALUE" [hm_getvalue comps name=PROBE_A dataname=id]
set compA [hm_getvalue comps name=PROBE_A dataname=id]

# createentity without the includeid option (reference form)
T "CREATE_COMP_C_PLAIN" {*createentity comps name=PROBE_C}
P "EXIST_C" [hm_entityinfo exist comps PROBE_C -byname]
catch {*clearmark comps 1}
catch {*createmark comps 1 "by name" PROBE_C}
catch {*deletemark comps 1}

# collectorcreateonly fallback
T "CREATE_COMP_D_FALLBACK" {*collectorcreateonly comps PROBE_D "" 7}
P "EXIST_D" [hm_entityinfo exist comps PROBE_D -byname]
catch {*clearmark comps 1}
catch {*createmark comps 1 "by name" PROBE_D}
catch {*deletemark comps 1}

# --- 3. Collector name/entityinfo read APIs --------------------------------
foreach etype {comps components component} {
    T "GETCOLLECTORNAME $etype" [list hm_getcollectorname $etype $compA]
}
foreach etype {comps components component} {
    T "ENTITYINFO_NAME_BYID $etype" [list hm_entityinfo name $etype $compA -byid]
}
foreach etype {comps components component} {
    T "ENTITYINFO_ID_BYNAME $etype" [list hm_entityinfo id $etype PROBE_A -byname]
}
foreach etype {comps components component} {
    T "ENTITYINFO_EXIST_BYNAME $etype" [list hm_entityinfo exist $etype PROBE_A -byname]
}
T "ENTITYINFO_EXIST_MISSING" [list hm_entityinfo exist comps NO_SUCH_COMP -byname]
T "GETVALUE_COMP_NAME" [list hm_getvalue comps id=$compA dataname=name]
T "GETVALUE_COMP_COLOR" [list hm_getvalue comps id=$compA dataname=color]

# --- 4. Mark creation selectors (as used by the file) ----------------------
foreach {key args} {
    "MARK ALL"            {all}
    "MARK DISPLAYED"      {displayed}
    "MARK INACTIVE"       {inactive}
    "MARK BYNAMEONLY"     {"by name only" PROBE_A}
    "MARK BYNAME"         {"by name" PROBE_A}
    "MARK BYIDONLY"       {"by id only" $compA}
    "MARK BAREID"         {$compA}
    "MARK BARENAME"       {PROBE_A}
    "MARK NOARGS"         {}
} {
    catch {*clearmark comps 1}
    T "CREATEMARK_COMP $key" [concat [list *createmark comps 1] $args]
    if {![catch {set got [hm_getmark comps 1]}]} {
        P "CREATEMARK_COMP $key COUNT" [llength $got]
    }
}
foreach etype {comps components} {
    catch {*clearmark $etype 1}
    T "CREATEMARK_EMPTY_MARK $etype" [list *createmark $etype 1]
    T "CLEARMARK $etype" [list *clearmark $etype 1]
}
catch {*clearmark comps 1}
T "CLEARMARK_UNUSED" {*clearmark comps 3}
catch {*clearmark components 1}
T "CLEARMARK_COMPONENTS" {*clearmark components 1}

# --- 5. Component activation/display commands ------------------------------
catch {*clearmark comps 1}
catch {*createmark comps 1 "by name" PROBE_A}
T "MARKSUPPRESSACTIVE" {*marksuppressactive comps 1 0}
T "MARKSUPPRESSOUTPUT" {*marksuppressoutput comps 1 0}
T "DISPLAYCOLLECTORSBYMARK" {*displaycollectorsbymark comps 1 on 1 1}
T "DISPLAYCOLLECTORSBYMARK_COMPONENTS" {*displaycollectorsbymark components 1 on 1 1}
T "DISPLAYCOLLECTORSALLBYMARK" {*displaycollectorsallbymark 1 on 1 1}
T "DISPLAYCOLLECTOR" {*displaycollector component on PROBE_A 1 1}
T "DISPLAYCOLLECTOR_COMPONENTS" {*displaycollector components on PROBE_A 1 1}
T "DISPLAYCOLLECTOR_WITHFILTER" {*displaycollectorwithfilter component on PROBE_A 1 1}
T "DISPLAYCOLLECTOR_WITHFILTER_C" {*displaycollectorwithfilter components on PROBE_A 1 1}
T "SHOWENTITY_BYID" {*showentity comps "by id" $compA}
T "SHOWENTITY_BYID_C" {*showentity components "by id" $compA}

# --- 6. Collector mutation: rename / current / setvalue --------------------
T "RENAMECOLLECTOR_COMP" {*renamecollector component PROBE_B PROBE_B2}
P "RENAMED_B_EXISTS" [hm_entityinfo exist comps PROBE_B2 -byname]
T "RENAMECOLLECTOR_COMPONENTS" {*renamecollector components PROBE_B2 PROBE_B}
P "RENAMED_B_AGAIN" [hm_entityinfo exist comps PROBE_B -byname]
T "CURRENTCOLLECTOR_COMP" {*currentcollector component PROBE_A}
T "CURRENTCOLLECTOR_COMPONENTS" {*currentcollector components PROBE_A}
T "SETVALUE_COLOR_COMP" {*setvalue comps id=$compA color=11}
P "COLOR_AFTER_SETVALUE" [hm_getvalue comps id=$compA dataname=color]
T "SETVALUE_COLOR_COMPONENTS" {*setvalue components id=$compA color=12}
P "COLOR_AFTER_SETVALUE2" [hm_getvalue comps id=$compA dataname=color]

# --- 7. History block -------------------------------------------------------
T "STARTNOTEHISTORY" {*startnotehistorystate Audit Probe Step}
T "ENDNOTEHISTORY" {*endnotehistorystate Audit Probe Step}

# --- 8. Assembly creation / organization -----------------------------------
catch {*clearmark comps 1}
catch {*createmark comps 1 "by name" PROBE_A}
catch {*appendmark comps 1 "by name" PROBE_B}
P "ASSEMBLY_MARK_COUNT" [llength [hm_getmark comps 1]]
T "ASSEMBLYMODIFYHIERARCHY" {*assemblymodifyhierarchy AUDIT_ASM_1 1 9}
P "ASM1_EXISTS" [expr {[catch {hm_entityinfo id assemblies AUDIT_ASM_1 -byname}] ? 0 : ([hm_entityinfo id assemblies AUDIT_ASM_1 -byname] != 0)}]
T "ASSEMBLYMODIFY" {*assemblymodify AUDIT_ASM_2 1 9}
P "ASM2_EXISTS" [expr {[catch {hm_entityinfo id assemblies AUDIT_ASM_2 -byname}] ? 0 : ([hm_entityinfo id assemblies AUDIT_ASM_2 -byname] != 0)}]
T "CREATEENTITY_ASSEMS" {*createentity assems name=AUDIT_ASM_3}
T "CREATEENTITY_ASSEMBLIES" {*createentity assemblies name=AUDIT_ASM_4}
P "ASM3_EXISTS" [expr {[catch {hm_entityinfo id assemblies AUDIT_ASM_3 -byname}] ? 0 : ([hm_entityinfo id assemblies AUDIT_ASM_3 -byname] != 0)}]
P "ASM4_EXISTS" [expr {[catch {hm_entityinfo id assemblies AUDIT_ASM_4 -byname}] ? 0 : ([hm_entityinfo id assemblies AUDIT_ASM_4 -byname] != 0)}]

set asm1 [hm_entityinfo id assemblies AUDIT_ASM_1 -byname]
catch {*clearmark comps 1}
catch {*createmark comps 1 "by name" PROBE_A}
T "ASSEMBLYADDMARK_1" [list *assemblyaddmark $asm1 comps 1]
T "ASSEMBLYADDMARK_1B" [list *assemblyaddmark $asm1 components 1]
catch {*clearmark comps 1}
catch {*createmark comps 1 "by name" PROBE_B}
T "ASSEMBLYADDMARK_2" [list *assemblyaddmark $asm1 comps 1]

# mark an assembly by id (markAssemblyById patterns)
foreach etype {assemblies assems assembly} {
    catch {*clearmark $etype 2}
    T "MARKASM_BYIDONLY $etype" [list *createmark $etype 2 "by id only" $asm1]
    catch {*clearmark $etype 2}
    T "MARKASM_BAREID $etype" [list *createmark $etype 2 $asm1]
}

# assembly name lookup APIs
foreach etype {assemblies assems assembly} {
    T "ASM_ENTITYINFO_ID $etype" [list hm_entityinfo id $etype AUDIT_ASM_1 -byname]
    T "ASM_GETVALUE_ID $etype" [list hm_getvalue $etype name=AUDIT_ASM_1 dataname=id]
}
catch {*clearmark comps 1}
T "CREATEMARK_COMP_NOARGS2" {*createmark comps 1}
catch {*clearmark comps 1}
catch {*createmark comps 1 "by name" PROBE_A}
T "CREATEMARK_COMP_NAME_NOQUOTE" {*createmark comps 1 PROBE_A}

# assemblyaddmark with mark of assemblies (addAssemblyToAssembly pattern)
catch {*clearmark assemblies 2}
catch {*createmark assemblies 2 "by id only" $asm1}
T "ASSEMBLYADDMARK_ASM" [list *assemblyaddmark $asm1 assemblies 2]

# --- 9. Element dataname / by-comp-id mark (getCompEntityIds) ---------------
catch {*clearmark nodes 1}
eval *createnode 0 0 0 0 0 0
eval *createnode 10 0 0 0 0 0
eval *createnode 10 10 0 0 0 0
eval *createnode 0 10 0 0 0 0
catch {*clearmark nodes 1}
*createmark nodes 1 all
set nodeIds [hm_getmark nodes 1]
P "FIXTURE_NODES" [llength $nodeIds]
catch {*clearmark comps 1}
catch {*createmark comps 1 "by name" PROBE_A}
*currentcollector component PROBE_A
catch {*clearlist nodes 1}
eval *createlist nodes 1 $nodeIds
T "CREATEQUAD" {*createelement 104 1 1 1}
catch {*clearmark elems 1}
*createmark elems 1 -1
set elemIds [hm_getmark elems 1]
P "FIXTURE_ELEMS" [llength $elemIds]
set elem1 [lindex $elemIds 0]
T "GETVALUE_COMP_ELEMS" [list hm_getvalue comps id=$compA dataname=elems]
T "GETVALUE_COMP_ELEMENTS" [list hm_getvalue comps id=$compA dataname=elements]
T "MARK_ELEMS_BYCOMPID" [list *createmark elems 1 "by comp id" $compA]
P "ELEMS_BYCOMPID_COUNT" [llength [hm_getmark elems 1]]
T "GETVALUE_ELEM_CONFIG" [list hm_getvalue elems id=$elem1 dataname=config]

# --- 10. Setoption / throttling commands (resetBrowserBlocks) ---------------
T "SETOPTION_EQ_BLOCKREDRAW" {*setoption block_redraw=0}
T "SETOPTION_SP_BLOCKREDRAW" {*setoption block_redraw 0}
T "SETOPTION_EQ_BLOCKMESSAGES" {*setoption block_messages=0}
T "SETOPTION_SP_BLOCKMESSAGES" {*setoption block_messages 0}
T "SETOPTION_EQ_CMDFILE" {*setoption command_file_state=1}
T "SETOPTION_SP_CMDFILE" {*setoption command_file_state 1}
T "HMBLOCKBROWSERUPDATE" {hm_blockbrowserupdate 0}
T "HMBLOCKREDRAW" {hm_blockredraw 0}
T "HMBLOCKMESSAGES" {hm_blockmessages 0}
T "HMBLOCKERRORMESSAGES" {hm_blockerrormessages 0}
T "HMCOMMANDFILESTATE" {hm_commandfilestate 1}
T "HMBR_SIGNALS_STOP" {hmbr_signals buffer stop}
T "HWBROWSER_FLUSH_TRUE" {hwbrowsermanager view flush true}
T "HWBROWSER_FLUSH_1" {hwbrowsermanager view flush 1}
T "HWBROWSER_FLUSH_ON" {hwbrowsermanager view flush on}
T "HMREDRAW" {hm_redraw}
T "HMUSERMESSAGE" {hm_usermessage Audit workflow_common probe}

# --- 11. Import/export helpers ----------------------------------------------
T "HM_INFO_IMPORTERRORS" {hm_info displayimporterrors}
T "DISPLAYIMPORTERRORS_0" {*displayimporterrors 0}
T "HM_INFO_TEMPLATETYPE" {hm_info templatetype}
foreach answer {all yes none} {
    T "HM_ANSWERNEXT $answer" [list hm_answernext $answer]
}

# --- 12. Browser create operation gate (createComponentThroughBrowser) ------
set gate [catch {::hmbr::operation perform hmbr::createonly [list [list Components {}]]} r]
if {$gate} {
    P "HMBR_CREATEONLY" "ERR [regsub -all {[^\x20-\x7E]} $r {?}]"
} else {
    P "HMBR_CREATEONLY" "OK $r"
}

# --- 13. Selection-panel commands: existence only (modal in batch) ----------
# *createmarkpanel / *editmarkpanel must never be invoked headless.
P "EXISTS CREATEMARKPANEL" [expr {[llength [info commands *createmarkpanel]] > 0}]
P "EXISTS EDITMARKPANEL" [expr {[llength [info commands *editmarkpanel]] > 0}]

close $channel
exit 0
