# ============================================================================
# Batch Mesh Washer
# HyperMesh 2019 Tcl/Tk
#
# Sheet-metal oriented BatchMesh + automatic washer generation.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::BatchMeshWasher {
    variable VERSION "0.1"
    variable CONFIG_KEY "batch_mesh_washer"
    variable RULE_FILE [file join [::HWFlow::configDir] "washer_rules.txt"]
    variable MESH_RULE_FILE [file join [::HWFlow::configDir] "mesh_rules.txt"]

    variable DEFAULTS
    array set DEFAULTS {
        ELEM_SIZE 5.0
        MIN_ELEM_SIZE 2.5
        MAX_ELEM_SIZE 8.0
        PARAMS_GENERATE_MODE shell
        FEATURE_ANGLE 30
        BATCH_TEMP_FILES_MODE 1
        NO_GEOMCLEANUP 1
        NO_WASHER 1
        NO_REMOVE_HOLES 1
        HOLE_MIN_DIA 6.0
        HOLE_MAX_DIA 30.0
        BATCH_BY_COMPONENT 0
        SURFACE_BATCH_SIZE 1
        PERFORMANCE_MODE 0
        WASHER_PROGRESS_STEP 10
        WASHER_BATCH_MODE 1
        WASHER_BATCH_SIZE 80
        RIGID_SPIDER 0
        LOCAL_COORDINATE_SYSTEM 0
        VERBOSE 1
    }

    variable ui
    array set ui {}
    variable rules {}
    variable stat
    array set stat {}
}

