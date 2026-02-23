# TTMPythonRuntimeBundle Runtime Layout

Place a bundled arm64 CPython runtime under one of these directories:

- `Runtime/current`
- `Runtime/python3.11`
- `Runtime/python3.11-arm64`

Expected contents (example for Python 3.11):

- `lib/libpython3.11.dylib`
- `lib/python3.11/` (stdlib)
- `lib/python3.11/site-packages/` (dependencies)

This folder is packaged as an SPM resource and discovered at runtime by
`TTMPythonRuntimeBundleLocator`.
