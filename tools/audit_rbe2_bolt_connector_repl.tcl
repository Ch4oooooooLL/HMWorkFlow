# ============================================================================
# *replacenodes argument-form probe for rbe2_bolt_connector replaceOneNode.
# The module calls: *replacenodes <src> <tgt> 1 0  (fails on both 2019/2022).
# Try documented/plausible variants and report which form merges src into tgt.
# Also: *createentity props cardimage=PBAR (module PBAR path), and a check of
# the *syncpropertybeamsectionvalues effect on a real linked section.
# Results: runtime/audit_rbe2_bolt_connector_repl_<version>.log
# ============================================================================

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [string trim [hm_info -appinfo VERSION]]
set reportPath [file join $outputDir "audit_rbe2_bolt_connector_repl_${version}.log"]
set ch [open $reportPath w]
fconfigure $ch -translation lf

proc P {key value} {
    variable ch
    regsub -all {[\r\n]} $value { } value
    puts $ch "${key}=${value}"
    flush $ch
}
proc TRY {prefix script} {
    variable ch
    if {[catch {uplevel 1 $script} result options]} {
        P "${prefix}_RC" 1
        P "${prefix}_ERR" $result
    } else {
        P "${prefix}_RC" 0
        P "${prefix}_VAL" [string trim $result]
    }
}
proc newNode {x y z} {
    *createnode $x $y $z 0 0 0
    catch {*clearmark nodes 1}
    *createmark nodes 1 all
    set ids [hm_getmark nodes 1]
    lindex [lsort -integer $ids] end
}
proc nodeExists {id} {
    if {$id eq ""} {return 0}
    set v ""
    catch {set v [hm_getvalue nodes id=$id dataname=id]}
    expr {$v ne "" && $v ne 0}
}
proc tryVariant {name flagArgs} {
    set src [newNode 90.0 0.0 0.0]
    set tgt [newNode 90.0 0.0 0.0]
    P "${name}_SRC_TGT" "$src $tgt"
    set cmd [concat [list *replacenodes] [list $src $tgt] $flagArgs]
    set rc [catch {uplevel 1 $cmd} err]
    P "${name}_RC" $rc
    P "${name}_ERR" $err
    P "${name}_SRC_GONE" [expr {![nodeExists $src]}]
    P "${name}_TGT_KEPT" [nodeExists $tgt]
}
proc trySwapped {name flagArgs} {
    set src [newNode 91.0 0.0 0.0]
    set tgt [newNode 91.0 0.0 0.0]
    P "${name}_SRC_TGT" "$src $tgt"
    set cmd [concat [list *replacenodes] [list $tgt $src] $flagArgs]
    set rc [catch {uplevel 1 $cmd} err]
    P "${name}_RC" $rc
    P "${name}_ERR" $err
    P "${name}_SRC_GONE" [expr {![nodeExists $src]}]
    P "${name}_TGT_KEPT" [nodeExists $tgt]
}

P "VERSION" $version

# module form (src tgt 1 0)
tryVariant M_SRC_TGT_1_0 {1 0}
# flag variants
tryVariant V_SRC_TGT_0_0 {0 0}
tryVariant V_SRC_TGT_0_1 {0 1}
tryVariant V_SRC_TGT_1_1 {1 1}
# 2-arg and 3-arg forms
tryVariant V_TWOARG {}
tryVariant V_THREEARG_0 {0}
tryVariant V_THREEARG_1 {1}
# swapped order (target first)
trySwapped V_TGT_SRC_1_0 {1 0}
trySwapped V_TGT_SRC_0 {0}

# *createentity props cardimage=PBAR (module CBAR path)
catch {*createentity props cardimage=PBAR includeid=0 name=AUDIT_PBAR2} pe
P "CREATE_PROP_PBAR_RC" [expr {$pe eq "" ? 0 : 1}]
P "CREATE_PROP_PBAR_ERR" $pe
set pbid ""
catch {set pbid [hm_getvalue props name=AUDIT_PBAR2 dataname=id]}
if {$pbid eq ""} {
    # 2019 may have renamed the prop on import failure; find by fallback name scan
    catch {*createmark props 1 all}
    set allP [hm_getmark props 1]
    foreach id [lsort -integer $allP] {
        set nm ""
        catch {set nm [hm_getvalue props id=$id dataname=name]}
        if {$nm eq "AUDIT_PBAR2"} { set pbid $id }
    }
}
P "CREATE_PROP_PBAR_ID" $pbid
if {$pbid ne ""} {
    TRY PBAR_CARD_READ [list hm_getvalue props id=$pbid dataname=cardimage]
}

# *syncpropertybeamsectionvalues behavior with a fully linked section
# (reuse pattern from the module: create section, link attr, mark props, sync)
TRY SECTION_CREATE [list *beamsectioncreatestandardsolver 11 0 HMCirc 0]
set sectId ""
catch {set sectId [hm_latestentityid beamsects]}
P "SECTION_ID" $sectId
set collId ""
catch {set collId [hm_getvalue beamsects id=$sectId dataname=setid]}
TRY SECTION_DATAROOT [list *beamsectionsetdataroot $sectId $collId 0 2 7 1 0 1.0 1.0 0 0 0 0]
TRY SECTION_DOUBLEARRAY [list *createdoublearray 3 6.0 0.006 6000.0]
TRY SECTION_DATASET [list *beamsectionsetdatastandard 1 3 $sectId 11 0 HMCirc]
TRY ATTR_LINK [list *attributeupdateentity properties $pbid 3179 1 2 0 beamsects $sectId]
catch {*clearmark props 1}
TRY SYNC_MARK [list *createmark props 1 $pbid]
TRY SYNC_PROP [list *syncpropertybeamsectionvalues 1]
foreach dn {A I1 I2 J} {
    TRY "PBAR_AFTERSYNC_$dn" [list hm_getvalue props id=$pbid dataname=$dn]
}
# read section radius back to confirm the section data took
TRY SECTION_RADIUS [list hm_getvalue beamsects id=$sectId dataname=radius]

close $ch
catch {puts "repl probe done: $reportPath"}
exit 0