proc ::BatchMeshWasher::defaultWasherRulesText {} {
    return [join {
        {# Sheet-metal hole washer rules extracted from the provided standard image.}
        {hole_dia_min|hole_dia_max|action|hole_density|washer_layers|width_mode|widths|note}
        {0|6|ignore|0|0|abs||D < 6mm ignored after meshing; geometry is not modified}
        {6|9|washer|8|2|abs|4,6|6mm < D <= 9mm}
        {9|13|washer|10|2|abs|4,6|9mm < D <= 13mm}
        {13|20|washer|12|2|abs|6,8|13mm < D <= 20mm}
        {20|30|washer|16|2|abs|8,8|20mm < D <= 30mm}
        {30|999|keep|0|0|abs||D > 30mm no special handling}
    } "\n"]
}

proc ::BatchMeshWasher::defaultMeshRulesText {} {
    return [join {
        {# Sheet-metal BatchMesh defaults.}
        {# Values are read by modules/batch_mesh_washer.tcl and can be changed in the UI.}
        {key|value|note}
        {elem_size|5.0|target shell element size}
        {min_elem_size|2.5|minimum shell element size}
        {max_elem_size|8.0|maximum shell element size}
        {params_generate_mode|shell|generic, scale, midmesh, shell, solid}
        {feature_angle|30|feature angle used by washer generation}
        {batchtempfilesmode|1|use temporary criteria/parameter files}
        {batch_by_component|0|0 is faster; 1 gives per-component BatchMesh progress}
        {surface_batch_size|1|number of surfaces per BatchMesh call; 1 keeps Tk most responsive}
        {hole_min_dia|6.0|minimum hole diameter for washer detection; smaller holes are ignored without geometry edits}
        {hole_max_dia|30.0|maximum hole diameter for washer detection}
        {performance_mode|0|reserved; UI-safe mode keeps HyperMesh/Tk messages enabled}
        {washer_progress_step|10|update washer progress every N holes}
        {washer_batch_mode|1|group holes with identical washer rules into fewer HyperMesh commands}
        {washer_batch_size|80|maximum hole seed nodes per washer command when batch mode is enabled}
        {no_geomcleanup|1|do not modify geometry during BatchMesh}
        {no_washer|1|disable BatchMesh default washer; Tcl rules create washers later}
        {no_remove_holes|1|keep geometry unchanged during BatchMesh}
    } "\n"]
}

proc ::BatchMeshWasher::ensureConfigFiles {} {
    variable RULE_FILE
    variable MESH_RULE_FILE
    if {![file exists $RULE_FILE]} {
        ::HWFlow::writeTextFile $RULE_FILE [::BatchMeshWasher::defaultWasherRulesText]
    }
    if {![file exists $MESH_RULE_FILE]} {
        ::HWFlow::writeTextFile $MESH_RULE_FILE [::BatchMeshWasher::defaultMeshRulesText]
    }
}

proc ::BatchMeshWasher::msg {text} {
    variable ui
    set line "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] BatchMeshWasher: $text"
    if {![info exists ui(VERBOSE)] || $ui(VERBOSE)} {
        puts $line
    }
    catch {hm_usermessage $text}
    if {[llength [info commands ::HWFlow::progressAppend]] > 0} {
        catch {::HWFlow::progressAppend "BatchMeshWasher: $text"}
    }
}

proc ::BatchMeshWasher::beginPerformanceMode {} {
    return
}

proc ::BatchMeshWasher::endPerformanceMode {} {
    catch {update idletasks}
}

proc ::BatchMeshWasher::stateKeys {} {
    return {
        ELEM_SIZE MIN_ELEM_SIZE MAX_ELEM_SIZE PARAMS_GENERATE_MODE FEATURE_ANGLE
        BATCH_TEMP_FILES_MODE NO_WASHER NO_REMOVE_HOLES
        NO_GEOMCLEANUP HOLE_MIN_DIA HOLE_MAX_DIA BATCH_BY_COMPONENT
        SURFACE_BATCH_SIZE PERFORMANCE_MODE WASHER_PROGRESS_STEP
        WASHER_BATCH_MODE WASHER_BATCH_SIZE
        RIGID_SPIDER LOCAL_COORDINATE_SYSTEM VERBOSE
    }
}

proc ::BatchMeshWasher::loadMeshRuleFile {} {
    variable MESH_RULE_FILE
    variable ui
    if {![file exists $MESH_RULE_FILE]} {
        return
    }
    foreach raw [split [::HWFlow::readTextFile $MESH_RULE_FILE] "\n"] {
        set line [string trim $raw]
        if {$line eq "" || [string index $line 0] eq "#"} { continue }
        set cols [split $line "|"]
        if {[llength $cols] < 2} { continue }
        set key [string tolower [string trim [lindex $cols 0]]]
        set val [string trim [lindex $cols 1]]
        switch -- $key {
            elem_size { set ui(ELEM_SIZE) $val }
            min_elem_size { set ui(MIN_ELEM_SIZE) $val }
            max_elem_size { set ui(MAX_ELEM_SIZE) $val }
            params_generate_mode { set ui(PARAMS_GENERATE_MODE) $val }
            feature_angle { set ui(FEATURE_ANGLE) $val }
            batchtempfilesmode { set ui(BATCH_TEMP_FILES_MODE) $val }
            batch_by_component { set ui(BATCH_BY_COMPONENT) $val }
            surface_batch_size { set ui(SURFACE_BATCH_SIZE) $val }
            hole_min_dia { set ui(HOLE_MIN_DIA) $val }
            hole_max_dia { set ui(HOLE_MAX_DIA) $val }
            performance_mode { set ui(PERFORMANCE_MODE) $val }
            washer_progress_step { set ui(WASHER_PROGRESS_STEP) $val }
            washer_batch_mode { set ui(WASHER_BATCH_MODE) $val }
            washer_batch_size { set ui(WASHER_BATCH_SIZE) $val }
            no_geomcleanup { set ui(NO_GEOMCLEANUP) $val }
            no_washer { set ui(NO_WASHER) $val }
            no_remove_holes { set ui(NO_REMOVE_HOLES) $val }
        }
    }
}

proc ::BatchMeshWasher::loadState {} {
    variable DEFAULTS
    variable ui
    ::BatchMeshWasher::ensureConfigFiles
    foreach key [::BatchMeshWasher::stateKeys] {
        set ui($key) $DEFAULTS($key)
    }
    ::BatchMeshWasher::loadMeshRuleFile
    set state [::HWFlow::loadState batch_mesh_washer]
    foreach key [::BatchMeshWasher::stateKeys] {
        if {[dict exists $state $key]} {
            set ui($key) [dict get $state $key]
        }
    }
}

proc ::BatchMeshWasher::saveState {} {
    variable ui
    set state [dict create]
    foreach key [::BatchMeshWasher::stateKeys] {
        if {[info exists ui($key)]} {
            dict set state $key $ui($key)
        }
    }
    ::HWFlow::saveState batch_mesh_washer $state
}

proc ::BatchMeshWasher::savePanelState {} {
    ::BatchMeshWasher::saveState
}

proc ::BatchMeshWasher::ruleFile {} {
    variable RULE_FILE
    return $RULE_FILE
}

proc ::BatchMeshWasher::loadRules {} {
    variable RULE_FILE
    variable rules
    ::BatchMeshWasher::ensureConfigFiles
    set rules {}
    set header {}
    foreach raw [split [::HWFlow::readTextFile $RULE_FILE] "\n"] {
        set line [string trim $raw]
        if {$line eq "" || [string index $line 0] eq "#"} { continue }
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
        if {![dict exists $row hole_dia_min] || ![dict exists $row hole_dia_max]} {
            continue
        }
        lappend rules $row
    }
    return $rules
}

proc ::BatchMeshWasher::ruleForDiameter {diameter} {
    variable rules
    foreach rule $rules {
        set min [dict get $rule hole_dia_min]
        set max [dict get $rule hole_dia_max]
        if {![string is double -strict $min] || ![string is double -strict $max]} {
            continue
        }
        set action ""
        if {[dict exists $rule action]} {
            set action [string tolower [dict get $rule action]]
        }
        if {$action in {ignore skip delete} && double($min) == 0.0} {
            if {$diameter < double($max)} {
                return $rule
            }
            continue
        }
        if {$diameter > double($min) && $diameter <= double($max)} {
            return $rule
        }
    }
    return ""
}

proc ::BatchMeshWasher::ruleKey {rule} {
    set parts {}
    foreach key {action hole_density washer_layers width_mode widths} {
        if {[dict exists $rule $key]} {
            lappend parts [dict get $rule $key]
        }
    }
    return [join $parts "|"]
}

proc ::BatchMeshWasher::splitNumberList {text} {
    set out {}
    foreach item [split [string map {";" "," " " ","} $text] ","] {
        set v [string trim $item]
        if {$v ne "" && [string is double -strict $v]} {
            lappend out $v
        }
    }
    return $out
}

proc ::BatchMeshWasher::pickComponents {} {
    variable ui
    catch {*clearmark comps 1}
    *createmarkpanel comps 1 [::HWFlow::txt "选择钣金中面/壳网格组件" "Select sheet-metal midsurface/shell components"]
    set comps [hm_getmark comps 1]
    catch {*clearmark comps 1}
    set ui(selectedComps) [::BatchMeshWasher::uniq $comps]
    if {[llength $ui(selectedComps)] == 0} {
        set ui(selectedText) [::HWFlow::txt "未选择组件" "No components selected"]
    } else {
        set ui(selectedText) [::HWFlow::txt "已选择 [llength $ui(selectedComps)] 个组件" "Selected [llength $ui(selectedComps)] component(s)"]
    }
    catch {raise .batch_mesh_washer}
}

proc ::BatchMeshWasher::showRules {} {
    set path [::BatchMeshWasher::ruleFile]
    set msg [::HWFlow::txt "当前 washer 规则文件：\n$path\n\n[::HWFlow::readTextFile $path]" "Current washer rule file:\n$path\n\n[::HWFlow::readTextFile $path]"]
    tk_messageBox -icon info -title [::HWFlow::txt "Sheet BatchMesh + Washer 规则" "Sheet BatchMesh + Washer Rules"] -message $msg
}

proc ::BatchMeshWasher::showPanel {} {
    variable ui
    variable VERSION
    ::BatchMeshWasher::loadState
    set ui(ok) 0
    set ui(selectedComps) ""
    set ui(selectedText) [::HWFlow::txt "未选择组件" "No components selected"]

    catch {destroy .batch_mesh_washer}
    set w .batch_mesh_washer
    ::HWFlow::createTopLevel $w
    wm title $w "[::HWFlow::txt "Sheet BatchMesh + Washer" "Sheet BatchMesh + Washer"] v$VERSION"
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "Sheet BatchMesh + Washer" "Sheet BatchMesh + Washer"] -font [::HWFlow::uiFont heading]
    grid $w.main.title -row 0 -column 0 -columnspan 4 -sticky w -pady {0 8}

    labelframe $w.main.sel -text [::HWFlow::txt "1. 组件选择" "1. Component Selection"] -padx 8 -pady 8
    grid $w.main.sel -row 1 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    button $w.main.sel.pick -text [::HWFlow::txt "选择/重选组件" "Pick / Repick Components"] -width 22 -command "::BatchMeshWasher::pickComponents"
    label $w.main.sel.info -textvariable ::BatchMeshWasher::ui(selectedText) -width 64 -anchor w
    grid $w.main.sel.pick -row 0 -column 0 -sticky w -padx {0 8}
    grid $w.main.sel.info -row 0 -column 1 -sticky w

    labelframe $w.main.mesh -text [::HWFlow::txt "2. BatchMesh 参数" "2. BatchMesh Parameters"] -padx 8 -pady 8
    grid $w.main.mesh -row 2 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    set fields {
        {ELEM_SIZE "目标单元尺寸" "Element size"}
        {MIN_ELEM_SIZE "最小单元尺寸" "Minimum element size"}
        {MAX_ELEM_SIZE "最大单元尺寸" "Maximum element size"}
        {PARAMS_GENERATE_MODE "参数模式" "Parameter mode"}
        {FEATURE_ANGLE "Washer 特征角" "Washer feature angle"}
        {HOLE_MIN_DIA "washer 最小孔径 D" "Washer min hole D"}
        {HOLE_MAX_DIA "washer 最大孔径 D" "Washer max hole D"}
        {SURFACE_BATCH_SIZE "surface 分块数量" "Surface batch size"}
        {WASHER_PROGRESS_STEP "washer 进度步长" "Washer progress step"}
        {WASHER_BATCH_SIZE "washer 批量孔数" "Washer batch size"}
    }
    set i 0
    foreach item $fields {
        set key [lindex $item 0]
        set label [::HWFlow::txt [lindex $item 1] [lindex $item 2]]
        set r [expr {$i / 2}]
        set c [expr {($i % 2) * 2}]
        label $w.main.mesh.l_$key -text $label -anchor w
        entry $w.main.mesh.e_$key -textvariable ::BatchMeshWasher::ui($key) -width 16
        grid $w.main.mesh.l_$key -row $r -column $c -sticky w -padx {0 6} -pady 2
        grid $w.main.mesh.e_$key -row $r -column [expr {$c+1}] -sticky w -padx {0 18} -pady 2
        incr i
    }

    labelframe $w.main.opt -text [::HWFlow::txt "3. 选项" "3. Options"] -padx 8 -pady 8
    grid $w.main.opt -row 3 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    checkbutton $w.main.opt.bycomp -text [::HWFlow::txt "按组件分批网格划分并更新进度" "Mesh by component and update progress"] -variable ::BatchMeshWasher::ui(BATCH_BY_COMPONENT)
    checkbutton $w.main.opt.wbatch -text [::HWFlow::txt "按相同规则批量创建 washer" "Batch-create washers with identical rules"] -variable ::BatchMeshWasher::ui(WASHER_BATCH_MODE)
    checkbutton $w.main.opt.spider -text [::HWFlow::txt "washer 同时创建 rigid spider" "Create rigid spider with washer"] -variable ::BatchMeshWasher::ui(RIGID_SPIDER)
    checkbutton $w.main.opt.local -text [::HWFlow::txt "创建孔平面局部坐标系" "Create hole local coordinate system"] -variable ::BatchMeshWasher::ui(LOCAL_COORDINATE_SYSTEM)
    checkbutton $w.main.opt.verbose -text [::HWFlow::txt "输出详细日志" "Verbose log"] -variable ::BatchMeshWasher::ui(VERBOSE)
    grid $w.main.opt.bycomp -row 0 -column 0 -sticky w -pady 2
    grid $w.main.opt.wbatch -row 1 -column 0 -sticky w -pady 2
    grid $w.main.opt.spider -row 2 -column 0 -sticky w -pady 2
    grid $w.main.opt.local -row 2 -column 1 -sticky w -pady 2
    grid $w.main.opt.verbose -row 3 -column 0 -sticky w -pady 2

    frame $w.btn -padx 12 -pady 10
    pack $w.btn -fill x
    button $w.btn.back -text [::HWFlow::txt "返回主页" "Back to Home"] -width 12 -command "::BatchMeshWasher::savePanelState; set ::BatchMeshWasher::ui(ok) 0; catch {destroy .batch_mesh_washer}; catch {::HWToolkit::showHome}"
    button $w.btn.rules -text [::HWFlow::txt "查看规则" "View Rules"] -width 12 -command "::BatchMeshWasher::showRules"
    button $w.btn.save -text [::HWFlow::txt "保存配置" "Save Config"] -width 12 -command "::BatchMeshWasher::savePanelState"
    button $w.btn.start -text [::HWFlow::txt "开始网格+washer" "Start Mesh + Washer"] -width 18 -command "::BatchMeshWasher::acceptPanel"
    pack $w.btn.back $w.btn.rules $w.btn.save $w.btn.start -side right -padx 4

    bind $w <Escape> "::BatchMeshWasher::savePanelState; set ::BatchMeshWasher::ui(ok) 0; destroy .batch_mesh_washer"
    wm protocol $w WM_DELETE_WINDOW "::BatchMeshWasher::savePanelState; set ::BatchMeshWasher::ui(ok) 0; destroy .batch_mesh_washer"

    update idletasks
    set sw [winfo screenwidth $w]
    set sh [winfo screenheight $w]
    set ww [winfo reqwidth $w]
    set wh [winfo reqheight $w]
    wm geometry $w +[expr {($sw-$ww)/2}]+[expr {($sh-$wh)/2}]
    tkwait window $w
    return $ui(ok)
}

proc ::BatchMeshWasher::acceptPanel {} {
    variable ui
    if {[llength $ui(selectedComps)] == 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Sheet BatchMesh + Washer" "Sheet BatchMesh + Washer"] -message [::HWFlow::txt "请先选择组件。" "Pick components first."]
        return
    }
    foreach key {ELEM_SIZE MIN_ELEM_SIZE MAX_ELEM_SIZE FEATURE_ANGLE HOLE_MIN_DIA HOLE_MAX_DIA} {
        if {![string is double -strict $ui($key)]} {
            tk_messageBox -icon warning -title [::HWFlow::txt "Sheet BatchMesh + Washer" "Sheet BatchMesh + Washer"] -message "$key must be a number."
            return
        }
    }
    foreach key {SURFACE_BATCH_SIZE WASHER_PROGRESS_STEP WASHER_BATCH_SIZE} {
        if {![string is integer -strict $ui($key)]} {
            tk_messageBox -icon warning -title [::HWFlow::txt "Sheet BatchMesh + Washer" "Sheet BatchMesh + Washer"] -message "$key must be an integer."
            return
        }
    }
    foreach key {BATCH_BY_COMPONENT WASHER_BATCH_MODE RIGID_SPIDER LOCAL_COORDINATE_SYSTEM VERBOSE} {
        if {![string is integer -strict $ui($key)]} {
            tk_messageBox -icon warning -title [::HWFlow::txt "Sheet BatchMesh + Washer" "Sheet BatchMesh + Washer"] -message "$key must be 0 or 1."
            return
        }
    }
    if {$ui(ELEM_SIZE) <= 0 || $ui(MIN_ELEM_SIZE) <= 0 || $ui(MAX_ELEM_SIZE) <= 0 || $ui(MIN_ELEM_SIZE) > $ui(MAX_ELEM_SIZE)} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Sheet BatchMesh + Washer" "Sheet BatchMesh + Washer"] -message [::HWFlow::txt "网格尺寸参数无效。" "Invalid mesh size parameters."]
        return
    }
    if {$ui(HOLE_MIN_DIA) < 0 || $ui(HOLE_MAX_DIA) <= $ui(HOLE_MIN_DIA)} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Sheet BatchMesh + Washer" "Sheet BatchMesh + Washer"] -message [::HWFlow::txt "孔径参数无效。" "Invalid hole diameter parameters."]
        return
    }
    if {$ui(WASHER_PROGRESS_STEP) < 1} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Sheet BatchMesh + Washer" "Sheet BatchMesh + Washer"] -message [::HWFlow::txt "washer 进度步长必须大于 0。" "Washer progress step must be greater than 0."]
        return
    }
    if {$ui(SURFACE_BATCH_SIZE) < 1} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Sheet BatchMesh + Washer" "Sheet BatchMesh + Washer"] -message [::HWFlow::txt "surface 分块数量必须大于 0。" "Surface batch size must be greater than 0."]
        return
    }
    if {$ui(WASHER_BATCH_SIZE) < 1} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Sheet BatchMesh + Washer" "Sheet BatchMesh + Washer"] -message [::HWFlow::txt "washer 批量孔数必须大于 0。" "Washer batch size must be greater than 0."]
        return
    }
    ::BatchMeshWasher::saveState
    set ui(ok) 1
    destroy .batch_mesh_washer
}

