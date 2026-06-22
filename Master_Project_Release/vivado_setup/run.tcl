connect
targets -set -filter {name =~ "*ARM*#0"}
rst -system

fpga -file nir_app/_ide/bitstream/nir_system_wrapper.bit

targets -set -filter {name =~ "*ARM*#0"}
dow nir_app/Debug/nir_app.elf
con