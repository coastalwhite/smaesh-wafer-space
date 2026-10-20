# SPDX-FileCopyrightText: © 2025 XXX Authors
# SPDX-License-Identifier: Apache-2.0
#
# cpmpy is not packaged in nixpkgs, but COMPRESS's solver frontend
# (scripts/compress.py) imports it directly.
{
  lib,
  buildPythonPackage,
  fetchPypi,
  setuptools,
  numpy,
  ortools,
  packaging,
}:

buildPythonPackage rec {
  pname = "cpmpy";
  version = "0.10.1";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-QQxpPoqwTVtH7P52n7wjgFl3IGpBgmzfxv36nnDtw4Y=";
  };

  build-system = [ setuptools ];

  # cpmpy pins ortools <=9.14.6206; nixpkgs labels its 9.14 as "9.14.9999",
  # a placeholder that fails the pin on a version that actually satisfies it.
  pythonRelaxDeps = [ "ortools" ];

  dependencies = [
    numpy
    ortools
    packaging
    setuptools
  ];

  # The test suite pulls in a pile of optional solver backends.
  doCheck = false;
  pythonImportsCheck = [ "cpmpy" ];

  meta = {
    description = "Constraint programming and modeling library in Python";
    homepage = "https://github.com/CPMpy/cpmpy";
    license = lib.licenses.mit;
  };
}
