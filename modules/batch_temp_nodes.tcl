# ============================================================================
# Batch Temporary Nodes
# HyperMesh 2019+
#
# Create independent nodes from one XYZ coordinate triple per input line.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source -encoding utf-8 [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::BatchTempNodes {
    variable VERSION "1.0"
    variable WINDOW ".batch_temp_nodes"
    variable LAST_CREATED_NODE_IDS {}
    variable ui
    array set ui {
        status ""
    }
}

proc ::BatchTempNodes::parseCoordinates {input} {
    set points {}
    set errors {}
    set lineNumber 0
    set normalized [string map [list "\r\n" "\n" "\r" "\n" "，" ","] $input]

    foreach rawLine [split $normalized "\n"] {
        incr lineNumber
        set line [string trim $rawLine]
        if {$line eq ""} {
            continue
        }

        set fields [split $line ","]
        if {[llength $fields] != 3} {
            lappend errors [::HWFlow::txt \
                "第 $lineNumber 行：需要恰好 3 个逗号分隔的坐标。" \
                "Line $lineNumber: expected exactly 3 comma-separated coordinates."]
            continue
        }

        set point {}
        set invalid 0
        foreach field $fields axis {X Y Z} {
            set value [string trim $field]
            if {$value eq "" || ![string is double -strict $value] ||
                [regexp -nocase {^[+-]?(inf(inity)?|nan)$} $value]} {
                lappend errors [::HWFlow::txt \
                    "第 $lineNumber 行：$axis 坐标不是有效数字。" \
                    "Line $lineNumber: $axis is not a valid number."]
                set invalid 1
                break
            }
            # Keep a canonical numeric value while preserving all supported
            # finite decimal/scientific-notation inputs.
            if {[catch {set numeric [expr {double($value)}]}]} {
                lappend errors [::HWFlow::txt \
                    "第 $lineNumber 行：$axis 坐标必须是有限数值。" \
                    "Line $lineNumber: $axis must be a finite number."]
                set invalid 1
                break
            }
            lappend point $numeric
        }
        if {!$invalid} {
            lappend points $point
        }
    }

    return [dict create points $points errors $errors]
}

proc ::BatchTempNodes::deleteNodes {nodeIds} {
    if {[llength $nodeIds] == 0} {
        return 1
    }
    catch {*clearmark nodes 2}
    set code [catch {
        eval [linsert $nodeIds 0 *createmark nodes 2 "by id only"]
        *deletemark nodes 2
    } message]
    catch {*clearmark nodes 2}
    if {$code} {
        return -code error $message
    }
    catch {*redraw}
    return 1
}

proc ::BatchTempNodes::createNodes {points} {
    variable LAST_CREATED_NODE_IDS
    set created {}
    set previousSuccessfulBatch $LAST_CREATED_NODE_IDS

    foreach point $points {
        lassign $point x y z
        set previous ""
        catch {set previous [hm_latestentityid nodes]}
        if {[catch {*createnode $x $y $z 0 0 0} createError]} {
            set rollbackCode [catch {::BatchTempNodes::deleteNodes $created} rollbackError]
            set LAST_CREATED_NODE_IDS $previousSuccessfulBatch
            set message [::HWFlow::txt \
                "坐标 ($x, $y, $z) 创建失败；本批次已回滚：$createError" \
                "Failed to create ($x, $y, $z); this batch was rolled back: $createError"]
            if {$rollbackCode} {
                append message "\n" [::HWFlow::txt \
                    "警告：回滚也失败，请检查模型：$rollbackError" \
                    "Warning: rollback also failed; inspect the model: $rollbackError"]
            }
            error $message
        }
        set nodeId ""
        catch {set nodeId [hm_latestentityid nodes]}
        if {$nodeId eq "" || $nodeId == 0 || $nodeId eq $previous} {
            set rollbackCode [catch {::BatchTempNodes::deleteNodes $created} rollbackError]
            set LAST_CREATED_NODE_IDS $previousSuccessfulBatch
            set message [::HWFlow::txt \
                "节点创建命令已执行，但无法取得新节点 ID；已回滚可识别的本批节点。" \
                "The create command ran, but the new node ID could not be read; identifiable nodes from this batch were rolled back."]
            if {$rollbackCode} {
                append message "\n" [::HWFlow::txt \
                    "警告：回滚也失败，请检查模型：$rollbackError" \
                    "Warning: rollback also failed; inspect the model: $rollbackError"]
            }
            error $message
        }
        lappend created $nodeId
    }

    set LAST_CREATED_NODE_IDS $created
    if {[llength $created] > 0} {
        catch {
            eval [linsert $created 0 *createmark nodes 1 "by id only"]
            *numbersmark nodes 1 1
            *clearmark nodes 1
        }
        catch {*redraw}
    }
    return $created
}

