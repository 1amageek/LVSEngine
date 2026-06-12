# Headless layout-netlist extractor for LVS input.

proc normalize_message {value} {
    return [string map [list "\\" "\\\\" "\"" "\\\"" "\n" "\\n" "\r" "\\r" "\t" "\\t"] $value]
}

if {![info exists env(EXT_CELL)]} { puts "EXT_ERROR EXT_CELL not set"; exit 1 }
if {![info exists env(EXT_OUT)]}  { puts "EXT_ERROR EXT_OUT not set";  exit 1 }
if {[info exists env(EXT_GDS)] && ![file exists $env(EXT_GDS)]} {
    puts "EXT_ERROR [normalize_message "gds not found: $env(EXT_GDS)"]"
    exit 1
}

if {[catch {
    if {[info exists env(EXT_GDS)]} { gds read $env(EXT_GDS) }
    load $env(EXT_CELL)
    select top cell
    lassign [box values] llx lly urx ury
    if {[expr {($urx - $llx) * ($ury - $lly)}] <= 1} {
        error "cell not found or empty: $env(EXT_CELL)"
    }
    port makeall
    extract do local
    extract all
    ext2spice lvs
    ext2spice subcircuit top on
    ext2spice -o $env(EXT_OUT)
} err]} {
    puts "EXT_ERROR [normalize_message $err]"
    exit 1
}

puts "EXT_DONE"
quit -noprompt
