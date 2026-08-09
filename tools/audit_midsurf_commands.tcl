# MidSurf module command-surface probe (part 1: existence / alternatives).
#
# Audits every HyperMesh native command used by modules/midsurf.tcl and the
# workflow_common.tcl helpers it calls, and lists *mid*/*thick*/*assembly*
# command surfaces to look for better alternatives.
#
# Run headless (one hmbatch per installed build):
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_midsurf_commands.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe"   -nocommand -nouserprofiledialog -tcl tools/audit_midsurf_commands.tcl
#
# hmbatch has no stdout channel: results go to runtime/audit_midsurf_commands_<version>.log
# as ASCII KEY=VALUE lines.

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_midsurf_commands_${version}.log"]
set channel [open $reportPath w]
proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}
proc esc {name} {
    string map {* {\*} ? {\?} [ {\[} ] {\]} \\ {\\\\}} $name
}
proc has {name} {
    expr {[llength [info commands [esc $name]]] > 0}
}

P "VERSION" $version
P "TCL_PATCHLEVEL" [info patchlevel]

# --- 1. Existence of every native command used by the midsurf flow ----------
# From modules/midsurf.tcl + modules/workflow_common.tcl helpers it calls.
set commands {
    *clearmark
    *createmark
    *deletemark
    *setoption
    *marksuppressactive
    *marksuppressoutput
    *displaycollectorsbymark
    *displaycollectorsallbymark
    *displaycollector
    *displaycollectorwithfilter
    *midsurface_extract_10
    *startnotehistorystate
    *endnotehistorystate
    *renamecollector
    *currentcollector
    *assemblyaddmark
    *assemblymodify
    *assemblymodifyhierarchy
    *createentity
    *collectorcreateonly
    *createpoint
    *create_solid_from_eight_points
    *surfaceprimitivefrompoints
    hm_getmark
    hm_usermessage
    hm_getcollectorname
    hm_entityinfo
    hm_getvalue
    hm_getthickness
    hm_getsurfacethicknessvalues
    hm_getsurfaceedges
    hm_getverticesfromedge
    hm_getvolumeofsolid
    hm_getareaofsurface
    hm_redraw
    hmbr_signals
    hwbrowsermanager
    hm_blockredraw
    hm_blockmessages
    hm_blockerrormessages
    hm_commandfilestate
    hm_viewfit
    hm_blockbrowserupdate
}
foreach name $commands {
    P "EXISTS $name" [expr {[has $name] ? 1 : 0}]
}

# --- 2. Command-surface listings for better-alternative discovery -----------
foreach pattern {*mid* *midsurface* *extract* *thick* *assembly* *create_solid* *surfaceprimitive* *marksuppress*} {
    set list [lsort [info commands $pattern]]
    P "LIST $pattern" [join $list { }]
}

# --- 3. Functional smoke of the two *setoption forms used by the module -----
foreach form {{*setoption block_redraw=0} {*setoption block_messages=0} {*setoption block_redraw 0}} {
    if {[catch {uplevel #0 $form} err]} {
        P "SETOPTION [join $form { }]" "ERR $err"
    } else {
        P "SETOPTION [join $form { }]" "OK"
    }
}

close $channel
exit 0
