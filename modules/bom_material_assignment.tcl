# ============================================================================
# BOM Material Assignment v0.1
# HyperMesh 2019 / OptiStruct
#
# The BOM reader is intentionally kept behind readBom.  Until the BOM format
# is agreed, this module uses one default material for every component in the
# MIDSURFED assembly.  The current default operation:
#   1. creates or reuses a Q355 MAT1 material;
#   2. assigns that material directly to every target component; and
#   3. keeps the material name in the component name as a _Q355 suffix.
#
# The component-name update is useful to the later property-assignment module,
# while the direct material pointer makes the current result visible to
# HyperMesh immediately.  Reading and matching BOM rows can replace
# defaultBomAssignments without changing the execution path.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source -encoding utf-8 [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::BomMaterialAssignment {
    variable VERSION "0.1"
    variable TARGET_ASSEMBLY "MIDSURFED"
    variable DEFAULT_MATERIAL "Q355"

    variable ui
    array set ui {
        ok 0
    }
}

proc ::BomMaterialAssignment::backToHome {w} {
    if {[llength [info commands ::HWFlow::backToHome]] > 0} {
        ::HWFlow::backToHome $w
    } else {
        catch {destroy $w}
    }
}

proc ::BomMaterialAssignment::showPanel {} {
    variable VERSION
    variable TARGET_ASSEMBLY
    variable DEFAULT_MATERIAL
    variable ui

    catch {destroy .bom_material_assignment}
    set ui(ok) 0
    set w .bom_material_assignment
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::txt "读取 BOM 表 / 材料赋予" "BOM Reader / Material Assignment"]
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "读取 BOM 表 / 材料赋予" "BOM Reader / Material Assignment"] -font [::HWFlow::uiFont heading]
    grid $w.main.title -row 0 -column 0 -sticky w -pady {0 8}

    labelframe $w.main.target -text [::HWFlow::txt "当前处理范围" "Current Scope"] -padx 8 -pady 8
    grid $w.main.target -row 1 -column 0 -sticky ew -pady {0 8}
    label $w.main.target.assembly -text [::HWFlow::txt "目标 Assembly：$TARGET_ASSEMBLY" "Target Assembly: $TARGET_ASSEMBLY"] -anchor w
    label $w.main.target.material -text [::HWFlow::txt "当前默认材料：$DEFAULT_MATERIAL" "Current default material: $DEFAULT_MATERIAL"] -anchor w
    grid $w.main.target.assembly -row 0 -column 0 -sticky w -pady 2
    grid $w.main.target.material -row 1 -column 0 -sticky w -pady 2

    message $w.main.note -width 560 -anchor w -text [::HWFlow::txt \
        "当前版本暂不解析 BOM 文件。执行后会扫描 MIDSURFED 中的全部 component，创建/复用 Q355 材料，给组件赋予该材料，并将组件名规范为 *_Q355。后续只需替换 BOM 读取接口即可。" \
        "This version does not parse a BOM file yet. It scans every component in MIDSURFED, creates or reuses Q355, assigns it to the components, and normalizes component names to end with *_Q355. The BOM reader can be plugged in later."]
    grid $w.main.note -row 2 -column 0 -sticky ew -pady {0 8}

    frame $w.btn -padx 12 -pady 10
    pack $w.btn -fill x
    button $w.btn.cancel -text [::HWFlow::txt "返回主页" "Back to Home"] -width 14 -command "set ::BomMaterialAssignment::ui(ok) 0; ::BomMaterialAssignment::backToHome $w"
    button $w.btn.start -text [::HWFlow::txt "应用 Q355" "Apply Q355"] -width 16 -command "set ::BomMaterialAssignment::ui(ok) 1; destroy $w"
    pack $w.btn.cancel -side right -padx 4
    pack $w.btn.start -side right -padx 4

    bind $w <Escape> "set ::BomMaterialAssignment::ui(ok) 0; destroy $w"
    wm protocol $w WM_DELETE_WINDOW "set ::BomMaterialAssignment::ui(ok) 0; destroy $w"

    update idletasks
    set sw [winfo screenwidth $w]
    set sh [winfo screenheight $w]
    set ww [winfo reqwidth $w]
    set wh [winfo reqheight $w]
    wm geometry $w +[expr {($sw - $ww) / 2}]+[expr {($sh - $wh) / 2}]

    tkwait window $w
    return $ui(ok)
}

