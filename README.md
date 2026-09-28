# PDCCH Mapping

FPGA/Verilog implementation of the **5G NR PDCCH transmit mapping path**, with the current repository focused on two core functions:

1. **PDCCH Packer** – receives PDCCH data/DMRS streams, organizes them in logical REG order, and provides a clean stream for later Resource Element mapping.
2. **CCE-to-REG Mapper** – converts a selected CCE allocation into physical REG/RB/symbol positions inside a CORESET, supporting both non-interleaved and interleaved mapping.

The project is intended for simulation and FPGA implementation in **Xilinx Vivado**, and is part of a larger 5G NR gNB TX resource-grid mapping architecture.

---

## 1. System position

At a high level, the PDCCH path is:

```text
Parameter / DCI configuration
            |
            v
     PDCCH processing
            |
            +--------------------+
            |                    |
            v                    v
      PDCCH Packer        CCE-to-REG Mapper
            |                    |
            | packed PDCCH       | RB/symbol allocation bitmap
            | data / DMRS        |
            +---------+----------+
                      |
                      v
             TX RE Mapping CTRL
                      |
                      v
               Resource Grid RAM
                      |
                      v
              RG RAM Read CTRL
                      |
                      v
                    IFFT
```

The two blocks solve two different problems:

- **PDCCH Packer** handles the **data ordering / streaming side**.
- **CCE-to-REG Mapper** handles the **resource-position side**.

The TX RE Mapping stage combines both: it knows **what sample to write** and **where that sample belongs in the resource grid**.

---

## 2. Repository contents

| File | Purpose |
|---|---|
| `README.md` | Main project documentation |
| `pdcch_packer.tcl` | Vivado project recreation script for the PDCCH packer |
| `pdcch_packer.srcs.zip` | Archived Vivado source set for the PDCCH packer |
| `CCE_to_REG_Mapper.tcl` | Vivado project recreation script for the CCE-to-REG mapper |
| `CCE_to_REG_Mapper.srcs.zip` | Archived Vivado source set for the mapper |
| `TX gNB.drawio` | Overall gNB TX architecture/block diagram |
| `TX RE Mapping Note.txt` | Design notes for TX resource-grid mapping and RAM control |
| `UE_FAPI.xlsx` | FAPI/reference configuration material |

The exported Vivado Tcl scripts reference the RTL and simulation sources used by the projects:

### PDCCH packer project

- RTL: `pdcch_packer.v`
- Testbench: `tb_pdcch_packer.v`
- Simulation top: `tb_pdcch_packer`
- RTL top in the current exported project: `pdcch_packer_minimal`

### CCE-to-REG mapper project

- RTL: `cce_to_reg_mapper.v`
- Testbench: `tb_cce_to_reg_mapper.v`
- Simulation top in the exported project: `tb_cce_to_reg_mapper_optimized`
- RTL top: `cce_to_reg_mapper`

---

## 3. 5G NR resource hierarchy used by the design

The mapper works with the standard PDCCH resource hierarchy:

```text
1 REG = 1 RB x 1 OFDM symbol
      = 12 Resource Elements

1 CCE = 6 REG
```

Therefore:

```text
Number of REG used by one PDCCH
= Aggregation Level x 6
```

Examples:

| Aggregation Level | Number of CCE | Number of REG |
|---:|---:|---:|
| 1 | 1 | 6 |
| 2 | 2 | 12 |
| 4 | 4 | 24 |
| 8 | 8 | 48 |
| 16 | 16 | 96 |

Supported aggregation levels:

```text
AL = 1, 2, 4, 8, 16
```

---

## 4. CCE-to-REG Mapper

### 4.1 Function

The CCE-to-REG mapper determines which REGs belong to a selected PDCCH allocation.

It receives:

- selected starting CCE,
- aggregation level,
- CORESET size,
- CORESET starting symbol,
- CORESET duration,
- REG bundle size,
- interleaver mode,
- interleaver size,
- shift index,

and produces a bitmap representing the physical RB/symbol locations occupied by the PDCCH.

The mapper does **not** generate PDCCH IQ samples. It only generates the **resource allocation / position information**.

