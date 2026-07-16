# Bundled Python Runtime

HMWorkFlow bundles the official CPython 3.8.10 Windows x64 embeddable distribution for offline use by its Python-backed modules.

Runtime location:

```text
runtime/python/windows-x64/python.exe
```

At HyperMesh startup, `shortcut_bootstrap.tcl` opens a bidirectional pipe to this executable and keeps one worker alive for that HyperMesh instance. The worker is therefore a direct child of HyperMesh in the Windows process tree. Starting another HyperMesh creates another worker and another private pipe; workers are never shared. Closing HyperMesh closes the pipe, causing its worker to exit.

The hybrid core intentionally has no system-Python fallback. If this executable is missing or unusable, startup records a clear error under `runtime/instances/hm-<HyperMesh PID>/startup.log` instead of silently attaching a different Python installation.

## Contents

- CPython interpreter and runtime DLLs;
- `python38.zip`, containing the Python standard library source for manual deployment;
- standard extension modules required by CPython;
- the original `LICENSE.txt` from the distribution.

Local Mesh Optimizer uses only the standard library. No pip packages, network downloads, `site-packages`, or administrator installation are required.

The controller explicitly adds its own script directory to `sys.path` because the embeddable distribution runs with the restrictive `python38._pth` configuration.

## Corporate endpoint compatibility

The target corporate environment automatically encrypts ZIP files. On those
computers, manually extract `python38.zip` beside `python.exe` as the directory
`python38/` before launching HyperMesh. The committed `python38._pth` already
points to that directory, so later updates do not restore the incompatible ZIP
path. The unpacked directory is a local deployment artifact and must not be
included in release packages; both packaging scripts remove it from staging.

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
