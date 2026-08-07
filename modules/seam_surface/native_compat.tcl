# ============================================================================
# native_compat.tcl - HyperMesh Tcl API compatibility layer for the geometry
# seam module.
#
# The executor only describes seam business semantics ("extend this source to
# that target"). Every HyperMesh-native detail that carries cross-version risk
# lives here:
#
#   * Current Component verification (never a silent catch-and-continue)
#   * Checked mark helpers (fail fast on geometry inputs)
#   * Public query APIs (hm_getthickness, hm_entityinfo) with legacy fallback
#   * cleanup_tolerance transaction (save/restore around *multi_surfs_lines_merge)
#   * Undocumented / private commands isolated in one place with explicit
#     comments about why they are used and how they must be verified.
#
# Compatibility baseline: HyperMesh 2019 (project baseline) and 2022.x.
# Commands that are not public in the Altair 2022 Help are isolated under
# ::hmtoolkit::seam::native::undocumented and must never be treated as a
# stable contract.
# ============================================================================

namespace eval ::hmtoolkit::seam::native {}
namespace eval ::hmtoolkit::seam::native::undocumented {}

# ---------------------------------------------------------------------------
# Current Component
# ---------------------------------------------------------------------------

# Public query first (hm_info currentcomponent, verified in the 2022.2 Help);
# hm_getcurrentcollector components stays as a legacy fallback only.
proc ::hmtoolkit::seam::native::current_component {} {
    if {[llength [info commands ::hm_info]] > 0} {
        if {![catch {set value [hm_info currentcomponent]}] && $value ne ""} {
            if {[string is integer -strict $value] && $value > 0} {
                return $value
            }
            # hm_info currentcomponent returns the component NAME on the
            # locally installed builds (2019.0.0.70 and 2022.0.0.33),
            # verified by the 2026-08-07 dual-version probe; convert it so
            # the post-set re-read verification actually runs.
            set byName [::HWFlow::componentIdByName $value]
            if {$byName ne ""} { return $byName }
        }
    }
    if {[llength [info commands ::hm_getcurrentcollector]] > 0} {
        if {![catch {set id [hm_getcurrentcollector components]}] &&
            [string is integer -strict $id] && $id > 0} {
            return $id
        }
    }
    return ""
}

