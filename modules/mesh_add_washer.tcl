# ============================================================================
# Mesh Add Washer (::WasherTool)
# HyperMesh 2019 / 2022 - pure Tcl, FE mesh only, no geometry dependency
#
# Creates a regular washer on an existing FE hole of a 2D shell mesh:
#   1. The user picks ONE node on the hole free-edge boundary.
#   2. The owning component(s) are resolved through native node/element data
#      names only (no ID ranges, no name guessing).
#   3. HyperMesh native *findedges (free edges) provides the temporary ^edges
#      plot elements; the edge chain containing the seed node is traced by
#      pure topology (BFS over node->edge adjacency, never by coordinates).
#   4. The chain must be a simple closed loop: every node of the chain has
#      edge degree exactly 2 (1 = open edge, >2 = branching; both rejected).
#   5. *add_multi_washer_elements receives ONLY the single seed node and
#      rebuilds the hole boundary at hole_density while laying the washer
#      layers. No AutoMesh pass is required before the call.
#   6. The result is validated and all temporary ^edges data is cleaned up.
#
# All HyperMesh commands used here were verified against the local HyperMesh
# 2019 installation (2019.0.0.70):
#   - *add_multi_washer_elements positional syntax and the string-array
#     format: <install>/hm/scripts/macroAddWasher.tcl (native Utility macro)
#   - *findedges comps <mark> 0 (old positional syntax, 0 = free edges)
#   - hm_nodelist <elem_id>: used by the native midsurf/weld scripts
#
# First version limits: 2D shell mesh, single closed FE hole, one seed node,
# identical circumferential density for every washer ring. The string-array
# density request is passed through verbatim - if the native mesher refuses a
# request (e.g. growing 8 -> 20) the command error is reported, never clamped.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source -encoding utf-8 [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::WasherTool {
    # ------------------------------------------------------------------
    # Configuration - the single place to tune the tool. No UI yet; the
    # toolbox Settings button stays disabled for this module on purpose.
    # ------------------------------------------------------------------
    variable holeDensity 12        ;# final node count around the hole (integer >= 4)
    variable layerWidths {5.0 5.0} ;# radial width of EACH washer layer, not cumulative radii
    variable featureAngle 30.0     ;# native feature angle for hole boundary recognition
    variable createRigid 0         ;# rigid_spider flag; this release only supports 0
    variable createLocalSystem 0   ;# local coordinate system flag; this release only supports 0

    variable minHoleNodes 4        ;# reject hole chains shorter than this
    variable debugMode 1           ;# print the WasherTool debug block before the washer call

    # Temporary free-edge component names. The ^ prefix keeps them hidden in
    # the Model Browser; both are removed again before the tool returns.
    variable EDGE_TEMP_PREFIX "^WTE_"
    variable EDGE_KEEP_PREFIX "^WT_KEEP_"
}

# ----------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------
proc ::WasherTool::log {message} {
    variable debugMode
    if {!$debugMode} {
        return
    }
    catch {puts "WasherTool: $message"}
    catch {hm_usermessage "WasherTool: $message"}
}

# Print the pre-mutation debug block. Never dumps long ID lists.
proc ::WasherTool::logPlan {seedNode compId compName oldDensity} {
    variable holeDensity
    variable layerWidths
    variable featureAngle
    set lines [list \
        "WasherTool:" \
        "Seed Node      = $seedNode" \
        "Component      = $compName (id $compId)" \
        "Current Density= $oldDensity" \
        "Target Density = $holeDensity" \
        "Layers         = [llength $layerWidths]" \
        "Widths         = [join $layerWidths { }]" \
        "Feature Angle  = $featureAngle"]
    foreach line $lines {
        catch {puts $line}
    }
    catch {hm_usermessage "WasherTool: seed=$seedNode comp=$compName density $oldDensity -> $holeDensity"}
    if {$holeDensity > 3 * $oldDensity} {
        ::WasherTool::log "target density is more than 3x the current density; the native GUI macro refuses such requests, this tool still attempts it"
    }
}

