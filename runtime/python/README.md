# Bundled Python Runtime

HMWorkFlow bundles the official CPython 3.8.10 Windows x64 embeddable distribution for offline use by Local Mesh Optimizer.

Runtime location:

```text
runtime/python/windows-x64/pythonw.exe
```

The Tcl module uses `pythonw.exe` automatically when `PYTHON_COMMAND` is empty, so no command-line window is shown. `python.exe` is retained for packaging checks and command-line diagnostics. A user-configured interpreter is mapped to its sibling `pythonw.exe`; interpreters without a windowless executable are rejected on Windows. System launchers are fallback candidates only when a matching windowless launcher is available.

## Contents

- CPython interpreter and runtime DLLs;
- `python38.zip`, containing the Python standard library;
- standard extension modules required by CPython;
- the original `LICENSE.txt` from the distribution.

Local Mesh Optimizer uses only the standard library. No pip packages, network downloads, `site-packages`, or administrator installation are required.

The controller explicitly adds its own script directory to `sys.path` because the embeddable distribution runs with the restrictive `python38._pth` configuration.

## Source and integrity

- Source: `https://www.python.org/ftp/python/3.8.10/python-3.8.10-embed-amd64.zip`
- Official release page MD5: `3acb1d7d9bde5a79f840167b166bb633`
- SHA-256: `abbe314e9b41603dde0a823b76f5bbbe17b3de3e5ac4ef06b759da5466711271`
- Target: Windows x86-64/AMD64

Python 3.8 is end-of-life. It is intentionally used here as a compatibility-focused offline runtime for the HyperMesh 2019-era Windows environment. It must not be used as a general-purpose network-facing interpreter.

## Replacing the runtime

If the target environment requires another architecture or Python version:

1. obtain the official embeddable distribution;
2. replace the contents of `runtime/python/windows-x64`;
3. update the runtime manifest and checksum documentation;
4. run the offline self-test and both packaging scripts;
5. verify the resulting package on the target HyperMesh build.
