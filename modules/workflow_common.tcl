# ============================================================================
# Workflow common helpers
# HyperMesh 2019 Tcl/Tk
#
# Shared configuration, naming, assembly and browser utilities for the
# preprocessing workflow modules.
# ============================================================================

namespace eval ::HWFlow {
    variable VERSION "0.2"
    variable ROOT_DIR [file dirname [file dirname [file normalize [info script]]]]
    variable GLOBAL_CONFIG_FILE [file join $ROOT_DIR "config.yaml"]
    variable CONFIG_DIR [file join $ROOT_DIR "config"]
    variable MATERIAL_FILE [file join $CONFIG_DIR "materials.txt"]
    variable CATEGORIES {SHELL SOLID CASTING SOURCE_GEOM SEAM CONNECTOR}
    variable LANGUAGE "zh_CN"
    variable LANGUAGE_LOADED 0
    variable ENGINEERING_CONTEXT {}
    variable ENGINEERING_CONTEXT_LOADED 0
    variable materialRows {}
    variable materialKeys {}
    variable progressWin ".hwflow_progress"
    variable progressMessage ""
    variable progressDetail ""
    variable progressPercentText "0.0%"
    variable progressLastLog ""
    variable progressLogMaxLines 220
    variable progressCancelRequested 0
    variable progressActive 0
    variable progressLastEventPumpMs 0
    variable progressEventPumpActive 0
    variable componentColorSeeded 0
    variable componentColorPalette {
        2 3 4 5 6 8 10 12 13 14 15 16
        17 18 19 20 21 22 23 24 25 26 27 28
        29 30 31 32 33 34 35 36 37 38 39 40
        41 42 43 44 45 46 47 48 49 50 51 52
        53 54 55 56 57 58 59 60 61 62 63 64
    }
    variable FONT_INITIALIZED 0
    variable UI_FONT_FAMILY ""
    variable UI_FIXED_FONT_FAMILY ""
    variable touchedComponents {}
    variable WRAP_TIMERS
    catch {array set WRAP_TIMERS {}}
    variable UI_INITIALIZED 0
    variable UI_BACKEND "tk"
    variable UI_WINDOWS
    catch {array set UI_WINDOWS {}}
}

proc ::HWFlow::globalConfigFile {} {
    variable GLOBAL_CONFIG_FILE
    return $GLOBAL_CONFIG_FILE
}