# ----------------------------------------------------------------------
# Parameter validation - everything that can fail without touching the model
# ----------------------------------------------------------------------
proc ::WasherTool::validateParameters {} {
    variable holeDensity
    variable layerWidths
    variable featureAngle
    variable createRigid
    variable createLocalSystem
    variable minHoleNodes

    if {![string is integer -strict $holeDensity] || $holeDensity < 4} {
        error [::HWFlow::txt \
            "holeDensity 必须是 >= 4 的整数（当前值：$holeDensity）。" \
            "holeDensity must be an integer >= 4 (current value: $holeDensity)."]
    }
    if {[llength $layerWidths] == 0} {
        error [::HWFlow::txt \
            "layerWidths 不能为空，至少需要一层 washer。" \
            "layerWidths is empty; at least one washer layer is required."]
    }
    foreach width $layerWidths {
        if {![string is double -strict $width] || $width <= 0.0} {
            error [::HWFlow::txt \
                "每层 washer 宽度必须是大于 0 的数值（当前值：$width）。" \
                "Every layer width must be a number greater than 0 (current value: $width)."]
        }
    }
    if {![string is double -strict $featureAngle] || $featureAngle <= 0.0 || $featureAngle >= 180.0} {
        error [::HWFlow::txt \
            "featureAngle 必须在 0-180 之间（当前值：$featureAngle）。" \
            "featureAngle must be between 0 and 180 (current value: $featureAngle)."]
    }
    if {$createRigid != 0} {
        error [::HWFlow::txt \
            "本版本不支持自动创建 rigid（createRigid 必须为 0）。" \
            "This release does not create rigid spiders (createRigid must be 0)."]
    }
    if {$createLocalSystem != 0} {
        error [::HWFlow::txt \
            "本版本不支持自动创建局部坐标系（createLocalSystem 必须为 0）。" \
            "This release does not create local coordinate systems (createLocalSystem must be 0)."]
    }
    if {![string is integer -strict $minHoleNodes] || $minHoleNodes < 3} {
        error [::HWFlow::txt \
            "minHoleNodes 必须是 >= 3 的整数（当前值：$minHoleNodes）。" \
            "minHoleNodes must be an integer >= 3 (current value: $minHoleNodes)."]
    }
}

# ----------------------------------------------------------------------
# Seed node selection
# ----------------------------------------------------------------------
proc ::WasherTool::selectSeedNode {} {
    catch {*clearmark nodes 1}
    set selected [::HWFlow::nativeMarkPanel nodes 1 [::HWFlow::txt \
        "选择孔边自由边界上的一个节点；中键确认，Esc 取消" \
        "Select one node on the hole free edge; middle-click to confirm, Esc to cancel"]]
    # Prefer the native mark length; fall back to the returned list.
    set count [llength $selected]
    catch {set count [hm_marklength nodes 1]}
    catch {*clearmark nodes 1}
    if {$count == 0} {
        # No selection: normal, silent exit.
        return ""
    }
    if {$count > 1} {
        error [::HWFlow::txt \
            "选择了 $count 个节点；本工具每次只处理一个孔边节点。" \
            "$count nodes were selected; this tool processes exactly one hole-edge node per run."]
    }
    if {[llength $selected] == 0} {
        return ""
    }
    return [lindex $selected 0]
}

# ----------------------------------------------------------------------
# Component resolution (native relationships only)
# ----------------------------------------------------------------------
proc ::WasherTool::elementComponentId {elemId} {
    foreach dataName {collector.id component.id comp.id component collector} {
        if {[catch {set value [hm_getvalue elems id=$elemId dataname=$dataName]}] ||
            $value eq "" || $value eq "0"} {
            continue
        }
        if {[string is integer -strict $value]} {
            return $value
        }
        set componentId [::HWFlow::componentIdByName $value]
        if {$componentId ne ""} {
            return $componentId
        }
    }
    return ""
}

proc ::WasherTool::attachedElementIds {nodeId} {
    set elemIds {}
    foreach selector [list \
            [list "by node id" $nodeId] \
            [list "by node" $nodeId] \
            [list "by nodes" $nodeId]] {
        catch {*clearmark elems 3}
        if {![catch {eval *createmark elems 3 $selector}]} {
            catch {set elemIds [hm_getmark elems 3]}
        }
        catch {*clearmark elems 3}
        if {[llength $elemIds] > 0} {
            break
        }
    }
    return $elemIds
}

# Components that reference the seed node: the node's own collector plus the
# components of every element attached to it (at equivalenced interfaces one
# node can serve several components).
proc ::WasherTool::findCandidateComponents {seedNode} {
    set candidates {}
    foreach dataName {collector.id component.id comp.id} {
        if {![catch {set componentId [hm_getvalue nodes id=$seedNode dataname=$dataName]}] &&
            [string is integer -strict $componentId] && $componentId > 0} {
            lappend candidates $componentId
            break
        }
    }
    foreach elemId [::WasherTool::attachedElementIds $seedNode] {
        set componentId [::WasherTool::elementComponentId $elemId]
        if {$componentId ne "" && $componentId > 0} {
            lappend candidates $componentId
        }
    }
    return [lsort -integer -unique $candidates]
}

