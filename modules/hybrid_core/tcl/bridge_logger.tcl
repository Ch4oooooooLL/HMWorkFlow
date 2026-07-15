proc ::HybridCore::openLog {path} {
    variable logChannel
    variable logPath
    ::HybridCore::closeLog
    file mkdir [file dirname $path]
    set logChannel [open $path a]
    fconfigure $logChannel -encoding utf-8 -translation lf -buffering line
    set logPath $path
    return $path
}

proc ::HybridCore::closeLog {} {
    variable logChannel
    if {$logChannel ne ""} { catch {close $logChannel} }
    set logChannel ""
}

proc ::HybridCore::log {level message} {
    variable logChannel
    set line "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] [string toupper $level] $message"
    # HyperMesh hmbatch does not expose Tcl's stdout channel. Console output
    # is therefore best-effort; the UTF-8 operation log remains authoritative.
    catch {puts $line}
    if {$logChannel ne ""} {
        catch {puts $logChannel $line; flush $logChannel}
    }
    return $line
}
