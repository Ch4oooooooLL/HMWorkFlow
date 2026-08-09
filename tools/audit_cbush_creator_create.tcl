# Audit probe B: full CBUSH creation chain of modules/cbush_creator.tcl plus
# documented alternatives, on the real installed HyperMesh.
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_cbush_creator_create.tcl
# Results: runtime/audit_cbush_create_<version>.log (KEY=VALUE, ASCII only),
#          runtime/audit_cbush_model_<version>.fem

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_cbush_create_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
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
proc makeNode {x y z} {
    *createnode $x $y $z 0 0 0
    return [hm_latestentityid nodes]
}
proc elemInfo {label eid} {
    foreach dn {config type collector.id property.id CID STATUS} {
        set code [catch {set v [hm_getvalue elems id=$eid dataname=$dn]} err]
        if {$code} { P "$label $dn" "ERROR: $err" } else { P "$label $dn" "OK: $v" }
    }
}
proc exportFem {path} {
    set code [catch {
        hm_answernext yes
        *writefile $path
    } err]
    if {$code} { P "EXPORT $path" "ERROR: $err"; return 0 }
    if {[file exists $path]} {
        set fh [open $path r]
        set content [read $fh]
        close $fh
        P "EXPORT $path" "OK bytes=[string length $content]"
        P "FEM_HAS_CID" [string match -nocase *CID* $content]
        P "FEM_HAS_CBUSH" [string match -nocase *CBUSH* $content]
        set cbushLines {}
        foreach line [split $content \n] {
            if {[string match -nocase *CBUSH* $line]} { lappend cbushLines [string trim $line] }
        }
        P "FEM_CBUSH_LINES" [join $cbushLines { | }]
        return 1
    }
    P "EXPORT $path" "NO FILE WRITTEN"
    return 0
}

P "VERSION" $version
catch {P "PROFILE_COMMANDS" [join [lsort [info commands *profile*]] { }]}
catch {*setprofile OptiStruct}
tryResult "PROFILE" {hm_info -appinfo PROFILE}

# --- 1. Fixture -------------------------------------------------------------
catch {*createentity comps includeid=0 name=PROBE_CBUSH_COMP}
catch {*currentcollector component PROBE_CBUSH_COMP}
catch {*currentcollector components PROBE_CBUSH_COMP}

set srcNode [makeNode 1 2 3]
P "SRC_NODE" $srcNode

# --- 2. Module chain: *elementtype 21 6 then *springos -----------------------
tryResult "ELEMENTTYPE_21_6" {*elementtype 21 6}
set offNodeA [makeNode 1 2 8]
set prevElem [hm_latestentityid elems]
set springCode [catch {*springos $srcNode $offNodeA "" 0 0 0 0 0 0 0} springRet]
P "SPRINGOS_MODULE_ARGS" [expr {$springCode ? "ERROR: $springRet" : "OK ret=$springRet"}]
set elemId [hm_latestentityid elems]
P "ELEM_ID_AFTER_SPRINGOS" $elemId
P "ELEM_ID_UNCHANGED" [expr {$elemId eq $prevElem}]
elemInfo "ELEM" $elemId

# --- 3. *setvalue isolation: CID=0 STATUS=1 vs each part ---------------------
set setCode [catch {*setvalue elems id=$elemId CID=0 STATUS=1} setRet]
P "SETVALUE_CID0_STATUS1" [expr {$setCode ? "ERROR: $setRet" : "OK ret=$setRet"}]
tryResult "SETVALUE_STATUS1_ONLY" {*setvalue elems id=$elemId STATUS=1}
tryResult "SETVALUE_CID0_ONLY" {*setvalue elems id=$elemId CID=0}
tryResult "SETVALUE_CONFIG_SANITY" {*setvalue elems id=$elemId config=21}
tryResult "SETVALUE_TYPE_SANITY" {*setvalue elems id=$elemId type=6}
elemInfo "ELEM_AFTER_SETVALUE" $elemId
exportFem [file join $outputDir "audit_cbush_model_${version}.fem"]

# --- 3b. ASCII OptiStruct export with template -------------------------------
set tpl2019 "C:/Program Files/Altair/2019/templates/feoutput/optistruct/optistruct"
set tpl2022 "D:/Program Files/Altair/hwdesktop/templates/feoutput/optistruct/optistruct"
set tpl [expr {[file exists $tpl2019] ? $tpl2019 : ([file exists $tpl2022] ? $tpl2022 : "")}]
if {$tpl ne ""} {
    tryResult "TEMPLATEFILESET" {*templatefileset $tpl}
    set asciiPath [file join $outputDir "audit_cbush_deck_${version}.fem"]
    set code [catch {
        hm_answernext yes
        *writefile $asciiPath
    } err]
    P "EXPORT_ASCII" [expr {$code ? "ERROR: $err" : "OK"}]
    if {[file exists $asciiPath] && !$code} {
        set fh [open $asciiPath r]
        set content [read $fh]
        close $fh
        P "ASCII_HAS_CBUSH" [string match -nocase *CBUSH* $content]
        P "ASCII_HAS_CID" [string match -nocase *CID* $content]
        set cbushLines {}
        foreach line [split $content \n] {
            if {[string match -nocase *CBUSH* $line]} { lappend cbushLines [string trim $line] }
        }
        P "ASCII_CBUSH_LINES" [join $cbushLines { | }]
        set gridLines {}
        foreach line [split $content \n] {
            if {[string match -nocase "GRID*" $line]} { lappend gridLines [string trim $line] }
        }
        P "ASCII_GRID_LINES" [join $gridLines { | }]
    }
} else {
    P "EXPORT_ASCII" "NO TEMPLATE FOUND"
}

