proc ::HybridCore::workerContentFingerprint {text} {
    if {[llength [info commands zlib]]} {
        return "mesh-v1:[string length $text]:[format %08x [zlib crc32 $text]]:[format %08x [zlib adler32 $text]]"
    }
    # HyperMesh versions embedding Tcl before 8.6 may not expose zlib.  Keep a
    # deterministic full-content fallback so persistent caching stays correct.
    set fnv 2166136261
    set djb 5381
    foreach character [split $text ""] {
        scan $character %c codepoint
        set fnv [expr {(($fnv ^ $codepoint) * 16777619) & 0xffffffff}]
        set djb [expr {(($djb * 33) ^ $codepoint) & 0xffffffff}]
    }
    return "mesh-v1:[string length $text]:[format %08x $fnv]:[format %08x $djb]"
}

proc ::HybridCore::writeTextFile {path text} {
    variable workerFileFingerprints
    file mkdir [file dirname $path]
    set channel [open $path w]
    fconfigure $channel -encoding utf-8 -translation lf
    set code [catch {puts -nonewline $channel $text} err opts]
    catch {close $channel}
    if {$code} { return -options $opts $err }
    if {[file tail $path] eq "mesh.json"} {
        dict set workerFileFingerprints [file normalize $path] \
            [::HybridCore::workerContentFingerprint $text]
    }
    return $path
}

proc ::HybridCore::readTextFile {path} {
    set channel [open $path r]
    fconfigure $channel -encoding utf-8 -translation auto
    set code [catch {read $channel} text opts]
    catch {close $channel}
    if {$code} { return -options $opts $text }
    return $text
}

proc ::HybridCore::jsonEscape {value} {
    return [string map [list \\ \\\\ \" \\" \b \\b \f \\f \n \\n \r \\r \t \\t] $value]
}

proc ::HybridCore::jsonString {value} {
    return "\"[::HybridCore::jsonEscape $value]\""
}

proc ::HybridCore::jsonBool {value} {
    return [expr {$value ? "true" : "false"}]
}

proc ::HybridCore::jsonNumber {value} {
    if {![string is double -strict $value]} {
        error "JSON number expected, got: $value"
    }
    return $value
}

proc ::HybridCore::jsonIntArray {values} {
    set rows {}
    foreach value $values {
        if {![string is integer -strict $value]} { error "integer ID expected, got: $value" }
        lappend rows $value
    }
    return "\[[join $rows ,]\]"
}

proc ::HybridCore::jsonStringArray {values} {
    set rows {}
    foreach value $values { lappend rows [::HybridCore::jsonString $value] }
    return "\[[join $rows ,]\]"
}
