# MidSurf module functional probe (part 2: full pipeline on a real model).
#
# Mirrors modules/midsurf.tcl exactly:
#   *midsurface_extract_10 (19-arg documented call, then the 17-arg fallback),
#   thickness reads (hm_getthickness / dataname=thickness /
#   hm_getsurfacethicknessvalues via hm_getsurfaceedges + hm_getverticesfromedge),
#   volume/area measurement (hm_getvolumeofsolid / hm_getareaofsurface),
#   rename (renamecollector), assembly (*createentity assems /
#   *assemblymodifyhierarchy / *assemblyaddmark), display family, history.
#
# Run headless, one hmbatch per installed build:
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_midsurf_extract.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe"   -nocommand -nouserprofiledialog -tcl tools/audit_midsurf_extract.tcl
#
# Results: runtime/audit_midsurf_extract_<version>.log (ASCII KEY=VALUE).

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_midsurf_extract_${version}.log"]
set channel [open $reportPath w]
proc P {key value} {
    global channel
    puts $channel "${key}=${value}"
    flush $channel
}
proc try {label args} {
    # args = full command word list; log OK / ERR <message>
    if {[catch {uplevel #0 {*}$args} value]} {
        P "$label" "ERR [regsub -all {\s+} [string trim $value] { }]"
        return 0
    }
    P "$label" "OK"
    return 1
}
proc query {label script} {
    # log LABEL_RC=0/1 and LABEL_VALUE=<result>
    set rc [catch {uplevel #0 $script} value]
    P "${label}_RC" $rc
    P "${label}_VALUE" [regsub -all {\s+} [string trim $value] { }]
    if {$rc} { return "" }
    return $value
}

P "VERSION" $version
P "SCRIPT_START" 1

proc audit_main {} {
proc has {name} {
    set pat [string map {* {\*} ? {\?} [ {\[} ] {\]} \\ {\\\\}} $name]
    expr {[llength [info commands $pat]] > 0}
}
foreach name {*midsurfaceextract *midsurface_extract_new *solids_create_from_surfaces
              *midmesh_extract *compute_midmesh_thickness *estimate_geom_thickness
              hm_getmidsurfcomp hm_getcompthickness hm_estimategeomthicknesslimits
              hm_getnodalthickness hmbr_signals hwbrowsermanager} {
    P "EXISTS $name" [expr {[has $name] ? 1 : 0}]
}

# --------------------------------------------------------------------------
# Fixture 1: two parallel sheet surfaces (10x10 mm, 2 mm apart) in SRC_SHEET
# --------------------------------------------------------------------------
try COLLECTOR_SHEET [list *collectorcreateonly components SRC_SHEET "" 1]
try CURRENT_SHEET [list *currentcollector component SRC_SHEET]
foreach {x y z} {0 0 10  10 0 10  10 10 10  0 10 10  0 0 12  10 0 12  10 10 12  0 10 12} {
    catch {*createpoint $x $y $z 0}
}
catch {*clearmark points 1}
*createmark points 1 all
set pts [lsort -integer [hm_getmark points 1]]
P "SHEET_POINTS" [llength $pts]
# surface 1 from the four z=10 points, surface 2 from the four z=12 points
catch {*clearmark points 1}
eval *createmark points 1 [lrange $pts 0 3]
try SURFP1 [list *surfaceprimitivefrompoints points 1 1 0 0]
catch {*clearmark points 1}
eval *createmark points 1 [lrange $pts 4 7]
try SURFP2 [list *surfaceprimitivefrompoints points 1 1 0 0]
catch {*clearmark surfs 1}
*createmark surfs 1 all
P "SHEET_SURFS" [join [hm_getmark surfs 1] { }]

# --- extraction on surfaces (module's 19-arg call, rerunType=9, normals=-1) --
catch {*clearmark surfs 1}
*createmark surfs 1 all
set extractByComp [expr {1 + 10}]   ;# extractByComp=1 + 10 (keepTransparency path)
set cmd19s [list *midsurface_extract_10 surfaces 1 -1 0 1 $extractByComp 9 0 2.0 0 0 10.0 0 0 0.5 undefined 0 0 1]
try EXTRACT_SURFS_19ARGS $cmd19s
query HM_GETMIDSURFCOMP_SHEETS {hm_getmidsurfcomp}
set midId [query MID_COMP_SHEETS {hm_entityinfo id comps "Middle Surface" -byname}]
if {$midId ne "" && $midId ne 0} {
    catch {*clearmark surfs 1}
    *createmark surfs 1 "by comp id" $midId
    set midSurfs [hm_getmark surfs 1]
    P "MID_SURF_COUNT_SHEETS" [llength $midSurfs]
    P "MID_SURF_IDS_SHEETS" [join $midSurfs { }]
    # thickness reads on the extracted midsurface (module readThicknessFromSurface)
    set thick {}
    set sample {}
    foreach s $midSurfs {
        if {[catch {set loops [hm_getsurfaceedges $s]}]} { continue }
        foreach loop $loops {
            foreach e $loop {
                if {[catch {set ev [hm_getverticesfromedge $e]}]} { continue }
                foreach pt $ev {
                    if {[catch {set raw [hm_getsurfacethicknessvalues points $pt]}]} { continue }
                    foreach item $raw {
                        if {[llength $item] >= 3} {
                            lappend thick [lindex $item 1]
                            if {[llength $sample] < 3} { lappend sample $item }
                        }
                    }
                }
            }
        }
    }
    P "SHEET_THICKNESS_READS" [llength $thick]
    P "SHEET_THICKNESS_VALUES" [join $thick { }]
    P "SHEET_THICKNESS_SAMPLE" [join $sample { }]
    query SHEET_HM_GETTHICKNESS [list hm_getthickness comps $midId]
    query SHEET_DATANAME_THICKNESS [list hm_getvalue comps id=$midId dataname=thickness]
    if {[llength $midSurfs] > 0} {
        query SHEET_AREA_SURF0 [list hm_getareaofsurface surfs [lindex $midSurfs 0]]
    }
    try RENAME_MID_SHEETS [list *renamecollector component "Middle Surface" "MID_SHEET_T2"]
    query RENAME_VERIFY_SHEETS [list hm_getcollectorname comps [hm_entityinfo id comps "MID_SHEET_T2" -byname]]
}

# --------------------------------------------------------------------------
# Fixture 2: solid box 20x20x2 mm in SRC_SOLID
# *create_solid_from_eight_points exists on 2022 only; on 2019 fall back to
# six planar surfaces + *solids_create_from_surfaces.
# --------------------------------------------------------------------------
try COLLECTOR_SOLID [list *collectorcreateonly components SRC_SOLID "" 2]
try CURRENT_SOLID [list *currentcollector component SRC_SOLID]
set solidArgs [list \
    Point1={0 0 0} Point2={0 20 0} Point3={20 0 0} Point4={20 20 0} \
    Point5={0 0 2} Point6={0 20 2} Point7={20 0 2} Point8={20 20 2}]
set solidOk [try SOLID_FROM_POINTS [list *create_solid_from_eight_points {*}$solidArgs]]
if {!$solidOk} {
    # box corners: A=(0,0,0) B=(0,20,0) C=(20,20,0) D=(20,0,0)
    #              E=(0,0,2) F=(0,20,2) G=(20,20,2) H=(20,0,2)
    set corners [list \
        {0 0 0} {0 20 0} {20 20 0} {20 0 0} \
        {0 0 2} {0 20 2} {20 20 2} {20 0 2}]
    set cornerIds {}
    foreach c $corners {
        lassign $c x y z
        catch {*createpoint $x $y $z 0}
        catch {*clearmark points 1}
        *createmark points 1 -1
        lappend cornerIds [lindex [lsort -integer [hm_getmark points 1]] 0]
    }
    P "BOX_CORNER_IDS" [join $cornerIds { }]
    # face quads: bottom ABCD top EFGH front AEHD back BFGC left ABFE right DCGH
    set faces [list [list 0 1 2 3] [list 4 5 6 7] [list 0 4 7 3] [list 1 5 6 2] [list 0 1 5 4] [list 3 7 6 2]]
    set faceIdx 0
    foreach face $faces {
        catch {*clearmark points 1}
        set facePts {}
        foreach idx $face { lappend facePts [lindex $cornerIds $idx] }
        eval *createmark points 1 $facePts
        try SURFP_BOX_$faceIdx [list *surfaceprimitivefrompoints points 1 1 0 0]
        incr faceIdx
    }
    catch {*clearmark surfs 1}
    *createmark surfs 1 all
    set allSurfs [hm_getmark surfs 1]
    P "BOX_SURFS" [join $allSurfs { }]
    set boxSurfs [lrange $allSurfs end-5 end]
    P "BOX_SURFS_IDS" [join $boxSurfs { }]
    catch {*clearmark surfs 1}
    eval *createmark surfs 1 $boxSurfs
    try SELFSTITCH [list *selfstitchcombine 1 3 0.01 0.01]
    foreach depthArgs {{1 0 1 1} {1 0 1 0} {1 1 1 1} {1 4 0 1}} {
        if {[try SOLIDS_FROM_SURFS_[join $depthArgs _] [list *solids_create_from_surfaces {*}$depthArgs]]} {
            break
        }
    }
}
catch {*clearmark solids 1}
*createmark solids 1 all
set solids [hm_getmark solids 1]
P "SOLIDS_COUNT" [llength $solids]
P "SOLIDS_IDS" [join $solids { }]
set volume ""
if {[llength $solids] > 0} {
    set volume [query SOLID_VOLUME [list hm_getvolumeofsolid solids [lindex $solids 0]]]
    # comp dataname probes used by ::MidSurf::getCompEntityIds
    foreach dn {solids surfaces points thickness} {
        query DATANAME_COMP_$dn [list hm_getvalue comps name=SRC_SOLID dataname=$dn]
    }
}

# --- extraction on solids (module's 19-arg call, normals=3) -----------------
catch {*clearmark solids 1}
*createmark solids 1 all
set cmd19b [list *midsurface_extract_10 solids 1 3 0 1 1 9 0 2.0 0 0 10.0 0 0 0.5 undefined 0 0 1]
try EXTRACT_SOLIDS_19ARGS $cmd19b
query HM_GETMIDSURFCOMP_SOLIDS {hm_getmidsurfcomp}
set midId2 [query MID_COMP_SOLIDS {hm_entityinfo id comps "Middle Surface" -byname}]
if {$midId2 ne "" && $midId2 ne 0} {
    catch {*clearmark surfs 1}
    *createmark surfs 1 "by comp id" $midId2
    set midSurfs2 [hm_getmark surfs 1]
    P "MID_SURF_COUNT_SOLID" [llength $midSurfs2]
    # module thickness chain on the solid-derived midsurface
    set thick2 {}
    foreach s $midSurfs2 {
        if {[catch {set loops [hm_getsurfaceedges $s]}]} { continue }
        foreach loop $loops {
            foreach e $loop {
                if {[catch {set ev [hm_getverticesfromedge $e]}]} { continue }
                foreach pt $ev {
                    if {[catch {set raw [hm_getsurfacethicknessvalues points $pt]}]} { continue }
                    foreach item $raw {
                        if {[llength $item] >= 3} { lappend thick2 [lindex $item 1] }
                    }
                }
            }
        }
    }
    P "SOLID_THICKNESS_READS" [llength $thick2]
    P "SOLID_THICKNESS_VALUES" [join $thick2 { }]
    query SOLID_HM_GETTHICKNESS [list hm_getthickness comps $midId2]
    query SOLID_DATANAME_THICKNESS [list hm_getvalue comps id=$midId2 dataname=thickness]
    # volume/area fallback measurement (module measureThicknessByVolumeArea)
    if {[llength $midSurfs2] > 0 && $volume ne "" && [string is double -strict $volume] && $volume > 0.0} {
        set totArea 0.0
        set areaCount 0
        foreach s $midSurfs2 {
            if {![catch {set a [hm_getareaofsurface surfs $s]}] && [string is double -strict $a] && $a > 0.0} {
                set totArea [expr {$totArea + $a}]
                incr areaCount
            }
        }
        P "SOLID_MID_AREA_TOTAL" [format %.6g $totArea]
        P "SOLID_AREA_COUNT" $areaCount
        P "SOLID_VOLUME_AREA_RATIO" [format %.6g [expr {double($volume) / $totArea}]]
    }
    try RENAME_MID_SOLID [list *renamecollector component "Middle Surface" "MID_SOLID_T2"]
}

# --- 17-arg fallback layout (module's second attempt) ------------------------
try COLLECTOR_SOLID2 [list *collectorcreateonly components SRC_SOLID2 "" 3]
try CURRENT_SOLID2 [list *currentcollector component SRC_SOLID2]
try SOLID2_FROM_POINTS [list *create_solid_from_eight_points {*}$solidArgs]
catch {*clearmark solids 1}
*createmark solids 1 all
set cmd17 [list *midsurface_extract_10 solids 1 3 0 1 1 9 0 2.0 10.0 0 0 0.5 undefined 0 0 1]
try EXTRACT_SOLIDS_17ARGS $cmd17
set midId3 [query MID_COMP_17ARGS {hm_entityinfo id comps "Middle Surface" -byname}]
if {$midId3 ne "" && $midId3 ne 0} {
    try RENAME_MID_17 [list *renamecollector component "Middle Surface" "MID_17ARGS_T2"]
}

# --- assembly organization (module organizeOutputComponent) ------------------
try ASSEMBLY_CREATEENTITY [list *createentity assems name=MIDSURFED]
set asmId [query ASSEMBLY_ID {hm_entityinfo id assemblies "MIDSURFED" -byname}]
set asmTestComp [query ASM_TEST_COMP_ID {hm_entityinfo id comps "MID_SHEET_T2" -byname}]
if {$asmTestComp ne "" && $asmTestComp ne 0} {
    catch {*clearmark comps 1}
    eval *createmark comps 1 $asmTestComp
    try ASSEMBLY_MODIFY_HIER [list *assemblymodifyhierarchy MIDSURFED 1 9]
    try ASSEMBLY_MODIFY [list *assemblymodify MIDSURFED 1 9]
}
if {$asmId ne "" && $asmId ne 0 && $asmTestComp ne "" && $asmTestComp ne 0} {
    catch {*clearmark comps 1}
    eval *createmark comps 1 $asmTestComp
    try ASSEMBLY_ADDMARK [list *assemblyaddmark $asmId comps 1]
    query ASSEMBLY_MEMBERS [list hm_getvalue assemblies id=$asmId dataname=components]
}
catch {*clearmark comps 1}
*createmark comps 1 all
P "COMPS_TOTAL" [llength [hm_getmark comps 1]]

# --- renamecollector token variants ------------------------------------------
try COLLECTOR_RN [list *collectorcreateonly components RNTOKENTEST "" 4]
foreach token {components comps} {
    set rn [catch {*renamecollector $token RNTOKENTEST RNTOKENTEST_RENAMED} rnErr]
    P "RENAMECOLLECTOR_$token" [expr {$rn ? "ERR [regsub -all {\s+} [string trim $rnErr] { }]" : "OK"}]
    if {!$rn} {
        query RENAMECOLLECTOR_${token}_VERIFY [list hm_getcollectorname comps [hm_entityinfo id comps "RNTOKENTEST_RENAMED" -byname]]
        break
    }
}

# --- display family (module refreshComponentBrowser / hideSourceComponent) ---
set dispName MID_SHEET_T2
if {$midId2 ne "" && $midId2 ne 0} { set dispName MID_SOLID_T2 }
try DISPLAY_COLLECTOR_ON [list *displaycollector component on $dispName 1 1]
try DISPLAY_COLLECTOR_OFF [list *displaycollector components off $dispName 1 1]
catch {*clearmark comps 2}
*createmark comps 2 "by name" $dispName
try DISPLAY_BY_MARK [list *displaycollectorsbymark comps 2 on 1 1]
try DISPLAY_ALL_BY_MARK [list *displaycollectorsallbymark 2 on 1 1]
try DISPLAY_WITH_FILTER [list *displaycollectorwithfilter component on $dispName 1 1]
try MARKSUPPRESS_ACTIVE [list *marksuppressactive comps 2 0]
try MARKSUPPRESS_OUTPUT [list *marksuppressoutput comps 2 0]
try CURRENTCOLLECTOR [list *currentcollector component $dispName]

# --- history + browser plumbing (module renameMiddleSurface) -----------------
try START_NOTE_HISTORY [list *startnotehistorystate "AuditProbeRename"]
try END_NOTE_HISTORY [list *endnotehistorystate "AuditProbeRename"]
try HMBR_SIGNALS [list hmbr_signals buffer stop]
try HWBROWSER_FLUSH [list hwbrowsermanager view flush true]
try HM_BLOCKREDRAW [list hm_blockredraw 0]
try HM_BLOCKMESSAGES [list hm_blockmessages 0]
try HM_BLOCKERRORMESSAGES [list hm_blockerrormessages 0]
try HM_COMMANDFILESTATE [list hm_commandfilestate 1]
try HM_REDRAW [list hm_redraw]
}

if {[catch {audit_main} auditErr]} {
    P "FATAL" [regsub -all {\s+} [string trim $auditErr] { }]
}
close $channel
exit 0