---

## 5. REG, bundle and CCE relationship

A REG bundle contains multiple consecutive REGs.

Supported REG bundle sizes:

```text
L = 2, 3, 6
```

Because:

```text
1 CCE = 6 REG
```

the number of bundles per CCE is:

```text
bundles_per_CCE = 6 / L
```

Therefore:

| Bundle size L | Bundles per CCE |
|---:|---:|
| 2 | 3 |
| 3 | 2 |
| 6 | 1 |

For a PDCCH using aggregation level `AL`:

```text
total_REG     = AL x 6
total_bundles = total_REG / L
```

---

## 6. Non-interleaved mapping

In non-interleaved mode, the logical bundle order is also the physical bundle order.

Conceptually:

```text
CCE
 |
 v
Logical REG bundles
 |
 v
Physical REG bundles
 |
 v
REG
 |
 v
(RB, symbol)
```

No row/column permutation is applied.

This is effectively equivalent to using:

```text
R = 1
```

with the number of columns equal to the number of bundles.

---

## 7. Interleaved mapping

Interleaved mapping changes the physical order of REG bundles before they are expanded into REGs.

Supported interleaver sizes:

```text
R = 2, 3, 6
```

The bundle matrix can be viewed as:

```text
R rows
C columns
```

where:

```text
C = N_bundle / R
```

Each cell represents **one REG bundle**, not one individual REG.

The logical bundle index is first converted into row/column coordinates, reordered, shifted by `shift_index`, and wrapped into the valid bundle range.

Conceptually:

```text
Logical bundle
      |
      v
Row / column coordinate
      |
      v
Row-column permutation
      |
      v
Add shift_index
      |
      v
Wrap into bundle range
      |
      v
Physical bundle
```

The implementation is designed to avoid using the Verilog `%` modulo operator for the critical wrap operation. Equivalent compare/subtract logic can be used instead.

---

## 8. Bundle-to-REG expansion

After a physical REG bundle is selected, it is expanded according to `L`.

For example:

### L = 2

```text
Bundle 0 -> REG 0, REG 1
Bundle 1 -> REG 2, REG 3
...
```

### L = 3

```text
Bundle 0 -> REG 0, REG 1, REG 2
Bundle 1 -> REG 3, REG 4, REG 5
...
```

### L = 6

```text
Bundle 0 -> REG 0 ... REG 5
Bundle 1 -> REG 6 ... REG 11
...
```

---

## 9. REG to RB/symbol conversion

A REG represents one RB in one OFDM symbol.

The mapper converts each REG index into:

```text
REG -> RB index + symbol offset
```

The final physical symbol is:

```text
physical_symbol
= coreset_start_symbol + symbol_offset
```

The exact REG-to-RB/symbol relationship depends on the configured CORESET duration.

Supported duration:

```text
duration = 1, 2, 3 OFDM symbols
```

The configuration must satisfy:

```text
coreset_start_symbol + duration <= 14
```

for a normal 14-symbol slot.

---

## 10. Output bitmap

The mapper output represents resource positions in a flattened symbol/RB bitmap.

The indexing convention is:

```text
bitmap_index = symbol * MAX_RB + rb
```

and:

```text
pdcch_rb_bitmap[bitmap_index] = 1
```

means that the corresponding REG belongs to the current PDCCH allocation.

This representation is convenient for the TX Resource Element Mapping controller because it allows the controller to test whether PDCCH occupies a given RB in a given symbol.

---

## 11. PDCCH Packer

### 11.1 Purpose

The PDCCH packer handles the **sample/data side** of the PDCCH path.

Its purpose is to collect and organize PDCCH modulation data and DMRS into the order expected by the later resource-mapping stage.

Conceptually:

```text
PDCCH QPSK data ----+
                    |
                    +--> PDCCH Packer --> packed PDCCH stream
                    |
PDCCH DMRS ---------+
```

The packed output is not itself the final resource grid.

It is a stream that will later be consumed by the TX RE Mapping logic.

---

## 12. Why the packer and mapper are separate

The two blocks intentionally separate:

### Data information

