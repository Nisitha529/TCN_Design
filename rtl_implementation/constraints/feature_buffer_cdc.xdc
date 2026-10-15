# feature_buffer_cdc.xdc -- clock-crossing constraints for rtl/stream/feature_buffer.sv
#
# Scoped to the module, so it applies to every instance:
#   read_xdc -ref feature_buffer constraints/feature_buffer_cdc.xdc
# (or add it to the project and set its SCOPED_TO_REF property to feature_buffer).
# The two clocks must already be defined by the system constraints (CMAC /
# QDMA / TCN clock wizard).
#
# Why these are needed: the only signals that cross are the two Gray-coded
# pointers. What makes a Gray pointer safe is that its bits arrive within one
# DESTINATION clock period of each other -- then a sample taken mid-change is
# either the old value or the new one, never a third. That is a bus-skew bound,
# and set_bus_skew below is the constraint for it. An unconstrained crossing
# (what an asynchronous clock group alone gives you) leaves the skew unbounded.
#
# PRECEDENCE -- checked on Vivado 2020.2: set_clock_groups -asynchronous
# between s_clk and m_clk OVERRIDES set_max_delay -datapath_only, so with a
# clock group the max-delay lines below are silently ignored (report_cdc shows
# the crossing under "Asynch Clock Groups"). set_bus_skew is NOT overridden by
# it, which is why it is the constraint that matters. Without a clock group,
# both apply (report_cdc shows "Max Delay Datapath Only").
#
# report_cdc will still list both buses as CDC-6 "Multi-bit synchronized with
# ASYNC_REG property". That is expected: Vivado cannot see that the bus is Gray
# coded. The bus-skew bound is what makes it safe.

set s_period [get_property -min PERIOD [get_clocks -of_objects [get_ports s_clk]]]
set m_period [get_property -min PERIOD [get_clocks -of_objects [get_ports m_clk]]]

# Bus skew: the constraint that makes the Gray crossing correct.
set_bus_skew \
  -from [get_cells -filter {NAME =~ wr_gray_reg[*]}] \
  -to   [get_cells -filter {NAME =~ wr_gray_sync_reg[0][*]}] $m_period
set_bus_skew \
  -from [get_cells -filter {NAME =~ rd_gray_reg[*]}] \
  -to   [get_cells -filter {NAME =~ rd_gray_sync_reg[0][*]}] $s_period

# Total delay: keeps pointer latency (and so full/empty reaction time) bounded
# when the clocks are NOT in an asynchronous clock group -- see PRECEDENCE.
# write pointer -> read domain
set_max_delay -datapath_only \
  -from [get_cells -filter {NAME =~ wr_gray_reg[*]}] \
  -to   [get_cells -filter {NAME =~ wr_gray_sync_reg[0][*]}] $m_period

# read pointer -> write domain
set_max_delay -datapath_only \
  -from [get_cells -filter {NAME =~ rd_gray_reg[*]}] \
  -to   [get_cells -filter {NAME =~ rd_gray_sync_reg[0][*]}] $s_period

# Block RAM / UltraRAM need nothing more: the write and read ports are
# separately clocked inside the primitive, and a word is only read once the
# write pointer that covers it has been synchronised across -- by which time
# it has long been written. With RAM_STYLE="distributed" the read is a LUT-RAM
# path from s_clk logic into the m_clk output register, which needs the same
# bound; uncomment for that build:
# set_max_delay -datapath_only \
#   -from [get_cells -filter {NAME =~ mem_reg*}] \
#   -to   [get_cells -filter {NAME =~ m_axis_tdata_reg[*]}] $m_period