# --- 4. Without *elementtype: what does *springos default to? ----------------
catch {*createentity comps includeid=0 name=PROBE_DEFAULT_COMP}
catch {*currentcollector component PROBE_DEFAULT_COMP}
catch {*currentcollector components PROBE_DEFAULT_COMP}
set offNodeB [makeNode 11 2 8]
set prev [hm_latestentityid elems]
set code [catch {*springos $srcNode $offNodeB "" 0 0 0 0 0 0 0} ret]
P "SPRINGOS_NO_ELEMENTTYPE" [expr {$code ? "ERROR: $ret" : "OK ret=$ret"}]
set dfltElem [hm_latestentityid elems]
if {!$code && $dfltElem ne $prev} {
    elemInfo "ELEM_DEFAULT" $dfltElem
}

# --- 5. Alternative: *springos with a real property --------------------------
set propCode [catch {*createentity props includeid=0 name=PROBE_PBUSH cardimage=PBUSH} propRet]
P "CREATE_PROP_PBUSH" [expr {$propCode ? "ERROR: $propRet" : "OK"}]
set offNodeC [makeNode 21 2 8]
set prev [hm_latestentityid elems]
set code [catch {*springos $srcNode $offNodeC "PROBE_PBUSH" 0 0 0 0 0 0 0} ret]
P "SPRINGOS_WITH_PROP" [expr {$code ? "ERROR: $ret" : "OK ret=$ret"}]
set propElem [hm_latestentityid elems]
if {!$code && $propElem ne $prev} {
    elemInfo "ELEM_WITH_PROP" $propElem
}

# --- 6. Alternative: *spring (dof form) ---------------------------------------
set offNodeD [makeNode 31 2 8]
set prev [hm_latestentityid elems]
set code [catch {*spring $srcNode $offNodeD 2 "PROBE_PBUSH" 0} ret]
P "SPRING_DOF_FORM" [expr {$code ? "ERROR: $ret" : "OK ret=$ret"}]
set springElem [hm_latestentityid elems]
if {!$code && $springElem ne $prev} {
    elemInfo "ELEM_SPRING" $springElem
}

# --- 7. Cleanup path: node deletion semantics --------------------------------
# 7a. Unattached node deletion.
set loneNode [makeNode 41 2 8]
catch {*createmark nodes 2 "by id only" $loneNode}
tryResult "DELETEMARK_LONE_NODE" {*deletemark nodes 2}
catch {*clearmark nodes 2}
catch {*createmark nodes 1 all}
set loneGone [expr {[lsearch -exact [hm_getmark nodes 1] $loneNode] < 0}]
P "LONE_NODE_GONE" $loneGone
catch {*clearmark nodes 1}

# 7a2. Alternative node deletion commands.
P "EXISTS *deleteentity" [expr {[llength [info commands *deleteentity]] > 0}]
if {[llength [info commands *deleteentity]] > 0} {
    tryResult "DELETEENTITY_NODE" {*deleteentity nodes id=$loneNode}
}
catch {*clearmark nodes 1 all}
catch {*createmark nodes 1 all}
P "NODES_AFTER_DELETEENTITY" [llength [hm_getmark nodes 1]]
catch {*clearmark nodes 1}

# 7b. Delete element first, then its node (module cleanup order).
catch {*createmark elems 2 "by id only" $elemId}
tryResult "DELETEMARK_ELEM" {*deletemark elems 2}
catch {*clearmark elems 2}
catch {*createmark nodes 2 "by id only" $offNodeA}
tryResult "DELETEMARK_NODE_AFTER_ELEM" {*deletemark nodes 2}
catch {*clearmark nodes 2}

# 7c. Delete attached node directly (without deleting element first).
catch {*createmark nodes 2 "by id only" $offNodeB}
tryResult "DELETEMARK_ATTACHED_NODE" {*deletemark nodes 2}
catch {*clearmark nodes 2}
catch {*createmark elems 1 all}
set remaining {}
foreach eid [hm_getmark elems 1] {
    catch {set cfg [hm_getvalue elems id=$eid dataname=config]}
    if {$cfg eq "21"} { lappend remaining $eid }
}
P "SPRING_ELEMS_AFTER_ATTACHED_NODE_DELETE" [join $remaining { }]
catch {*clearmark elems 1}

close $channel
exit 0
