# Final depth probe for batch_property_assignment audit:
#  A. diagnose fem import (*feinputwithdata2) with MAT1/PSHELL cards
#  B. MAT1/PSHELL field access on imported real cards (the module's GUI data
#     state): E=/Nu=/Rho= writes, T=/thickness= writes, *attributeupdatedouble
#     95, hm_getthickness, materialid, plus ASCII ground-truth export via
#     *feoutputwithdata
#  C. *EntityPreviewEmpty treatment of geometry-only components (line and
#     surface geometry created via *createlist + *linecreatefromnodes /
#     *linearsurfacebetweennodes)
#  D. *propertyupdate / *setvalue propertyid on imported entities
#
# Run headless (one launch per version):
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_batch_property_geom.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_batch_property_geom.tcl
#
# Results to runtime/audit_batch_property_geom_<version>.log, ASCII KEY=VALUE.

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_batch_property_geom_${version}.log"]
set channel [open $reportPath w]

proc P {key args} {
    variable channel
    set value [join $args " "]
    set value [string map [list "\"" "" "\n" " " "\r" " " "," "_"] $value]
    puts $channel "${key}=${value}"
}

proc T {key script} {
    variable channel
    set code [catch {uplevel 1 $script} msg]
    set msg [string map [list "\n" " " "\r" " " "," "_"] $msg]
    puts $channel "${key}_CODE=$code"
    puts $channel "${key}_MSG=$msg"
    return $code
}

proc N {x y z} {
    catch {*createnode $x $y $z 0 0 0}
    catch {*createmark nodes 1 -1}
    return [lindex [hm_getmark nodes 1] end]
}

proc WriteFem {path lines} {
    set fh [open $path w]
    fconfigure $fh -translation crlf
    foreach line $lines { puts $fh $line }
    close $fh
}

P "HM_VERSION" $version

# --- A. Fem import diagnostics ----------------------------------------------
set fixtureMinimal [file join $outputDir "audit_bpa_minimal.fem"]
WriteFem $fixtureMinimal {
    "BEGIN BULK"
    "MAT1   1       210000.0       0.3    7.85E-9"
    "PSHELL 1       1       2.5     1       1"
    "GRID   1       0.0     0.0     0.0"
    "GRID   2       10.0    0.0     0.0"
    "GRID   3       10.0    10.0    0.0"
    "GRID   4       0.0     10.0    0.0"
    "CQUAD4 1       1       1       2       3       4       2.5"
    "ENDDATA"
}
P "MINIMAL_FIXTURE_SIZE" [file size $fixtureMinimal]
T "IMPORT_MINIMAL" {*feinputwithdata2 "#optistruct/optistruct" [file nativename $fixtureMinimal] 0 0 0 0 0 1 0 1 0}

set matCount 0
set propCount 0
catch {*clearmark mats 1}
catch {*createmark mats 1 all}
set matCount [llength [hm_getmark mats 1]]
catch {*clearmark props 1}
catch {*createmark props 1 all}
set propCount [llength [hm_getmark props 1]]
P "AFTER_MINIMAL MATS" $matCount
P "AFTER_MINIMAL PROPS" $propCount

if {$matCount == 0} {
    # try a cards-only fem (no elements)
    set fixtureCards [file join $outputDir "audit_bpa_cards_only.fem"]
    WriteFem $fixtureCards {
        "BEGIN BULK"
        "MAT1   1       210000.0       0.3    7.85E-9"
        "PSHELL 1       1       2.5     1       1"
        "ENDDATA"
    }
    T "IMPORT_CARDS_ONLY" {*feinputwithdata2 "#optistruct/optistruct" [file nativename $fixtureCards] 0 0 0 0 0 1 0 1 0}
    catch {*clearmark mats 1}
    catch {*createmark mats 1 all}
    set matCount [llength [hm_getmark mats 1]]
    catch {*clearmark props 1}
    catch {*createmark props 1 all}
    set propCount [llength [hm_getmark props 1]]
    P "AFTER_CARDS_ONLY MATS" $matCount
    P "AFTER_CARDS_ONLY PROPS" $propCount
}

if {$matCount == 0} {
    # try *readfile on the minimal fem
    T "READFILE_MINIMAL" {*readfile [file nativename $fixtureMinimal] 0}
    catch {*clearmark mats 1}
    catch {*createmark mats 1 all}
    set matCount [llength [hm_getmark mats 1]]
    P "AFTER_READFILE MATS" $matCount
}