# Returns {compId disambiguated} - disambiguated is 1 when several components
# referenced the seed node and the free-edge test picked exactly one.
proc ::WasherTool::resolveTargetComponent {seedNode} {
    set candidates [::WasherTool::findCandidateComponents $seedNode]
    if {[llength $candidates] == 0} {
        error [::HWFlow::txt \
            "无法确定所选节点所属的 component。" \
            "Cannot determine the component that owns the selected node."]
    }
    if {[llength $candidates] == 1} {
        return [list [lindex $candidates 0] 0]
    }
    # Several components reference the node: keep only those whose free-edge
    # set actually contains the seed node. Never pick one silently.
    set qualified {}
    set serial 0
    foreach componentId $candidates {
        incr serial
        if {[::WasherTool::componentHasSeedOnFreeEdge $componentId $seedNode $serial]} {
            lappend qualified $componentId
        }
    }
    if {[llength $qualified] == 0} {
        error [::HWFlow::txt \
            "所选节点不在任何候选 component 的自由边上。" \
            "Selected node is not on a free edge of any candidate component."]
    }
    if {[llength $qualified] > 1} {
        error [::HWFlow::txt \
            "所选节点同时属于多个自由边 component（$qualified），本次不处理。" \
            "Selected node belongs to multiple free-edge components ($qualified); nothing was modified."]
    }
    return [list [lindex $qualified 0] 1]
}

# ----------------------------------------------------------------------
# Native free-edge detection with temporary ^edges handling
# ----------------------------------------------------------------------
proc ::WasherTool::markComponents {compIds markId} {
    set expected [llength [lsort -integer -unique $compIds]]
    foreach entityType {comps components component} {
        catch {*clearmark $entityType $markId}
        if {![catch {eval *createmark $entityType $markId $compIds}]} {
            set marked {}
            catch {set marked [hm_getmark $entityType $markId]}
            if {[llength $marked] == $expected} {
                return 1
            }
        }
        catch {*clearmark $entityType $markId}
    }
    return 0
}

proc ::WasherTool::renameComponentById {componentId newName} {
    set oldName [::HWFlow::componentName $componentId]
    if {$oldName eq $newName} {
        return $componentId
    }
    set lastErr ""
    foreach entityType {component components comps} {
        if {![catch {*renamecollector $entityType $oldName $newName} renameErr]} {
            return $componentId
        }
        set lastErr $renameErr
    }
    error "Could not rename component $oldName to $newName: $lastErr"
}

proc ::WasherTool::deleteComponentById {componentId} {
    if {$componentId eq ""} {
        return 0
    }
    foreach entityType {components comps component} {
        foreach selector [list [list $componentId] [list "by id only" $componentId]] {
            catch {*clearmark $entityType 2}
            if {![catch {eval *createmark $entityType 2 $selector}]} {
                set marked {}
                catch {set marked [hm_getmark $entityType 2]}
                if {[lsearch -exact $marked $componentId] >= 0} {
                    set deleted [expr {![catch {*deletemark $entityType 2}]}]
                    catch {*clearmark $entityType 2}
                    return $deleted
                }
            }
        }
        catch {*clearmark $entityType 2}
    }
    return 0
}

# Best-effort sweeper for stranded task-owned temporary components. The
# normal path cleans up inside buildFreeEdges; this only runs on unexpected
# failure so a user ^edges collector is never deleted (only renamed back).
proc ::WasherTool::cleanupTempEdges {} {
    variable EDGE_TEMP_PREFIX
    variable EDGE_KEEP_PREFIX
    foreach compId [::HWFlow::componentIds 2] {
        set name ""
        catch {set name [::HWFlow::componentName $compId]}
        if {[string match "${EDGE_TEMP_PREFIX}*" $name]} {
            catch {::WasherTool::deleteComponentById $compId}
        }
    }
    # A leftover keep-copy means the restore rename failed: put it back.
    if {[::HWFlow::componentIdByName "^edges"] eq ""} {
        foreach compId [::HWFlow::componentIds 2] {
            set name ""
            catch {set name [::HWFlow::componentName $compId]}
            if {[string match "${EDGE_KEEP_PREFIX}*" $name]} {
                catch {::WasherTool::renameComponentById $compId "^edges"}
                break
            }
        }
    }
    return ""
}

