# SPDX-FileCopyrightText: © 2025 XXX Authors
# SPDX-License-Identifier: Apache-2.0
#
# Generates the flattened SMAesH HDL tree that `make -C ip/SMAesH hdl` would
# produce, without needing `uv`, a network connection or the nested
# `sboxes-compress/compress` git submodule.
#
# The result is the directory SMAesH's own flows call RTL_DIR_HDL: every
# source flattened into one directory, so `*.v`/`*.sv` globbing plus a single
# include path is enough to elaborate `smaesh_hpc`.
#
#   $out/hdl                 flat HDL tree (sources + generated headers)
#   $out/share/compress      solver stats and log for the generated S-box
#
# NOTE ON REPRODUCIBILITY: the S-box is produced by COMPRESS, which optimises
# it with ortools CP-SAT (via cpmpy). The model reaches *proven optimality* in
# a fraction of a second, so the wall-clock budget never decides the result --
# but the optimal set has many members, and anything that reorders the model's
# decision variables changes which member comes back. Two such sources turned
# up, and both are pinned below:
#
#   * Python hash randomisation, which reorders the sets of strings
#     compress.py builds its model from. This is the dominant one: without
#     PYTHONHASHSEED pinned, two builds on the same machine already differ.
#   * CP-SAT's worker count, which follows the host's core count and
#     tie-breaks differently between hosts -- see `deterministicSolver`.
#
# Builds that differ this way still agree on area, gadget mix and `rnd_bus*`
# widths; only S-box register placement moves. With both pinned the
# derivation passes `nix build --rebuild`.
{
  lib,
  stdenvNoCC,
  python3,
  yosys,
  verilator,
  gnumake,
  smaeshSrc,
  compressSrc,
  # Number of shares. Must match the `d` parameter the design is instantiated
  # with; src/smaesh_driver.sv passes .d(2).
  nshares ? 2,
  # S-box latency target, in cycles. SMAesH builds with 4.
  latency ? 4,
  # Solver budget in seconds, per COMPRESS invocation. Not normally reached:
  # the S-box model solves to proven optimality in well under a second.
  timeoutCompress ? 3600,
  # Pin CP-SAT to a single worker with a fixed seed. PYTHONHASHSEED alone is
  # enough to make rebuilds on one host identical; this additionally stops a
  # host with a different core count from picking a different member of the
  # optimal set. Costs nothing -- the solve is well under a second either way.
  deterministicSolver ? true,
}:

let
  python = python3.override {
    # Without threading `self` through, packages in the overridden set still
    # resolve their own dependencies against the original one, and the
    # protobuf swap below silently does nothing.
    self = python;
    packageOverrides = pyfinal: pyprev: {
      # nixpkgs' or-tools generates its protobuf bindings with C++ protoc
      # 31.1 (gencode 6.31.1) but pairs them with the Python protobuf 5
      # runtime, so importing ortools.sat dies on protobuf's gencode/runtime
      # major-version check. Line the runtime up with the gencode;
      # protobuf/6.nix asserts only that it is not older than the protoc it
      # is built against, which 6.33.1 satisfies against 31.1.
      protobuf5 = pyprev.protobuf6;

      cpmpy = pyfinal.callPackage ./cpmpy.nix { };
    };
  };

  pythonEnv = python.withPackages (ps: [
    ps.cpmpy
    ps.networkx
    ps.numpy
    ps.tomli
  ]);

  circuitName = "canright_aes_sbox_dual";
  circuitDir = "circuits/${circuitName}_d${toString nshares}_l${toString latency}";
in

