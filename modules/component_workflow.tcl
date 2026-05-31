# ============================================================================
# Component Workflow v0.2
# HyperMesh 2019 Tcl/Tk
#
# Separate category classification and material assignment workflow modules.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::CompWorkflow {
    variable VERSION "0.2"

    variable ui
    array set ui {
        classifyCategory SHELL
        classifyComps ""
        classifyText "No components selected"
        materialComps ""
        materialText "No components selected"
        selectedMaterial ""
        status ""
    }
}

proc ::CompWorkflow::centerWindow {w} {
    update idletasks
    set sw [winfo screenwidth $w]
    set sh [winfo screenheight $w]
    set ww [winfo reqwidth $w]
    set wh [winfo reqheight $w]
    wm geometry $w +[expr {($sw - $ww) / 2}]+[expr {($sh - $wh) / 2}]
}

proc ::CompWorkflow::backToHome {w} {
    if {[llength [info commands ::HWFlow::backToHome]] > 0} {
        ::HWFlow::backToHome $w
    } else {
        catch {destroy $w}
    }
}

proc ::CompWorkflow::loadState {} {
    if {[llength [info commands ::HWFlow::applyStateToArray]] > 0} {
        ::HWFlow::applyStateToArray component_workflow ::CompWorkflow::ui {classifyCategory selectedMaterial}
    }
}

proc ::CompWorkflow::saveState {} {
    if {[llength [info commands ::HWFlow::saveState]] == 0} {
        return
    }
    variable ui
    set state [dict create]
    foreach key {classifyCategory selectedMaterial} {
        if {[info exists ui($key)]} {
            dict set state $key $ui($key)
        }
    }
    ::HWFlow::saveState component_workflow $state
}

proc ::CompWorkflow::showCategoryPanel {} {
    variable ui
    variable VERSION

    ::CompWorkflow::loadState
    set ui(classifyComps) ""
    set ui(classifyText) [::HWFlow::txt "未选择组件" "No components selected"]
    set ui(status) ""

    catch {destroy .comp_category}
    set w .comp_category
    toplevel $w
    wm title $w "[::HWFlow::txt "组件类型分类" "Component Type Classification"] v$VERSION"
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "组件类型分类" "Component Type Classification"] -font {Arial 11 bold}
    grid $w.main.title -row 0 -column 0 -columnspan 3 -sticky w -pady {0 8}

    labelframe $w.main.classify -text [::HWFlow::txt "组件分类" "Classify Components"] -padx 8 -pady 8
    grid $w.main.classify -row 1 -column 0 -sticky news -pady {0 8}

    label $w.main.classify.l_cat -text [::HWFlow::txt "类型" "Category"]
    tk_optionMenu $w.main.classify.m_cat ::CompWorkflow::ui(classifyCategory) SHELL SOLID CASTING
    button $w.main.classify.pick -text [::HWFlow::txt "选择组件" "Pick Components"] -width 18 -command "::CompWorkflow::pickClassifyComponents"
    label $w.main.classify.info -textvariable ::CompWorkflow::ui(classifyText) -width 40 -anchor w
    button $w.main.classify.apply -text [::HWFlow::txt "应用类型" "Apply Category"] -width 18 -command "::CompWorkflow::applyCategory"
    grid $w.main.classify.l_cat -row 0 -column 0 -sticky w -padx {0 6} -pady 3
    grid $w.main.classify.m_cat -row 0 -column 1 -sticky w -pady 3
    grid $w.main.classify.pick -row 1 -column 0 -sticky w -padx {0 6} -pady 3
    grid $w.main.classify.info -row 1 -column 1 -sticky w -pady 3
    grid $w.main.classify.apply -row 2 -column 0 -columnspan 2 -sticky e -pady {8 0}

    labelframe $w.main.rules -text [::HWFlow::txt "命名规则" "Naming Rule"] -padx 8 -pady 8
    grid $w.main.rules -row 2 -column 0 -sticky ew -pady {0 8}
    message $w.main.rules.msg -width 520 -anchor w -text [::HWFlow::txt "NAME -> CATEGORY_NAME。已有类型前缀将被替换。" "NAME -> CATEGORY_NAME. Existing category prefixes are replaced."]
    grid $w.main.rules.msg -row 0 -column 0 -sticky ew

    label $w.main.status -textvariable ::CompWorkflow::ui(status) -width 70 -anchor w
    grid $w.main.status -row 3 -column 0 -sticky ew -pady {0 8}

    frame $w.btn -padx 12 -pady 10
    pack $w.btn -fill x
    button $w.btn.back -text [::HWFlow::txt "返回主页" "Back to Home"] -width 14 -command "::CompWorkflow::saveState; ::CompWorkflow::backToHome $w"
    pack $w.btn.back -side right

    bind $w <Escape> "::CompWorkflow::saveState; destroy $w"
    wm protocol $w WM_DELETE_WINDOW "::CompWorkflow::saveState; destroy $w"
    ::CompWorkflow::centerWindow $w
    tkwait window $w
}

