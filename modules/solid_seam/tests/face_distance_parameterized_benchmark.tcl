# Parameterized ground truth for the coarse-target failure mode. The geometric
# surface stays fixed while target mesh density changes.
set directory [file dirname [file normalize [info script]]]
namespace eval ::SolidSeam {}
source -encoding utf-8 [file join $directory .. tcl diagnostics.tcl]
proc ::SolidSeam::nodeDistance {p q} {
    set dx [expr {[lindex $p 0]-[lindex $q 0]}]; set dy [expr {[lindex $p 1]-[lindex $q 1]}]; set dz [expr {[lindex $p 2]-[lindex $q 2]}]
    return [expr {sqrt($dx*$dx+$dy*$dy+$dz*$dz)}]
}
proc assert {condition message} { if {![uplevel 1 [list expr $condition]]} { error $message } }

puts "cell_size,divisions,gap,node_distance,face_distance"
foreach cellSize {10.0 20.0 40.0} {
    foreach divisions {1 2 4 8} {
        foreach gap {0.5 1.0 3.0} {
            set triangles {}; set vertices {}
            set step [expr {$cellSize/$divisions}]
            for {set ix 0} {$ix < $divisions} {incr ix} {
                for {set iy 0} {$iy < $divisions} {incr iy} {
                    set x0 [expr {$ix*$step}]; set x1 [expr {($ix+1)*$step}]
                    set y0 [expr {$iy*$step}]; set y1 [expr {($iy+1)*$step}]
                    set a [list $x0 $y0 0.0]; set b [list $x1 $y0 0.0]; set c [list $x1 $y1 0.0]; set d [list $x0 $y1 0.0]
                    lappend triangles [::SolidSeam::shadowTriangleRecord $a $b $c] [::SolidSeam::shadowTriangleRecord $a $c $d]
                    lappend vertices $a $b $c $d
                }
            }
            set point [list [expr {$cellSize*0.5}] [expr {$cellSize*0.5}] $gap]
            set nodeDistance 1.0e100
            foreach vertex $vertices { set d [::SolidSeam::nodeDistance $point $vertex]; if {$d < $nodeDistance} { set nodeDistance $d } }
            set faceDistance [::SolidSeam::shadowNearestFaceDistance [::SolidSeam::shadowBuildBVH $triangles] $point]
            assert {abs($faceDistance-$gap) < 1.0e-9} "Face distance changed under remesh: cell=$cellSize divisions=$divisions gap=$gap"
            puts "$cellSize,$divisions,$gap,[format %.6f $nodeDistance],[format %.6f $faceDistance]"
        }
    }
}
puts "PASS parameterized face-distance benchmark"

