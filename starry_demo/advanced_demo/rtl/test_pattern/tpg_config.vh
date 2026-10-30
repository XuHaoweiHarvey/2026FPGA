`ifndef TPG_CONFIG_VH
`define TPG_CONFIG_VH
// Phase in framebuffer MSB-first sample order; see docs/ARCHITECTURE.md.
// 0=RGGB, 1=BGGR, 2=GRBG, 3=GBRG. Keep the existing HDMI R/B mapping.
`define TPG_BAYER_PATTERN       1
`define TPG_H_BLANK_CYCLES      320
`define TPG_V_BLANK_LINES       170
// Centralized final HDMI RGB colors, left to right.
`define TPG_BAR_RED             24'hFF0000
`define TPG_BAR_GREEN           24'h00FF00
`define TPG_BAR_BLUE            24'h0000FF
`define TPG_BAR_WHITE           24'hFFFFFF
`define TPG_GAIN_Q8_8           16'h0100
`endif
