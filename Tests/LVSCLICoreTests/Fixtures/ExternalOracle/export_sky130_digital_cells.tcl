if {![info exists ::env(PDK_ROOT)] || $::env(PDK_ROOT) eq ""} {
    error "PDK_ROOT is required"
}
if {![info exists ::env(OUTPUT_ROOT)] || $::env(OUTPUT_ROOT) eq ""} {
    error "OUTPUT_ROOT is required"
}

set libraryPath [file join $::env(PDK_ROOT) libs.ref sky130_fd_sc_hd gds sky130_fd_sc_hd.gds]
set cells {
    sky130_fd_sc_hd__inv_1
    sky130_fd_sc_hd__nand2_1
    sky130_fd_sc_hd__nor2_1
    sky130_fd_sc_hd__and2_1
    sky130_fd_sc_hd__or2_1
    sky130_fd_sc_hd__xor2_1
    sky130_fd_sc_hd__xnor2_1
    sky130_fd_sc_hd__mux2_1
    sky130_fd_sc_hd__a21o_1
    sky130_fd_sc_hd__a21oi_1
    sky130_fd_sc_hd__o21a_1
    sky130_fd_sc_hd__o21ai_1
    sky130_fd_sc_hd__a22o_1
    sky130_fd_sc_hd__a22oi_1
    sky130_fd_sc_hd__o22a_1
    sky130_fd_sc_hd__o22ai_1
    sky130_fd_sc_hd__nand3_1
    sky130_fd_sc_hd__nor3_1
    sky130_fd_sc_hd__buf_1
    sky130_fd_sc_hd__clkbuf_1
}

file mkdir $::env(OUTPUT_ROOT)
gds read $libraryPath
foreach cell $cells {
    load $cell
    gds write [file join $::env(OUTPUT_ROOT) "$cell.gds"]
}
quit -noprompt
