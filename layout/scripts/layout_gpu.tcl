################################
## Layout scripts for Innovus 25.10
## Professor Matthew LaRue
## rev 1
## 4/2/2026
## adapted for tiny-gpu (top module: gpu)
##
## Work through this script SECTION BY SECTION from the innovus prompt.
## The floorplan section requires manual GUI steps - see the comments in
## floorplan_gpu.tcl before running it.
################################

###########################
## Initialize Design
###########################

set DESIGN "gpu"

# load verilog netlist from synthesis
# NOTE: this must be the IBM cmos8hp-mapped netlist from the course
# run_syn flow (source run_syn -top gpu) - NOT an OSU05-mapped netlist
set design_netlisttype verilog
set init_verilog [list ../../synthesis/netlists/${DESIGN}.v]
set init_design_set_top 1
set init_top_cell ${DESIGN}

# init power net names
set init_pwr_net {VDD}
set init_gnd_net {GND}

## load in constraints from synthesis
create_constraint_mode \
    -name syn_constraints \
    -sdc_files ../../synthesis/netlists/${DESIGN}.sdc

# init MMMC
set init_mmmc_file ../scripts/mmmc.tcl

# read in LEF files
set init_lef_file {\
/apps/design_kits/ibm_kits/IBM_IP/ibm_cmos8hp/std_cell/sc/v.20110613/lef/cmos8hp_7AM_tech.lef \
/apps/design_kits/ibm_kits/IBM_IP/ibm_cmos8hp/std_cell/sc/v.20110613/lef/ibm_cmos8hp_sc.lef \
}

## Initialize Design
init_design \
    -setup {VIEW_ss_125} \
    -hold {VIEW_ff_-55}

## Save design

saveDesign saves/${DESIGN}_init_design
#restoreDesign saves/${DESIGN}_init_design.dat ${DESIGN}

###########################
## Floorplan
###########################

### Note: Open the floorplan script and follow the instructions inside it
##     Just running the below line will generate an invalid layout
source ../scripts/floorplan_${DESIGN}.tcl

## if floorplan has already been completed, use below command to load saved floorplan
#loadFPlan ../floorplan/${DESIGN}_floorplan.fp

saveDesign saves/${DESIGN}_floorplan
#restoreDesign saves/${DESIGN}_floorplan.dat ${DESIGN}

###########################
## Place Design
###########################

setDesignMode \
    -process 130

setPlaceMode \
    -congEffort auto \
    -timingDriven true \
    -ignoreScan true

placeDesign
setDrawView place

saveDesign saves/${DESIGN}_place
#restoreDesign saves/${DESIGN}_place.dat ${DESIGN}

##########################
## Pre-CTS Timing
##########################

setAnalysisMode \
    -analysisType onChipVariation \
    -skew true \
    -clockPropagation sdcControl

timeDesign \
    -preCTS \
    -idealClock \
    -numPaths 10 \
    -prefix preCTS \
    -outDIR ../reports/${DESIGN}/preCTS

setOptMode \
    -yieldEffort none \
    -effort high \
    -maxDensity 0.95 \
    -fixDRC true \
    -fixFanoutLoad true \
    -optimizeFF true \
    -simplifyNetlist false \
    -holdTargetSlack 0.0 \
    -setupTargetSlack 0.0 \
    -usefulSkew false

optDesign \
    -preCTS \
    -drv \
    -outDir ../reports/${DESIGN}/preCTS_opt_timing

####################
## Clock tree synthesis
####################

create_ccopt_clock_tree_spec -file ${DESIGN}.ctstch

set_ccopt_property buffer_cells {CLK_I CLK_K CLK_M CLK_O CLK_Q}
set_ccopt_property inverter_cells {CLKI_I CLKI_K CLKI_M CLKI_O CLKI_Q}


#set_ccopt_mode

## create clock tree
ccopt_design \
    -prefix CTS \
    -outDir ../reports/${DESIGN}/CTS

## Step 6: Inspect clock tree
#          Clock -> Clock tree debugger
#          Does the clock tree look good?
#          (gpu has ~1500+ flops - expect a much deeper tree than the
#           program counter's)

saveDesign saves/${DESIGN}_cts
#restoreDesign saves/${DESIGN}_cts.dat ${DESIGN}

##########################
## Post-CTS Timing
##########################

# update timing constraints post-CTS

update_constraint_mode \
    -name syn_constraints \
    -sdc_files ../../synthesis/netlists/${DESIGN}_postcts.sdc

optDesign \
    -postCTS \
    -hold \
    -outDir ../reports/${DESIGN}/postCTS_opt_timing

timeDesign \
    -postCTS \
    -numPaths 10 \
    -prefix postCTS \
    -outDIR ../reports/${DESIGN}/postCTS

timeDesign \
    -postCTS \
    -hold \
    -numPaths 10 \
    -prefix postCTS_hold \
    -outDIR ../reports/${DESIGN}/postCTS_hold

saveDesign saves/${DESIGN}_postcts
#restoreDesign saves/${DESIGN}_postcts.dat ${DESIGN}

#####################
## Route Design
#####################

routeDesign

# update RC extraction to use postRoute engine
setExtractRCMode \
    -engine postRoute \
    -effortLevel medium

# time design with updated RC extraction
timeDesign \
    -postCTS \
    -numPaths 10 \
    -prefix postRoute \
    -outDIR ../reports/${DESIGN}/postRoute

timeDesign \
    -postCTS \
    -hold \
    -numPaths 10 \
    -prefix postRoute_hold \
    -outDIR ../reports/${DESIGN}/postRoute_hold

# optimize design
optDesign \
    -postRoute \
    -outDir ../reports/${DESIGN}/postRouteOpt

optDesign \
    -postRoute \
    -hold \
    -outDir ../reports/${DESIGN}/postRouteOpt_hold

saveDesign saves/${DESIGN}_route
#restoreDesign saves/${DESIGN}_route.dat ${DESIGN}

#####################
## Decap and Filler
#####################

set decapCells {DECAP_C}

addDeCapCellCandidates DECAP_C 7.775

addDeCap \
    -totCap 100 \
    -addFixAttr \
    -prefix DECAP \
    -cells ${decapCells}


set fillerCells {FILL1 FILL2}

## filler
setFillerMode \
    -corePrefix FILLER \
    -core ${fillerCells}

addFiller \
    -cell ${fillerCells} \
    -prefix FILLER \
    -markFixed

# Connect VDD/GND on all cells
globalNetConnect VDD -type pgpin -pin VDD -override -verbose
globalNetConnect GND -type pgpin -pin GND -override -verbose

verify_connectivity
verify_drc

## final timing report

timeDesign \
    -postRoute \
    -numPaths 10 \
    -prefix final \
    -outDIR ../reports/${DESIGN}/final

timeDesign \
    -postRoute \
    -hold \
    -numPaths 10 \
    -prefix final_hold \
    -outDIR ../reports/${DESIGN}/final

###############################
## design export
###############################

extractRC
rcOut -spef ../netlists/${DESIGN}.spef
write_sdf   ../netlists/${DESIGN}.sdf
saveNetlist ../netlists/${DESIGN}.v

saveDesign saves/${DESIGN}_final
#restoreDesign saves/${DESIGN}_final.dat ${DESIGN}

# exit innovus
exit