proc ::CompWorkflow::showMaterialPanel {} {
    variable ui
    variable VERSION

    ::CompWorkflow::loadState
    ::HWFlow::loadMaterials
    set keys [::HWFlow::materialKeys]
    if {[llength $keys] > 0 && [lsearch -exact $keys $ui(selectedMaterial)] < 0} {
        set ui(selectedMaterial) [lindex $keys 0]
    } elseif {[llength $keys] == 0} {
        set ui(selectedMaterial) ""
    }
    set ui(materialComps) ""
    set ui(materialText) [::HWFlow::txt "未选择组件" "No components selected"]
    set ui(status) ""

    catch {destroy .material_assign}
    set w .material_assign
    toplevel $w
    wm title $w "[::HWFlow::txt "材料标识分配" "Material Assignment"] v$VERSION"
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "材料标识分配" "Material Assignment"] -font {Arial 11 bold}
    grid $w.main.title -row 0 -column 0 -columnspan 3 -sticky w -pady {0 8}

    labelframe $w.main.mat -text [::HWFlow::txt "材料库" "Material Library"] -padx 8 -pady 8
    grid $w.main.mat -row 1 -column 0 -sticky news -pady {0 8}

    listbox $w.main.mat.list -height 8 -width 28 -exportselection 0
    scrollbar $w.main.mat.ys -orient vertical -command "$w.main.mat.list yview"
    $w.main.mat.list configure -yscrollcommand "$w.main.mat.ys set"
    button $w.main.mat.reload -text [::HWFlow::txt "重新加载" "Reload"] -width 10 -command "::CompWorkflow::reloadMaterials"
    button $w.main.mat.edit -text [::HWFlow::txt "编辑 TXT" "Edit TXT"] -width 10 -command "::CompWorkflow::showMaterialEditor"
    grid $w.main.mat.list -row 0 -column 0 -columnspan 2 -sticky news -pady 3
    grid $w.main.mat.ys -row 0 -column 2 -sticky ns -pady 3
    grid $w.main.mat.reload -row 1 -column 0 -sticky w -pady 3
    grid $w.main.mat.edit -row 1 -column 1 -sticky w -pady 3

    labelframe $w.main.sel -text [::HWFlow::txt "已分类组件" "Classified Components"] -padx 8 -pady 8
    grid $w.main.sel -row 2 -column 0 -sticky ew -pady {0 8}
    button $w.main.sel.pick -text [::HWFlow::txt "选择组件" "Pick Components"] -width 18 -command "::CompWorkflow::pickMaterialComponents"
    label $w.main.sel.info -textvariable ::CompWorkflow::ui(materialText) -width 42 -anchor w
    button $w.main.sel.apply -text [::HWFlow::txt "应用材料标识" "Apply Material"] -width 18 -command "::CompWorkflow::applyMaterial"
    grid $w.main.sel.pick -row 0 -column 0 -sticky w -padx {0 6} -pady 3
    grid $w.main.sel.info -row 0 -column 1 -sticky w -pady 3
    grid $w.main.sel.apply -row 1 -column 0 -columnspan 2 -sticky e -pady {8 0}

    labelframe $w.main.rules -text [::HWFlow::txt "命名规则" "Naming Rule"] -padx 8 -pady 8
    grid $w.main.rules -row 3 -column 0 -sticky ew -pady {0 8}
    message $w.main.rules.msg -width 520 -anchor w -text [::HWFlow::txt "CATEGORY_NAME -> CATEGORY_NAME_MATERIAL。已在材料库中定义的材料后缀将被替换。" "CATEGORY_NAME -> CATEGORY_NAME_MATERIAL. Existing material suffixes from the material library are replaced."]
    grid $w.main.rules.msg -row 0 -column 0 -sticky ew

    label $w.main.status -textvariable ::CompWorkflow::ui(status) -width 70 -anchor w
    grid $w.main.status -row 4 -column 0 -sticky ew -pady {0 8}

    frame $w.btn -padx 12 -pady 10
    pack $w.btn -fill x
    button $w.btn.back -text [::HWFlow::txt "返回主页" "Back to Home"] -width 14 -command "::CompWorkflow::saveState; ::CompWorkflow::backToHome $w"
    pack $w.btn.back -side right

    bind $w <Escape> "::CompWorkflow::saveState; destroy $w"
    wm protocol $w WM_DELETE_WINDOW "::CompWorkflow::saveState; destroy $w"
    bind $w.main.mat.list <<ListboxSelect>> "::CompWorkflow::onMaterialSelect"
    ::CompWorkflow::refreshMaterialList
    ::CompWorkflow::centerWindow $w
    tkwait window $w
}