# --- B. MAT1/PSHELL card access on imported cards ---------------------------
set mid ""
if {$matCount > 0} {
    catch {*clearmark mats 1}
    catch {*createmark mats 1 all}
    set mids [hm_getmark mats 1]
    set mid [lindex $mids 0]
    P "MAT_IDS" [join $mids { }]
    T "MAT_CARDIMAGE" {hm_getvalue mats id=$mid dataname=cardimage}
    T "MAT_READ_E" {hm_getvalue mats id=$mid dataname=E}
    T "MAT_READ_NU" {hm_getvalue mats id=$mid dataname=Nu}
    T "MAT_READ_RHO" {hm_getvalue mats id=$mid dataname=Rho}
    T "MAT_READ_G" {hm_getvalue mats id=$mid dataname=G}
    T "MAT_SET_E" {*setvalue mats id=$mid STATUS=1 E=211000.0}
    T "MAT_READ_E_AFTER" {hm_getvalue mats id=$mid dataname=E}
    T "MAT_SET_NU" {*setvalue mats id=$mid STATUS=1 Nu=0.32}
    T "MAT_READ_NU_AFTER" {hm_getvalue mats id=$mid dataname=Nu}
    T "MAT_SET_RHO" {*setvalue mats id=$mid STATUS=1 Rho=7.8e-9}
    T "MAT_READ_RHO_AFTER" {hm_getvalue mats id=$mid dataname=Rho}
    T "MAT_SET_NUM1" {*setvalue mats id=$mid STATUS=1 1=212000.0}
    T "MAT_READ_NUM1" {hm_getvalue mats id=$mid dataname=1}
    T "MAT_SET_E_NOSTATUS" {*setvalue mats id=$mid E=213000.0}
    T "MAT_READ_E_NOSTATUS" {hm_getvalue mats id=$mid dataname=E}
    T "MAT_ENTITYINFO" {hm_entityinfo id mats $mid}
}

set pid ""
if {$propCount > 0} {
    catch {*clearmark props 1}
    catch {*createmark props 1 all}
    set pids [hm_getmark props 1]
    set pid [lindex $pids 0]
    P "PROP_IDS" [join $pids { }]
    T "PROP_CARDIMAGE" {hm_getvalue props id=$pid dataname=cardimage}
    T "PROP_READ_T" {hm_getvalue props id=$pid dataname=T}
    T "PROP_READ_THICKNESS" {hm_getvalue props id=$pid dataname=thickness}
    T "PROP_READ_MATERIALID" {hm_getvalue props id=$pid dataname=materialid}
    T "PROP_READ_MATERIAL" {hm_getvalue props id=$pid dataname=material}
    T "PROP_READ_MATERIAL_DOT" {hm_getvalue props id=$pid dataname=material.id}
    T "GETTHICKNESS_IMPORTED" {hm_getthickness props $pid}
    if {$mid ne ""} {
        T "PROP_SET_MID" {*setvalue props id=$pid STATUS=1 materialid=$mid}
        T "PROP_READ_MID_AFTER" {hm_getvalue props id=$pid dataname=materialid}
    }
    # Method A: *setvalue thickness= (module fallback)
    T "METH_A_SET" {*setvalue props id=$pid STATUS=1 thickness=2.75}
    T "METH_A_READ_THICK" {hm_getvalue props id=$pid dataname=thickness}
    T "METH_A_READ_T" {hm_getvalue props id=$pid dataname=T}
    T "METH_A_GETTHICKNESS" {hm_getthickness props $pid}
    # Method B: attribute 95, module's exact 7-arg form
    T "METH_B_ATTR95" {*attributeupdatedouble properties $pid 95 1 1 0 3.0}
    T "METH_B_READ_THICK" {hm_getvalue props id=$pid dataname=thickness}
    T "METH_B_READ_T" {hm_getvalue props id=$pid dataname=T}
    T "METH_B_GETTHICKNESS" {hm_getthickness props $pid}
    # Method C: attribute 95, 6-arg form
    T "METH_C_ATTR95_6" {*attributeupdatedouble properties $pid 95 1 0 3.5}
    T "METH_C_READ_THICK" {hm_getvalue props id=$pid dataname=thickness}
    T "METH_C_GETTHICKNESS" {hm_getthickness props $pid}
    # Method D: *setvalue T=
    T "METH_D_SET_T" {*setvalue props id=$pid STATUS=1 T=2.25}
    T "METH_D_READ_THICK" {hm_getvalue props id=$pid dataname=thickness}
    T "METH_D_READ_T" {hm_getvalue props id=$pid dataname=T}
    T "METH_D_GETTHICKNESS" {hm_getthickness props $pid}
    # ASCII ground-truth export
    set exeDir [file dirname [info nameofexecutable]]
    set templatePath [file normalize [file join $exeDir .. .. .. templates feoutput optistruct optistruct]]
    P "TEMPLATE_EXISTS" [file isfile $templatePath]
    T "FEOUTPUT_ASCII" {*feoutputwithdata [file nativename $templatePath] [file nativename [file join $outputDir "audit_bpa_ascii_${version}.fem"]] 0 0 2 1 0}
}

