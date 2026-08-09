set chan [open "runtime/audit_probe_min.log" w]
puts $chan "VERSION=[hm_info -appinfo VERSION]"
close $chan
exit 0
