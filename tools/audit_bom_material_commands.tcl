# Audit probe for every HyperMesh native command used by
# modules/bom_material_assignment.tcl.  Verifies existence, argument forms,
# and semantics on the installed build, and enumerates official alternatives.
#
# Run headless (one launch covers everything):
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_bom_material_commands.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_bom_material_commands.tcl
#
# Results are written to runtime/audit_bom_material_<version>.log as
# KEY=VALUE lines (ASCII only, no stdout channel under hmbatch).

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_bom_material_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    regsub -all {[\r\n]+} $value " | " value
    puts $channel "${key}=${value}"
}

proc TRY {label script} {
    set code [catch {uplevel 1 $script} result]
    if {$code == 0} {
        P "$label" "OK:[string trim $result]"
    } else {
        regsub -all {[\r\n]+} $result " | " result
        P "$label" "ERR:$result"
    }
}

proc MARKCOUNT {t markId} {
    set ids [hm_getmark $t $markId]
    expr {[llength $ids]}
}

P "HM_VERSION" $version

# --- A. Entity type validity (*createmark ... all) ---------------------------
# The module tries plural aliases (comps/components, mats/materials,
# assemblies/assems/assembly) as defensive fallbacks.
foreach t {comps components component mats materials material assemblies assems assembly} {
    TRY "A_CREATEMARK_ALL $t" {
        catch {*clearmark $t 1}
        *createmark $t 1 all
        P "A_COUNT $t" [MARKCOUNT $t 1]
    }
}

# --- B. Fixture: two components ----------------------------------------------
TRY "B_CREATE_COMP1" {*createentity comps includeid=0 name=PROBE_BOM_C1}
TRY "B_CREATE_COMP2" {*createentity comps includeid=0 name=PROBE_BOM_C2}
set c1 ""
catch {set c1 [hm_getvalue comps name=PROBE_BOM_C1 dataname=id]}
set c2 ""
catch {set c2 [hm_getvalue comps name=PROBE_BOM_C2 dataname=id]}
P "B_COMP_IDS" "$c1,$c2"

# --- B2. Assembly creation methods + name lookup ------------------------------
catch {*clearmark comps 1}
if {$c1 ne "" && $c2 ne ""} {
    *createmark comps 1 $c1 $c2
}
TRY "B2_ASSEMBLYMODIFYHIERARCHY" {*assemblymodifyhierarchy PROBE_ASM 1 9}
TRY "B2_ASSEMBLYMODIFY" {*assemblymodify PROBE_ASM 1 9}
TRY "B2_CREATEENTITY_ASSEMS" {*createentity assems name=PROBE_ASM}
TRY "B2_CREATEENTITY_ASSEMBLIES" {*createentity assemblies name=PROBE_ASM}
TRY "B2_ENTITYINFO_ASSEMBLIES_BYNAME" {hm_entityinfo id assemblies PROBE_ASM -byname}
TRY "B2_ENTITYINFO_ASSEMS_BYNAME" {hm_entityinfo id assems PROBE_ASM -byname}
TRY "B2_GETVALUE_ASSEMBLIES" {hm_getvalue assemblies name=PROBE_ASM dataname=id}
TRY "B2_GETVALUE_ASSEMS" {hm_getvalue assems name=PROBE_ASM dataname=id}
set asmId ""
catch {set asmId [hm_getvalue assemblies name=PROBE_ASM dataname=id]}
if {$asmId eq ""} {
    catch {set asmId [hm_getvalue assems name=PROBE_ASM dataname=id]}
}
P "B2_ASM_ID" $asmId
TRY "B2_MARK_ASSEMBLIES_ALL" {catch {*clearmark assemblies 1}; *createmark assemblies 1 all; P "B2_ASSEMBLIES_COUNT" [MARKCOUNT assemblies 1]}
TRY "B2_MARK_ASSEMS_ALL" {catch {*clearmark assems 1}; *createmark assems 1 all; P "B2_ASSEMS_COUNT" [MARKCOUNT assems 1]}

