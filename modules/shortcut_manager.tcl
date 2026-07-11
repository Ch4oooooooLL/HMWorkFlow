# ============================================================================
# HMWorkFlow Shortcut Manager
# HyperMesh 2019 Tcl/Tk
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::HWShortcut {
    # Cache script locations while this file is being sourced.  Do not call
    # [info script] later from Tk callbacks; it is normally empty then.
    variable SCRIPT_FILE [file normalize [info script]]
    variable SCRIPT_DIR [file dirname $SCRIPT_FILE]
    variable PROJECT_ROOT [file dirname $SCRIPT_DIR]

    variable MODULE_MAP
    variable KEY_MAP
    variable ENABLED_MAP
    variable ROW_MODULE
    variable INITIALIZED 0
    variable CONFIG_LOADED 0
    variable SELECTED_MODULE ""
    variable CAPTURED_SHORTCUT ""
    variable AUTO_INSTALL 1
    variable MARK_START "# >>> HMWorkFlow shortcut loader >>>"
    variable MARK_END "# <<< HMWorkFlow shortcut loader <<<"
}

proc ::HWShortcut::projectRoot {} {
    variable PROJECT_ROOT
    return $PROJECT_ROOT
}

proc ::HWShortcut::log {text} {
    catch {puts "HMWorkFlow shortcuts: $text"}
}

proc ::HWShortcut::getUserConfigDir {} {
    if {[info exists ::env(APPDATA)] && $::env(APPDATA) ne ""} {
        set dir [file join $::env(APPDATA) HMWorkFlow]
    } else {
        set dir [file join [file normalize "~"] .hmworkflow]
    }
    if {![file exists $dir]} {
        file mkdir $dir
    }
    return $dir
}

proc ::HWShortcut::getConfigFile {} {
    return [file join [::HWShortcut::getUserConfigDir] shortcuts.cfg]
}

proc ::HWShortcut::getBootstrapFile {} {
    return [file join [::HWShortcut::projectRoot] shortcut_bootstrap.tcl]
}

proc ::HWShortcut::getHmcustomFile {} {
    return [file join [file normalize "~"] hmcustom.tcl]
}

proc ::HWShortcut::moduleExistsVisible {moduleKey} {
    if {![namespace exists ::HWToolkit]} { return 0 }
    variable ::HWToolkit::MODULES
    if {![dict exists $::HWToolkit::MODULES $moduleKey]} { return 0 }
    return [::HWToolkit::moduleVisible [dict get $::HWToolkit::MODULES $moduleKey]]
}

proc ::HWShortcut::moduleLabel {moduleKey} {
    variable ::HWToolkit::MODULES
    if {![dict exists $::HWToolkit::MODULES $moduleKey]} { return $moduleKey }
    return [::HWToolkit::moduleText [dict get $::HWToolkit::MODULES $moduleKey] label]
}

proc ::HWShortcut::moduleGroup {moduleKey} {
    variable ::HWToolkit::MODULES
    if {![dict exists $::HWToolkit::MODULES $moduleKey]} { return "" }
    set info [dict get $::HWToolkit::MODULES $moduleKey]
    if {[dict exists $info group]} { return [::HWToolkit::groupText [dict get $info group]] }
    return ""
}

proc ::HWShortcut::moduleShortcut {moduleKey} {
    variable MODULE_MAP
    variable ENABLED_MAP
    if {[info exists MODULE_MAP($moduleKey)] && [info exists ENABLED_MAP($moduleKey)] && $ENABLED_MAP($moduleKey)} {
        return $MODULE_MAP($moduleKey)
    }
    return ""
}

proc ::HWShortcut::clearMemory {} {
    variable MODULE_MAP
    variable KEY_MAP
    variable ENABLED_MAP
    catch {array unset MODULE_MAP}
    catch {array unset KEY_MAP}
    catch {array unset ENABLED_MAP}
}

