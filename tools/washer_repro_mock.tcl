# Offline mock harness for modules/mesh_add_washer.tcl.
#
# Reproduces the "-T  added washer" free-edge branch on a synthetic shell model
# with a real closed hole, so the module's own detection chain can be exercised
# without HyperMesh. Run with:
#   tclsh tools/washer_repro_mock.tcl
#
# The mock mirrors the native behaviours the module depends on:
#   * hm_getvalue nodes id=N dataname=elems / x / y / z
#   * hm_getvalue elems id=N dataname=nodes
#   * hm_getcollectorname / hm_entityinfo for collector naming
#   * *findedges comps <mark> 0 creating 2-node PLOTELs in a fresh ^edges comp
#   * *renamecollector / *deletemark for the temp-component dance
#   * hm_nodelist / hm_nodevalue

set root [file dirname [file dirname [file normalize [info script]]]]

namespace eval ::HWFlow {}
proc ::HWFlow::txt {zh en} { return $en }
proc ::HWFlow::componentIds {markId} { return {} }

source -encoding utf-8 [file join $root modules mesh_add_washer.tcl]

namespace eval ::M {
    variable xyz
    variable conn
    variable compOf
    variable name
    variable mark
    variable config
    variable nodeComp
    array set xyz {}
    array set conn {}
    array set compOf {}
    array set name {}
    array set mark {}
    array set config {}
    array set nodeComp {}
    variable findedgesCalls 0
    variable nextPlotId 9000
    # id of the collector currently holding ^edges plot elements, 0 = none.
    variable plotOwner 0
}

proc ::M::addNode {id x y z} { set ::M::xyz($id) [list $x $y $z] }
proc ::M::addElem {id comp config nodes} {
    set ::M::conn($id) $nodes
    set ::M::compOf($id) $comp
    set ::M::config($id) $config
}
proc ::M::addComp {id name} { set ::M::name($id) $name }

# ---------------------------------------------------------------------------
# HyperMesh command surface
# ---------------------------------------------------------------------------
proc *clearmark {type slot} { catch {unset ::M::mark($type,$slot)} }

proc *createmark {type slot args} {
    if {[lindex $args 0] eq "all"} {
        if {$type in {comps components component}} {
            set ::M::mark($type,$slot) [array names ::M::name]
        } elseif {$type eq "elems"} {
            set ::M::mark($type,$slot) [array names ::M::conn]
        } elseif {$type eq "nodes"} {
            set ::M::mark($type,$slot) [array names ::M::xyz]
        }
        return
    }
    # "by node id" / "by node" / "by nodes" <nodeId>: elements touching a node.
    # The module relies on this selector, which the positional id list cannot
    # express, so it must be handled before the numeric fallback below. Tcl
    # preserves the selector list through `eval *createmark elems 3 $selector`,
    # so it arrives as one word plus the node id.
    set selector [lindex $args 0]
    if {[string match "by node*" $selector] && $type eq "elems"} {
        set nodeId [lindex $args end]
        set out {}
        foreach e [array names ::M::conn] {
            if {[lsearch -exact $::M::conn($e) $nodeId] >= 0} { lappend out $e }
        }
        set ::M::mark($type,$slot) [lsort -integer -unique $out]
        return
    }
    if {[string match "by *" $selector]} {
        set ::M::mark($type,$slot) {}
        return
    }
    # Positional id list (what markComponents and the module use).
    set ids {}
    foreach token $args {
        if {[string is integer -strict $token]} { lappend ids $token }
    }
    set ::M::mark($type,$slot) [lsort -integer -unique $ids]
}

proc hm_getmark {type slot} {
    return [expr {[info exists ::M::mark($type,$slot)] ? $::M::mark($type,$slot) : {}}]
}

proc *deletemark {type slot} {
    foreach id $::M::mark($type,$slot) {
        if {$type eq "elems"} { catch {unset ::M::conn($id)}; catch {unset ::M::compOf($id)}; catch {unset ::M::config($id)} }
        if {$type in {comps components component}} { catch {unset ::M::name($id)} }
    }
    catch {unset ::M::mark($type,$slot)}
}

proc *renamecollector {type old new} {
    foreach id [array names ::M::name] {
        if {$::M::name($id) eq $old} { set ::M::name($id) $new; return }
    }
    error "no such collector $old"
}

proc hm_getcollectorname {type id} {
    return [expr {[info exists ::M::name($id)] ? $::M::name($id) : ""}]
}
proc hm_entityinfo {args} { return "" }
proc hm_nodevalue {nodeId} { return $::M::xyz($nodeId) }
proc hm_nodelist {elemId} {
    return [expr {[info exists ::M::conn($elemId)] ? $::M::conn($elemId) : {}}]
}

proc hm_getvalue {args} {
    set entity [lindex $args 0]
    set id ""; set dn ""
    foreach token [lrange $args 1 end] {
        set kv [split $token =]
        if {[llength $kv] == 2} {
            if {[lindex $kv 0] eq "id"} { set id [lindex $kv 1] }
            if {[lindex $kv 0] eq "dataname"} { set dn [lindex $kv 1] }
        }
    }
    switch -- $entity {
        nodes {
            if {$dn in {elems elements}} {
                set out {}
                foreach e [array names ::M::conn] {
                    if {[lsearch -exact $::M::conn($e) $id] >= 0} { lappend out $e }
                }
                return [lsort -integer -unique $out]
            }
            if {$dn in {collector.id component.id comp.id}} {
                return [expr {[info exists ::M::nodeComp($id)] ? $::M::nodeComp($id) : 0}]
            }
            set index [lsearch -exact {x y z} $dn]
            if {$index >= 0} { return [lindex $::M::xyz($id) $index] }
        }
        elems {
            if {$dn eq "nodes"} { return $::M::conn($id) }
            if {$dn in {component.id collector.id comp.id}} {
                return [expr {[info exists ::M::compOf($id)] ? $::M::compOf($id) : 0}]
            }
        }
        comps {
            if {$dn eq "name"} { return $::M::name($id) }
        }
    }
    error "unsupported mock query: $entity [join $args { }]"
}

