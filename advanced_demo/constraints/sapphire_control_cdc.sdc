# Load AFTER the original SDC, when core_clk has been defined.
# The generated Sapphire JTAG bridge synchronizes its TCK/core_clk crossings.
# This exception is confined to JTAG; RGB pair_clk/pixel_clk timing is retained.
set_clock_groups -asynchronous -group {jtag_inst1_TCK} -group {core_clk}
