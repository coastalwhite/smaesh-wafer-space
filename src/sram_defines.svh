// SPDX-FileCopyrightText: © 2025 XXX Authors
// SPDX-License-Identifier: Apache-2.0
//
// Resolves the configured SRAM vendor to a macro naming its 512x8 macro cell.
//
// Included by both chip_top.sv and chip_core.sv rather than being defined in
// the former and used in the latter: yosys' own Verilog frontend carries
// preprocessor state across files, but the slang frontend compiles each file
// as its own unit, so a macro defined in one file is not visible in the next.
// The include guard keeps that harmless under either.

`ifndef SRAM_DEFINES_SVH
`define SRAM_DEFINES_SVH

`include "generated_defines.svh"

`ifdef SRAM_gf180mcu_ocd_ip_sram
`define gf180mcu_xxx_ip_sram__sram512x8m8wm1 gf180mcu_ocd_ip_sram__sram512x8m8wm1
`else
`define gf180mcu_xxx_ip_sram__sram512x8m8wm1 gf180mcu_fd_ip_sram__sram512x8m8wm1
`endif

`endif