Handled by the **PDCCH Packer**.

It answers:

> Which IQ sample should be transmitted next?

### Position information

Handled by the **CCE-to-REG Mapper**.

It answers:

> Which RB and OFDM symbol should contain this PDCCH allocation?

The TX RE Mapping controller combines these two pieces of information.

This separation also makes the blocks easier to test independently.

---

## 13. Resource Grid RAM architecture

According to the design note in this repository, the larger TX RE Mapping architecture uses **four Block RAMs in a ring arrangement**.

Each RAM stores one OFDM symbol worth of frequency-domain samples.

Conceptually:

```text
                Write side
                    |
                    v
          +-------------------+
          | TX RE Mapping CTRL|
          +-------------------+
                    |
             write pointer
                    |
        +-----+-----+-----+-----+
        |RAM0 |RAM1 |RAM2 |RAM3 |
        +-----+-----+-----+-----+
                    |
              read pointer
                    |
                    v
          +-------------------+
          | RG RAM Read CTRL  |
          +-------------------+
                    |
                    v
                   IFFT
```

Example sequence:

```text
Symbol 0 -> RAM0
Symbol 1 -> RAM1
Symbol 2 -> RAM2
Symbol 3 -> RAM3
Symbol 4 -> RAM0 again after RAM0 becomes free
```

This allows RE mapping and IFFT input reading to operate as a pipeline.

---

## 14. TX RE Mapping CTRL

The TX RE Mapping controller is responsible for writing the individual channel streams into the correct locations of the resource grid.

It receives resource allocation information for channels such as:

- SSB,
- PDCCH,
- PDSCH,

and receives sample streams from their corresponding buffers/FIFOs.

For every OFDM symbol, it determines which channels occupy the symbol and writes their IQ samples into the appropriate Resource Grid RAM addresses.

The PDCCH information therefore arrives from two logical directions:

```text
PDCCH Packer
   |
   +--> IQ/data stream

CCE-to-REG Mapper
   |
   +--> RB/symbol allocation
```

Both are used by the Resource Element mapping stage.

---

## 15. RG RAM Read CTRL

The Resource Grid RAM Read Controller reads a complete OFDM symbol from the current RAM and forwards it to the IFFT path.

For an FFT size of `N`:

```text
N complex samples
```

must be read for each symbol.

The read and write pointers are coordinated so the TX RE mapper does not overwrite a RAM that has not yet been consumed by the IFFT side.

---

## 16. AXI-stream style handshaking

The project uses AXI-stream-style `valid/ready` behavior for streaming paths.

A transfer occurs only when:

```text
valid = 1
and
ready = 1
```

If:

```text
valid = 1
ready = 0
```

the producer must hold the current data stable until the transfer is accepted.

This behavior is especially important for the PDCCH packer because downstream stalls must not cause a sample to be skipped or duplicated.

---

## 17. Configuration checks

A valid CCE-to-REG configuration should verify at least:

- valid aggregation level,
- valid REG bundle size,
- valid interleaver size,
- valid CORESET duration,
- valid RB count,
- selected CCE range fits inside the CORESET,
- `start_symbol + duration <= 14`,
- bundle/REG counts are internally consistent.

Invalid configurations should not generate a valid resource bitmap.

---

## 18. Typical CCE-to-REG processing flow

A practical processing sequence is:

```text
1. Receive configuration
2. Decode aggregation level
3. Calculate number of REG
4. Calculate bundle size / number of bundles
5. Determine selected logical bundles
6. If interleaving is enabled:
      - calculate row and column
      - perform permutation
      - add shift index
      - wrap into valid range
7. Expand bundle into REG indices
8. Convert REG into RB + symbol
9. Set the corresponding bitmap bit
10. Assert bitmap valid
```

---

## 19. Example

Assume:

```text
Aggregation level AL = 2
Bundle size L        = 3
```

Then:

```text
Number of CCE = 2
Number of REG = 2 x 6 = 12
```

Because:

```text
L = 3
```

each bundle contains 3 REG.

Therefore:

```text
Number of bundles = 12 / 3 = 4
```