proc ::BatchMeshWasher::uniq {lst} {
    array set seen {}
    foreach x $lst {
        if {$x ne ""} { set seen($x) 1 }
    }
    set out [array names seen]
    if {[catch {set out [lsort -integer $out]}]} {
        set out [lsort $out]
    }
    return $out
}

proc ::BatchMeshWasher::markComponents {markId compIds} {
    catch {*clearmark comps $markId}
    if {[llength $compIds] == 0} { return 0 }
    if {[catch {eval *createmark comps $markId $compIds}]} {
        catch {eval *createmark components $markId $compIds}
    }
    return 1
}

proc ::BatchMeshWasher::componentSurfaces {compId} {
    set ids {}
    foreach etype {surfs surfaces} {
        catch {*clearmark $etype 2}
        if {![catch {*createmark $etype 2 "by comp id" $compId}]} {
            catch {set ids [hm_getmark $etype 2]}
        }
        catch {*clearmark $etype 2}
        if {[llength $ids] > 0} {
            return [::BatchMeshWasher::uniq $ids]
        }
    }
    return {}
}

proc ::BatchMeshWasher::markSurfaces {markId surfIds} {
    catch {*clearmark surfs $markId}
    if {[llength $surfIds] == 0} { return 0 }
    if {[catch {eval *createmark surfs $markId $surfIds}]} {
        catch {eval *createmark surfaces $markId $surfIds}
    }
    return 1
}

