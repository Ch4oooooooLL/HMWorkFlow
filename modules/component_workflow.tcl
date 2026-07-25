# ============================================================================
# Component Workflow v0.2
# HyperMesh 2019 Tcl/Tk
#
# Separate category classification and material assignment workflow modules.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source -encoding utf-8 [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
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
    ::HWFlow::createTopLevel $w
    wm title $w "[::HWFlow::txt "Component Classification" "Component Classification"] v$VERSION"
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "Component Classification" "Component Classification"] -font [::HWFlow::uiFont title]
    grid $w.main.title -row 0 -column 0 -columnspan 3 -sticky w -pady {0 8}

    labelframe $w.main.classify -text [::HWFlow::txt "Classify Components" "Classify Components"] -padx 8 -pady 8
    grid $w.main.classify -row 1 -column 0 -sticky news -pady {0 8}

    label $w.main.classify.l_cat -text [::HWFlow::txt "类型" "Category"]
    tk_optionMenu $w.main.classify.m_cat ::CompWorkflow::ui(classifyCategory) SHELL SOLID CASTING
    button $w.main.classify.pick -text [::HWFlow::txt "选择组件" "Pick Components"] -width 18 -command "::CompWorkflow::pickClassifyComponents"
    label $w.main.classify.info -textvariable ::CompWorkflow::ui(classifyText) -width 40 -anchor w
    button $w.main.classify.apply -text [::HWFlow::txt "应用类型" "Apply Category"] -width 18 -command "::CompWorkflow::applyCategory"
    button $w.main.classify.auto_shell -text [::HWFlow::txt "自动识别钣金并只显示 SHELL" "Auto Sheet Metal + Show SHELL"] -width 28 -command "::CompWorkflow::autoClassifySheetMetal"
    grid $w.main.classify.l_cat -row 0 -column 0 -sticky w -padx {0 6} -pady 3
    grid $w.main.classify.m_cat -row 0 -column 1 -sticky w -pady 3
    grid $w.main.classify.pick -row 1 -column 0 -sticky w -padx {0 6} -pady 3
    grid $w.main.classify.info -row 1 -column 1 -sticky w -pady 3
    grid $w.main.classify.apply -row 2 -column 0 -columnspan 2 -sticky e -pady {8 0}
    grid $w.main.classify.auto_shell -row 3 -column 0 -columnspan 2 -sticky e -pady {6 0}

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
    ::HWFlow::createTopLevel $w
    wm title $w "[::HWFlow::txt "Material Assignment" "Material Assignment"] v$VERSION"
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "Material Assignment" "Material Assignment"] -font [::HWFlow::uiFont title]
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
    button $w.main.sel.apply -text [::HWFlow::txt "Apply Material" "Apply Material"] -width 18 -command "::CompWorkflow::applyMaterial"
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
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::txt "编辑材料库" "Edit Material Library"]
    wm resizable $w 1 1

    frame $w.main -padx 10 -pady 10
    pack $w.main -fill both -expand 1
    text $w.main.txt -width 92 -height 18 -wrap none -font [::HWFlow::uiFont fixed]
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
    ::HWFlow::nativeMarkPanel comps 1 [::HWFlow::txt "选择需要分类的组件" "Select components to classify"]
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
    ::HWFlow::nativeMarkPanel comps 1 [::HWFlow::txt "选择需要分配材料标识的已分类组件" "Select classified components for material assignment"]
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

proc ::CompWorkflow::uniq {items} {
    if {[llength $items] == 0} {
        return {}
    }
    return [lsort -unique $items]
}

proc ::CompWorkflow::entityIdsInComponent {compId datanames entityTypes {markId 2}} {
    foreach dn $datanames {
        if {![catch {set ids [hm_getvalue comps id=$compId dataname=$dn]}] && [llength $ids] > 0} {
            return [::CompWorkflow::uniq $ids]
        }
    }
    foreach etype $entityTypes {
        catch {*clearmark $etype $markId}
        if {![catch {*createmark $etype $markId "by comp id" $compId}]} {
            if {![catch {set ids [hm_getmark $etype $markId]}] && [llength $ids] > 0} {
                catch {*clearmark $etype $markId}
                return [::CompWorkflow::uniq $ids]
            }
        }
        catch {*clearmark $etype $markId}
    }
    return {}
}