# Free edges of the marked components become 2-node PLOTELs in a fresh ^edges
# collector, exactly like the native command.
proc *findedges {type slot mode} {
    incr ::M::findedgesCalls
    set marked [hm_getmark $type $slot]
    # The native command replaces the ^edges content each time: drop the
    # previous plot elements, tracked by collector id, before adding new ones.
    if {$::M::plotOwner != 0} {
        foreach id [array names ::M::compOf] {
            if {$::M::compOf($id) == $::M::plotOwner} {
                catch {unset ::M::conn($id)}
                catch {unset ::M::compOf($id)}
                catch {unset ::M::config($id)}
            }
        }
    }
    array set counts {}
    foreach e [lsort -integer [array names ::M::conn]] {
        if {[lsearch -exact $marked $::M::compOf($e)] < 0} { continue }
        set nodes $::M::conn($e)
        set n [llength $nodes]
        if {$n ni {3 4}} { continue }
        for {set i 0} {$i < $n} {incr i} {
            set a [lindex $nodes $i]
            set b [lindex $nodes [expr {($i + 1) % $n}]]
            set key [join [lsort -integer [list $a $b]] ,]
            if {[info exists counts($key)]} { incr counts($key) } else { set counts($key) 1 }
        }
    }
    set ::M::plotOwner 0
    foreach id [array names ::M::name] {
        if {$::M::name($id) eq "^edges"} { set ::M::plotOwner $id }
    }
    if {$::M::plotOwner == 0} {
        set ::M::plotOwner 500
        foreach id [array names ::M::name] { if {$id >= $::M::plotOwner} { set ::M::plotOwner [expr {$id + 1}] } }
        ::M::addComp $::M::plotOwner "^edges"
    }
    foreach key [lsort [array names counts]] {
        if {$counts($key) > 1} { continue }
        incr ::M::nextPlotId
        ::M::addElem $::M::nextPlotId $::M::plotOwner 11 [split $key ,]
    }
    return
}

proc ::HWFlow::componentName {compId} {
    return [expr {[info exists ::M::name($compId)] ? $::M::name($compId) : "COMP_$compId"}]
}
proc ::HWFlow::componentIdByName {name} {
    foreach id [array names ::M::name] {
        if {$::M::name($id) eq $name} { return $id }
    }
    return ""
}
proc ::HWFlow::getCompEntityIds {compId dataname markEntityType {markId 2}} {
    set out {}
    foreach e [array names ::M::conn] {
        if {[info exists ::M::compOf($e)] && $::M::compOf($e) == $compId} { lappend out $e }
    }
    return [lsort -integer -unique $out]
}

# ---------------------------------------------------------------------------
# Synthetic model: 4 x 4 quad plate of 10 mm cells in component 5, with the
# centre 2 x 2 cell region removed so a genuine square 4-node hole exists.
# ---------------------------------------------------------------------------
for {set row 0} {$row <= 4} {incr row} {
    for {set col 0} {$col <= 4} {incr col} {
        ::M::addNode [expr {$row * 10 + $col + 1}] [expr {$col * 10.0}] [expr {$row * 10.0}] 0.0
    }
}
# node(row,col) = row*10 + col + 1
proc nid {row col} { return [expr {$row * 10 + $col + 1}] }

set elemId 100
for {set row 0} {$row < 4} {incr row} {
    for {set col 0} {$col < 4} {incr col} {
        # skip the centre 2x2 block -> hole spans nodes (1,1)..(2,2)
        if {$row >= 1 && $row <= 2 && $col >= 1 && $col <= 2} { continue }
        incr elemId
        ::M::addElem $elemId 5 104 [list [nid $row $col] [nid $row [expr {$col+1}]] \
            [nid [expr {$row+1}] [expr {$col+1}]] [nid [expr {$row+1}] $col]]
    }
}
::M::addComp 5 "HOLE_PLATE"

proc report {seed label} {
    puts "--- $label (seed=$seed) ---"
    set code [catch { set elems [::WasherTool::buildFreeEdges 5 1] } err]
    if {$code} { puts "  buildFreeEdges FAILED: $err"; return }
    puts "  free-edge plot elements: [llength $elems]"
    lassign [::WasherTool::buildEdgeTopology $elems] e2n n2e
    puts "  distinct plot edges: [dict size $e2n]"
    if {[catch { lassign [::WasherTool::extractChainFromSeed $seed $e2n $n2e] he hn } cerr]} {
        puts "  extractChainFromSeed FAILED -> \"$cerr\""
        return
    }
    puts "  chain: [llength $hn] nodes / [llength $he] edges"
    if {[catch { ::WasherTool::validateClosedLoop $hn $he $n2e } verr]} {
        puts "  validateClosedLoop FAILED -> \"$verr\""
    } else {
        puts "  validateClosedLoop OK (closed loop)"
    }
}

puts "== mesh: [llength [array names ::M::conn]] elements, hole between nodes (1,1)-(2,2) =="
report [nid 1 1] "SEED ON HOLE FREE EDGE"
report [nid 1 2] "SEED ON HOLE FREE EDGE (other side)"
report [nid 0 0] "SEED ON PLATE OUTER CORNER"
report [nid 2 0] "SEED ON PLATE OUTER EDGE (not hole)"
