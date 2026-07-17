# ======================================================================
# Batch Property Assignment - HyperMesh 2019 / OptiStruct
#
# Recognized key fields:
#   Vxx_<part>_T<thickness><ignored text>_..._<material>
#   <text containing SEAM>...T<thickness><ignored text> (material is Steel)
# Existing properties and 1D-name keywords BEAM/RBE/BUSH/SPRING are skipped.
#
# Failed/unrecognized components stay untouched.  An empty component
# collector is created in PROPERTY_ASSIGNMENT_REVIEW so the Model Browser
# contains a name-only review list without duplicating mesh or geometry.
# ======================================================================

namespace eval ::BatchPropertyAssignment {
    variable REVIEW_ASSEMBLY "PROPERTY_ASSIGNMENT_REVIEW"
    variable REVIEW_PREFIX "PROPERTY_REVIEW__"
}

proc ::BatchPropertyAssignment::formatThicknessToken {value} {
    if {$value eq "" || ![string is double -strict $value] || $value <= 0.0} {
        return ""
    }
    set text [format "%.12g" [expr {double($value)}]]
    regsub {\.0+$} $text "" text
    regsub {(\.[0-9]*?)0+([eE].*)?$} $text {\1\2} text
    return $text
}

proc ::BatchPropertyAssignment::parseComponentName {name} {
    variable REVIEW_PREFIX
    set name [string trim $name]
    if {$name eq "" || [string first $REVIEW_PREFIX $name] == 0} {
        return {}
    }

    set numberPattern {([0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?)}
    set seamIndex [string first "SEAM" [string toupper $name]]
    if {$seamIndex >= 0} {
        set seamText [string range $name $seamIndex end]
    } else {
        set seamText ""
    }
    if {$seamText ne "" &&
        [regexp -nocase -- "T${numberPattern}" $seamText -> thickness decimal exponent]} {
        set token [::BatchPropertyAssignment::formatThicknessToken $thickness]
        if {$token eq ""} {return {}}
        return [dict create \
            kind SEAM \
            material Steel \
            thickness [expr {double($thickness)}] \
            thickness_token $token \
            property_name "SEAM_T${token}"]
    }

    # Only the key fields are structural: Vxx prefix, the first _T<number>
    # after a non-empty part number, and the final underscore token as the
    # material.  Text such as T10aaa or T2.5.surf is intentionally ignored
    # after the numeric thickness.
    set expression [format {^(V[[:alnum:]]+)_(.+?)_T%s.*_([^_]+)$} $numberPattern]
    if {![regexp -nocase -- $expression $name -> version partNumber thickness decimal exponent material]} {
        return {}
    }
    set version [string trim $version]
    set partNumber [string trim $partNumber]
    set material [string trim $material]
    set token [::BatchPropertyAssignment::formatThicknessToken $thickness]
    if {$version eq "" || $partNumber eq "" || $material eq "" || $token eq ""} {
        return {}
    }
    return [dict create \
        kind PART \
        version $version \
        part_number $partNumber \
        material $material \
        thickness [expr {double($thickness)}] \
        thickness_token $token \
        property_name "${material}_T${token}"]
}

proc ::BatchPropertyAssignment::isIgnoredOneDimensionalName {name} {
    set upper [string toupper $name]
    foreach keyword {BEAM RBE BUSH SPRING} {
        if {[string first $keyword $upper] >= 0} {return 1}
    }
    return 0
}

proc ::BatchPropertyAssignment::allEntityIds {entityTypes} {
    foreach entityType $entityTypes {
        set ids {}
        catch {*clearmark $entityType 1}
        if {![catch {*createmark $entityType 1 all}]} {
            catch {set ids [hm_getmark $entityType 1]}
        }
        catch {*clearmark $entityType 1}
        if {[llength $ids] > 0} {
            return [lsort -integer -unique $ids]
        }
    }
    return {}
}

proc ::BatchPropertyAssignment::allComponentIds {} {
    return [::BatchPropertyAssignment::allEntityIds {comps components}]
}

proc ::BatchPropertyAssignment::componentName {componentId} {
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

proc ::BatchPropertyAssignment::entityIdByName {entityTypes name} {
    if {[llength [info commands ::HWFlow::entityIdByName]] > 0} {
        set id [::HWFlow::entityIdByName $entityTypes $name]
        if {$id ne "" && $id != 0} {return $id}
    }
    foreach entityType $entityTypes {
        if {![catch {set id [hm_entityinfo id $entityType $name -byname]}] && $id ne "" && $id != 0} {
            return $id
        }
        if {![catch {set id [hm_getvalue $entityType name=$name dataname=id]}] && $id ne "" && $id != 0} {
            return $id
        }
    }
    return ""
}

proc ::BatchPropertyAssignment::materialIdByName {materialName} {
    set id [::BatchPropertyAssignment::entityIdByName {mats materials} $materialName]
    if {$id ne ""} {return $id}

    # HyperMesh name lookup can be case-sensitive.  Reuse Steel/steel rather
    # than creating or requiring a second material with different casing.
    foreach materialId [::BatchPropertyAssignment::allEntityIds {mats materials}] {
        foreach entityType {mats materials} {
            if {![catch {set existing [hm_getvalue $entityType id=$materialId dataname=name]}] &&
                [string equal -nocase [string trim $existing] [string trim $materialName]]} {
                return $materialId
            }
        }
    }
    return ""
}

proc ::BatchPropertyAssignment::trySetValue {entityTypes selector field value} {
    foreach entityType $entityTypes {
        set command [list *setvalue $entityType $selector STATUS=1 "$field=$value"]
        if {![catch {eval $command}]} {return 1}
    }
    return 0
}

proc ::BatchPropertyAssignment::propertyMaterialMatches {propertyId materialId} {
    foreach entityType {props properties property} {
        foreach dataName {materialid material.id material MID mid} {
            if {[catch {set value [hm_getvalue $entityType id=$propertyId dataname=$dataName]}]} {
                continue
            }
            if {"$value" eq "$materialId"} {return 1}
        }
    }
    return 0
}

proc ::BatchPropertyAssignment::ensureProperty {propertyName thickness materialId} {
    set propertyId [::BatchPropertyAssignment::entityIdByName {props properties property} $propertyName]
    if {$propertyId eq ""} {
        set firstError ""
        if {[catch {*createentity props cardimage=PSHELL includeid=0 name=$propertyName} firstError] &&
            [catch {*createentity properties cardimage=PSHELL includeid=0 name=$propertyName} secondError]} {
            error "cannot create PSHELL property $propertyName: $firstError / $secondError"
        }
        set propertyId [::BatchPropertyAssignment::entityIdByName {props properties property} $propertyName]
    }
    if {$propertyId eq "" || $propertyId == 0} {
        error "cannot read property id for $propertyName"
    }

    foreach entityType {props properties property} {
        catch {*setvalue $entityType id=$propertyId cardimage=PSHELL}
    }

    set materialSet [::BatchPropertyAssignment::trySetValue \
        {props properties property} "id=$propertyId" materialid $materialId]
    if {!$materialSet} {
        error "cannot set material id $materialId on property $propertyName"
    }

    # Attribute 95 is OptiStruct PSHELL_T in HyperMesh 2019.  Keep the
    # data-name fallback for installations whose loaded template exposes it.
    set thicknessSet 0
    if {![catch {*attributeupdatedouble properties $propertyId 95 1 1 0 $thickness}]} {
        set thicknessSet 1
    } elseif {![catch {*attributeupdatedouble props $propertyId 95 1 1 0 $thickness}]} {
        set thicknessSet 1
    } elseif {[::BatchPropertyAssignment::trySetValue \
        {props properties property} "id=$propertyId" thickness $thickness]} {
        set thicknessSet 1
    }
    if {!$thicknessSet} {
        error "cannot set PSHELL thickness $thickness on property $propertyName"
    }

    set actualThickness ""
    catch {set actualThickness [hm_getthickness props $propertyId]}
    if {$actualThickness eq ""} {
        catch {set actualThickness [hm_getthickness properties $propertyId]}
    }
    if {$actualThickness eq "" || ![string is double -strict $actualThickness] ||
        abs(double($actualThickness) - double($thickness)) > 1.0e-8 * max(1.0, abs(double($thickness)))} {
        error "PSHELL thickness verification failed for $propertyName"
    }
    if {![::BatchPropertyAssignment::propertyMaterialMatches $propertyId $materialId]} {
        error "material verification failed for property $propertyName"
    }
    return $propertyId
}

proc ::BatchPropertyAssignment::componentHasProperty {componentId propertyId propertyName} {
    foreach entityType {comps components component} {
        foreach dataName {propertyid property.id property prop.id} {
            if {[catch {set value [hm_getvalue $entityType id=$componentId dataname=$dataName]}]} {
                continue
            }
            if {"$value" eq "$propertyId" || [string equal -nocase "$value" $propertyName]} {
                return 1
            }
        }
    }
    return 0
}

proc ::BatchPropertyAssignment::componentHasAnyProperty {componentId} {
    foreach entityType {comps components component} {
        foreach dataName {propertyid property.id property prop.id} {
            if {[catch {set value [hm_getvalue $entityType id=$componentId dataname=$dataName]}]} {
                continue
            }
            set value [string trim $value]
            if {$value eq ""} {continue}
            if {[string is double -strict $value] && double($value) == 0.0} {continue}
            return 1
        }
    }
    return 0
}

proc ::BatchPropertyAssignment::assignProperty {componentId propertyId propertyName} {
    set assigned [::BatchPropertyAssignment::trySetValue \
        {comps components component} "id=$componentId" propertyid $propertyId]
    catch {*clearmark comps 1}
    if {![catch {*createmark comps 1 $componentId}] &&
        ![catch {*propertyupdate comps 1 $propertyName}]} {
        set assigned 1
    }
    catch {*clearmark comps 1}
    catch {*clearmark components 1}
    if {!$assigned || ![::BatchPropertyAssignment::componentHasProperty $componentId $propertyId $propertyName]} {
        return 0
    }
    return 1
}

proc ::BatchPropertyAssignment::reviewEntryName {componentName} {
    variable REVIEW_PREFIX
    return "${REVIEW_PREFIX}${componentName}"
}

proc ::BatchPropertyAssignment::ensureReviewEntry {componentName} {
    variable REVIEW_ASSEMBLY
    set reviewName [::BatchPropertyAssignment::reviewEntryName $componentName]
    # createComponent only creates an empty collector here.  No duplicate or
    # move command is used, so the source component contents remain untouched.
    set reviewId [::HWFlow::createComponent $reviewName 3]
    if {$reviewId eq ""} {
        error "cannot create empty review component $reviewName"
    }
    set assemblyId [::HWFlow::addComponentsToAssembly $REVIEW_ASSEMBLY [list $reviewId] 3]
    if {$assemblyId eq ""} {
        error "cannot add $reviewName to assembly $REVIEW_ASSEMBLY"
    }
    return $reviewId
}

proc ::BatchPropertyAssignment::appendProgress {message} {
    if {[llength [info commands ::HWFlow::progressAppend]] > 0} {
        catch {::HWFlow::progressAppend $message 1}
    }
}

proc ::BatchPropertyAssignment::execute {} {
    variable REVIEW_ASSEMBLY
    variable REVIEW_PREFIX
    set componentIds [::BatchPropertyAssignment::allComponentIds]
    set sourceRows {}
    foreach componentId $componentIds {
        set name [::BatchPropertyAssignment::componentName $componentId]
        if {[string first $REVIEW_PREFIX $name] == 0} {continue}
        lappend sourceRows [list $componentId $name]
    }

    set total [llength $sourceRows]
    set assignedCount 0
    set skippedExisting {}
    set skippedOneDimensional {}
    set createdProperties {}
    set failures {}
    set index 0
    foreach row $sourceRows {
        incr index
        lassign $row componentId componentName
        if {[llength [info commands ::HWFlow::progressUpdate]] > 0} {
            set percent [expr {$total > 0 ? 5.0 + 85.0 * ($index - 1) / double($total) : 90.0}]
            catch {::HWFlow::progressUpdate $percent \
                [::HWFlow::txt "正在处理 $componentName" "Processing $componentName"] \
                [::HWFlow::txt "$index / $total" "$index / $total"] 1}
        }

        if {[::BatchPropertyAssignment::componentHasAnyProperty $componentId]} {
            lappend skippedExisting $componentName
            ::BatchPropertyAssignment::appendProgress "$componentName: 已有关联 Property，跳过"
            continue
        }
        if {[::BatchPropertyAssignment::isIgnoredOneDimensionalName $componentName]} {
            lappend skippedOneDimensional $componentName
            ::BatchPropertyAssignment::appendProgress "$componentName: 识别为 1D component，跳过"
            continue
        }

        set parsed [::BatchPropertyAssignment::parseComponentName $componentName]
        if {[llength $parsed] == 0} {
            lappend failures [list $componentName "未能从名称提取有效厚度及材料/焊缝信息"]
            continue
        }

        set materialName [dict get $parsed material]
        set materialId [::BatchPropertyAssignment::materialIdByName $materialName]
        if {$materialId eq ""} {
            lappend failures [list $componentName "未找到材料 $materialName"]
            continue
        }

        set propertyName [dict get $parsed property_name]
        set thickness [dict get $parsed thickness]
        if {[catch {
            set propertyId [::BatchPropertyAssignment::ensureProperty \
                $propertyName $thickness $materialId]
            if {![::BatchPropertyAssignment::assignProperty \
                $componentId $propertyId $propertyName]} {
                error "property 赋予或校验失败"
            }
        } assignmentError]} {
            lappend failures [list $componentName $assignmentError]
            continue
        }
        incr assignedCount
        if {$propertyName ni $createdProperties} {lappend createdProperties $propertyName}
        ::BatchPropertyAssignment::appendProgress "$componentName -> $propertyName"
    }

    set reviewErrors {}
    foreach failure $failures {
        lassign $failure componentName reason
        if {[catch {::BatchPropertyAssignment::ensureReviewEntry $componentName} reviewError]} {
            lappend reviewErrors [list $componentName $reviewError]
        }
        ::BatchPropertyAssignment::appendProgress "$componentName: $reason"
    }
    catch {::HWFlow::refreshBrowserNow 0}
    return [dict create \
        scanned $total \
        assigned $assignedCount \
        skipped_existing [llength $skippedExisting] \
        skipped_existing_names $skippedExisting \
        skipped_1d [llength $skippedOneDimensional] \
        skipped_1d_names $skippedOneDimensional \
        property_names $createdProperties \
        failures $failures \
        review_errors $reviewErrors \
        review_assembly $REVIEW_ASSEMBLY]
}

proc ::BatchPropertyAssignment::runAction {} {
    set title [::HWFlow::txt "批量赋予 Property 和材料" "Batch Property and Material Assignment"]
    set prompt [::HWFlow::txt \
        "将扫描全部 component，从普通件名称提取 T 后数字和最后的材料字段；名称含 SEAM 时只提取厚度。已有 Property，以及名称含 BEAM/RBE/BUSH/SPRING 的 1D component 会直接跳过。\n\n无法识别、材料缺失或赋予失败的 component 会以空 collector 名称副本列入 PROPERTY_ASSIGNMENT_REVIEW；原 component 不会被移动。是否继续？" \
        "Scan all components, extracting the number after T and the final material field for regular parts; names containing SEAM only contribute thickness. Components with an existing property and 1D names containing BEAM/RBE/BUSH/SPRING are skipped.\n\nUnrecognized or failed components will be listed as empty name-only collectors in PROPERTY_ASSIGNMENT_REVIEW; source components are not moved. Continue?"]
    if {[llength [info commands tk_messageBox]] > 0} {
        set answer [tk_messageBox -icon question -type yesno -default no -title $title -message $prompt]
        if {$answer ne "yes"} {return}
    }

    set progressOpened 0
    if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
        set progressOpened [::HWFlow::progressOpen $title \
            [::HWFlow::txt "正在扫描 component..." "Scanning components..."] 0]
    }
    if {[catch {set result [::BatchPropertyAssignment::execute]} runError]} {
        if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
            catch {::HWFlow::progressClose [::HWFlow::txt "批量赋予失败" "Batch assignment failed"] 100.0}
        }
        tk_messageBox -icon error -title $title -message [::HWFlow::txt \
            "批量赋予失败：\n$runError" "Batch assignment failed:\n$runError"]
        return
    }

    set scanned [dict get $result scanned]
    set assigned [dict get $result assigned]
    set skippedExisting [dict get $result skipped_existing]
    set skippedOneDimensional [dict get $result skipped_1d]
    set properties [dict get $result property_names]
    set failures [dict get $result failures]
    set reviewErrors [dict get $result review_errors]
    if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose [::HWFlow::txt \
            "完成：$assigned / $scanned 个 component 已赋予 Property。" \
            "Complete: $assigned / $scanned components assigned a property."] 100.0}
    }

    set message [::HWFlow::txt \
        "批量赋予完成。\n\n扫描 component：$scanned\n成功赋予：$assigned\n已有 Property 跳过：$skippedExisting\n1D 关键词跳过：$skippedOneDimensional\nProperty 分类数：[llength $properties]\n待人工复核：[llength $failures]\n复核 assembly：[dict get $result review_assembly]" \
        "Batch assignment complete.\n\nComponents scanned: $scanned\nAssigned: $assigned\nSkipped with existing property: $skippedExisting\nSkipped by 1D keyword: $skippedOneDimensional\nProperty groups: [llength $properties]\nManual review: [llength $failures]\nReview assembly: [dict get $result review_assembly]"]
    if {[llength $failures] > 0} {
        set preview {}
        foreach row [lrange $failures 0 7] {
            lappend preview "[lindex $row 0]: [lindex $row 1]"
        }
        append message "\n\n[join $preview \n]"
        if {[llength $failures] > 8} {
            append message [::HWFlow::txt \
                "\n……另有 [expr {[llength $failures] - 8}] 项。" \
                "\n...and [expr {[llength $failures] - 8}] more."]
        }
    }
    if {[llength $reviewErrors] > 0} {
        append message [::HWFlow::txt \
            "\n\n注意：[llength $reviewErrors] 个异常名称副本创建失败。" \
            "\n\nWarning: [llength $reviewErrors] review name entries could not be created."]
    }
    tk_messageBox -icon [expr {[llength $failures] > 0 || [llength $reviewErrors] > 0 ? "warning" : "info"}] \
        -title $title -message $message
}

proc ::BatchPropertyAssignment::run {} {
    ::BatchPropertyAssignment::runAction
}