# Runs *findedges (free edges) for one component and returns the plot element
# IDs of the fresh result. A pre-existing ^edges collector is renamed away for
# the duration of the call and restored afterwards; the task-owned result
# component is always deleted again.
proc ::WasherTool::buildFreeEdges {compId {serial 1}} {
    variable EDGE_TEMP_PREFIX
    variable EDGE_KEEP_PREFIX

    set existingEdgesId [::HWFlow::componentIdByName "^edges"]
    set preservedName ""
    if {$existingEdgesId ne ""} {
        set preservedName "${EDGE_KEEP_PREFIX}[expr {abs([clock clicks])}]"
        ::WasherTool::renameComponentById $existingEdgesId $preservedName
    }

    set edgeComponentId ""
    set edgeElems {}
    set code 0
    set edgeErr ""
    if {[catch {
        if {![::WasherTool::markComponents [list $compId] 1]} {
            error "Could not mark component $compId for native free-edge detection."
        }
        # HyperMesh 2019 positional syntax: <entity type> <mark id> <edge type>
        # 0 = free edges. The command creates 2-node plot elements inside a
        # fresh ^edges component.
        *findedges comps 1 0
        set edgeComponentId [::HWFlow::componentIdByName "^edges"]
        if {$edgeComponentId eq "" ||
            ($existingEdgesId ne "" && $edgeComponentId == $existingEdgesId)} {
            error "HyperMesh did not create a new ^edges component for component $compId."
        }
        ::WasherTool::renameComponentById $edgeComponentId \
            "${EDGE_TEMP_PREFIX}${compId}_${serial}"
    } edgeErr]} {
        set code 1
    }
    catch {*clearmark comps 1}
    catch {*clearmark components 1}

    if {!$code && $edgeComponentId ne ""} {
        if {[catch {
            set edgeElems [::HWFlow::getCompEntityIds $edgeComponentId elems elems]
        } readErr]} {
            set code 1
            set edgeErr $readErr
        }
    }
    if {$edgeComponentId ne "" && ($existingEdgesId eq "" || $edgeComponentId != $existingEdgesId)} {
        catch {::WasherTool::deleteComponentById $edgeComponentId}
    }
    if {$preservedName ne ""} {
        if {[catch {::WasherTool::renameComponentById $existingEdgesId "^edges"} restoreErr]} {
            append edgeErr " Existing ^edges restoration also failed: $restoreErr"
            set code 1
        }
    }
    if {$code} {
        error $edgeErr
    }
    return $edgeElems
}

# ----------------------------------------------------------------------
# Edge topology from plot elements
# ----------------------------------------------------------------------
# Returns {edgeToNodes nodeToEdges} as two Tcl dicts:
#   edgeToNodes(edgeId) = {n1 n2}
#   nodeToEdges(nodeId) = {edge1 edge2 ...}
proc ::WasherTool::buildEdgeTopology {edgeElems} {
    set edgeToNodes [dict create]
    set nodeToEdges [dict create]
    set processed 0
    foreach elemId [lsort -integer -unique $edgeElems] {
        set nodes {}
        if {[catch {set nodes [hm_nodelist $elemId]}]} {
            continue
        }
        if {[llength $nodes] != 2} {
            continue
        }
        lassign $nodes first second
        if {$first eq "" || $second eq "" || $first == $second} {
            continue
        }
        dict set edgeToNodes $elemId [list $first $second]
        dict lappend nodeToEdges $first $elemId
        dict lappend nodeToEdges $second $elemId
        incr processed
        if {$processed % 5000 == 0} {
            ::WasherTool::log "reading free-edge plot elements $processed..."
        }
    }
    return [list $edgeToNodes $nodeToEdges]
}

# Connectivity-only BFS from the seed node over nodeToEdges. Returns
# {holeEdgeElems holeNodes}. Errors when the seed node sits on no free edge.
proc ::WasherTool::extractChainFromSeed {seedNode edgeToNodes nodeToEdges} {
    if {![dict exists $nodeToEdges $seedNode]} {
        error [::HWFlow::txt \
            "所选节点不在任何自由边上。" \
            "Selected node is not on a free edge."]
    }
    set visitedEdges [dict create]
    set visitedNodes [dict create]
    dict set visitedNodes $seedNode 1
    set queue [list $seedNode]
    while {[llength $queue] > 0} {
        set nodeId [lindex $queue 0]
        set queue [lrange $queue 1 end]
        foreach edgeId [dict get $nodeToEdges $nodeId] {
            if {[dict exists $visitedEdges $edgeId]} {
                continue
            }
            dict set visitedEdges $edgeId 1
            lassign [dict get $edgeToNodes $edgeId] first second
            set other $second
            if {$first != $nodeId} {
                set other $first
            }
            if {![dict exists $visitedNodes $other]} {
                dict set visitedNodes $other 1
                lappend queue $other
            }
        }
    }
    return [list [dict keys $visitedEdges] [dict keys $visitedNodes]]
}

# A simple closed hole boundary requires every node of the chain to have edge
# degree exactly 2 within the chain. degree 1 = open edge, degree > 2 =
# branching / T-connection; both are rejected without modifying the mesh.
proc ::WasherTool::validateClosedLoop {holeNodes holeEdges nodeToEdges} {
    variable minHoleNodes
    set edgeDict [dict create]
    foreach edgeId $holeEdges {
        dict set edgeDict $edgeId 1
    }
    foreach nodeId $holeNodes {
        set degree 0
        foreach edgeId [dict get $nodeToEdges $nodeId] {
            if {[dict exists $edgeDict $edgeId]} {
                incr degree
            }
        }
        if {$degree == 1} {
            error [::HWFlow::txt \
                "自由边链在节点 $nodeId 处不闭合（开放边），本次不处理。" \
                "The free-edge chain is not closed (open end at node $nodeId); nothing was modified."]
        }
        if {$degree > 2} {
            error [::HWFlow::txt \
                "自由边链在节点 $nodeId 处存在分叉/T 连接，本次不处理。" \
                "The free-edge chain branches at node $nodeId (T-connection); nothing was modified."]
        }
    }
    if {[llength $holeNodes] < $minHoleNodes} {
        error [::HWFlow::txt \
            "闭合自由边链只有 [llength $holeNodes] 个节点，少于最小要求 $minHoleNodes。" \
            "The closed free-edge chain has only [llength $holeNodes] nodes, below the minimum of $minHoleNodes."]
    }
    return 1
}

