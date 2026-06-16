# ============================================================================
# Workflow common helpers
# HyperMesh 2019 Tcl/Tk
#
# Shared configuration, naming, assembly and browser utilities for the
# preprocessing workflow modules.
# ============================================================================

namespace eval ::HWFlow {
    variable VERSION "0.1"
    variable ROOT_DIR [file dirname [file dirname [file normalize [info script]]]]
    variable GLOBAL_CONFIG_FILE [file join $ROOT_DIR "config.yaml"]
    variable CONFIG_DIR [file join $ROOT_DIR "config"]
    variable MATERIAL_FILE [file join $CONFIG_DIR "materials.txt"]
    variable CATEGORIES {SHELL SOLID CASTING SOURCE_GEOM SEAM CONNECTOR}
    variable LANGUAGE "zh_CN"
    variable LANGUAGE_LOADED 0
    variable materialRows {}
    variable materialKeys {}
    variable progressWin ".hwflow_progress"
    variable progressMessage ""
    variable progressDetail ""
    variable progressLastLog ""
    variable progressLogMaxLines 220
    variable progressCancelRequested 0
    variable FONT_INITIALIZED 0
    variable UI_FONT_FAMILY ""
    variable UI_FIXED_FONT_FAMILY ""
}

proc ::HWFlow::globalConfigFile {} {
    variable GLOBAL_CONFIG_FILE
    return $GLOBAL_CONFIG_FILE
}