proc ::BatchMeshWasher::buildBatchMeshStrings {} {
    variable ui
    set s [join [list \
        "elem_size = $ui(ELEM_SIZE)" \
        "min_elem_size = $ui(MIN_ELEM_SIZE)" \
        "max_elem_size = $ui(MAX_ELEM_SIZE)" \
        "params_generate_mode = $ui(PARAMS_GENERATE_MODE)" \
        "no_geomcleanup = $ui(NO_GEOMCLEANUP)" \
        "no_washer = $ui(NO_WASHER)" \
        "no_remove_holes = $ui(NO_REMOVE_HOLES)"] " "]
    set temp "batchtempfilesmode = $ui(BATCH_TEMP_FILES_MODE)"
    return [list $s $temp]
}

proc ::BatchMeshWasher::createBatchMeshStringArray {} {
    set strings [::BatchMeshWasher::buildBatchMeshStrings]
    if {[catch {*createstringarray 2 [lindex $strings 0] [lindex $strings 1]} err]} {
        error "createstringarray failed: $err"
    }
}

proc ::BatchMeshWasher::runBatchMeshOnSurfaces {surfIds} {
    variable stat
    set surfIds [::BatchMeshWasher::uniq $surfIds]
    if {[llength $surfIds] == 0} { return 0 }
    ::BatchMeshWasher::markSurfaces 1 $surfIds
    ::BatchMeshWasher::createBatchMeshStringArray
    catch {::HWFlow::progressForceVisible}
    catch {update idletasks}
    catch {update}
    catch {after 200}
    if {[catch {*hm_batchmesh2 surfs 1 1 2 "dummy" "dummy"} err]} {
        if {[catch {*hm_batchmesh2 surfaces 1 1 2 "dummy" "dummy"} err2]} {
            error "BatchMesh surfaces failed: $err / $err2"
        }
    }
    incr stat(meshBatches)
    incr stat(meshSurfaces) [llength $surfIds]
    catch {*clearmark surfs 1}
    catch {*clearmark surfaces 1}
    return 1
}

proc ::BatchMeshWasher::surfaceBatchSize {} {
    variable ui
    set size 1
    if {[info exists ui(SURFACE_BATCH_SIZE)] && [string is integer -strict $ui(SURFACE_BATCH_SIZE)] && $ui(SURFACE_BATCH_SIZE) > 0} {
        set size $ui(SURFACE_BATCH_SIZE)
    }
    return $size
}