# Used only when several components reference the seed node.
proc ::WasherTool::componentHasSeedOnFreeEdge {compId seedNode {serial 1}} {
    set onEdge 0
    set code [catch {
        set edgeElems [::WasherTool::buildFreeEdges $compId $serial]
        if {[llength $edgeElems] > 0} {
            lassign [::WasherTool::buildEdgeTopology $edgeElems] edgeToNodes nodeToEdges
            if {[dict exists $nodeToEdges $seedNode]} {
                set onEdge 1
            }
        }
    } err]
    if {$code} {
        ::WasherTool::log "free-edge test for component $compId failed: $err"
        return 0
    }
    return $onEdge
}

# ----------------------------------------------------------------------
# Washer string array
# ----------------------------------------------------------------------
proc ::WasherTool::formatWidth {width} {
    set text [format %.6g $width]
    if {![string match "*.*" $text] && ![string match "*e*" [string tolower $text]]} {
        append text ".0"
    }
    return $text
}

# Builds the *createstringarray payload. Returns {strings stringCount}.
#   varying widths {4.0 5.0 6.0} with density 12 ->
#     "layer_number = 3 uniform_layers = 0 hole_density = 12" "1 4.0" "1 5.0" "1 6.0"
#   identical widths {5.0 5.0 5.0} with density 12 ->
#     "layer_number = 3 uniform_layers = 1 hole_density = 12" "1 5.0"
# The leading "1" of a width string is the native width type (1 = absolute
# width, 0 = scale), matching GetWidthType in macroAddWasher.tcl.
proc ::WasherTool::buildWasherStringArray {holeDensity layerWidths} {
    set layerCount [llength $layerWidths]
    set first [lindex $layerWidths 0]
    set uniform 1
    foreach width $layerWidths {
        if {abs($width - $first) > 1e-9} {
            set uniform 0
            break
        }
    }
    set header [format "layer_number = %d uniform_layers = %d hole_density = %d" \
        $layerCount $uniform $holeDensity]
    set strings [list $header]
    if {$uniform} {
        lappend strings "1 [::WasherTool::formatWidth $first]"
    } else {
        foreach width $layerWidths {
            lappend strings "1 [::WasherTool::formatWidth $width]"
        }
    }
    return [list $strings [llength $strings]]
}

# ----------------------------------------------------------------------
# The single model-mutating step
# ----------------------------------------------------------------------
proc ::WasherTool::createWasher {seedNode stringArray stringCount} {
    variable featureAngle
    variable createRigid
    variable createLocalSystem
    catch {*clearmark nodes 1}
    *createmark nodes 1 $seedNode
    eval *createstringarray $stringCount $stringArray
    # *add_multi_washer_elements - HyperMesh 2019 positional arguments,
    # verified against <install>/hm/scripts/macroAddWasher.tcl:
    #   1                  -> node_mark_id: mark 1 holds ONLY the single seed
    #                         node (one seed node per hole)
    #   $featureAngle      -> feature_angle: boundary recognition angle
    #   1                  -> string_array_id: the array just created
    #   $stringCount       -> number_of_strings: layer count + 1 header string
    #   2                  -> periphery_node_mark_id: HyperMesh returns the new
    #                         hole-ring nodes on mark 2 for QA
    #   0                  -> background_elem_mark_id: no pre-marked background
    #                         elements; HyperMesh removes the overlaid background
    #                         elements and updates connectivity itself
    #   $createRigid       -> rigid_spider: 0 = do not create an RBE2/RBE3 spider
    #   $createLocalSystem -> local_coordinate_system: 0 = do not create a local system
    *add_multi_washer_elements 1 $featureAngle 1 $stringCount 2 0 $createRigid $createLocalSystem
    set peripheryIds {}
    catch {set peripheryIds [hm_getmark nodes 2]}
    catch {*clearmark nodes 1}
    catch {*clearmark nodes 2}
    return $peripheryIds
}

