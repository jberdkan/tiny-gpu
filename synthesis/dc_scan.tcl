##################################################################
#### Design Compiler DFT Script for ECE 128
#### Performs Synthesis + Scan Insertion to AMI .5 technology
#### based on dc_syn.tcl; adds scan chains and writes the test
#### protocol (.spf) that TetraMax needs for ATPG
#### run AFTER (or instead of) dc_syn.tcl when you want a scan netlist:
####   outputs gpu_scan.v / gpu_scan.spf / gpu_scan.sdf / gpu_scan.sdc
####   next to the RTL, reports to synthesis/reports/
##################################################################

# locate the repo relative to this script's own location, so the script
# works no matter which directory design_vision was launched from and
# whether it sits at the repo root or in synthesis/
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
    error "dc_scan.tcl: cannot find the RTL directory (src/ or source/) next to $scriptdir"
}
set repodir [file dirname $srcdir]
echo "RTL directory: $srcdir"

# list of all HDL files in the design
set myFiles [list \
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
    $srcdir/gpu.v ] ;
set basename gpu                    ;# Top-level module name
set myClk clk                       ;# The name of your clock
set myPeriod_ns 50                  ;# desired clock period (in ns) (sets speed goal)

set runname scan                    ;# Name appended to output files
set exit_dc 0                       ;# 1 to exit DC after running, 0 to keep DC running
set target_library [list osu05_stdcells.db] ;
set scanChainCount 1                ;# number of scan chains to build

set myClkLatency_ns 0.3
set myInDelay_ns 2.0
set myOutDelay_ns 1.65
set myInputBuf INVX1
set myLoadLibrary [file rootname $target_library]
set myMaxFanout 1
set myOutputLoad 0.1
set optimizeArea 1

set link_library [concat  [concat  "*" $target_library] $synthetic_library]
set fileFormat verilog

set outdir $srcdir                  ;# scan netlist / spf / sdf / sdc written next to the RTL
set rptdir [file join $repodir synthesis reports]
file mkdir $rptdir

##############################################################
### YOU SHOULD NOT NEED TO CHANGE ANYTHING BELOW THIS LINE ###
##############################################################

remove_design -all

echo IMPORTING DESIGN
analyze -format $fileFormat -lib WORK $myFiles
elaborate $basename -lib WORK -update
current_design $basename
link
uniquify

echo SETTING CONSTRAINTS
create_clock -period $myPeriod_ns $myClk
set_clock_latency $myClkLatency_ns $myClk
set_input_delay $myInDelay_ns -clock $myClk [all_inputs]
set_output_delay $myOutDelay_ns -clock $myClk [all_outputs]
set_driving_cell -library $myLoadLibrary -lib_cell $myInputBuf [all_inputs]
set_load $myOutputLoad [all_outputs]
set_max_fanout $myMaxFanout [all_inputs]
set_fanout_load 8 [all_outputs]
set_fix_multiple_port_nets -all -buffer_constants
if { $optimizeArea == 1} {
    set_max_area 0
}

####################################
# scan configuration
# > multiplexed flip-flop style scan (standard for the OSU cells)
# > clk is the scan clock
# > reset is SYNCHRONOUS in tiny-gpu (plain data logic on the D inputs),
#   so it must NOT be declared as a DFT Reset/clock - declaring it makes
#   TetraMax treat it as a clock and fail DRC rule C4-1 ("clock cannot
#   capture data with other clocks off"). Left as a normal data input,
#   ATPG controls it like any other PI and the reset logic gets tested too.
####################################
echo SETTING SCAN CONFIGURATION
set_scan_configuration -style multiplexed_flip_flop -chain_count $scanChainCount
set_dft_signal -view existing_dft -type ScanClock -port $myClk -timing [list 45 55]
create_test_protocol -infer_asynch -infer_clock

echo BEGIN COMPILING DESIGN WITH SCAN
####################################
# compile with scan-equivalent flops, then check testability,
# preview and insert the scan chains, and re-check
####################################
compile -scan -map_effort medium
dft_drc
preview_dft
insert_dft
dft_drc

check_design
echo VIOLATIONS
report_constraint -all_violators

#####################################################
#### output files: scan netlist, spf, sdf, sdc   ####
#####################################################
echo OUTPUT FILES AND REPORTS
set filebase [format "%s%s" [format "%s%s" $basename "_"] $runname]

set filename [format "%s/%s%s" $outdir $filebase ".v"]
redirect change_names { change_names -rules verilog -hierarchy -verbose }
write -format verilog -hierarchy -output $filename

# test protocol for TetraMax (STIL)
set filename [format "%s/%s%s" $outdir $filebase ".spf"]
write_test_protocol -output $filename

set filename [format "%s/%s%s" $outdir $filebase ".sdf"]
write_sdf -version 1.0 $filename

set filename [format "%s/%s%s" $outdir $filebase ".sdc"]
write_sdc $filename

####################################
# reports
####################################
set filename [format "%s/%s%s" $rptdir $filebase ".design"]
redirect $filename { report_design }
redirect -append $filename { report_hierarchy }

set filename [format "%s/%s%s" $rptdir $filebase ".timing"]
redirect $filename { report_timing -path full -delay max -nworst 5 -significant_digits 2 -sort_by group }
redirect -append $filename { report_timing -path full -delay min -nworst 5 -significant_digits 2 -sort_by group }

set filename [format "%s/%s%s" $rptdir $filebase ".area"]
redirect $filename { report_area }
redirect -append $filename { report_cell }

set filename [format "%s/%s%s" $rptdir $filebase ".scan"]
redirect $filename { report_scan_path -view existing_dft -chain all }
redirect -append $filename { report_scan_path -view existing_dft -cell all }

if { $exit_dc == 1} {
    exit
}