proc ::HWShortcut::normalizeShortcut {shortcut} {
    set shortcut [string trim $shortcut]
    if {$shortcut eq ""} { return "" }
    set parts [split $shortcut "-"]
    set hasCtrl 0
    set hasShift 0
    set key ""
    foreach part $parts {
        set p [string trim $part]
        switch -nocase -- $p {
            Control - Ctrl { set hasCtrl 1 }
            Shift { set hasShift 1 }
            default { set key $p }
        }
    }
    if {$key eq ""} { return "" }
    set upper [string toupper $key]
    if {[regexp {^F([0-9]|1[0-2])$} $upper]} {
        set key $upper
    } elseif {[string length $key] == 1 && [string is alpha $key]} {
        if {$hasShift} {
            set key [string toupper $key]
        } else {
            set key [string tolower $key]
        }
    } elseif {[string length $key] == 1 && [string is digit $key]} {
        set key $key
    } else {
        set key $upper
    }
    set out {}
    if {$hasCtrl} { lappend out Control }
    if {$hasShift} { lappend out Shift }
    lappend out $key
    return [join $out "-"]
}

proc ::HWShortcut::validateShortcut {shortcut {moduleKey ""}} {
    variable KEY_MAP
    set shortcut [::HWShortcut::normalizeShortcut $shortcut]
    if {$shortcut eq ""} {
        return [list 0 [::HWFlow::txt "快捷键为空。" "Shortcut is empty."] ""]
    }

    set dangerousKeys {Escape Return Enter Tab Space BackSpace Delete Insert Home End Left Right Up Down Prior Next}
    set parts [split $shortcut "-"]
    set key [lindex $parts end]
    foreach bad $dangerousKeys {
        if {[string equal -nocase $key $bad]} {
            return [list 0 [::HWFlow::txt "该按键不能绑定。" "This key cannot be bound."] ""]
        }
    }

    set hasCtrl [expr {[lsearch -exact $parts Control] >= 0}]
    set hasShift [expr {[lsearch -exact $parts Shift] >= 0}]
    if {!$hasCtrl && !$hasShift && ![regexp {^F(1[1-2])$} $key]} {
        return [list 0 [::HWFlow::txt "普通按键必须配合 Control/Shift，或使用 F11/F12。" "Plain keys require Control/Shift, or use F11/F12."] ""]
    }

    set lower [string tolower $shortcut]
    foreach reserved {control-z control-y control-s control-o control-n control-c control-v control-x} {
        if {$lower eq $reserved} {
            return [list 0 [::HWFlow::txt "该组合键属于保留快捷键。" "This shortcut is reserved."] ""]
        }
    }

    if {[regexp {^F([1-9]|10)$} $key] || [regexp {^(Control-|Shift-|Control-Shift-)F([1-9]|10)$} $shortcut]} {
        return [list 0 [::HWFlow::txt "F1-F10 容易与 HyperMesh 原生命令冲突，默认禁止。" "F1-F10 may conflict with native HyperMesh commands and are disabled by default."] ""]
    }

    if {[info exists KEY_MAP($shortcut)] && $KEY_MAP($shortcut) ne $moduleKey} {
        return [list 0 [::HWFlow::txt "该快捷键已被 [::HWShortcut::moduleLabel $KEY_MAP($shortcut)] 占用。" "This shortcut is already used by [::HWShortcut::moduleLabel $KEY_MAP($shortcut)]."] ""]
    }

    set warning ""
    if {[regexp {F(11|12)$} $shortcut]} {
        set warning [::HWFlow::txt "注意：功能键可能与 HyperMesh 原生命令冲突。" "Note: function keys may conflict with native HyperMesh commands."]
    }
    return [list 1 "" $warning]
}

proc ::HWShortcut::shortcutFromEvent {keysym state} {
    set ignored {Control_L Control_R Shift_L Shift_R Alt_L Alt_R Meta_L Meta_R Super_L Super_R}
    if {[lsearch -exact $ignored $keysym] >= 0} { return "" }
    set hasShift [expr {$state & 1}]
    set hasCtrl [expr {$state & 4}]
    if {[string match "F*" $keysym]} {
        set key [string toupper $keysym]
    } elseif {[string length $keysym] == 1} {
        set key $keysym
    } else {
        set key $keysym
    }
    set parts {}
    if {$hasCtrl} { lappend parts Control }
    if {$hasShift} { lappend parts Shift }
    lappend parts $key
    return [::HWShortcut::normalizeShortcut [join $parts "-"]]
}

