source [file join [file dirname [info script]] hm2019_penta_mig_common.tcl]

proc ::SolidSeamCommandProfile::realize {candidate profile} {
    # feconfig.cfg: CFG optistruct 119 penta (mig + B), filter=seam.
    return [::SolidSeamCommandProfile::realizePentaMig $candidate $profile 119 "penta (mig + B)"]
}
