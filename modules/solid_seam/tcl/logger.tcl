namespace eval ::SolidSeam {
    variable VERSION "1.0.0"
    variable ROOT_DIR [file dirname [file dirname $MODULE_DIR]]
    variable runtimeDir ""
    variable runId ""
    variable candidateRows {}
    variable selectedComponentIds {}
    variable solidComponentIds {}
    variable shellComponentIds {}
    variable mode ""
    variable cancelled 0
    variable ui
    array set ui {
        search_distance 15.0 max_search_distance 25.0 min_weld_length 20.0
        min_valid_ratio 0.7 feature_angle_deg 35.0 max_chain_turn_angle_deg 60.0
        gap_jump_limit 5.0 allow_closed_loop 1 detect_duplicates 1
        high_confidence_threshold 0.85 review_confidence_threshold 0.60
        default_realization PENTA_MIG_T auto_accept_high 1 status "Ready"
    }
}

proc ::SolidSeam::txt {zh en} { return [::HWFlow::txt $zh $en] }

proc ::SolidSeam::jsonEscape {value} {
    return [string map [list \\ \\\\ \" \\" "\n" \\n "\r" \\r "\t" \\t] $value]
}
proc ::SolidSeam::jsonString {value} { return "\"[::SolidSeam::jsonEscape $value]\"" }
proc ::SolidSeam::jsonBool {value} { return [expr {$value ? "true" : "false"}] }
proc ::SolidSeam::jsonIntArray {values} { return "\[[join $values ,]\]" }

proc ::SolidSeam::newRun {} {
    variable ROOT_DIR; variable runtimeDir; variable runId; variable candidateRows; variable cancelled
    set stamp [clock format [clock seconds] -format %Y%m%d_%H%M%S]
    set runId "${stamp}_[format %05d [expr {int(rand()*100000)}]]"
    set runtimeDir [file normalize [file join $ROOT_DIR temp solid_seam $runId]]
    file mkdir $runtimeDir
    set candidateRows {}
    set cancelled 0
    ::SolidSeam::log INFO "run started version=$::SolidSeam::VERSION"
    return $runtimeDir
}

proc ::SolidSeam::log {level message {candidateId "-"}} {
    variable runtimeDir; variable runId
    set line "[clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S}] $level run=$runId candidate=$candidateId $message"
    catch {puts "SolidSeam: $line"}
    if {$runtimeDir ne ""} {
        set channel [open [file join $runtimeDir operation.log] a]
        fconfigure $channel -encoding utf-8 -translation lf
        puts $channel $line
        close $channel
    }
}

proc ::SolidSeam::message {icon text} {
    if {[llength [info commands tk_messageBox]] > 0} {
        tk_messageBox -icon $icon -title [::SolidSeam::txt "实体焊缝" "Solid Seam"] -message $text
    } else { catch {puts $text} }
}
