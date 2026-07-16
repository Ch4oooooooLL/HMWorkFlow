namespace eval ::HybridCore {
    variable BINARY_MESH_MAGIC "HMWFMB1\x00"
    variable BINARY_MESH_ENDIAN_MARKER 16909060
    variable BINARY_RESULT_MAGIC "HMWFR1\x00\x00"
}

proc ::HybridCore::binaryMeshWriteString {channel value} {
    set bytes [encoding convertto utf-8 $value]
    puts -nonewline $channel [binary format i [string length $bytes]]
    puts -nonewline $channel $bytes
}

proc ::HybridCore::binaryMeshRequirePositiveId {value label} {
    if {![string is wideinteger -strict $value] || $value <= 0} {
        error "$label must be a positive integer: $value"
    }
    return $value
}

proc ::HybridCore::writeBinaryMesh {path components nodes elements} {
    variable BINARY_MESH_MAGIC
    variable BINARY_MESH_ENDIAN_MARKER
    variable workerFileFingerprints

    file mkdir [file dirname $path]
    set channel [open $path w]
    fconfigure $channel -encoding binary -translation binary -buffering full -buffersize 1048576
    set code [catch {
        puts -nonewline $channel $BINARY_MESH_MAGIC
        puts -nonewline $channel [binary format iiii \
            $BINARY_MESH_ENDIAN_MARKER [llength $components] [llength $nodes] [llength $elements]]

        set recordIndex 0
        foreach component $components {
            incr recordIndex
            foreach key {component_id component_name mesh_class} {
                if {![dict exists $component $key]} { error "binary mesh component is missing $key" }
            }
            set componentId [::HybridCore::binaryMeshRequirePositiveId \
                [dict get $component component_id] component_id]
            puts -nonewline $channel [binary format w $componentId]
            ::HybridCore::binaryMeshWriteString $channel [dict get $component component_name]
            ::HybridCore::binaryMeshWriteString $channel [string toupper [dict get $component mesh_class]]
            if {$recordIndex % 4096 == 0 && [llength [info commands ::HybridCore::cooperativeYield]]} {
                ::HybridCore::cooperativeYield
            }
        }

        set recordIndex 0
        foreach node $nodes {
            incr recordIndex
            if {[llength $node] != 4} { error "binary mesh node must be {id x y z}: $node" }
            set nodeId [::HybridCore::binaryMeshRequirePositiveId [lindex $node 0] node_id]
            foreach coordinate [lrange $node 1 3] {
                if {![string is double -strict $coordinate]} {
                    error "binary mesh node $nodeId has an invalid coordinate: $coordinate"
                }
            }
            puts -nonewline $channel [binary format wddd \
                $nodeId [lindex $node 1] [lindex $node 2] [lindex $node 3]]
            if {$recordIndex % 4096 == 0 && [llength [info commands ::HybridCore::cooperativeYield]]} {
                ::HybridCore::cooperativeYield
            }
        }

        set recordIndex 0
        foreach element $elements {
            incr recordIndex
            foreach key {element_id component_id element_type node_ids} {
                if {![dict exists $element $key]} { error "binary mesh element is missing $key" }
            }
            set elementId [::HybridCore::binaryMeshRequirePositiveId \
                [dict get $element element_id] element_id]
            set componentId [::HybridCore::binaryMeshRequirePositiveId \
                [dict get $element component_id] component_id]
            set nodeIds [dict get $element node_ids]
            if {[llength $nodeIds] == 0 || [llength $nodeIds] > 255} {
                error "binary mesh element $elementId has an invalid node count"
            }
            puts -nonewline $channel [binary format ww $elementId $componentId]
            ::HybridCore::binaryMeshWriteString $channel [string toupper [dict get $element element_type]]
            puts -nonewline $channel [binary format i [llength $nodeIds]]
            foreach nodeId $nodeIds {
                ::HybridCore::binaryMeshRequirePositiveId $nodeId "element $elementId node_id"
                puts -nonewline $channel [binary format w $nodeId]
            }
            if {$recordIndex % 4096 == 0 && [llength [info commands ::HybridCore::cooperativeYield]]} {
                ::HybridCore::cooperativeYield
            }
        }
    } err opts]
    set closeCode [catch {close $channel} closeErr closeOpts]
    if {$code} {
        catch {file delete -force $path}
        return -options $opts $err
    }
    if {$closeCode} {
        catch {file delete -force $path}
        return -options $closeOpts $closeErr
    }

    # The task path is unique, so this identity is safe and avoids rereading the
    # just-written binary payload on Tcl's single thread. Cross-task reuse will
    # be enabled only when a reliable HyperMesh model revision is available.
    set normalized [file normalize $path]
    dict set workerFileFingerprints $normalized \
        "mesh-bin-v1:[file size $normalized]:[clock clicks -milliseconds]"
    return $path
}