# ----------------------------------------------------------------------
# Pre/post bookkeeping helpers for result validation
# ----------------------------------------------------------------------
proc ::WasherTool::nodeCoordinates {nodeId} {
    set coordinates {}
    foreach dataName {x y z} {
        if {[catch {set value [hm_getvalue nodes id=$nodeId dataname=$dataName]}] ||
            ![string is double -strict $value]} {
            set coordinates {}
            break
        }
        lappend coordinates $value
    }
    if {[llength $coordinates] == 3} {
        return $coordinates
    }
    if {![catch {set values [hm_nodevalue $nodeId]}] && [llength $values] >= 3} {
        return [lrange $values 0 2]
    }
    return {}
}

proc ::WasherTool::componentElementCount {compId} {
    set elems [::HWFlow::getCompEntityIds $compId elems elems]
    return [llength $elems]
}

# Best-effort rigid count. The selector is profile dependent; any selector
# that works is applied identically before and after, so the difference is
# still a valid "did the washer call create rigids" answer. Returns "" when
# no selector is available on the current profile.
proc ::WasherTool::rigidElementCount {} {
    foreach selector [list \
            [list "by config" 55] \
            [list "by element config" 55] \
            [list "by type" RBE2] \
            [list "by card image" RBE2]] {
        catch {*clearmark elems 3}
        if {![catch {eval *createmark elems 3 $selector}]} {
            set ids {}
            catch {set ids [hm_getmark elems 3]}
            catch {*clearmark elems 3}
            return [llength $ids]
        }
    }
    return ""
}

proc ::WasherTool::systemsMaxId {} {
    set maxId ""
    catch {set maxId [hm_entitymaxid systems]}
    return $maxId
}

# Orders node IDs by squared distance to the reference coordinates. The old
# seed node may be deleted after the washer rebuild, so the nearest current
# node is the reliable anchor back onto the rebuilt hole ring. Nodes whose
# coordinates cannot be read keep their relative order at the end.
proc ::WasherTool::sortNodesByDistance {nodeIds coordinates} {
    if {[llength $coordinates] != 3 || [llength $nodeIds] < 2} {
        return $nodeIds
    }
    lassign $coordinates sx sy sz
    set pairs {}
    set fallback {}
    foreach nodeId $nodeIds {
        set coords [::WasherTool::nodeCoordinates $nodeId]
        if {[llength $coords] != 3} {
            lappend fallback $nodeId
            continue
        }
        lassign $coords x y z
        lappend pairs [list [expr {($x-$sx)*($x-$sx) + ($y-$sy)*($y-$sy) + ($z-$sz)*($z-$sz)}] $nodeId]
    }
    set sorted {}
    foreach pair [lsort -real -index 0 $pairs] {
        lappend sorted [lindex $pair 1]
    }
    foreach nodeId $fallback {
        lappend sorted $nodeId
    }
    return $sorted
}

