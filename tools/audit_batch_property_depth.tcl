# Depth probe for batch_property_assignment audit: user-profile influence on
# MAT1/PSHELL field writes (*setvalue E=/T=), *attributeupdatedouble 95
# semantics with fem-export ground truth, hm_getthickness props behavior,
# and *EntityPreviewEmpty treatment of geometry-only components.
#
# Run headless (one launch per version):
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_batch_property_depth.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_batch_property_depth.tcl
#
# Results to runtime/audit_batch_property_depth_<version>.log, ASCII KEY=VALUE.

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_batch_property_depth_${version}.log"]
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

# --- A. Profile discovery ---------------------------------------------------
P "CMDS_PROFILE" [lsort [info commands *profile*]]
P "CMDS_FRAMEWORK" [lsort [info commands hm_framework*]]
T "PROFILE_GET" {hm_framework getuserprofile}
T "PROFILE_INFO" {hm_info -appinfo PROFILE}

# --- B. Baseline mats under the current (default) profile -------------------
T "BASE_CREATE_MAT" {*createentity mats cardimage=MAT1 includeid=0 name=BASE_MAT}
set bmid ""
T "BASE_MAT_ID" {set bmid [hm_getvalue mats name=BASE_MAT dataname=id]}
P "BASE_MAT_ID_VALUE" $bmid
if {$bmid ne ""} {
    T "BASE_CARDIMAGE_READ" {hm_getvalue mats id=$bmid dataname=cardimage}
    T "BASE_READ_E" {hm_getvalue mats id=$bmid dataname=E}
    T "BASE_SET_E_STATUS1" {*setvalue mats id=$bmid STATUS=1 E=210000.0}
    T "BASE_SET_E_STATUS2" {*setvalue mats id=$bmid STATUS=2 E=210000.0}
}

# --- C. Load the OptiStruct user profile (module's real environment) --------
T "LOAD_OS" {hm_framework loaduserprofile OptiStruct}
T "PROFILE_GET_AFTER" {hm_framework getuserprofile}

# --- D. Mats under OptiStruct profile ---------------------------------------
T "OS_CREATE_MAT" {*createentity mats cardimage=MAT1 includeid=0 name=OS_MAT}
set osmid ""
T "OS_MAT_ID" {set osmid [hm_getvalue mats name=OS_MAT dataname=id]}
P "OS_MAT_ID_VALUE" $osmid
if {$osmid ne ""} {
    T "OS_CARDIMAGE_READ" {hm_getvalue mats id=$osmid dataname=cardimage}
    T "OS_READ_E_BEFORE" {hm_getvalue mats id=$osmid dataname=E}
    T "OS_SET_E" {*setvalue mats id=$osmid STATUS=1 E=210000.0}
    T "OS_READ_E" {hm_getvalue mats id=$osmid dataname=E}
    T "OS_SET_E_NOSTATUS" {*setvalue mats id=$osmid E=211000.0}
    T "OS_READ_E_AFTER_NOSTATUS" {hm_getvalue mats id=$osmid dataname=E}
    T "OS_SET_NU" {*setvalue mats id=$osmid STATUS=1 Nu=0.30}
    T "OS_READ_NU" {hm_getvalue mats id=$osmid dataname=Nu}
    T "OS_SET_RHO" {*setvalue mats id=$osmid STATUS=1 Rho=7.85e-9}
    T "OS_READ_RHO" {hm_getvalue mats id=$osmid dataname=Rho}
    T "OS_SET_NUM1" {*setvalue mats id=$osmid STATUS=1 1=212000.0}
    T "OS_READ_NUM1" {hm_getvalue mats id=$osmid dataname=1}
    # attribute-based writes for MAT1 fields (module fallback candidate)
    foreach attr {1 2 3 4 5} {
        set val [expr {220000 + $attr * 1000}]
        T "OS_ATTR_MATS_$attr" {*attributeupdatedouble mats $osmid $attr 1 1 0 $val}
        T "OS_READ_E_AFTER_ATTR_$attr" {hm_getvalue mats id=$osmid dataname=E}
    }
    T "OS_WRITEFILE_MATS" {*writefile [file nativename [file join $outputDir audit_bpa_mats_${version}.fem]] 1}
}