proc ::CompWorkflow::materialListWidget {} {
    if {[winfo exists .material_assign.main.mat.list]} {
        return .material_assign.main.mat.list
    }
    return ""
}

proc ::CompWorkflow::refreshMaterialList {} {
    variable ui
    set w [::CompWorkflow::materialListWidget]
    if {$w eq ""} {
        return
    }
    $w delete 0 end
    set idx 0
    set selectedIndex 0
    foreach row [::HWFlow::loadMaterials] {
        set key [dict get $row key]
        set display [dict get $row display]
        if {$display eq ""} {
            set display $key
        }
        $w insert end "$key  $display"
        if {$key eq $ui(selectedMaterial)} {
            set selectedIndex $idx
        }
        incr idx
    }
    if {[$w size] > 0} {
        $w selection set $selectedIndex
        $w see $selectedIndex
        set firstLine [$w get $selectedIndex]
        set ui(selectedMaterial) [lindex $firstLine 0]
    }
}

proc ::CompWorkflow::reloadMaterials {} {
    ::HWFlow::loadMaterials
    ::CompWorkflow::refreshMaterialList
    ::CompWorkflow::saveState
    set ::CompWorkflow::ui(status) [::HWFlow::txt "材料库已重新加载。" "Material library reloaded."]
}

proc ::CompWorkflow::onMaterialSelect {} {
    variable ui
    set w [::CompWorkflow::materialListWidget]
    if {$w eq ""} {
        return
    }
    set sel [$w curselection]
    if {[llength $sel] == 0} {
        return
    }
    set line [$w get [lindex $sel 0]]
    set ui(selectedMaterial) [lindex $line 0]
    ::CompWorkflow::saveState
}

