{
  nixConfig = {
    extra-substituters = [
      "https://nix-cache.fossi-foundation.org"
    ];
    extra-trusted-public-keys = [
      "nix-cache.fossi-foundation.org:3+K59iFwXqKsL7BNu6Guy0v+uTlwsxYQxjspXzqLYQs="
    ];
  };

  inputs = {
    librelane.url = "github:librelane/librelane/dev";

    # The SMAesH IP and its nested COMPRESS dependency, as plain sources.
    #
    # These duplicate the git submodule pins (ip/SMAesH, and its own
    # sboxes-compress/compress) on purpose: flakes do not fetch submodules
    # unless you remember `?submodules=1`, and COMPRESS is pinned over SSH,
    # which CI will not have a key for. Keep the revisions below in sync with
    # `git submodule status` when bumping either one.
    smaesh = {
      url = "github:simple-crypto/SMAesH/01e46e41f496bca75ced34f24f7273e28d212455";
      flake = false;
    };
    compress = {
      url = "github:cassiersg/compress/26ccd9ca3a0e761b78f22367b5b77f678a611795";
      flake = false;
    };
  };

  outputs =
    {
      self,
      librelane,
      smaesh,
      compress,
      ...
    }:
    let
      nix-eda = librelane.inputs.nix-eda;
      devshell = librelane.inputs.devshell;
      nixpkgs = nix-eda.inputs.nixpkgs;
      lib = nixpkgs.lib;
    in
    {
      # Outputs
      legacyPackages = nix-eda.forAllSystems (
        system:
        import nixpkgs {
          inherit system;
          overlays = [
            nix-eda.overlays.default
            devshell.overlays.default
            librelane.overlays.default
          ];
        }
      );

      packages = nix-eda.forAllSystems (
        system:
        let
          pkgs = self.legacyPackages.${system};
        in
        rec {
          # Flattened SMAesH HDL tree with the COMPRESS-generated S-box,
          # i.e. what `make -C ip/SMAesH hdl` produces. See nix/smaesh-hdl.nix
          # for the reproducibility caveat before wiring this into CI.
          smaesh-hdl = pkgs.callPackage ./nix/smaesh-hdl.nix {
            smaeshSrc = smaesh;
            compressSrc = compress;
          };

          default = smaesh-hdl;
        }
      );

      devShells = nix-eda.forAllSystems (
        system:
        let
          pkgs = (self.legacyPackages.${system});
          callPackage = lib.callPackageWith pkgs;
        in
        {
          default = pkgs.librelane-shell.override ({
            extra-packages = with pkgs; [
              # Utilities
              gnumake
              gnugrep
              gawk

              # Simulation
              iverilog
              verilator

              # Verilator compiles the simulation to C++, so cocotb's
              # verilator runner needs a host compiler on PATH. Icarus is
              # not an alternative here: it cannot elaborate SMAesH, and
              # upstream only supports verilator.
              gcc

              # Waveform viewing
              gtkwave
              surfer
            ];

            extra-python-packages =
              ps: with ps; [
                # Verification
                cocotb

                # For KLayout Python DRC runner
                docopt

                # For logo generation
                pillow
              ];
          });
        }
      );
    };
}
