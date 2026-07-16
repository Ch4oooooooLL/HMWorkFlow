proc ::HybridCore::pythonCandidates {} {
    variable ROOT_DIR
    # Deliberately do not fall back to a machine-wide Python.  Every
    # HyperMesh instance must own the portable interpreter shipped here.
    return [list [list [file normalize [file join $ROOT_DIR runtime python windows-x64 python.exe]]]]
}

proc ::HybridCore::probePython {candidate} {
    set executable [lindex $candidate 0]
    if {[file pathtype $executable] eq "absolute" && ![file isfile $executable]} { return 0 }
    return [expr {![catch {exec {*}$candidate -c {import sys; assert sys.version_info >= (3, 8); print(sys.version.split()[0])}}]}]
}

proc ::HybridCore::resolvePython {} {
    variable cachedPython
    variable ROOT_DIR
    if {$cachedPython ne ""} { return $cachedPython }
    foreach candidate [::HybridCore::pythonCandidates] {
        if {[::HybridCore::probePython $candidate]} {
            ::HybridCore::log INFO "python resolved executable=[lindex $candidate 0]"
            set cachedPython $candidate
            return $cachedPython
        }
    }
    set expected [file normalize [file join $ROOT_DIR runtime python windows-x64 python.exe]]
    error "The bundled HMWorkFlow Python 3.8+ runtime is missing or unusable: $expected"
}

proc ::HybridCore::pythonVersion {candidate} {
    if {[catch {exec {*}$candidate -c {import sys; print(sys.version.split()[0])}} version]} {
        return "unknown"
    }
    return [string trim $version]
}