proc ::HWShortcut::loadConfig {} {
    variable MODULE_MAP
    variable KEY_MAP
    variable ENABLED_MAP
    variable CONFIG_LOADED
    ::HWShortcut::clearMemory
    set file ""
    if {[catch {set file [::HWShortcut::getConfigFile]} err]} {
        ::HWShortcut::log "cannot resolve config path: $err"
        return 0
    }
    if {![file exists $file]} {
        set CONFIG_LOADED 1
        return 1
    }
    if {[catch {set ch [open $file r]} err]} {
        ::HWShortcut::log "cannot read $file: $err"
        return 0
    }
    set lineNo 0
    while {[gets $ch line] >= 0} {
        incr lineNo
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} { continue }
        if {[catch {set fields [lrange $line 0 end]} err] || [llength $fields] != 3} {
            ::HWShortcut::log "skip damaged config line $lineNo"
            continue
        }
        set moduleKey [lindex $fields 0]
        set shortcut [::HWShortcut::normalizeShortcut [lindex $fields 1]]
        set enabled [lindex $fields 2]
        if {![::HWShortcut::moduleExistsVisible $moduleKey]} {
            ::HWShortcut::log "skip unknown or hidden module $moduleKey"
            continue
        }
        set valid [::HWShortcut::validateShortcut $shortcut $moduleKey]
        if {![lindex $valid 0]} {
            ::HWShortcut::log "skip invalid shortcut $shortcut: [lindex $valid 1]"
            continue
        }
        if {[info exists KEY_MAP($shortcut)] && $KEY_MAP($shortcut) ne $moduleKey} {
            ::HWShortcut::log "skip duplicate shortcut $shortcut"
            continue
        }
        set MODULE_MAP($moduleKey) $shortcut
        set ENABLED_MAP($moduleKey) [expr {$enabled ? 1 : 0}]
        if {$ENABLED_MAP($moduleKey)} {
            set KEY_MAP($shortcut) $moduleKey
        }
    }
    close $ch
    set CONFIG_LOADED 1
    return 1
}

proc ::HWShortcut::saveConfig {} {
    variable MODULE_MAP
    variable ENABLED_MAP
    if {[catch {set file [::HWShortcut::getConfigFile]} err]} {
        error [::HWFlow::txt "无法定位快捷键配置路径：$err" "Cannot resolve shortcut config path: $err"]
    }
    set tmp "${file}.tmp"
    if {[catch {set ch [open $tmp w]} err]} {
        error [::HWFlow::txt "无法写入快捷键配置：$err" "Cannot write shortcut config: $err"]
    }
    puts $ch "# HMWorkFlow shortcut configuration v1"
    foreach moduleKey [lsort [array names MODULE_MAP]] {
        set enabled 1
        if {[info exists ENABLED_MAP($moduleKey)]} { set enabled $ENABLED_MAP($moduleKey) }
        puts $ch [list $moduleKey $MODULE_MAP($moduleKey) $enabled]
    }
    if {[catch {close $ch} err]} {
        catch {file delete -force $tmp}
        error [::HWFlow::txt "无法关闭快捷键配置：$err" "Cannot close shortcut config: $err"]
    }
    if {[catch {file rename -force $tmp $file} err]} {
        catch {file delete -force $tmp}
        error [::HWFlow::txt "无法替换快捷键配置：$err" "Cannot replace shortcut config: $err"]
    }
    return 1
}

proc ::HWShortcut::rebuildKeyMap {} {
    variable MODULE_MAP
    variable KEY_MAP
    variable ENABLED_MAP
    catch {array unset KEY_MAP}
    foreach moduleKey [array names MODULE_MAP] {
        if {[info exists ENABLED_MAP($moduleKey)] && $ENABLED_MAP($moduleKey)} {
            set KEY_MAP($MODULE_MAP($moduleKey)) $moduleKey
        }
    }
}

proc ::HWShortcut::registerBinding {shortcut moduleKey} {
    set script [list ::HWShortcut::dispatch $shortcut]
    if {[catch {hm_registerkeyproc $shortcut {} $script} err]} {
        ::HWShortcut::log "hm_registerkeyproc failed for $shortcut: $err"
        return 0
    }
    return 1
}

proc ::HWShortcut::registerAll {} {
    variable KEY_MAP
    foreach shortcut [array names KEY_MAP] {
        ::HWShortcut::registerBinding $shortcut $KEY_MAP($shortcut)
    }
}

