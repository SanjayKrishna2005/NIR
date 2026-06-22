## This file is a clean .xdc for the EDGE Artix 7 board running the VIO Testbench

# Clock signal (N11)
set_property -dict { PACKAGE_PIN N11    IOSTANDARD LVCMOS33 } [get_ports { clk }];
# Assuming 50 MHz oscillator (period = 20.00 ns). Update to 10.00 ns if 100 MHz.
create_clock -add -name sys_clk_pin -period 20.00 -waveform {0 10} [get_ports { clk }];

# Push Button (K13)
set_property -dict {PACKAGE_PIN K13 IOSTANDARD LVCMOS33 PULLDOWN true} [get_ports {pb[0]}]; #Button-top

## NO OTHER PINS ARE NEEDED FOR THE VIO TESTBENCH!
## The VIO IP communicates to the PC over the JTAG connection, 
## which does not require any explicit PL pin assignments.
