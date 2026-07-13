###########################
## Innovus Floorplan Script
## adapted for tiny-gpu (top module: gpu)
###########################


# Step 1: adjust the core size for the layout. Floorplan -> Specify Floorplan
#     Core Size by: Aspect Ratio,  Ratio (H/W) = 1.0 (square)
#     Core Utilization = 0.25   <-- IMPORTANT for gpu
#     Add margins of 15um to all sides of the core
#     NOTE (gpu): the gpu is much larger than the program counter
#     (~1500+ flops, multipliers and dividers per thread) and the cmos8hp
#     kit only has ~5 routing layers (M1-M4, MQ). Higher utilization does
#     NOT route: at 0.35 the ~8500 preCTS-opt buffers pushed density back to
#     ~62% and routeDesign stalled with hundreds of M2/M3 shorts and M4
#     spacing violations that never cleared. Start at 0.25 so post-OPT
#     density lands ~45-50%. Expect a core on the order of ~1.5-2 mm/side;
#     that sparse look is correct for this routing-limited design.

# Step 2: add power rings to the design. Power -> Power Planning -> Add Ring
#     for nets, select VDD and GND
#     for configuration, place the rings on metal 4/5 depending on the orientation of the route (metal 5 is horizonatal, metal 4 is vertical)
#     set the width to 5um

# Step 3: add power stripes to the design. Power -> Power Planning -> add Stripe
#     for nets, select VDD and GND
#     The stripes should be vertical and on layer 4
#     Set width to 5
#     NOTE (gpu): keep the M4 stripes SPARSE. Use a large set-to-set
#     distance (~300um, i.e. only 2-3 VDD/GND stripe pairs across the core).
#     M4 is the only vertical signal-routing layer here, so tightly-spaced
#     stripes starve it of tracks - that was the persistent ~132 M4 MetSpc
#     violations that would not clear during routing. Fewer stripes = more
#     M4 signal tracks.

# Step 4: route power from the rings/stripes to the standard cell rows
#      Route -> Special Route
#      Nets are VDD and GND
#      Under Via Generation tab, select Make Via Connections to Core Ring and Stripe
#      Once you do sroute, zoom in on layout and make sure the vias were added

# Step 5: Place the pins
#      Edit -> Pin Editor
#      Select all the pins from the list in the lower left
#      Set pin layer to M2, and Width/Depth to 0.5
#      For location, set "Spread" and then on the top of window, the Side/Edge field should become valid.
#      NOTE (gpu): gpu has ~183 pins - far too many for one edge.
#      Spread them across sides instead, e.g.:
#        - clk, reset, start, done, device_control_* on Top
#        - program_mem_* (26 pins) on Left
#        - data_mem_read_* (72 pins) on Bottom
#        - data_mem_write_* (72 pins) on Right
#      (select each group in the pin list and assign its side, keeping
#       Spread mode; start the X/Y offset at 20um so pins clear the
#       corner power rings)


setEndCapMode \
    -cells NWSX \
    -leftEdge NWSX \
    -rightEdge NWSX

addEndCap -prefix ENDCAP

#deleteFiller -prefix ENDCAP

addWellTap \
    -cell NWSX \
    -prefix WELLTAP \
    -cellInterval 30.0 \
    -skipRow 1 \
    -inRowOffset 15

addWellTap \
    -cell NWSX \
    -prefix WELLTAP \
    -cellInterval 30.0 \
    -skipRow 1 \
    -startRowNum 2 \
    -inRowOffset 30.0

#deleteFiller -prefix WELLTAP

saveFPlan ../floorplan/${DESIGN}_floorplan.fp
#loadFPlan ../floorplan/${DESIGN}_floorplan.fp