proc ::HWShortcut::initialize {} {
    variable INITIALIZED
    if {!$INITIALIZED} {
        set INITIALIZED 1
    }
    ::HWShortcut::loadConfig
    ::HWShortcut::registerAll
    return 1
}

proc ::HWShortcut::dispatch {shortcut} {
    variable KEY_MAP
    set shortcut [::HWShortcut::normalizeShortcut $shortcut]
    if {![info exists KEY_MAP($shortcut)]} { return }
    ::HWToolkit::invokeModule $KEY_MAP($shortcut)
}

proc ::HWShortcut::applyBinding {moduleKey shortcut} {
    variable MODULE_MAP
    variable KEY_MAP
    variable ENABLED_MAP
    set shortcut [::HWShortcut::normalizeShortcut $shortcut]
    if {![::HWShortcut::moduleExistsVisible $moduleKey]} {
        error [::HWFlow::txt "模块不可用。" "Module is not available."]
    }
    set valid [::HWShortcut::validateShortcut $shortcut $moduleKey]
    if {![lindex $valid 0]} {
        error [lindex $valid 1]
    }
    if {[info exists MODULE_MAP($moduleKey)]} {
        unset -nocomplain KEY_MAP($MODULE_MAP($moduleKey))
    }
    set MODULE_MAP($moduleKey) $shortcut
    set ENABLED_MAP($moduleKey) 1
    set KEY_MAP($shortcut) $moduleKey
    ::HWShortcut::registerBinding $shortcut $moduleKey
    ::HWShortcut::saveConfig
    if {[lindex $valid 2] ne ""} {
        catch {hm_usermessage [lindex $valid 2]}
    }
    if {[::HWShortcut::getAutoLoaderStatusValue] ne "enabled"} {
        catch {::HWShortcut::installAutoLoader} autoErr
        if {[info exists autoErr] && $autoErr ne ""} {
            catch {hm_usermessage [::HWFlow::txt "当前会话快捷键已生效，但启动自动恢复安装失败。" "Shortcut is active now, but startup restore could not be installed."]}
            ::HWShortcut::log "autoloader install failed: $autoErr"
        }
    }
    ::HWToolkit::refreshShortcutDisplays
    ::HWShortcut::refreshManager
    return 1
}

proc ::HWShortcut::clearBinding {moduleKey} {
    variable MODULE_MAP
    variable KEY_MAP
    variable ENABLED_MAP
    if {[info exists MODULE_MAP($moduleKey)]} {
        unset -nocomplain KEY_MAP($MODULE_MAP($moduleKey))
        unset -nocomplain MODULE_MAP($moduleKey)
        unset -nocomplain ENABLED_MAP($moduleKey)
    }
    ::HWShortcut::saveConfig
    catch {hm_usermessage [::HWFlow::txt "自定义功能已立即停用。如果该快捷键覆盖了 HyperMesh 原有功能，请重启 HyperMesh 以恢复原功能。" "The custom action is disabled. Restart HyperMesh if the shortcut replaced a native HyperMesh command."]}
    ::HWToolkit::refreshShortcutDisplays
    ::HWShortcut::refreshManager
}

proc ::HWShortcut::clearAllBindings {} {
    ::HWShortcut::clearMemory
    ::HWShortcut::saveConfig
    ::HWToolkit::refreshShortcutDisplays
    ::HWShortcut::refreshManager
}

proc ::HWShortcut::loaderBlock {} {
    variable MARK_START
    variable MARK_END
    set bootstrap [file normalize [::HWShortcut::getBootstrapFile]]
    set lines {}
    lappend lines $MARK_START
    lappend lines [list set hmworkflowBootstrap $bootstrap]
    lappend lines {if {[file exists $hmworkflowBootstrap]} {
    if {[catch {
        source $hmworkflowBootstrap
    } hmworkflowShortcutError]} {
        puts "HMWorkFlow shortcut initialization failed:"
        puts $hmworkflowShortcutError
    }
}}
    lappend lines $MARK_END
    return [join $lines "\n"]
}

proc ::HWShortcut::readFileSafe {file} {
    if {![file exists $file]} { return "" }
    set ch [open $file r]
    set data [read $ch]
    close $ch
    return $data
}