stdenvNoCC.mkDerivation {
  pname = "smaesh-hdl";
  version = "2.0.1-d${toString nshares}";

  dontUnpack = true;

  # compress.py builds its model by iterating over sets of strings, whose
  # order varies per process unless the hash seed is pinned. That reorders
  # the decision variables and so changes which member of the optimal set
  # CP-SAT returns, independently of the solver's own settings.
  PYTHONHASHSEED = "0";

  nativeBuildInputs = [
    pythonEnv
    yosys
    gnumake
  ];

  # Deliberately serial. The per-gadget area syntheses look independent, but
  # concurrent yosys processes share one liberty-cache directory under
  # TMPDIR and race on it, which surfaces as an intermittent
  #   ERROR: Can't open ABC output file `.../output.blif'
  # from whichever gadget lost. Serial costs nothing worth having: the whole
  # derivation builds in about 15 seconds once or-tools is in the store.
  enableParallelBuilding = false;

  buildPhase = ''
    runHook preBuild

    # Both source trees get written into, so work on copies.
    cp -r --no-preserve=mode,ownership ${smaeshSrc} smaesh
    cp -r --no-preserve=mode,ownership ${compressSrc} compress
    ${lib.optionalString deterministicSolver ''
      # See the reproducibility note at the top. cpmpy forwards unknown
      # kwargs straight to ortools' sat_parameters, but cpmpy.Model.solve
      # rejects solver-specific kwargs unless the solver is named -- and
      # "ortools" is the default it would have picked anyway. --replace-fail
      # so an upstream edit to this call breaks the build loudly instead of
      # silently dropping the pin.
      substituteInPlace compress/scripts/compress.py \
        --replace-fail \
          'm.m.solve(time_limit=params.time_limit)' \
          'm.m.solve(solver="ortools", time_limit=params.time_limit, num_workers=1, random_seed=0)'
    ''}

    work=$PWD/work
    mkdir -p "$work"

    echo "==> Elaborating unmasked S-box to a JSON netlist"
    ( cd smaesh/sboxes-compress
      FILE_IN=${circuitName}.v \
      YOSYS_NETLIST="$work/${circuitName}.json" \
        yosys -c build-json-yosys.tcl
    )

    echo "==> Converting netlist to a COMPRESS circuit description"
    python3 compress/scripts/yosys2compress.py \
      --netlist-file "$work/${circuitName}.json" \
      --top ${circuitName} \
      --compress-file "$work/${circuitName}.txt"

    echo "==> Running COMPRESS (d=${toString nshares}, latency=${toString latency}, budget=${toString timeoutCompress}s)"
    make -C compress \
      -j1 \
      WORK="$work/compress" \
      CIRCUIT="$work/${circuitName}.txt" \
      DS=${toString nshares} \
      LATS=${toString latency} \
      TIMEOUT_COMPRESS=${toString timeoutCompress} \
      YOSYS=yosys \
      PYTHON=python3 \
      "$work/compress/${circuitDir}/design.v"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/hdl" "$out/share/compress"

    # Equivalent of SMAesH's gather_sources.sh: flatten the design and the
    # COMPRESS gadget library into a single directory.
    for dir in \
      smaesh/hdl/smaesh_hpc \
      compress/gadget_library/BIN \
      compress/gadget_library/MSK
    do
      # Process substitution, not a pipe: a collision has to fail the build,
      # and `exit` from a piped subshell would not.
      while IFS= read -r -d ''' f; do
        base=$(basename "$f")
        if [ -e "$out/hdl/$base" ]; then
          echo "ERROR: $base collides while flattening ($f)" >&2
          exit 1
        fi
        cp "$f" "$out/hdl/$base"
      done < <(find "$dir" -type f \( -name '*.v' -o -name '*.vh' -o -name '*.sv' \) -print0)
    done

    # The generated S-box, named as the rest of the design includes it.
    cp "$work/compress/${circuitDir}/design.v"  "$out/hdl/${circuitName}.v"
    cp "$work/compress/${circuitDir}/design.vh" "$out/hdl/${circuitName}.vh"

    # Supplies `DEFAULTSHARES, the default for smaesh_hpc's `d` parameter.
    echo '`define DEFAULTSHARES ${toString nshares}' > "$out/hdl/architecture_default.vh"

    # Both of these embed the measured solve time, which would make the
    # output differ between builds even with the solver pinned. Keep the
    # parts that describe the design (area estimate, gadget mix) and drop
    # the timing.
    python3 - "$work/compress/${circuitDir}/stats.json" "$out/share/compress/stats.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    stats = json.load(f)
stats.pop("solve_time", None)
with open(sys.argv[2], "w") as f:
    json.dump(stats, f, indent=2, sort_keys=True)
    f.write("\n")
PY
    sed -E 's/\([0-9]+\.[0-9]+ seconds\)/(time elided for reproducibility)/' \
      "$work/compress/${circuitDir}/compress.log" > "$out/share/compress/compress.log"

    runHook postInstall
  '';

  # Same check as SMAesH's own `make lint-verilator`: resolves every module
  # and include from the flattened tree, so a missing gadget or header fails
  # the build here rather than in the testbench.
  doInstallCheck = true;
  nativeInstallCheckInputs = [ verilator ];
  installCheckPhase = ''
    runHook preInstallCheck

    echo "==> Linting smaesh_hpc from the generated tree"
    ( cd "$out/hdl" && verilator --lint-only smaesh_hpc.sv )

    runHook postInstallCheck
  '';

  meta = {
    description = "Flattened SMAesH masked-AES HDL tree, with COMPRESS-generated S-box";
    homepage = "https://github.com/simple-crypto/SMAesH";
    # Not in nixpkgs' license set.
    license = {
      spdxId = "CERN-OHL-S-2.0";
      fullName = "CERN Open Hardware Licence Version 2 - Strongly Reciprocal";
      url = "https://ohwr.org/cern_ohl_s_v2.txt";
      free = true;
    };
  };
}
