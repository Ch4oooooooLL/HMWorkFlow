if {[namespace exists ::WeldIntegrityCheck]} {
    proc ::WeldIntegrityCheck::OpenWeldCreator {pairData} { ::MeshSeamWeld::openAutoCandidate $pairData }
}