proc ::BatchTempNodes::inputText {} {
    variable WINDOW
    if {![winfo exists $WINDOW.main.editor.text]} {
        return ""
    }
    return [$WINDOW.main.editor.text get 1.0 end-1c]
}

proc ::BatchTempNodes::setInput {value} {
    variable WINDOW
    if {![winfo exists $WINDOW.main.editor.text]} {
        return
    }
    $WINDOW.main.editor.text delete 1.0 end
    $WINDOW.main.editor.text insert 1.0 $value
    focus $WINDOW.main.editor.text
}

proc ::BatchTempNodes::showValidation {} {
    variable ui
    set parsed [::BatchTempNodes::parseCoordinates [::BatchTempNodes::inputText]]
    set errors [dict get $parsed errors]
    set count [llength [dict get $parsed points]]
    if {[llength $errors] > 0} {
        set ui(status) [::HWFlow::txt "校验失败：[llength $errors] 处错误" "Validation failed: [llength $errors] error(s)"]
        tk_messageBox -icon warning -title [::HWFlow::txt "坐标校验" "Coordinate Validation"] \
            -message [join $errors "\n"]
        return 0
    }
    if {$count == 0} {
        set ui(status) [::HWFlow::txt "请输入至少一行坐标。" "Enter at least one coordinate row."]
        return 0
    }
    set ui(status) [::HWFlow::txt "校验通过：$count 个节点待创建" "Valid: $count node(s) ready"]
    return 1
}

proc ::BatchTempNodes::createFromInput {} {
    variable ui
    set parsed [::BatchTempNodes::parseCoordinates [::BatchTempNodes::inputText]]
    set errors [dict get $parsed errors]
    set points [dict get $parsed points]
    if {[llength $errors] > 0} {
        set ui(status) [::HWFlow::txt "未创建：请先修正输入。" "Nothing created: fix the input first."]
        tk_messageBox -icon warning -title [::HWFlow::txt "输入格式错误" "Invalid Input"] -message [join $errors "\n"]
        return {}
    }
    if {[llength $points] == 0} {
        set ui(status) [::HWFlow::txt "未创建：请输入至少一行坐标。" "Nothing created: enter at least one coordinate row."]
        return {}
    }

    if {[catch {set created [::BatchTempNodes::createNodes $points]} message]} {
        set ui(status) [::HWFlow::txt "创建失败，本批次已回滚。" "Creation failed; this batch was rolled back."]
        tk_messageBox -icon error -title [::HWFlow::txt "批量添加临时节点" "Batch Temporary Nodes"] -message $message
        return {}
    }
    set ui(status) [::HWFlow::txt "已创建 [llength $created] 个节点，可撤销本批次。" "Created [llength $created] node(s); this batch can be undone."]
    return $created
}

proc ::BatchTempNodes::undoLast {} {
    variable LAST_CREATED_NODE_IDS
    variable ui
    if {[llength $LAST_CREATED_NODE_IDS] == 0} {
        set ui(status) [::HWFlow::txt "没有可撤销的节点批次。" "There is no node batch to undo."]
        return 0
    }
    set count [llength $LAST_CREATED_NODE_IDS]
    if {[catch {::BatchTempNodes::deleteNodes $LAST_CREATED_NODE_IDS} message]} {
        set ui(status) [::HWFlow::txt "撤销失败。" "Undo failed."]
        tk_messageBox -icon error -title [::HWFlow::txt "撤销临时节点" "Undo Temporary Nodes"] -message $message
        return 0
    }
    set LAST_CREATED_NODE_IDS {}
    set ui(status) [::HWFlow::txt "已撤销上一批 $count 个节点。" "Undid the previous batch of $count node(s)."]
    return 1
}