# --- C. *createentity mats (module: cardimage=MAT1 includeid=0 name=Q355) -----
set matReturn ""
TRY "C_CREATEENTITY_MATS" {set matReturn [*createentity mats cardimage=MAT1 includeid=0 name=PROBE_Q355]}
P "C_CREATEENTITY_RETURN" $matReturn
set mid ""
catch {set mid [hm_getvalue mats name=PROBE_Q355 dataname=id]}
P "C_MAT_ID_BY_NAME" $mid
TRY "C_CREATEENTITY_MATERIALS" {*createentity materials cardimage=MAT1 includeid=0 name=PROBE_Q355B}
TRY "C_CREATEENTITY_NO_INCLUDE" {*createentity mats cardimage=MAT1 name=PROBE_Q355C}
# module fallback: *createmark mats 1 -1 (last created)
TRY "C_MARK_LAST_NEG1" {
    catch {*clearmark mats 1}
    *createmark mats 1 -1
    P "C_MARK_LAST_IDS" [join [hm_getmark mats 1] {,}]
}

# --- D. hm_entityinfo forms (module: id <type> <name> -byname) ----------------
TRY "D_ENTITYINFO_BYNAME_FLAG" {hm_entityinfo id mats PROBE_Q355 -byname}
TRY "D_ENTITYINFO_BYNAME_NOFLAG" {hm_entityinfo id mats PROBE_Q355}
TRY "D_ENTITYINFO_BYID_FLAG" {hm_entityinfo name mats $mid -byid}
TRY "D_ENTITYINFO_COMP_BYNAME_FLAG" {hm_entityinfo id comps PROBE_BOM_C1 -byname}
TRY "D_GETVALUE_NAME_ID" {hm_getvalue mats name=PROBE_Q355 dataname=id}

# --- E. *setvalue MAT1 card fields (module: E/Nu/Rho names + 1/3/4 numbers,
#        STATUS=1 flag, cardimage=MAT1) ----------------------------------------
if {$mid ne ""} {
    foreach pair [list "E=206000.0" "1=206000.0" "Nu=0.30" "3=0.30" "Rho=7.85e-9" "4=7.85e-9"] {
        TRY "E_SET $pair" {*setvalue mats id=$mid STATUS=1 $pair}
    }
    foreach dn {E 1 G 2 Nu 3 Rho 4 cardimage} {
        TRY "E_READ $dn" {hm_getvalue mats id=$mid dataname=$dn}
    }
    TRY "E_SET_CARDIMAGE" {*setvalue mats id=$mid cardimage=MAT1}
    TRY "E_SET_BY_NAME_SELECTOR" {*setvalue mats name=PROBE_Q355 STATUS=1 E=210000.0}
    TRY "E_READ_AFTER_NAME_SET" {hm_getvalue mats id=$mid dataname=E}
    TRY "E_GETVALUE_MAT_NAME" {hm_getvalue mats id=$mid dataname=name}
}

# --- F. *renamecollector entity-type forms (module: component, components) ----
TRY "F_RENAME_COMPONENT_SINGULAR" {*renamecollector component PROBE_BOM_C1 PROBE_BOM_C1A}
TRY "F_RENAME_COMPONENTS_PLURAL" {*renamecollector components PROBE_BOM_C2 PROBE_BOM_C2A}
TRY "F_RENAME_COMPS" {*renamecollector comps PROBE_BOM_C1A PROBE_BOM_C1B}
TRY "F_GETCOLLECTORNAME" {hm_getcollectorname comps $c1}

# --- G. comps materialid dataname read/write ----------------------------------
if {$c1 ne "" && $mid ne ""} {
    foreach dn {materialid material.id material} {
        TRY "G_READ_COMP_BEFORE $dn" {hm_getvalue comps id=$c1 dataname=$dn}
    }
    TRY "G_SETVALUE_COMP_ID" {*setvalue comps id=$c1 materialid=$mid}
    foreach dn {materialid material.id material} {
        TRY "G_READ_COMP_AFTER $dn" {hm_getvalue comps id=$c1 dataname=$dn}
    }
    # module fallback: mark-based assignment
    TRY "G_SETVALUE_MARK" {
        catch {*clearmark comps 1}
        *createmark comps 1 $c1 $c2
        *setvalue comps mark=1 materialid=$mid
        P "G_MARK_COUNT" [MARKCOUNT comps 1]
    }
    foreach dn {materialid material.id material} {
        TRY "G_READ_C2_AFTER_MARK $dn" {hm_getvalue comps id=$c2 dataname=$dn}
    }
}

