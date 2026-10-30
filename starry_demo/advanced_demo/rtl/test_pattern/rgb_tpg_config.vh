`ifndef RGB_TPG_CONFIG_VH
`define RGB_TPG_CONFIG_VH
// fps = 50,000,000 / ((1920/4 + H_BLANK_CYCLES) * (1080 + V_BLANK_LINES)).
// Default: 800 cycles/line, 1250 lines/frame, 50 fps.
// Example 25 fps: H_BLANK_CYCLES=1120, V_BLANK_LINES=170.
`define RGB_TPG_H_BLANK_CYCLES 320
`define RGB_TPG_V_BLANK_LINES  170
`define RGB_TPG_BAR_RED       32'h00FF0000
`define RGB_TPG_BAR_GREEN     32'h0000FF00
`define RGB_TPG_BAR_BLUE      32'h000000FF
`define RGB_TPG_BAR_WHITE     32'h00FFFFFF
`endif
