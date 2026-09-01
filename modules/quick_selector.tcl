# ============================================================================
# HMWorkFlow native Quick Selector actions
# HyperMesh 2019/2022 native entity-selector integration
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source -encoding utf-8 [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::Toolbox::QuickSelector {
    variable SCRIPT_DIR [file dirname [file normalize [info script]]]
    variable SETTINGS
    array set SETTINGS {
        enabled 1
        debug 0
        native_path_fallback 0
    }
    variable LAST_RESULT [dict create ok 0 reason not_run]
}

proc ::Toolbox::QuickSelector::getConfigFile {} {
    if {[info exists ::env(APPDATA)] && $::env(APPDATA) ne ""} {
        set dir [file join $::env(APPDATA) HMWorkFlow]
    } else {
        set dir [file join [file normalize "~"] .hmworkflow]
    }
    if {![file exists $dir]} { file mkdir $dir }
    return [file join $dir quick_selector.cfg]
}

proc ::Toolbox::QuickSelector::loadSettings {} {
    variable SETTINGS
    set path [::Toolbox::QuickSelector::getConfigFile]
    if {![file isfile $path]} { return 1 }
    if {[catch {set ch [open $path r]} err]} {
        ::Toolbox::QuickSelector::debugLog "settings_read_failed=$err"
        return 0
    }
    while {[gets $ch line] >= 0} {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} { continue }
        if {[catch {set fields [lrange $line 0 end]}] || [llength $fields] != 2} { continue }
        lassign $fields key value
        if {[info exists SETTINGS($key)]} {
            set SETTINGS($key) [expr {$value ? 1 : 0}]
        }
    }
    close $ch
    return 1
}

proc ::Toolbox::QuickSelector::saveSettings {} {
    variable SETTINGS
    set path [::Toolbox::QuickSelector::getConfigFile]
    set tmp "${path}.tmp"
    set ch [open $tmp w]
    puts $ch "# HMWorkFlow Quick Selector settings v1"
    foreach key {enabled debug native_path_fallback} {
        puts $ch [list $key [expr {$SETTINGS($key) ? 1 : 0}]]
    }
    close $ch
    file rename -force $tmp $path
    catch {hm_usermessage [::HWFlow::txt "快速选择功能设置已保存。" "Quick Selector settings saved."]}
    return 1
}

proc ::Toolbox::QuickSelector::debugLog {text} {
    variable SETTINGS
    if {![info exists SETTINGS(debug)] || !$SETTINGS(debug)} { return }
    catch {puts "HMWorkFlow QuickSelector: $text"}
}

proc ::Toolbox::QuickSelector::notify {zh en} {
    set message [::HWFlow::txt $zh $en]
    catch {hm_usermessage $message}
    ::Toolbox::QuickSelector::debugLog $en
}

# HyperMesh 2019's native entity selector manager keeps the most recently
# activated selector last.  This is the same source used by the native guide
# bar and, unlike scanning marks, remains correct for two-selector panels.
proc ::Toolbox::QuickSelector::activeSelectorObject {} {
    set varName ::hmtk::HMEntitySelectorMgr::_prevActiveSelectors
    if {![info exists $varName]} { return "" }
    set selectors [set $varName]
    for {set i [expr {[llength $selectors] - 1}]} {$i >= 0} {incr i -1} {
        set selector [lindex $selectors $i]
        if {$selector eq "" || [llength [info commands $selector]] == 0} { continue }
        if {![catch {$selector IsSelectorActive} active] && $active} {
            return $selector
        }
        if {![catch {$selector ExecSelectionCommand GetActive} active] && $active} {
            return $selector
        }
    }
    return ""
}

proc ::Toolbox::QuickSelector::canonicalEntity {value} {
    set value [string tolower [string trim $value]]
    switch -glob -- $value {
        element* - elem* { return elems }
        node* { return nodes }
        surface* - surf* { return surfs }
        line* { return lines }
        point* { return points }
        solid* { return solids }
        component* - comp* { return comps }
        laminate* { return laminates }
        ply - plies { return plies }
    }
    return $value
}