proc ::HWFlow::defaultGlobalConfigText {} {
    return [join {
        {# HyperMesh Toolkit global configuration}
        {schema_version: 2.0}
        {workflow:}
        {  # 界面语言 / UI language: zh_CN or en_US}
        {  language: zh_CN}
        {project:}
        {  unit_system: mm_N_s_tonne}
        {  solver_profile: OptiStruct}
        {  length_unit: mm}
        {  force_unit: N}
        {  time_unit: s}
        {  mass_unit: tonne}
        {  stress_unit: MPa}
        {  density_unit: tonne_per_mm3}
        {  units_confirmed: false}
    } "\n"]
}

proc ::HWFlow::configScalar {section key fallback} {
    set path [::HWFlow::ensureGlobalConfig]
    set active ""
    foreach rawLine [split [::HWFlow::readTextFile $path] "\n"] {
        set withoutComment [lindex [split $rawLine "#"] 0]
        if {[string trim $withoutComment] eq ""} {continue}
        if {[regexp {^([A-Za-z0-9_.-]+)\s*:\s*$} [string trim $withoutComment] -> name]} {
            set active $name
            continue
        }
        if {$active eq $section && [regexp "^\\s+${key}\\s*:\\s*(.+?)\\s*$" $withoutComment -> value]} {
            return [string trim $value "\"' "]
        }
        if {[regexp "^${section}\\.${key}\\s*:\\s*(.+?)\\s*$" [string trim $withoutComment] -> value]} {
            return [string trim $value "\"' "]
        }
    }
    return $fallback
}

proc ::HWFlow::configBoolean {section key fallback} {
    set value [string tolower [::HWFlow::configScalar $section $key $fallback]]
    return [expr {$value in {1 true yes on}}]
}

proc ::HWFlow::engineeringContext {{refresh 0}} {
    variable ENGINEERING_CONTEXT
    variable ENGINEERING_CONTEXT_LOADED
    if {$ENGINEERING_CONTEXT_LOADED && !$refresh} {return $ENGINEERING_CONTEXT}
    set context [dict create \
        unit_system [::HWFlow::configScalar project unit_system ""] \
        solver_profile [::HWFlow::configScalar project solver_profile ""] \
        length_unit [::HWFlow::configScalar project length_unit ""] \
        force_unit [::HWFlow::configScalar project force_unit ""] \
        time_unit [::HWFlow::configScalar project time_unit ""] \
        mass_unit [::HWFlow::configScalar project mass_unit ""] \
        stress_unit [::HWFlow::configScalar project stress_unit ""] \
        density_unit [::HWFlow::configScalar project density_unit ""] \
        units_confirmed [::HWFlow::configBoolean project units_confirmed false]]
    set ENGINEERING_CONTEXT $context
    set ENGINEERING_CONTEXT_LOADED 1
    return $context
}

proc ::HWFlow::currentSolverContext {} {
    set profile ""
    set template ""
    if {[info exists ::g_profile_name]} {set profile [string trim $::g_profile_name]}
    if {[llength [info commands hm_info]] > 0} {
        catch {set template [string trim [hm_info templatetype]]}
    }
    return [dict create profile $profile template $template]
}

proc ::HWFlow::preflightCheck {name status detail} {
    return [dict create name $name status $status detail $detail]
}

proc ::HWFlow::engineeringPreflight {{refresh 0}} {
    set context [::HWFlow::engineeringContext $refresh]
    set checks {}
    set blocked 0
    set warned 0

    set requiredUnits {unit_system length_unit force_unit time_unit mass_unit stress_unit density_unit}
    set missing {}
    foreach key $requiredUnits {
        if {[string trim [dict get $context $key]] eq ""} {lappend missing $key}
    }
    if {![dict get $context units_confirmed] || [llength $missing] > 0} {
        set blocked 1
        lappend checks [::HWFlow::preflightCheck units BLOCKED "Project units are incomplete or not confirmed: $missing"]
    } else {
        lappend checks [::HWFlow::preflightCheck units PASS "[dict get $context unit_system] ([dict get $context stress_unit], [dict get $context density_unit])"]
    }

    set expected [dict get $context solver_profile]
    set solver [::HWFlow::currentSolverContext]
    set profile [string tolower [dict get $solver profile]]
    set template [string tolower [dict get $solver template]]
    if {$expected eq ""} {
        set blocked 1
        lappend checks [::HWFlow::preflightCheck solver BLOCKED "project.solver_profile is not configured"]
    } elseif {[llength [info commands hm_info]] == 0} {
        set warned 1
        lappend checks [::HWFlow::preflightCheck solver WARNING "HyperMesh solver context is unavailable offline; expected $expected"]
    } elseif {($profile ne "" && $profile ne "optistruct") || ($profile eq "" && $template ni {nastran optistruct})} {
        set blocked 1
        lappend checks [::HWFlow::preflightCheck solver BLOCKED "Expected $expected; current profile='$profile' template='$template'"]
    } else {
        lappend checks [::HWFlow::preflightCheck solver PASS "profile='$profile' template='$template'"]
    }

    set hmVersion ""
    if {[llength [info commands hm_info]] > 0} {catch {set hmVersion [hm_info -appinfo VERSION]}}
    if {$hmVersion eq ""} {
        set warned 1
        lappend checks [::HWFlow::preflightCheck hypermesh WARNING "HyperMesh version could not be queried"]
    } elseif {![string match "*2019*" $hmVersion]} {
        set warned 1
        lappend checks [::HWFlow::preflightCheck hypermesh WARNING "Validated baseline is HM2019; current version is $hmVersion"]
    } else {
        lappend checks [::HWFlow::preflightCheck hypermesh PASS $hmVersion]
    }

    if {[llength [info commands ::HybridCore::workerAlive]] > 0} {
        if {[::HybridCore::workerAlive]} {
            lappend checks [::HWFlow::preflightCheck worker PASS "persistent worker is alive"]
        } else {
            set warned 1
            lappend checks [::HWFlow::preflightCheck worker WARNING "persistent worker is not started yet"]
        }
    } else {
        set warned 1
        lappend checks [::HWFlow::preflightCheck worker WARNING "module does not require the shared worker"]
    }

    set scratch [file join $::HWFlow::ROOT_DIR runtime tasks]
    if {[info exists ::HybridCore::TASK_ROOT]} {set scratch $::HybridCore::TASK_ROOT}
    if {[file exists $scratch] && ![file writable $scratch]} {
        set blocked 1
        lappend checks [::HWFlow::preflightCheck scratch BLOCKED "Task storage is not writable: $scratch"]
    } else {
        lappend checks [::HWFlow::preflightCheck scratch PASS $scratch]
    }

    set status PASS
    if {$blocked} {set status BLOCKED} elseif {$warned} {set status WARNING}
    return [dict create status $status context $context checks $checks]
}

proc ::HWFlow::formatEngineeringPreflight {result} {
    set lines [list "HMWorkFlow preflight: [dict get $result status]"]
    foreach check [dict get $result checks] {
        lappend lines "[dict get $check status] [dict get $check name]: [dict get $check detail]"
    }
    return [join $lines "\n"]
}

proc ::HWFlow::requireEngineeringContext {} {
    set result [::HWFlow::engineeringPreflight 1]
    if {[dict get $result status] eq "BLOCKED"} {
        error [::HWFlow::formatEngineeringPreflight $result]
    }
    return $result
}

proc ::HWFlow::ensureGlobalConfig {} {
    set f [::HWFlow::globalConfigFile]
    if {![file exists $f]} {
        ::HWFlow::writeTextFile $f [::HWFlow::defaultGlobalConfigText]
    }
    return $f
}

proc ::HWFlow::normalizeLanguage {value} {
    regsub {\s+#.*$} $value "" value
    set v [string tolower [string trim $value "\"' "]]
    switch -glob -- $v {
        zh -
        zh_cn -
        zh-cn -
        chinese -
        cn {
            return zh_CN
        }
        en -
        en_us -
        en-us -
        english {
            return en_US
        }
        default {
            return zh_CN
        }
    }
}

proc ::HWFlow::loadGlobalConfig {} {
    variable LANGUAGE
    variable LANGUAGE_LOADED

    set LANGUAGE zh_CN
    set path [::HWFlow::ensureGlobalConfig]
    set inWorkflow 0
    foreach rawLine [split [::HWFlow::readTextFile $path] "\n"] {
        set line [string trim $rawLine]
        if {$line eq "" || [string index $line 0] eq "#"} {
            continue
        }
        if {[regexp {^workflow\s*:\s*$} $line]} {
            set inWorkflow 1
            continue
        }
        if {[regexp {^[A-Za-z0-9_.-]+\s*:\s*$} $line]} {
            set inWorkflow 0
            continue
        }
        if {$inWorkflow && [regexp {^language\s*:\s*(.+)$} $line -> value]} {
            set LANGUAGE [::HWFlow::normalizeLanguage $value]
            break
        }
        if {[regexp {^workflow\.language\s*:\s*(.+)$} $line -> value]} {
            set LANGUAGE [::HWFlow::normalizeLanguage $value]
            break
        }
    }
    set LANGUAGE_LOADED 1
    return $LANGUAGE
}

proc ::HWFlow::language {} {
    variable LANGUAGE
    variable LANGUAGE_LOADED
    if {!$LANGUAGE_LOADED} {
        ::HWFlow::loadGlobalConfig
    }
    return $LANGUAGE
}

proc ::HWFlow::isChinese {} {
    return [expr {[::HWFlow::language] eq "zh_CN"}]
}

proc ::HWFlow::txt {zh en} {
    if {[::HWFlow::isChinese]} {
        return $zh
    }
    return $en
}

proc ::HWFlow::firstAvailableFont {candidates fallback} {
    if {[llength [info commands font]] == 0} {
        return $fallback
    }
    set families [font families]
    foreach candidate $candidates {
        if {[lsearch -exact $families $candidate] >= 0} {
            return $candidate
        }
    }
    return $fallback
}

proc ::HWFlow::initFonts {} {
    variable FONT_INITIALIZED
    variable UI_FONT_FAMILY
    variable UI_FIXED_FONT_FAMILY

    if {$FONT_INITIALIZED} {
        return
    }

    set UI_FONT_FAMILY "Arial"
    set UI_FIXED_FONT_FAMILY "Consolas"
    if {[llength [info commands font]] > 0} {
        set UI_FONT_FAMILY [::HWFlow::firstAvailableFont [list "Microsoft YaHei UI" "Microsoft YaHei" "SimHei" "SimSun" "NSimSun" "Arial Unicode MS" "Arial"] "Arial"]
        set UI_FIXED_FONT_FAMILY [::HWFlow::firstAvailableFont [list "NSimSun" "SimSun" "Microsoft YaHei UI" "Microsoft YaHei" "Consolas" "Courier New"] $UI_FONT_FAMILY]

        catch {font configure TkDefaultFont -family $UI_FONT_FAMILY -size 9 -weight normal}
        catch {font configure TkTextFont -family $UI_FONT_FAMILY -size 9 -weight normal}
        catch {font configure TkMenuFont -family $UI_FONT_FAMILY -size 9 -weight normal}
        catch {font configure TkCaptionFont -family $UI_FONT_FAMILY -size 9 -weight bold}
        catch {font configure TkHeadingFont -family $UI_FONT_FAMILY -size 9 -weight bold}
        catch {font configure TkFixedFont -family $UI_FIXED_FONT_FAMILY -size 9 -weight normal}
        catch {option add *Font TkDefaultFont}


    }

    set FONT_INITIALIZED 1
}

proc ::HWFlow::bindAutoWrap {labelWidget {padding 40}} {
    if {[llength [info commands bind]] == 0 || ![winfo exists $labelWidget]} {
        return
    }
    set top [winfo toplevel $labelWidget]
    if {$top ne ""} {
        bind $top <Configure> +[list ::HWFlow::onConfigure %W $top $labelWidget $padding]
    }
}

proc ::HWFlow::onConfigure {eventWidget top labelWidget padding} {
    if {$eventWidget eq $top} {
        ::HWFlow::queueLabelWrap $labelWidget $padding
    }
}

proc ::HWFlow::queueLabelWrap {labelWidget padding} {
    variable WRAP_TIMERS
    if {![info exists WRAP_TIMERS($labelWidget)]} {
        set WRAP_TIMERS($labelWidget) ""
    }
    if {$WRAP_TIMERS($labelWidget) ne ""} {
        catch {after cancel $WRAP_TIMERS($labelWidget)}
    }
    set WRAP_TIMERS($labelWidget) [after 50 [list ::HWFlow::updateLabelWrap $labelWidget $padding]]
}

proc ::HWFlow::updateLabelWrap {labelWidget padding} {
    variable WRAP_TIMERS
    set WRAP_TIMERS($labelWidget) ""
    if {![winfo exists $labelWidget]} { return }
    set top [winfo toplevel $labelWidget]
    if {$top eq ""} { return }
    set wWidth [winfo width $top]
    if {$wWidth > 50} {
        set wrap [expr {$wWidth - $padding}]
        if {$wrap < 100} { set wrap 100 }
        catch {
            set currentWrap [$labelWidget cget -wraplength]
            if {$currentWrap != $wrap} {
                $labelWidget configure -wraplength $wrap
            }
        }
    }
}

proc ::HWFlow::uiFont {{role default}} {
    variable UI_FONT_FAMILY
    variable UI_FIXED_FONT_FAMILY

    ::HWFlow::initFonts
    switch -- $role {
        header {
            return [list $UI_FONT_FAMILY 14 bold]
        }
        title {
            return [list $UI_FONT_FAMILY 11 bold]
        }
        heading {
            return [list $UI_FONT_FAMILY 10 bold]
        }
        module {
            return [list $UI_FONT_FAMILY 9 bold]
        }
        small {
            return [list $UI_FONT_FAMILY 8 normal]
        }
        fixed {
            return [list $UI_FIXED_FONT_FAMILY 9 normal]
        }
        fixedSmall {
            return [list $UI_FIXED_FONT_FAMILY 8 normal]
        }
        default {
            return [list $UI_FONT_FAMILY 9 normal]
        }
    }
}

proc ::HWFlow::initUI {} {
    variable UI_INITIALIZED
    variable UI_BACKEND

    if {$UI_INITIALIZED} {
        return $UI_BACKEND
    }

    set UI_BACKEND "tk"
    if {![catch {package require hwtk} hwtkVersion] &&
        [llength [info commands ::hwtk::toplevel]] > 0} {
        set UI_BACKEND "hwtk"
        catch {puts "HWToolkit: using hwtk $hwtkVersion UI backend"}
    } else {
        catch {puts "HWToolkit: hwtk unavailable; using Tk compatibility backend"}
    }
    set UI_INITIALIZED 1
    return $UI_BACKEND
}

proc ::HWFlow::uiBackend {} {
    return [::HWFlow::initUI]
}

proc ::HWFlow::usingHwtk {} {
    return [expr {[::HWFlow::uiBackend] eq "hwtk"}]
}

# Create a child widget through the active UI backend.  Only shared and shell
# UI should use this adapter during the first migration stage; module-specific
# parameter layouts intentionally remain compatible with their existing Tk
# widget paths and commands.
proc ::HWFlow::uiWidget {kind w args} {
    set candidates {}
    if {[::HWFlow::usingHwtk] && [llength [info commands ::hwtk::$kind]] > 0} {
        lappend candidates ::hwtk::$kind
    }
    if {$kind in {frame label button labelframe scrollbar checkbutton radiobutton entry}} {
        if {[llength [info commands ::ttk::$kind]] > 0} {
            lappend candidates ::ttk::$kind
        }
        if {[llength [info commands ::$kind]] > 0} {
            lappend candidates ::$kind
        }
    } elseif {$kind eq "notebook"} {
        if {[llength [info commands ::ttk::notebook]] == 0} {
            catch {package require tile}
        }
        if {[llength [info commands ::ttk::notebook]] > 0} {
            lappend candidates ::ttk::notebook
        }
    } elseif {$kind eq "progressbar"} {
        if {[llength [info commands ::ttk::progressbar]] > 0} {
            lappend candidates ::ttk::progressbar
        }
    }

    set lastError "no widget command is available for $kind"
    foreach command $candidates {
        catch {destroy $w}
        set code [catch {uplevel 1 [linsert $args 0 $command $w]} result]
        if {!$code} {
            return $result
        }
        set lastError $result
    }
    return -code error $lastError
}

proc ::HWFlow::registerWindow {w {role module}} {
    variable UI_WINDOWS
    set UI_WINDOWS($w) $role
    bind $w <Destroy> +[list ::HWFlow::unregisterWindow %W $w]
}

proc ::HWFlow::unregisterWindow {eventWidget registeredWindow} {
    variable UI_WINDOWS
    if {$eventWidget eq $registeredWindow} {
        catch {unset UI_WINDOWS($registeredWindow)}
    }
}

proc ::HWFlow::managedWindows {} {
    variable UI_WINDOWS
    set result {}
    foreach w [array names UI_WINDOWS] {
        if {[llength [info commands winfo]] > 0 && [winfo exists $w]} {
            lappend result $w
        } else {
            catch {unset UI_WINDOWS($w)}
        }
    }
    return $result
}

proc ::HWFlow::destroyManagedWindows {} {
    foreach w [::HWFlow::managedWindows] {
        catch {destroy $w}
    }
    catch {update idletasks}
}

proc ::HWFlow::progressIsActive {} {
    variable progressActive
    return $progressActive
}

# Compatibility entry point retained for modules that previously requested a
# permanent topmost window.  hwtk windows are raised only when explicitly
# requested; the topmost attribute is no longer installed or rebound.
proc ::HWFlow::keepWindowTopmost {w} {
    if {[llength [info commands winfo]] == 0 || ![winfo exists $w]} {
        return
    }
    catch {raise $w}
}

# HyperMesh mark panels are native modal UI.  Temporarily unpost only windows
# owned by this toolkit, rather than every Tcl toplevel in the HyperMesh
# process.  This preserves compatibility with HM2019 selection panels while
# avoiding the former permanent-topmost focus conflict.
proc ::HWFlow::nativeMarkPanel {entityType markId prompt args} {
    set windows {}
    if {[llength [info commands winfo]] > 0} {
        foreach w [::HWFlow::managedWindows] {
            set mapped [winfo ismapped $w]
            lappend windows [list $w $mapped]
            if {$mapped} { catch {wm withdraw $w} }
        }
        catch {set grabbed [grab current]}
        if {[info exists grabbed] && $grabbed ne ""} { catch {grab release $grabbed} }
        catch {update}
    }

    set code [catch {*createmarkpanel $entityType $markId $prompt {*}$args} err opts]
    foreach state $windows {
        lassign $state w mapped
        if {![winfo exists $w]} { continue }
        if {$mapped} { catch {wm deiconify $w} }
        if {$mapped} { catch {raise $w} }
    }
    catch {update idletasks}
    if {$code} { return -options $opts $err }
    return [hm_getmark $entityType $markId]
}

proc ::HWFlow::nativePanelSessionBegin {} {
    set windows {}
    if {[llength [info commands winfo]] > 0} {
        foreach w [::HWFlow::managedWindows] {
            set mapped [winfo ismapped $w]
            lappend windows [list $w $mapped]
            if {$mapped} { catch {wm withdraw $w} }
        }
        catch {set grabbed [grab current]}
        if {[info exists grabbed] && $grabbed ne ""} { catch {grab release $grabbed} }
        catch {update}
    }
    return $windows
}

proc ::HWFlow::nativePanelSessionEnd {windows} {
    foreach state $windows {
        lassign $state w mapped
        if {![winfo exists $w]} { continue }
        if {$mapped} { catch {wm deiconify $w} }
        if {$mapped} { catch {raise $w} }
    }
    catch {update idletasks}
}

proc ::HWFlow::nativeMarkPanelInSession {entityType markId prompt args} {
    catch {*clearmark $entityType $markId}
    *createmarkpanel $entityType $markId $prompt {*}$args
    return [hm_getmark $entityType $markId]
}

# Run consecutive native selection panels while toolkit windows remain hidden.
# Restoring/raising a modal toolkit window between panels can steal focus from
# the second HyperMesh push panel, especially in HM2019.
proc ::HWFlow::nativeMarkPanelSequence {requests} {
    set windows {}
    if {[llength [info commands winfo]] > 0} {
        foreach w [::HWFlow::managedWindows] {
            set mapped [winfo ismapped $w]
            lappend windows [list $w $mapped]
            if {$mapped} { catch {wm withdraw $w} }
        }
        catch {set grabbed [grab current]}
        if {[info exists grabbed] && $grabbed ne ""} { catch {grab release $grabbed} }
        catch {update}
    }

    set selections {}
    set code [catch {
        foreach request $requests {
            set entityType [lindex $request 0]
            set markId [lindex $request 1]
            set prompt [lindex $request 2]
            set panelArgs [lrange $request 3 end]
            catch {*clearmark $entityType $markId}
            *createmarkpanel $entityType $markId $prompt {*}$panelArgs
            set selected [hm_getmark $entityType $markId]
            lappend selections $selected
            if {[llength $selected] == 0} { break }
        }
    } err opts]

    foreach state $windows {
        lassign $state w mapped
        if {![winfo exists $w]} { continue }
        if {$mapped} { catch {wm deiconify $w} }
        if {$mapped} { catch {raise $w} }
    }
    catch {update idletasks}
    if {$code} { return -options $opts $err }
    return $selections
}

proc ::HWFlow::createTopLevel {w {role module}} {
    set created 0
    if {[::HWFlow::usingHwtk] && [llength [info commands ::hwtk::toplevel]] > 0} {
        if {![catch {::hwtk::toplevel $w}]} {
            set created 1
        } else {
            catch {destroy $w}
        }
    }
    if {!$created} {
        toplevel $w
    }
    ::HWFlow::registerWindow $w $role
    return $w
}

proc ::HWFlow::configDir {} {
    if {[info exists ::env(APPDATA)] && [string trim $::env(APPDATA)] ne ""} {
        set userConfig [file normalize [file join $::env(APPDATA) HMWorkFlow]]
    } else {
        variable CONFIG_DIR
        set userConfig $CONFIG_DIR
    }
    if {![file isdirectory $userConfig]} {file mkdir $userConfig}
    return $userConfig
}

proc ::HWFlow::materialFile {} {
    variable MATERIAL_FILE
    ::HWFlow::configDir
    return $MATERIAL_FILE
}

proc ::HWFlow::defaultMaterialText {} {
    return [join {
        {key|display|density|E|nu|yield|ultimate|note}
        {Q235|Q235|7.85e-9|210000|0.30|235|370|steel}
        {Q345|Q345|7.85e-9|206000|0.30|345|470|steel}
        {AL6061|AL6061|2.70e-9|69000|0.33|275|310|aluminum}
        {QT500|QT500|7.20e-9|169000|0.28|320|500|casting}
    } "\n"]
}

proc ::HWFlow::ensureDefaultConfigs {} {
    set f [::HWFlow::materialFile]
    if {![file exists $f]} {
        set ch [open $f w]
        fconfigure $ch -encoding utf-8 -translation lf
        puts $ch [::HWFlow::defaultMaterialText]
        close $ch
    }
}

proc ::HWFlow::readTextFile {path} {
    if {![file exists $path]} {
        return ""
    }
    set ch [open $path r]
    fconfigure $ch -encoding utf-8
    set data [read $ch]
    close $ch
    return $data
}

proc ::HWFlow::writeTextFile {path data} {
    file mkdir [file dirname $path]
    set ch [open $path w]
    fconfigure $ch -encoding utf-8 -translation lf
    puts -nonewline $ch $data
    close $ch
}

proc ::HWFlow::stateFile {moduleKey} {
    set safe [::HWFlow::sanitizeToken $moduleKey state]
    return [file join [::HWFlow::configDir] "${safe}_state.txt"]
}

proc ::HWFlow::loadState {moduleKey} {
    set path [::HWFlow::stateFile $moduleKey]
    set state [dict create]
    if {![file exists $path]} {
        # Dual-read migration: consume the former installation-local state
        # once, while all new writes go to the per-user AppData directory.
        set legacy [file join $::HWFlow::CONFIG_DIR "[::HWFlow::sanitizeToken $moduleKey state]_state.txt"]
        if {[file exists $legacy]} {set path $legacy} else {return $state}
    }

    foreach rawLine [split [::HWFlow::readTextFile $path] "\n"] {
        set line [string trim $rawLine]
        if {$line eq "" || [string index $line 0] eq "#"} {
            continue
        }
        if {[catch {set fields [lrange $line 0 end]}] || [llength $fields] < 2} {
            continue
        }
        dict set state [lindex $fields 0] [lindex $fields 1]
    }
    return $state
}

proc ::HWFlow::saveState {moduleKey state} {
    set lines [list "# Saved UI state for $moduleKey" "# key value"]
    foreach key [lsort [dict keys $state]] {
        lappend lines [list $key [dict get $state $key]]
    }
    ::HWFlow::writeTextFile [::HWFlow::stateFile $moduleKey] [join $lines "\n"]
}

proc ::HWFlow::applyStateToArray {moduleKey arrayName {allowedKeys ""}} {
    upvar #0 $arrayName arr
    if {![array exists arr]} {
        return 0
    }
    set state [::HWFlow::loadState $moduleKey]
    foreach key [dict keys $state] {
        if {$allowedKeys ne "" && [lsearch -exact $allowedKeys $key] < 0} {
            continue
        }
        if {[info exists arr($key)]} {
            set arr($key) [dict get $state $key]
        }
    }
    return 1
}

proc ::HWFlow::saveArrayState {moduleKey arrayName {skipKeys ""}} {
    upvar #0 $arrayName arr
    if {![array exists arr]} {
        return 0
    }
    set state [dict create]
    foreach key [lsort [array names arr]] {
        if {[lsearch -exact $skipKeys $key] >= 0} {
            continue
        }
        dict set state $key $arr($key)
    }
    ::HWFlow::saveState $moduleKey $state
    return 1
}

proc ::HWFlow::loadMaterials {} {
    variable materialRows
    variable materialKeys

    ::HWFlow::ensureDefaultConfigs
    set data [::HWFlow::readTextFile [::HWFlow::materialFile]]
    set materialRows {}
    set materialKeys {}
    set header {}

    foreach rawLine [split $data "\n"] {
        set line [string trim $rawLine]
        if {$line eq "" || [string index $line 0] eq "#"} {
            continue
        }
        set cols [split $line "|"]
        if {[llength $header] == 0} {
            set header $cols
            continue
        }

        set row [dict create]
        for {set i 0} {$i < [llength $header]} {incr i} {
            set key [string trim [lindex $header $i]]
            set val [string trim [lindex $cols $i]]
            dict set row $key $val
        }
        set matKey [string trim [dict get $row key]]
        if {$matKey eq ""} {
            continue
        }
        lappend materialRows $row
        lappend materialKeys $matKey
    }
    return $materialRows
}

proc ::HWFlow::materialKeys {} {
    variable materialKeys
    if {[llength $materialKeys] == 0} {
        ::HWFlow::loadMaterials
    }
    return $materialKeys
}

proc ::HWFlow::materialRowByKey {matKey} {
    variable materialRows
    if {[llength $materialRows] == 0} {
        ::HWFlow::loadMaterials
    }
    foreach row $materialRows {
        if {[dict get $row key] eq $matKey} {
            return $row
        }
    }
    return ""
}

proc ::HWFlow::isMaterialKey {token} {
    return [expr {[lsearch -exact [::HWFlow::materialKeys] $token] >= 0}]
}

proc ::HWFlow::categoryList {} {
    variable CATEGORIES
    return $CATEGORIES
}

proc ::HWFlow::isCategory {token} {
    return [expr {[lsearch -exact [::HWFlow::categoryList] $token] >= 0}]
}

proc ::HWFlow::sanitizeToken {raw {fallback X}} {
    set s [string trim $raw]
    if {$s eq ""} {
        set s $fallback
    }
    regsub -all {[^0-9A-Za-z_.+-]+} $s "_" s
    regsub -all {_+} $s "_" s
    set s [string trim $s "_"]
    if {$s eq ""} {
        set s $fallback
    }
    return $s
}

proc ::HWFlow::stableHash {text} {
    set hash 2166136261
    foreach ch [split $text ""] {
        scan $ch %c code
        set hash [expr {(($hash ^ $code) * 16777619) & 0xffffffff}]
    }
    return [format %08X $hash]
}

proc ::HWFlow::entityTagName {prefix key} {
    set safePrefix [::HWFlow::sanitizeToken $prefix TAG]
    return "${safePrefix}_[::HWFlow::stableHash $key]"
}

proc ::HWFlow::nodeSetKey {nodes} {
    set clean {}
    foreach n $nodes {
        if {$n eq ""} {
            continue
        }
        lappend clean [expr {int($n)}]
    }
    return [join [lsort -integer -unique $clean] "_"]
}

proc ::HWFlow::nodePairKey {n1 n2 {extra ""}} {
    set a [expr {int($n1)}]
    set b [expr {int($n2)}]
    if {$a > $b} {
        set tmp $a
        set a $b
        set b $tmp
    }
    if {$extra eq ""} {
        return "${a}_${b}"
    }
    return "${a}_${b}|$extra"
}

proc ::HWFlow::coordKey {point {tol 0.001}} {
    if {$tol <= 0.0} {
        set tol 0.001
    }
    set out {}
    foreach v [lrange $point 0 2] {
        if {$v eq "" || ![string is double -strict $v]} {
            lappend out 0
        } else {
            lappend out [expr {round(double($v) / double($tol))}]
        }
    }
    while {[llength $out] < 3} {
        lappend out 0
    }
    return [join $out ","]
}

proc ::HWFlow::coordListKey {coords {tol 0.001}} {
    set out {}
    foreach p $coords {
        if {[llength $p] >= 3} {
            lappend out [::HWFlow::coordKey $p $tol]
        }
    }
    return [join $out ";"]
}

proc ::HWFlow::nameTokens {name} {
    set out {}
    foreach token [split [string trim $name] "_"] {
        set token [::HWFlow::sanitizeToken $token ""]
        if {$token ne ""} {
            lappend out $token
        }
    }
    return $out
}

proc ::HWFlow::stripKnownCategory {tokens} {
    if {[llength $tokens] > 0 && [::HWFlow::isCategory [lindex $tokens 0]]} {
        return [lrange $tokens 1 end]
    }
    return $tokens
}

proc ::HWFlow::componentCategoryFromName {name} {
    set tokens [::HWFlow::nameTokens $name]
    if {[llength $tokens] > 0 && [::HWFlow::isCategory [lindex $tokens 0]]} {
        return [lindex $tokens 0]
    }
    return ""
}

proc ::HWFlow::replaceCategoryInName {name category} {
    set category [::HWFlow::sanitizeToken [string toupper $category] "SHELL"]
    set tokens [::HWFlow::stripKnownCategory [::HWFlow::nameTokens $name]]
    if {[llength $tokens] == 0} {
        set tokens [list COMPONENT]
    }
    return [join [linsert $tokens 0 $category] "_"]
}

proc ::HWFlow::replaceMaterialInName {name matKey} {
    set matKey [::HWFlow::sanitizeToken $matKey MAT]
    set tokens [::HWFlow::nameTokens $name]
    if {[llength $tokens] == 0} {
        set tokens [list COMPONENT]
    }
    set last [lindex $tokens end]
    if {[::HWFlow::isMaterialKey $last]} {
        set tokens [lreplace $tokens end end $matKey]
    } else {
        lappend tokens $matKey
    }
    return [join $tokens "_"]
}

# Canonical thickness naming shared by midsurface and mesh-weld outputs.
# Keeping both the reader and formatter here prevents one module from creating
# a T token that the next module cannot recognize.
proc ::HWFlow::thicknessFromComponentName {name} {
    if {[regexp -nocase {(^|_)T([0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?)(_|$)} $name -> prefix value decimal exponent suffix] &&
        [string is double -strict $value] && $value > 0.0} {
        return [expr {double($value)}]
    }
    return ""
}

proc ::HWFlow::formatThicknessToken {value} {
    if {$value eq "" || ![string is double -strict $value] || $value <= 0.0} {
        return "UNKNOWN"
    }
    set text [format "%.6g" $value]
    regsub {\.0+$} $text "" text
    regsub {(\.[0-9]*?)0+([eE].*)?$} $text {\1\2} text
    return [::HWFlow::sanitizeToken $text UNKNOWN]
}

proc ::HWFlow::formatMidsurfName {sourceName thicknessText} {
    set tText [::HWFlow::sanitizeToken $thicknessText UNKNOWN]
    set tokens [::HWFlow::nameTokens $sourceName]
    if {[llength $tokens] == 0} {
        set tokens [list SHELL COMPONENT]
    }

    set mat ""
    if {[llength $tokens] > 0 && [::HWFlow::isMaterialKey [lindex $tokens end]]} {
        set mat [lindex $tokens end]
        set tokens [lrange $tokens 0 end-1]
    }

    set clean {}
    foreach token $tokens {
        if {[::HWFlow::thicknessFromComponentName $token] eq ""} {
            lappend clean $token
        }
    }
    set tokens $clean
    lappend tokens "T$tText"
    if {$mat ne ""} {
        lappend tokens $mat
    }
    return [join $tokens "_"]
}

proc ::HWFlow::componentName {compId} {
    foreach etype {comps components component} {
        if {![catch {set n [hm_getcollectorname $etype $compId]}] && $n ne ""} {
            return $n
        }
        if {![catch {set n [hm_entityinfo name $etype $compId -byid]}] && $n ne ""} {
            return $n
        }
    }
    if {![catch {set n [hm_getvalue comps id=$compId dataname=name]}] && $n ne ""} {
        return $n
    }
    return "COMP_$compId"
}

proc ::HWFlow::componentIdByName {name} {
    foreach etype {components comps component} {
        if {![catch {set id [hm_entityinfo id $etype $name -byname]}] && $id ne "" && $id != 0} {
            return $id
        }
        if {![catch {set id [hm_getvalue $etype name=$name dataname=id]}] && $id ne "" && $id != 0} {
            return $id
        }
    }
    return ""
}

proc ::HWFlow::componentSnapshot {{markId 2}} {
    set ids {}
    set markType ""
    foreach etype {comps components} {
        catch {*clearmark $etype $markId}
        foreach selector {all displayed inactive} {
            if {![catch {*createmark $etype $markId $selector}]} {
                if {![catch {set gotIds [hm_getmark $etype $markId]}] && [llength $gotIds] > 0} {
                    set ids $gotIds
                    set markType $etype
                    break
                }
            }
        }
        if {[llength $ids] > 0} {
            break
        }
    }

    set names {}
    foreach compId $ids {
        set name [::HWFlow::componentName $compId]
        if {$name ne ""} {
            lappend names $name
        }
    }
    if {$markType ne ""} {
        catch {*clearmark $markType $markId}
    }
    return [dict create ids $ids names $names count [llength $ids] markType $markType]
}

proc ::HWFlow::componentIds {{markId 2}} {
    set ids {}
    foreach etype {components comps} {
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

proc ::HWFlow::newIds {beforeIds afterIds} {
    array set seen {}
    foreach id $beforeIds {
        set seen($id) 1
    }
    set added {}
    foreach id $afterIds {
        if {![info exists seen($id)]} {
            lappend added $id
        }
    }
    return [lsort -integer -unique $added]
}

proc ::HWFlow::createComponentThroughBrowser {compName} {
    if {[llength [info commands ::hmbr::operation]] == 0} {
        return ""
    }

    set beforeIds [::HWFlow::componentIds 2]
    if {[catch {
        ::hmbr::operation perform hmbr::createonly [list [list Components {}]]
    } err]} {
        return ""
    }

    set addedIds [::HWFlow::newIds $beforeIds [::HWFlow::componentIds 2]]
    if {[llength $addedIds] == 0} {
        return ""
    }
    set compId [lindex $addedIds end]
    set createdName [::HWFlow::componentName $compId]
    if {$createdName ne $compName} {
        if {[catch {*renamecollector component $createdName $compName} err1]} {
            if {[catch {*renamecollector components $createdName $compName} err2]} {
                error [::HWFlow::txt \
                    "Model Browser 已创建组件 $createdName，但无法重命名为 $compName：$err1 / $err2" \
                    "Model Browser created component $createdName, but it could not be renamed to $compName: $err1 / $err2"]
            }
        }
    }

    set renamedId [::HWFlow::componentIdByName $compName]
    if {$renamedId ne ""} {
        return $renamedId
    }
    return $compId
}

proc ::HWFlow::randomComponentColor {} {
    variable componentColorSeeded
    variable componentColorPalette

    if {!$componentColorSeeded} {
        set seed [clock clicks]
        catch {set seed [expr {$seed + [pid]}]}
        expr {srand($seed)}
        set componentColorSeeded 1
    }
    if {[llength $componentColorPalette] == 0} {
        return 3
    }
    return [lindex $componentColorPalette [expr {int(rand() * [llength $componentColorPalette])}]]
}

proc ::HWFlow::resolveComponentColor {{color ""}} {
    set color [string trim $color]
    if {$color eq "" || $color eq "random" || $color eq "auto"} {
        return [::HWFlow::randomComponentColor]
    }
    return $color
}

proc ::HWFlow::rememberComponent {compName} {
    variable touchedComponents
    set compName [string trim $compName]
    if {$compName eq ""} {
        return
    }
    if {[lsearch -exact $touchedComponents $compName] < 0} {
        lappend touchedComponents $compName
    }
}

proc ::HWFlow::markComponentByName {compName markId} {
    foreach etype {components comps} {
        catch {*clearmark $etype $markId}
        foreach selector {"by name only" "by name"} {
            if {![catch {*createmark $etype $markId $selector $compName}]} {
                if {![catch {set ids [hm_getmark $etype $markId]}] && [llength $ids] > 0} {
                    return $etype
                }
            }
        }
    }

    set compId [::HWFlow::componentIdByName $compName]
    if {$compId ne ""} {
        foreach etype {components comps} {
            catch {*clearmark $etype $markId}
            if {![catch {*createmark $etype $markId "by id only" $compId}]} {
                if {![catch {set ids [hm_getmark $etype $markId]}] && [llength $ids] > 0} {
                    return $etype
                }
            }
        }
    }
    return ""
}

proc ::HWFlow::activateAndShowComponent {compName {refresh 0}} {
    set compName [string trim $compName]
    if {$compName eq ""} {
        return 0
    }
    ::HWFlow::rememberComponent $compName

    set markType [::HWFlow::markComponentByName $compName 2]
    if {$markType ne ""} {
        catch {*marksuppressactive $markType 2 0}
        catch {*marksuppressoutput $markType 2 0}
        catch {*displaycollectorsbymark $markType 2 on 1 1}
        catch {*displaycollectorsbymark components 2 on 1 1}
        catch {*displaycollectorsbymark comps 2 on 1 1}
        catch {*displaycollectorsallbymark 2 on 1 1}
        catch {*clearmark $markType 2}
    }

    catch {*displaycollector component on $compName 1 1}
    catch {*displaycollector components on $compName 1 1}
    catch {*displaycollectorwithfilter component on $compName 1 1}
    catch {*displaycollectorwithfilter components on $compName 1 1}

    set compId [::HWFlow::componentIdByName $compName]
    if {$compId ne ""} {
        catch {*showentity comps "by id" $compId}
        catch {*showentity components "by id" $compId}
    }
    if {$refresh} {
        ::HWFlow::syncComponentInBrowser $compName
    }
    return 1
}

proc ::HWFlow::syncComponentInBrowser {compName {activateInactive 0}} {
    set compName [string trim $compName]
    if {$compName eq ""} {
        return 0
    }
    ::HWFlow::rememberComponent $compName
    ::HWFlow::resetBrowserBlocks
    ::HWFlow::activateAndShowComponent $compName 0
    set summary [::HWFlow::refreshBrowserNow $activateInactive]
    ::HWFlow::scheduleBrowserRefresh $activateInactive
    return $summary
}

proc ::HWFlow::createComponent {compName {color ""}} {
    set compName [string trim $compName]
    if {$compName eq ""} {
        set compName COMPONENT
    }
    set compId [::HWFlow::componentIdByName $compName]
    if {$compId ne ""} {
        catch {*currentcollector component $compName}
        catch {*currentcollector components $compName}
        ::HWFlow::syncComponentInBrowser $compName
        return $compId
    }
    set color [::HWFlow::resolveComponentColor $color]

    ::HWFlow::resetBrowserBlocks

    # Never use the Model Browser create operation for automated component
    # creation. In HyperMesh 2019 it opens the interactive Create Component
    # dialog and blocks batch workflows. The command fallbacks below create
    # the same collector without user interaction.
    set compId ""
    if {$compId eq ""} {
        set histName "Created Component $compName"
        catch {*startnotehistorystate $histName}
        set createCode [catch {*createentity comps includeid=0 name=$compName} err1]
        if {$createCode} {
            set createCode [catch {*createentity components includeid=0 name=$compName} err1]
        }
        if {$createCode} {
            set createCode [catch {*collectorcreateonly comps $compName "" $color} err2]
        }
        if {$createCode} {
            set createCode [catch {*collectorcreateonly components $compName "" $color} err2]
        }
        if {$createCode} {
            catch {*endnotehistorystate $histName}
            error [::HWFlow::txt "无法创建组件 $compName：$err1 / $err2" "Cannot create component $compName: $err1 / $err2"]
        }
        catch {*endnotehistorystate $histName}
        set compId [::HWFlow::componentIdByName $compName]
    }

    if {$compId ne ""} {
        foreach etype {comps components} {
            catch {*setvalue $etype id=$compId color=$color}
        }
    }

    catch {*createmark components 1 $compName}
    catch {*clearmark components 1}
    catch {*currentcollector component $compName}
    catch {*currentcollector components $compName}
    ::HWFlow::syncComponentInBrowser $compName
    return $compId
}

proc ::HWFlow::entityExistsByName {etype name} {
    if {![catch {set exists [hm_entityinfo exist $etype $name -byname]}]} {
        return $exists
    }
    if {![catch {set id [hm_entityinfo id $etype $name -byname]}] && $id ne "" && $id != 0} {
        return 1
    }
    return 0
}

proc ::HWFlow::entityIdByName {entityTypes name} {
    foreach etype $entityTypes {
        if {![catch {set id [hm_entityinfo id $etype $name -byname]}] && $id ne "" && $id != 0} {
            return $id
        }
        if {![catch {set id [hm_getvalue $etype name=$name dataname=id]}] && $id ne "" && $id != 0} {
            return $id
        }
    }
    return ""
}

proc ::HWFlow::assemblyIdByName {name} {
    foreach etype {assemblies assems assembly} {
        if {![catch {set id [hm_entityinfo id $etype $name -byname]}] && $id ne "" && $id != 0} {
            return $id
        }
        if {![catch {set id [hm_getvalue $etype name=$name dataname=id]}] && $id ne "" && $id != 0} {
            return $id
        }
    }
    return ""
}

proc ::HWFlow::createAssemblyWithMark {name markId {color 9}} {
    if {[::HWFlow::assemblyIdByName $name] ne ""} {
        return 1
    }
    if {![catch {*assemblymodifyhierarchy $name $markId $color}]} {
        return 1
    }
    if {![catch {*assemblymodify $name $markId $color}]} {
        return 1
    }
    if {![catch {*createentity assems name=$name}]} {
        return 1
    }
    if {![catch {*createentity assemblies name=$name}]} {
        return 1
    }
    return 0
}

proc ::HWFlow::ensureAssembly {name {color 9}} {
    set id [::HWFlow::assemblyIdByName $name]
    if {$id ne ""} {
        return $id
    }
    catch {*clearmark comps 1}
    catch {*createmark comps 1}
    ::HWFlow::createAssemblyWithMark $name 1 $color
    catch {*clearmark comps 1}
    return [::HWFlow::assemblyIdByName $name]
}

proc ::HWFlow::markComponents {markId compIds} {
    catch {*clearmark comps $markId}
    if {[llength $compIds] == 0} {
        return 0
    }
    if {[catch {eval *createmark comps $markId $compIds}]} {
        catch {eval *createmark components $markId $compIds}
    }
    return 1
}

proc ::HWFlow::markAssemblyById {markId asmId} {
    foreach etype {assemblies assems assembly} {
        catch {*clearmark $etype $markId}
        if {![catch {*createmark $etype $markId "by id only" $asmId}]} {
            if {![catch {set ids [hm_getmark $etype $markId]}] && [llength $ids] > 0} {
                return $etype
            }
        }
        if {![catch {*createmark $etype $markId $asmId}]} {
            if {![catch {set ids [hm_getmark $etype $markId]}] && [llength $ids] > 0} {
                return $etype
            }
        }
    }
    return ""
}

proc ::HWFlow::addComponentsToAssembly {assemblyName compIds {color 9}} {
    if {[llength $compIds] == 0} {
        return ""
    }

    set asmId [::HWFlow::assemblyIdByName $assemblyName]
    ::HWFlow::markComponents 1 $compIds
    if {$asmId eq ""} {
        ::HWFlow::createAssemblyWithMark $assemblyName 1 $color
        set asmId [::HWFlow::assemblyIdByName $assemblyName]
    } else {
        catch {*assemblyaddmark $asmId comps 1}
        catch {*assemblyaddmark $asmId components 1}
    }
    catch {*clearmark comps 1}
    catch {*clearmark components 1}
    return $asmId
}

proc ::HWFlow::addAssemblyToAssembly {parentName childName {color 9}} {
    set parentId [::HWFlow::ensureAssembly $parentName $color]
    set childId [::HWFlow::ensureAssembly $childName $color]
    if {$parentId eq "" || $childId eq ""} {
        return 0
    }
    set etype [::HWFlow::markAssemblyById 2 $childId]
    if {$etype eq ""} {
        return 0
    }
    catch {*assemblyaddmark $parentId $etype 2}
    catch {*clearmark $etype 2}
    return 1
}

proc ::HWFlow::renameComponent {oldName newName} {
    if {$oldName eq $newName} {
        return $newName
    }
    set base [::HWFlow::sanitizeToken $newName COMPONENT]
    set candidate $base
    for {set i 1} {$i <= 999} {incr i} {
        if {![::HWFlow::entityExistsByName components $candidate] || $candidate eq $oldName} {
            break
        }
        set candidate [format "%s_%02d" $base $i]
    }
    if {[catch {*renamecollector component $oldName $candidate} err1]} {
        if {[catch {*renamecollector components $oldName $candidate} err2]} {
            error [::HWFlow::txt "无法将组件 $oldName 重命名为 $candidate：$err1 / $err2" "Cannot rename component $oldName to $candidate: $err1 / $err2"]
        }
    }
    ::HWFlow::rememberComponent $candidate
    ::HWFlow::activateAndShowComponent $candidate 0
    return $candidate
}

proc ::HWFlow::getCompEntityIds {compId dataname markEntityType {markId 2}} {
    set ids {}
    if {![catch {set ids [hm_getvalue comps id=$compId dataname=$dataname]}] && [llength $ids] > 0} {
        return [lsort -integer -unique $ids]
    }

    catch {*clearmark $markEntityType $markId}
    if {![catch {*createmark $markEntityType $markId "by comp id" $compId}]} {
        catch {set ids [hm_getmark $markEntityType $markId]}
    }
    catch {*clearmark $markEntityType $markId}
    if {[llength $ids] == 0} {
        return {}
    }
    return [lsort -integer -unique $ids]
}

proc ::HWFlow::componentEntityCount {compId dataname markEntityType} {
    return [llength [::HWFlow::getCompEntityIds $compId $dataname $markEntityType]]
}

proc ::HWFlow::displayComponent {compName state} {
    catch {*displaycollector component $state $compName 1 1}
    catch {*displaycollector components $state $compName 1 1}
    catch {::HWFlow::browserFlushPulse}
    catch {hm_redraw}
    catch {update idletasks}
}

proc ::HWFlow::resetBrowserBlocks {} {
    foreach cmd {
        {hm_blockbrowserupdate 0}
        {*setoption block_browser_update=0}
        {*setoption block_redraw=0}
        {*setoption block_messages=0}
        {*setoption command_file_state=1}
        {hm_blockredraw 0}
        {hm_blockmessages 0}
        {hm_blockerrormessages 0}
        {hm_commandfilestate 1}
        {hmbr_signals buffer stop}
    } {
        catch {uplevel #0 $cmd}
    }
}

proc ::HWFlow::browserFlushPulse {} {
    foreach cmd {
        {hm_blockbrowserupdate 0}
        {hmbr_signals buffer stop}
        {hwbrowsermanager view flush true}
        {hwbrowsermanager view flush 1}
        {hwbrowsermanager view flush on}
        {hm_blockbrowserupdate 0}
        {hm_redraw}
    } {
        catch {uplevel #0 $cmd}
    }
}

proc ::HWFlow::refreshBrowserNow {{activateInactive 0}} {
    # Reset redraw/browser throttles, then force a false->true browser flush.
    # The pulse matters on HM2019 because a no-op "true" flush can leave the
    # existing Model Browser tree unchanged while the database is already valid.
    ::HWFlow::resetBrowserBlocks
    variable touchedComponents
    set modelSnapshot [::HWFlow::componentSnapshot 2]
    set trackedComponents [list {*}$touchedComponents]
    catch {::HWFlow::browserFlushPulse}
    catch {update idletasks}
    catch {update}

    return [dict create \
        touchedComponents $trackedComponents \
        touchedCount [llength $trackedComponents] \
        modelComponents [dict get $modelSnapshot names] \
        modelCount [dict get $modelSnapshot count] \
        activateInactive 0 \
        preserveVisibility 1]
}

proc ::HWFlow::scheduleBrowserRefresh {{activateInactive 0}} {
    if {[llength [info commands after]] == 0} {
        return
    }
    catch {after idle [list catch [list ::HWFlow::refreshBrowserNow $activateInactive]]}
    foreach delay {150 600} {
        catch {after $delay [list catch [list ::HWFlow::refreshBrowserNow $activateInactive]]}
    }
}

proc ::HWFlow::refreshBrowser {{notify 0} {activateInactive 0}} {
    set summary [::HWFlow::refreshBrowserNow $activateInactive]
    ::HWFlow::scheduleBrowserRefresh $activateInactive
    if {$notify} {
        catch {hm_usermessage [::HWFlow::refreshBrowserSummaryText $summary]}
    }
    return $summary
}

proc ::HWFlow::refreshBrowserSummaryText {summary} {
    set touchedCount 0
    set touchedComponents {}
    set modelCount 0
    set modelComponents {}
    set activateInactive 0

    if {[dict exists $summary touchedCount]} {
        set touchedCount [dict get $summary touchedCount]
    }
    if {[dict exists $summary touchedComponents]} {
        set touchedComponents [dict get $summary touchedComponents]
    }
    if {[dict exists $summary modelCount]} {
        set modelCount [dict get $summary modelCount]
    }
    if {[dict exists $summary modelComponents]} {
        set modelComponents [dict get $summary modelComponents]
    }
    if {[dict exists $summary activateInactive]} {
        set activateInactive [dict get $summary activateInactive]
    }

    set message [::HWFlow::txt "模型浏览器已刷新。" "Model Browser refreshed."]
    append message [::HWFlow::txt "\n当前模型 component：$modelCount 个。" "\nModel components: $modelCount."]
    append message [::HWFlow::txt "\n脚本记录 component：$touchedCount 个。" "\nTracked components: $touchedCount."]
    append message [::HWFlow::txt "\n未改变 component 的显示/隐藏状态。" "\nComponent visibility was not changed."]
    if {$touchedCount > 0} {
        set preview [lrange $touchedComponents 0 12]
        append message [::HWFlow::txt "\n脚本记录组件：\n[join $preview \n]" "\nTracked components:\n[join $preview \n]"]
        if {$touchedCount > [llength $preview]} {
            append message [::HWFlow::txt "\n..." "\n..."]
        }
    } elseif {$modelCount > 0} {
        set preview [lrange $modelComponents 0 12]
        append message [::HWFlow::txt "\n模型组件预览：\n[join $preview \n]" "\nModel component preview:\n[join $preview \n]"]
        if {$modelCount > [llength $preview]} {
            append message [::HWFlow::txt "\n..." "\n..."]
        }
    }
    if {$activateInactive} {
        append message [::HWFlow::txt "\n已请求同时显示 inactive component。" "\nInactive components were also requested for display."]
    }
    return $message
}

proc ::HWFlow::progressOpen {title {message ""} {allowCancel 0}} {
    variable progressWin
    variable progressMessage
    variable progressDetail
    variable progressPercentText
    variable progressLastLog
    variable progressCancelRequested
    variable progressActive

    set progressMessage $message
    set progressDetail ""
    set progressPercentText "0.0%"
    set progressLastLog ""
    set progressCancelRequested 0
    set progressActive 1

    if {[llength [info commands toplevel]] == 0} {
        set progressActive 0
        return 0
    }

    set w $progressWin
    catch {destroy $w}
    if {[catch {
        ::HWFlow::createTopLevel $w progress
        wm title $w $title
        wm resizable $w 0 0

        ::HWFlow::uiWidget frame $w.main
        pack $w.main -fill both -expand 1 -padx 14 -pady 12

        ::HWFlow::uiWidget label $w.main.title -text $title -font [::HWFlow::uiFont heading] -anchor w
        ::HWFlow::uiWidget label $w.main.msg -textvariable ::HWFlow::progressMessage -anchor w -width 66 -wraplength 520 -justify left
        ::HWFlow::uiWidget label $w.main.detail -textvariable ::HWFlow::progressDetail -anchor w -width 66 -wraplength 520 -justify left
        ::HWFlow::uiWidget progressbar $w.main.bar -mode determinate -value 0
        ::HWFlow::uiWidget label $w.main.percent -textvariable ::HWFlow::progressPercentText -width 7 -anchor e
        ::HWFlow::uiWidget labelframe $w.main.stream -text [::HWFlow::txt "命令流" "Command Stream"]
        text $w.main.stream.text -width 78 -height 11 -wrap word -font [::HWFlow::uiFont fixedSmall] -state disabled -background #f8f8f8
        ::HWFlow::uiWidget scrollbar $w.main.stream.scroll -orient vertical -command "$w.main.stream.text yview"
        $w.main.stream.text configure -yscrollcommand "$w.main.stream.scroll set"
        grid $w.main.stream.text -row 0 -column 0 -sticky nsew
        grid $w.main.stream.scroll -row 0 -column 1 -sticky ns
        grid rowconfigure $w.main.stream 0 -weight 1
        grid columnconfigure $w.main.stream 0 -weight 1

        grid $w.main.title -row 0 -column 0 -sticky ew -pady {0 6}
        grid $w.main.msg -row 1 -column 0 -sticky ew
        grid $w.main.detail -row 2 -column 0 -sticky ew -pady {2 8}
        grid $w.main.bar -row 3 -column 0 -sticky ew
        grid $w.main.percent -row 3 -column 1 -sticky e -padx {8 0}
        grid $w.main.stream -row 4 -column 0 -columnspan 2 -sticky nsew -pady {8 0}
        grid rowconfigure $w.main 4 -weight 1
        grid columnconfigure $w.main 0 -weight 1

        if {$allowCancel} {
            ::HWFlow::uiWidget frame $w.btn
            pack $w.btn -fill x -padx 14 -pady {0 12}
            ::HWFlow::uiWidget button $w.btn.cancel -text [::HWFlow::txt "取消" "Cancel"] -width 10 -command ::HWFlow::progressRequestCancel
            pack $w.btn.cancel -side right
            wm protocol $w WM_DELETE_WINDOW ::HWFlow::progressRequestCancel
        } else {
            wm protocol $w WM_DELETE_WINDOW [list destroy $w]
        }

        update idletasks
        set sw [winfo screenwidth $w]
        set sh [winfo screenheight $w]
        set ww [winfo reqwidth $w]
        set wh [winfo reqheight $w]
        wm geometry $w +[expr {($sw - $ww) / 2}]+[expr {($sh - $wh) / 2}]
        ::HWFlow::progressForceVisible
    } err]} {
        catch {destroy $w}
        set progressActive 0
        if {$allowCancel} {
            return [::HWFlow::progressOpen $title $message 0]
        }
        if {[::HWFlow::progressOpenMinimal $title $message]} {
            return 1
        }
        catch {hm_usermessage [::HWFlow::txt "进度窗口创建失败。" "Progress window creation failed."]}
        return 0
    }

    ::HWFlow::progressUpdate 0.0 $message "" 1
    ::HWFlow::progressForceVisible
    return 1
}

proc ::HWFlow::progressPumpEvents {{force 0}} {
    variable progressLastEventPumpMs
    variable progressEventPumpActive

    if {$progressEventPumpActive} {
        return
    }
    set progressEventPumpActive 1

    catch {update idletasks}

    set shouldUpdate $force
    if {!$shouldUpdate} {
        if {[catch {clock milliseconds} now]} {
            set shouldUpdate 1
        } elseif {$progressLastEventPumpMs == 0 || ($now - $progressLastEventPumpMs) >= 250} {
            set shouldUpdate 1
        }
    }
    if {$shouldUpdate} {
        catch {update}
        catch {set progressLastEventPumpMs [clock milliseconds]}
    }

    set progressEventPumpActive 0
}

proc ::HWFlow::progressForceVisible {} {
    variable progressWin
    if {[llength [info commands winfo]] == 0} {
        return 0
    }
    if {![winfo exists $progressWin]} {
        return 0
    }
    # Do not steal focus from HyperMesh.  Pumping events is enough to keep the
    # native hwtk progress window painted without a permanent topmost flag.
    ::HWFlow::progressPumpEvents 1
    return 1
}

proc ::HWFlow::progressOpenMinimal {title {message ""}} {
    variable progressWin
    variable progressMessage
    variable progressDetail
    variable progressPercentText
    variable progressLastLog
    variable progressCancelRequested
    variable progressActive

    set progressMessage $message
    set progressDetail ""
    set progressPercentText "0.0%"
    set progressLastLog ""
    set progressCancelRequested 0
    set progressActive 1

    if {[llength [info commands toplevel]] == 0} {
        set progressActive 0
        return 0
    }

    set w $progressWin
    catch {destroy $w}
    if {[catch {
        ::HWFlow::createTopLevel $w progress
        wm title $w $title
        wm resizable $w 0 0
        ::HWFlow::uiWidget frame $w.main
        pack $w.main -fill both -expand 1 -padx 14 -pady 12
        ::HWFlow::uiWidget label $w.main.title -text $title -font [::HWFlow::uiFont heading] -anchor w
        ::HWFlow::uiWidget label $w.main.msg -textvariable ::HWFlow::progressMessage -anchor w -width 66 -wraplength 520 -justify left
        ::HWFlow::uiWidget label $w.main.detail -textvariable ::HWFlow::progressDetail -anchor w -width 66 -wraplength 520 -justify left
        ::HWFlow::uiWidget progressbar $w.main.bar -mode determinate -value 0
        ::HWFlow::uiWidget label $w.main.percent -textvariable ::HWFlow::progressPercentText -width 7 -anchor e
        grid $w.main.title -row 0 -column 0 -sticky ew -pady {0 6}
        grid $w.main.msg -row 1 -column 0 -sticky ew
        grid $w.main.detail -row 2 -column 0 -sticky ew -pady {2 8}
        grid $w.main.bar -row 3 -column 0 -sticky ew
        grid $w.main.percent -row 3 -column 1 -sticky e -padx {8 0}
        grid columnconfigure $w.main 0 -weight 1
        wm protocol $w WM_DELETE_WINDOW [list destroy $w]
        update idletasks
        set sw [winfo screenwidth $w]
        set sh [winfo screenheight $w]
        set ww [winfo reqwidth $w]
        set wh [winfo reqheight $w]
        wm geometry $w +[expr {($sw - $ww) / 2}]+[expr {($sh - $wh) / 2}]
        ::HWFlow::progressForceVisible
    }]} {
        catch {destroy $w}
        set progressActive 0
        return 0
    }

    ::HWFlow::progressUpdate 0.0 $message "" 1
    ::HWFlow::progressForceVisible
    return 1
}

proc ::HWFlow::progressUpdate {percent {message ""} {detail ""} {force 0}} {
    variable progressWin
    variable progressMessage
    variable progressDetail
    variable progressPercentText

    if {$message ne ""} {
        set progressMessage $message
    }
    if {$detail ne ""} {
        set progressDetail $detail
    }

    if {![string is double -strict $percent]} {
        set percent 0.0
    }
    if {$percent < 0.0} { set percent 0.0 }
    if {$percent > 100.0} { set percent 100.0 }
    set progressPercentText "[format %.1f $percent]%"

    if {[llength [info commands winfo]] == 0} {
        return [::HWFlow::progressCancelled]
    }
    if {![winfo exists $progressWin]} {
        return [::HWFlow::progressCancelled]
    }

    set bar $progressWin.main.bar
    if {[winfo exists $bar]} {
        if {[catch {$bar configure -value $percent}]} {
            # Compatibility with a progress window created by an older loaded
            # version of this module in the same HyperMesh session.
            set width [$bar cget -width]
            set height [$bar cget -height]
            set fillWidth [expr {int(double($width) * double($percent) / 100.0)}]
            $bar coords fill 0 0 $fillWidth $height
            $bar coords text [expr {int(double($width) / 2.0)}] [expr {int(double($height) / 2.0)}]
            $bar itemconfigure text -text $progressPercentText
        }
    }

    set logText ""
    if {$detail ne ""} {
        set logText $detail
    } elseif {$message ne ""} {
        set logText $message
    }
    if {$logText ne ""} {
        ::HWFlow::progressAppend $logText $force
    }

    ::HWFlow::progressPumpEvents $force
    if {$force} {
        catch {::HWFlow::progressForceVisible}
    }
    return [::HWFlow::progressCancelled]
}

proc ::HWFlow::progressAppend {text {force 0}} {
    variable progressWin
    variable progressLastLog
    variable progressLogMaxLines

    set text [string trim $text]
    if {$text eq ""} {
        return
    }
    if {!$force && $text eq $progressLastLog} {
        return
    }
    set progressLastLog $text

    if {[llength [info commands winfo]] == 0} {
        return
    }
    if {![winfo exists $progressWin]} {
        return
    }

    set logWidget $progressWin.main.stream.text
    if {![winfo exists $logWidget]} {
        return
    }

    set stamp [clock format [clock seconds] -format {%H:%M:%S}]
    set line "\[$stamp\] $text"
    catch {
        $logWidget configure -state normal
        $logWidget insert end "$line\n"
        set lineCount [expr {int([$logWidget index end])}]
        if {$lineCount > $progressLogMaxLines} {
            set deleteTo [expr {$lineCount - $progressLogMaxLines}]
            $logWidget delete 1.0 "${deleteTo}.0"
        }
        $logWidget see end
        $logWidget configure -state disabled
    }
}

proc ::HWFlow::progressRequestCancel {} {
    variable progressWin
    variable progressMessage
    variable progressCancelRequested

    set progressCancelRequested 1
    set progressMessage [::HWFlow::txt "正在请求取消，请等待当前步骤结束..." "Cancel requested. Waiting for the current step to finish..."]
    catch {::HWFlow::progressAppend $progressMessage 1}
    catch {$progressWin.btn.cancel configure -state disabled}
    catch {update idletasks}
}

proc ::HWFlow::progressCancelled {} {
    variable progressCancelRequested
    return $progressCancelRequested
}

proc ::HWFlow::progressClose {{message ""} {percent 100.0}} {
    variable progressWin
    variable progressActive
    set progressActive 0

    if {$message ne ""} {
        catch {::HWFlow::progressUpdate $percent $message "" 1}
    }
    if {[llength [info commands winfo]] > 0} {
        if {[winfo exists $progressWin]} {
            catch {destroy $progressWin}
        }
    }
    catch {update idletasks}
}

# Complete a task without destroying its progress window.  This avoids hiding
# the only useful diagnostic text at the exact moment a background/native
# command returns.  The former Cancel button becomes an explicit Close button.
proc ::HWFlow::progressFinish {{message ""} {percent 100.0}} {
    variable progressWin
    variable progressActive
    set progressActive 0

    if {$message ne ""} {
        catch {::HWFlow::progressUpdate $percent $message "" 1}
    }
    if {[llength [info commands winfo]] == 0 || ![winfo exists $progressWin]} {
        return 0
    }
    if {[winfo exists $progressWin.btn.cancel]} {
        catch {$progressWin.btn.cancel configure \
            -text [::HWFlow::txt "关闭" "Close"] \
            -state normal \
            -command [list destroy $progressWin]}
    }
    catch {wm protocol $progressWin WM_DELETE_WINDOW [list destroy $progressWin]}
    catch {update idletasks}
    return 1
}

proc ::HWFlow::backToHome {{window ""}} {
    if {$window ne ""} {
        catch {destroy $window}
    }
    if {[llength [info commands ::HWToolkit::showHome]] > 0} {
        after idle ::HWToolkit::showHome
    }
}

proc ::HWFlow::visualLength {str} {
    set len 0
    set strLen [string length $str]
    for {set i 0} {$i < $strLen} {incr i} {
        set char [string index $str $i]
        if {[regexp {[\u4e00-\u9fa5]} $char]} {
            incr len 2
        } else {
            incr len 1
        }
    }
    return $len
}

proc ::HWFlow::padString {str width} {
    set curLen [::HWFlow::visualLength $str]
    set pad [expr {$width - $curLen}]
    if {$pad < 0} { set pad 0 }
    return "$str[string repeat " " $pad]"
}

::HWFlow::ensureDefaultConfigs
