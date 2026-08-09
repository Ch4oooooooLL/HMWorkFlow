# ============================================================================
# Contact Setup module - native HyperMesh command audit probe.
#
# Verifies on the installed build every native command the contact_setup
# module (modules/contact_setup.tcl) calls, plus the documented alternatives
# for contact-surface creation.  Run headless with:
#
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_contact_setup_commands.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_contact_setup_commands.tcl
#
# Results are written to runtime/audit_contact_setup_<version>.log as
# KEY=VALUE lines, pure ASCII.  One launch per build, no stdout dependency.
# ============================================================================

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_contact_setup_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    set text [string map {"\n" " " "\r" " "} $value]
    puts $channel "${key}=${text}"
    flush $channel
}

proc PB {key flag} {
    P $key [expr {$flag ? "yes" : "no"}]
}

proc TRY {key script} {
    # Evaluate the script in the caller's scope; log OK:<result> or ERROR:<msg>.
    set code [catch {uplevel 1 $script} result]
    if {$code} {
        P $key "ERROR: $result"
    } else {
        P $key "OK: $result"
    }
}

P "AUDIT_TOPIC" "contact_setup_native_commands"
P "VERSION" $version
P "EXECUTABLEDIR" [hm_info -appinfo EXECUTABLEDIR]

# --- 0. template ------------------------------------------------------------
set templatePath [file normalize [file join [hm_info -appinfo EXECUTABLEDIR] \
    .. .. .. templates feoutput optistruct optistruct]]
P "TEMPLATE_PATH" $templatePath
P "TEMPLATE_PATH_EXISTS" [expr {[file isfile $templatePath] ? "yes" : "no"}]
P "TEMPLATE_TYPE_BEFORE" [string trim [hm_info templatetype]]
if {[file isfile $templatePath]} {
    if {[catch {*templatefileset $templatePath} tErr]} {
        P "TEMPLATE_SET" "ERROR: $tErr"
    } else {
        P "TEMPLATE_SET" "ok"
    }
}
P "TEMPLATE_TYPE_NOW" [string trim [hm_info templatetype]]
P "TEMPLATE_FILENAME" [string trim [hm_info templatefilename]]

# --- 1. command existence ---------------------------------------------------
set auditCommands {
    *contactsurfcreatewithshells *addshellstocontactsurf *removeelemsfromcontactsurf
    *adjustcontactsurfacenormal *createentity *setvalue *dictionaryload
    *findfaces *movemark *displaycollectorsbymark *displaycollectorsallbymark
    *createmark *clearmark *deletemark *startnotehistorystate *endnotehistorystate
    *undohistorystate *createnode *createlist *createelement *collectorcreateonly
    *currentcollector *templatefileset *feoutputwithdata *createmarkpanel *editmarkpanel
    hm_getvalue hm_getmark hm_entityinfo hm_attributelist hm_attributeidfromname
    hm_marklength hm_nodelist hm_nodevalue hm_redraw hm_usermessage hm_info
    hm_latestentityid hm_getcollectorname
}
foreach command $auditCommands {
    PB "EXISTS_$command" [expr {[llength [info commands $command]] > 0}]
}

# --- 2. fixture -------------------------------------------------------------
# Two opposite shell quads (A1/A2 at z=0, B1 at z=1), an extra quad C, and a
# hex8 solid, in separate components.
namespace eval ::Audit {}
proc ::Audit::node {x y z} {
    *createnode $x $y $z 0 0 0
    return [hm_latestentityid nodes]
}
proc ::Audit::quad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    return [hm_latestentityid elems]
}
proc ::Audit::hex {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 208 1 1 1
    return [hm_latestentityid elems]
}

if {[catch {*collectorcreateonly components AUDIT_SHELL "" 11} err]} {
    P "FIXTURE_COMP_SHELL" "ERROR: $err"
} else {
    P "FIXTURE_COMP_SHELL" "ok"
}
if {[catch {*currentcollector component AUDIT_SHELL} err]} {
    P "FIXTURE_CURRENT_SHELL" "ERROR: $err"
} else {
    P "FIXTURE_CURRENT_SHELL" "ok"
}

