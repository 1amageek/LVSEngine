# Headless LVS driver for the signoff harness.
#
# Netgen writes its full final result to the comparison report file. This driver
# emits normalized lines the parser understands:
#
#   LVS_RESULT status=match message="..."
#   MISMATCH rule=LVS_MISMATCH message="..."
#   ERROR rule=DRIVER message="..."

proc normalize_message {value} {
    return [string map [list "\\" "\\\\" "\"" "\\\"" "\n" "\\n" "\r" "\\r" "\t" "\\t"] $value]
}

proc is_match_result {value} {
    set trimmed [string trim $value]
    return [regexp -nocase {^(circuits|netlists) match uniquely\.?$} $trimmed]
}

foreach v {LVS_LAYOUT LVS_SCHEM LVS_TOP LVS_SETUP LVS_OUT} {
    if {![info exists env($v)]} {
        puts "ERROR rule=DRIVER message=\"$v not set\""
        exit 1
    }
}
foreach {v label} {LVS_LAYOUT "layout netlist" LVS_SCHEM "schematic netlist" LVS_SETUP "setup file"} {
    if {![file exists $env($v)]} {
        puts "ERROR rule=DRIVER message=\"[normalize_message "$label not found: $env($v)"]\""
        exit 1
    }
}

if {[catch {
    lvs "$env(LVS_LAYOUT) $env(LVS_TOP)" "$env(LVS_SCHEM) $env(LVS_TOP)" \
        $env(LVS_SETUP) $env(LVS_OUT)
} err]} {
    puts "ERROR rule=DRIVER message=\"[normalize_message "lvs failed: $err"]\""
    exit 1
}

set result "no final result in report"
if {[file exists $env(LVS_OUT)]} {
    set fp [open $env(LVS_OUT) r]
    set data [read $fp]
    close $fp
    foreach line [split $data "\n"] {
        if {[regexp {Final result:\s*(.+)} $line -> matched]} {
            set result [string trim $matched]
        }
    }
}

if {[is_match_result $result]} {
    puts "LVS_RESULT status=match message=\"[normalize_message $result]\""
} else {
    puts "MISMATCH rule=LVS_MISMATCH message=\"[normalize_message $result]\""
}
puts "LVS_DONE"
quit
