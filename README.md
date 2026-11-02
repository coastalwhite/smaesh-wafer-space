# SMAEsH for WaferSpace

> Templated on [WaferSpace gf180mcu Project Template][Template].

This is an implementation of the [SMAesH] masked AES cryptography primitive for
a WaferSpace shared-project wafer run. The goal is for this chip to be used for
side-channel analysis and fault-injection measurements. Furthermore, since the
PDK is fully open, we can compare the RTL, gate-level, full-timing gate-level,
FPGA and ASIC implementations.

Most of this repository is just a wrapper around the existing SMAesH source
code, including:
- A top-level that receives, feeds and sends data to and from the SMAesH
- A trigger signal to simplify trace collection
- End-to-end testing of the RTL and the gate-level
- Synthesis configuration and instructions

## Building

Dependencies are managed using Nix. You can use the instructions in
<https://librelane.readthedocs.io/en/latest/installation/nix_installation/index.html>
to set up your environment. To activate a shell with all the dependencies,
simply run `nix-shell`. This might take some time on the first invocation. All
the following commands assume you are in this shell.

When setting up, you should clone the SMAesH source code in its submodule, run
`git submodule update --init --recursive`.

To clone the latest PDK version via
[Ciel](https://github.com/fossi-foundation/ciel), run `make clone-pdk`.

To compile the SMAesH source code run `nix build .#smaesh-hdl`.

To synthesize the netlist, run `make librelane`. This will take a while and
place all final artifacts in a `final/` directory.

RTL testing is done by `make sim`, but gate-level testing is still a TODO.

[Template]: https://github.com/wafer-space/gf180mcu-project-template
[SMAesH]: https://github.com/simple-crypto/SMAesH