# --- E. PSHELL under OptiStruct profile -------------------------------------
T "OS_CREATE_PROP" {*createentity props cardimage=PSHELL includeid=0 name=OS_PROP}
set ospid ""
T "OS_PROP_ID" {set ospid [hm_getvalue props name=OS_PROP dataname=id]}
P "OS_PROP_ID_VALUE" $ospid
if {$ospid ne "" && $osmid ne ""} {
    T "OS_PROP_CARDIMAGE" {hm_getvalue props id=$ospid dataname=cardimage}
    T "OS_PROP_SET_MID" {*setvalue props id=$ospid STATUS=1 materialid=$osmid}
    T "OS_PROP_READ_MID" {hm_getvalue props id=$ospid dataname=materialid}
    T "OS_GETTHICKNESS_0" {hm_getthickness props $ospid}
    T "OS_PROP_READ_T_BEFORE" {hm_getvalue props id=$ospid dataname=T}
    T "OS_PROP_READ_THICKNESS_BEFORE" {hm_getvalue props id=$ospid dataname=thickness}
    # Method A: *setvalue thickness= (module fallback)
    T "OS_METHODA_SET" {*setvalue props id=$ospid STATUS=1 thickness=2.75}
    T "OS_METHODA_READ_THICK" {hm_getvalue props id=$ospid dataname=thickness}
    T "OS_METHODA_READ_T" {hm_getvalue props id=$ospid dataname=T}
    T "OS_METHODA_GETTHICKNESS" {hm_getthickness props $ospid}
    T "OS_WRITEFILE_A" {*writefile [file nativename [file join $outputDir audit_bpa_propA_${version}.fem]] 1}
    # Method B: attribute 95, module's exact 7-arg form
    T "OS_METHODB_ATTR95" {*attributeupdatedouble properties $ospid 95 1 1 0 3.0}
    T "OS_METHODB_READ_THICK" {hm_getvalue props id=$ospid dataname=thickness}
    T "OS_METHODB_READ_T" {hm_getvalue props id=$ospid dataname=T}
    T "OS_METHODB_GETTHICKNESS" {hm_getthickness props $ospid}
    T "OS_WRITEFILE_B" {*writefile [file nativename [file join $outputDir audit_bpa_propB_${version}.fem]] 1}
    # Method C: attribute 95, 6-arg form (status index value)
    T "OS_METHODC_ATTR95_6" {*attributeupdatedouble properties $ospid 95 1 0 3.5}
    T "OS_METHODC_READ_THICK" {hm_getvalue props id=$ospid dataname=thickness}
    T "OS_METHODC_GETTHICKNESS" {hm_getthickness props $ospid}
    T "OS_WRITEFILE_C" {*writefile [file nativename [file join $outputDir audit_bpa_propC_${version}.fem]] 1}
    # Method D: *setvalue T=
    T "OS_METHODD_SET_T" {*setvalue props id=$ospid STATUS=1 T=2.25}
    T "OS_METHODD_READ_THICK" {hm_getvalue props id=$ospid dataname=thickness}
    T "OS_METHODD_READ_T" {hm_getvalue props id=$ospid dataname=T}
    T "OS_METHODD_GETTHICKNESS" {hm_getthickness props $ospid}
    T "OS_WRITEFILE_D" {*writefile [file nativename [file join $outputDir audit_bpa_propD_${version}.fem]] 1}
}

# --- F. *EntityPreviewEmpty vs geometry-only components ----------------------
P "CMDS_LINE" [lsort [info commands *line*]]
P "CMDS_SURFACE" [lsort [info commands *surface*]]

# C_QUAD: one real quad
*currentcollector component C_QUAD
set q0 [N 0 0 0]; set q1 [N 10 0 0]; set q2 [N 10 10 0]; set q3 [N 0 10 0]
eval *createlist nodes 1 [list $q0 $q1 $q2 $q3]
T "F_QUAD_CREATE" {*createelement 104 1 1 1}

# C_GLINE: two nodes + line geometry (if the command exists)
*currentcollector component C_GLINE
set l0 [N 100 0 0]; set l1 [N 100 10 0]
T "F_LINE_CREATE" {*createline $l0 $l1}

# C_GSURF: four nodes + surface geometry (if the command exists)
*currentcollector component C_GSURF
set s0 [N 200 0 0]; set s1 [N 210 0 0]; set s2 [N 210 10 0]; set s3 [N 200 10 0]
T "F_SURF_CREATE" {*createsurface 4 $s0 $s1 $s2 $s3}

# C_NODEONLY: nodes only
*currentcollector component C_NODEONLY
N 300 0 0; N 300 10 0

# C_EMPTY2: nothing
*collectorcreateonly comps C_EMPTY2 "" 8

catch {*clearmark comps 2}
T "F_PREVIEW_EMPTY" {*EntityPreviewEmpty comps 2}
set emptyMarks [hm_getmark comps 2]
P "F_PREVIEW_EMPTY_MARKS" [lsort -integer $emptyMarks]
foreach id [lsort -integer $emptyMarks] {
    P "F_EMPTY_COMP $id" [hm_getvalue comps id=$id dataname=name]
}

# element/geometry counts per fixture comp
foreach cname {C_QUAD C_GLINE C_GSURF C_NODEONLY C_EMPTY2} {
    set cid ""
    catch {set cid [hm_getvalue comps name=$cname dataname=id]}
    catch {*clearmark elems 1}
    set rc [catch {*createmark elems 1 "by comp" $cid}]
    P "F_ELEMCOUNT $cname" [expr {$rc ? -1 : [llength [hm_getmark elems 1]]}]
    T "F_COMP_ELEMCOUNT_DN $cname" {hm_getvalue comps id=$cid dataname=elemcount}
}

close $channel
exit 0