set a1 [::Audit::node 0 0 0]
set a2 [::Audit::node 10 0 0]
set a3 [::Audit::node 10 10 0]
set a4 [::Audit::node 0 10 0]
set elemA1 [::Audit::quad [list $a1 $a2 $a3 $a4]]
set elemA2 [::Audit::quad [list $a2 [::Audit::node 20 0 0] [::Audit::node 20 10 0] $a3]]
set b1 [::Audit::node 0 0 1]
set b2 [::Audit::node 10 0 1]
set b3 [::Audit::node 10 10 1]
set b4 [::Audit::node 0 10 1]
set elemB1 [::Audit::quad [list $b1 $b2 $b3 $b4]]
set c1 [::Audit::node 0 0 2]
set c2 [::Audit::node 10 0 2]
set c3 [::Audit::node 10 10 2]
set c4 [::Audit::node 0 10 2]
set quadC [::Audit::quad [list $c1 $c2 $c3 $c4]]

if {[catch {*collectorcreateonly components AUDIT_SOLID "" 12} err]} {
    P "FIXTURE_COMP_SOLID" "ERROR: $err"
} else {
    P "FIXTURE_COMP_SOLID" "ok"
}
if {[catch {*currentcollector component AUDIT_SOLID} err]} {
    P "FIXTURE_CURRENT_SOLID" "ERROR: $err"
} else {
    P "FIXTURE_CURRENT_SOLID" "ok"
}
set h1 [::Audit::node 0 0 0]
set h2 [::Audit::node 10 0 0]
set h3 [::Audit::node 10 10 0]
set h4 [::Audit::node 0 10 0]
set h5 [::Audit::node 0 0 10]
set h6 [::Audit::node 10 0 10]
set h7 [::Audit::node 10 10 10]
set h8 [::Audit::node 0 10 10]
set hexE1 [::Audit::hex [list $h1 $h2 $h3 $h4 $h5 $h6 $h7 $h8]]

set shellCompId ""
set solidCompId ""
if {![catch {set shellCompId [hm_getvalue comps name=AUDIT_SHELL dataname=id]}]} {}
if {![catch {set solidCompId [hm_getvalue comps name=AUDIT_SOLID dataname=id]}]} {}
P "FIXTURE_ELEM_A1" $elemA1
P "FIXTURE_ELEM_A2" $elemA2
P "FIXTURE_ELEM_B1" $elemB1
P "FIXTURE_ELEM_C" $quadC
P "FIXTURE_ELEM_HEX" $hexE1
P "FIXTURE_COMP_SHELL_ID" $shellCompId
P "FIXTURE_COMP_SOLID_ID" $solidCompId

