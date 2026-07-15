source [file join [file dirname [info script]] hm2019_penta_mig_common.tcl]

proc ::SolidSeamCommandProfile::realize {candidate profile} {
    # feconfig.cfg: CFG optistruct 118 penta (mig + T), filter=seam.
    return [::SolidSeamCommandProfile::realizePentaMig $candidate $profile 118 "penta (mig + T)"]
}
