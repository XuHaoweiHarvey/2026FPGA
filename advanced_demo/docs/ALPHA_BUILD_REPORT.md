# Alpha v6 build report

The advanced Ti60F225 project completed the Efinity 2026.1.132 compile flow
(map, interface, place-and-route and programming-file generation) on 2026-10-22.
The dedicated output directory is `output/efinity_alpha`; the resulting
`ti60f225_oob.bit` is kept out of Git.

Post-route timing analysis reports a 10.000 ns `core_clk` constraint, a
9.223 ns maximum analyzed period (108.425 MHz), and 0.777 ns setup slack for
the core-clock relationship. The smallest reported hold slack is positive at
0.026 ns. The constrained 100 MHz core clock therefore meets timing in this
build.

The Ti60F225 placement report uses 50,715/60,800 XLRs (83.41%), 165/256 memory
blocks (64.45%), 46/160 DSP blocks (28.75%), and 17/32 global clocks (53.12%).
This fits the selected device, with XLR capacity as the tightest resource.

Efinity reports 117 warnings in the post-map netlist. Alpha-specific warnings
are two 9-bit-to-8-bit truncations when assigning `burst_beats - 1` to AXI
lengths (legal bursts are capped at 32 beats), and two 4096-bit segment arrays
mapped into logic because of the inferred read-port form. The arrays are
functional in simulation; their logic mapping contributes to XLR use and is a
clear target for future memory-inference optimization. The build has no
reported compile or timing failure.

The matching RV32 ELF was built at `output/toolchain/advanced/advanced_demo.elf`
with the formal 64 KiB OCRAM linker layout. Neither this build nor the bitstream
has been run on the physical board; on-board Alpha/Color Key output, error
counters, FPS and actual presentation cadence remain to be measured.
