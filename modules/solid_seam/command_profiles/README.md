# HyperMesh 2019 realization command profiles

This directory contains the HM2019 OptiStruct seam realization profiles used by
the module. The custom seam FE type IDs come from the installed HM2019
`feconfig.cfg`; the creation command and result element configs were verified
against HM2019.0.0.70 with the combined validation FEM.

Each delivered wrapper exposes the following procedure and delegates to the
shared, validated HM2019 implementation:

```tcl
proc ::SolidSeamCommandProfile::realize {candidate profile} {
    # candidate is a dict containing source_component_id,
    # target_component_id, node_ids and selected realization metadata.
    # Return a dict with connector_id, connector_state, penta_ids,
    # and rbe3_ids. Raise a Tcl error on failure.
}
```

The profile files are `hm2019_penta_mig.tcl`, `hm2019_penta_mig_t.tcl`,
`hm2019_penta_mig_l.tcl`, and `hm2019_penta_mig_b.tcl`. Their FE type IDs are
125, 118, 117, and 119 respectively (the seam-filter entries in HM2019
`feconfig.cfg`).

The module refuses model writes until both conditions are met. The delivered
profiles implement that verified contract and validate the connector state plus
the generated PENTA6/RBE3 elements after every creation.