# Set the current component and verify the result by re-reading it. The
# verification is best-effort on the project baseline: HyperMesh 2019 has no
# hm_getcurrentcollector command, so the re-read may be unavailable even
# though *currentcollector succeeded. A failed set is a hard error; an
# unverifiable or mismatched re-read is logged as a warning and the operation
# continues, because created_surfaces_for_component's owner check still
# catches surfaces that land in the wrong component.
proc ::hmtoolkit::seam::native::set_current_component_checked {name expectedId} {
    set hasCollector [expr {[llength [info commands ::*currentcollector]] > 0}]
    set ok 0
    if {$hasCollector} {
        foreach command [list \
            [list *currentcollector component $name] \
            [list *currentcollector components $name]] {
            if {![catch {uplevel #0 $command} err]} {
                set ok 1
                break
            }
        }
        if {!$ok} {
            error "Unable to set current component '$name'"
        }
    } else {
        ::hmtoolkit::seam::log::write WARN \
            "HyperMesh collector command unavailable; current component is not set for '$name'"
    }
    set actual [::hmtoolkit::seam::native::current_component]
    if {$actual ne ""} {
        if {$expectedId ne "" && $actual != $expectedId} {
            ::hmtoolkit::seam::log::write WARN \
                "Current component verification mismatch: expected $expectedId ($name), got $actual; continuing"
        }
        ::hmtoolkit::seam::log::write INFO "Current component verified: $actual ($name)"
        return $actual
    }
    if {$hasCollector} {
        ::hmtoolkit::seam::log::write WARN \
            "Current component could not be re-read after setting '$name' (HM2019 has no hm_getcurrentcollector); continuing"
        return $expectedId
    }
    return $expectedId
}

# Re-verify (and repair once) the current component before a native call that
# routes new entities into it, e.g. *connect_surfaces_11 advanced_options=59
# or *duplicatemark ... 1.
proc ::hmtoolkit::seam::native::ensure_current_component {name expectedId} {
    set actual [::hmtoolkit::seam::native::current_component]
    if {$actual ne "" && $expectedId ne "" && $actual == $expectedId} {
        return $actual
    }
    return [::hmtoolkit::seam::native::set_current_component_checked $name $expectedId]
}

# ---------------------------------------------------------------------------
# Checked mark helpers
# ---------------------------------------------------------------------------

# Fill markId with ids and fail fast when the mark comes out empty.
proc ::hmtoolkit::seam::native::mark_checked {entityType markId ids} {
    catch {*clearmark $entityType $markId}
    if {[llength $ids] == 0} {
        error "Refusing to build an empty $entityType mark $markId"
    }
    if {[catch {
        eval [linsert $ids 0 *createmark $entityType $markId]
    } err]} {
        error "Failed to mark $entityType $markId with $ids: $err"
    }
    set actual {}
    catch {set actual [hm_getmark $entityType $markId]}
    if {[llength $actual] == 0} {
        error "Mark $entityType $markId is empty after createmark ($ids)"
    }
    return [lsort -integer -unique $actual]
}

# Mark every entity currently owned by a component. Used wherever a native
# command must operate on the full contents of a temporary/result component.
proc ::hmtoolkit::seam::native::mark_by_component_checked {entityType markId compName} {
    catch {*clearmark $entityType $markId}
    if {[catch {
        *createmark $entityType $markId "by comp" $compName
    } err]} {
        error "Failed to mark $entityType in component '$compName': $err"
    }
    set ids {}
    catch {set ids [hm_getmark $entityType $markId]}
    if {[llength $ids] == 0} {
        error "No $entityType found in component '$compName'"
    }
    return [lsort -integer -unique $ids]
}

# ---------------------------------------------------------------------------
# Thickness
# ---------------------------------------------------------------------------

# Public hm_getthickness is the primary source of plate thickness; the
# Component-name _Txx parser is only a legacy fallback (see report section 10).
proc ::hmtoolkit::seam::native::component_thickness {compId} {
    if {[llength [info commands ::hm_getthickness]] > 0} {
        if {![catch {set value [hm_getthickness comps $compId]}] &&
            [string is double -strict $value] && $value > 0.0} {
            return [expr {double($value)}]
        }
    }
    return ""
}

# ---------------------------------------------------------------------------
# cleanup_tolerance transaction for *multi_surfs_lines_merge
# ---------------------------------------------------------------------------

# Save the session cleanup tolerance, run body with a fixed tolerance, then
# restore the previous value. The merge command consumes the global Modeling
# Option, so leaving it untouched between users/sessions would make CONNECT and
# COMBINE results session-dependent.
proc ::hmtoolkit::seam::native::with_cleanup_tolerance {tolerance body} {
    set old ""
    set canManage 0
    if {[llength [info commands ::hm_getoption]] > 0 &&
        [llength [info commands ::*setoption]] > 0} {
        if {![catch {set old [hm_getoption cleanup_tolerance]}]} {
            if {[catch {*setoption cleanup_tolerance=$tolerance} err]} {
                error "Unable to set cleanup tolerance to $tolerance: $err"
            }
            set canManage 1
        }
    }
    if {!$canManage} {
        ::hmtoolkit::seam::log::write WARN \
            "HyperMesh option commands unavailable; cleanup tolerance transaction skipped"
    }
    set code [catch {uplevel 1 $body} value options]
    if {$canManage} { catch {*setoption cleanup_tolerance=$old} }
    if {$code} {
        return -options $options $value
    }
    return $value
}

# ---------------------------------------------------------------------------
# Display state queries (HM2019 baseline)
# ---------------------------------------------------------------------------

# hm_getvalue ... dataname=visible/displayed is the legacy query that works on
# HyperMesh 2019 and 2022.2. The hm_entityinfo geometryvisible/elementsvisible
# forms were introduced with the 2026-08-07 audit (verified on 2022.3 only)
# and are not used on the project baseline.
proc ::hmtoolkit::seam::native::geometry_visible {compId} {
    if {![catch {set v [hm_getvalue comps id=$compId dataname=visible]}] &&
        [string is boolean -strict $v]} {
        return [expr {$v ? 1 : 0}]
    }
    return ""
}

proc ::hmtoolkit::seam::native::elements_visible {compId} {
    if {![catch {set v [hm_getvalue comps id=$compId dataname=displayed]}] &&
        [string is boolean -strict $v]} {
        return [expr {$v ? 1 : 0}]
    }
    return ""
}

# ---------------------------------------------------------------------------
# Undocumented / private commands. Isolated so they cannot spread through the
# business layer. Every use must state why, on which version it was verified,
# and how it degrades.
# ---------------------------------------------------------------------------

# *trim_solids_by_surfaces is listed under "Undocumented Tcl Modify Commands"
# in the Altair 2022 Help. It is required by the current L_SURF solid-based
# pipeline; a public *surfmark_trim_by_surfmark-based rewrite is tracked as
# the mid-term replacement. Verify behavior on HM2019 and HM2022 with the same
# fixture before relying on it.
proc ::hmtoolkit::seam::native::undocumented::trim_solids_by_surfaces {solidMarkId surfMarkId mode} {
    ::hmtoolkit::seam::log::write WARN \
        "Undocumented command *trim_solids_by_surfaces $solidMarkId $surfMarkId $mode (verify on HM2019/HM2022)"
    return [*trim_solids_by_surfaces $solidMarkId $surfMarkId $mode]
}

# *edgesmarkaddpoints is also listed under "Undocumented Tcl Modify Commands"
# (DISTRIBUTE_POINTS). Keep it behind this wrapper and add a real-kernel smoke
# test per supported HyperMesh version.
proc ::hmtoolkit::seam::native::undocumented::edges_mark_add_points {markId count} {
    ::hmtoolkit::seam::log::write WARN \
        "Undocumented command *edgesmarkaddpoints $markId $count (verify on HM2019/HM2022)"
    return [*edgesmarkaddpoints $markId $count]
}

# hm_private_frwk is a private/internal dependency, not part of the public
# 2022 Help. It must never be a correctness contract; public history states
# (*startnotehistorystate/*endnotehistorystate) remain the undo/redo owner.
proc ::hmtoolkit::seam::native::history_from_tcl {enabled} {
    if {[::hmtoolkit::seam::config::get private_history_api] > 0 &&
        [llength [info commands ::hm_private_frwk]] > 0} {
        catch {hm_private_frwk enablehistoryfromtcl $enabled}
    }
}
