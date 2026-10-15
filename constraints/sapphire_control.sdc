# Sapphire's generated Ti60F225 example uses a 100 ns Hard JTAG timing budget.
# Actual generated debug_ti.cfg uses adapter speed 800 (kHz), below this budget.
# Load this file BEFORE the original SDC so its JTAG IO delays see this clock.
create_clock -period 100.000 -name jtag_inst1_TCK [get_ports {jtag_inst1_TCK}]
