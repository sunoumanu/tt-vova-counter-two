// 27 MHz board crystal
create_clock -name clk -period 37.037 -waveform {0 18.518} [get_ports {clk}]

// The core and all board logic run from a /4 divider off the crystal: 6.75 MHz
create_generated_clock -name core_clk -source [get_ports {clk}] -divide_by 4 [get_nets {core_clk}]
