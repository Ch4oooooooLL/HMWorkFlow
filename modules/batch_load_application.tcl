# ============================================================================
# Batch Load Application
# HyperMesh 2019+
#
# Import point/load records from text files, review point usage, and map every
# logical load point to a model node.  The final production parser is isolated
# in parseText so the UI/mapping workflow does not depend on the file format.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source -encoding utf-8 [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::BatchLoadApplication {
    variable VERSION "0.4"
    variable WINDOW ".batch_load_application"
    variable DETAIL_WINDOW ".batch_load_application_detail"
    variable RENUMBER_WINDOW ".batch_load_application_renumber"
    variable CASE_MAPPING_WINDOW ".batch_load_application_case_mapping"
    variable FILES {}
    variable POINTS [dict create]
    variable ORDER {}
    variable MAPPINGS [dict create]
    variable ROW_KEYS [dict create]
    variable PARSE_BUSY 0
    variable CASE_NAME_RULES {}
    variable CASE_NAME_RULES_LOADED 0
    variable ui
    array set ui {
        status ""
        summary ""
        selected_files "尚未选择文件"
        renumber_start "2000"
        rule_keywords ""
        rule_suffix ""
    }
}

proc ::BatchLoadApplication::caseNameRulePath {} {
    return [file join [::HWFlow::configDir] batch_load_case_name_mappings.txt]
}

proc ::BatchLoadApplication::defaultCaseNameRules {} {
    # Keep the defaults deliberately narrow. Additional vehicle programmes can
    # extend the list in the module without changing the TXT parser.
    return [list \
        [dict create keywords {左转弯;左转} suffix left_turn] \
        [dict create keywords {加速} suffix acceleration]]
}

proc ::BatchLoadApplication::caseRuleKeywords {text} {
    set normalized [string map [list "，" ";" "," ";" "；" ";" "、" ";"] [string trim $text]]
    set result {}
    foreach item [split $normalized ";"] {
        set keyword [string tolower [string trim $item]]
        if {$keyword ne "" && [lsearch -exact $result $keyword] < 0} { lappend result $keyword }
    }
    return $result
}

proc ::BatchLoadApplication::validCaseRule {keywords suffix} {
    return [expr {[llength [::BatchLoadApplication::caseRuleKeywords $keywords]] > 0 &&
        [regexp {^[A-Za-z][A-Za-z0-9_]*$} [string trim $suffix]]}]
}

proc ::BatchLoadApplication::loadCaseNameRules {} {
    variable CASE_NAME_RULES
    variable CASE_NAME_RULES_LOADED
    if {$CASE_NAME_RULES_LOADED} { return $CASE_NAME_RULES }
    set CASE_NAME_RULES {}
    set path [::BatchLoadApplication::caseNameRulePath]
    if {[file exists $path]} {
        foreach raw [split [::HWFlow::readTextFile $path] "\n"] {
            set line [string trim $raw]
            if {$line eq "" || [string index $line 0] eq "#"} { continue }
            set columns [split $line "\t"]
            if {[llength $columns] < 2} { continue }
            set suffix [string trim [lindex $columns 0]]
            set keywords [string trim [join [lrange $columns 1 end] "\t"]]
            if {[::BatchLoadApplication::validCaseRule $keywords $suffix]} {
                lappend CASE_NAME_RULES [dict create keywords $keywords suffix $suffix]
            }
        }
    } else {
        set CASE_NAME_RULES [::BatchLoadApplication::defaultCaseNameRules]
    }
    set CASE_NAME_RULES_LOADED 1
    return $CASE_NAME_RULES
}

proc ::BatchLoadApplication::saveCaseNameRules {} {
    variable CASE_NAME_RULES
    set rows [list "# english_suffix<TAB>keywords (separate alternatives with semicolons)"]
    foreach rule $CASE_NAME_RULES {
        lappend rows "[dict get $rule suffix]\t[dict get $rule keywords]"
    }
    ::HWFlow::writeTextFile [::BatchLoadApplication::caseNameRulePath] [join $rows "\n"]
}

proc ::BatchLoadApplication::caseNameSuffix {description} {
    variable CASE_NAME_RULES
    ::BatchLoadApplication::loadCaseNameRules
    set haystack [string tolower [string trim $description]]
    if {$haystack eq ""} { return "" }
    foreach rule $CASE_NAME_RULES {
        foreach keyword [::BatchLoadApplication::caseRuleKeywords [dict get $rule keywords]] {
            if {[string first $keyword $haystack] >= 0} { return [dict get $rule suffix] }
        }
    }
    return ""
}

proc ::BatchLoadApplication::caseEntityName {caseName description} {
    set base [string tolower [string trim $caseName]]
    set suffix [::BatchLoadApplication::caseNameSuffix $description]
    return [expr {$suffix eq "" ? $base : "${base}_${suffix}"}]
}

proc ::BatchLoadApplication::splitFields {line} {
    set normalized [string map [list "，" "," "\t" "\t"] [string trim $line]]
    if {[string first "\t" $normalized] >= 0} {
        set fields [split $normalized "\t"]
    } elseif {[string first "," $normalized] >= 0} {
        set fields {}
        set field ""
        set quoted 0
        set length [string length $normalized]
        for {set i 0} {$i < $length} {incr i} {
            set char [string index $normalized $i]
            if {$char eq "\""} {
                if {$quoted && $i + 1 < $length && [string index $normalized [expr {$i + 1}]] eq "\""} {
                    append field "\""
                    incr i
                } else {
                    set quoted [expr {!$quoted}]
                }
            } elseif {$char eq "," && !$quoted} {
                lappend fields $field
                set field ""
            } else {
                append field $char
            }
        }
        lappend fields $field
    } else {
        set fields [regexp -all -inline {\S+} $normalized]
    }
    set result {}
    foreach field $fields { lappend result [string trim $field " \t\r\n\""] }
    return $result
}

proc ::BatchLoadApplication::trimTrailingEmptyFields {fields} {
    while {[llength $fields] > 0 && [string trim [lindex $fields end]] eq ""} {
        set fields [lrange $fields 0 end-1]
    }
    return $fields
}

proc ::BatchLoadApplication::firstNonEmptyField {fields} {
    foreach field $fields {
        set value [string trim $field]
        if {$value ne ""} { return $value }
    }
    return ""
}

proc ::BatchLoadApplication::finiteNumber {value} {
    set value [string trim $value]
    if {$value eq "" || ![string is double -strict $value] ||
        [regexp -nocase {^[+-]?(inf(inity)?|nan)$} $value]} { return 0 }
    return [expr {![catch {expr {double($value)}}]}]
}

proc ::BatchLoadApplication::looksLikeLoadRow {fields} {
    set fields [::BatchLoadApplication::trimTrailingEmptyFields $fields]
    if {[llength $fields] < 13} { return 0 }
    set tail [lrange $fields end-12 end]
    foreach index {0 1 2} {
        if {![::BatchLoadApplication::finiteNumber [lindex $tail $index]]} { return 0 }
    }
    return [expr {[string trim [lindex $tail 3]] ne "" || [string trim [lindex $tail 4]] ne ""}]
}

proc ::BatchLoadApplication::recordFromLoadTail {fields caseName caseDescription lineNumber source} {
    set fields [::BatchLoadApplication::trimTrailingEmptyFields $fields]
    if {[llength $fields] < 13} {
        error [::HWFlow::txt "第 $lineNumber 行没有完整的载荷字段。" "Line $lineNumber does not contain a complete load record."]
    }
    # CSV conversion can add a case token, a point group, or empty merged-cell
    # columns at the start.  The useful record is stable at the right edge.
    set tail [lrange $fields end-12 end]
    set values [dict create case $caseName case_description $caseDescription]
    foreach key {x y z english chinese serial time fx fy fz tx ty tz} value $tail {
        dict set values $key [string trim $value]
    }
    foreach axis {x y z} {
        if {![::BatchLoadApplication::finiteNumber [dict get $values $axis]]} {
            error [::HWFlow::txt "第 $lineNumber 行的 [string toupper $axis] 坐标无效。" "Line $lineNumber has an invalid [string toupper $axis] coordinate."]
        }
        dict set values $axis [expr {double([dict get $values $axis])}]
    }
    foreach component {fx fy fz tx ty tz} {
        if {![::BatchLoadApplication::finiteNumber [dict get $values $component]]} {
            error [::HWFlow::txt "第 $lineNumber 行的 [string toupper $component] 无效。" "Line $lineNumber has an invalid [string toupper $component] value."]
        }
        dict set values $component [expr {double([dict get $values $component])}]
    }
    dict set values source $source
    dict set values line $lineNumber
    return $values
}