proc ::CompWorkflow::showMaterialEditor {} {
    set path [::HWFlow::materialFile]
    catch {destroy .material_editor}
    set w .material_editor
    toplevel $w
    wm title $w [::HWFlow::txt "编辑材料库" "Edit Material Library"]
    wm resizable $w 1 1

    frame $w.main -padx 10 -pady 10
    pack $w.main -fill both -expand 1
    text $w.main.txt -width 92 -height 18 -wrap none -font {Consolas 9}
    scrollbar $w.main.y -orient vertical -command "$w.main.txt yview"
    scrollbar $w.main.x -orient horizontal -command "$w.main.txt xview"
    $w.main.txt configure -yscrollcommand "$w.main.y set" -xscrollcommand "$w.main.x set"
    grid $w.main.txt -row 0 -column 0 -sticky news
    grid $w.main.y -row 0 -column 1 -sticky ns
    grid $w.main.x -row 1 -column 0 -sticky ew
    grid rowconfigure $w.main 0 -weight 1
    grid columnconfigure $w.main 0 -weight 1
    $w.main.txt insert 1.0 [::HWFlow::readTextFile $path]

    frame $w.btn -padx 10 -pady 8
    pack $w.btn -fill x
    button $w.btn.back -text [::HWFlow::txt "返回主页" "Back to Home"] -width 14 -command "::CompWorkflow::saveState; catch {destroy .material_editor}; ::CompWorkflow::backToHome .material_assign"
    button $w.btn.save -text [::HWFlow::txt "保存" "Save"] -width 10 -command "::CompWorkflow::saveMaterialEditor"
    pack $w.btn.back -side right -padx 4
    pack $w.btn.save -side right -padx 4
    bind $w <Escape> "destroy .material_editor"
    ::CompWorkflow::centerWindow $w
}

proc ::CompWorkflow::saveMaterialEditor {} {
    set w .material_editor
    if {![winfo exists $w]} {
        return
    }
    set data [$w.main.txt get 1.0 end]
    ::HWFlow::writeTextFile [::HWFlow::materialFile] [string trimright $data]
    destroy $w
    ::CompWorkflow::reloadMaterials
}

proc ::CompWorkflow::pickClassifyComponents {} {
    variable ui
    catch {*clearmark comps 1}
    *createmarkpanel comps 1 [::HWFlow::txt "选择需要分类的组件" "Select components to classify"]
    set comps [hm_getmark comps 1]
    catch {*clearmark comps 1}
    set ui(classifyComps) $comps
    if {[llength $comps] == 0} {
        set ui(classifyText) [::HWFlow::txt "未选择组件" "No components selected"]
    } else {
        set ui(classifyText) [::HWFlow::txt "已选择 [llength $comps] 个组件" "Selected [llength $comps] component(s)"]
    }
    catch {raise .comp_category}
    catch {focus .comp_category}
}

proc ::CompWorkflow::pickMaterialComponents {} {
    variable ui
    catch {*clearmark comps 1}
    *createmarkpanel comps 1 [::HWFlow::txt "选择需要分配材料标识的已分类组件" "Select classified components for material assignment"]
    set comps [hm_getmark comps 1]
    catch {*clearmark comps 1}
    set ui(materialComps) $comps
    if {[llength $comps] == 0} {
        set ui(materialText) [::HWFlow::txt "未选择组件" "No components selected"]
    } else {
        set ui(materialText) [::HWFlow::txt "已选择 [llength $comps] 个组件" "Selected [llength $comps] component(s)"]
    }
    catch {raise .material_assign}
    catch {focus .material_assign}
}