proc ::HWShortcut::writeFileSafe {file text} {
    set dir [file dirname $file]
    if {![file exists $dir]} { file mkdir $dir }
    set tmp "${file}.tmp"
    set ch [open $tmp w]
    puts -nonewline $ch $text
    close $ch
    file rename -force $tmp $file
}

proc ::HWShortcut::removeLoaderBlockText {text} {
    variable MARK_START
    variable MARK_END
    set start [string first $MARK_START $text]
    if {$start < 0} { return $text }
    set end [string first $MARK_END $text $start]
    if {$end < 0} { return $text }
    set end [expr {$end + [string length $MARK_END]}]
    set before [string range $text 0 [expr {$start - 1}]]
    set after [string range $text [expr {$end + 1}] end]
    set result [string trimright $before]
    if {[string trim $result] ne "" && [string trim $after] ne ""} {
        append result "\n"
    }
    append result [string trimleft $after]
    return $result
}

proc ::HWShortcut::installAutoLoader {} {
    set hmcustom [::HWShortcut::getHmcustomFile]
    set text [::HWShortcut::readFileSafe $hmcustom]
    set text [::HWShortcut::removeLoaderBlockText $text]
    if {[string trim $text] ne ""} {
        append text "\n\n"
    }
    append text [::HWShortcut::loaderBlock] "\n"
    ::HWShortcut::writeFileSafe $hmcustom $text
    ::HWShortcut::refreshManager
    return 1
}

proc ::HWShortcut::removeAutoLoader {} {
    set hmcustom [::HWShortcut::getHmcustomFile]
    set text [::HWShortcut::readFileSafe $hmcustom]
    set text [::HWShortcut::removeLoaderBlockText $text]
    ::HWShortcut::writeFileSafe $hmcustom $text
    ::HWShortcut::refreshManager
    return 1
}

proc ::HWShortcut::repairAutoLoader {} {
    return [::HWShortcut::installAutoLoader]
}

proc ::HWShortcut::getAutoLoaderInfo {} {
    variable MARK_START
    variable MARK_END
    set hmcustom [::HWShortcut::getHmcustomFile]
    set expected [file normalize [::HWShortcut::getBootstrapFile]]
    if {![file exists $hmcustom]} {
        return [list status disabled path "" expected $expected hmcustom $hmcustom]
    }
    set text [::HWShortcut::readFileSafe $hmcustom]
    set start [string first $MARK_START $text]
    set end [string first $MARK_END $text]
    if {$start < 0 || $end < $start} {
        return [list status disabled path "" expected $expected hmcustom $hmcustom]
    }
    set block [string range $text $start $end]
    set path ""
    foreach line [split $block "\n"] {
        if {[catch {set fields [lrange $line 0 end]}]} {
            continue
        }
        if {[llength $fields] >= 3 && [lindex $fields 0] eq "set" && [lindex $fields 1] eq "hmworkflowBootstrap"} {
            set path [lindex $fields 2]
            break
        }
    }
    if {$path eq ""} {
        return [list status invalid path "" expected $expected hmcustom $hmcustom]
    }
    set normalizedPath [file normalize $path]
    if {![file exists $normalizedPath]} {
        return [list status path_invalid path $normalizedPath expected $expected hmcustom $hmcustom]
    }
    if {$normalizedPath ne $expected} {
        return [list status path_mismatch path $normalizedPath expected $expected hmcustom $hmcustom]
    }
    return [list status enabled path $normalizedPath expected $expected hmcustom $hmcustom]
}

proc ::HWShortcut::getAutoLoaderStatusValue {} {
    set info [::HWShortcut::getAutoLoaderInfo]
    return [dict get $info status]
}

proc ::HWShortcut::getAutoLoaderStatus {} {
    set status [::HWShortcut::getAutoLoaderStatusValue]
    switch -- $status {
        enabled { return [::HWFlow::txt "已启用" "Enabled"] }
        path_invalid { return [::HWFlow::txt "路径失效" "Invalid path"] }
        path_mismatch { return [::HWFlow::txt "路径失效" "Invalid path"] }
        invalid { return [::HWFlow::txt "路径失效" "Invalid path"] }
    }
    return [::HWFlow::txt "未启用" "Disabled"]
}