proc ::BatchMeshWasher::runBatchMeshSurfaceChunks {surfIds {progressOpened 0} {startPct 15.0} {endPct 55.0} {label ""}} {
    set surfIds [::BatchMeshWasher::uniq $surfIds]
    set totalSurfs [llength $surfIds]
    if {$totalSurfs == 0} { return 0 }
    set batchSize [::BatchMeshWasher::surfaceBatchSize]
    set totalChunks [expr {int(ceil($totalSurfs / double($batchSize)))}]
    set chunkIndex 0
    for {set i 0} {$i < $totalSurfs} {incr i $batchSize} {
        incr chunkIndex
        set chunk [lrange $surfIds $i [expr {$i + $batchSize - 1}]]
        if {$progressOpened} {
            set pct [expr {double($startPct) + (double($endPct) - double($startPct)) * ($chunkIndex - 1) / double($totalChunks)}]
            set detail [::HWFlow::txt "surface 分块 $chunkIndex/$totalChunks，当前 surfaces=[llength $chunk]，总 surfaces=$totalSurfs。每个分块执行期间窗口可能短暂无响应。" "surface batch $chunkIndex/$totalChunks, current surfaces=[llength $chunk], total surfaces=$totalSurfs. The window may be briefly unresponsive during each batch."]
            if {$label ne ""} {
                set detail "$label | $detail"
            }
            catch {::HWFlow::progressUpdate $pct [::HWFlow::txt "正在执行 BatchMesh" "Running BatchMesh"] $detail 1}
        }
        ::BatchMeshWasher::runBatchMeshOnSurfaces $chunk
        catch {update idletasks}
        catch {update}
        if {[llength [info commands ::HWFlow::progressCancelled]] > 0 && [::HWFlow::progressCancelled]} {
            error [::HWFlow::txt "用户取消了执行。" "Run cancelled by user."]
        }
    }
    if {$progressOpened} {
        catch {::HWFlow::progressUpdate $endPct [::HWFlow::txt "BatchMesh 已完成" "BatchMesh finished"] [::HWFlow::txt "已完成 surface 分块：$totalChunks" "Completed surface batches: $totalChunks"] 1}
    }
    return 1
}

proc ::BatchMeshWasher::runBatchMeshOnComponents {compIds {progressOpened 0} {startPct 15.0} {endPct 55.0}} {
    variable ui
    variable stat
    if {[llength $compIds] == 0} { return 0 }
    set surfIds {}
    foreach compId $compIds {
        foreach sid [::BatchMeshWasher::componentSurfaces $compId] {
            lappend surfIds $sid
        }
    }
    if {[llength $surfIds] > 0} {
        return [::BatchMeshWasher::runBatchMeshSurfaceChunks $surfIds $progressOpened $startPct $endPct ""]
    }
    ::BatchMeshWasher::markComponents 1 $compIds
    ::BatchMeshWasher::createBatchMeshStringArray
    catch {::HWFlow::progressForceVisible}
    catch {update idletasks}
    catch {update}
    catch {after 200}
    if {[catch {*hm_batchmesh2 comps 1 1 2 "dummy" "dummy"} err]} {
        if {[catch {*hm_batchmesh2 components 1 1 2 "dummy" "dummy"} err2]} {
            error "BatchMesh failed: $err / $err2"
        }
    }
    incr stat(meshBatches)
    catch {*clearmark comps 1}
    return 1
}

proc ::BatchMeshWasher::nodeXYZ {nodeId} {
    set xyz {}
    if {![catch {set x [hm_getvalue nodes id=$nodeId dataname=x]}] &&
        ![catch {set y [hm_getvalue nodes id=$nodeId dataname=y]}] &&
        ![catch {set z [hm_getvalue nodes id=$nodeId dataname=z]}]} {
        return [list $x $y $z]
    }
    if {![catch {set xyz [hm_nodevalue $nodeId]}] && [llength $xyz] >= 3} {
        return [lrange $xyz 0 2]
    }
    return ""
}

proc ::BatchMeshWasher::diameterFromNodes {nodes} {
    set pts {}
    foreach n $nodes {
        set p [::BatchMeshWasher::nodeXYZ $n]
        if {[llength $p] >= 3} { lappend pts $p }
    }
    if {[llength $pts] < 3} { return 0.0 }
    set cx 0.0; set cy 0.0; set cz 0.0
    foreach p $pts {
        set cx [expr {$cx + double([lindex $p 0])}]
        set cy [expr {$cy + double([lindex $p 1])}]
        set cz [expr {$cz + double([lindex $p 2])}]
    }
    set npts [llength $pts]
    set cx [expr {$cx / $npts}]
    set cy [expr {$cy / $npts}]
    set cz [expr {$cz / $npts}]
    set sumR 0.0
    foreach p $pts {
        set dx [expr {double([lindex $p 0]) - $cx}]
        set dy [expr {double([lindex $p 1]) - $cy}]
        set dz [expr {double([lindex $p 2]) - $cz}]
        set sumR [expr {$sumR + sqrt($dx*$dx + $dy*$dy + $dz*$dz)}]
    }
    return [expr {2.0 * $sumR / $npts}]
}

proc ::BatchMeshWasher::extractNodesFromHoleRecord {record} {
    set out {}
    foreach item $record {
        if {[llength $item] > 1} {
            foreach n [::BatchMeshWasher::extractNodesFromHoleRecord $item] {
                lappend out $n
            }
        } elseif {[string is integer -strict $item] && $item > 0} {
            lappend out $item
        }
    }
    return [::BatchMeshWasher::uniq $out]
}

proc ::BatchMeshWasher::nodesFromHmHole {holeRec} {
    if {[llength $holeRec] >= 2} {
        set nodes [lindex $holeRec 1]
        set clean {}
        foreach n $nodes {
            if {[string is integer -strict $n] && $n > 0} {
                lappend clean $n
            }
        }
        if {[llength $clean] >= 3} {
            return [::BatchMeshWasher::uniq $clean]
        }
    }
    return [::BatchMeshWasher::extractNodesFromHoleRecord $holeRec]
}

proc ::BatchMeshWasher::detectHolesForComponents {compIds} {
    variable ui
    if {[llength $compIds] == 0} { return {} }
    ::BatchMeshWasher::markComponents 1 $compIds
    set holesRaw {}
    if {[catch {set holesRaw [hm_ce_gethmholes 1 $ui(HOLE_MAX_DIA) $ui(HOLE_MIN_DIA) 0 0 0]} err]} {
        catch {*clearmark comps 1}
        error "hm_ce_gethmholes failed: $err"
    }
    catch {*clearmark comps 1}
    set holes {}
    foreach compRec $holesRaw {
        if {[llength $compRec] < 2} {
            continue
        }
        set compId [lindex $compRec 0]
        foreach holeRec [lrange $compRec 1 end] {
            set nodes [::BatchMeshWasher::nodesFromHmHole $holeRec]
            if {[llength $nodes] < 3} { continue }
            set dia [::BatchMeshWasher::diameterFromNodes $nodes]
            if {$dia <= 0.0} { continue }
            lappend holes [dict create compId $compId diameter $dia nodes $nodes raw $holeRec]
        }
    }
    return $holes
}

