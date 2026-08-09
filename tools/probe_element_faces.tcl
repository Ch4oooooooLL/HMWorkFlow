# Probe the exact element-to-face topology HM uses internally, for every
# solid config id (linear + quadratic), by creating elements natively and
# extracting their faces with *findfaces (faces become shell elements).
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/probe_element_faces.tcl
#
# Result: runtime/element_faces_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "element_faces_${version}.log"]
set channel [open $reportPath w]
proc P {key value} { variable channel; puts $channel "${key}=${value}" }

proc ExistingNodeIds {} {
    catch {*clearmark nodes 1}
    *createmark nodes 1 all
    return [hm_getmark nodes 1]
}

proc MkNodes {coords} {
    # coords = list of {x y z} triples; ids auto-assigned in creation order
    set before [ExistingNodeIds]
    foreach c $coords {
        eval *createnode $c 0 0 0
    }
    set all [ExistingNodeIds]
    set new {}
    foreach n $all {
        if {[lsearch -exact $before $n] < 0} { lappend new $n }
    }
    return $new
}

# --- proper solid geometry: corners + edge midpoints -------------------------
# hex20 (Nastran order): corners 1-8, bottom mids 9-12 (12,23,34,41),
# top mids 13-16 (56,67,78,85), vertical mids 17-20 (15,26,37,48)
set HEX20_COORDS {
    {0 0 0} {1 0 0} {1 1 0} {0 1 0}
    {0 0 1} {1 0 1} {1 1 1} {0 1 1}
    {0.5 0 0} {1 0.5 0} {0.5 1 0} {0 0.5 0}
    {0.5 0 1} {1 0.5 1} {0.5 1 1} {0 0.5 1}
    {0 0 0.5} {1 0 0.5} {1 1 0.5} {0 1 0.5}
}
# tetra10 (Nastran order): corners 1-4, edge mids 5-10 (12,23,31,14,24,34)
set TETRA10_COORDS {
    {0 0 0} {2 0 0} {0 2 0} {0 0 2}
    {1 0 0} {1 1 0} {0 1 0} {0 0 1} {1 0 1} {0 1 1}
}
# penta15: corners 1-6 (bottom tri 1-3, top tri 4-6),
# vertical mids 7-9 (14,25,36), bottom mids 10-12 (12,23,31),
# top mids 13-15 (45,56,64)
set PENTA15_COORDS {
    {0 0 0} {2 0 0} {0 2 0}
    {0 0 2} {2 0 2} {0 2 2}
    {0 0 1} {2 0 1} {0 2 1}
    {1 0 0} {1 1 0} {0 1 0}
    {1 0 2} {1 1 2} {0 1 2}
}
# pyra13: base 1-4, apex 5, base mids 6-9 (12,23,34,41),
# apex-edge mids 10-13 (15,25,35,45)
set PYRA13_COORDS {
    {0 0 0} {2 0 0} {2 2 0} {0 2 0} {1 1 2}
    {1 0 0} {2 1 0} {1 2 0} {0 1 0}
    {0.5 0.5 1} {1.5 0.5 1} {1.5 1.5 1} {0.5 1.5 1}
}

proc Probe {label config coords} {
    set ids [MkNodes $coords]
    set nodeCount [llength $coords]
    P "$label NODEIDS" [join $ids { }]
    set err {}
    catch {eval *createlist nodes 1 $ids} err
    catch {*currentcollector components probecomp}
    catch {*createelement $config 1 1 0} err
    P "$label CREATE" "$err"
    catch {*clearmark elems 1}
    catch {*createmark elems 1 all}
    set e [hm_getmark elems 1]
    if {[llength $e] != 1} { P "$label ELEMS" [join $e { }]; return }
    P "$label CONFIG" [hm_getvalue elems id=$e dataname=config]
    set nodes {}
    for {set i 1} {$i <= $nodeCount} {incr i} {
        lappend nodes [hm_getvalue elems id=$e dataname=node$i]
    }
    P "$label NODES" [join $nodes { }]
    # extract faces as shell elements, then read each face's node ring
    set faceErr {}
    catch {*findfaces elems 1} faceErr
    P "$label FINDFACES" "$faceErr"
    catch {*clearmark elems 1}
    *createmark elems 1 all
    set shells [hm_getmark elems 1]
    set idx 0
    foreach s $shells {
        if {$s == $e} { continue }   ;# skip the original solid itself
        incr idx
        set fn {}
        for {set i 1} {$i <= 8} {incr i} {
            set v {}
            catch {set v [hm_getvalue elems id=$s dataname=node$i]}
            if {$v eq ""} { break }
            lappend fn $v
        }
        P "$label FACE$idx" [join $fn { }]
    }
    # clean up for the next probe
    catch {*clearmark elems 1}
    *createmark elems 1 all
    catch {*deletemark elems 1}
    catch {*clearmark nodes 1}
    *createmark nodes 1 all
    catch {*deletemark nodes 1}
}

set templatePath "C:/Program Files/Altair/2019/templates/feoutput/optistruct/optistruct"
catch {*templatefileset $templatePath}
catch {*createentity comps name=probecomp}

Probe HEX8    208 {{0 0 0} {1 0 0} {1 1 0} {0 1 0} {0 0 1} {1 0 1} {1 1 1} {0 1 1}}
Probe TETRA4  204 {{0 0 0} {2 0 0} {0 2 0} {0 0 2}}
Probe PENTA6  206 {{0 0 0} {2 0 0} {0 2 0} {0 0 2} {2 0 2} {0 2 2}}
Probe PYRA5   205 {{0 0 0} {2 0 0} {2 2 0} {0 2 0} {1 1 2}}
Probe HEX20   220 $HEX20_COORDS
Probe TETRA10 210 $TETRA10_COORDS
Probe PENTA15 215 $PENTA15_COORDS
Probe PYRA13  213 $PYRA13_COORDS
Probe TRIA6   106 {{0 0 0} {2 0 0} {0 2 0} {1 0 0} {1 1 0} {0 1 0}}
Probe QUAD8   108 {{0 0 0} {2 0 0} {2 2 0} {0 2 0} {1 0 0} {2 1 0} {1 2 0} {0 1 0}}

close $channel
exit 0
