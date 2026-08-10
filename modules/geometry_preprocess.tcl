# Geometry Preprocess
# HyperMesh 2019 / 2022
#
# Vehicle-coordinate rotation and non-destructive component archiving.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source -encoding utf-8 [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::GeometryPreprocess {
    variable VERSION "1.0"
    variable WINDOW ".geometry_preprocess"
    variable USELESS_ASSEMBLY "USELESS"
    variable ui
    array set ui {status ""}
}

# HyperMesh appends .<number> when imported collectors have duplicate names.
# Remove exactly that generated suffix; dots elsewhere remain part of the name.
proc ::GeometryPreprocess::familyBase {name} {
    set value [string trim $name]
    if {[regexp {^(.*)\.[0-9]+$} $value -> base] && $base ne ""} {
        return $base
    }
    return $value
}

proc ::GeometryPreprocess::sameFamily {candidate selected} {
    set base [::GeometryPreprocess::familyBase $selected]
    if {$candidate eq $base} {
        return 1
    }
    set baseLength [string length $base]
    if {[string length $candidate] <= ($baseLength + 1) ||
        [string range $candidate 0 [expr {$baseLength - 1}]] ne $base ||
        [string index $candidate $baseLength] ne "."} {
        return 0
    }
    set suffix [string range $candidate [expr {$baseLength + 1}] end]
    return [regexp {^[0-9]+$} $suffix]
}

proc ::GeometryPreprocess::componentFamilyIds {selectedName} {
    set result {}
    foreach compId [::HWFlow::componentIds 2] {
        set name [::HWFlow::componentName $compId]
        if {[::GeometryPreprocess::sameFamily $name $selectedName]} {
            lappend result $compId
        }
    }
    return [lsort -integer -unique $result]
}

proc ::GeometryPreprocess::skeletonComponentIds {} {
    set result {}
    foreach compId [::HWFlow::componentIds 2] {
        if {[string first "SKELL" [string toupper [::HWFlow::componentName $compId]]] >= 0} {
            lappend result $compId
        }
    }
    return [lsort -integer -unique $result]
}

proc ::GeometryPreprocess::archiveComponents {compIds} {
    variable USELESS_ASSEMBLY
    if {[llength $compIds] == 0} {
        return 0
    }

    set historyName "Archive components to $USELESS_ASSEMBLY"
    set historyStarted 0
    if {![catch {*startnotehistorystate $historyName}]} {
        set historyStarted 1
    }
    set code [catch {
        set assemblyId [::HWFlow::addComponentsToAssembly $USELESS_ASSEMBLY $compIds]
        if {$assemblyId eq ""} {
            error [::HWFlow::txt \
                "无法创建或更新 $USELESS_ASSEMBLY Assembly。" \
                "Could not create or update the $USELESS_ASSEMBLY assembly."]
        }
        foreach compId $compIds {
            ::HWFlow::displayComponent [::HWFlow::componentName $compId] off
        }
    } message options]
    if {$historyStarted} {
        catch {*endnotehistorystate $historyName}
    }
    if {$code} {
        if {$historyStarted} {
            catch {*undohistorystate 1}
        }
        return -options $options $message
    }
    catch {hm_redraw}
    return [llength $compIds]
}

proc ::GeometryPreprocess::showMessage {icon title message} {
    if {[llength [info commands tk_messageBox]] > 0} {
        tk_messageBox -icon $icon -title $title -message $message
    } else {
        catch {hm_usermessage $message}
    }
}