proc ::HWShortcut::captureShortcut {} {
    variable CAPTURED_SHORTCUT
    set CAPTURED_SHORTCUT ""
    catch {destroy .hwshortcut_capture}
    set w .hwshortcut_capture
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::txt "录入快捷键" "Capture Shortcut"]
    label $w.msg -text [::HWFlow::txt "请按下需要绑定的快捷键" "Press the shortcut to bind"] -font [::HWFlow::uiFont heading] -padx 18 -pady 18
    pack $w.msg -fill both -expand 1
    bind $w <KeyPress> {
        set ::HWShortcut::CAPTURED_SHORTCUT [::HWShortcut::shortcutFromEvent %K %s]
        if {$::HWShortcut::CAPTURED_SHORTCUT ne ""} {
            destroy .hwshortcut_capture
        }
    }
    bind $w <Escape> {set ::HWShortcut::CAPTURED_SHORTCUT ""; destroy .hwshortcut_capture}
    focus -force $w
    tkwait window $w
    return $CAPTURED_SHORTCUT
}

proc ::HWShortcut::selectedModule {} {
    variable ROW_MODULE
    variable SELECTED_MODULE
    set w .hwshortcut_manager
    if {[winfo exists $w.list]} {
        set sel [$w.list curselection]
        if {[llength $sel] > 0 && [info exists ROW_MODULE([lindex $sel 0])]} {
            set SELECTED_MODULE $ROW_MODULE([lindex $sel 0])
        }
    }
    return $SELECTED_MODULE
}

proc ::HWShortcut::refreshManager {} {
    variable ROW_MODULE
    variable SELECTED_MODULE
    set w .hwshortcut_manager
    if {![winfo exists $w]} { return }
    $w.list delete 0 end
    catch {array unset ROW_MODULE}
    set row 0
    foreach moduleKey [::HWToolkit::visibleModuleKeys] {
        set shortcut [::HWShortcut::moduleShortcut $moduleKey]
        if {$shortcut eq ""} {
            set shortcut [::HWFlow::txt "未绑定" "Unbound"]
            set status [::HWFlow::txt "未启用" "Disabled"]
        } else {
            set status [::HWFlow::txt "已启用" "Enabled"]
        }
        set line [format "%-12s  %-24s  %-20s  %s" [::HWShortcut::moduleGroup $moduleKey] [::HWShortcut::moduleLabel $moduleKey] $shortcut $status]
        $w.list insert end $line
        set ROW_MODULE($row) $moduleKey
        if {$moduleKey eq $SELECTED_MODULE} {
            $w.list selection clear 0 end
            $w.list selection set $row
            $w.list see $row
        }
        incr row
    }
    set info [::HWShortcut::getAutoLoaderInfo]
    catch {$w.status configure -text [::HWFlow::txt "自动加载状态：[::HWShortcut::getAutoLoaderStatus]\n用户配置路径：[::HWShortcut::getConfigFile]\n启动加载路径：[dict get $info path]" "Auto-load status: [::HWShortcut::getAutoLoaderStatus]\nUser config: [::HWShortcut::getConfigFile]\nBootstrap path: [dict get $info path]"]}
}

proc ::HWShortcut::managerApply {} {
    variable CAPTURED_SHORTCUT
    set moduleKey [::HWShortcut::selectedModule]
    if {$moduleKey eq ""} { return }
    if {$CAPTURED_SHORTCUT eq ""} {
        set CAPTURED_SHORTCUT [::HWShortcut::captureShortcut]
    }
    if {$CAPTURED_SHORTCUT eq ""} { return }
    if {[catch {::HWShortcut::applyBinding $moduleKey $CAPTURED_SHORTCUT} err]} {
        tk_messageBox -icon warning -title [::HWFlow::txt "快捷键管理" "Shortcuts"] -message $err
    } else {
        set CAPTURED_SHORTCUT ""
        if {[winfo exists .hwshortcut_manager.pending]} {
            .hwshortcut_manager.pending configure -text [::HWFlow::txt "待应用快捷键：无" "Pending shortcut: none"]
        }
    }
}