proc ::Toolbox::QuickSelector::entityFromTypeId {typeId} {
    if {![string is integer -strict $typeId] || [llength [info commands hm_getentitytype]] == 0} {
        return [::Toolbox::QuickSelector::canonicalEntity $typeId]
    }
    foreach {canonical queryName} {
        nodes nodes elems elements surfs surfaces lines lines points points
        solids solids comps components laminates laminates plies plies
    } {
        if {![catch {hm_getentitytype $queryName} candidate] && $candidate == $typeId} {
            return $canonical
        }
    }
    return ""
}

proc ::Toolbox::QuickSelector::resolveActiveSelector {} {
    variable SETTINGS
    if {!$SETTINGS(enabled)} {
        return [dict create valid 0 reason disabled]
    }
    if {[llength [info commands ::hm::context::GetSelectionTool]] == 0} {
        return [dict create valid 0 reason no_native_selection_tool]
    }
    if {[catch {set tool [::hm::context::GetSelectionTool]} err] || $tool eq ""} {
        return [dict create valid 0 reason selection_tool_unavailable detail $err]
    }
    set selector [::Toolbox::QuickSelector::activeSelectorObject]
    if {$selector eq ""} {
        return [dict create valid 0 reason no_active_selector]
    }
    if {[catch {$selector GetCurrentEntityType 1} entity]} {
        if {[catch {$tool GetEntityType} entity]} {
            return [dict create valid 0 reason entity_type_unavailable]
        }
    }
    set entity [::Toolbox::QuickSelector::entityFromTypeId $entity]
    if {$entity eq "" || $entity eq "all" || $entity eq "undefined"} {
        return [dict create valid 0 reason unsupported_entity entity $entity]
    }
    set count 0
    catch {set count [$tool GetNumSelected]}
    set selectionName ""
    catch {set selectionName [$selector GetSelectionName]}
    return [dict create valid 1 adapter hm2019_native_context selector $selector selection_tool $tool \
        selection_name $selectionName entity_type $entity selected_count $count]
}

proc ::Toolbox::QuickSelector::supports {entity action} {
    switch -- $action {
        by_face { return [expr {$entity in {elems nodes surfs}}] }
        by_attached { return [expr {$entity in {elems nodes surfs}}] }
        by_path_mode { return [expr {$entity in {elems nodes surfs lines laminates plies}}] }
    }
    return 0
}

proc ::Toolbox::QuickSelector::nativeEntityName {entity} {
    switch -- $entity {
        elems { return Elements }
        nodes { return Nodes }
        surfs { return Surfaces }
        lines { return Lines }
        laminates { return Laminates }
        plies { return Plies }
    }
    return $entity
}

proc ::Toolbox::QuickSelector::setResult {ok reason args} {
    variable LAST_RESULT
    set LAST_RESULT [dict create ok $ok reason $reason {*}$args]
    return $ok
}

