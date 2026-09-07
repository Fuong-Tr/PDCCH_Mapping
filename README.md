# PDCCH Mapping

Verilog implementation of the **5G NR PDCCH mapping path**, focused on mapping Control Channel Elements (CCE) to Resource Element Groups (REG) inside a CORESET and packing PDCCH data/DMRS for later RE mapping.

## Main blocks

- `cce_to_reg_mapper.v` — maps selected CCEs to REG/RB positions and generates a PDCCH RB bitmap.
- `pdcch_packer.v` — packs PDCCH QPSK data and DMRS into logical REG order.
- `tb_cce_to_reg_mapper.v` — testbench for the CCE-to-REG mapper.
- `TX gNB.drawio` — TX architecture/block diagram.
- `TX RE Mapping Note.txt` — design notes for TX resource-element mapping.
- `CCE_to_REG_Mapper.docx` — detailed design documentation.

## CCE / REG mapping

- 1 REG = 1 RB × 1 OFDM symbol = 12 RE.
- 1 CCE = 6 REG = 72 RE.
- Supported aggregation levels: **1, 2, 4, 8, 16**.
- Supported REG bundle sizes `L`: **2, 3, 6**.
- Supported interleaver sizes `R`: **2, 3, 6**.
- Supports both **non-interleaved** and **interleaved** CCE-to-REG mapping.

The mapper receives CORESET/PDCCH configuration through a 64-bit AXI-style configuration interface and outputs a bitmap indicating the RB/symbol locations occupied by the selected PDCCH.

## Output bitmap

`pdcch_rb_bitmap[symbol * MAX_RB + rb] = 1`

A set bit means that the corresponding REG location belongs to the current PDCCH allocation.

## Target

The project is intended for FPGA implementation and simulation in **Vivado**, as part of a larger 5G NR gNB TX resource-mapping chain.

## Status

Work in progress — current development focuses on CCE-to-REG mapping, interleaving, AXI-style handshaking, and integration with the PDCCH RE mapping path.
