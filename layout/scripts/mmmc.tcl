###########################
## MMMC Setup



## operating conditions
create_op_cond \
    -name OP_ss_125 \
    -library_file {/apps/design_kits/ibm_kits/IBM_IP/ibm_cmos8hp/std_cell/sc/v.20110613/synopsys/ss_125/IBM_CMOS8HP_SS125.lib} \
    -P {1} \
    -V {1.35} \
    -T {125}

create_op_cond \
    -name OP_ff_-55 \
    -library_file {/apps/design_kits/ibm_kits/IBM_IP/ibm_cmos8hp/std_cell/sc/v.20110613/synopsys/ff_-55/IBM_CMOS8HP_FF55.lib} \
    -P {1} \
    -V {1.60} \
    -T {-55}

## rc corners
create_rc_corner \
    -name RC_max \
    -cap_table /apps/design_kits/ibm_kits/IBM_DIG_FLOW/cmos8hp/cadence/v.20110204/captable/cmos8hp_7AM_41_FuncCmax.CapTbl \
    -qx_tech /apps/design_kits/ibm_kits/IBM_DIG_FLOW/cmos8hp/cadence/v.20110204/tch/cmos8hp_7AM_41_FuncCmax.tch

create_rc_corner \
    -name RC_min \
    -cap_table /apps/design_kits/ibm_kits/IBM_DIG_FLOW/cmos8hp/cadence/v.20110204/captable/cmos8hp_7AM_41_FuncCmin.CapTbl \
    -qx_tech /apps/design_kits/ibm_kits/IBM_DIG_FLOW/cmos8hp/cadence/v.20110204/tch/cmos8hp_7AM_41_FuncCmax.tch

## standard cell library
create_library_set \
    -name LIB_ss_125 \
    -timing {/apps/design_kits/ibm_kits/IBM_IP/ibm_cmos8hp/std_cell/sc/v.20110613/synopsys/ss_125/IBM_CMOS8HP_SS125.lib}

create_library_set \
    -name LIB_ff_-55 \
    -timing {/apps/design_kits/ibm_kits/IBM_IP/ibm_cmos8hp/std_cell/sc/v.20110613/synopsys/ff_-55/IBM_CMOS8HP_FF55.lib}


## create corners
create_delay_corner \
    -name CORNER_ss_125 \
    -library_set LIB_ss_125 \
    -rc_corner RC_max

create_delay_corner \
    -name CORNER_ff_-55 \
    -library_set LIB_ff_-55 \
    -rc_corner RC_min

## create analysis views
create_analysis_view \
    -name VIEW_ss_125 \
    -delay_corner CORNER_ss_125 \
    -constraint_mode syn_constraints

create_analysis_view \
    -name VIEW_ff_-55 \
    -delay_corner CORNER_ff_-55 \
    -constraint_mode syn_constraints

## Set analysis views for setup and hold
#set_analysis_view \
#    -setup {VIEW_ss_125} \
#    -hold {VIEW_ff_-55}