# --- C. Geometry-only components vs *EntityPreviewEmpty ----------------------
foreach {cname color} {C_QUAD 1 C_GLINE 2 C_GSURF 3 C_NODEONLY 4 C_EMPTY2 5} {
    set rc [catch {*collectorcreateonly comps $cname "" $color} cerr]
    P "GEOM_COMP $cname" "CREATE_CODE=$rc ERR=$cerr"
}

# C_QUAD: one real quad element
*currentcollector component C_QUAD
set q0 [N 0 0 0]; set q1 [N 10 0 0]; set q2 [N 10 10 0]; set q3 [N 0 10 0]
eval *createlist nodes 1 [list $q0 $q1 $q2 $q3]
T "GEOM_QUAD_CREATE" {*createelement 104 1 1 1}

# C_GLINE: two nodes + one line geometry entity (list-based, Altair pattern)
*currentcollector component C_GLINE
set l0 [N 100 0 0]; set l1 [N 100 10 0]
*createlist nodes 1 $l0 $l1
T "GEOM_LINE_CREATE" {*linecreatefromnodes 1 0 0 0 0}
catch {*clearlist nodes 1}

# C_GSURF: four nodes + one surface geometry entity (list-based, Altair pattern)
*currentcollector component C_GSURF
set s0 [N 200 0 0]; set s1 [N 210 0 0]; set s2 [N 210 10 0]; set s3 [N 200 10 0]
*createlist nodes 1 $s0 $s1
*createlist nodes 2 $s2 $s3
T "GEOM_SURF_CREATE" {*linearsurfacebetweennodes 1 2 1}
catch {*clearlist nodes 1}
catch {*clearlist nodes 2}

# C_NODEONLY: nodes only
*currentcollector component C_NODEONLY
N 300 0 0; N 300 10 0

# verify geometry actually landed in the right comps
foreach cname {C_QUAD C_GLINE C_GSURF C_NODEONLY C_EMPTY2} {
    set cid ""
    catch {set cid [hm_getvalue comps name=$cname dataname=id]}
    catch {*clearmark elems 1}
    set rc [catch {*createmark elems 1 "by comp" $cid}]
    P "ELEMCOUNT $cname" [expr {$rc ? -1 : [llength [hm_getmark elems 1]]}]
    catch {*clearmark lines 1}
    set rc [catch {*createmark lines 1 "by comp" $cid}]
    P "LINECOUNT $cname" [expr {$rc ? -1 : [llength [hm_getmark lines 1]]}]
    catch {*clearmark surfs 1}
    set rc [catch {*createmark surfs 1 "by comp" $cid}]
    P "SURFCOUNT $cname" [expr {$rc ? -1 : [llength [hm_getmark surfs 1]]}]
}

catch {*clearmark comps 2}
T "PREVIEW_EMPTY_GEOM" {*EntityPreviewEmpty comps 2}
set emptyMarks [hm_getmark comps 2]
P "PREVIEW_EMPTY_MARKS" [lsort -integer $emptyMarks]
foreach id [lsort -integer $emptyMarks] {
    P "EMPTY_COMP $id" [hm_getvalue comps id=$id dataname=name]
}

# --- D. propertyupdate / setvalue propertyid on a fresh comp -----------------
set targetId ""
catch {set targetId [hm_getvalue comps name=C_EMPTY2 dataname=id]}
P "TARGET_COMP_ID" $targetId
if {$targetId ne "" && $pid ne ""} {
    catch {*clearmark comps 1}
    T "MARK_TARGET" {*createmark comps 1 $targetId}
    T "PROPUPDATE_NAME" {*propertyupdate comps 1 [hm_getvalue props id=$pid dataname=name]}
    T "PROPUPDATE_READBACK" {hm_getvalue comps id=$targetId dataname=propertyid}
    catch {*clearmark comps 1}
    T "MARK_TARGET_2" {*createmark comps 1 $targetId}
    T "PROPUPDATE_ID" {*propertyupdate comps 1 $pid}
    T "PROPUPDATE_ID_READBACK" {hm_getvalue comps id=$targetId dataname=propertyid}
    T "SETVALUE_PROPERTYID" {*setvalue comps id=$targetId propertyid=$pid}
    T "SETVALUE_PROPERTYID_READBACK" {hm_getvalue comps id=$targetId dataname=propertyid}
    catch {*clearmark comps 1}
}

close $channel
exit 0