proc ::HWFlow::defaultGlobalConfigText {} {
    return [join {
        {# HyperMesh 前处理工作流全局配置 / HyperMesh Preprocess Workflow global configuration}
        {workflow:}
        {  # 界面语言 / UI language: zh_CN or en_US}
        {  language: zh_CN}
    } "\n"]
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

proc ::HWFlow::configDir {} {
    variable CONFIG_DIR
    if {![file isdirectory $CONFIG_DIR]} {
        file mkdir $CONFIG_DIR
    }
    return $CONFIG_DIR
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
        return $state
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
        if {![regexp {^T[0-9.+-]+$} $token]} {
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
    catch {hwbrowsermanager view flush true}
    catch {hm_redraw}
    catch {update idletasks}
}

proc ::HWFlow::refreshBrowser {{notify 0}} {
    # Reset the common redraw/browser throttles used by performance modes, then
    # force the Model Browser and graphics window to consume pending updates.
    foreach cmd {
        {hm_blockbrowserupdate 0}
        {*setoption block_browser_update=0}
        {*setoption block_redraw=0}
        {*setoption block_messages=0}
        {hm_blockredraw 0}
        {hm_blockmessages 0}
        {hm_blockerrormessages 0}
        {hm_commandfilestate 1}
        {hmbr_signals buffer stop}
        {hwbrowsermanager view flush true}
        {hwbrowsermanager view flush 1}
        {hwbrowsermanager view flush on}
        {hm_redraw}
    } {
        catch {uplevel #0 $cmd}
    }
    catch {update idletasks}
    catch {update}
    if {$notify} {
        catch {hm_usermessage [::HWFlow::txt "模型浏览器已刷新。" "Model Browser refreshed."]}
    }
}

proc ::HWFlow::progressOpen {title {message ""} {allowCancel 0}} {
    variable progressWin
    variable progressMessage
    variable progressDetail
    variable progressLastLog
    variable progressCancelRequested

    set progressMessage $message
    set progressDetail ""
    set progressLastLog ""
    set progressCancelRequested 0

    if {[llength [info commands toplevel]] == 0} {
        return 0
    }

    set w $progressWin
    catch {destroy $w}
    if {[catch {
        toplevel $w
        wm title $w $title
        wm resizable $w 0 0

        frame $w.main -padx 14 -pady 12
        pack $w.main -fill both -expand 1

        label $w.main.title -text $title -font [::HWFlow::uiFont heading] -anchor w
        label $w.main.msg -textvariable ::HWFlow::progressMessage -anchor w -width 66 -wraplength 520 -justify left
        label $w.main.detail -textvariable ::HWFlow::progressDetail -anchor w -width 66 -wraplength 520 -justify left
        canvas $w.main.bar -width 520 -height 18 -highlightthickness 1 -highlightbackground #8a8a8a -background white
        $w.main.bar create rectangle 0 0 0 18 -tags fill -fill #2f74d0 -outline ""
        $w.main.bar create text 260 9 -tags text -text "0.0%" -fill #222222 -font [::HWFlow::uiFont small]
        labelframe $w.main.stream -text [::HWFlow::txt "命令流" "Command Stream"] -padx 6 -pady 6
        text $w.main.stream.text -width 78 -height 11 -wrap word -font [::HWFlow::uiFont fixedSmall] -state disabled -background #f8f8f8
        scrollbar $w.main.stream.scroll -orient vertical -command "$w.main.stream.text yview"
        $w.main.stream.text configure -yscrollcommand "$w.main.stream.scroll set"
        grid $w.main.stream.text -row 0 -column 0 -sticky nsew
        grid $w.main.stream.scroll -row 0 -column 1 -sticky ns
        grid rowconfigure $w.main.stream 0 -weight 1
        grid columnconfigure $w.main.stream 0 -weight 1

        grid $w.main.title -row 0 -column 0 -sticky ew -pady {0 6}
        grid $w.main.msg -row 1 -column 0 -sticky ew
        grid $w.main.detail -row 2 -column 0 -sticky ew -pady {2 8}
        grid $w.main.bar -row 3 -column 0 -sticky ew
        grid $w.main.stream -row 4 -column 0 -sticky nsew -pady {8 0}
        grid rowconfigure $w.main 4 -weight 1
        grid columnconfigure $w.main 0 -weight 1

        if {$allowCancel} {
            frame $w.btn -padx 14 -pady {0 12}
            pack $w.btn -fill x
            button $w.btn.cancel -text [::HWFlow::txt "取消" "Cancel"] -width 10 -command ::HWFlow::progressRequestCancel
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

proc ::HWFlow::progressForceVisible {} {
    variable progressWin
    if {[llength [info commands winfo]] == 0} {
        return 0
    }
    if {![winfo exists $progressWin]} {
        return 0
    }
    # Intentionally do not raise, focus, or set topmost here. Progress updates
    # must not steal foreground focus while the user is working elsewhere.
    catch {update idletasks}
    catch {update}
    return 1
}

proc ::HWFlow::progressOpenMinimal {title {message ""}} {
    variable progressWin
    variable progressMessage
    variable progressDetail
    variable progressLastLog
    variable progressCancelRequested

    set progressMessage $message
    set progressDetail ""
    set progressLastLog ""
    set progressCancelRequested 0

    if {[llength [info commands toplevel]] == 0} {
        return 0
    }

    set w $progressWin
    catch {destroy $w}
    if {[catch {
        toplevel $w
        wm title $w $title
        wm resizable $w 0 0
        frame $w.main -padx 14 -pady 12
        pack $w.main -fill both -expand 1
        label $w.main.title -text $title -font [::HWFlow::uiFont heading] -anchor w
        label $w.main.msg -textvariable ::HWFlow::progressMessage -anchor w -width 66 -wraplength 520 -justify left
        label $w.main.detail -textvariable ::HWFlow::progressDetail -anchor w -width 66 -wraplength 520 -justify left
        canvas $w.main.bar -width 520 -height 18 -highlightthickness 1 -highlightbackground #8a8a8a -background white
        $w.main.bar create rectangle 0 0 0 18 -tags fill -fill #2f74d0 -outline ""
        $w.main.bar create text 260 9 -tags text -text "0.0%" -fill #222222 -font [::HWFlow::uiFont small]
        grid $w.main.title -row 0 -column 0 -sticky ew -pady {0 6}
        grid $w.main.msg -row 1 -column 0 -sticky ew
        grid $w.main.detail -row 2 -column 0 -sticky ew -pady {2 8}
        grid $w.main.bar -row 3 -column 0 -sticky ew
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

    if {[llength [info commands winfo]] == 0} {
        return [::HWFlow::progressCancelled]
    }
    if {![winfo exists $progressWin]} {
        return [::HWFlow::progressCancelled]
    }

    set bar $progressWin.main.bar
    if {[winfo exists $bar]} {
        set width [$bar cget -width]
        set height [$bar cget -height]
        set fillWidth [expr {int(double($width) * double($percent) / 100.0)}]
        $bar coords fill 0 0 $fillWidth $height
        $bar coords text [expr {int(double($width) / 2.0)}] [expr {int(double($height) / 2.0)}]
        $bar itemconfigure text -text "[format %.1f $percent]%"
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

    catch {update idletasks}
    if {$force} {
        catch {update}
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

proc ::HWFlow::backToHome {{window ""}} {
    if {$window ne ""} {
        catch {destroy $window}
    }
    if {[llength [info commands ::HWToolkit::showHome]] > 0} {
        after idle ::HWToolkit::showHome
    }
}

::HWFlow::ensureDefaultConfigs
