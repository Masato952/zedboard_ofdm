# Add the project-owned build_info RTL module to an already-created ADI Zed BD.
# Source this after the base zed_system_bd.tcl/fmcomms2_bd.tcl scripts have run.

set build_info_bd_script_dir [file dirname [file normalize [info script]]]
set build_info_repo_root [file normalize \
  [file join $build_info_bd_script_dir .. .. ..]]
set build_info_rtl_dir [file join \
  $build_info_repo_root fpga rtl common build_info]

# Freeze Git/date/time metadata immediately before the RTL is added.
source [file join $build_info_repo_root fpga scripts generate_build_info.tcl]

set build_info_rtl [file join $build_info_rtl_dir build_info_axi.v]
set build_info_header [file join $build_info_rtl_dir build_info_regs.vh]
add_files -norecurse [list $build_info_header $build_info_rtl]
set_property file_type {Verilog Header} [get_files $build_info_header]

set build_info_include_dirs [get_property include_dirs [current_fileset]]
if {[lsearch -exact $build_info_include_dirs $build_info_rtl_dir] < 0} {
  lappend build_info_include_dirs $build_info_rtl_dir
  set_property include_dirs $build_info_include_dirs [current_fileset]
}

create_bd_cell -type module -reference build_info_axi build_info_0
ad_cpu_interconnect 0x43C00000 build_info_0 S_AXI
ad_connect sys_cpu_resetn build_info_0/s_axi_aresetn