proc ::BatchMeshWasher::washerStringsForRule {rule} {
    set layers [dict get $rule washer_layers]
    set density [dict get $rule hole_density]
    set mode [string tolower [dict get $rule width_mode]]
    set widths [::BatchMeshWasher::splitNumberList [dict get $rule widths]]
    if {![string is integer -strict $layers] || $layers <= 0 || ![string is integer -strict $density] || $density <= 0} {
        return ""
    }
    if {[llength $widths] == 0} {
        return ""
    }
    while {[llength $widths] < $layers} {
        lappend widths [lindex $widths end]
    }
    set widthFlag [expr {$mode eq "abs" ? 1 : 0}]
    set uniform 1
    if {$layers > 1} {
        for {set i 1} {$i < $layers} {incr i} {
            if {[lindex $widths $i] ne [lindex $widths 0]} {
                set uniform 0
                break
            }
        }
    }
    set strings [list "layer_number = $layers uniform_layers = $uniform hole_density = $density"]
    if {$uniform} {
        lappend strings "$widthFlag [lindex $widths 0]"
    } else {
        for {set i 0} {$i < $layers} {incr i} {
            lappend strings "$widthFlag [lindex $widths $i]"
        }
    }
    return $strings
}

proc ::BatchMeshWasher::createWasherStringArray {strings} {
    set nstr [llength $strings]
    set cmd [list *createstringarray $nstr]
    foreach s $strings { lappend cmd $s }
    if {[catch {eval $cmd} err]} {
        error $err
    }
    return $nstr
}

proc ::BatchMeshWasher::holeSeedNode {hole} {
    set nodes [dict get $hole nodes]
    if {[llength $nodes] == 0} {
        return ""
    }
    return [lindex $nodes 0]
}

proc ::BatchMeshWasher::washerBatchSize {} {
    variable ui
    set size 80
    if {[info exists ui(WASHER_BATCH_SIZE)] && [string is integer -strict $ui(WASHER_BATCH_SIZE)] && $ui(WASHER_BATCH_SIZE) > 0} {
        set size $ui(WASHER_BATCH_SIZE)
    }
    return $size
}

proc ::BatchMeshWasher::createWasherForHole {rule hole index total {progressOpened 0}} {
    variable ui
    variable stat
    set nodes [dict get $hole nodes]
    if {[llength $nodes] == 0} {
        incr stat(washerFailed)
        return 0
    }
    set seedNode [lindex $nodes 0]
    set dia [dict get $hole diameter]
    set compId ""
    if {[dict exists $hole compId]} {
        set compId [dict get $hole compId]
    }
    set density [dict get $rule hole_density]
    set widths [::BatchMeshWasher::splitNumberList [dict get $rule widths]]
    set strings [::BatchMeshWasher::washerStringsForRule $rule]
    if {[llength $strings] == 0} {
        return 0
    }
    set step 10
    if {[info exists ui(WASHER_PROGRESS_STEP)] && [string is integer -strict $ui(WASHER_PROGRESS_STEP)] && $ui(WASHER_PROGRESS_STEP) > 0} {
        set step $ui(WASHER_PROGRESS_STEP)
    }
    set shouldUpdate [expr {$index == 1 || $index == $total || ($index % $step) == 0}]
    if {$shouldUpdate && $progressOpened && [llength [info commands ::HWFlow::progressUpdate]] > 0} {
        set pct [expr {75.0 + 20.0 * ($index - 1) / double($total)}]
        set detail [::HWFlow::txt "washer $index/$total | comp=$compId | D=[format %.2f $dia] | seed node=$seedNode | density=$density | widths=[join $widths ,]" "washer $index/$total | comp=$compId | D=[format %.2f $dia] | seed node=$seedNode | density=$density | widths=[join $widths ,]"]
        catch {::HWFlow::progressUpdate $pct [::HWFlow::txt "正在按标准创建 washer" "Creating washers by standard"] $detail [expr {$index == 1 || $index == $total}]}
    }
    catch {*clearmark nodes 1}
    if {[catch {*createmark nodes 1 $seedNode} err]} {
        incr stat(washerFailed)
        ::BatchMeshWasher::msg [::HWFlow::txt "washer 节点打 mark 失败：$err" "Failed to mark washer nodes: $err"]
        return 0
    }
    if {[catch {set nstr [::BatchMeshWasher::createWasherStringArray $strings]} err]} {
        incr stat(washerFailed)
        ::BatchMeshWasher::msg [::HWFlow::txt "washer 参数创建失败：$err" "Failed to create washer parameter strings: $err"]
        return 0
    }
    if {[catch {*add_multi_washer_elements 1 $ui(FEATURE_ANGLE) 1 $nstr 0 0 $ui(RIGID_SPIDER) $ui(LOCAL_COORDINATE_SYSTEM)} err]} {
        incr stat(washerFailed)
        ::BatchMeshWasher::msg [::HWFlow::txt "washer 创建失败：comp=$compId D=[format %.2f $dia] seed=$seedNode，$err" "Washer creation failed: comp=$compId D=[format %.2f $dia] seed=$seedNode, $err"]
        return 0
    }
    incr stat(washerCreated)
    catch {*clearmark nodes 1}
    return 1
}

