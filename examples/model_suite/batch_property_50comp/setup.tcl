# BatchProperty_50comp preparation (run AFTER importing the .fem).
# The module expects UNPROPERTIED components; the imported deck carries a
# same-id PSHELL per component so .fem import groups elements correctly.
# This script clears the property of EVERY component.
# Best effort: if *propertyupdate is rejected by your HyperMesh build, use
# the GUI: Model Browser -> select all components -> clear the Property column.

*createmark comps 1 all
*propertyupdate comps 1 ""
puts "BatchProperty setup: properties cleared for all components."
puts "To validate the skip-existing-property path afterwards, re-assign a"
puts "PSHELL to V41_PROP_T2.0_Q355 and V42_PROP_T2.5_STEEL and re-run the module."