# --- H. Official alternatives surface ----------------------------------------
P "H_CMDS_ASSEMBLY" [join [lsort [info commands *assembly*]] { }]
P "H_CMDS_COLLECTORCREATE" [join [lsort [info commands *collectorcreate*]] { }]
P "H_CMDS_HM_ENTITY" [join [lsort [info commands hm_*entity*]] { }]
P "H_CMDS_GETCOLLECTORNAME_EXISTS" [expr {[info commands hm_getcollectorname] ne ""}]
P "H_CMDS_USRMESSAGE_EXISTS" [expr {[info commands hm_usermessage] ne ""}]
P "H_CMDS_ENTITYEXIST_EXISTS" [expr {[info commands hm_entityexist] ne ""}]
P "H_CMDS_SETVALUE_EXISTS" [expr {[info commands *setvalue] ne ""}]
P "H_CMDS_CREATEMARK_EXISTS" [expr {[info commands *createmark] ne ""}]

# by-assem mark selectors (module: "by assem id" / "by assem name")
if {$asmId ne ""} {
    TRY "H_MARK_BY_ASSEM_ID" {
        catch {*clearmark comps 1}
        *createmark comps 1 "by assem id" $asmId
        P "H_MARK_BY_ASSEM_ID_IDS" [join [lsort -integer [hm_getmark comps 1]] {,}]
    }
    TRY "H_MARK_BY_ASSEM_ID_ALIAS" {
        catch {*clearmark comps 1}
        *createmark comps 1 "by assembly id" $asmId
        P "H_MARK_BY_ASSEM_ID_ALIAS_IDS" [join [lsort -integer [hm_getmark comps 1]] {,}]
    }
}
TRY "H_MARK_BY_ASSEM_NAME" {
    catch {*clearmark comps 1}
    *createmark comps 1 "by assem name" PROBE_ASM
    P "H_MARK_BY_ASSEM_NAME_IDS" [join [lsort -integer [hm_getmark comps 1]] {,}]
}
TRY "H_MARK_BY_ASSEM_NAME_ALIAS" {
    catch {*clearmark comps 1}
    *createmark comps 1 "by assembly name" PROBE_ASM
    P "H_MARK_BY_ASSEM_NAME_ALIAS_IDS" [join [lsort -integer [hm_getmark comps 1]] {,}]
}

# --- I. End-to-end: module-equivalent execute() flow ---------------------------
if {$asmId ne "" && $mid ne ""} {
    TRY "I_BY_ASSEM_NAME_ALL" {
        catch {*clearmark comps 1}
        *createmark comps 1 "by assem name" PROBE_ASM
        P "I_ASM_COMP_IDS" [join [lsort -integer [hm_getmark comps 1]] {,}]
    }
    TRY "I_ASSIGN_LOOP" {
        set assignedOk 0
        set verifiedOk 0
        catch {*clearmark comps 1}
        *createmark comps 1 "by assem name" PROBE_ASM
        foreach cid [hm_getmark comps 1] {
            if {![catch {*setvalue comps id=$cid materialid=$mid}]} { incr assignedOk }
            set observed ""
            catch {set observed [hm_getvalue comps id=$cid dataname=materialid]}
            if {$observed eq $mid} { incr verifiedOk }
        }
        P "I_ASSIGNED_OK" $assignedOk
        P "I_VERIFIED_OK" $verifiedOk
    }
    TRY "I_RENAME_FINAL" {*renamecollector comps PROBE_BOM_C1B PROBE_BOM_C1B_Q355}
}

# --- J. Real module code path (source and call actual procs) ------------------
TRY "J_SOURCE_WORKFLOW" {source -encoding utf-8 [file join $root modules workflow_common.tcl]}
TRY "J_SOURCE_MODULE" {source -encoding utf-8 [file join $root modules bom_material_assignment.tcl]}
if {[namespace exists ::BomMaterialAssignment]} {
    TRY "J_ASSEMBLY_COMPONENT_IDS" {::BomMaterialAssignment::assemblyComponentIds PROBE_ASM}
    TRY "J_MATERIAL_ID_BY_NAME" {::BomMaterialAssignment::materialIdByName PROBE_Q355}
    TRY "J_ENSURE_Q355" {::BomMaterialAssignment::ensureQ355Material}
    TRY "J_COMPONENT_NAME" {::BomMaterialAssignment::componentName $c1}
    if {$c1 ne "" && $mid ne ""} {
        TRY "J_ASSIGN_MATERIAL" {::BomMaterialAssignment::assignMaterial $c1 $mid}
        TRY "J_RENAME_COMPONENT" {::BomMaterialAssignment::renameComponent PROBE_BOM_C1B PROBE_BOM_C1B_Q355}
        TRY "J_COMPONENT_MATERIAL_ID" {::BomMaterialAssignment::componentMaterialId $c1}
    }
}

close $channel
exit 0
