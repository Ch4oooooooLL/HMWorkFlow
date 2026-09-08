# ============================================================================
# Contact Setup - Component AutoContact backend
# HyperMesh 2019 / 2019.1, OptiStruct profile
# ============================================================================

proc ::ContactSetup::autoContactDefinitionCode {value} {
    switch -- $value {
        CONTACT { return 0 }
        TIE { return 1 }
    }
    error "Unsupported AutoContact definition: $value"
}

proc ::ContactSetup::autoContactMainCode {value} {
    switch -- $value {
        SET_ELEM { return 0 }
        SURF { return 1 }
    }
    error "Unsupported AutoContact main entity type: $value"
}

proc ::ContactSetup::autoContactSecondaryCode {value} {
    switch -- $value {
        SET_GRID { return 0 }
        SET_ELEM { return 1 }
        SURF { return 2 }
    }
    error "Unsupported AutoContact secondary entity type: $value"
}

proc ::ContactSetup::validateAutoContact {} {
    variable ui
    if {[llength $ui(selectedCompIds)] < 2} {
        error [::HWFlow::txt \
            "AutoContact 至少需要选择两个组件。" \
            "AutoContact requires at least two components."]
    }
    if {![string is double -strict $ui(tolerance)] || $ui(tolerance) < 0.0 ||
        (!$ui(use_shell_thickness) && $ui(tolerance) <= 0.0)} {
        error [::HWFlow::txt \
            "Tolerance 必须是有效数值；未使用壳厚时必须大于 0。" \
            "Tolerance must be numeric and greater than zero unless shell thickness is used."]
    }
    if {![string is double -strict $ui(reverse_angle)] ||
        $ui(reverse_angle) < 0.0 || $ui(reverse_angle) > 180.0} {
        error [::HWFlow::txt "反向角必须在 0 到 180 度之间。" "Reverse angle must be between 0 and 180 degrees."]
    }
    foreach key {use_shell_thickness consolidate intersection_check review_mode} {
        if {$ui($key) ni {0 1}} {
            error [::HWFlow::txt "AutoContact 开关参数无效。" "Invalid AutoContact toggle value."]
        }
    }
    ::ContactSetup::autoContactDefinitionCode $ui(definition_type)
    ::ContactSetup::autoContactMainCode $ui(main_entity_type)
    ::ContactSetup::autoContactSecondaryCode $ui(secondary_entity_type)
    if {$ui(contact_type) ni {SLIDE STICK FREEZE}} {
        error [::HWFlow::txt "内置接触类型无效。" "Invalid built-in contact type."]
    }
    if {$ui(property_mode) ni {BUILTIN FRICTION EXISTING_PCONT}} {
        error [::HWFlow::txt "Contact Property 模式无效。" "Invalid Contact Property mode."]
    }
    if {$ui(definition_type) eq "CONTACT" && $ui(property_mode) eq "FRICTION" &&
        (![string is double -strict $ui(friction)] || $ui(friction) < 0.0)} {
        error [::HWFlow::txt "摩擦系数必须是非负数。" "Friction must be a non-negative number."]
    }
    if {$ui(definition_type) eq "CONTACT" && $ui(property_mode) eq "EXISTING_PCONT" &&
        (![string is integer -strict $ui(property_id)] || $ui(property_id) <= 0)} {
        error [::HWFlow::txt "Existing PCONT 模式需要大于 0 的 Property ID。" "Existing PCONT mode requires a positive Property ID."]
    }
}

# Return exactly the documented HM2019 base signature after the command name.
# Keeping this conversion independent of the UI makes it easy to unit-test and
# avoids scattering solver numeric codes through widget callbacks.
proc ::ContactSetup::autoContactArguments {} {
    variable ui
    set definitionCode [::ContactSetup::autoContactDefinitionCode $ui(definition_type)]
    set propertyCode 0
    set propertyId 0
    set friction 0.0
    if {$definitionCode == 0} {
        switch -- $ui(property_mode) {
            BUILTIN { set propertyCode [::ContactSetup::contactTypeValue $ui(contact_type)] }
            FRICTION { set friction $ui(friction) }
            EXISTING_PCONT { set propertyId $ui(property_id) }
        }
    }
    set skipPreview [expr {$ui(review_mode) ? 0 : 1}]
    return [list \
        comps 1 $ui(tolerance) $ui(reverse_angle) \
        $ui(use_shell_thickness) $ui(consolidate) $ui(intersection_check) \
        $definitionCode \
        [::ContactSetup::autoContactMainCode $ui(main_entity_type)] \
        [::ContactSetup::autoContactSecondaryCode $ui(secondary_entity_type)] \
        $propertyCode $propertyId $friction 0 0 0 $skipPreview]
}

proc ::ContactSetup::createAutoContact {} {
    variable ui
    set historyStarted 0
    set code [catch {
        ::ContactSetup::validateAutoContact
        ::ContactSetup::saveRules

        catch {*clearmark comps 1}
        if {[catch {eval *createmark comps 1 $ui(selectedCompIds)} markError]} {
            error [::HWFlow::txt \
                "无法创建组件选择 Mark：$markError" \
                "Could not create the component selection mark: $markError"]
        }
        set validIds [hm_getmark comps 1]
        if {[llength $validIds] < 2} {
            error [::HWFlow::txt \
                "有效组件数量不足两个，请重新选择。" \
                "Fewer than two valid components remain; select them again."]
        }

        if {![catch {*startnotehistorystate "Create AutoContact"}]} { set historyStarted 1 }
        set args [::ContactSetup::autoContactArguments]
        ::ContactSetup::msg \
            "正在对 [llength $validIds] 个组件执行 AutoContact 检测..." \
            "Running AutoContact detection on [llength $validIds] components..."
        uplevel #0 [linsert $args 0 *detectandcreateface2facecontacts]
        if {$historyStarted} {
            catch {*endnotehistorystate "Create AutoContact"}
            set historyStarted 0
        }
        catch {*clearmark comps 1}
        catch {::HWFlow::refreshBrowser}
        set mode [expr {$ui(review_mode) ? "Review" : [::HWFlow::txt "直接创建" "Direct create"]}]
        ::ContactSetup::msg \
            "AutoContact 创建完成：组件=[llength $validIds]，定义=$ui(definition_type)，模式=$mode。" \
            "AutoContact completed: components=[llength $validIds], definition=$ui(definition_type), mode=$mode."
    } err]
    if {$code} {
        if {$historyStarted} {
            catch {*endnotehistorystate "Create AutoContact"}
            catch {*undohistorystate 1}
        }
        catch {*clearmark comps 1}
        tk_messageBox -icon error -title [::HWFlow::txt "Contact Setup" "Contact Setup"] -message $err
        return 0
    }
    return 1
}