proc ::BatchTempNodes::backToHome {} {
    variable WINDOW
    if {[llength [info commands ::HWFlow::backToHome]] > 0} {
        ::HWFlow::backToHome $WINDOW
    } else {
        catch {destroy $WINDOW}
    }
}

proc ::BatchTempNodes::runAction {} {
    variable VERSION
    variable WINDOW
    variable ui

    catch {destroy $WINDOW}
    set ui(status) [::HWFlow::txt "每行输入 X, Y, Z；空行会被忽略。" "Enter X, Y, Z per line; blank lines are ignored."]
    set w $WINDOW
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::windowTitle "[::HWFlow::txt "批量添加临时节点" "Batch Temporary Nodes"] v$VERSION" "Batch Temporary Nodes v$VERSION"]
    wm minsize $w 580 420

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1
    label $w.main.title -text [::HWFlow::txt "批量添加临时节点" "Batch Temporary Nodes"] -font [::HWFlow::uiFont title] -anchor w
    pack $w.main.title -fill x -pady {0 6}
    message $w.main.help -width 720 -anchor w -text [::HWFlow::txt \
        "一行对应一个节点，按 X、Y、Z 顺序使用英文逗号分隔。支持小数、负数和科学计数法；创建到当前 component。" \
        "One node per line, in X, Y, Z order separated by commas. Decimals, negatives, and scientific notation are supported; nodes are created in the current component."]
    pack $w.main.help -fill x -pady {0 8}

    frame $w.main.editor
    pack $w.main.editor -fill both -expand 1
    text $w.main.editor.text -width 72 -height 15 -wrap none -undo 1 -font [::HWFlow::uiFont fixed] \
        -yscrollcommand [list $w.main.editor.ys set] -xscrollcommand [list $w.main.editor.xs set]
    scrollbar $w.main.editor.ys -orient vertical -command [list $w.main.editor.text yview]
    scrollbar $w.main.editor.xs -orient horizontal -command [list $w.main.editor.text xview]
    grid $w.main.editor.text -row 0 -column 0 -sticky nsew
    grid $w.main.editor.ys -row 0 -column 1 -sticky ns
    grid $w.main.editor.xs -row 1 -column 0 -sticky ew
    grid rowconfigure $w.main.editor 0 -weight 1
    grid columnconfigure $w.main.editor 0 -weight 1

    label $w.main.status -textvariable ::BatchTempNodes::ui(status) -anchor w
    pack $w.main.status -fill x -pady {8 0}

    frame $w.buttons -padx 12 -pady 10
    pack $w.buttons -fill x
    button $w.buttons.back -text [::HWFlow::txt "返回主页" "Back to Home"] -width 12 -command ::BatchTempNodes::backToHome
    button $w.buttons.clear -text [::HWFlow::txt "清空" "Clear"] -width 9 -command [list ::BatchTempNodes::setInput ""]
    button $w.buttons.sample -text [::HWFlow::txt "填入示例" "Insert Sample"] -width 10 -command [list ::BatchTempNodes::setInput "0, 0, 0\n100, 25.5, -10"]
    button $w.buttons.undo -text [::HWFlow::txt "撤销上一批" "Undo Last Batch"] -width 12 -command ::BatchTempNodes::undoLast
    button $w.buttons.validate -text [::HWFlow::txt "校验" "Validate"] -width 9 -command ::BatchTempNodes::showValidation
    button $w.buttons.create -text [::HWFlow::txt "创建节点" "Create Nodes"] -width 12 -command ::BatchTempNodes::createFromInput
    pack $w.buttons.back -side left -padx {0 4}
    pack $w.buttons.clear $w.buttons.sample -side left -padx 4
    pack $w.buttons.create $w.buttons.validate $w.buttons.undo -side right -padx 4

    bind $w <Escape> ::BatchTempNodes::backToHome
    bind $w <Control-Return> ::BatchTempNodes::createFromInput
    wm protocol $w WM_DELETE_WINDOW ::BatchTempNodes::backToHome
    update idletasks
    wm geometry $w +[expr {([winfo screenwidth $w] - [winfo reqwidth $w]) / 2}]+[expr {([winfo screenheight $w] - [winfo reqheight $w]) / 2}]
    focus $w.main.editor.text
    tkwait window $w
    return ""
}
