# setup.tcl -- prepare the MIDSURFED assembly for bom_material_assignment.
# Assemblies are HyperMesh-only entities and are NOT persisted in the .fem, so
# they must be (re)built at import time.  Best effort: if the command names
# differ on your HM build, create a MIDSURFED assembly manually and add the
# 35 target components below (use Model Browser -> right click -> Add to
# existing assembly, or drag components onto the assembly node).
# Execution: File -> Run -> Tcl script (or paste your whole import block).

# 1) create the MIDSURFED assembly if it does not already exist
if {![hm_entityexists assemblies MIDSURFED]} {
    *createentity assemblies name=MIDSURFED
}

# 2) add the 35 target components (the whole MIDSURFED scan set)
eval *assemblyaddmembers MIDSURFED comps 1001 1002 1003 1004 1005 1006 1007 1008 1009 1010 1011 1012 1013 1014 1015 1016 1017 1018 1019 1020 1021 1022 1023 1024 1025 1026 1027 1028 1029 1030 1031 1032 1033 1034 1035

puts "MIDSURFED assembly populated with 35 target components."
puts "Run bom_material_assignment to assign Q355 (E=206000 Nu=0.30 Rho=7.85e-9)."