The mapper processes four logical bundles. If interleaving is enabled, those four bundle indices are permuted before being expanded back into twelve physical REG locations.

---

## 20. Vivado project recreation

The repository includes exported Vivado Tcl scripts.

### CCE-to-REG mapper

From the Vivado Tcl shell:

```tcl
source CCE_to_REG_Mapper.tcl
```

The exported mapper project targets:

```text
xczu9eg-ffvb1156-2-e
ZCU102 board configuration
```

and was exported from **Vivado 2023.2**.

### PDCCH packer

```tcl
source pdcch_packer.tcl
```

The current exported packer project targets:

```text
xc7z010iclg225-1L
```

and was also exported from **Vivado 2023.2**.

> Note: these are the targets stored in the current exported Tcl files. They do not prevent the RTL itself from being reused with another FPGA target after the project constraints/settings are adjusted.

---

## 21. Simulation

The intended verification flow is to test the packer and mapper independently before integrating them into the full TX chain.

### PDCCH packer testbench

Top:

```text
tb_pdcch_packer
```

Important cases include:

- reset behavior,
- single transfer,
- consecutive transfers,
- valid/ready handshake,
- downstream stall,
- output stability during stall,
- end-of-packet behavior,
- supported aggregation levels,
- correct ordering of data and DMRS.

### CCE-to-REG mapper testbench

The exported mapper project uses:

```text
tb_cce_to_reg_mapper_optimized
```

Useful mapping cases include:

- AL = 1,
- AL = 2,
- AL = 4,
- AL = 8,
- AL = 16,
- L = 2,
- L = 3,
- L = 6,
- non-interleaved mapping,
- interleaved R = 2,
- interleaved R = 3,
- interleaved R = 6,
- non-zero shift index,
- CORESET duration = 1,
- CORESET duration = 2,
- CORESET duration = 3,
- invalid configuration handling.

---

## 22. Integration objective

The longer-term integration path is:

```text
PDCCH generation
      |
      v
PDCCH packer
      |
      v
PDCCH buffer / FIFO
      |
      +------------------------------+
                                     |
CCE-to-REG mapper                    |
      |                              |
      v                              v
PDCCH RB/symbol map ----------> TX RE Mapping CTRL
                                     |
                                     v
                              Resource Grid RAM
                                     |
                                     v
                              RG RAM Read CTRL
                                     |
                                     v
                                   IFFT
```

This architecture separates data generation, resource allocation and physical resource-grid construction.

---

## 23. Design goals

The implementation is being developed with the following goals:

- synthesizable Verilog,
- Vivado-friendly RTL,
- simple FSM-based control,
- AXI-stream-style interfaces,
- deterministic CCE-to-REG mapping,
- support for both interleaved and non-interleaved operation,
- minimal unnecessary intermediate logic,
- no dependence on expensive modulo operators where simple compare/subtract logic can be used,
- independent testbenches for each major block,
- later integration into the complete gNB TX resource mapping chain.

---

## 24. Project status

Current repository focus:

- PDCCH packer RTL and testbench,
- CCE-to-REG mapper RTL and testbench,
- REG-bundle interleaving,
- AXI-style flow control,
- CORESET allocation handling,
- integration planning with TX RE Mapping CTRL,
- Resource Grid RAM architecture.

The repository is still under active development and should be treated as an implementation/reference project rather than a complete 3GPP-compliant gNB PHY.

---

## 25. Reference architecture files

For a better understanding of how the individual IPs fit into the complete transmitter, see:

- `TX gNB.drawio`
- `TX RE Mapping Note.txt`
- `CCE_to_REG_Mapper.tcl`
- `pdcch_packer.tcl`

These files provide the architectural context, Vivado project settings and current module/testbench organization.

---

## 26. Summary

The project separates the PDCCH transmit mapping problem into two main questions:

```text
What data should be transmitted?
        -> PDCCH Packer

Where should that data be placed?
        -> CCE-to-REG Mapper
```

The later TX RE Mapping stage combines these results and writes the PDCCH samples into the Resource Grid RAM before the grid is read toward the IFFT.

This separation is the main architectural principle of the repository.