proc ::Toolbox::QuickSelector::dispatch {action} {
    variable SETTINGS
    set ctx [::Toolbox::QuickSelector::resolveActiveSelector]
    if {![dict get $ctx valid]} {
        set reason [dict get $ctx reason]
        ::Toolbox::QuickSelector::notify "当前没有可用的原生实体选择器。" "No active native entity selector."
        return [::Toolbox::QuickSelector::setResult 0 $reason action $action]
    }
    set entity [dict get $ctx entity_type]
    if {![::Toolbox::QuickSelector::supports $entity $action]} {
        ::Toolbox::QuickSelector::notify "当前选择器不支持此功能：$entity" "This action is not available for the current selector: $entity"
        return [::Toolbox::QuickSelector::setResult 0 unsupported_entity action $action entity $entity]
    }
    if {[llength [info commands hm_entitycanselectby]] > 0} {
        switch -- $action {
            by_face { set selectionMethod "by face" }
            by_attached { set selectionMethod "by attached" }
            by_path_mode { set selectionMethod "by path" }
        }
        if {![catch {hm_entitycanselectby $selectionMethod [::Toolbox::QuickSelector::nativeEntityName $entity]} supported]
            && !$supported} {
            return [::Toolbox::QuickSelector::setResult 0 unsupported_native_method action $action entity $entity]
        }
    }
    set tool [dict get $ctx selection_tool]
    if {$action in {by_face by_attached} && [dict get $ctx selected_count] < 1} {
        ::Toolbox::QuickSelector::notify "请先选择至少一个种子实体。" "Select at least one seed entity first."
        return [::Toolbox::QuickSelector::setResult 0 no_seed action $action entity $entity]
    }

    switch -- $action {
        by_face { set nativeCommand SelectByFace }
        by_attached { set nativeCommand ByAttached }
        by_path_mode {
            set nativeCommand EnterAdvancedSelectionMode
        }
        default { return [::Toolbox::QuickSelector::setResult 0 unknown_action action $action] }
    }

    if {$action eq "by_path_mode"} {
        set code [catch {$tool $nativeCommand "by path"} err]
    } else {
        set code [catch {$tool $nativeCommand} err]
    }
    if {$code} {
        ::Toolbox::QuickSelector::debugLog "action=$action entity=$entity native_error=$err"
        # Optional, explicit fallback only.  It remains disabled by default
        # because it opens a new native collector instead of changing the
        # selector already owned by the current panel.
        if {$action eq "by_path_mode" && $SETTINGS(native_path_fallback) &&
            [llength [info commands *createlistbypathpanel]] > 0} {
            if {![catch {*createlistbypathpanel $entity 1 [::HWFlow::txt "按路径选择" "Select by path"]} fallbackErr]} {
                return [::Toolbox::QuickSelector::setResult 1 native_widget_fallback action $action entity $entity]
            }
            ::Toolbox::QuickSelector::debugLog "native_path_fallback_error=$fallbackErr"
        }
        ::Toolbox::QuickSelector::notify "原生选择命令执行失败，当前选择未被改动。" "Native selection command failed; the current selection was left unchanged."
        return [::Toolbox::QuickSelector::setResult 0 native_error action $action entity $entity detail $err]
    }
    ::Toolbox::QuickSelector::debugLog "action=$action entity=$entity selector=[dict get $ctx selector] result=success"
    return [::Toolbox::QuickSelector::setResult 1 success action $action entity $entity adapter [dict get $ctx adapter]]
}

proc ::Toolbox::QuickSelector::ByFace {} {
    return [::Toolbox::QuickSelector::dispatch by_face]
}

proc ::Toolbox::QuickSelector::ByAttached {} {
    return [::Toolbox::QuickSelector::dispatch by_attached]
}

proc ::Toolbox::QuickSelector::EnableByPathMode {} {
    return [::Toolbox::QuickSelector::dispatch by_path_mode]
}

proc ::Toolbox::QuickSelector::registerActions {} {
    if {[llength [info commands ::HWShortcut::registerAction]] == 0} { return 0 }
    ::HWShortcut::registerAction hm.selection.by_face [dict create \
        label_zh "By Face（按面扩选）" label_en "By Face" category_zh "HyperMesh / 选择" \
        category_en "HyperMesh / Selection" callback ::Toolbox::QuickSelector::ByFace repeatable 1]
    ::HWShortcut::registerAction hm.selection.by_attached [dict create \
        label_zh "By Attached（连通扩选）" label_en "By Attached" category_zh "HyperMesh / 选择" \
        category_en "HyperMesh / Selection" callback ::Toolbox::QuickSelector::ByAttached repeatable 1]
    ::HWShortcut::registerAction hm.selection.by_path_mode [dict create \
        label_zh "By Path Mode（路径模式）" label_en "By Path Mode" category_zh "HyperMesh / 选择" \
        category_en "HyperMesh / Selection" callback ::Toolbox::QuickSelector::EnableByPathMode repeatable 0]
    return 1
}

::Toolbox::QuickSelector::loadSettings
::Toolbox::QuickSelector::registerActions
