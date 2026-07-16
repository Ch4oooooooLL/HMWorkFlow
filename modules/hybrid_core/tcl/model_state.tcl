proc ::HybridCore::maxEntityId {entityTypes} {
    set best 0
    foreach entityType $entityTypes {
        set value 0
        if {[catch {set value [hm_entitymaxid $entityType]}]} {
            catch {set value [hm_latestentityid $entityType]}
        }
        if {[string is integer -strict $value] && $value > $best} { set best $value }
    }
    return $best
}

proc ::HybridCore::entityNameRegistryJson {entityTypes} {
    set ids {}
    foreach entityType $entityTypes {
        catch {*clearmark $entityType 2}
        if {![catch {*createmark $entityType 2 all}]} {
            catch {set ids [hm_getmark $entityType 2]}
        }
        catch {*clearmark $entityType 2}
        if {[llength $ids] > 0} { break }
    }
    set rows {}
    foreach id [lsort -integer -unique $ids] {
        set name ""
        foreach entityType $entityTypes {
            if {![catch {set name [hm_getvalue $entityType id=$id dataname=name]}] && $name ne ""} { break }
        }
        if {$name ne ""} {
            lappend rows "      [::HybridCore::jsonString $name]: $id"
        }
    }
    return [join $rows ,\n]
}

proc ::HybridCore::incrementalModelStateJson {} {
    set maxNode [::HybridCore::maxEntityId {nodes}]
    set maxElem [::HybridCore::maxEntityId {elems elements}]
    set maxProp [::HybridCore::maxEntityId {props properties}]
    set maxMat [::HybridCore::maxEntityId {mats materials}]
    set maxComp [::HybridCore::maxEntityId {comps components}]
    set props [::HybridCore::entityNameRegistryJson {props properties}]
    set mats [::HybridCore::entityNameRegistryJson {mats materials}]
    set comps [::HybridCore::entityNameRegistryJson {comps components}]
    return "  \"id_state\": {\"max_node_id\": $maxNode, \"max_element_id\": $maxElem, \"max_property_id\": $maxProp, \"max_material_id\": $maxMat, \"max_component_id\": $maxComp},\n  \"entity_registry\": {\n    \"properties\": {\n$props\n    },\n    \"materials\": {\n$mats\n    },\n    \"components\": {\n$comps\n    }\n  }"
}