proc ::CompWorkflow::elemNodes {elemId} {
    if {![catch {hm_getvalue elems id=$elemId dataname=nodes} nodes] && [llength $nodes] > 0} {
        return [::CompWorkflow::uniq $nodes]
    }
    if {![catch {hm_nodelist $elemId} nodes] && [llength $nodes] > 0} {
        return [::CompWorkflow::uniq $nodes]
    }
    return {}
}

proc ::CompWorkflow::elemConfig {elemId} {
    if {![catch {hm_getvalue elems id=$elemId dataname=config} cfg]} {
        return $cfg
    }
    return ""
}

proc ::CompWorkflow::isSolidElem {elemId} {
    set cfg [string toupper [string trim "[::CompWorkflow::elemConfig $elemId]"]]
    if {[lsearch -exact {204 205 206 208 210 213 215 220} $cfg] >= 0} {
        return 1
    }
    if {[regexp {(TETRA|TET|PENTA|WEDGE|HEX|HEXA|PYRAMID|SOLID)} $cfg]} {
        return 1
    }
    set nodeCount [llength [::CompWorkflow::elemNodes $elemId]]
    return [expr {$nodeCount >= 5}]
}

proc ::CompWorkflow::isShellElem {elemId} {
    if {[::CompWorkflow::isSolidElem $elemId]} {
        return 0
    }
    set cfg [string toupper [string trim "[::CompWorkflow::elemConfig $elemId]"]]
    if {[lsearch -exact {103 104 106 108} $cfg] >= 0 || [regexp {(SHELL|TRIA|QUAD|CQUAD|CTRIA)} $cfg]} {
        return 1
    }
    set nodeCount [llength [::CompWorkflow::elemNodes $elemId]]
    return [expr {$nodeCount >= 3 && $nodeCount <= 4}]
}

proc ::CompWorkflow::nodeXYZ {nodeId} {
    if {![catch {hm_getvalue nodes id=$nodeId dataname=x} x] &&
        ![catch {hm_getvalue nodes id=$nodeId dataname=y} y] &&
        ![catch {hm_getvalue nodes id=$nodeId dataname=z} z]} {
        return [list $x $y $z]
    }
    if {![catch {hm_nodevalue $nodeId} val]} {
        if {[llength $val] == 1} {
            set val [lindex $val 0]
        }
        if {[llength $val] >= 3} {
            return [lrange $val 0 2]
        }
    }
    return ""
}

proc ::CompWorkflow::pointXYZ {pointId} {
    foreach etype {points point nodes node} {
        if {![catch {set xyz [hm_getvalue $etype id=$pointId dataname=coordinates]}] && [llength $xyz] >= 3} {
            return [lrange $xyz 0 2]
        }
        if {![catch {set xyz [hm_getentityvalue $etype $pointId coordinates 0]}] && [llength $xyz] >= 3} {
            return [lrange $xyz 0 2]
        }
    }
    return ""
}

proc ::CompWorkflow::surfacePointIds {surfId} {
    set points {}
    if {[catch {set loops [hm_getsurfaceedges $surfId]}]} {
        return {}
    }
    foreach loop $loops {
        foreach edgeId $loop {
            if {![catch {set edgePoints [hm_getverticesfromedge $edgeId]}]} {
                set points [concat $points $edgePoints]
            }
        }
    }
    return [::CompWorkflow::uniq $points]
}

proc ::CompWorkflow::componentBBox {compId elems surfs points} {
    set coords {}
    foreach elemId $elems {
        foreach nodeId [::CompWorkflow::elemNodes $elemId] {
            set p [::CompWorkflow::nodeXYZ $nodeId]
            if {$p ne ""} {
                lappend coords $p
            }
        }
    }
    foreach pointId $points {
        set p [::CompWorkflow::pointXYZ $pointId]
        if {$p ne ""} {
            lappend coords $p
        }
    }
    foreach surfId $surfs {
        foreach pointId [::CompWorkflow::surfacePointIds $surfId] {
            set p [::CompWorkflow::pointXYZ $pointId]
            if {$p ne ""} {
                lappend coords $p
            }
        }
    }
    if {[llength $coords] == 0} {
        return ""
    }

    set first 1
    foreach p $coords {
        if {$first} {
            set xmin [lindex $p 0]; set xmax $xmin
            set ymin [lindex $p 1]; set ymax $ymin
            set zmin [lindex $p 2]; set zmax $zmin
            set first 0
            continue
        }
        set x [lindex $p 0]; set y [lindex $p 1]; set z [lindex $p 2]
        if {$x < $xmin} {set xmin $x}
        if {$x > $xmax} {set xmax $x}
        if {$y < $ymin} {set ymin $y}
        if {$y > $ymax} {set ymax $y}
        if {$z < $zmin} {set zmin $z}
        if {$z > $zmax} {set zmax $z}
    }
    set ranges [list [expr {$xmax - $xmin}] [expr {$ymax - $ymin}] [expr {$zmax - $zmin}]]
    return [dict create min [list $xmin $ymin $zmin] max [list $xmax $ymax $zmax] range $ranges]
}

