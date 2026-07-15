proc ::SolidSeam::elementConfig {elementId} {
    foreach name {config cardimage elementtype} {
        if {![catch {set value [hm_getvalue elems id=$elementId dataname=$name]}] && $value ne ""} {
            return [string toupper $value]
        }
    }
    return ""
}

proc ::SolidSeam::elementTypeFromConfig {config} {
    set config [string toupper [string trim $config]]
    switch -- $config {
        103 - TRIA3 - CTRIA3 { return CTRIA3 }
        104 - QUAD4 - CQUAD4 { return CQUAD4 }
        106 - TRIA6 - CTRIA6 { return CTRIA6 }
        108 - QUAD8 - CQUAD8 { return CQUAD8 }
        204 - TETRA4 - CTETRA { return CTETRA }
        205 - PYRA5 - CPYRA { return CPYRA }
        206 - PENTA6 - CPENTA { return CPENTA }
        208 - HEXA8 - CHEXA { return CHEXA }
        default { return "" }
    }
}

proc ::SolidSeam::elementFamily {elementId} {
    set config [::SolidSeam::elementConfig $elementId]
    set elementType [::SolidSeam::elementTypeFromConfig $config]
    if {$elementType in {CTETRA CPYRA CPENTA CHEXA}} { return SOLID }
    if {$elementType in {CTRIA3 CQUAD4 CTRIA6 CQUAD8}} { return SHELL }
    # HM config values are the authority. Node-count fallback is limited to
    # unambiguous first-order types; 4-node elements remain unsupported.
    if {![catch {set nodes [hm_getvalue elems id=$elementId dataname=nodes]}]} {
        if {[llength $nodes] in {5 6 8}} { return SOLID }
        if {[llength $nodes] == 3} { return SHELL }
    }
    return UNSUPPORTED
}

proc ::SolidSeam::classifyComponent {componentId} {
    catch {*clearmark elems 1}
    if {[catch {eval *createmark elems 1 "by comp id" $componentId} err]} {
        return [dict create component_id $componentId mesh_class UNSUPPORTED shell_count 0 solid_count 0 unsupported_count 0 error $err]
    }
    set elementIds [hm_getmark elems 1]
    if {[llength $elementIds] == 0} { return [dict create component_id $componentId mesh_class EMPTY shell_count 0 solid_count 0 unsupported_count 0] }
    set shells 0; set solids 0; set unsupported 0
    foreach elementId $elementIds {
        switch -- [::SolidSeam::elementFamily $elementId] {
            SHELL { incr shells } SOLID { incr solids } default { incr unsupported }
        }
    }
    if {$unsupported > 0} { set class UNSUPPORTED
    } elseif {$shells > 0 && $solids > 0} { set class MIXED
    } elseif {$solids > 0} { set class SOLID
    } elseif {$shells > 0} { set class SHELL
    } else { set class UNSUPPORTED }
    return [dict create component_id $componentId mesh_class $class shell_count $shells solid_count $solids unsupported_count $unsupported]
}

proc ::SolidSeam::classifySelection {componentIds} {
    variable solidComponentIds; variable shellComponentIds; variable mode
    if {[llength $componentIds] < 2} { error [::SolidSeam::txt "至少选择两个 Components。" "Select at least two Components."] }
    set solidComponentIds {}; set shellComponentIds {}; set problems {}; set rows {}
    foreach componentId $componentIds {
        set row [::SolidSeam::classifyComponent $componentId]
        lappend rows $row
        switch -- [dict get $row mesh_class] {
            SOLID { lappend solidComponentIds $componentId }
            SHELL { lappend shellComponentIds $componentId }
            default { lappend problems "$componentId:[dict get $row mesh_class]" }
        }
    }
    if {[llength $problems] > 0} { error [::SolidSeam::txt "以下组件不能处理：$problems" "Unsupported components: $problems"] }
    set count [llength $componentIds]
    if {$count == 2 && [llength $solidComponentIds] == 2} { set mode SOLID_SOLID_PAIR
    } elseif {$count == 2 && [llength $solidComponentIds] == 1 && [llength $shellComponentIds] == 1} { set mode SOLID_SHELL_PAIR
    } elseif {$count > 2 && [llength $solidComponentIds] > 0 && [llength $shellComponentIds] > 0} { set mode MULTI_SOLID_SHELL
    } elseif {[llength $solidComponentIds] == 0} { error [::SolidSeam::txt "当前选择中不存在实体组件；Shell-Shell 请使用现有网格焊缝模块。" "No solid component is selected; use the existing shell weld module for Shell-Shell."]
    } else { error [::SolidSeam::txt "选择组合不受支持。多组件模式必须同时包含 Solid 和 Shell。" "Unsupported selection. Multi-component mode requires both Solid and Shell components."] }
    ::SolidSeam::log INFO "mode=$mode solids=$solidComponentIds shells=$shellComponentIds"
    return $rows
}
