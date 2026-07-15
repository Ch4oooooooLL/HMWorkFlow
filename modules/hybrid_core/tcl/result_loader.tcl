proc ::HybridCore::validateResultDict {payload expectedModule expectedRunId} {
    variable SCHEMA_VERSION
    foreach key {schema_version module run_id status summary candidates warnings errors performance} {
        if {![dict exists $payload $key]} { error "Python result is missing '$key'" }
    }
    if {[dict get $payload schema_version] ne $SCHEMA_VERSION} {
        error "Unsupported result schema_version: [dict get $payload schema_version]"
    }
    if {[dict get $payload module] ne $expectedModule} {
        error "Result module does not match current task"
    }
    if {[dict get $payload run_id] ne $expectedRunId} {
        error "Result run_id does not match current task"
    }
    if {[dict get $payload status] ni {SUCCESS PARTIAL ERROR}} {
        error "Unsupported result status: [dict get $payload status]"
    }
    if {[dict get $payload status] eq "ERROR"} {
        error "Python returned ERROR: [dict get $payload errors]"
    }
    return $payload
}

proc ::HybridCore::loadResultSidecar {path variableName expectedModule expectedRunId} {
    if {![file isfile $path]} { error "Python result sidecar not found: $path" }
    set text [::HybridCore::readTextFile $path]
    if {![string match "# HYBRID_CORE_RESULT_V1*" $text]} {
        error "Result sidecar marker is missing: $path"
    }
    if {![regexp {^::[A-Za-z0-9_:]+$} $variableName]} {
        error "Unsafe result variable name: $variableName"
    }
    uplevel #0 [list unset -nocomplain $variableName]
    if {[catch {uplevel #0 [list source -encoding utf-8 $path]} err opts]} {
        return -options $opts "Could not load Python result sidecar: $err"
    }
    if {![uplevel #0 [list info exists $variableName]]} {
        error "Result sidecar did not set $variableName"
    }
    set payload [uplevel #0 [list set $variableName]]
    return [::HybridCore::validateResultDict $payload $expectedModule $expectedRunId]
}
