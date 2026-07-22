namespace eval ::hmtoolkit::seam::log {}

proc ::hmtoolkit::seam::log::begin {} {
    variable ::hmtoolkit::seam::runtime
    set dir [file join [file dirname [::HWFlow::configDir]] "logs"]
    catch {file mkdir $dir}
    set runtime(log_file) [file join $dir "geometry_seam_[clock format [clock seconds] -format %Y%m%d_%H%M%S].log"]
    ::hmtoolkit::seam::log::write INFO "Geometry seam session started"
    return $runtime(log_file)
}

proc ::hmtoolkit::seam::log::write {level message} {
    variable ::hmtoolkit::seam::runtime
    set row "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] | $level | $message\n"
    catch {puts -nonewline $row}
    if {$runtime(log_file) eq ""} { return }
    if {![catch {set chan [open $runtime(log_file) a]}]} {
        catch {puts -nonewline $chan $row}
        catch {close $chan}
    }
}

proc ::hmtoolkit::seam::log::result {result} {
    set level INFO
    if {![dict exists $result success] || ![dict get $result success]} { set level ERROR }
    ::hmtoolkit::seam::log::write $level $result
}

