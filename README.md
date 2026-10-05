# GHC for Windows on Arm (AArch64): unofficial test builds

Test builds of a native Windows AArch64 GHC, used to validate work in
progress in GitHub Actions on `windows-11-arm`. They are not official GHC
releases and are not meant for general use.

## Releases

Each release holds `ghc-<version>-aarch64-unknown-mingw32.tar.gz`, a
relocatable bindist with llvm-mingw's Windows AArch64 toolchain bundled as
`mingw/`, plus its SHA-256. Unpack it anywhere and run `bin\ghc.exe`.

The release notes give the GHC commit each build comes from. They are built
by cross-compiling from x86_64 Linux on branch `wip/windows-aarch64-native`
(GHC master plus):

- `hadrian: use the stage's target executable suffix for programs`
- `hadrian: enable binary-dist-dir-stage3 and recache it with a host ghc-pkg`
- `rts/linker: load AArch64 COFF objects on Windows` (the RTS linker, needed
  for GHCi, `ghc -e` and Template Haskell)
- `hadrian: build the cross-built target ghc with its interpreter`

## Workflows

- `test-ghc.yml`: downloads a release and checks that GHC runs natively and
  builds working programs: hello world, `text`/`bytestring`/`containers`,
  `-threaded`, C FFI, `ghc -e`, Template Haskell, and a quasiquoter.

## Licenses

GHC is under a BSD-style license (`LICENSE` in the bindist). The bundled
toolchain is [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) (LLVM's
Apache 2.0 with LLVM exceptions, plus the mingw-w64 licenses).