proc ::BatchLoadApplication::parseText {text source {defaultCase ""} {progressStart ""} {progressEnd ""}} {
    set records {}
    set errors {}
    set contextCase ""
    set contextDescription ""
    set lineNumber 0
    set normalized [string map [list "\r\n" "\n" "\r" "\n"] $text]
    set lines [split $normalized "\n"]
    set totalLines [llength $lines]
    foreach rawLine $lines {
        incr lineNumber
        if {$progressStart ne "" && ($lineNumber == 1 || $lineNumber == $totalLines || $lineNumber % 200 == 0)} {
            set percent [expr {$progressStart + ($progressEnd - $progressStart) * $lineNumber / double($totalLines)}]
            catch {::HWFlow::progressUpdate $percent [::HWFlow::txt "正在解析载荷记录" "Parsing load records"] "$lineNumber/$totalLines" [expr {$lineNumber == 1 || $lineNumber == $totalLines}]}
        }
        set line [string trim $rawLine]
        if {$line eq "" || [regexp {^\s*[#;]} $line]} { continue }
        if {[regexp {^[,，[:space:]]+$} $line]} { continue }
        set fields [::BatchLoadApplication::splitFields $line]
        set first [::BatchLoadApplication::firstNonEmptyField $fields]
        set isLoadRow [::BatchLoadApplication::looksLikeLoadRow $fields]
        if {[regexp -nocase {^case[[:space:]]*([0-9]+)(.*)$} $first -> caseNumber remainder]} {
            set nextCase "case$caseNumber"
            if {$nextCase ne $contextCase} { set contextDescription "" }
            set contextCase $nextCase
            set remainder [string trim $remainder " \t:：-_"]
            if {!$isLoadRow} {
                set contextDescription $remainder
                continue
            }
        }
        if {$contextCase eq "" || !$isLoadRow} {
            continue
        }
        if {[catch {set record [::BatchLoadApplication::recordFromLoadTail $fields $contextCase $contextDescription $lineNumber $source]} message]} {
            lappend errors $message
        } else {
            lappend records $record
        }
    }
    return [dict create records $records errors $errors]
}

proc ::BatchLoadApplication::readInputFile {path} {
    set ch [open $path rb]
    set code [catch {read $ch} bytes]
    close $ch
    if {$code} { error $bytes }

    if {[string range $bytes 0 2] eq "\xEF\xBB\xBF"} {
        return [encoding convertfrom utf-8 [string range $bytes 3 end]]
    }
    if {[string range $bytes 0 1] eq "\xFF\xFE" && [lsearch -exact [encoding names] unicode] >= 0} {
        return [encoding convertfrom unicode [string range $bytes 2 end]]
    }
    set utf8Code [catch {encoding convertfrom utf-8 $bytes} utf8]
    if {!$utf8Code && [string first "\uFFFD" $utf8] < 0} { return $utf8 }

    foreach encodingName {cp936 gbk} {
        if {[lsearch -exact [encoding names] $encodingName] < 0} { continue }
        if {![catch {encoding convertfrom $encodingName $bytes} decoded]} { return $decoded }
    }
    if {!$utf8Code} { return $utf8 }
    error [::HWFlow::txt "无法识别文本编码：$path" "Could not detect the text encoding: $path"]
}

proc ::BatchLoadApplication::pointKey {record} {
    set en [string tolower [string trim [dict get $record english]]]
    set zh [string trim [dict get $record chinese]]
    if {$en ne ""} { return "en:$en" }
    if {$zh ne ""} { return "zh:$zh" }
    return [format "xyz:%.12g,%.12g,%.12g" [dict get $record x] [dict get $record y] [dict get $record z]]
}

proc ::BatchLoadApplication::aggregateRecords {records} {
    set points [dict create]
    set order {}
    foreach record $records {
        set key [::BatchLoadApplication::pointKey $record]
        if {![dict exists $points $key]} {
            dict set points $key [dict create \
                english [dict get $record english] chinese [dict get $record chinese] \
                x [dict get $record x] y [dict get $record y] z [dict get $record z] \
                references {} node_id ""]
            lappend order $key
        }
        set point [dict get $points $key]
        dict lappend point references $record
        dict set points $key $point
    }
    return [dict create points $points order $order]
}

proc ::BatchLoadApplication::importPaths {paths {showProgress 0}} {
    variable FILES
    variable POINTS
    variable ORDER
    variable MAPPINGS
    set records {}
    set errors {}
    set accepted {}
    set fileCount [llength $paths]
    set fileIndex 0
    if {$showProgress} {
        catch {::HWFlow::progressOpen [::HWFlow::txt "解析载荷文件" "Parse Load Files"] [::HWFlow::txt "正在准备解析..." "Preparing to parse..."] 0}
    }
    foreach path $paths {
        incr fileIndex
        set fileStart [expr {5.0 + 80.0 * ($fileIndex - 1) / double($fileCount)}]
        set fileEnd [expr {5.0 + 80.0 * $fileIndex / double($fileCount)}]
        if {$showProgress} {
            catch {::HWFlow::progressUpdate $fileStart [::HWFlow::txt "正在读取文件 $fileIndex/$fileCount" "Reading file $fileIndex/$fileCount"] [file tail $path] 1}
        }
        if {![file isfile $path]} {
            lappend errors [::HWFlow::txt "文件不存在：$path" "File does not exist: $path"]
            continue
        }
        if {[catch {set text [::BatchLoadApplication::readInputFile $path]} message]} {
            lappend errors [::HWFlow::txt "无法读取 $path：$message" "Cannot read $path: $message"]
            continue
        }
        if {$showProgress} {
            set parsed [::BatchLoadApplication::parseText $text $path "" $fileStart $fileEnd]
        } else {
            set parsed [::BatchLoadApplication::parseText $text $path]
        }
        foreach record [dict get $parsed records] { lappend records $record }
        foreach message [dict get $parsed errors] { lappend errors "[file tail $path]: $message" }
        lappend accepted [file normalize $path]
    }
    if {$showProgress} {
        catch {::HWFlow::progressUpdate 90 [::HWFlow::txt "正在汇总点位" "Aggregating points"] [::HWFlow::txt "载荷记录：[llength $records]" "Load records: [llength $records]"] 1}
    }
    set aggregated [::BatchLoadApplication::aggregateRecords $records]
    set POINTS [dict get $aggregated points]
    set ORDER [dict get $aggregated order]
    set FILES $accepted
    set MAPPINGS [dict create]
    return [dict create file_count [llength $accepted] record_count [llength $records] point_count [llength $ORDER] errors $errors]
}

proc ::BatchLoadApplication::chooseFiles {} {
    variable WINDOW
    variable FILES
    variable ui
    set paths [tk_getOpenFile -parent $WINDOW -multiple 1 \
        -title [::HWFlow::txt "选择载荷 TXT 文件" "Select load TXT files"] \
        -filetypes [list [list [::HWFlow::txt "文本文件" "Text files"] {.txt}] [list [::HWFlow::txt "所有文件" "All files"] *]]]
    if {[llength $paths] == 0} { return }
    set FILES {}
    foreach path $paths { lappend FILES [file normalize $path] }
    set ui(selected_files) [::HWFlow::txt "已选择 [llength $FILES] 个文件" "[llength $FILES] file(s) selected"]
    set ui(status) [::HWFlow::txt "文件已选择，点击“开始解析”读取内容。" "Files selected. Click Parse to read them."]
    catch {$WINDOW.main.top.parse configure -state normal}
}

proc ::BatchLoadApplication::startParsing {} {
    variable FILES
    variable PARSE_BUSY
    variable WINDOW
    variable ui
    if {$PARSE_BUSY} { return }
    if {[llength $FILES] == 0} {
        set ui(status) [::HWFlow::txt "请先选择 TXT 文件。" "Select TXT files first."]
        return
    }
    set PARSE_BUSY 1
    catch {$WINDOW.main.top.import configure -state disabled}
    catch {$WINDOW.main.top.parse configure -state disabled}
    set ui(status) [::HWFlow::txt "正在解析所选文件..." "Parsing selected files..."]
    after idle ::BatchLoadApplication::performParsing
}

proc ::BatchLoadApplication::performParsing {} {
    variable FILES
    variable PARSE_BUSY
    variable WINDOW
    variable ui
    set code [catch {set result [::BatchLoadApplication::importPaths $FILES 1]} message options]
    set PARSE_BUSY 0
    catch {$WINDOW.main.top.import configure -state normal}
    catch {$WINDOW.main.top.parse configure -state [expr {[llength $FILES] > 0 ? "normal" : "disabled"}]}
    if {$code} {
        catch {::HWFlow::progressClose [::HWFlow::txt "解析失败" "Parsing failed"] 100}
        set ui(status) [::HWFlow::txt "解析失败。" "Parsing failed."]
        tk_messageBox -parent $WINDOW -icon error -title [::HWFlow::txt "载荷文件解析" "Load File Parsing"] -message $message
        return
    }
    catch {file delete -force [::BatchLoadApplication::defaultMappingPath]}
    ::BatchLoadApplication::refreshRows
    catch {::HWFlow::progressUpdate 100 [::HWFlow::txt "解析完成" "Parsing complete"] [::HWFlow::txt "汇总 [dict get $result point_count] 个点位" "Aggregated [dict get $result point_count] point(s)"] 1}
    catch {::HWFlow::progressClose}
    set ui(status) [::HWFlow::txt \
        "已读取 [dict get $result file_count] 个文件、[dict get $result record_count] 条载荷，汇总 [dict get $result point_count] 个点位。" \
        "Read [dict get $result file_count] file(s), [dict get $result record_count] load record(s), and aggregated [dict get $result point_count] point(s)."]
    set errors [dict get $result errors]
    if {[llength $errors] > 0} {
        tk_messageBox -parent $WINDOW -icon warning -title [::HWFlow::txt "部分记录未解析" "Some records were not parsed"] -message [join $errors "\n"]
    }
}

proc ::BatchLoadApplication::displayName {value} {
    set value [string trim $value]
    return [expr {$value eq "" ? "-" : $value}]
}

proc ::BatchLoadApplication::removePointData {key} {
    variable POINTS
    variable ORDER
    variable MAPPINGS
    if {![dict exists $POINTS $key]} { return [dict create removed 0] }
    set point [dict get $POINTS $key]
    set referenceCount [llength [dict get $point references]]
    set nodeId [dict get $point node_id]
    dict unset POINTS $key
    set index [lsearch -exact $ORDER $key]
    if {$index >= 0} { set ORDER [lreplace $ORDER $index $index] }
    if {[dict exists $MAPPINGS $key]} { dict unset MAPPINGS $key }
    return [dict create removed 1 references $referenceCount node_id $nodeId point $point]
}

proc ::BatchLoadApplication::clearData {} {
    variable FILES
    variable POINTS
    variable ORDER
    variable MAPPINGS
    set counts [dict create files [llength $FILES] points [llength $ORDER] mappings [dict size $MAPPINGS]]
    set FILES {}
    set POINTS [dict create]
    set ORDER {}
    set MAPPINGS [dict create]
    return $counts
}

proc ::BatchLoadApplication::clearCurrentList {} {
    variable WINDOW
    variable ui
    variable ORDER
    variable FILES
    if {[llength $ORDER] == 0 && [llength $FILES] == 0} {
        set ui(status) [::HWFlow::txt "当前列表已经为空。" "The current list is already empty."]
        return 0
    }
    set answer [tk_messageBox -parent $WINDOW -icon warning -type yesno -default no \
        -title [::HWFlow::txt "清除当前列表" "Clear Current List"] \
        -message [::HWFlow::txt "确定清除当前文件列表、全部点位、载荷记录和映射吗？\n\n不会删除模型中的节点、Load Collector 或 Subcase。" "Clear the current file list, all points, load records, and mappings?\n\nModel nodes, Load Collectors, and Subcases will not be deleted."]]
    if {$answer ne "yes"} { return 0 }
    ::BatchLoadApplication::clearData
    catch {::BatchLoadApplication::writeMappingCsv [::BatchLoadApplication::defaultMappingPath]}
    set ui(selected_files) [::HWFlow::txt "尚未选择文件" "No files selected"]
    set ui(status) [::HWFlow::txt "当前列表已清除。" "The current list was cleared."]
    catch {$WINDOW.main.top.parse configure -state disabled}
    ::BatchLoadApplication::refreshRows
    return 1
}

proc ::BatchLoadApplication::selectedCaseRuleIndex {} {
    variable CASE_MAPPING_WINDOW
    set listbox $CASE_MAPPING_WINDOW.main.list.items
    if {![winfo exists $listbox]} { return -1 }
    set selection [$listbox curselection]
    return [expr {[llength $selection] == 1 ? int([lindex $selection 0]) : -1}]
}

proc ::BatchLoadApplication::refreshCaseRuleList {{selection -1}} {
    variable CASE_MAPPING_WINDOW
    variable CASE_NAME_RULES
    set listbox $CASE_MAPPING_WINDOW.main.list.items
    if {![winfo exists $listbox]} { return }
    $listbox delete 0 end
    foreach rule $CASE_NAME_RULES {
        $listbox insert end "[dict get $rule suffix]    <-    [dict get $rule keywords]"
    }
    if {$selection >= 0 && $selection < [llength $CASE_NAME_RULES]} {
        $listbox selection set $selection
        $listbox see $selection
    }
}

proc ::BatchLoadApplication::selectCaseRule {} {
    variable CASE_NAME_RULES
    variable ui
    set index [::BatchLoadApplication::selectedCaseRuleIndex]
    if {$index < 0 || $index >= [llength $CASE_NAME_RULES]} { return }
    set rule [lindex $CASE_NAME_RULES $index]
    set ui(rule_keywords) [dict get $rule keywords]
    set ui(rule_suffix) [dict get $rule suffix]
}

proc ::BatchLoadApplication::caseRuleFromEditor {} {
    variable ui
    set keywords [string trim $ui(rule_keywords)]
    set suffix [string tolower [string trim $ui(rule_suffix)]]
    if {![::BatchLoadApplication::validCaseRule $keywords $suffix]} {
        error [::HWFlow::txt \
            "请输入至少一个关键词；英文名称后缀只能使用英文字母、数字和下划线，且必须以字母开头。" \
            "Enter at least one keyword. The English suffix may contain only ASCII letters, digits, and underscores, and must start with a letter."]
    }
    return [dict create keywords $keywords suffix $suffix]
}

proc ::BatchLoadApplication::duplicateCaseRuleKeyword {rule {ignoredIndex -1}} {
    variable CASE_NAME_RULES
    set wanted [::BatchLoadApplication::caseRuleKeywords [dict get $rule keywords]]
    set index -1
    foreach existing $CASE_NAME_RULES {
        incr index
        if {$index == $ignoredIndex} { continue }
        foreach keyword [::BatchLoadApplication::caseRuleKeywords [dict get $existing keywords]] {
            if {[lsearch -exact $wanted $keyword] >= 0} { return $keyword }
        }
    }
    return ""
}

proc ::BatchLoadApplication::addCaseRule {} {
    variable CASE_MAPPING_WINDOW
    variable CASE_NAME_RULES
    variable ui
    if {[catch {set rule [::BatchLoadApplication::caseRuleFromEditor]} message]} {
        tk_messageBox -parent $CASE_MAPPING_WINDOW -icon warning -title [::HWFlow::txt "映射无效" "Invalid Mapping"] -message $message
        return 0
    }
    set duplicate [::BatchLoadApplication::duplicateCaseRuleKeyword $rule]
    if {$duplicate ne ""} {
        tk_messageBox -parent $CASE_MAPPING_WINDOW -icon warning -title [::HWFlow::txt "关键词重复" "Duplicate Keyword"] -message [::HWFlow::txt "关键词“$duplicate”已存在。" "Keyword '$duplicate' already exists."]
        return 0
    }
    lappend CASE_NAME_RULES $rule
    ::BatchLoadApplication::saveCaseNameRules
    ::BatchLoadApplication::refreshCaseRuleList [expr {[llength $CASE_NAME_RULES] - 1}]
    set ui(status) [::HWFlow::txt "工况名称映射已添加。" "Case-name mapping added."]
    return 1
}

proc ::BatchLoadApplication::updateCaseRule {} {
    variable CASE_MAPPING_WINDOW
    variable CASE_NAME_RULES
    variable ui
    set index [::BatchLoadApplication::selectedCaseRuleIndex]
    if {$index < 0} {
        tk_messageBox -parent $CASE_MAPPING_WINDOW -icon warning -title [::HWFlow::txt "修改映射" "Update Mapping"] -message [::HWFlow::txt "请先选择一条映射。" "Select a mapping first."]
        return 0
    }
    if {[catch {set rule [::BatchLoadApplication::caseRuleFromEditor]} message]} {
        tk_messageBox -parent $CASE_MAPPING_WINDOW -icon warning -title [::HWFlow::txt "映射无效" "Invalid Mapping"] -message $message
        return 0
    }
    set duplicate [::BatchLoadApplication::duplicateCaseRuleKeyword $rule $index]
    if {$duplicate ne ""} {
        tk_messageBox -parent $CASE_MAPPING_WINDOW -icon warning -title [::HWFlow::txt "关键词重复" "Duplicate Keyword"] -message [::HWFlow::txt "关键词“$duplicate”已存在。" "Keyword '$duplicate' already exists."]
        return 0
    }
    set CASE_NAME_RULES [lreplace $CASE_NAME_RULES $index $index $rule]
    ::BatchLoadApplication::saveCaseNameRules
    ::BatchLoadApplication::refreshCaseRuleList $index
    set ui(status) [::HWFlow::txt "工况名称映射已修改。" "Case-name mapping updated."]
    return 1
}

proc ::BatchLoadApplication::deleteCaseRule {} {
    variable CASE_MAPPING_WINDOW
    variable CASE_NAME_RULES
    variable ui
    set index [::BatchLoadApplication::selectedCaseRuleIndex]
    if {$index < 0} { return 0 }
    set rule [lindex $CASE_NAME_RULES $index]
    set answer [tk_messageBox -parent $CASE_MAPPING_WINDOW -icon question -type yesno -default no \
        -title [::HWFlow::txt "删除映射" "Delete Mapping"] \
        -message [::HWFlow::txt "删除英文后缀“[dict get $rule suffix]”的映射吗？" "Delete the mapping for suffix '[dict get $rule suffix]'?"]]
    if {$answer ne "yes"} { return 0 }
    set CASE_NAME_RULES [lreplace $CASE_NAME_RULES $index $index]
    ::BatchLoadApplication::saveCaseNameRules
    ::BatchLoadApplication::refreshCaseRuleList [expr {$index > 0 ? $index - 1 : 0}]
    set ui(rule_keywords) ""; set ui(rule_suffix) ""
    set ui(status) [::HWFlow::txt "工况名称映射已删除。" "Case-name mapping deleted."]
    return 1
}

proc ::BatchLoadApplication::moveCaseRule {offset} {
    variable CASE_NAME_RULES
    set index [::BatchLoadApplication::selectedCaseRuleIndex]
    set target [expr {$index + $offset}]
    if {$index < 0 || $target < 0 || $target >= [llength $CASE_NAME_RULES]} { return 0 }
    set rule [lindex $CASE_NAME_RULES $index]
    set CASE_NAME_RULES [lreplace $CASE_NAME_RULES $index $index]
    set CASE_NAME_RULES [linsert $CASE_NAME_RULES $target $rule]
    ::BatchLoadApplication::saveCaseNameRules
    ::BatchLoadApplication::refreshCaseRuleList $target
    return 1
}

proc ::BatchLoadApplication::restoreDefaultCaseRules {} {
    variable CASE_MAPPING_WINDOW
    variable CASE_NAME_RULES
    variable ui
    set answer [tk_messageBox -parent $CASE_MAPPING_WINDOW -icon question -type yesno -default no \
        -title [::HWFlow::txt "恢复默认映射" "Restore Default Mappings"] \
        -message [::HWFlow::txt "用内置映射替换当前列表吗？" "Replace the current list with the built-in mappings?"]]
    if {$answer ne "yes"} { return 0 }
    set CASE_NAME_RULES [::BatchLoadApplication::defaultCaseNameRules]
    ::BatchLoadApplication::saveCaseNameRules
    ::BatchLoadApplication::refreshCaseRuleList 0
    set ui(status) [::HWFlow::txt "已恢复内置工况名称映射。" "Built-in case-name mappings restored."]
    return 1
}

proc ::BatchLoadApplication::showCaseMappingDialog {} {
    variable WINDOW
    variable CASE_MAPPING_WINDOW
    variable ui
    ::BatchLoadApplication::loadCaseNameRules
    catch {destroy $CASE_MAPPING_WINDOW}
    set w $CASE_MAPPING_WINDOW
    ::HWFlow::createTopLevel $w dialog
    wm title $w [::HWFlow::windowTitle [::HWFlow::txt "工况名称映射" "Case Name Mappings"] "Case Name Mappings"]
    wm transient $w $WINDOW
    wm minsize $w 680 430
    frame $w.main -padx 12 -pady 10; pack $w.main -fill both -expand 1
    message $w.main.help -width 650 -anchor w -text [::HWFlow::txt \
        "按列表顺序对工况中文说明做关键词包含匹配。多个关键词用分号分隔。最终名称始终保留编号，例如 case14_left_turn；未命中时使用 case14。" \
        "Rules perform ordered substring matching against the case description. Separate alternative keywords with semicolons. The final name always retains its number, for example case14_left_turn; unmatched cases use case14."]
    pack $w.main.help -fill x -pady {0 8}
    frame $w.main.list; pack $w.main.list -fill both -expand 1
    listbox $w.main.list.items -height 10 -exportselection 0 -yscrollcommand [list $w.main.list.scroll set]
    scrollbar $w.main.list.scroll -orient vertical -command [list $w.main.list.items yview]
    pack $w.main.list.scroll -side right -fill y
    pack $w.main.list.items -side left -fill both -expand 1
    bind $w.main.list.items <<ListboxSelect>> ::BatchLoadApplication::selectCaseRule
    frame $w.main.editor; pack $w.main.editor -fill x -pady {10 0}
    label $w.main.editor.kl -text [::HWFlow::txt "关键词" "Keywords"] -anchor w
    entry $w.main.editor.ke -textvariable ::BatchLoadApplication::ui(rule_keywords)
    label $w.main.editor.sl -text [::HWFlow::txt "英文名称后缀" "English Name Suffix"] -anchor w
    entry $w.main.editor.se -textvariable ::BatchLoadApplication::ui(rule_suffix)
    grid $w.main.editor.kl -row 0 -column 0 -sticky w -padx {0 8} -pady 3
    grid $w.main.editor.ke -row 0 -column 1 -sticky ew -pady 3
    grid $w.main.editor.sl -row 1 -column 0 -sticky w -padx {0 8} -pady 3
    grid $w.main.editor.se -row 1 -column 1 -sticky ew -pady 3
    grid columnconfigure $w.main.editor 1 -weight 1
    frame $w.main.buttons; pack $w.main.buttons -fill x -pady {10 0}
    button $w.main.buttons.add -text [::HWFlow::txt "添加" "Add"] -command ::BatchLoadApplication::addCaseRule
    button $w.main.buttons.update -text [::HWFlow::txt "修改" "Update"] -command ::BatchLoadApplication::updateCaseRule
    button $w.main.buttons.delete -text [::HWFlow::txt "删除" "Delete"] -command ::BatchLoadApplication::deleteCaseRule
    button $w.main.buttons.up -text [::HWFlow::txt "上移" "Move Up"] -command {::BatchLoadApplication::moveCaseRule -1}
    button $w.main.buttons.down -text [::HWFlow::txt "下移" "Move Down"] -command {::BatchLoadApplication::moveCaseRule 1}
    button $w.main.buttons.defaults -text [::HWFlow::txt "恢复默认" "Restore Defaults"] -command ::BatchLoadApplication::restoreDefaultCaseRules
    button $w.main.buttons.close -text [::HWFlow::txt "关闭" "Close"] -command [list destroy $w]
    pack $w.main.buttons.add $w.main.buttons.update $w.main.buttons.delete $w.main.buttons.up $w.main.buttons.down -side left -padx {0 5}
    pack $w.main.buttons.close $w.main.buttons.defaults -side right -padx {5 0}
    set ui(rule_keywords) ""; set ui(rule_suffix) ""
    ::BatchLoadApplication::refreshCaseRuleList
    ::HWFlow::centerWindow $w
}

proc ::BatchLoadApplication::caseNumber {caseName} {
    if {[regexp -nocase {^case([0-9]+)$} [string trim $caseName] -> number]} {
        return [expr {int($number)}]
    }
    return -1
}

proc ::BatchLoadApplication::compareCaseNames {left right} {
    set leftNumber [::BatchLoadApplication::caseNumber $left]
    set rightNumber [::BatchLoadApplication::caseNumber $right]
    if {$leftNumber >= 0 && $rightNumber >= 0 && $leftNumber != $rightNumber} {
        return [expr {$leftNumber < $rightNumber ? -1 : 1}]
    }
    return [string compare -nocase $left $right]
}

proc ::BatchLoadApplication::buildCasePlans {} {
    variable POINTS
    variable ORDER
    set cases [dict create]
    set skippedPoints 0
    set completedPoints 0
    set duplicates {}
    set nameConflicts {}
    set modelNames [dict create]
    set seen [dict create]
    foreach key $ORDER {
        if {![dict exists $POINTS $key]} { continue }
        set point [dict get $POINTS $key]
        set nodeId [dict get $point node_id]
        if {$nodeId eq ""} { incr skippedPoints; continue }
        incr completedPoints
        foreach reference [dict get $point references] {
            set caseName [string tolower [string trim [dict get $reference case]]]
            if {[::BatchLoadApplication::caseNumber $caseName] < 0} { continue }
            set description ""
            if {[dict exists $reference case_description]} { set description [dict get $reference case_description] }
            set proposedName [::BatchLoadApplication::caseEntityName $caseName $description]
            if {![dict exists $modelNames $caseName]} {
                dict set modelNames $caseName $proposedName
            } else {
                set currentName [dict get $modelNames $caseName]
                if {$currentName eq $caseName && $proposedName ne $caseName} {
                    dict set modelNames $caseName $proposedName
                } elseif {$proposedName ne $caseName && $currentName ne $proposedName} {
                    lappend nameConflicts "$caseName: $currentName / $proposedName"
                }
            }
            set recordKey "$caseName|$key"
            if {[dict exists $seen $recordKey]} {
                lappend duplicates "$caseName: [dict get $point english] / [dict get $point chinese]"
                continue
            }
            dict set seen $recordKey 1
            dict lappend cases $caseName [dict create \
                point_key $key node_id $nodeId english [dict get $point english] chinese [dict get $point chinese] \
                fx [dict get $reference fx] fy [dict get $reference fy] fz [dict get $reference fz] \
                tx [dict get $reference tx] ty [dict get $reference ty] tz [dict get $reference tz]]
        }
    }
    set caseNames [lsort -command ::BatchLoadApplication::compareCaseNames [dict keys $cases]]
    set recordCount 0
    foreach caseName $caseNames { incr recordCount [llength [dict get $cases $caseName]] }
    return [dict create cases $cases case_names $caseNames completed_points $completedPoints \
        skipped_points $skippedPoints record_count $recordCount duplicates $duplicates \
        model_names $modelNames name_conflicts [lsort -unique $nameConflicts]]
}

proc ::BatchLoadApplication::existingCaseConflicts {caseNames} {
    set conflicts {}
    foreach caseName $caseNames {
        if {[::HWFlow::entityExistsByName loadcols $caseName]} {
            lappend conflicts [::HWFlow::txt "Load Collector：$caseName" "Load Collector: $caseName"]
        }
        if {[::HWFlow::entityExistsByName loadsteps $caseName]} {
            lappend conflicts [::HWFlow::txt "Subcase：$caseName" "Subcase: $caseName"]
        }
    }
    return $conflicts
}

proc ::BatchLoadApplication::vectorIsZero {a b c} {
    return [expr {double($a) == 0.0 && double($b) == 0.0 && double($c) == 0.0}]
}

proc ::BatchLoadApplication::createOneCase {caseName entries} {
    foreach entry $entries {
        set nodeId [dict get $entry node_id]
        if {![::BatchLoadApplication::nodeExists $nodeId]} {
            error [::HWFlow::txt "点位 [dict get $entry english] 对应的 Node $nodeId 不存在。" "Node $nodeId mapped to point [dict get $entry english] does not exist."]
        }
    }

    *createentity loadcols name=$caseName
    set loadcolId [::HWFlow::entityIdByName {loadcols} $caseName]
    if {$loadcolId <= 0} { error [::HWFlow::txt "无法取得 Load Collector $caseName 的 ID。" "Could not get the ID of Load Collector $caseName."] }
    *currentcollector loadcols $caseName

    set forceCount 0
    set momentCount 0
    foreach entry $entries {
        set nodeId [dict get $entry node_id]
        set fx [dict get $entry fx]; set fy [dict get $entry fy]; set fz [dict get $entry fz]
        set tx [dict get $entry tx]; set ty [dict get $entry ty]; set tz [dict get $entry tz]
        *createmark nodes 1 "by id only" $nodeId
        if {![::BatchLoadApplication::vectorIsZero $fx $fy $fz]} {
            *loadcreateonentity_curve nodes 1 1 1 $fx $fy $fz 0 0 0 0 0 0 0 0
            incr forceCount
        }
        if {![::BatchLoadApplication::vectorIsZero $tx $ty $tz]} {
            *loadcreateonentity_curve nodes 1 2 1 $tx $ty $tz 0 0 0 0 0 0 0 0
            incr momentCount
        }
    }

    *loadstepscreate $caseName 1
    set loadstepId [::HWFlow::entityIdByName {loadsteps} $caseName]
    if {$loadstepId <= 0} { error [::HWFlow::txt "无法取得 Subcase $caseName 的 ID。" "Could not get the ID of Subcase $caseName."] }
    *attributeupdateint loadsteps $loadstepId 4143 1 1 0 1
    *attributeupdateint loadsteps $loadstepId 4709 1 1 0 1
    *setvalue loadsteps id=$loadstepId STATUS=2 4059=1 4060=STATICS
    *attributeupdateentity loadsteps $loadstepId 4147 1 1 0 loadcols $loadcolId
    return [dict create case $caseName loadcol_id $loadcolId loadstep_id $loadstepId \
        points [llength $entries] forces $forceCount moments $momentCount]
}

proc ::BatchLoadApplication::createAllCases {} {
    variable WINDOW
    variable ui
    set plan [::BatchLoadApplication::buildCasePlans]
    set caseNames [dict get $plan case_names]
    if {[llength $caseNames] == 0} {
        set ui(status) [::HWFlow::txt "没有可创建工况的已完成点位。" "There are no completed points available for case creation."]
        tk_messageBox -parent $WINDOW -icon warning -title [::HWFlow::txt "创建所有工况" "Create All Cases"] -message $ui(status)
        return 0
    }
    if {[llength [dict get $plan duplicates]] > 0} {
        set message [::HWFlow::txt "同一工况中发现重复点位，已停止创建：\n" "Duplicate points were found in the same case; creation stopped:\n"]
        append message [join [dict get $plan duplicates] "\n"]
        tk_messageBox -parent $WINDOW -icon error -title [::HWFlow::txt "工况数据冲突" "Case Data Conflict"] -message $message
        return 0
    }
    if {[llength [dict get $plan name_conflicts]] > 0} {
        set message [::HWFlow::txt "同一编号匹配到了不同的英文工况名称，请检查名称映射：\n" "One case number matched different English names. Check the case-name mappings:\n"]
        append message [join [dict get $plan name_conflicts] "\n"]
        tk_messageBox -parent $WINDOW -icon error -title [::HWFlow::txt "工况名称冲突" "Case Name Conflict"] -message $message
        return 0
    }
    set modelNames {}
    foreach caseName $caseNames { lappend modelNames [dict get [dict get $plan model_names] $caseName] }
    set conflicts [::BatchLoadApplication::existingCaseConflicts $modelNames]
    if {[llength $conflicts] > 0} {
        set message [::HWFlow::txt "模型中已存在以下同名实体。为避免覆盖，未创建任何工况：\n" "The following names already exist. No cases were created to avoid overwriting them:\n"]
        append message [join $conflicts "\n"]
        tk_messageBox -parent $WINDOW -icon error -title [::HWFlow::txt "名称冲突" "Name Conflict"] -message $message
        return 0
    }
    set namingRows {}
    foreach caseName $caseNames {
        set modelName [dict get [dict get $plan model_names] $caseName]
        if {$modelName ne $caseName} { lappend namingRows "$caseName -> $modelName" }
    }
    set namingText ""
    if {[llength $namingRows] > 0} {
        set namingText "\n\n[::HWFlow::txt "英文名称预览：" "English name preview:"]\n[join $namingRows \n]"
    }
    set confirm [::HWFlow::txt \
        "将创建 [llength $caseNames] 个 Load Collector 和 [llength $caseNames] 个 Subcase，使用 [dict get $plan completed_points] 个已完成点位、[dict get $plan record_count] 条工况载荷；跳过 [dict get $plan skipped_points] 个未完成点位。\n\n继续吗？" \
        "Create [llength $caseNames] Load Collector(s) and [llength $caseNames] Subcase(s) from [dict get $plan completed_points] completed point(s) and [dict get $plan record_count] case load record(s); [dict get $plan skipped_points] incomplete point(s) will be skipped.\n\nContinue?"]
    append confirm $namingText
    if {[tk_messageBox -parent $WINDOW -icon question -type yesno -default no -title [::HWFlow::txt "创建所有工况" "Create All Cases"] -message $confirm] ne "yes"} { return 0 }

    set historyName "Create batch load cases"
    set historyStarted 0
    if {![catch {*startnotehistorystate $historyName}]} { set historyStarted 1 }
    catch {::HWFlow::progressOpen [::HWFlow::txt "创建所有工况" "Create All Cases"] [::HWFlow::txt "正在创建载荷与 Subcase..." "Creating loads and Subcases..."] 0}
    set created {}
    set total [llength $caseNames]
    set index 0
    set code [catch {
        foreach caseName $caseNames {
            incr index
            set modelName [dict get [dict get $plan model_names] $caseName]
            catch {::HWFlow::progressUpdate [expr {5.0 + 90.0 * ($index - 1) / double($total)}] [::HWFlow::txt "正在创建 $modelName" "Creating $modelName"] "$index/$total" 1}
            lappend created [::BatchLoadApplication::createOneCase $modelName [dict get [dict get $plan cases] $caseName]]
        }
    } message options]
    if {$historyStarted} { catch {*endnotehistorystate $historyName} }
    if {$code} {
        if {$historyStarted} { catch {*undohistorystate 1} }
        catch {::HWFlow::progressClose [::HWFlow::txt "创建失败，已尝试回滚" "Creation failed; rollback was attempted"] 100}
        set ui(status) [::HWFlow::txt "工况创建失败，已尝试回滚。" "Case creation failed; rollback was attempted."]
        tk_messageBox -parent $WINDOW -icon error -title [::HWFlow::txt "创建所有工况" "Create All Cases"] -message $message
        return 0
    }
    set forceCount 0; set momentCount 0
    foreach result $created { incr forceCount [dict get $result forces]; incr momentCount [dict get $result moments] }
    catch {::HWFlow::progressUpdate 100 [::HWFlow::txt "工况创建完成" "Case creation complete"] [::HWFlow::txt "Force：$forceCount，Moment：$momentCount" "Forces: $forceCount; Moments: $momentCount"] 1}
    catch {::HWFlow::progressClose}
    set ui(status) [::HWFlow::txt "已创建 $total 个工况：$forceCount 个 Force，$momentCount 个 Moment。" "Created $total case(s): $forceCount Force(s), $momentCount Moment(s)."]
    tk_messageBox -parent $WINDOW -icon info -title [::HWFlow::txt "创建完成" "Creation Complete"] -message $ui(status)
    return $created
}

proc ::BatchLoadApplication::deletePoint {key} {
    variable POINTS
    variable WINDOW
    variable DETAIL_WINDOW
    variable ui
    if {![dict exists $POINTS $key]} { return 0 }
    set point [dict get $POINTS $key]
    set name "[::BatchLoadApplication::displayName [dict get $point english]] / [::BatchLoadApplication::displayName [dict get $point chinese]]"
    set referenceCount [llength [dict get $point references]]
    set message [::HWFlow::txt \
        "确定删除点位 $name 及其在全部工况中的 $referenceCount 条载荷吗？\n\n此操作不会删除模型节点或恢复 Node ID；重新解析原文件可以恢复该点位。" \
        "Delete point $name and its $referenceCount load record(s) from all cases?\n\nThis does not delete the model node or restore its Node ID. Reparse the source files to restore the point."]
    set answer [tk_messageBox -parent $WINDOW -icon warning -type yesno -default no \
        -title [::HWFlow::txt "删除点位" "Delete Point"] -message $message]
    if {$answer ne "yes"} { return 0 }
    set removed [::BatchLoadApplication::removePointData $key]
    if {![dict get $removed removed]} { return 0 }
    catch {destroy $DETAIL_WINDOW}
    if {[catch {::BatchLoadApplication::writeMappingCsv [::BatchLoadApplication::defaultMappingPath]} persistError]} {
        set ui(status) [::HWFlow::txt "点位及相关载荷已删除，但默认映射 CSV 更新失败。" "The point and its loads were deleted, but the default mapping CSV could not be updated."]
        tk_messageBox -parent $WINDOW -icon warning -title [::HWFlow::txt "删除已完成" "Deletion Completed"] -message $persistError
    } else {
        set ui(status) [::HWFlow::txt "已删除点位 $name 及 $referenceCount 条相关载荷。" "Deleted point $name and $referenceCount related load record(s)."]
    }
    ::BatchLoadApplication::refreshRows
    return 1
}

proc ::BatchLoadApplication::refreshRows {} {
    variable WINDOW
    variable POINTS
    variable ORDER
    variable ROW_KEYS
    variable ui
    set body $WINDOW.main.list.canvas.body
    if {![winfo exists $body]} { return }
    foreach child [winfo children $body] { destroy $child }
    set ROW_KEYS [dict create]
    set row 0
    foreach key $ORDER {
        if {![dict exists $POINTS $key]} { continue }
        set point [dict get $POINTS $key]
        set token "r$row"
        dict set ROW_KEYS $token $key
        frame $body.$token -bd 0 -padx 4 -pady 3
        label $body.$token.en -text [::BatchLoadApplication::displayName [dict get $point english]] -anchor w
        label $body.$token.zh -text [::BatchLoadApplication::displayName [dict get $point chinese]] -anchor w
        set nodeId [dict get $point node_id]
        label $body.$token.status -text [expr {$nodeId eq "" ? [::HWFlow::txt "未完成" "Pending"] : [::HWFlow::txt "已完成 (Node $nodeId)" "Done (Node $nodeId)"]}] -anchor w \
            -fg [expr {$nodeId eq "" ? "#9a6700" : "#1a7f37"}]
        button $body.$token.detail -text [::HWFlow::txt "详情" "Details"] -width 8 -command [list ::BatchLoadApplication::showDetails $key]
        button $body.$token.locate -text [::HWFlow::txt "定位" "Locate"] -width 8 -command [list ::BatchLoadApplication::locatePoint $key]
        button $body.$token.delete -text [::HWFlow::txt "删除" "Delete"] -width 8 -command [list ::BatchLoadApplication::deletePoint $key]
        if {$nodeId ne ""} { $body.$token.locate configure -state disabled }
        grid $body.$token.en -row 0 -column 0 -sticky ew -padx {2 8}
        grid $body.$token.zh -row 0 -column 1 -sticky ew -padx 8
        grid $body.$token.status -row 0 -column 2 -sticky ew -padx 8
        grid $body.$token.detail -row 0 -column 3 -padx 4
        grid $body.$token.locate -row 0 -column 4 -padx 4
        grid $body.$token.delete -row 0 -column 5 -padx 4
        grid columnconfigure $body.$token 0 -weight 3 -minsize 190
        grid columnconfigure $body.$token 1 -weight 3 -minsize 190
        grid columnconfigure $body.$token 2 -weight 2 -minsize 150
        pack $body.$token -fill x
        incr row
    }
    if {$row == 0} {
        label $body.empty -text [::HWFlow::txt "请选择 TXT 文件；解析后的点位将在这里平铺显示。" "Select TXT files; parsed points will be listed here."] -anchor center -pady 40
        pack $body.empty -fill x
    }
    set done 0
    foreach key $ORDER { if {[dict exists $POINTS $key] && [dict get $POINTS $key node_id] ne ""} { incr done } }
    set ui(summary) [::HWFlow::txt "点位：[llength $ORDER]    已完成：$done" "Points: [llength $ORDER]    Done: $done"]
    update idletasks
    catch {$WINDOW.main.list.canvas configure -scrollregion [$WINDOW.main.list.canvas bbox all]}
}

proc ::BatchLoadApplication::showDetails {key} {
    variable POINTS
    variable DETAIL_WINDOW
    variable WINDOW
    if {![dict exists $POINTS $key]} { return }
    set point [dict get $POINTS $key]
    catch {destroy $DETAIL_WINDOW}
    set w $DETAIL_WINDOW
    ::HWFlow::createTopLevel $w dialog
    wm title $w [::HWFlow::windowTitle [::HWFlow::txt "点位详情" "Point Details"] "Point Details"]
    wm transient $w $WINDOW
    wm minsize $w 860 360
    frame $w.main -padx 12 -pady 12; pack $w.main -fill both -expand 1
    label $w.main.name -anchor w -font [::HWFlow::uiFont title] -text "[dict get $point english] / [dict get $point chinese]"
    label $w.main.coords -anchor w -text [format "XYZ: %.12g, %.12g, %.12g" [dict get $point x] [dict get $point y] [dict get $point z]]
    pack $w.main.name $w.main.coords -fill x -pady {0 6}
    frame $w.main.table; pack $w.main.table -fill both -expand 1
    ttk::treeview $w.main.table.tree -show headings -columns {case fx fy fz tx ty tz source} -selectmode none
    foreach spec {
        {case "工况" "Load Case" 130} {fx FX FX 75} {fy FY FY 75} {fz FZ FZ 75}
        {tx TX TX 75} {ty TY TY 75} {tz TZ TZ 75} {source "来源" "Source" 170}
    } {
        set column [lindex $spec 0]
        $w.main.table.tree heading $column -text [::HWFlow::txt [lindex $spec 1] [lindex $spec 2]]
        $w.main.table.tree column $column -width [lindex $spec 3] -stretch [expr {$column in {case source}}]
    }
    foreach reference [dict get $point references] {
        set caseText [dict get $reference case]
        if {[dict exists $reference case_description] && [string trim [dict get $reference case_description]] ne ""} {
            append caseText " - " [dict get $reference case_description]
        }
        $w.main.table.tree insert {} end -values [list $caseText [dict get $reference fx] [dict get $reference fy] [dict get $reference fz] [dict get $reference tx] [dict get $reference ty] [dict get $reference tz] "[file tail [dict get $reference source]]:[dict get $reference line]"]
    }
    scrollbar $w.main.table.ys -orient vertical -command [list $w.main.table.tree yview]
    $w.main.table.tree configure -yscrollcommand [list $w.main.table.ys set]
    grid $w.main.table.tree -row 0 -column 0 -sticky nsew
    grid $w.main.table.ys -row 0 -column 1 -sticky ns
    grid rowconfigure $w.main.table 0 -weight 1; grid columnconfigure $w.main.table 0 -weight 1
    button $w.close -text [::HWFlow::txt "关闭" "Close"] -width 10 -command [list destroy $w]
    pack $w.close -pady {0 10}
    bind $w <Escape> [list destroy $w]
    ::HWFlow::centerWindow $w
}

proc ::BatchLoadApplication::nodeExists {nodeId} {
    return [expr {![catch {set value [hm_getvalue nodes id=$nodeId dataname=id]}] && $value ne "" && $value != 0}]
}

proc ::BatchLoadApplication::deleteTemporaryNode {nodeId} {
    if {$nodeId eq "" || ![::BatchLoadApplication::nodeExists $nodeId]} { return }
    catch {*clearmark nodes 2}
    catch {*createmark nodes 2 "by id only" $nodeId}
    catch {*deletemark nodes 2}
    catch {*clearmark nodes 2}
}

proc ::BatchLoadApplication::nextMappingId {} {
    variable MAPPINGS
    set used {}
    foreach key [dict keys $MAPPINGS] { lappend used [dict get $MAPPINGS $key] }
    set candidate 1001
    while {[lsearch -exact $used $candidate] >= 0} { incr candidate }
    return $candidate
}

proc ::BatchLoadApplication::renumberSelectedNode {nodeId targetId} {
    if {$nodeId == $targetId} { return $targetId }
    if {[::BatchLoadApplication::nodeExists $targetId]} {
        error [::HWFlow::txt "Node $targetId 已存在。请先使用 Node ID 重排腾出 1001 起的编号段。" "Node $targetId already exists. Use Node ID Reorder first to free the range beginning at 1001."]
    }
    *createmark nodes 1 "by id only" $nodeId
    *renumbersolverid nodes 1 $targetId 1 0 0 0 0 0
    if {![::BatchLoadApplication::nodeExists $targetId]} {
        error [::HWFlow::txt "节点重命名后无法确认 Node $targetId。" "Node $targetId could not be verified after renumbering."]
    }
    return $targetId
}

proc ::BatchLoadApplication::locatePoint {key} {
    variable POINTS
    variable MAPPINGS
    variable WINDOW
    variable ui
    if {![dict exists $POINTS $key]} { return }
    set point [dict get $POINTS $key]
    set temporary ""
    set persistWarning ""
    set historyName "Map batch load point"
    set historyStarted 0
    if {![catch {*startnotehistorystate $historyName}]} { set historyStarted 1 }
    set code [catch {
        set temporary [*createnode [dict get $point x] [dict get $point y] [dict get $point z] 0 0 0]
        if {![string is integer -strict $temporary] || $temporary <= 0} { set temporary [hm_latestentityid nodes] }
        catch {*createmark nodes 2 "by id only" $temporary}
        catch {*numbersmark nodes 2 1}
        set selected [::HWFlow::nativeMarkPanel nodes 1 [::HWFlow::txt "请选择与临时坐标标记对应的一个模型节点，然后中键确认" "Select one model node corresponding to the temporary coordinate marker, then confirm with the middle mouse button"]]
        catch {*numbersmark nodes 2 0}
        if {[llength $selected] == 0} { error [::HWFlow::txt "未选择节点。" "No node was selected."] }
        if {[llength $selected] != 1} { error [::HWFlow::txt "每个点位只能选择一个节点。" "Select exactly one node for each point."] }
        set chosen [lindex $selected 0]
        if {$chosen == $temporary} { error [::HWFlow::txt "不能把临时坐标标记本身作为目标节点。" "The temporary coordinate marker cannot be used as the target node."] }
        ::BatchLoadApplication::deleteTemporaryNode $temporary
        set temporary ""
        set targetId [::BatchLoadApplication::nextMappingId]
        set assigned [::BatchLoadApplication::renumberSelectedNode $chosen $targetId]
        dict set MAPPINGS $key $assigned
        dict set point node_id $assigned
        dict set POINTS $key $point
        if {[catch {::BatchLoadApplication::writeMappingCsv [::BatchLoadApplication::defaultMappingPath]} persistError]} {
            set persistWarning $persistError
        }
    } message options]
    if {$temporary ne ""} { ::BatchLoadApplication::deleteTemporaryNode $temporary }
    catch {*numbersmark nodes 2 0}
    if {$historyStarted} { catch {*endnotehistorystate $historyName} }
    if {$code} {
        set ui(status) [::HWFlow::txt "点位定位未完成。" "Point mapping was not completed."]
        tk_messageBox -parent $WINDOW -icon warning -title [::HWFlow::txt "定位" "Locate"] -message $message
        return 0
    }
    if {$persistWarning eq ""} {
        set ui(status) [::HWFlow::txt "点位已对应到 Node $assigned，默认映射已更新。" "Point mapped to Node $assigned; the default mapping was updated."]
    } else {
        set ui(status) [::HWFlow::txt "点位已对应到 Node $assigned，但默认 CSV 写入失败。" "Point mapped to Node $assigned, but the default CSV could not be written."]
        tk_messageBox -parent $WINDOW -icon warning -title [::HWFlow::txt "映射已完成" "Mapping Completed"] -message $persistWarning
    }
    ::BatchLoadApplication::refreshRows
    return $assigned
}

proc ::BatchLoadApplication::defaultMappingPath {} {
    return [file join [::HWFlow::configDir] runtime batch_load_application node_mapping.csv]
}

proc ::BatchLoadApplication::csvQuote {value} {
    set value [string map [list "\"" "\"\""] $value]
    return "\"$value\""
}

proc ::BatchLoadApplication::mappingCsvText {} {
    variable POINTS
    variable ORDER
    set lines [list "english_name,chinese_name,node_id"]
    foreach key $ORDER {
        if {![dict exists $POINTS $key]} { continue }
        set point [dict get $POINTS $key]
        if {[dict get $point node_id] eq ""} { continue }
        lappend lines [join [list [::BatchLoadApplication::csvQuote [dict get $point english]] [::BatchLoadApplication::csvQuote [dict get $point chinese]] [dict get $point node_id]] ,]
    }
    return "[join $lines \n]\n"
}

proc ::BatchLoadApplication::writeMappingCsv {path} {
    ::HWFlow::writeTextFile $path [::BatchLoadApplication::mappingCsvText]
    return $path
}

proc ::BatchLoadApplication::saveMapping {} {
    variable WINDOW
    variable MAPPINGS
    variable ui
    if {[dict size $MAPPINGS] == 0} {
        set ui(status) [::HWFlow::txt "当前没有已完成的点位映射。" "There are no completed point mappings."]
        return
    }
    set path [tk_getSaveFile -parent $WINDOW -title [::HWFlow::txt "保存 Node 映射" "Save Node Mapping"] \
        -defaultextension .csv -initialfile node_mapping.csv -filetypes [list [list "CSV" {.csv}] [list [::HWFlow::txt "所有文件" "All files"] *]]]
    if {$path eq ""} { return }
    if {[catch {::BatchLoadApplication::writeMappingCsv $path} message]} {
        tk_messageBox -parent $WINDOW -icon error -title [::HWFlow::txt "保存失败" "Save Failed"] -message $message
        return
    }
    set ui(status) [::HWFlow::txt "映射已保存到：$path" "Mapping saved to: $path"]
}

proc ::BatchLoadApplication::showRenumberDialog {} {
    variable WINDOW
    variable RENUMBER_WINDOW
    variable ui
    catch {destroy $RENUMBER_WINDOW}
    set w $RENUMBER_WINDOW
    ::HWFlow::createTopLevel $w dialog
    wm title $w [::HWFlow::windowTitle [::HWFlow::txt "Node ID 重排" "Node ID Reorder"] "Node ID Reorder"]
    wm transient $w $WINDOW
    frame $w.main -padx 16 -pady 14; pack $w.main -fill both -expand 1
    message $w.main.help -width 440 -text [::HWFlow::txt "输入起始 ID，将模型中的所有节点按步长 1 连续重排。此操作会清空本模块中已有的点位映射。" "Enter a starting ID to renumber every model node consecutively with increment 1. Existing point mappings in this module will be cleared."]
    frame $w.main.input
    label $w.main.input.label -text [::HWFlow::txt "起始 Node ID：" "Starting Node ID:"]
    entry $w.main.input.value -width 16 -textvariable ::BatchLoadApplication::ui(renumber_start)
    pack $w.main.input.label $w.main.input.value -side left
    pack $w.main.help $w.main.input -fill x -pady {0 12}
    frame $w.actions -padx 16 -pady 10; pack $w.actions -fill x
    button $w.actions.cancel -text [::HWFlow::txt "取消" "Cancel"] -command [list destroy $w]
    button $w.actions.ok -text [::HWFlow::txt "执行重排" "Renumber"] -command ::BatchLoadApplication::confirmRenumber
    pack $w.actions.ok $w.actions.cancel -side right -padx {6 0}
    bind $w <Escape> [list destroy $w]
    bind $w.main.input.value <Return> ::BatchLoadApplication::confirmRenumber
    ::HWFlow::centerWindow $w
    focus $w.main.input.value
}

proc ::BatchLoadApplication::confirmRenumber {} {
    variable ui
    variable WINDOW
    variable RENUMBER_WINDOW
    variable POINTS
    variable ORDER
    variable MAPPINGS
    set start [string trim $ui(renumber_start)]
    if {![string is integer -strict $start] || $start <= 0} {
        tk_messageBox -parent $RENUMBER_WINDOW -icon warning -title [::HWFlow::txt "输入无效" "Invalid Input"] -message [::HWFlow::txt "起始 ID 必须是大于 0 的整数。" "The starting ID must be an integer greater than zero."]
        return
    }
    set answer [tk_messageBox -parent $RENUMBER_WINDOW -icon warning -type yesno -default no \
        -title [::HWFlow::txt "确认重排" "Confirm Renumber"] \
        -message [::HWFlow::txt "确定从 $start 开始重排模型中的所有 Node ID 吗？" "Renumber every model Node ID starting at $start?"]]
    if {$answer ne "yes"} { return }
    set historyName "Reorder all node IDs"
    set historyStarted 0
    if {![catch {*startnotehistorystate $historyName}]} { set historyStarted 1 }
    set code [catch {
        *createmark nodes 1 all
        *renumbersolverid nodes 1 $start 1 0 0 0 0 0
    } message]
    if {$historyStarted} { catch {*endnotehistorystate $historyName} }
    if {$code} {
        if {$historyStarted} { catch {*undohistorystate 1} }
        tk_messageBox -parent $RENUMBER_WINDOW -icon error -title [::HWFlow::txt "重排失败" "Renumber Failed"] -message $message
        return
    }
    set MAPPINGS [dict create]
    foreach key $ORDER {
        if {[dict exists $POINTS $key]} { dict set POINTS $key node_id "" }
    }
    catch {file delete -force [::BatchLoadApplication::defaultMappingPath]}
    destroy $RENUMBER_WINDOW
    set ui(status) [::HWFlow::txt "所有节点已从 $start 开始重排；点位映射已清空。" "All nodes were renumbered from $start; point mappings were cleared."]
    ::BatchLoadApplication::refreshRows
}

proc ::BatchLoadApplication::onCanvasConfigure {canvas width} {
    catch {$canvas itemconfigure body -width $width}
}

proc ::BatchLoadApplication::onBodyConfigure {canvas} {
    catch {$canvas configure -scrollregion [$canvas bbox all]}
}

proc ::BatchLoadApplication::backToHome {} {
    variable WINDOW
    ::BatchLoadApplication::closeModule
    if {[llength [info commands ::HWFlow::backToHome]] > 0} { ::HWFlow::backToHome $WINDOW } else { catch {destroy $WINDOW} }
}

proc ::BatchLoadApplication::closeModule {} {
    variable WINDOW
    variable DETAIL_WINDOW
    variable RENUMBER_WINDOW
    variable CASE_MAPPING_WINDOW
    catch {destroy $DETAIL_WINDOW}
    catch {destroy $RENUMBER_WINDOW}
    catch {destroy $CASE_MAPPING_WINDOW}
    catch {destroy $WINDOW}
}

proc ::BatchLoadApplication::runAction {} {
    variable VERSION
    variable WINDOW
    variable FILES
    variable PARSE_BUSY
    variable ui
    ::BatchLoadApplication::loadCaseNameRules
    catch {destroy $WINDOW}
    set FILES {}
    set PARSE_BUSY 0
    set ui(status) [::HWFlow::txt "请选择一个或多个由 CSV 转换得到的 TXT 文件。" "Select one or more TXT files converted from CSV."]
    set ui(selected_files) [::HWFlow::txt "尚未选择文件" "No files selected"]
    set w $WINDOW
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::windowTitle "[::HWFlow::txt "载荷批量施加" "Batch Load Application"] v$VERSION" "Batch Load Application v$VERSION"]
    wm minsize $w 1020 560
    frame $w.main -padx 12 -pady 10; pack $w.main -fill both -expand 1
    frame $w.main.top; pack $w.main.top -fill x -pady {0 8}
    label $w.main.top.title -text [::HWFlow::txt "载荷批量施加" "Batch Load Application"] -font [::HWFlow::uiFont title] -anchor w
    button $w.main.top.import -text [::HWFlow::txt "选择 TXT 文件" "Select TXT Files"] -command ::BatchLoadApplication::chooseFiles
    button $w.main.top.parse -text [::HWFlow::txt "开始解析" "Parse"] -state disabled -command ::BatchLoadApplication::startParsing
    button $w.main.top.case_names -text [::HWFlow::txt "工况名称映射" "Case Name Mappings"] -command ::BatchLoadApplication::showCaseMappingDialog
    button $w.main.top.renumber -text [::HWFlow::txt "Node ID 重排" "Node ID Reorder"] -command ::BatchLoadApplication::showRenumberDialog
    pack $w.main.top.title -side left -fill x -expand 1
    pack $w.main.top.renumber $w.main.top.case_names $w.main.top.parse $w.main.top.import -side right -padx {6 0}
    label $w.main.selection -textvariable ::BatchLoadApplication::ui(selected_files) -anchor w
    pack $w.main.selection -fill x -pady {0 5}
    message $w.main.help -width 880 -anchor w -text [::HWFlow::txt \
        "先选择 TXT 文件，再点击“开始解析”；解析过程显示进度。“工况名称映射”可编辑中文关键词与英文名称。定位会在文件坐标处创建临时节点并打开 Node 选择器。" \
        "Select TXT files, then click Parse; progress is shown while parsing. Case Name Mappings edits Chinese keywords and English names. Locate creates a temporary node at the file coordinate and opens the Node selector."]
    pack $w.main.help -fill x -pady {0 8}
    frame $w.main.header -bd 1 -relief groove -padx 4 -pady 4; pack $w.main.header -fill x
    foreach spec {{en "英文名称" "English Name" 3 190} {zh "中文名称" "Chinese Name" 3 190} {status "完成状态" "Status" 2 150} {action "操作" "Actions" 0 270}} {
        set name [lindex $spec 0]
        label $w.main.header.$name -text [::HWFlow::txt [lindex $spec 1] [lindex $spec 2]] -anchor w
        grid $w.main.header.$name -row 0 -column [lsearch -exact {en zh status action} $name] -sticky ew -padx 8
        grid columnconfigure $w.main.header [lsearch -exact {en zh status action} $name] -weight [lindex $spec 3] -minsize [lindex $spec 4]
    }
    frame $w.main.list -bd 1 -relief sunken; pack $w.main.list -fill both -expand 1
    canvas $w.main.list.canvas -highlightthickness 0 -yscrollcommand [list $w.main.list.ys set]
    scrollbar $w.main.list.ys -orient vertical -command [list $w.main.list.canvas yview]
    frame $w.main.list.canvas.body
    $w.main.list.canvas create window 0 0 -anchor nw -window $w.main.list.canvas.body -tags body
    grid $w.main.list.canvas -row 0 -column 0 -sticky nsew
    grid $w.main.list.ys -row 0 -column 1 -sticky ns
    grid rowconfigure $w.main.list 0 -weight 1; grid columnconfigure $w.main.list 0 -weight 1
    bind $w.main.list.canvas <Configure> [list ::BatchLoadApplication::onCanvasConfigure $w.main.list.canvas %w]
    bind $w.main.list.canvas.body <Configure> [list ::BatchLoadApplication::onBodyConfigure $w.main.list.canvas]
    label $w.main.summary -textvariable ::BatchLoadApplication::ui(summary) -anchor w; pack $w.main.summary -fill x -pady {7 0}
    label $w.main.status -textvariable ::BatchLoadApplication::ui(status) -anchor w; pack $w.main.status -fill x -pady {4 0}
    frame $w.actions -padx 12 -pady 10; pack $w.actions -fill x
    button $w.actions.back -text [::HWFlow::txt "返回主页" "Back to Home"] -width 12 -command ::BatchLoadApplication::backToHome
    button $w.actions.clear -text [::HWFlow::txt "清除当前列表" "Clear List"] -width 14 -command ::BatchLoadApplication::clearCurrentList
    button $w.actions.save -text [::HWFlow::txt "保存映射" "Save Mapping"] -width 12 -command ::BatchLoadApplication::saveMapping
    button $w.actions.cases -text [::HWFlow::txt "创建所有工况" "Create All Cases"] -width 14 -command ::BatchLoadApplication::createAllCases
    pack $w.actions.back $w.actions.clear -side left -padx {0 6}
    pack $w.actions.save $w.actions.cases -side right -padx {6 0}
    bind $w <Escape> ::BatchLoadApplication::closeModule
    wm protocol $w WM_DELETE_WINDOW ::BatchLoadApplication::closeModule
    ::BatchLoadApplication::refreshRows
    update idletasks
    ::HWFlow::centerWindow $w
    tkwait window $w
    return ""
}