# --- 3. contact surface creation via *contactsurfcreatewithshells -----------
catch {*clearmark elems 1}
if {[catch {eval *createmark elems 1 $elemA1 $elemA2} err]} {
    P "CS_MARK_ELEMS" "ERROR: $err"
} else {
    P "CS_MARK_ELEMS" "ok"
}
P "CS_MARK_ELEMS_LEN" [hm_marklength elems 1]
TRY "CS_CREATE_MAIN" {*contactsurfcreatewithshells AUDIT_MAIN 13 1 0}
TRY "CS_CREATE_MAIN_REVERSE" {*contactsurfcreatewithshells AUDIT_REV 45 1 1}
set mainId ""
if {![catch {set mainId [hm_entityinfo id contactsurfs AUDIT_MAIN -byname]}] && $mainId ne ""} {
    P "CS_MAIN_ID_SOURCE" "hm_entityinfo_byname"
} elseif {![catch {set mainId [hm_getvalue contactsurfs name=AUDIT_MAIN dataname=id]}] && $mainId ne ""} {
    P "CS_MAIN_ID_SOURCE" "hm_getvalue"
} else {
    P "CS_MAIN_ID_SOURCE" "NOT_FOUND"
}
set revId ""
if {![catch {set revId [hm_entityinfo id contactsurfs AUDIT_REV -byname]}] && $revId ne ""} {
    P "CS_REV_ID_SOURCE" "hm_entityinfo_byname"
} elseif {![catch {set revId [hm_getvalue contactsurfs name=AUDIT_REV dataname=id]}] && $revId ne ""} {
    P "CS_REV_ID_SOURCE" "hm_getvalue"
} else {
    P "CS_REV_ID_SOURCE" "NOT_FOUND"
}
P "CS_MAIN_ID" $mainId
P "CS_REV_ID" $revId
foreach dn {cardimage elements name color} {
    if {$mainId ne ""} {
        TRY "CS_MAIN_${dn}" [list hm_getvalue contactsurfs id=$mainId dataname=$dn]
    }
    if {$revId ne ""} {
        TRY "CS_REV_${dn}" [list hm_getvalue contactsurfs id=$revId dataname=$dn]
    }
}
if {$mainId ne ""} {
    TRY "CS_ATTRLIST" [list hm_attributelist contactsurfs $mainId]
    TRY "CS_ATTRLIST_NAME_BYID" [list hm_attributelist contactsurfs $mainId name -byid]
}

# --- 4. mark/dictionary path used by createContactSurf -----------------------
catch {*clearmark contactsurfs 1}
TRY "CS_MARK_BYNAMEONLY" {*createmark contactsurfs 1 "by name only" AUDIT_MAIN}
P "CS_MARK_BYNAMEONLY_LEN" [hm_marklength contactsurfs 1]
catch {*clearmark contactsurfs 1}
TRY "CS_MARK_BYNAME_PLAIN" {*createmark contactsurfs 1 AUDIT_MAIN}
P "CS_MARK_BYNAME_PLAIN_LEN" [hm_marklength contactsurfs 1]
if {$mainId ne ""} {
    TRY "CS_DICT_LOAD" {*dictionaryload contactsurfs 1 $templatePath "SURF"}
    TRY "CS_MAIN_CARDIMAGE_AFTER_DICT" [list hm_getvalue contactsurfs id=$mainId dataname=cardimage]
    TRY "CS_MAIN_ELEMENTS_AFTER_DICT" [list hm_getvalue contactsurfs id=$mainId dataname=elements]
}

# --- 5. *createentity contactsurfs + *addshellstocontactsurf (alternative) ---
catch {*clearmark contactsurfs 1}
TRY "CS_ENTITY_CREATE" {*createentity contactsurfs name=AUDIT_ENTITY cardimage=SURF}
set entId ""
if {![catch {set entId [hm_entityinfo id contactsurfs AUDIT_ENTITY -byname]}] && $entId ne ""} {
    P "CS_ENTITY_ID" $entId
} else {
    P "CS_ENTITY_ID" "NOT_FOUND"
}
if {$entId ne ""} {
    TRY "CS_ENTITY_CARDIMAGE" [list hm_getvalue contactsurfs id=$entId dataname=cardimage]
    TRY "CS_ENTITY_ELEMENTS" [list hm_getvalue contactsurfs id=$entId dataname=elements]
    catch {*clearmark elems 1}
    *createmark elems 1 $quadC
    TRY "CS_ADDSHELLS_TO_ENTITY" {*addshellstocontactsurf AUDIT_ENTITY 1}
    TRY "CS_ENTITY_ELEMENTS_AFTER_ADD" [list hm_getvalue contactsurfs id=$entId dataname=elements]
    TRY "CS_ENTITY_CARDIMAGE_AFTER_ADD" [list hm_getvalue contactsurfs id=$entId dataname=cardimage]
}
# add shells to the shell-created surface (module comment claims this works)
if {$mainId ne ""} {
    catch {*clearmark elems 1}
    *createmark elems 1 $quadC
    TRY "CS_ADDSHELLS_TO_SHELLSURF" {*addshellstocontactsurf AUDIT_MAIN 1}
    TRY "CS_MAIN_ELEMENTS_AFTER_ADD" [list hm_getvalue contactsurfs id=$mainId dataname=elements]
}

