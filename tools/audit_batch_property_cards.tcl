# Card-level probe for batch_property_assignment audit: import a real
# OptiStruct fem fixture (MAT1 + PSHELL cards, exactly the data state the
# module sees in the GUI) and verify MAT1/PSHELL field writes, attribute 95,
# hm_getthickness, and *EntityPreviewEmpty geometry semantics against real
# cards.  Also probes *templatefileset ASCII fem export as ground truth.
#
# Run headless (one launch per version):
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_batch_property_cards.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_batch_property_cards.tcl
#
# Results to runtime/audit_batch_property_cards_<version>.log, ASCII KEY=VALUE.

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_batch_property_cards_${version}.log"]
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

P "HM_VERSION" $version

# --- A. Import fixture fem with real MAT1/PSHELL cards ----------------------
set fixturePath [file join $outputDir "audit_bpa_fixture.fem"]
set fixture [open $fixturePath w]
puts $fixture "BEGIN BULK"
puts $fixture "\$HMNAME COMP       1\"FIXTURE_FULL\""
puts $fixture "\$HMNAME COMP       2\"FIXTURE_EMPTY\""
puts $fixture "\$HMNAME MAT       1\"FIXTURE_STEEL\""
puts $fixture "\$HMNAME PROP       1\"FIXTURE_T25\""
puts $fixture "MAT1   1       210000.0       0.3    7.85E-9"
puts $fixture "PSHELL 1       1       2.5     1       1"
puts $fixture "GRID   1       0.0     0.0     0.0"
puts $fixture "GRID   2       10.0    0.0     0.0"
puts $fixture "GRID   3       10.0    10.0    0.0"
puts $fixture "GRID   4       0.0     10.0    0.0"
puts $fixture "CQUAD4 1       1       1       2       3       4       2.5"
puts $fixture "ENDDATA"
close $fixture
P "FIXTURE_PATH" $fixturePath
P "FIXTURE_SIZE" [file size $fixturePath]

T "FEINPUT" {*feinputwithdata2 "#optistruct/optistruct" [file nativename $fixturePath] 0 0 0 0 0 1 0 1 0}
catch {*clearmark mats 1}
catch {*createmark mats 1 all}
P "IMPORTED_MATS" [hm_getmark mats 1]
catch {*clearmark props 1}
catch {*createmark props 1 all}
P "IMPORTED_PROPS" [hm_getmark props 1]
catch {*clearmark comps 1}
catch {*createmark comps 1 all}
P "IMPORTED_COMPS" [hm_getmark comps 1]

# --- B. MAT1 card access on imported material --------------------------------
set mid ""
T "MAT_ID_BY_NAME" {set mid [hm_getvalue mats name=FIXTURE_STEEL dataname=id]}
P "MAT_ID_VALUE" $mid
if {$mid ne ""} {
    T "MAT_CARDIMAGE" {hm_getvalue mats id=$mid dataname=cardimage}
    T "MAT_READ_E" {hm_getvalue mats id=$mid dataname=E}
    T "MAT_READ_NU" {hm_getvalue mats id=$mid dataname=Nu}
    T "MAT_READ_RHO" {hm_getvalue mats id=$mid dataname=Rho}
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
    T "MAT_ENTITYINFO" {hm_entityinfo id mats FIXTURE_STEEL -byname}
}

# --- C. PSHELL card access on imported property ------------------------------
set pid ""
T "PROP_ID_BY_NAME" {set pid [hm_getvalue props name=FIXTURE_T25 dataname=id]}
P "PROP_ID_VALUE" $pid
if {$pid ne "" && $mid ne ""} {
    T "PROP_CARDIMAGE" {hm_getvalue props id=$pid dataname=cardimage}
    T "PROP_READ_T" {hm_getvalue props id=$pid dataname=T}
    T "PROP_READ_THICKNESS" {hm_getvalue props id=$pid dataname=thickness}
    T "PROP_READ_MATERIALID" {hm_getvalue props id=$pid dataname=materialid}
    T "PROP_READ_MATERIAL" {hm_getvalue props id=$pid dataname=material}
    T "PROP_READ_MATERIAL_DOT" {hm_getvalue props id=$pid dataname=material.id}
    T "GETTHICKNESS_IMPORTED" {hm_getthickness props $pid}
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
}

# --- D. ASCII fem export ground truth (*templatefileset) ---------------------
set exeDir [file dirname [info nameofexecutable]]
set templatePath [file normalize [file join $exeDir .. .. .. templates feoutput optistruct optistruct]]
P "TEMPLATE_PATH" $templatePath
P "TEMPLATE_EXISTS" [file isfile $templatePath]
T "TEMPLATEFILESET" {*templatefileset [file nativename $templatePath]}
T "WRITEFILE_ASCII" {*writefile [file nativename [file join $outputDir "audit_bpa_cards_${version}.fem"]] 1}

