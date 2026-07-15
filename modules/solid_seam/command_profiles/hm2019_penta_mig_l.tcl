source [file join [file dirname [info script]] hm2019_penta_mig_common.tcl]

proc ::SolidSeamCommandProfile::realize {candidate profile} {
    # feconfig.cfg: CFG optistruct 117 penta (mig + L), filter=seam.
    return [::SolidSeamCommandProfile::realizePentaMig $candidate $profile 117 "penta (mig + L)"]
}