# --- 6. *adjustcontactsurfacenormal signature probes -------------------------
catch {*clearmark elems 1}
eval *createmark elems 1 $elemA1 $elemA2
TRY "CS_ADJUST_5ARG" {*adjustcontactsurfacenormal AUDIT_MAIN 1 1 $elemA1 1}
TRY "CS_ADJUST_4ARG" {*adjustcontactsurfacenormal AUDIT_MAIN 1 $elemA1 1}
TRY "CS_ADJUST_3ARG" {*adjustcontactsurfacenormal AUDIT_MAIN 1 1}
TRY "CS_ADJUST_2ARG" {*adjustcontactsurfacenormal AUDIT_MAIN 1}

# --- 7. CONTACT group creation chain ----------------------------------------
TRY "GROUP_CREATE" {*createentity groups name=AUDIT_CONTACT cardimage=CONTACT}
set gid ""
if {![catch {set gid [hm_entityinfo id groups AUDIT_CONTACT -byname]}] && $gid ne ""} {
    P "GROUP_ID_SOURCE" "hm_entityinfo_byname"
} elseif {![catch {set gid [hm_getvalue groups name=AUDIT_CONTACT dataname=id]}] && $gid ne ""} {
    P "GROUP_ID_SOURCE" "hm_getvalue"
} else {
    P "GROUP_ID_SOURCE" "NOT_FOUND"
}
P "GROUP_ID" $gid
if {$gid ne "" && $mainId ne "" && $revId ne ""} {
    TRY "GROUP_MASTER_SET" {*setvalue groups id=$gid masterentityids={contactsurfs $mainId}}
    TRY "GROUP_SLAVE_SET" {*setvalue groups id=$gid slaveentityids={contactsurfs $revId}}
    foreach dn {cardimage maincontactsurflist mastercontactsurflist secondarycontactsurflist \
                slavecontactsurflist maindefinition masterdefinition secondarydefinition slavedefinition} {
        TRY "GROUP_${dn}" [list hm_getvalue groups id=$gid dataname=$dn]
    }
    TRY "GROUP_ATTRLIST" [list hm_attributelist groups $gid]
    TRY "GROUP_ATTRLIST_NAME_BYID" [list hm_attributelist groups $gid name -byid]
    TRY "ATTRID_FROMNAME_TYPE" {hm_attributeidfromname TYPE}
    TRY "ATTRID_FROMNAME_CONTACT_PROP_TYPE" {hm_attributeidfromname CONTACT_PROP_TYPE}
    # module's exact TYPE write, then the alternative field write
    TRY "GROUP_TYPE_CPT_WRITE" {*setvalue groups id=$gid STATUS=2 CONTACT_PROP_TYPE=STICK}
    TRY "GROUP_TYPE_CPT_READ" [list hm_getvalue groups id=$gid dataname=CONTACT_PROP_TYPE]
    TRY "GROUP_TYPE_TYPE_WRITE" {*setvalue groups id=$gid STATUS=2 TYPE=SLIDE}
    TRY "GROUP_TYPE_TYPE_READ" [list hm_getvalue groups id=$gid dataname=TYPE]
    TRY "GROUP_TYPE_CPT_READ_AFTER_TYPE" [list hm_getvalue groups id=$gid dataname=CONTACT_PROP_TYPE]
}

