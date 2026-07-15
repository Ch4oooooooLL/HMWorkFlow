proc ::SolidSeam::profileNameForRealization {realization} { return "${realization}_DEFAULT" }

proc ::SolidSeam::profileCommandName {realization} {
    switch -- $realization {
        PENTA_MIG_T { return hm2019_penta_mig_t }
        PENTA_MIG_L { return hm2019_penta_mig_l }
        PENTA_MIG_B { return hm2019_penta_mig_b }
        PENTA_MIG { return hm2019_penta_mig }
        default { error "Unsupported realization type: $realization" }
    }
}

proc ::SolidSeam::profileVerified {realization} {
    variable MODULE_DIR
    set path [file join $MODULE_DIR config realization_profiles.json]
    set data [::HWFlow::readTextFile $path]
    set profile [::SolidSeam::profileNameForRealization $realization]
    set escaped [regsub -all {([][(){}.*+?^$\\|])} $profile {\\\1}]
    return [regexp -nocase "\"$escaped\"\\s*:\\s*\\{\[^}]*\"verified\"\\s*:\\s*true" $data]
}

proc ::SolidSeam::profileNumericSetting {realization setting fallback} {
    variable MODULE_DIR
    set path [file join $MODULE_DIR config realization_profiles.json]
    set data [::HWFlow::readTextFile $path]
    set profile [::SolidSeam::profileNameForRealization $realization]
    set escapedProfile [regsub -all {([][(){}.*+?^$\\|])} $profile {\\\1}]
    set escapedSetting [regsub -all {([][(){}.*+?^$\\|])} $setting {\\\1}]
    set pattern [format {"%s"\s*:\s*\{[^\}]*"%s"\s*:\s*([-+0-9.eE]+)} $escapedProfile $escapedSetting]
    if {[regexp -nocase $pattern $data -> value]} {
        return $value
    }
    return $fallback
}

proc ::SolidSeam::loadRealizationProfile {realization} {
    variable MODULE_DIR
    if {![::SolidSeam::profileVerified $realization]} {
        error [::SolidSeam::txt \
            "$realization profile 尚未由目标 HM2019 Command File 验证，已阻止模型写入。" \
            "$realization profile is not verified from a target HM2019 Command File; model writes are blocked."]
    }
    set commandName [::SolidSeam::profileCommandName $realization]
    set path [file join $MODULE_DIR command_profiles "${commandName}.tcl"]
    if {![file isfile $path]} { error "Verified command profile file is missing: $path" }
    namespace eval ::SolidSeamCommandProfile {}
    catch {rename ::SolidSeamCommandProfile::realize {}}
    source $path
    if {[llength [info commands ::SolidSeamCommandProfile::realize]] == 0} { error "Command profile does not define ::SolidSeamCommandProfile::realize: $path" }
    return [dict create \
        profile_name [::SolidSeam::profileNameForRealization $realization] \
        realization_type $realization \
        command_profile $commandName \
        default_width [::SolidSeam::profileNumericSetting $realization default_width 6.0] \
        default_tolerance [::SolidSeam::profileNumericSetting $realization default_tolerance 15.0] \
    ]
}
