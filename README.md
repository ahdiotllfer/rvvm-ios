# rvvm-ios

An iOS app wrapper around [RVVM](https://github.com/ahdiotllfer/RVVM) (RISC-V virtual machine), built with Theos.

This repository vendors RVVM as a git submodule and compiles a subset of RVVM sources directly into the iOS application target.

## Repository layout

- `RVVM/`: RVVM submodule (core VM + devices)
- `Resources/`: app resources (includes xterm.js assets used by the UI)
- `RV64Runner.mm`, `RV64RootViewController.m`: iOS UI + VM integration

## Build (Theos)

### Prerequisites

- Theos installed and `THEOS` environment variable set
- iOS SDK/toolchain available to Theos (see Theos documentation for setup)
- `curl` (used to fetch xterm.js assets on first build)

### Clone

```bash
git clone --recurse-submodules git@github.com:ahdiotllfer/rvvm-ios.git
cd rvvm-ios
```

### Build the app

```bash
make
```

The built `.app` ends up under:

```text
.theos/obj/debug/rvvm.app
```

### Build an IPA

```bash
make ipa
```

The resulting `.ipa` is written under Theos’ package directory (usually `.theos/packages/`).

## Notes

- The RVVM submodule path is `RVVM` by default; override with `RVVM_DIR=...` if needed.