# --- 8. trim chain: *removeelemsfromcontactsurf + history/undo --------------
if {$mainId ne ""} {
    catch {*clearmark elems 1}
    *createmark elems 1 $quadC
    TRY "TRIM_REMOVE" {*removeelemsfromcontactsurf AUDIT_MAIN 1}
    TRY "TRIM_ELEMENTS_AFTER_REMOVE" [list hm_getvalue contactsurfs id=$mainId dataname=elements]
    TRY "TRIM_HIST_START" {*startnotehistorystate AUDIT_HIST1}
    catch {*clearmark elems 1}
    *createmark elems 1 $quadC
    TRY "TRIM_REMOVE_2" {*removeelemsfromcontactsurf AUDIT_MAIN 1}
    TRY "TRIM_HIST_END" {*endnotehistorystate AUDIT_HIST1}
    TRY "TRIM_HIST_UNDO" {*undohistorystate 1}
    TRY "TRIM_ELEMENTS_AFTER_UNDO" [list hm_getvalue contactsurfs id=$mainId dataname=elements]
}

# --- 9. solid free-face flow: *findfaces / ^faces / *movemark ---------------
if {$solidCompId ne ""} {
    catch {*clearmark comps 1}
    if {[catch {*createmark comps 1 $solidCompId} err]} {
        P "FIND_MARK_COMP" "ERROR: $err"
    } else {
        P "FIND_MARK_COMP" "ok"
    }
    TRY "FINDFACES" {*findfaces components 1}
    set facesId ""
    if {![catch {set facesId [hm_entityinfo id comps ^faces -byname]}] && $facesId ne ""} {
        P "FACES_COMP_ID_SOURCE" "hm_entityinfo_byname"
    } elseif {![catch {set facesId [hm_getvalue comps name=^faces dataname=id]}] && $facesId ne ""} {
        P "FACES_COMP_ID_SOURCE" "hm_getvalue"
    } else {
        P "FACES_COMP_ID_SOURCE" "NOT_FOUND"
    }
    P "FACES_COMP_ID" $facesId
    if {$facesId ne ""} {
        TRY "FACES_COMP_ELEMS" [list hm_getvalue comps id=$facesId dataname=elems]
        set faceElems {}
        if {![catch {set faceElems [hm_getvalue comps id=$facesId dataname=elems]}]} {}
        P "FACES_ELEM_COUNT" [llength $faceElems]
        if {[llength $faceElems] > 0} {
            if {[catch {*collectorcreateonly components AUDIT_FACES_TMP "" 35} err]} {
                P "TMP_COMP_CREATE" "ERROR: $err"
            } else {
                P "TMP_COMP_CREATE" "ok"
            }
            catch {*clearmark elems 1}
            if {[catch {eval *createmark elems 1 $faceElems} err]} {
                P "TMP_MARK_ELEMS" "ERROR: $err"
            } else {
                P "TMP_MARK_ELEMS" "ok"
            }
            TRY "MOVEMARK_BY_NAME" {*movemark elems 1 AUDIT_FACES_TMP}
            TRY "TMP_COMP_ELEMS_VERIFY" [list hm_getvalue comps name=AUDIT_FACES_TMP dataname=elems]
        }
    }
    # delete ^faces like the module does
    catch {*clearmark comps 2}
    TRY "MARK_FACES_BYNAMEONLY" {*createmark comps 2 "by name only" ^faces}
    TRY "DELETEMARK_FACES" {*deletemark comps 2}
}

# --- 10. display commands ----------------------------------------------------
catch {*clearmark comps 1}
TRY "MARK_COMPS_ALL" {*createmark comps 1 all}
TRY "DISPLAY_BYMARK_OFF" {*displaycollectorsbymark comps 1 0 1 1}
TRY "DISPLAY_BYMARK_ON" {*displaycollectorsbymark comps 1 1 1 1}
TRY "DISPLAY_ALLBYMARK_4ARG" {*displaycollectorsallbymark 1 1 1 1}
TRY "DISPLAY_ALLBYMARK_5ARG" {*displaycollectorsallbymark comps 1 1 1 1}
TRY "REDRAW" {hm_redraw}