proc ::BatchMeshWasher::createWasherBatchChunk {rule holes chunkIndex totalChunks {progressOpened 0}} {
    variable ui
    variable stat

    set strings [::BatchMeshWasher::washerStringsForRule $rule]
    if {[llength $strings] == 0} {
        foreach hole $holes {
            incr stat(washerFailed)
        }
        return 0
    }

    set seedNodes {}
    set validHoles {}
    foreach hole $holes {
        set seed [::BatchMeshWasher::holeSeedNode $hole]
        if {$seed eq ""} {
            incr stat(washerFailed)
            continue
        }
        lappend seedNodes $seed
        lappend validHoles $hole
    }
    set count [llength $seedNodes]
    if {$count == 0} {
        return 0
    }

    if {$progressOpened && [llength [info commands ::HWFlow::progressUpdate]] > 0} {
        set pct [expr {75.0 + 20.0 * ($chunkIndex - 1) / double($totalChunks)}]
        set detail [::HWFlow::txt "washer 批量 $chunkIndex/$totalChunks | 本批孔数=$count | density=[dict get $rule hole_density] | widths=[dict get $rule widths]" "washer batch $chunkIndex/$totalChunks | holes=$count | density=[dict get $rule hole_density] | widths=[dict get $rule widths]"]
        catch {::HWFlow::progressUpdate $pct [::HWFlow::txt "正在批量创建 washer" "Batch-creating washers"] $detail [expr {$chunkIndex == 1 || $chunkIndex == $totalChunks}]}
    }

    catch {*clearmark nodes 1}
    if {[catch {eval *createmark nodes 1 $seedNodes} markErr]} {
        ::BatchMeshWasher::msg [::HWFlow::txt "washer 批量节点打 mark 失败，将退回逐孔：$markErr" "Washer batch node mark failed; falling back to per-hole: $markErr"]
        set idx 0
        foreach hole $validHoles {
            incr idx
            ::BatchMeshWasher::createWasherForHole $rule $hole $idx $count 0
        }
        return 0
    }

    if {[catch {set nstr [::BatchMeshWasher::createWasherStringArray $strings]} strErr]} {
        ::BatchMeshWasher::msg [::HWFlow::txt "washer 批量参数创建失败，将退回逐孔：$strErr" "Washer batch parameter creation failed; falling back to per-hole: $strErr"]
        catch {*clearmark nodes 1}
        set idx 0
        foreach hole $validHoles {
            incr idx
            ::BatchMeshWasher::createWasherForHole $rule $hole $idx $count 0
        }
        return 0
    }

    if {[catch {*add_multi_washer_elements 1 $ui(FEATURE_ANGLE) 1 $nstr 0 0 $ui(RIGID_SPIDER) $ui(LOCAL_COORDINATE_SYSTEM)} err]} {
        ::BatchMeshWasher::msg [::HWFlow::txt "washer 批量创建失败，将退回逐孔：$err" "Washer batch creation failed; falling back to per-hole: $err"]
        catch {*clearmark nodes 1}
        set idx 0
        foreach hole $validHoles {
            incr idx
            ::BatchMeshWasher::createWasherForHole $rule $hole $idx $count 0
        }
        return 0
    }

    incr stat(washerCreated) $count
    catch {*clearmark nodes 1}
    return 1
}

proc ::BatchMeshWasher::createWasherBatches {washerJobs {progressOpened 0}} {
    array set grouped {}
    array set groupRule {}
    foreach job $washerJobs {
        set hole [lindex $job 0]
        set rule [lindex $job 1]
        set key [::BatchMeshWasher::ruleKey $rule]
        lappend grouped($key) $hole
        set groupRule($key) $rule
    }

    set batchSize [::BatchMeshWasher::washerBatchSize]
    set chunks {}
    foreach key [lsort [array names grouped]] {
        set holes $grouped($key)
        set total [llength $holes]
        for {set i 0} {$i < $total} {incr i $batchSize} {
            lappend chunks [list $groupRule($key) [lrange $holes $i [expr {$i + $batchSize - 1}]]]
        }
    }

    set totalChunks [llength $chunks]
    if {$totalChunks == 0} {
        return
    }
    set chunkIndex 0
    foreach chunk $chunks {
        incr chunkIndex
        ::BatchMeshWasher::createWasherBatchChunk [lindex $chunk 0] [lindex $chunk 1] $chunkIndex $totalChunks $progressOpened
        catch {update idletasks}
        catch {update}
    }
}

proc ::BatchMeshWasher::applyWasherRules {holes {progressOpened 0}} {
    variable ui
    variable stat
    set washerJobs {}
    foreach hole $holes {
        set dia [dict get $hole diameter]
        set rule [::BatchMeshWasher::ruleForDiameter $dia]
        if {$rule eq ""} {
            incr stat(kept)
            continue
        }
        set action [string tolower [dict get $rule action]]
        switch -- $action {
            washer -
            keep_washer {
                lappend washerJobs [list $hole $rule]
                incr stat(washerHoles)
            }
            ignore -
            skip -
            delete {
                incr stat(ignoredSmall)
            }
            default {
                incr stat(kept)
            }
        }
    }
    set total [llength $washerJobs]
    if {$total == 0} {
        return
    }
    if {[info exists ui(WASHER_BATCH_MODE)] && $ui(WASHER_BATCH_MODE)} {
        ::BatchMeshWasher::createWasherBatches $washerJobs $progressOpened
        return
    }
    set index 0
    foreach job $washerJobs {
        incr index
        set hole [lindex $job 0]
        set rule [lindex $job 1]
        ::BatchMeshWasher::createWasherForHole $rule $hole $index $total $progressOpened
    }
}

proc ::BatchMeshWasher::resetStats {} {
    variable stat
    catch {array unset stat}
    array set stat {
        meshBatches 0
        meshSurfaces 0
        holes 0
        washerHoles 0
        washerCreated 0
        washerFailed 0
        ignoredSmall 0
        kept 0
    }
}

