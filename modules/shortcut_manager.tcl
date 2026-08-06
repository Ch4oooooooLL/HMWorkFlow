# ============================================================================
# HMWorkFlow Shortcut Manager
# HyperMesh 2019 Tcl/Tk
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source -encoding utf-8 [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
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
    variable MAIN_SHORTCUT ""
    variable MAIN_ENABLED 0
    variable SETUP_SHORTCUT "Control-Shift-W"
    variable SETUP_RESULT ""
    variable MARK_START "# >>> HMWorkFlow shortcut loader >>>"
    variable MARK_END "# <<< HMWorkFlow shortcut loader <<<"
    variable LAST_REGISTRATION_RESULT [dict create registered 0 errors {}]
    variable STARTUP_AFTER_ID ""
    variable STARTUP_ATTEMPTS 0
    variable STARTUP_MAX_ATTEMPTS 240
    variable STARTUP_RETRY_MS 250
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

proc ::HWShortcut::getLocalStateDir {} {
    if {[info exists ::env(LOCALAPPDATA)] && $::env(LOCALAPPDATA) ne ""} {
        set dir [file join $::env(LOCALAPPDATA) HMWorkFlow]
    } elseif {[info exists ::env(APPDATA)] && $::env(APPDATA) ne ""} {
        set dir [file join $::env(APPDATA) HMWorkFlow local]
    } else {
        set dir [file join [file normalize "~"] .hmworkflow local]
    }
    if {![file exists $dir]} { file mkdir $dir }
    return $dir
}

proc ::HWShortcut::getStartupHeartbeatFile {} {
    return [file join [::HWShortcut::getLocalStateDir] startup_heartbeat.json]
}

proc ::HWShortcut::jsonString {value} {
    set escaped [string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $value]
    return "\"$escaped\""
}

proc ::HWShortcut::writeStartupHeartbeat {registrationResult} {
    set errors {}
    if {[dict exists $registrationResult errors]} {
        foreach value [dict get $registrationResult errors] {
            lappend errors [::HWShortcut::jsonString $value]
        }
    }
    set registered 0
    if {[dict exists $registrationResult registered]} {
        set registered [dict get $registrationResult registered]
    }
    set path [::HWShortcut::getStartupHeartbeatFile]
    set json "{\n"
    append json "  \"schema_version\": \"1.0\",\n"
    append json "  \"timestamp_utc\": [::HWShortcut::jsonString [clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}]],\n"
    append json "  \"hm_pid\": [pid],\n"
    append json "  \"project_root\": [::HWShortcut::jsonString [file normalize [::HWShortcut::projectRoot]]],\n"
    append json "  \"bootstrap_path\": [::HWShortcut::jsonString [file normalize [::HWShortcut::getBootstrapFile]]],\n"
    append json "  \"native_api\": [::HWShortcut::jsonString [::HWShortcut::nativeKeyApi]],\n"
    append json "  \"registered_shortcuts\": $registered,\n"
    append json "  \"errors\": \[[join $errors ,]\]\n"
    append json "}\n"
    ::HWShortcut::writeFileSafe $path $json
    return $path
}

proc ::HWShortcut::getStartupHeartbeatInfo {} {
    set path [::HWShortcut::getStartupHeartbeatFile]
    if {![file isfile $path]} {
        return [dict create status missing path $path]
    }
    set text [::HWShortcut::readFileSafe $path]
    if {![regexp {"hm_pid"\s*:\s*([0-9]+)} $text -> heartbeatPid] ||
        ![regexp {"project_root"\s*:\s*"([^"]*)"} $text -> heartbeatRoot] ||
        ![regexp {"timestamp_utc"\s*:\s*"([^"]*)"} $text -> timestamp]} {
        return [dict create status invalid path $path]
    }
    set expected [file normalize [::HWShortcut::projectRoot]]
    if {[catch {set heartbeatRoot [file normalize $heartbeatRoot]}] || $heartbeatRoot ne $expected} {
        return [dict create status path_mismatch path $path timestamp $timestamp pid $heartbeatPid]
    }
    if {$heartbeatPid != [pid]} {
        return [dict create status previous_session path $path timestamp $timestamp pid $heartbeatPid]
    }
    return [dict create status verified path $path timestamp $timestamp pid $heartbeatPid]
}

proc ::HWShortcut::getStartupHeartbeatStatus {} {
    set status [dict get [::HWShortcut::getStartupHeartbeatInfo] status]
    switch -- $status {
        verified { return [::HWFlow::txt "本次启动已验证" "Verified this startup"] }
        previous_session { return [::HWFlow::txt "仅有上次启动记录" "Previous startup only"] }
        path_mismatch { return [::HWFlow::txt "启动记录路径不匹配" "Startup path mismatch"] }
        invalid { return [::HWFlow::txt "启动记录损坏" "Invalid startup record"] }
    }
    return [::HWFlow::txt "本次启动未验证" "Not verified this startup"]
}

proc ::HWShortcut::getBootstrapFile {} {
    return [file join [::HWShortcut::projectRoot] shortcut_bootstrap.tcl]
}

proc ::HWShortcut::getHmcustomFile {} {
    return [file join [file normalize "~"] hmcustom.tcl]
}

# HyperMesh 2019 keeps the user-facing Key Commands table in the framework
# settings arrays.  Going through this wrapper is important: the global
# hm_registerkeyproc registers only for the current context, whereas the
# framework variant also updates the native key-command library that is saved
# into hmsettings.tcl on normal HyperMesh exit.
proc ::HWShortcut::nativeKeyApi {} {
    if {[llength [info commands ::HM_Framework::hm_registerkeyproc]] > 0} {
        return ::HM_Framework::hm_registerkeyproc
    }
    if {[llength [info commands hm_registerkeyproc]] > 0} {
        return hm_registerkeyproc
    }
    return ""
}

proc ::HWShortcut::nativeLibraryStatus {} {
    if {[llength [info commands ::HM_Framework::hm_registerkeyproc]] > 0} {
        return [::HWFlow::txt "HyperMesh 原生快捷键库" "HyperMesh native key library"]
    }
    if {[llength [info commands hm_registerkeyproc]] > 0} {
        return [::HWFlow::txt "当前会话回退模式" "Session fallback mode"]
    }
    return [::HWFlow::txt "不可用" "Unavailable"]
}

# HyperWorks 2022 reads hmcustom.tcl before its modeling context has finished
# creating hm_registerkeyproc.  A one-shot registration from hmcustom.tcl
# therefore fails even though the same installer works when sourced manually
# after startup.  Keep the 2019 fast path, but let the startup loader wait for
# the native API instead of requiring the user to source install_update.tcl
# once per HyperWorks process.
proc ::HWShortcut::startupRegistrationReady {} {
    return [expr {[::HWShortcut::nativeKeyApi] ne ""}]
}

proc ::HWShortcut::isContextManagedGeneration {} {
    if {[llength [info commands ::HWFlow::hyperWorksYear]] == 0} { return 0 }
    if {[catch {set year [::HWFlow::hyperWorksYear]}]} { return 0 }
    return [expr {$year ne "" && $year >= 2022}]
}

proc ::HWShortcut::contextKeysChanged {args} {
    variable LAST_REGISTRATION_RESULT
    if {![::HWShortcut::startupRegistrationReady]} { return }
    # HyperWorks 2022 documents hm_registerkeyproc as context-bound.  Register
    # directly from the execution-trace callback, matching Altair's own 2022
    # Weld Certification integration, rather than postponing it past setkeys.
    ::HWShortcut::loadConfig
    set LAST_REGISTRATION_RESULT [::HWShortcut::registerAll]
}

proc ::HWShortcut::installContextKeyHooks {} {
    if {![::HWShortcut::isContextManagedGeneration]} { return }
    foreach command {::HM_Framework::p_RegisterKeys ::hm::context::ContextBase::setkeys} {
        if {[llength [info commands $command]] == 0} { continue }
        catch {trace remove execution $command leave ::HWShortcut::contextKeysChanged}
        catch {trace add execution $command leave ::HWShortcut::contextKeysChanged}
    }
}

proc ::HWShortcut::attemptStartupInitialization {} {
    variable STARTUP_AFTER_ID
    variable STARTUP_ATTEMPTS
    variable STARTUP_MAX_ATTEMPTS
    variable STARTUP_RETRY_MS
    set STARTUP_AFTER_ID ""

    if {[::HWShortcut::startupRegistrationReady]} {
        ::HWShortcut::initialize startup
        ::HWShortcut::installContextKeyHooks
        return 1
    }

    incr STARTUP_ATTEMPTS
    if {$STARTUP_ATTEMPTS >= $STARTUP_MAX_ATTEMPTS} {
        # Preserve the existing diagnostic heartbeat if the host never exposes
        # a keyboard API (for example, a non-interactive HyperMesh process).
        ::HWShortcut::initialize startup
        ::HWShortcut::log "startup shortcut API was not ready after [expr {$STARTUP_ATTEMPTS * $STARTUP_RETRY_MS}] ms"
        return 0
    }
    set STARTUP_AFTER_ID [after $STARTUP_RETRY_MS ::HWShortcut::attemptStartupInitialization]
    return 0
}

proc ::HWShortcut::startStartupInitialization {} {
    variable STARTUP_AFTER_ID
    variable STARTUP_ATTEMPTS
    if {$STARTUP_AFTER_ID ne ""} { return 0 }
    set STARTUP_ATTEMPTS 0
    return [::HWShortcut::attemptStartupInitialization]
}

proc ::HWShortcut::moduleExistsVisible {moduleKey} {
    if {![namespace exists ::HWToolkit]} { return 0 }
    variable ::HWToolkit::MODULES
    return [dict exists $::HWToolkit::MODULES $moduleKey]
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
    variable MAIN_SHORTCUT
    variable MAIN_ENABLED
    variable CONFIG_LOADED
    ::HWShortcut::clearMemory
    set MAIN_SHORTCUT ""
    set MAIN_ENABLED 0
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
        if {$moduleKey eq "__toolkit_home__"} {
            set valid [::HWShortcut::validateShortcut $shortcut]
            if {![lindex $valid 0]} {
                ::HWShortcut::log "skip invalid main shortcut $shortcut: [lindex $valid 1]"
                continue
            }
            set MAIN_SHORTCUT $shortcut
            set MAIN_ENABLED [expr {$enabled ? 1 : 0}]
            continue
        }
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
    variable MAIN_SHORTCUT
    variable MAIN_ENABLED
    if {[catch {set file [::HWShortcut::getConfigFile]} err]} {
        error [::HWFlow::txt "无法定位快捷键配置路径：$err" "Cannot resolve shortcut config path: $err"]
    }
    set tmp "${file}.tmp"
    if {[catch {set ch [open $tmp w]} err]} {
        error [::HWFlow::txt "无法写入快捷键配置：$err" "Cannot write shortcut config: $err"]
    }
    puts $ch "# HMWorkFlow shortcut configuration v2"
    if {$MAIN_SHORTCUT ne ""} {
        puts $ch [list __toolkit_home__ $MAIN_SHORTCUT $MAIN_ENABLED]
    }
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

proc ::HWShortcut::shortcutAliases {shortcut} {
    set shortcut [::HWShortcut::normalizeShortcut $shortcut]
    set parts [split $shortcut "-"]
    set key [lindex $parts end]
    set hasShift [expr {[lsearch -exact $parts Shift] >= 0}]
    if {!$hasShift && [string length $key] == 1 && [string is alpha $key]} {
        set prefix [join [lrange $parts 0 end-1] "-"]
        if {$prefix ne ""} { append prefix "-" }
        return [list "${prefix}[string tolower $key]" "${prefix}[string toupper $key]"]
    }
    return [list $shortcut]
}

proc ::HWShortcut::nativeRegister {shortcut command} {
    set api [::HWShortcut::nativeKeyApi]
    if {$api eq ""} {
        error [::HWFlow::txt "当前 HyperMesh 会话没有可用的快捷键注册接口。" "No keyboard registration API is available in this HyperMesh session."]
    }
    foreach alias [::HWShortcut::shortcutAliases $shortcut] {
        if {[catch {uplevel #0 [list $api $alias {} $command]} err]} {
            error "[::HWFlow::txt "注册快捷键 $alias 失败" "Failed to register shortcut $alias"]: $err"
        }
    }
    return 1
}

proc ::HWShortcut::clearNativeBinding {shortcut} {
    if {$shortcut eq ""} { return 1 }
    return [::HWShortcut::nativeRegister $shortcut ""]
}

proc ::HWShortcut::registerBinding {shortcut moduleKey} {
    set script [list ::HWShortcut::dispatch $shortcut]
    if {[catch {::HWShortcut::nativeRegister $shortcut $script} err]} {
        ::HWShortcut::log "native shortcut registration failed for $shortcut: $err"
        return 0
    }
    return 1
}

proc ::HWShortcut::registerMainBinding {} {
    variable MAIN_SHORTCUT
    variable MAIN_ENABLED
    if {!$MAIN_ENABLED || $MAIN_SHORTCUT eq ""} { return 1 }
    if {[catch {::HWShortcut::nativeRegister $MAIN_SHORTCUT ::HWToolkit::requestShortcutHome} err]} {
        ::HWShortcut::log "native main-panel registration failed for $MAIN_SHORTCUT: $err"
        return 0
    }
    return 1
}

proc ::HWShortcut::registerAll {} {
    variable KEY_MAP
    set registered 0
    set errors {}
    if {[::HWShortcut::mainShortcutConfigured]} {
        if {[::HWShortcut::registerMainBinding]} {
            incr registered
        } else {
            lappend errors "main shortcut registration failed"
        }
    }
    foreach shortcut [array names KEY_MAP] {
        if {[::HWShortcut::registerBinding $shortcut $KEY_MAP($shortcut)]} {
            incr registered
        } else {
            lappend errors "shortcut registration failed: $shortcut"
        }
    }
    return [dict create registered $registered errors $errors]
}

proc ::HWShortcut::initialize {{mode manual}} {
    variable INITIALIZED
    variable LAST_REGISTRATION_RESULT
    if {!$INITIALIZED} {
        set INITIALIZED 1
    }
    ::HWShortcut::loadConfig
    set LAST_REGISTRATION_RESULT [::HWShortcut::registerAll]
    if {$mode eq "startup"} {
        ::HWShortcut::writeStartupHeartbeat $LAST_REGISTRATION_RESULT
    }
    return 1
}

proc ::HWShortcut::dispatch {shortcut} {
    variable KEY_MAP
    set shortcut [::HWShortcut::normalizeShortcut $shortcut]
    if {![info exists KEY_MAP($shortcut)]} { return }
    ::HWToolkit::requestShortcutModule $KEY_MAP($shortcut)
}

proc ::HWShortcut::mainShortcut {} {
    variable MAIN_SHORTCUT
    variable MAIN_ENABLED
    if {$MAIN_ENABLED} { return $MAIN_SHORTCUT }
    return ""
}

proc ::HWShortcut::mainShortcutConfigured {} {
    return [expr {[::HWShortcut::mainShortcut] ne ""}]
}

proc ::HWShortcut::applyMainBinding {shortcut} {
    variable MAIN_SHORTCUT
    variable MAIN_ENABLED
    variable KEY_MAP
    set shortcut [::HWShortcut::normalizeShortcut $shortcut]
    set valid [::HWShortcut::validateShortcut $shortcut]
    if {![lindex $valid 0]} { error [lindex $valid 1] }
    if {[info exists KEY_MAP($shortcut)]} {
        error [::HWFlow::txt "该快捷键已被 [::HWShortcut::moduleLabel $KEY_MAP($shortcut)] 使用。" "This shortcut is already used by [::HWShortcut::moduleLabel $KEY_MAP($shortcut)]."]
    }
    set previous $MAIN_SHORTCUT
    if {$previous ne "" && $previous ne $shortcut} {
        ::HWShortcut::clearNativeBinding $previous
    }
    if {[catch {::HWShortcut::nativeRegister $shortcut ::HWToolkit::requestShortcutHome} err]} {
        if {$previous ne ""} {
            catch {::HWShortcut::nativeRegister $previous ::HWToolkit::requestShortcutHome}
        }
        error $err
    }
    set MAIN_SHORTCUT $shortcut
    set MAIN_ENABLED 1
    ::HWShortcut::saveConfig
    ::HWShortcut::refreshManager
    return 1
}

proc ::HWShortcut::clearMainBinding {} {
    variable MAIN_SHORTCUT
    variable MAIN_ENABLED
    if {$MAIN_SHORTCUT ne ""} {
        ::HWShortcut::clearNativeBinding $MAIN_SHORTCUT
    }
    set MAIN_SHORTCUT ""
    set MAIN_ENABLED 0
    ::HWShortcut::saveConfig
    ::HWShortcut::refreshManager
    return 1
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
    if {[::HWShortcut::mainShortcut] eq $shortcut} {
        error [::HWFlow::txt "该快捷键已用于打开主面板。" "This shortcut is already used to open the main panel."]
    }
    set previous ""
    if {[info exists MODULE_MAP($moduleKey)]} {
        set previous $MODULE_MAP($moduleKey)
        unset -nocomplain KEY_MAP($previous)
    }
    if {$previous ne "" && $previous ne $shortcut} {
        ::HWShortcut::clearNativeBinding $previous
    }
    set MODULE_MAP($moduleKey) $shortcut
    set ENABLED_MAP($moduleKey) 1
    set KEY_MAP($shortcut) $moduleKey
    if {![::HWShortcut::registerBinding $shortcut $moduleKey]} {
        unset -nocomplain KEY_MAP($shortcut)
        if {$previous ne ""} {
            set MODULE_MAP($moduleKey) $previous
            set ENABLED_MAP($moduleKey) 1
            set KEY_MAP($previous) $moduleKey
            catch {::HWShortcut::registerBinding $previous $moduleKey}
        } else {
            unset -nocomplain MODULE_MAP($moduleKey)
            unset -nocomplain ENABLED_MAP($moduleKey)
        }
        error [::HWFlow::txt "无法将快捷键写入 HyperMesh 原生快捷键库。" "Could not write the shortcut to the HyperMesh native key library."]
    }
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
        set shortcut $MODULE_MAP($moduleKey)
        ::HWShortcut::clearNativeBinding $shortcut
        unset -nocomplain KEY_MAP($shortcut)
        unset -nocomplain MODULE_MAP($moduleKey)
        unset -nocomplain ENABLED_MAP($moduleKey)
    }
    ::HWShortcut::saveConfig
    catch {hm_usermessage [::HWFlow::txt "自定义功能已立即停用。如果该快捷键覆盖了 HyperMesh 原有功能，请重启 HyperMesh 以恢复原功能。" "The custom action is disabled. Restart HyperMesh if the shortcut replaced a native HyperMesh command."]}
    ::HWToolkit::refreshShortcutDisplays
    ::HWShortcut::refreshManager
}

proc ::HWShortcut::clearAllBindings {} {
    variable MODULE_MAP
    foreach moduleKey [array names MODULE_MAP] {
        catch {::HWShortcut::clearNativeBinding $MODULE_MAP($moduleKey)}
    }
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
        source -encoding utf-8 $hmworkflowBootstrap
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
    wm title $w [::HWFlow::windowTitle [::HWFlow::txt "录入快捷键" "Capture Shortcut"] "Capture Shortcut"]
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

proc ::HWShortcut::setupCaptureMainShortcut {} {
    variable SETUP_SHORTCUT
    set captured [::HWShortcut::captureShortcut]
    if {$captured ne ""} { set SETUP_SHORTCUT $captured }
}

proc ::HWShortcut::setupUseRecommendedMainShortcut {} {
    variable SETUP_SHORTCUT
    set SETUP_SHORTCUT "Control-Shift-W"
}

proc ::HWShortcut::setupApplyMainShortcut {} {
    variable SETUP_SHORTCUT
    variable SETUP_RESULT
    if {[catch {::HWShortcut::applyMainBinding $SETUP_SHORTCUT} err]} {
        tk_messageBox -icon warning -title [::HWFlow::txt "主面板快捷键" "Main Panel Shortcut"] -message $err
        return
    }
    set SETUP_RESULT applied
    catch {destroy .hwshortcut_setup}
}

proc ::HWShortcut::setupCancel {} {
    variable SETUP_RESULT
    set SETUP_RESULT cancelled
    catch {destroy .hwshortcut_setup}
}

proc ::HWShortcut::showInitialSetup {} {
    variable SETUP_SHORTCUT
    variable SETUP_RESULT
    if {[::HWShortcut::mainShortcutConfigured]} { return 1 }
    catch {destroy .hwshortcut_setup}
    set SETUP_SHORTCUT "Control-Shift-W"
    set SETUP_RESULT cancelled
    set w .hwshortcut_setup
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::windowTitle [::HWFlow::txt "HMWorkFlow 初始安装" "HMWorkFlow Initial Setup"] "HMWorkFlow Initial Setup"]
    wm resizable $w 0 0

    frame $w.main -padx 16 -pady 14
    pack $w.main -fill both -expand 1
    label $w.main.title -text [::HWFlow::txt "设置主面板快捷键" "Set Main Panel Shortcut"] -font [::HWFlow::uiFont header] -anchor w
    label $w.main.desc -text [::HWFlow::txt "此绑定会写入 HyperMesh 原生快捷键库。之后请在主面板的“快捷键管理”中设置各模块快捷键。" "This binding is written to the HyperMesh native key library. Configure module shortcuts later from the main panel's Shortcuts page."] -justify left -wraplength 440 -anchor w
    pack $w.main.title -fill x -pady {0 6}
    pack $w.main.desc -fill x -pady {0 12}

    labelframe $w.main.key -text [::HWFlow::txt "主面板 / Main panel" "Main panel"] -padx 10 -pady 10
    pack $w.main.key -fill x
    entry $w.main.key.value -textvariable ::HWShortcut::SETUP_SHORTCUT -width 30 -font [::HWFlow::uiFont fixed]
    button $w.main.key.capture -text [::HWFlow::txt "录入按键" "Capture"] -width 12 -command ::HWShortcut::setupCaptureMainShortcut
    button $w.main.key.recommended -text [::HWFlow::txt "推荐 Ctrl+Shift+W" "Use Ctrl+Shift+W"] -width 18 -command ::HWShortcut::setupUseRecommendedMainShortcut
    pack $w.main.key.value -side left -fill x -expand 1 -padx {0 8}
    pack $w.main.key.capture -side left -padx {0 6}
    pack $w.main.key.recommended -side left

    label $w.main.note -text [::HWFlow::txt "避免使用 Ctrl+S、Ctrl+O、Ctrl+Z 等 HyperMesh 常用原生快捷键。" "Avoid common HyperMesh native shortcuts such as Ctrl+S, Ctrl+O, and Ctrl+Z."] -font [::HWFlow::uiFont small] -justify left -anchor w
    pack $w.main.note -fill x -pady {8 12}
    frame $w.main.actions
    pack $w.main.actions -fill x
    button $w.main.actions.cancel -text [::HWFlow::txt "稍后设置" "Set Later"] -width 12 -command ::HWShortcut::setupCancel
    button $w.main.actions.ok -text [::HWFlow::txt "写入原生快捷键库" "Save to Native Library"] -width 20 -command ::HWShortcut::setupApplyMainShortcut
    pack $w.main.actions.cancel -side right
    pack $w.main.actions.ok -side right -padx {0 8}

    bind $w <Escape> ::HWShortcut::setupCancel
    focus -force $w.main.key.value
    tkwait window $w
    return [expr {$SETUP_RESULT eq "applied"}]
}

proc ::HWShortcut::managerSetMainShortcut {} {
    set captured [::HWShortcut::captureShortcut]
    if {$captured eq ""} { return }
    if {[catch {::HWShortcut::applyMainBinding $captured} err]} {
        tk_messageBox -icon warning -title [::HWFlow::txt "主面板快捷键" "Main Panel Shortcut"] -message $err
    }
}

proc ::HWShortcut::selectedModule {} {
    variable ROW_MODULE
    variable SELECTED_MODULE
    set w .hwshortcut_manager
    set listbox $w.modules.listframe.list
    if {[winfo exists $listbox]} {
        set sel [$listbox curselection]
        if {[llength $sel] > 0 && [info exists ROW_MODULE([lindex $sel 0])]} {
            set SELECTED_MODULE $ROW_MODULE([lindex $sel 0])
        }
    }
    return $SELECTED_MODULE
}

proc ::HWShortcut::managerModuleKeys {} {
    variable MODULE_MAP
    variable ENABLED_MAP

    # Keep the complete library available for assigning new bindings, while
    # also appending every enabled persisted entry.  The latter makes the
    # manager resilient when an enabled module is currently hidden from the
    # home panel or the module list is refreshed after a toolkit update.
    set keys [::HWToolkit::allModuleKeys]
    foreach moduleKey [array names MODULE_MAP] {
        if {![info exists ENABLED_MAP($moduleKey)] || !$ENABLED_MAP($moduleKey)} {
            continue
        }
        if {[lsearch -exact $keys $moduleKey] < 0} {
            lappend keys $moduleKey
        }
    }
    return $keys
}

proc ::HWShortcut::refreshManager {} {
    variable ROW_MODULE
    variable SELECTED_MODULE
    set w .hwshortcut_manager
    if {![winfo exists $w]} { return }
    if {[winfo exists $w.mainpanel.value]} {
        set mainShortcut [::HWShortcut::mainShortcut]
        if {$mainShortcut eq ""} { set mainShortcut [::HWFlow::txt "未绑定" "Unbound"] }
        $w.mainpanel.value configure -text $mainShortcut
    }
    if {[winfo exists $w.native]} {
        $w.native configure -text [::HWFlow::txt "写入位置： [::HWShortcut::nativeLibraryStatus]" "Binding target: [::HWShortcut::nativeLibraryStatus]"]
    }
    set listbox $w.modules.listframe.list
    if {[winfo exists $listbox]} {
        $listbox delete 0 end
        catch {array unset ROW_MODULE}
        set row 0
        foreach moduleKey [::HWShortcut::managerModuleKeys] {
            set shortcut [::HWShortcut::moduleShortcut $moduleKey]
            if {$shortcut eq ""} {
                set shortcut [::HWFlow::txt "未绑定" "Unbound"]
                set status [::HWFlow::txt "未启用" "Disabled"]
            } else {
                set status [::HWFlow::txt "已启用" "Enabled"]
            }
            set groupCol [::HWFlow::padString [::HWShortcut::moduleGroup $moduleKey] 12]
            set labelCol [::HWFlow::padString [::HWShortcut::moduleLabel $moduleKey] 24]
            set shortcutCol [::HWFlow::padString $shortcut 20]
            set line "$groupCol  $labelCol  $shortcutCol  $status"
            $listbox insert end $line
            set ROW_MODULE($row) $moduleKey
            if {$moduleKey eq $SELECTED_MODULE} {
                $listbox selection clear 0 end
                $listbox selection set $row
                $listbox see $row
            }
            incr row
        }
    }
    set info [::HWShortcut::getAutoLoaderInfo]
    catch {$w.status configure -text [::HWFlow::txt "安装状态：[::HWShortcut::getAutoLoaderStatus]\n启动验证：[::HWShortcut::getStartupHeartbeatStatus]\n用户配置路径：[::HWShortcut::getConfigFile]\n启动加载路径：[dict get $info path]" "Installed: [::HWShortcut::getAutoLoaderStatus]\nStartup verification: [::HWShortcut::getStartupHeartbeatStatus]\nUser config: [::HWShortcut::getConfigFile]\nBootstrap path: [dict get $info path]"]}
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
    wm title $w [::HWFlow::windowTitle [::HWFlow::txt "快捷键管理" "Shortcuts"] "Shortcuts"]
    wm minsize $w 680 420
    wm resizable $w 1 1

    label $w.title -text [::HWFlow::txt "快捷键管理" "Shortcuts"] -font [::HWFlow::uiFont header] -anchor w
    label $w.native -text "" -font [::HWFlow::uiFont small] -anchor w
    pack $w.title -fill x -padx 14 -pady {12 0}
    pack $w.native -fill x -padx 14 -pady {2 10}
    ::HWFlow::bindAutoWrap $w.native 50

    labelframe $w.mainpanel -text [::HWFlow::txt "主入口" "Main entry"] -padx 10 -pady 8
    pack $w.mainpanel -fill x -padx 14 -pady {0 8}
    label $w.mainpanel.caption -text [::HWFlow::txt "打开 HyperMesh Toolkit" "Open HyperMesh Toolkit"] -font [::HWFlow::uiFont heading] -anchor w
    label $w.mainpanel.value -text "" -font [::HWFlow::uiFont fixed] -width 22 -anchor center -relief groove
    button $w.mainpanel.set -text [::HWFlow::txt "设置主面板快捷键" "Set Main Shortcut"] -width 18 -command ::HWShortcut::managerSetMainShortcut
    button $w.mainpanel.clear -text [::HWFlow::txt "清除" "Clear"] -width 8 -command ::HWShortcut::clearMainBinding
    pack $w.mainpanel.caption -side left -fill x -expand 1
    pack $w.mainpanel.clear -side right
    pack $w.mainpanel.set -side right -padx {0 6}
    pack $w.mainpanel.value -side right -padx {0 8}

    labelframe $w.modules -text [::HWFlow::txt "模块快捷键" "Module shortcuts"] -padx 8 -pady 8
    pack $w.modules -fill both -expand 1 -padx 14

    set groupHeader [::HWFlow::padString [::HWFlow::txt "分组" "Group"] 12]
    set labelHeader [::HWFlow::padString [::HWFlow::txt "模块名称" "Module"] 24]
    set shortcutHeader [::HWFlow::padString [::HWFlow::txt "当前快捷键" "Shortcut"] 20]
    set statusHeader [::HWFlow::txt "状态" "Status"]
    set headerText "$groupHeader  $labelHeader  $shortcutHeader  $statusHeader"
    label $w.modules.header -text $headerText -font [::HWFlow::uiFont fixed] -anchor w
    pack $w.modules.header -fill x -pady {0 4}

    frame $w.modules.listframe
    pack $w.modules.listframe -fill both -expand 1
    listbox $w.modules.listframe.list -width 84 -height 10 -font [::HWFlow::uiFont fixed] -exportselection 0 -selectmode browse
    scrollbar $w.modules.listframe.scroll -orient vertical -command [list $w.modules.listframe.list yview]
    $w.modules.listframe.list configure -yscrollcommand [list $w.modules.listframe.scroll set]
    pack $w.modules.listframe.scroll -side right -fill y
    pack $w.modules.listframe.list -side left -fill both -expand 1
    bind $w.modules.listframe.list <<ListboxSelect>> {::HWShortcut::selectedModule}

    label $w.pending -text [::HWFlow::txt "待应用快捷键：无" "Pending shortcut: none"] -anchor w -padx 14 -pady 7
    pack $w.pending -fill x
    ::HWFlow::bindAutoWrap $w.pending 50

    frame $w.actions -padx 14 -pady 5
    pack $w.actions -fill x
    button $w.actions.capture -text [::HWFlow::txt "录入快捷键" "Capture"] -width 12 -command ::HWShortcut::managerCapture
    button $w.actions.apply -text [::HWFlow::txt "应用绑定" "Apply"] -width 12 -command ::HWShortcut::managerApply
    button $w.actions.clear -text [::HWFlow::txt "清除绑定" "Clear"] -width 12 -command ::HWShortcut::managerClear
    button $w.actions.clearall -text [::HWFlow::txt "清除全部" "Clear All"] -width 12 -command ::HWShortcut::clearAllBindings
    pack $w.actions.capture $w.actions.apply $w.actions.clear $w.actions.clearall -side left -padx {0 6}
    button $w.actions.close -text [::HWFlow::txt "关闭" "Close"] -width 10 -command [list destroy $w]
    pack $w.actions.close -side right

    label $w.status -text "" -justify left -anchor w -font [::HWFlow::uiFont small] -padx 14 -pady 3
    pack $w.status -fill x
    ::HWFlow::bindAutoWrap $w.status 50

    frame $w.persist -padx 14 -pady 6
    pack $w.persist -fill x
    button $w.persist.enable -text [::HWFlow::txt "安装启动加载" "Install Startup Loader"] -width 18 -command ::HWShortcut::installAutoLoader
    button $w.persist.repair -text [::HWFlow::txt "更新启动加载" "Update Loader"] -width 18 -command ::HWShortcut::repairAutoLoader
    button $w.persist.disable -text [::HWFlow::txt "移除启动加载" "Remove Loader"] -width 18 -command ::HWShortcut::removeAutoLoader
    pack $w.persist.enable $w.persist.repair $w.persist.disable -side left -padx {0 6}
    bind $w <Escape> [list destroy $w]
    ::HWShortcut::refreshManager
}