proc ::HybridCore::binaryResultReadBytes {data offsetVar size label} {
    upvar 1 $offsetVar offset
    if {$size < 0 || $offset < 0 || $offset + $size > [string length $data]} {
        error "Truncated binary result while reading $label"
    }
    binary scan $data @${offset}a${size} value
    incr offset $size
    return $value
}

proc ::HybridCore::binaryResultReadInt32 {data offsetVar label} {
    upvar 1 $offsetVar offset
    set bytes [::HybridCore::binaryResultReadBytes $data offset 4 $label]
    binary scan $bytes i value
    if {$value < 0} { error "Invalid binary result $label: $value" }
    return $value
}

proc ::HybridCore::binaryResultReadString {data offsetVar label} {
    upvar 1 $offsetVar offset
    set size [::HybridCore::binaryResultReadInt32 $data offset "$label length"]
    if {$size > 16777216} { error "Binary result $label is too large" }
    set bytes [::HybridCore::binaryResultReadBytes $data offset $size $label]
    if {[catch {encoding convertfrom utf-8 $bytes} value]} {
        error "Binary result $label is not valid UTF-8"
    }
    return $value
}

proc ::HybridCore::binaryResultDecodeValue {data offsetVar} {
    upvar 1 $offsetVar offset
    set typeBytes [::HybridCore::binaryResultReadBytes $data offset 1 "value type"]
    binary scan $typeBytes c type
    switch -- $type {
        0 { return "" }
        1 { return 0 }
        2 { return 1 }
        3 {
            set bytes [::HybridCore::binaryResultReadBytes $data offset 8 integer]
            binary scan $bytes w value
            return $value
        }
        4 {
            set bytes [::HybridCore::binaryResultReadBytes $data offset 8 float]
            binary scan $bytes d value
            return $value
        }
        5 { return [::HybridCore::binaryResultReadString $data offset string] }
        6 {
            set count [::HybridCore::binaryResultReadInt32 $data offset "list count"]
            set result {}
            for {set index 0} {$index < $count} {incr index} {
                lappend result [::HybridCore::binaryResultDecodeValue $data offset]
            }
            return $result
        }
        7 {
            set count [::HybridCore::binaryResultReadInt32 $data offset "map count"]
            set result [dict create]
            for {set index 0} {$index < $count} {incr index} {
                set key [::HybridCore::binaryResultReadString $data offset "map key"]
                dict set result $key [::HybridCore::binaryResultDecodeValue $data offset]
            }
            return $result
        }
        default { error "Unsupported binary result value type: $type" }
    }
}

proc ::HybridCore::readBinaryResultFile {path} {
    variable BINARY_RESULT_MAGIC
    set channel [open $path r]
    fconfigure $channel -encoding binary -translation binary
    set code [catch {read $channel} data opts]
    catch {close $channel}
    if {$code} { return -options $opts $data }
    set magicLength [string length $BINARY_RESULT_MAGIC]
    if {[string range $data 0 [expr {$magicLength-1}]] ne $BINARY_RESULT_MAGIC} {
        error "Unsupported binary result header: $path"
    }
    set offset $magicLength
    set payload [::HybridCore::binaryResultDecodeValue $data offset]
    if {$offset != [string length $data]} { error "Binary result has trailing data: $path" }
    return $payload
}