proc ::BatchMeshWasher::main {} {
    variable ui
    variable stat
    if {![::BatchMeshWasher::showPanel]} {
        return
    }
    ::BatchMeshWasher::loadRules
    ::BatchMeshWasher::resetStats

    set comps [::BatchMeshWasher::uniq $ui(selectedComps)]
    set runStart [clock milliseconds]
    set progressOpened 0
    if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
        set progressOpened [::HWFlow::progressOpen \
            [::HWFlow::txt "Sheet BatchMesh + Washer" "Sheet BatchMesh + Washer"] \
            [::HWFlow::txt "准备执行钣金网格划分..." "Preparing sheet-metal meshing..."] \
            0]
    }
    if {!$progressOpened} {
        catch {hm_usermessage [::HWFlow::txt "未能创建 Tk 进度窗口，将使用 HyperMesh 状态栏提示。" "Could not create the Tk progress window; using HyperMesh status messages."]}
    } else {
        catch {::HWFlow::progressForceVisible}
    }

    set code [catch {
        ::BatchMeshWasher::msg [::HWFlow::txt "==== Sheet BatchMesh + Washer 开始 ====" "==== Sheet BatchMesh + Washer started ===="]
        if {$progressOpened} {
            catch {::HWFlow::progressUpdate 5.0 [::HWFlow::txt "正在准备网格任务" "Preparing mesh job"] [::HWFlow::txt "组件数量：[llength $comps]；不修改几何" "Components: [llength $comps]; geometry will not be modified"] 1}
            catch {::HWFlow::progressForceVisible}
        }
        ::BatchMeshWasher::beginPerformanceMode

        if {$ui(BATCH_BY_COMPONENT)} {
            set total [llength $comps]
            set idx 0
            foreach compId $comps {
                incr idx
                set cname [::HWFlow::componentName $compId]
                set pct [expr {10.0 + 45.0 * ($idx - 1) / double($total)}]
                if {$progressOpened} {
                    catch {::HWFlow::progressUpdate $pct [::HWFlow::txt "正在执行 BatchMesh" "Running BatchMesh"] [::HWFlow::txt "组件 $idx/$total：$cname。当前 HyperMesh 命令执行期间窗口可能短暂无响应。" "Component $idx/$total: $cname. The window may be briefly unresponsive while the HyperMesh command is running."] 1}
                }
                set compStart [expr {10.0 + 45.0 * ($idx - 1) / double($total)}]
                set compEnd [expr {10.0 + 45.0 * $idx / double($total)}]
                ::BatchMeshWasher::runBatchMeshOnComponents [list $compId] $progressOpened $compStart $compEnd
                if {[llength [info commands ::HWFlow::progressCancelled]] > 0 && [::HWFlow::progressCancelled]} {
                    error [::HWFlow::txt "用户取消了执行。" "Run cancelled by user."]
                }
            }
        } else {
            if {$progressOpened} {
                catch {::HWFlow::progressUpdate 15.0 [::HWFlow::txt "正在执行 BatchMesh" "Running BatchMesh"] [::HWFlow::txt "正在处理所选组件。当前 HyperMesh 命令执行期间窗口可能短暂无响应。" "Meshing selected components. The window may be briefly unresponsive while the HyperMesh command is running."] 1}
            }
            ::BatchMeshWasher::runBatchMeshOnComponents $comps $progressOpened 15.0 55.0
            if {[llength [info commands ::HWFlow::progressCancelled]] > 0 && [::HWFlow::progressCancelled]} {
                error [::HWFlow::txt "用户取消了执行。" "Run cancelled by user."]
            }
        }

        if {$progressOpened} {
            catch {::HWFlow::progressUpdate 60.0 [::HWFlow::txt "正在识别孔" "Detecting holes"] [::HWFlow::txt "调用 hm_ce_gethmholes..." "Calling hm_ce_gethmholes..."] 1}
        }
        set holes [::BatchMeshWasher::detectHolesForComponents $comps]
        set stat(holes) [llength $holes]
        ::BatchMeshWasher::msg [::HWFlow::txt "识别到孔数量：$stat(holes)" "Detected holes: $stat(holes)"]

        if {$progressOpened} {
            catch {::HWFlow::progressUpdate 75.0 [::HWFlow::txt "正在按标准创建 washer" "Creating washers by standard"] [::HWFlow::txt "washer 候选孔：$stat(holes)" "Washer candidate holes: $stat(holes)"] 1}
        }
        ::BatchMeshWasher::applyWasherRules $holes $progressOpened

        if {$progressOpened} {
            catch {::HWFlow::progressUpdate 95.0 [::HWFlow::txt "正在刷新结果" "Refreshing results"] [::HWFlow::txt "刷新浏览器和图形窗口..." "Refreshing browser and graphics..."] 1}
        }
        ::HWFlow::refreshBrowser
    } err opts]
    ::BatchMeshWasher::endPerformanceMode

    set runMs [expr {[clock milliseconds] - $runStart}]
    if {$code} {
        if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
            catch {::HWFlow::progressClose [::HWFlow::txt "Sheet BatchMesh + Washer 执行失败。" "Sheet BatchMesh + Washer failed."] 100.0}
        }
        tk_messageBox -icon error -title [::HWFlow::txt "Sheet BatchMesh + Washer" "Sheet BatchMesh + Washer"] -message [::HWFlow::txt "执行失败：\n$err" "Run failed:\n$err"]
        return -options $opts $err
    }

    set msg [::HWFlow::txt "Sheet BatchMesh + Washer 已完成。\n组件数：[llength $comps]\nBatchMesh 批次数：$stat(meshBatches)\nBatchMesh surfaces：$stat(meshSurfaces)\n识别孔数量：$stat(holes)\n匹配 washer 孔数量：$stat(washerHoles)\nwasher 创建数量：$stat(washerCreated)\nwasher 失败数量：$stat(washerFailed)\n忽略小孔数量：$stat(ignoredSmall)\n保留/跳过孔数量：$stat(kept)\n运行时间：${runMs} ms" "Sheet BatchMesh + Washer finished.\nComponents: [llength $comps]\nBatchMesh batches: $stat(meshBatches)\nBatchMesh surfaces: $stat(meshSurfaces)\nDetected holes: $stat(holes)\nWasher-matched holes: $stat(washerHoles)\nWasher created: $stat(washerCreated)\nWasher failed: $stat(washerFailed)\nIgnored small holes: $stat(ignoredSmall)\nKept/skipped holes: $stat(kept)\nRun time: ${runMs} ms"]
    ::BatchMeshWasher::msg [::HWFlow::txt "==== 完成：组件数=[llength $comps]，BatchMesh批次=$stat(meshBatches)，surfaces=$stat(meshSurfaces)，孔=$stat(holes)，washer孔=$stat(washerHoles)，已创建=$stat(washerCreated)，失败=$stat(washerFailed)，运行时间=${runMs}ms ====" "==== Finished: components=[llength $comps], meshBatches=$stat(meshBatches), surfaces=$stat(meshSurfaces), holes=$stat(holes), washerHoles=$stat(washerHoles), created=$stat(washerCreated), failed=$stat(washerFailed), runtime=${runMs}ms ===="]
    ::BatchMeshWasher::saveState
    if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose [::HWFlow::txt "Sheet BatchMesh + Washer 已完成。" "Sheet BatchMesh + Washer finished."] 100.0}
    }
    tk_messageBox -icon info -title [::HWFlow::txt "Sheet BatchMesh + Washer" "Sheet BatchMesh + Washer"] -message $msg
}

proc ::BatchMeshWasher::run {} {
    ::BatchMeshWasher::main
}