proc ::GeometryPreprocess::convertToVehicleCoordinates {} {
    variable ui
    catch {*clearmark comps 1}
    if {[catch {*createmark comps 1 displayed} markError]} {
        set ui(status) [::HWFlow::txt "无法读取当前显示组件。" "Could not read displayed components."]
        ::GeometryPreprocess::showMessage error [::HWFlow::txt "转为车辆坐标系" "Vehicle Coordinates"] $markError
        return 0
    }
    set compIds {}
    catch {set compIds [hm_getmark comps 1]}
    if {[llength $compIds] == 0} {
        catch {*clearmark comps 1}
        set ui(status) [::HWFlow::txt "没有可转换的显示组件。" "No displayed components to transform."]
        ::GeometryPreprocess::showMessage warning [::HWFlow::txt "转为车辆坐标系" "Vehicle Coordinates"] $ui(status)
        return 0
    }

    set historyName "Convert to vehicle coordinates"
    set historyStarted 0
    if {![catch {*startnotehistorystate $historyName}]} { set historyStarted 1 }
    set code [catch {
        # Match the validated legacy macro: +90 degrees about global X,
        # followed by -90 degrees about global Z.
        *createplane 1 1 0 0 0 0 0
        *rotatemark components 1 1 90
        *createmark comps 1 displayed
        *createplane 1 0 0 1 0 0 0
        *rotatemark components 1 1 -90
    } message options]
    if {$historyStarted} { catch {*endnotehistorystate $historyName} }
    catch {*clearmark comps 1}
    catch {*clearmark components 1}
    if {$code} {
        if {$historyStarted} { catch {*undohistorystate 1} }
        set ui(status) [::HWFlow::txt "坐标转换失败，已尝试回滚。" "Coordinate conversion failed; rollback was attempted."]
        ::GeometryPreprocess::showMessage error [::HWFlow::txt "转为车辆坐标系" "Vehicle Coordinates"] "$ui(status)\n\n$message"
        return 0
    }
    catch {hm_redraw}
    set ui(status) [::HWFlow::txt \
        "已将 [llength $compIds] 个显示组件转为车辆坐标系。" \
        "Converted [llength $compIds] displayed component(s) to vehicle coordinates."]
    return [llength $compIds]
}

proc ::GeometryPreprocess::cleanIrrelevantComponents {} {
    variable ui
    catch {*clearmark comps 1}
    if {[catch {set selectedIds [::HWFlow::nativeMarkPanel comps 1 [::HWFlow::txt \
            "请选择一个组件，中键确认" \
            "Select one component and middle-click to confirm"]]} message]} {
        set ui(status) [::HWFlow::txt "组件选择已取消或失败。" "Component selection was cancelled or failed."]
        return 0
    }
    catch {*clearmark comps 1}
    if {[llength $selectedIds] == 0} {
        set ui(status) [::HWFlow::txt "未选择组件。" "No component was selected."]
        return 0
    }
    if {[llength $selectedIds] != 1} {
        set ui(status) [::HWFlow::txt "请只选择一个组件作为名称样本。" "Select exactly one component as the name sample."]
        ::GeometryPreprocess::showMessage warning [::HWFlow::txt "清理无关部件" "Clean Irrelevant Components"] $ui(status)
        return 0
    }

    set selectedName [::HWFlow::componentName [lindex $selectedIds 0]]
    set familyIds [::GeometryPreprocess::componentFamilyIds $selectedName]
    if {[catch {set count [::GeometryPreprocess::archiveComponents $familyIds]} message]} {
        set ui(status) [::HWFlow::txt "归档失败。" "Archiving failed."]
        ::GeometryPreprocess::showMessage error [::HWFlow::txt "清理无关部件" "Clean Irrelevant Components"] "$ui(status)\n\n$message"
        return 0
    }
    set base [::GeometryPreprocess::familyBase $selectedName]
    set ui(status) [::HWFlow::txt \
        "已将名称族“$base”的 $count 个组件归入 USELESS 并隐藏。" \
        "Archived and hid $count component(s) in the '$base' family under USELESS."]
    return $count
}