proc ::CompWorkflow::bboxLooksThin {bbox} {
    if {$bbox eq ""} {
        return 0
    }
    set dims {}
    foreach d [dict get $bbox range] {
        if {[string is double -strict $d] && $d > 1.0e-9} {
            lappend dims [expr {double($d)}]
        }
    }
    if {[llength $dims] < 2} {
        return 0
    }
    set dims [lsort -real $dims]
    set smallest [lindex $dims 0]
    set largest [lindex $dims end]
    if {$largest <= 1.0e-9} {
        return 0
    }
    return [expr {$smallest / $largest <= 0.28}]
}

proc ::CompWorkflow::surfaceArea {surfId} {
    foreach cmd [list \
        [list hm_getareaofsurface surfs $surfId] \
        [list hm_getvalue surfs id=$surfId dataname=area] \
        [list hm_getentityvalue surfs $surfId area 0]] {
        if {![catch {set area [uplevel #0 $cmd]}] && [string is double -strict $area] && $area > 0.0} {
            return [expr {double($area)}]
        }
    }
    return 0.0
}

proc ::CompWorkflow::solidVolume {solidId} {
    foreach cmd [list \
        [list hm_getvolumeofsolid solids $solidId] \
        [list hm_getvalue solids id=$solidId dataname=volume] \
        [list hm_getentityvalue solids $solidId volume 0]] {
        if {![catch {set volume [uplevel #0 $cmd]}] && [string is double -strict $volume] && $volume > 0.0} {
            return [expr {double($volume)}]
        }
    }
    return 0.0
}

proc ::CompWorkflow::solidGeometryLooksThin {solids surfs bbox} {
    if {[llength $solids] == 0 || $bbox eq ""} {
        return 0
    }

    set totalVolume 0.0
    foreach solidId $solids {
        set totalVolume [expr {$totalVolume + [::CompWorkflow::solidVolume $solidId]}]
    }
    set totalArea 0.0
    foreach surfId $surfs {
        set totalArea [expr {$totalArea + [::CompWorkflow::surfaceArea $surfId]}]
    }
    if {$totalVolume <= 0.0 || $totalArea <= 0.0} {
        return [::CompWorkflow::bboxLooksThin $bbox]
    }

    set dims {}
    foreach d [dict get $bbox range] {
        if {[string is double -strict $d] && $d > 1.0e-9} {
            lappend dims [expr {double($d)}]
        }
    }
    if {[llength $dims] == 0} {
        return 0
    }
    set longest [lindex [lsort -real $dims] end]
    if {$longest <= 1.0e-9} {
        return 0
    }

    set estimatedThickness [expr {2.0 * $totalVolume / $totalArea}]
    return [expr {$estimatedThickness > 0.0 && $estimatedThickness / $longest <= 0.30}]
}

proc ::CompWorkflow::nameLooksSheetMetal {name} {
    set u [string toupper [string trim $name]]
    if {[::HWFlow::componentCategoryFromName $u] eq "SHELL"} {
        return 1
    }
    return [regexp {(SHEET|SHELL|PANEL|PLATE|BRACKET|STAMP|MIDSURF|MID_SURF|THIN)} $u]
}

proc ::CompWorkflow::sheetMetalCandidate {compId} {
    set name [::HWFlow::componentName $compId]
    set elems [::CompWorkflow::entityIdsInComponent $compId {elems elements} {elems elements}]
    set surfs [::CompWorkflow::entityIdsInComponent $compId {surfaces surfs} {surfs surfaces}]
    set solids [::CompWorkflow::entityIdsInComponent $compId {solids solid} {solids solid}]
    set points [::CompWorkflow::entityIdsInComponent $compId {points point} {points point}]

    if {[::CompWorkflow::nameLooksSheetMetal $name]} {
        return [list 1 name]
    }
    if {[llength $surfs] > 0 && [llength $solids] == 0 && [llength $elems] == 0} {
        return [list 1 surfaces]
    }

    set shellElems 0
    set solidElems 0
    foreach elemId $elems {
        if {[::CompWorkflow::isShellElem $elemId]} {
            incr shellElems
        } elseif {[::CompWorkflow::isSolidElem $elemId]} {
            incr solidElems
        }
    }
    if {$shellElems > 0} {
        return [list 1 shell_elements]
    }

    set bbox [::CompWorkflow::componentBBox $compId $elems $surfs $points]
    if {[llength $solids] > 0 && [::CompWorkflow::solidGeometryLooksThin $solids $surfs $bbox]} {
        return [list 1 thin_solid_geometry]
    }
    if {$solidElems > 0 && [::CompWorkflow::bboxLooksThin $bbox]} {
        return [list 1 thin_solid_mesh]
    }
    return [list 0 not_sheet_like]
}

proc ::CompWorkflow::assemblyName {assemblyId} {
    foreach etype {assemblies assems assembly} {
        if {![catch {set n [hm_entityinfo name $etype $assemblyId -byid]}] && $n ne ""} {
            return $n
        }
        if {![catch {set n [hm_getvalue $etype id=$assemblyId dataname=name]}] && $n ne ""} {
            return $n
        }
    }
    return ""
}

proc ::CompWorkflow::assemblyIds {{markId 2}} {
    set ids {}
    foreach etype {assemblies assems} {
        catch {*clearmark $etype $markId}
        if {![catch {*createmark $etype $markId all}]} {
            catch {set ids [hm_getmark $etype $markId]}
        }
        catch {*clearmark $etype $markId}
        if {[llength $ids] > 0} {
            break
        }
    }
    return [lsort -integer -unique $ids]
}

proc ::CompWorkflow::displayAssembly {assemblyName state} {
    foreach etype {assembly assemblies assem assems} {
        catch {*displaycollector $etype $state $assemblyName 1 1}
        catch {*displaycollectorwithfilter $etype $state $assemblyName 1 1}
    }
}

proc ::CompWorkflow::isolateShellAssemblies {} {
    foreach assemblyId [::CompWorkflow::assemblyIds 2] {
        set name [::CompWorkflow::assemblyName $assemblyId]
        if {$name eq ""} {
            continue
        }
        if {$name eq "SHELL" || [string match "SHELL_*" $name]} {
            ::CompWorkflow::displayAssembly $name on
        } else {
            ::CompWorkflow::displayAssembly $name off
        }
    }
}

proc ::CompWorkflow::isolateComponents {compIds} {
    set visibleIds [lsort -integer -unique $compIds]
    array set visible {}
    foreach compId $visibleIds {
        set visible($compId) 1
    }

    set snapshot [::HWFlow::componentSnapshot 2]
    ::CompWorkflow::isolateShellAssemblies
    foreach compId [dict get $snapshot ids] {
        set name [::HWFlow::componentName $compId]
        if {$name eq ""} {
            continue
        }
        if {[info exists visible($compId)]} {
            ::HWFlow::displayComponent $name on
        } else {
            ::HWFlow::displayComponent $name off
        }
    }
    catch {hm_redraw}
    catch {update idletasks}
}

proc ::CompWorkflow::autoClassifySheetMetal {} {
    variable ui

    set snapshot [::HWFlow::componentSnapshot 2]
    set compIds [dict get $snapshot ids]
    if {[llength $compIds] == 0} {
        set ui(status) [::HWFlow::txt "未扫描到模型 component。" "No model components found."]
        tk_messageBox -icon warning -title [::HWFlow::txt "自动识别钣金" "Auto Sheet Metal"] -message $ui(status)
        return
    }

    set progressOpened 0
    if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
        set progressOpened [::HWFlow::progressOpen \
            [::HWFlow::txt "自动识别钣金" "Auto Sheet Metal"] \
            [::HWFlow::txt "正在按组件拓扑扫描..." "Scanning component topology..."] \
            0]
    }

    set candidates {}
    array set reasonCounts {}
    set total [llength $compIds]
    set index 0
    foreach compId $compIds {
        incr index
        set name [::HWFlow::componentName $compId]
        set result [::CompWorkflow::sheetMetalCandidate $compId]
        set isCandidate [lindex $result 0]
        set reason [lindex $result 1]
        if {$isCandidate} {
            lappend candidates $compId
            if {![info exists reasonCounts($reason)]} {
                set reasonCounts($reason) 0
            }
            incr reasonCounts($reason)
        }
        if {$progressOpened && [llength [info commands ::HWFlow::progressUpdate]] > 0} {
            set pct [expr {5.0 + 55.0 * ($index / double($total))}]
            catch {::HWFlow::progressUpdate $pct \
                [::HWFlow::txt "正在识别钣金组件" "Detecting sheet-metal components"] \
                "$index/$total: $name" \
                [expr {$index == $total}]}
        }
    }

    if {[llength $candidates] == 0} {
        if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
            catch {::HWFlow::progressClose [::HWFlow::txt "未识别到钣金组件。" "No sheet-metal components detected."] 100.0}
        }
        set ui(status) [::HWFlow::txt "未识别到钣金组件；显示状态未改变。" "No sheet-metal components detected; visibility was not changed."]
        tk_messageBox -icon info -title [::HWFlow::txt "自动识别钣金" "Auto Sheet Metal"] -message $ui(status)
        return
    }

    set renamed {}
    set finalIds {}
    set index 0
    foreach compId $candidates {
        incr index
        set oldName [::HWFlow::componentName $compId]
        set newName [::HWFlow::replaceCategoryInName $oldName SHELL]
        if {$progressOpened && [llength [info commands ::HWFlow::progressUpdate]] > 0} {
            set pct [expr {60.0 + 25.0 * ($index / double([llength $candidates]))}]
            catch {::HWFlow::progressUpdate $pct \
                [::HWFlow::txt "正在归类为 SHELL" "Classifying as SHELL"] \
                "$index/[llength $candidates]: $oldName -> $newName" \
                [expr {$index == [llength $candidates]}]}
        }
        set finalName [::HWFlow::renameComponent $oldName $newName]
        set finalId [::HWFlow::componentIdByName $finalName]
        if {$finalId eq ""} {
            set finalId $compId
        }
        lappend finalIds $finalId
        lappend renamed "$oldName -> $finalName"
    }

    ::HWFlow::addComponentsToAssembly SHELL $finalIds 9
    if {$progressOpened && [llength [info commands ::HWFlow::progressUpdate]] > 0} {
        catch {::HWFlow::progressUpdate 90.0 \
            [::HWFlow::txt "正在隔离显示 SHELL" "Showing SHELL only"] \
            [::HWFlow::txt "隐藏其他组件并打开 SHELL 组件..." "Hiding other components and showing SHELL components..."] \
            0}
    }
    ::CompWorkflow::isolateComponents $finalIds
    ::HWFlow::refreshBrowser
    ::CompWorkflow::saveState

    set ui(classifyCategory) SHELL
    set ui(classifyComps) $finalIds
    set ui(classifyText) [::HWFlow::txt "自动识别 [llength $finalIds] 个 SHELL 组件" "Auto-detected [llength $finalIds] SHELL component(s)"]

    set reasonSummary {}
    foreach reason [lsort [array names reasonCounts]] {
        lappend reasonSummary "$reason=$reasonCounts($reason)"
    }
    set msg [::HWFlow::txt \
        "自动识别完成：已将 [llength $finalIds] 个组件归类为 SHELL，并隐藏其他组件。识别原因：[join $reasonSummary {, }]" \
        "Auto detection finished: classified [llength $finalIds] component(s) as SHELL and hid other components. Reasons: [join $reasonSummary {, }]"]
    set ui(status) $msg
    if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose [::HWFlow::txt "自动识别钣金完成。" "Auto sheet-metal detection finished."] 100.0}
    }

    set detail $msg
    append detail [::HWFlow::txt "\n\n已重命名：\n[join [lrange $renamed 0 12] \n]" "\n\nRenamed:\n[join [lrange $renamed 0 12] \n]"]
    if {[llength $renamed] > 13} {
        append detail [::HWFlow::txt "\n..." "\n..."]
    }
    tk_messageBox -icon info -title [::HWFlow::txt "自动识别钣金" "Auto Sheet Metal"] -message $detail
}

proc ::CompWorkflow::applyCategory {} {
    variable ui
    set comps $ui(classifyComps)
    set category [string toupper [string trim $ui(classifyCategory)]]
    if {[llength $comps] == 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Component Classification" "Component Classification"] -message [::HWFlow::txt "请先选择组件。" "Pick components first."]
        return
    }

    set renamed {}
    set ids {}
    set total [llength $comps]
    set progressOpened 0
    if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
        set progressOpened [::HWFlow::progressOpen \
            [::HWFlow::txt "Component Classification" "Component Classification"] \
            [::HWFlow::txt "准备应用组件类型..." "Preparing component classification..."] \
            0]
    }
    set index 0
    foreach compId $comps {
        incr index
        set oldName [::HWFlow::componentName $compId]
        set newName [::HWFlow::replaceCategoryInName $oldName $category]
        if {$progressOpened && [llength [info commands ::HWFlow::progressUpdate]] > 0} {
            set pct [expr {10.0 + 75.0 * ($index / double($total))}]
            catch {::HWFlow::progressUpdate $pct \
                [::HWFlow::txt "Component classification running" "Component classification running"] \
                "$index/$total: $oldName -> $newName" \
                [expr {$index == $total}]}
        }
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
    if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose [::HWFlow::txt "Component classification finished." "Component classification finished."] 100.0}
    }
    tk_messageBox -icon info -title [::HWFlow::txt "Component Classification" "Component Classification"] -message "[::HWFlow::txt "类型已应用：" "Category applied:"]\n[join [lrange $renamed 0 12] \n]"
}