# Reserved extension point for the real BOM implementation.
proc ::BomMaterialAssignment::readBom {bomPath} {
    error [::HWFlow::txt \
        "BOM 读取功能尚未实现：$bomPath" \
        "BOM reading is not implemented yet: $bomPath"]
}

proc ::BomMaterialAssignment::uniqueIds {ids} {
    set out {}
    array set seen {}
    foreach id $ids {
        if {$id eq "" || [info exists seen($id)]} {
            continue
        }
        set seen($id) 1
        lappend out $id
    }
    if {[llength $out] == 0} {
        return {}
    }
    return [lsort -integer -unique $out]
}

proc ::BomMaterialAssignment::assemblyIdByName {assemblyName} {
    if {[llength [info commands ::HWFlow::assemblyIdByName]] > 0} {
        return [::HWFlow::assemblyIdByName $assemblyName]
    }
    foreach entityType {assemblies assems assembly} {
        if {![catch {set id [hm_entityinfo id $entityType $assemblyName -byname]}] && $id ne "" && $id != 0} {
            return $id
        }
    }
    return ""
}

proc ::BomMaterialAssignment::assemblyComponentIds {assemblyName} {
    set assemblyId [::BomMaterialAssignment::assemblyIdByName $assemblyName]
    if {$assemblyId eq ""} {
        error [::HWFlow::txt \
            "找不到目标 Assembly：$assemblyName" \
            "Target assembly not found: $assemblyName"]
    }

    set ids {}
    foreach entityType {comps components} {
        catch {*clearmark $entityType 1}

        # "by assem id" is unambiguous when the legacy assembly API is
        # available.  The name form is retained for HM installations whose
        # assembly query returns a name but not a usable numeric ID.
        if {![catch {*createmark $entityType 1 "by assem id" $assemblyId}]} {
            catch {set ids [hm_getmark $entityType 1]}
        }
        if {[llength $ids] == 0 &&
            ![catch {*createmark $entityType 1 "by assem name" $assemblyName}]} {
            catch {set ids [hm_getmark $entityType 1]}
        }
        catch {*clearmark $entityType 1}
        if {[llength $ids] > 0} {
            break
        }
    }
    return [::BomMaterialAssignment::uniqueIds $ids]
}

proc ::BomMaterialAssignment::allEntityIds {entityTypes} {
    foreach entityType $entityTypes {
        set ids {}
        catch {*clearmark $entityType 1}
        if {![catch {*createmark $entityType 1 all}]} {
            catch {set ids [hm_getmark $entityType 1]}
        }
        catch {*clearmark $entityType 1}
        if {[llength $ids] > 0} {
            return [::BomMaterialAssignment::uniqueIds $ids]
        }
    }
    return {}
}

proc ::BomMaterialAssignment::canonicalMaterialName {materialName} {
    if {[llength [info commands ::HWFlow::canonicalMaterialToken]] > 0} {
        return [::HWFlow::canonicalMaterialToken $materialName]
    }
    set materialName [string trim $materialName]
    while {[regexp {^(.+)[.]([1-9][0-9]*)$} $materialName -> base serial]} {
        set materialName [string trim $base]
    }
    return $materialName
}

proc ::BomMaterialAssignment::materialIdByName {materialName} {
    set materialName [string trim $materialName]
    if {[llength [info commands ::HWFlow::entityIdByName]] > 0} {
        set id [::HWFlow::entityIdByName {mats materials} $materialName]
        if {$id ne "" && $id != 0} {
            return $id
        }
    }

    foreach entityType {mats materials} {
        if {![catch {set id [hm_entityinfo id $entityType $materialName -byname]}] && $id ne "" && $id != 0} {
            return $id
        }
        if {![catch {set id [hm_getvalue $entityType name=$materialName dataname=id]}] && $id ne "" && $id != 0} {
            return $id
        }
    }

    set target [string tolower [::BomMaterialAssignment::canonicalMaterialName $materialName]]
    foreach materialId [::BomMaterialAssignment::allEntityIds {mats materials}] {
        foreach entityType {mats materials} {
            if {![catch {set existing [hm_getvalue $entityType id=$materialId dataname=name]}] &&
                [string tolower [::BomMaterialAssignment::canonicalMaterialName $existing]] eq $target} {
                return $materialId
            }
        }
    }
    return ""
}

