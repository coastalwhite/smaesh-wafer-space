#!/usr/bin/env python3
# SPDX-FileCopyrightText: © 2025 Project Template Contributors
# SPDX-License-Identifier: Apache-2.0
"""Turn a cocotb results.xml into a process exit code.

cocotb runs the simulator as a child process, and neither iverilog nor
verilator propagate a failed assertion into their own exit status -- a run
where every test failed still leaves `make sim` returning 0. The only record
of what happened is the JUnit XML the regression manager writes, so CI has to
read it to decide anything.

The obvious shell version of this check,

    ! grep failure cocotb/sim_build/results.xml

is worse than no check at all: if the simulator dies before writing the file,
grep exits 2, `!` turns that into success, and the job goes green on a run
that never produced a result. This script treats a missing, unparseable or
empty report as a failure, which is the case that actually matters.

Usage: check_sim_results.py <results.xml> [...]
"""

import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def summarize(path: Path):
    """Return (testcases, failures) for one report, or raise ValueError."""
    if not path.is_file():
        raise ValueError(f"no results file at {path} -- the simulation did not finish")

    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as exc:
        raise ValueError(f"{path} is not valid XML ({exc}) -- the simulation was cut short")

    cases = root.findall(".//testcase")
    if not cases:
        raise ValueError(f"{path} contains no testcases -- nothing ran")

    failures = []
    for case in cases:
        name = f"{case.get('classname', '?')}.{case.get('name', '?')}"
        # cocotb writes <failure> for an assertion and <error> for a crash in
        # the test coroutine; both mean the test did not pass.
        for bad in list(case.findall("failure")) + list(case.findall("error")):
            failures.append((name, bad.get("error_type", bad.tag), bad.get("error_msg", "")))

    return cases, failures


def main(argv):
    if len(argv) < 2:
        print(f"usage: {argv[0]} <results.xml> [...]", file=sys.stderr)
        return 2

    lines = []
    ok = True

    for arg in argv[1:]:
        path = Path(arg)
        try:
            cases, failures = summarize(path)
        except ValueError as exc:
            ok = False
            print(f"ERROR: {exc}", file=sys.stderr)
            lines.append(f"| `{path}` | n/a | n/a | **no report** |")
            continue

        passed = len(cases) - len(failures)
        status = "pass" if not failures else "**FAIL**"
        lines.append(f"| `{path}` | {len(cases)} | {passed} | {status} |")

        print(f"{path}: {len(cases)} tests, {passed} passed, {len(failures)} failed")
        for name, kind, msg in failures:
            ok = False
            # Keep the whole assertion message: for the SMAesH vectors it is
            # the key/input/expected/got block, which is the useful part.
            print(f"  FAIL {name} ({kind})")
            for line in msg.splitlines():
                print(f"       {line}")

    # GitHub renders this under the job in the run summary.
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a") as fh:
            fh.write("\n### cocotb results\n\n")
            fh.write("| report | tests | passed | status |\n")
            fh.write("| --- | --- | --- | --- |\n")
            fh.write("\n".join(lines) + "\n")

    if not ok:
        print("\nsimulation FAILED", file=sys.stderr)
        return 1

    print("\nall simulations passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