proc ::GeometryPreprocess::removeSkeleton {} {
    variable ui
    set compIds [::GeometryPreprocess::skeletonComponentIds]
    if {[llength $compIds] == 0} {
        set ui(status) [::HWFlow::txt "未找到名称中包含 SKELL 的组件。" "No component name containing SKELL was found."]
        return 0
    }
    if {[catch {set count [::GeometryPreprocess::archiveComponents $compIds]} message]} {
        set ui(status) [::HWFlow::txt "骨架归档失败。" "Skeleton archiving failed."]
        ::GeometryPreprocess::showMessage error [::HWFlow::txt "移除骨架" "Remove Skeleton"] "$ui(status)\n\n$message"
        return 0
    }
    set ui(status) [::HWFlow::txt \
        "已将 $count 个 SKELL 组件归入 USELESS 并隐藏。" \
        "Archived and hid $count SKELL component(s) under USELESS."]
    return $count
}

proc ::GeometryPreprocess::backToHome {} {
    variable WINDOW
    if {[llength [info commands ::HWFlow::backToHome]] > 0} {
        ::HWFlow::backToHome $WINDOW
    } else {
        catch {destroy $WINDOW}
    }
}

proc ::GeometryPreprocess::runAction {} {
    variable VERSION
    variable WINDOW
    variable ui

    catch {destroy $WINDOW}
    set ui(status) [::HWFlow::txt "请选择一项预处理操作。" "Choose a preprocessing action."]
    set w $WINDOW
    ::HWFlow::createTopLevel $w
    wm withdraw $w
    wm title $w [::HWFlow::windowTitle "[::HWFlow::txt "预处理" "Preprocess"] v$VERSION" "Preprocess v$VERSION"]
    wm minsize $w 620 390
    wm resizable $w 1 0

    set bodyBg [::HWFlow::uiColors bodyBg]
    set textPrimary [::HWFlow::uiColors textPrimary]
    set textSecondary [::HWFlow::uiColors textSecondary]

    # Shared module header: title, one-line guidance, and the native groove
    # used by the home panel and other modernized module dialogs.
    ::HWFlow::uiWidget frame $w.header -background $bodyBg
    pack $w.header -fill x -padx 14 -pady {10 0}
    ::HWFlow::uiWidget label $w.header.title \
        -text [::HWFlow::txt "几何预处理" "Geometry Preprocess"] \
        -font [::HWFlow::uiFont header] -foreground $textPrimary \
        -background $bodyBg -anchor w
    ::HWFlow::uiWidget label $w.header.hint \
        -text [::HWFlow::txt \
            "坐标统一与非破坏性组件整理" \
            "Coordinate alignment and non-destructive component organization"] \
        -font [::HWFlow::uiFont small] -foreground $textSecondary \
        -background $bodyBg -anchor w
    pack $w.header.title -fill x
    pack $w.header.hint -fill x -pady {2 0}
    ::HWFlow::groove $w.headerRule
    pack $w.headerRule -fill x -padx 14 -pady {7 0}

    ::HWFlow::uiWidget frame $w.main -background $bodyBg
    pack $w.main -fill both -expand 1 -padx 14 -pady 8

    ::HWFlow::sectionFrame $w.main.coordinates [::HWFlow::txt "1. 坐标系" "1. Coordinate System"]
    pack $w.main.coordinates -fill x -pady {0 8}
    ::HWFlow::uiWidget label $w.main.coordinates.desc \
        -text [::HWFlow::txt \
            "对当前显示组件执行全局 X +90°，再执行全局 Z -90°。执行前请确认显示范围和初始坐标系。" \
            "Rotate displayed components +90 degrees about global X, then -90 degrees about global Z. Verify the display set and starting coordinates first."] \
        -font [::HWFlow::uiFont default] -foreground $textPrimary -anchor w -justify left
    ::HWFlow::uiWidget button $w.main.coordinates.run \
        -text [::HWFlow::txt "转为车辆坐标系" "Convert to Vehicle Coordinates"] \
        -width 22 -command ::GeometryPreprocess::convertToVehicleCoordinates -cursor hand2
    grid $w.main.coordinates.desc -row 0 -column 0 -sticky ew -padx {2 12} -pady 3
    grid $w.main.coordinates.run -row 0 -column 1 -sticky e -pady 3
    grid columnconfigure $w.main.coordinates 0 -weight 1
    ::HWFlow::bindAutoWrap $w.main.coordinates.desc 290

    ::HWFlow::sectionFrame $w.main.organization [::HWFlow::txt "2. 组件整理" "2. Component Organization"]
    pack $w.main.organization -fill x -pady {0 8}
    ::HWFlow::uiWidget label $w.main.organization.cleanDesc \
        -text [::HWFlow::txt \
            "选择一个 component，中键确认后归档同名本体及 .数字 重名族。" \
            "Pick one component and middle-click; archive its base name and .number duplicates."] \
        -font [::HWFlow::uiFont default] -foreground $textPrimary -anchor w -justify left
    ::HWFlow::uiWidget button $w.main.organization.clean \
        -text [::HWFlow::txt "清理无关部件" "Clean Irrelevant Components"] \
        -width 22 -command ::GeometryPreprocess::cleanIrrelevantComponents -cursor hand2
    ::HWFlow::uiWidget label $w.main.organization.skellDesc \
        -text [::HWFlow::txt \
            "归档名称中包含 SKELL 的所有组件；匹配时不区分大小写。" \
            "Archive all components whose names contain SKELL; matching is case-insensitive."] \
        -font [::HWFlow::uiFont default] -foreground $textPrimary -anchor w -justify left
    ::HWFlow::uiWidget button $w.main.organization.skell \
        -text [::HWFlow::txt "移除骨架" "Remove Skeleton"] \
        -width 22 -command ::GeometryPreprocess::removeSkeleton -cursor hand2
    grid $w.main.organization.cleanDesc -row 0 -column 0 -sticky ew -padx {2 12} -pady 3
    grid $w.main.organization.clean -row 0 -column 1 -sticky e -pady 3
    grid $w.main.organization.skellDesc -row 1 -column 0 -sticky ew -padx {2 12} -pady 3
    grid $w.main.organization.skell -row 1 -column 1 -sticky e -pady 3
    grid columnconfigure $w.main.organization 0 -weight 1
    ::HWFlow::bindAutoWrap $w.main.organization.cleanDesc 290
    ::HWFlow::bindAutoWrap $w.main.organization.skellDesc 290

    ::HWFlow::uiWidget label $w.main.note \
        -text [::HWFlow::txt \
            "组件整理结果统一归入 USELESS Assembly 并隐藏，不删除模型内容。" \
            "Organization moves components into the USELESS assembly and hides them; model content is not deleted."] \
        -font [::HWFlow::uiFont small] -foreground $textSecondary \
        -background $bodyBg -anchor w -justify left
    ::HWFlow::uiWidget label $w.main.status \
        -textvariable ::GeometryPreprocess::ui(status) \
        -font [::HWFlow::uiFont default] -foreground $textPrimary \
        -background $bodyBg -anchor w -justify left
    pack $w.main.note -fill x -padx 2 -pady {0 6}
    pack $w.main.status -fill x -padx 2
    ::HWFlow::bindAutoWrap $w.main.note 40
    ::HWFlow::bindAutoWrap $w.main.status 40

    set footer [::HWFlow::actionBar $w.foot]
    pack $w.foot -fill x -padx 14 -pady {0 10}
    ::HWFlow::uiWidget button $footer.back \
        -text [::HWFlow::txt "返回主页" "Back to Home"] -width 12 \
        -command ::GeometryPreprocess::backToHome -cursor hand2
    pack $footer.back -side right

    bind $w <Escape> ::GeometryPreprocess::backToHome
    wm protocol $w WM_DELETE_WINDOW ::GeometryPreprocess::backToHome
    update idletasks
    ::HWFlow::centerWindow $w 680 0
    wm deiconify $w
    catch {raise $w}
    catch {focus $w}
    tkwait window $w
    return ""
}