# --- 11. dataname probes used by the module ----------------------------------
set nid $a1
foreach dn {x y z coordinates globalx globaly globalz} {
    TRY "NODE_DN_${dn}" [list hm_getvalue nodes id=$nid dataname=$dn]
}
foreach dn {nodes config collector.id component.id comp.id material.id} {
    TRY "ELEM_DN_${dn}" [list hm_getvalue elems id=$elemA1 dataname=$dn]
}
catch {*clearmark elems 1}
eval *createmark elems 1 $elemA1 $elemA2
TRY "ELEM_BULK_NODES_MARK1" {hm_getvalue elems mark=1 dataname=nodes}
catch {*clearmark nodes 2}
TRY "MARK_NODES_ALL" {*createmark nodes 2 all}
TRY "NODE_BULK_COORDS_MARK2" {hm_getvalue nodes mark=2 dataname=coordinates}
TRY "GETMARK_ELEMS" {hm_getmark elems 1}
TRY "NODELIST_ELEM" [list hm_nodelist $elemA1]
TRY "NODEVALUE_NODE" [list hm_nodevalue $nid]
TRY "USERMESSAGE" {hm_usermessage "audit contact setup"}

# --- 12. *createmark selector probes -----------------------------------------
TRY "MARK_ELEMS_BY_COMP_ID" [list *createmark elems 2 "by comp id" $shellCompId]
P "MARK_ELEMS_BY_COMP_ID_LEN" [hm_marklength elems 2]
TRY "MARK_COMPS_DISPLAYED" {*createmark comps 2 displayed}
P "MARK_COMPS_DISPLAYED_LEN" [hm_marklength comps 2]
TRY "MARK_GROUPS_BYNAMEONLY" {*createmark groups 2 "by name only" AUDIT_CONTACT}
P "MARK_GROUPS_BYNAMEONLY_LEN" [hm_marklength groups 2]
TRY "MARK_GROUP_SINGULAR_BYNAMEONLY" {*createmark group 2 "by name only" AUDIT_CONTACT}
TRY "MARK_COMPS_BYNAMEONLY" {*createmark comps 2 "by name only" AUDIT_SHELL}
P "MARK_COMPS_BYNAMEONLY_LEN" [hm_marklength comps 2]
TRY "MARK_COMPS_BYNAME" {*createmark comps 2 "by name" AUDIT_SHELL}
P "MARK_COMPS_BYNAME_LEN" [hm_marklength comps 2]
TRY "MARK_COMPONENTS_PLURAL_ALL" {*createmark components 1 all}
TRY "MARK_CS_BYNAMEONLY" {*createmark contactsurfs 2 "by name only" AUDIT_MAIN}
P "MARK_CS_BYNAMEONLY_LEN" [hm_marklength contactsurfs 2]
TRY "MARK_CONTACTSURF_SINGULAR" {*createmark contactsurf 2 "by name only" AUDIT_MAIN}

# --- 13. end-to-end OptiStruct export ----------------------------------------
set deckPath [file join $outputDir "audit_contact_setup_${version}.fem"]
if {[file exists $deckPath]} { file delete -force $deckPath }
if {[catch {*feoutputwithdata $templatePath $deckPath 0 0 1 1 0} eErr]} {
    P "EXPORT" "ERROR: $eErr"
} else {
    P "EXPORT" "ok"
}
if {[file isfile $deckPath]} {
    set fh [open $deckPath r]
    set deck [read $fh]
    close $fh
    P "EXPORT_FILE_SIZE" [file size $deckPath]
    P "EXPORT_SURF_CARD" [expr {[regexp -line {^[ \t]*SURF[ \t,]} $deck] ? "yes" : "no"}]
    P "EXPORT_CONTACT_CARD" [expr {[regexp -line {^[ \t]*CONTACT[ \t,]} $deck] ? "yes" : "no"}]
    P "EXPORT_STICK" [expr {[regexp -line {^[ \t]*CONTACT[ \t]+[0-9]+[ \t]+STICK([ \t]|$)} $deck] ? "yes" : "no"}]
    foreach line [split $deck "\n"] {
        if {[regexp {^[ \t]*(CONTACT|SURF)[ \t,]} $line]} {
            P "EXPORT_CARD_LINE" [string trim $line]
        }
    }
}

close $channel
exit 0