# Full post-creation validation. Returns {problems notes} (both lists of
# human-readable strings; problems non-empty means the result needs review).
proc ::WasherTool::validateResult {compId seedCoordinates peripheryIds targetDensity
                                   compElemCountBefore rigidBefore systemsBefore
                                   edgesExistedBefore {serial 2}} {
    set problems {}
    set notes {}

    # (2) periphery output mark non-empty
    if {[llength $peripheryIds] == 0} {
        lappend problems [::HWFlow::txt \
            "washer 命令没有返回孔周节点（periphery mark 为空）。" \
            "The washer command returned no periphery nodes (empty output mark)."]
    }

    # (3)+(4) the hole must still exist as a closed loop with targetDensity nodes
    set newCount ""
    if {![catch {
        set edgeElems [::WasherTool::buildFreeEdges $compId $serial]
        if {[llength $edgeElems] == 0} {
            error [::HWFlow::txt "washer 后组件没有任何自由边。" \
                "The component has no free edges after the washer call."]
        }
        lassign [::WasherTool::buildEdgeTopology $edgeElems] edgeToNodes nodeToEdges
        # The old seed ID may have been deleted by the rebuild; anchor on the
        # node nearest to the original seed coordinates. Periphery nodes come
        # first (they form the rebuilt hole ring), then all free-edge nodes.
        set anchorCandidates {}
        foreach nodeId [::WasherTool::sortNodesByDistance $peripheryIds $seedCoordinates] {
            lappend anchorCandidates $nodeId
        }
        foreach nodeId [::WasherTool::sortNodesByDistance [dict keys $nodeToEdges] $seedCoordinates] {
            lappend anchorCandidates $nodeId
        }
        set seen [dict create]
        set chainFound 0
        foreach anchorId $anchorCandidates {
            if {$anchorId eq "" || [dict exists $seen $anchorId]} {
                continue
            }
            dict set seen $anchorId 1
            if {![dict exists $nodeToEdges $anchorId]} {
                continue
            }
            if {[catch {
                lassign [::WasherTool::extractChainFromSeed $anchorId $edgeToNodes $nodeToEdges] holeEdges holeNodes
                ::WasherTool::validateClosedLoop $holeNodes $holeEdges $nodeToEdges
            } chainErr]} {
                continue
            }
            set newCount [llength $holeNodes]
            set chainFound 1
            break
        }
        if {!$chainFound} {
            error [::HWFlow::txt "washer 后未能重新识别出闭合孔边。" \
                "Could not re-derive a closed hole loop after the washer call."]
        }
    } scanErr]} {
        lappend problems [::HWFlow::txt \
            "washer 后自由边复检失败：$scanErr" \
            "Free-edge re-check after the washer call failed: $scanErr"]
    } else {
        if {$newCount ne $targetDensity} {
            lappend problems [::HWFlow::txt \
                "新孔周节点数为 $newCount，目标 holeDensity 为 $targetDensity。" \
                "The new hole ring has $newCount nodes; the target holeDensity is $targetDensity."]
        } else {
            lappend notes [::HWFlow::txt \
                "新孔周节点数 = $newCount，与目标一致。" \
                "New hole-ring node count = $newCount, matching the target."]
        }
        if {[llength $peripheryIds] > 0 && [llength $peripheryIds] != $newCount} {
            lappend notes [::HWFlow::txt \
                "periphery 输出标记含 [llength $peripheryIds] 个节点，与复检环链 $newCount 不同。" \
                "The periphery mark holds [llength $peripheryIds] nodes vs the re-derived loop of $newCount."]
        }
    }

    # (5) new mesh stayed inside the original component
    set compElemCountAfter ""
    catch {set compElemCountAfter [::WasherTool::componentElementCount $compId]}
    if {$compElemCountAfter eq "" || $compElemCountAfter <= $compElemCountBefore} {
        lappend problems [::HWFlow::txt \
            "原 component（$compId）单元数未增加（$compElemCountBefore -> $compElemCountAfter），washer 网格可能落在其他组件。" \
            "The original component ($compId) did not gain elements ($compElemCountBefore -> $compElemCountAfter); the washer mesh may have landed elsewhere."]
    }
    set sampled 0
    set foreignComps {}
    foreach nodeId $peripheryIds {
        if {$sampled >= 3} {
            break
        }
        foreach elemId [::WasherTool::attachedElementIds $nodeId] {
            set ownerComp [::WasherTool::elementComponentId $elemId]
            if {$ownerComp ne "" && $ownerComp != $compId} {
                lappend foreignComps $ownerComp
            }
        }
        incr sampled
    }
    set foreignComps [lsort -integer -unique $foreignComps]
    if {[llength $foreignComps] > 0} {
        lappend problems [::HWFlow::txt \
            "孔周节点附近发现属于其他 component（$foreignComps）的单元，请人工确认。" \
            "Elements from other components ($foreignComps) touch the periphery nodes; review manually."]
    }

    # (6) no additional rigid elements
    if {$rigidBefore ne ""} {
        set rigidAfter [::WasherTool::rigidElementCount]
        if {$rigidAfter ne "" && $rigidAfter != $rigidBefore} {
            lappend problems [::HWFlow::txt \
                "washer 后 rigid 数量发生变化（$rigidBefore -> $rigidAfter）。" \
                "The rigid element count changed after the washer call ($rigidBefore -> $rigidAfter)."]
        }
    } else {
        lappend notes [::HWFlow::txt \
            "当前模板无法统计 rigid 数量；rigid_spider=0 已在参数层保证不创建。" \
            "Rigid count is not queryable on this template; rigid_spider=0 guarantees none are requested."]
    }

    # (7) no additional coordinate systems
    set systemsAfter [::WasherTool::systemsMaxId]
    if {$systemsBefore ne "" && $systemsAfter ne "" && $systemsAfter != $systemsBefore} {
        lappend problems [::HWFlow::txt \
            "washer 后 system 最大 ID 发生变化（$systemsBefore -> $systemsAfter），可能创建了新坐标系。" \
            "The max system ID changed after the washer call ($systemsBefore -> $systemsAfter); a system may have been created."]
    }

    # (8) no ^edges residue
    set edgesAfter [::HWFlow::componentIdByName "^edges"]
    if {$edgesExistedBefore} {
        if {$edgesAfter eq ""} {
            lappend problems [::HWFlow::txt \
                "运行前已存在的 ^edges 组件丢失。" \
                "The pre-existing ^edges component is gone."]
        }
    } elseif {$edgesAfter ne ""} {
        lappend problems [::HWFlow::txt \
            "残留了临时 ^edges 组件。" \
            "A temporary ^edges component was left behind."]
    }

    return [list $problems $notes]
}

