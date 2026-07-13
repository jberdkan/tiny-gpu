##################################################################
#### TetraMax Script for ECE 128
#### Performs ATPG Pattern Generation for Synopsys Generic files
#### author: tjf
#### update: wgibb, spring 2010
#### note: this script will only run in TMAX TCL mode
#### start tmax like this:   tmax -tcl
####
#### adapted for tiny-gpu:
####   reads the scan netlist + protocol written by dc_scan.tcl
####   (src/gpu_scan.v and src/gpu_scan.spf)
##################################################################


############################################################
#### local variables, designer must change these values ####
############################################################

# locate the repo relative to this script's own location
# (the RTL directory may be named src/ or source/ depending on the checkout)
set scriptdir [file dirname [file normalize [info script]]]
set srcdir ""
foreach candidate [list \
    [file join $scriptdir src] \
    [file join $scriptdir source] \
    [file join $scriptdir .. src] \
    [file join $scriptdir .. source] ] {
    if { $srcdir == "" && [file isdirectory $candidate] } {
        set srcdir [file normalize $candidate]
    }
}
if { $srcdir == "" } {
    error "tmax_atpg.tcl: cannot find the RTL directory (src/ or source/) next to $scriptdir"
}
set repodir [file dirname $srcdir]
set rptdir [file join $repodir synthesis reports]
file mkdir $rptdir
puts "RTL directory: $srcdir"

set top_module gpu
set synthesized_files [list $srcdir/gpu_scan.v]
set cell_lib $srcdir/osu05_stdcells.v   ;# copy from the OSU kit install, or point directly at it
set scan_lib $srcdir/osu_scan.v         ;# copy from the course materials, or point directly at it
set stil_file [list $srcdir/gpu_scan.spf]

# ATPG mode: 0 = scan-based stuck-at ATPG (fast, use this for tiny-gpu)
#            1 = full-sequential ATPG like the course template
#                (tiny-gpu has >1000 flip-flops - full-seq will run for a
#                 very long time; only use it if your assignment requires it)
set use_full_seq 0


#################################################
#### read in standard cells and user's design ###
#################################################

# remove any other designs from design compiler's memory
read_netlist -delete

# read in standard cell library
read_netlist $cell_lib -library

# read in scan cell library
read_netlist $scan_lib -library

# read in user's synthesized verilog code
read_netlist $synthesized_files


#################################################
#### BUILD and DRC test model
#################################################

run_build_model $top_module
# ignoring warnings like N20 or B10

# Set STIL file from DFT Compiler
set_drc $stil_file

# run check to see if synthesized code violates any testing rules
run_drc

#################################################
#### Generate ATPG (patterns)
#################################################

remove_faults -all
add_faults -all

if { $use_full_seq == 1 } {
    # capture all faults, 9 capture cycles, full sequential mode
    set_atpg -capture_cycles 9 -full_seq_atpg
    run_atpg full_sequential_only
} else {
    # scan-based stuck-at ATPG (basic-scan then fast-sequential top-off)
    set_atpg -capture_cycles 4
    run_atpg -auto_compression
}

# write out patterns (overwrite old files)
write_patterns $srcdir/${top_module}_tb_patterns.v -replace -internal -format verilog_single_file -parallel 0

#################################################
#### Output reports
#################################################

report_patterns -all >> $rptdir/${top_module}.tmax.patterns
report_violations -all >> $rptdir/${top_module}.tmax.violations
report_faults -summary -collapsed >> $rptdir/${top_module}.tmax.coverage

#################################################
#### Analyze Faults
#################################################

# up to user to run these commands, they can inspect the faults and various reasons for them:
#analyze_faults -class an
#analyze_faults -class an -verbose -max 3
#analyze_faults in_a_reg_reg/p_dregscan0/q -stuck 1