proc ::BomMaterialAssignment::trySetValue {entityTypes selector field value} {
    foreach entityType $entityTypes {
        set command [list *setvalue $entityType $selector STATUS=1 "$field=$value"]
        if {![catch {eval $command}]} {
            return 1
        }
    }
    return 0
}

proc ::BomMaterialAssignment::ensureQ355Material {} {
    variable DEFAULT_MATERIAL

    set materialId [::BomMaterialAssignment::materialIdByName $DEFAULT_MATERIAL]
    if {$materialId eq "" || $materialId == 0} {
        set firstError ""
        set secondError ""
        if {[catch {*createentity mats cardimage=MAT1 includeid=0 name=$DEFAULT_MATERIAL} firstError]} {
            if {[catch {*createentity materials cardimage=MAT1 includeid=0 name=$DEFAULT_MATERIAL} secondError]} {
                error "cannot create Q355 material: $firstError / $secondError"
            }
        }
        set materialId [::BomMaterialAssignment::materialIdByName $DEFAULT_MATERIAL]
        if {$materialId eq "" || $materialId == 0} {
            # A newly created material is normally discoverable by name.  The
            # negative mark fallback covers HM versions that update the mark
            # before the entity-name query becomes available.
            foreach entityType {mats materials} {
                catch {*clearmark $entityType 1}
                if {![catch {*createmark $entityType 1 -1}] &&
                    ![catch {set ids [hm_getmark $entityType 1]}] &&
                    [llength $ids] > 0} {
                    set materialId [lindex $ids 0]
                    break
                }
            }
            catch {*clearmark mats 1}
            catch {*clearmark materials 1}
        }
    }
    if {$materialId eq "" || $materialId == 0} {
        error "cannot read Q355 material id"
    }

    foreach selector [list "id=$materialId" "name=$DEFAULT_MATERIAL"] {
        foreach entityType {mats materials} {
            catch {*setvalue $entityType $selector cardimage=MAT1}
        }
        # mm-N-s-tonne convention: E in MPa and density in tonne/mm^3.
        ::BomMaterialAssignment::trySetValue {mats materials} $selector E 206000.0
        ::BomMaterialAssignment::trySetValue {mats materials} $selector 1 206000.0
        ::BomMaterialAssignment::trySetValue {mats materials} $selector Nu 0.30
        ::BomMaterialAssignment::trySetValue {mats materials} $selector 3 0.30
        ::BomMaterialAssignment::trySetValue {mats materials} $selector Rho 7.85e-9
        ::BomMaterialAssignment::trySetValue {mats materials} $selector 4 7.85e-9
    }
    return $materialId
}

proc ::BomMaterialAssignment::componentName {componentId} {
    if {[llength [info commands ::HWFlow::componentName]] > 0} {
        return [::HWFlow::componentName $componentId]
    }
    foreach entityType {comps components component} {
        if {![catch {set name [hm_getvalue $entityType id=$componentId dataname=name]}] && $name ne ""} {
            return $name
        }
    }
    return "COMP_$componentId"
}