# ----------------------------------------------------------------------
# Main entry
# ----------------------------------------------------------------------
proc ::WasherTool::run {} {
    # 1) Parameters first: every failure here happens before any model query.
    if {[catch {::WasherTool::validateParameters} err]} {
        catch {tk_messageBox -icon error -title "Add Washer" -message $err}
        return ""
    }

    # 2) Seed node selection (0 = normal exit, >1 = error).
    if {[catch {set seedNode [::WasherTool::selectSeedNode]} err]} {
        catch {tk_messageBox -icon error -title "Add Washer" -message $err}
        return ""
    }
    if {$seedNode eq "" || $seedNode == 0} {
        return ""
    }
    variable holeDensity
    variable layerWidths
    set layerCount [llength $layerWidths]

    # 3) Recognition + validation. Everything below runs before the single
    #    mutating call; any error must leave the mesh untouched.
    # NOTE: no `return` inside the catch script - a return would be trapped
    # by catch itself (code 2) and look like a failure.
    set mutated 0
    set outcome ""
    set code [catch {
        lassign [::WasherTool::resolveTargetComponent $seedNode] compId disambiguated
        set compName [::HWFlow::componentName $compId]
        if {$disambiguated} {
            ::WasherTool::log "seed node is shared; component $compName selected by free-edge membership"
        }

        set edgeElems [::WasherTool::buildFreeEdges $compId 1]
        if {[llength $edgeElems] == 0} {
            error [::HWFlow::txt \
                "组件 $compName 中没有检测到自由边。" \
                "No free edges were detected in component $compName."]
        }
        lassign [::WasherTool::buildEdgeTopology $edgeElems] edgeToNodes nodeToEdges
        lassign [::WasherTool::extractChainFromSeed $seedNode $edgeToNodes $nodeToEdges] holeEdges holeNodes
        ::WasherTool::validateClosedLoop $holeNodes $holeEdges $nodeToEdges
        set oldDensity [llength $holeNodes]

        # The seed node may be deleted by the rebuild; remember its coordinates.
        set seedCoordinates [::WasherTool::nodeCoordinates $seedNode]
        set edgesExistedBefore [expr {[::HWFlow::componentIdByName "^edges"] ne "" ? 1 : 0}]
        set compElemCountBefore [::WasherTool::componentElementCount $compId]
        set rigidBefore [::WasherTool::rigidElementCount]
        set systemsBefore [::WasherTool::systemsMaxId]

        ::WasherTool::logPlan $seedNode $compId $compName $oldDensity

        lassign [::WasherTool::buildWasherStringArray $holeDensity $layerWidths] stringArray stringCount

        # 4) The one and only model mutation. mutated is set before the call
        #    so a failure inside the native command is still reported honestly.
        set mutated 1
        set peripheryIds [::WasherTool::createWasher $seedNode $stringArray $stringCount]

        # 5) Result validation (re-runs the free-edge scan on the component).
        lassign [::WasherTool::validateResult $compId $seedCoordinates $peripheryIds \
            $holeDensity $compElemCountBefore $rigidBefore $systemsBefore \
            $edgesExistedBefore] problems notes

        set outcome [dict create compId $compId compName $compName oldDensity $oldDensity \
            periphery [llength $peripheryIds] problems $problems notes $notes]
    } result]

    if {$code} {
        ::WasherTool::cleanupTempEdges
        if {$mutated} {
            set message [::HWFlow::txt \
                "Add Washer 在创建步骤之后失败，模型可能已被修改，请立即检查结果（必要时用 Ctrl+Z 回退）：\n$result" \
                "Add Washer failed after the creation step; the model may have been modified. Review the result immediately (undo with Ctrl+Z if needed):\n$result"]
            catch {tk_messageBox -icon error -title "Add Washer" -message $message}
        } else {
            set message [::HWFlow::txt \
                "Add Washer 未执行到创建步骤，网格未修改：\n$result" \
                "Add Washer stopped before the creation step; the mesh was not modified:\n$result"]
            catch {tk_messageBox -icon error -title "Add Washer" -message $message}
        }
        return ""
    }

    set problems [dict get $outcome problems]
    set notes [dict get $outcome notes]
    set icon "info"
    if {[llength $problems] > 0} {
        set icon "warning"
    }
    set message [::HWFlow::txt \
        "Add Washer 完成。\nComponent：[dict get $outcome compName]\n孔周节点数：[dict get $outcome oldDensity] -> $holeDensity\nWasher 层数：$layerCount，宽度：[join $layerWidths { }]\nperiphery 输出：[dict get $outcome periphery] 个节点" \
        "Add Washer finished.\nComponent: [dict get $outcome compName]\nHole-ring nodes: [dict get $outcome oldDensity] -> $holeDensity\nWasher layers: $layerCount, widths: [join $layerWidths { }]\nPeriphery output: [dict get $outcome periphery] nodes"]
    foreach note $notes {
        append message "\n" $note
    }
    if {[llength $problems] > 0} {
        append message "\n\n" [::HWFlow::txt "以下校验项需要人工复核：" "The following checks need manual review:"]
        foreach problem $problems {
            append message "\n" $problem
        }
    }
    catch {tk_messageBox -icon $icon -title "Add Washer" -message $message}
    return $outcome
}
