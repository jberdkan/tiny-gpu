##################################################################
#### Design Compiler Synthesis Script for tiny-gpu (top: gpu)
#### ECE 6214 flow: invoked by run_syn (-top gpu) from synthesis/,
#### running inside synthesis/work/
#### Modeled on the project 2 synthesis_program_counter.tcl
####
#### Reads:  RTL from <repo>/src (or source/)
####         constraints from ../constraints/constraints_gpu.tcl
#### Writes: ../netlists/gpu.v    (cmos8hp netlist for Innovus)
####         ../netlists/gpu.sdc  (expanded constraints for Innovus)
####         ../netlists/gpu.sdf
####         reports to ../reports/
##################################################################

# IBM cmos8hp library setup (from project 2 synthesis script)
set search_path [concat . $search_path "/apps/design_kits/ibm_kits/IBM_IP/ibm_cmos8hp/std_cell/sc/v.20110613/synopsys/ss_125"]
set target_library IBM_CMOS8HP_SS125.db
set link_library [concat * $target_library $synthetic_library]
set acs_work_dir "."

#############################
# Update design name to match top-level module name
set DESIGN "gpu"

# locate the repo relative to this script's own location
# (this script lives in synthesis/scripts/; RTL dir may be src/ or source/)
set scriptdir [file dirname [file normalize [info script]]]
set syndir  [file dirname $scriptdir]     ;# synthesis/
set repodir [file dirname $syndir]        ;# repo root
set srcdir ""
foreach candidate [list \
    [file join $repodir src] \
    [file join $repodir source] ] {
    if { $srcdir == "" && [file isdirectory $candidate] } {
        set srcdir [file normalize $candidate]
    }
}
if { $srcdir == "" } {
    error "synthesis_gpu.tcl: cannot find the RTL directory (src/ or source/) under $repodir"
}
set netdir [file join $syndir netlists]
set rptdir [file join $syndir reports]
file mkdir $netdir
file mkdir $rptdir
echo "RTL directory: $srcdir"

##########################
# Analyze design (all tiny-gpu RTL files)
analyze -format verilog [list \
    $srcdir/alu.v \
    $srcdir/dcr.v \
    $srcdir/decoder.v \
    $srcdir/fetcher.v \
    $srcdir/lsu.v \
    $srcdir/pc.v \
    $srcdir/registers.v \
    $srcdir/scheduler.v \
    $srcdir/controller.v \
    $srcdir/dispatch.v \
    $srcdir/core.v \
    $srcdir/gpu.v ]

# elaborate design
elaborate ${DESIGN} -architecture verilog -library DEFAULT
uniquify

# constraints
source [file join $syndir constraints constraints_${DESIGN}.tcl]

# check design for issues
check_design

# compile design
compile -map_effort medium

#compile -map_effort high -incremental

# reports
## worst case timing paths
redirect [file join $rptdir ${DESIGN}_timing_worst.rpt] {report_timing -path full -delay max -nworst 5 -max_paths 5 -significant_digits 3 -sort_by group }

redirect [file join $rptdir ${DESIGN}_area.rpt] {report_area -hierarchy }

# write netlist, sdc, and constraints out
redirect change_names { change_names -rules verilog -hierarchy -verbose }
write -hierarchy -format verilog -output [file join $netdir ${DESIGN}.v]
write_sdf -version 1.0 [file join $netdir ${DESIGN}.sdf]
write_sdc [file join $netdir ${DESIGN}.sdc]

echo "Synthesis Complete"
echo "   use command 'exit' on dc_shell to exit design_compiler"