proc ::BomMaterialAssignment::componentNameWithMaterial {componentName materialName} {
    set componentName [string trim $componentName]
    set materialName [string trim $materialName]
    if {$componentName eq ""} {
        return "COMPONENT_$materialName"
    }

    # Prefer the canonical midsurface naming parser so Vxx_part_Tx_Q235,
    # duplicate import suffixes, and part names containing underscores are
    # normalized consistently with the existing workflow.
    if {[llength [info commands ::HWFlow::componentNameInfo]] > 0} {
        set info [::HWFlow::componentNameInfo $componentName 0]
        if {[dict size $info] > 0} {
            return "[dict get $info version]_[dict get $info part_number]_T[dict get $info thickness_token]_$materialName"
        }
    }

    # MIDSURFED output is expected to carry a T<number> token.  Replace any
    # existing trailing material-like text after that token, instead of
    # accumulating _Q235_Q355 on repeated/material-change runs.
    set numberPattern {[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?}
    if {[regexp -nocase -- "^(.*_T${numberPattern})(?:_.*)?$" $componentName -> base decimal exponent]} {
        return "${base}_$materialName"
    }
    if {[regexp -nocase -- {^(.*)_([^_]+)$} $componentName -> base current] &&
        [string equal -nocase $current $materialName]} {
        return "${base}_$materialName"
    }
    return "${componentName}_$materialName"
}

proc ::BomMaterialAssignment::renameComponent {oldName newName} {
    if {[llength [info commands ::HWFlow::renameComponent]] > 0} {
        return [::HWFlow::renameComponent $oldName $newName]
    }
    if {$oldName eq $newName} {
        return $newName
    }
    if {[catch {*renamecollector component $oldName $newName} errorMessage] &&
        [catch {*renamecollector components $oldName $newName} errorMessage2]} {
        error "cannot rename component $oldName to $newName: $errorMessage / $errorMessage2"
    }
    return $newName
}

proc ::BomMaterialAssignment::componentMaterialId {componentId} {
    foreach entityType {comps components component} {
        foreach dataName {materialid material.id material} {
            if {![catch {set value [hm_getvalue $entityType id=$componentId dataname=$dataName]}] &&
                [string trim $value] ne ""} {
                return [string trim $value]
            }
        }
    }
    return ""
}

proc ::BomMaterialAssignment::assignMaterial {componentId materialId} {
    set assigned 0
    foreach entityType {comps components} {
        if {![catch {*setvalue $entityType id=$componentId materialid=$materialId}]} {
            set assigned 1
            break
        }
    }
    if {!$assigned} {
        catch {*clearmark comps 1}
        if {![catch {*createmark comps 1 $componentId}] &&
            ![catch {*setvalue comps mark=1 materialid=$materialId}]} {
            set assigned 1
        }
        catch {*clearmark comps 1}
    }
    if {!$assigned} {
        error "cannot assign material $materialId to component $componentId"
    }

    # Only enforce verification when HyperMesh exposes a readable material
    # data name.  This keeps HM2019 template aliases compatible while still
    # detecting a real mismatch when a query is available.
    set observed [::BomMaterialAssignment::componentMaterialId $componentId]
    if {$observed ne "" && $observed ne $materialId} {
        error "material verification failed for component $componentId: expected $materialId, got $observed"
    }
    return 1
}

# Placeholder for the future BOM mapper.  It deliberately returns a row per
# component so the execution loop already consumes a component/material map.
proc ::BomMaterialAssignment::defaultBomAssignments {componentIds} {
    variable DEFAULT_MATERIAL
    set assignments {}
    foreach componentId $componentIds {
        lappend assignments [dict create component_id $componentId material $DEFAULT_MATERIAL]
    }
    return $assignments
}

proc ::BomMaterialAssignment::appendProgress {message} {
    if {[llength [info commands ::HWFlow::progressAppend]] > 0} {
        catch {::HWFlow::progressAppend $message 1}
    }
}

proc ::BomMaterialAssignment::execute {} {
    variable TARGET_ASSEMBLY

    set componentIds [::BomMaterialAssignment::assemblyComponentIds $TARGET_ASSEMBLY]
    if {[llength $componentIds] == 0} {
        error [::HWFlow::txt \
            "Assembly $TARGET_ASSEMBLY 中没有 component。" \
            "Assembly $TARGET_ASSEMBLY does not contain any components."]
    }
    set materialId [::BomMaterialAssignment::ensureQ355Material]
    set assignments [::BomMaterialAssignment::defaultBomAssignments $componentIds]

    set renamed 0
    set unchanged 0
    set materialAssigned 0
    set failures {}
    set updatedNames {}
    set total [llength $assignments]
    set index 0
    foreach assignment $assignments {
        incr index
        set componentId [dict get $assignment component_id]
        set materialName [dict get $assignment material]
        set oldName [::BomMaterialAssignment::componentName $componentId]
        set newName [::BomMaterialAssignment::componentNameWithMaterial $oldName $materialName]

        if {[llength [info commands ::HWFlow::progressUpdate]] > 0} {
            set pct [expr {5.0 + 85.0 * ($index - 1) / double($total)}]
            catch {::HWFlow::progressUpdate $pct \
                [::HWFlow::txt "正在处理 BOM 材料" "Applying BOM material"] \
                "$index / $total: $oldName" 1}
        }

        set rowErrors {}
        if {$oldName ne $newName} {
            if {[catch {set finalName [::BomMaterialAssignment::renameComponent $oldName $newName]} renameError]} {
                lappend rowErrors "rename: $renameError"
                set finalName $oldName
            } else {
                incr renamed
            }
        } else {
            set finalName $oldName
            incr unchanged
        }

        if {[catch {::BomMaterialAssignment::assignMaterial $componentId $materialId} materialError]} {
            lappend rowErrors "material: $materialError"
        } else {
            incr materialAssigned
        }

        if {[llength $rowErrors] > 0} {
            lappend failures [list $oldName [join $rowErrors "; "]]
            ::BomMaterialAssignment::appendProgress "$oldName: [join $rowErrors {; }]"
        } else {
            lappend updatedNames "$oldName -> $finalName"
            ::BomMaterialAssignment::appendProgress "$oldName -> $finalName; material=$materialName"
        }
    }

    catch {::HWFlow::refreshBrowserNow 0}
    catch {::HWFlow::refreshBrowser}
    return [dict create \
        assembly $TARGET_ASSEMBLY \
        material $::BomMaterialAssignment::DEFAULT_MATERIAL \
        material_id $materialId \
        scanned $total \
        renamed $renamed \
        unchanged $unchanged \
        material_assigned $materialAssigned \
        updated_names $updatedNames \
        failures $failures]
}

proc ::BomMaterialAssignment::runAction {} {
    variable TARGET_ASSEMBLY
    variable DEFAULT_MATERIAL
    set title [::HWFlow::txt "读取 BOM 表 / 材料赋予" "BOM Reader / Material Assignment"]

    if {![::BomMaterialAssignment::showPanel]} {
        catch {hm_usermessage [::HWFlow::txt "BOM 材料赋予已取消。" "BOM material assignment cancelled."]}
        return
    }

    set progressOpened 0
    if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
        set progressOpened [::HWFlow::progressOpen $title \
            [::HWFlow::txt "正在扫描 $TARGET_ASSEMBLY..." "Scanning $TARGET_ASSEMBLY..."] 0]
    }
    if {[catch {set result [::BomMaterialAssignment::execute]} runError]} {
        if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
            catch {::HWFlow::progressClose [::HWFlow::txt "BOM 材料赋予失败" "BOM material assignment failed"] 100.0}
        }
        tk_messageBox -icon error -title $title -message [::HWFlow::txt \
            "BOM 材料赋予失败：\n$runError" "BOM material assignment failed:\n$runError"]
        return
    }

    set failures [dict get $result failures]
    if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose [::HWFlow::txt \
            "完成：$DEFAULT_MATERIAL 已处理 [dict get $result scanned] 个 component。" \
            "Complete: $DEFAULT_MATERIAL processed [dict get $result scanned] components."] 100.0}
    }

    set message [::HWFlow::txt \
        "BOM 材料赋予完成。\n\n目标 Assembly：$TARGET_ASSEMBLY\n扫描 component：[dict get $result scanned]\n组件名更新：[dict get $result renamed]\n名称已是目标材料：[dict get $result unchanged]\n材料赋予成功：[dict get $result material_assigned]\n失败：[llength $failures]\n\n当前版本使用默认材料 $DEFAULT_MATERIAL，尚未读取 BOM 文件。" \
        "BOM material assignment complete.\n\nTarget assembly: $TARGET_ASSEMBLY\nComponents scanned: [dict get $result scanned]\nNames updated: [dict get $result renamed]\nAlready using target name: [dict get $result unchanged]\nMaterial assignments: [dict get $result material_assigned]\nFailures: [llength $failures]\n\nThis version uses default $DEFAULT_MATERIAL; BOM file parsing is not implemented yet."]
    if {[llength $failures] > 0} {
        set preview {}
        foreach row [lrange $failures 0 7] {
            lappend preview "[lindex $row 0]: [lindex $row 1]"
        }
        append message "\n\n[join $preview \n]"
    }
    tk_messageBox -icon [expr {[llength $failures] > 0 ? "warning" : "info"}] -title $title -message $message
}

proc ::BomMaterialAssignment::run {} {
    ::BomMaterialAssignment::runAction
}