# --- E. *EntityPreviewEmpty vs geometry/element content ----------------------
# comps are created FIRST, then content is added into them
foreach {cname color} {C_QUAD 1 C_GLINE 2 C_GSURF 3 C_NODEONLY 4 C_EMPTY2 5} {
    set rc [catch {*collectorcreateonly comps $cname "" $color} cerr]
    P "GEOM_COMP $cname" "CREATE_CODE=$rc ERR=$cerr"
}

# C_QUAD: one real quad element
*currentcollector component C_QUAD
set q0 [N 0 0 0]; set q1 [N 10 0 0]; set q2 [N 10 10 0]; set q3 [N 0 10 0]
eval *createlist nodes 1 [list $q0 $q1 $q2 $q3]
T "GEOM_QUAD_CREATE" {*createelement 104 1 1 1}

# C_GLINE: two nodes + line geometry
*currentcollector component C_GLINE
set l0 [N 100 0 0]; set l1 [N 100 10 0]
T "GEOM_LINE_CREATE_V1" {*linecreatefromnodes $l0 $l1}
if {[catch {*linecreatefromnodes $l0 $l1} linErr]} {
    T "GEOM_LINE_CREATE_V2" {*linecreatefromnodes 2 $l0 $l1}
}

# C_GSURF: four nodes + surface geometry
*currentcollector component C_GSURF
set s0 [N 200 0 0]; set s1 [N 210 0 0]; set s2 [N 210 10 0]; set s3 [N 200 10 0]
T "GEOM_SURF_CREATE_V1" {*linearsurfacebetweennodes 4 $s0 $s1 $s2 $s3}
if {[catch {*linearsurfacebetweennodes 4 $s0 $s1 $s2 $s3} surfErr]} {
    T "GEOM_SURF_CREATE_V2" {*surfacesplineonnodesloop 4 $s0 $s1 $s2 $s3}
}

# C_NODEONLY: nodes only
*currentcollector component C_NODEONLY
N 300 0 0; N 300 10 0

catch {*clearmark comps 2}
T "PREVIEW_EMPTY_FINAL" {*EntityPreviewEmpty comps 2}
set emptyMarks [hm_getmark comps 2]
P "PREVIEW_EMPTY_MARKS" [lsort -integer $emptyMarks]
foreach id [lsort -integer $emptyMarks] {
    P "EMPTY_COMP $id" [hm_getvalue comps id=$id dataname=name]
}

# element counts of fixture comps
foreach cname {C_QUAD C_GLINE C_GSURF C_NODEONLY C_EMPTY2} {
    set cid ""
    catch {set cid [hm_getvalue comps name=$cname dataname=id]}
    catch {*clearmark elems 1}
    set rc [catch {*createmark elems 1 "by comp" $cid}]
    P "ELEMCOUNT $cname" [expr {$rc ? -1 : [llength [hm_getmark elems 1]]}]
    T "ELEMCOUNT_DN $cname" {hm_getvalue comps id=$cid dataname=elemcount}
}

# geometry counts (lines/surfaces per comp)
foreach cname {C_GLINE C_GSURF} {
    set cid ""
    catch {set cid [hm_getvalue comps name=$cname dataname=id]}
    catch {*clearmark lines 1}
    set rcL [catch {*createmark lines 1 "by comp" $cid}]
    P "LINECOUNT $cname" [expr {$rcL ? -1 : [llength [hm_getmark lines 1]]}]
    catch {*clearmark surfs 1}
    set rcS [catch {*createmark surfs 1 "by comp" $cid}]
    P "SURFCOUNT $cname" [expr {$rcS ? -1 : [llength [hm_getmark surfs 1]]}]
}

# --- F. Full module flow on imported entities (assign imported prop) ---------
set targetId ""
catch {set targetId [hm_getvalue comps name=C_EMPTY2 dataname=id]}
if {$targetId ne "" && $pid ne ""} {
    catch {*clearmark comps 1}
    T "MARK_TARGET" {*createmark comps 1 $targetId}
    T "PROPUPDATE_IMPORTED" {*propertyupdate comps 1 FIXTURE_T25}
    T "PROPUPDATE_IMPORTED_READBACK" {hm_getvalue comps id=$targetId dataname=propertyid}
    T "SETVALUE_PROPERTYID" {*setvalue comps id=$targetId propertyid=$pid}
    T "SETVALUE_PROPERTYID_READBACK" {hm_getvalue comps id=$targetId dataname=propertyid}
    catch {*clearmark comps 1}
}
if {$targetId ne ""} {
    T "COMP_NAME_READ" {hm_getvalue comps id=$targetId dataname=name}
    T "COMP_PROPERTY_READ" {hm_getvalue comps id=$targetId dataname=property}
}

close $channel
exit 0