proc ::HWShortcut::managerCapture {} {
    variable CAPTURED_SHORTCUT
    set CAPTURED_SHORTCUT [::HWShortcut::captureShortcut]
    set w .hwshortcut_manager
    if {[winfo exists $w.pending]} {
        set text [::HWFlow::txt "待应用快捷键：$CAPTURED_SHORTCUT" "Pending shortcut: $CAPTURED_SHORTCUT"]
        if {$CAPTURED_SHORTCUT eq ""} {
            set text [::HWFlow::txt "待应用快捷键：无" "Pending shortcut: none"]
        }
        $w.pending configure -text $text
    }
}

proc ::HWShortcut::managerClear {} {
    set moduleKey [::HWShortcut::selectedModule]
    if {$moduleKey eq ""} { return }
    ::HWShortcut::clearBinding $moduleKey
}

proc ::HWShortcut::showForModule {moduleKey} {
    variable SELECTED_MODULE
    set SELECTED_MODULE $moduleKey
    ::HWShortcut::showManager
}

proc ::HWShortcut::showManager {} {
    variable SELECTED_MODULE
    ::HWShortcut::initialize
    catch {destroy .hwshortcut_manager}
    set w .hwshortcut_manager
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::txt "快捷键管理" "Shortcuts"]
    wm resizable $w 1 1

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1
    label $w.main.title -text [::HWFlow::txt "快捷键管理" "Shortcuts"] -font [::HWFlow::uiFont heading]
    pack $w.main.title -anchor w -pady {0 8}
    label $w.main.header -text [format "%-12s  %-24s  %-20s  %s" [::HWFlow::txt "分组" "Group"] [::HWFlow::txt "模块名称" "Module"] [::HWFlow::txt "当前快捷键" "Shortcut"] [::HWFlow::txt "启用状态" "Status"]] -font [::HWFlow::uiFont default] -anchor w
    pack $w.main.header -fill x
    listbox $w.list -width 84 -height 10 -font [::HWFlow::uiFont fixed] -exportselection 0
    pack $w.list -fill both -expand 1 -padx 12
    bind $w.list <<ListboxSelect>> {::HWShortcut::selectedModule}

    label $w.status -text "" -justify left -anchor w -padx 12 -pady 8
    pack $w.status -fill x
    label $w.pending -text [::HWFlow::txt "待应用快捷键：无" "Pending shortcut: none"] -anchor w -padx 12
    pack $w.pending -fill x

    frame $w.actions -padx 12 -pady 4
    pack $w.actions -fill x
    button $w.actions.capture -text [::HWFlow::txt "录入快捷键" "Capture"] -width 12 -command "::HWShortcut::managerCapture"
    button $w.actions.apply -text [::HWFlow::txt "应用绑定" "Apply"] -width 12 -command "::HWShortcut::managerApply"
    button $w.actions.clear -text [::HWFlow::txt "清除绑定" "Clear"] -width 12 -command "::HWShortcut::managerClear"
    button $w.actions.clearall -text [::HWFlow::txt "清除全部" "Clear All"] -width 12 -command "::HWShortcut::clearAllBindings"
    button $w.actions.refresh -text [::HWFlow::txt "刷新" "Refresh"] -width 10 -command "::HWShortcut::refreshManager"
    pack $w.actions.capture $w.actions.apply $w.actions.clear $w.actions.clearall $w.actions.refresh -side left -padx {0 6}

    frame $w.persist -padx 12 -pady 4
    pack $w.persist -fill x
    button $w.persist.enable -text [::HWFlow::txt "启用持久化" "Enable Restore"] -width 14 -command "::HWShortcut::installAutoLoader"
    button $w.persist.repair -text [::HWFlow::txt "修复自动加载" "Repair Loader"] -width 14 -command "::HWShortcut::repairAutoLoader"
    button $w.persist.disable -text [::HWFlow::txt "禁用自动加载" "Disable Loader"] -width 14 -command "::HWShortcut::removeAutoLoader"
    button $w.persist.close -text [::HWFlow::txt "关闭" "Close"] -width 10 -command "destroy .hwshortcut_manager"
    pack $w.persist.enable $w.persist.repair $w.persist.disable -side left -padx {0 6}
    pack $w.persist.close -side right
    bind $w <Escape> "destroy .hwshortcut_manager"
    ::HWShortcut::refreshManager
}
