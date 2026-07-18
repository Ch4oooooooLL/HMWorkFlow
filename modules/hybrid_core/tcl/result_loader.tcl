proc ::HybridCore::loadDataSidecar {path variableName marker} {
    variable currentTaskDir
    if {![file isfile $path]} {error "Python result sidecar not found: $path"}
    if {[catch {file type $path} fileType] || $fileType eq "link"} {error "Result sidecar must be a regular file"}
    if {[file size $path] > 16777216} {error "Result sidecar exceeds the 16 MiB safety limit"}
    if {$currentTaskDir ne "" && ![::HybridCore::pathWithin $path $currentTaskDir]} {
        error "Result sidecar is outside the current task workspace"
    }
    if {![regexp {^::[A-Za-z0-9_:]+$} $variableName]} {error "Unsafe result variable name: $variableName"}
    set text [::HybridCore::readTextFile $path]
    if {![string match "$marker*" $text]} {error "Result sidecar marker is missing: $path"}
    set lines [split $text "\n"]
    set body [string trim [join [lrange $lines 1 end] "\n"]]
    set quoted [regsub -all {([][(){}.*+?^$\\|])} $variableName {\\\1}]
    if {![regexp "(?s)^set\\s+$quoted\\s+.+$" $body]} {error "Result sidecar must contain exactly one data assignment"}
    set safe [interp create -safe]
    set namespaceName [namespace qualifiers $variableName]
    if {$namespaceName ne ""} {interp eval $safe [list namespace eval $namespaceName {}]}
    set code [catch {interp eval $safe $body} evalError evalOptions]
    if {!$code} {set payload [interp eval $safe [list set $variableName]]}
    interp delete $safe
    if {$code} {return -options $evalOptions "Could not parse Python result sidecar: $evalError"}
    return $payload
}

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
    set payload [::HybridCore::loadDataSidecar $path $variableName "# HYBRID_CORE_RESULT_V1"]
    return [::HybridCore::validateResultDict $payload $expectedModule $expectedRunId]
}

proc ::HybridCore::loadBinaryResult {path expectedModule expectedRunId} {
    if {![file isfile $path]} { error "Python binary result not found: $path" }
    set payload [::HybridCore::readBinaryResultFile $path]
    return [::HybridCore::validateResultDict $payload $expectedModule $expectedRunId]
}