proc ::CompWorkflow::applyMaterial {} {
    variable ui
    if {[catch {::HWFlow::requireEngineeringContext} preflightError]} {
        tk_messageBox -icon warning -title "HMWorkFlow Preflight" -message $preflightError
        return
    }
    set comps $ui(materialComps)
    set matKey [string trim $ui(selectedMaterial)]
    if {[llength $comps] == 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Material Assignment" "Material Assignment"] -message [::HWFlow::txt "请先选择组件。" "Pick components first."]
        return
    }
    if {$matKey eq "" || [::HWFlow::materialRowByKey $matKey] eq ""} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Material Assignment" "Material Assignment"] -message [::HWFlow::txt "请选择有效的材料标识。" "Select a valid material."]
        return
    }

    array set byCategory {}
    set renamed {}
    set skipped {}
    set total [llength $comps]
    set progressOpened 0
    if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
        set progressOpened [::HWFlow::progressOpen \
            [::HWFlow::txt "Material Assignment" "Material Assignment"] \
            [::HWFlow::txt "准备应用材料标识..." "Preparing material assignment..."] \
            0]
    }
    set index 0
    foreach compId $comps {
        incr index
        set oldName [::HWFlow::componentName $compId]
        set category [::HWFlow::componentCategoryFromName $oldName]
        if {$category eq "" || $category in {SEAM CONNECTOR SOURCE_GEOM}} {
            if {$progressOpened && [llength [info commands ::HWFlow::progressUpdate]] > 0} {
                set pct [expr {10.0 + 70.0 * ($index / double($total))}]
                catch {::HWFlow::progressUpdate $pct \
                    [::HWFlow::txt "Material assignment running" "Material assignment running"] \
                    "$index/$total: $oldName -> skipped" \
                    [expr {$index == $total}]}
            }
            lappend skipped [::HWFlow::txt "$oldName：未识别到受支持的类型前缀" "$oldName: no supported category prefix"]
            continue
        }
        set newName [::HWFlow::replaceMaterialInName $oldName $matKey]
        if {$progressOpened && [llength [info commands ::HWFlow::progressUpdate]] > 0} {
            set pct [expr {10.0 + 70.0 * ($index / double($total))}]
            catch {::HWFlow::progressUpdate $pct \
                [::HWFlow::txt "Material assignment running" "Material assignment running"] \
                "$index/$total: $oldName -> $newName" \
                [expr {$index == $total}]}
        }
        set finalName [::HWFlow::renameComponent $oldName $newName]
        set finalId [::HWFlow::componentIdByName $finalName]
        if {$finalId eq ""} {
            set finalId $compId
        }
        lappend byCategory($category) $finalId
        lappend renamed "$oldName -> $finalName"
    }

    foreach category [array names byCategory] {
        if {$progressOpened && [llength [info commands ::HWFlow::progressAppend]] > 0} {
            catch {::HWFlow::progressAppend [::HWFlow::txt "组织材料装配：${category}_${matKey}" "Organizing material assembly: ${category}_${matKey}"]}
        }
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
    if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose [::HWFlow::txt "Material assignment finished." "Material assignment finished."] 100.0}
    }
    tk_messageBox -icon info -title [::HWFlow::txt "Material Assignment" "Material Assignment"] -message $detail
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