proc ::CompWorkflow::applyCategory {} {
    variable ui
    set comps $ui(classifyComps)
    set category [string toupper [string trim $ui(classifyCategory)]]
    if {[llength $comps] == 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "组件类型分类" "Component Type Classification"] -message [::HWFlow::txt "请先选择组件。" "Pick components first."]
        return
    }

    set renamed {}
    set ids {}
    foreach compId $comps {
        set oldName [::HWFlow::componentName $compId]
        set newName [::HWFlow::replaceCategoryInName $oldName $category]
        set finalName [::HWFlow::renameComponent $oldName $newName]
        set finalId [::HWFlow::componentIdByName $finalName]
        if {$finalId eq ""} {
            set finalId $compId
        }
        lappend ids $finalId
        lappend renamed "$oldName -> $finalName"
    }

    ::HWFlow::addComponentsToAssembly $category $ids 9
    ::HWFlow::refreshBrowser
    ::CompWorkflow::saveState
    set ui(status) [::HWFlow::txt "已将 [llength $ids] 个组件分类为 $category。" "Classified [llength $ids] component(s) into $category."]
    tk_messageBox -icon info -title [::HWFlow::txt "组件类型分类" "Component Type Classification"] -message "[::HWFlow::txt "类型已应用：" "Category applied:"]\n[join [lrange $renamed 0 12] \n]"
}

proc ::CompWorkflow::applyMaterial {} {
    variable ui
    set comps $ui(materialComps)
    set matKey [string trim $ui(selectedMaterial)]
    if {[llength $comps] == 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "材料标识分配" "Material Assignment"] -message [::HWFlow::txt "请先选择组件。" "Pick components first."]
        return
    }
    if {$matKey eq "" || [::HWFlow::materialRowByKey $matKey] eq ""} {
        tk_messageBox -icon warning -title [::HWFlow::txt "材料标识分配" "Material Assignment"] -message [::HWFlow::txt "请选择有效的材料标识。" "Select a valid material."]
        return
    }

    array set byCategory {}
    set renamed {}
    set skipped {}
    foreach compId $comps {
        set oldName [::HWFlow::componentName $compId]
        set category [::HWFlow::componentCategoryFromName $oldName]
        if {$category eq "" || $category in {SEAM CONNECTOR SOURCE_GEOM}} {
            lappend skipped [::HWFlow::txt "$oldName：未识别到受支持的类型前缀" "$oldName: no supported category prefix"]
            continue
        }
        set newName [::HWFlow::replaceMaterialInName $oldName $matKey]
        set finalName [::HWFlow::renameComponent $oldName $newName]
        set finalId [::HWFlow::componentIdByName $finalName]
        if {$finalId eq ""} {
            set finalId $compId
        }
        lappend byCategory($category) $finalId
        lappend renamed "$oldName -> $finalName"
    }

    foreach category [array names byCategory] {
        set matAssembly "${category}_${matKey}"
        ::HWFlow::addComponentsToAssembly $matAssembly $byCategory($category) 10
        ::HWFlow::addAssemblyToAssembly $category $matAssembly 9
    }

    ::HWFlow::refreshBrowser
    ::CompWorkflow::saveState
    set msg [::HWFlow::txt "材料标识 $matKey 已应用到 [llength $renamed] 个组件。" "Material $matKey applied to [llength $renamed] component(s)."]
    if {[llength $skipped] > 0} {
        append msg [::HWFlow::txt "\n跳过 [llength $skipped] 个组件。" "\nSkipped [llength $skipped] component(s)."]
    }
    set ui(status) $msg
    set detail $msg
    if {[llength $renamed] > 0} {
        append detail [::HWFlow::txt "\n\n已重命名：\n[join [lrange $renamed 0 12] \n]" "\n\nRenamed:\n[join [lrange $renamed 0 12] \n]"]
    }
    if {[llength $skipped] > 0} {
        append detail [::HWFlow::txt "\n\n已跳过：\n[join [lrange $skipped 0 8] \n]" "\n\nSkipped:\n[join [lrange $skipped 0 8] \n]"]
    }
    tk_messageBox -icon info -title [::HWFlow::txt "材料标识分配" "Material Assignment"] -message $detail
}

proc ::CompWorkflow::runCategory {} {
    ::CompWorkflow::showCategoryPanel
}

proc ::CompWorkflow::runMaterial {} {
    ::CompWorkflow::showMaterialPanel
}

proc ::CompWorkflow::run {} {
    ::CompWorkflow::runCategory
}
