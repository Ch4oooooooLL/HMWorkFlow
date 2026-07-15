proc ::HybridCore::writeTextFile {path text} {
    file mkdir [file dirname $path]
    set channel [open $path w]
    fconfigure $channel -encoding utf-8 -translation lf
    set code [catch {puts -nonewline $channel $text} err opts]
    catch {close $channel}
    if {$code} { return -options $opts $err }
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
