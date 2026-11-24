# GHC for Windows on Arm (AArch64): unofficial test builds

Test builds of a native Windows AArch64 GHC, used to validate work in
progress in GitHub Actions on `windows-11-arm`. They are not official GHC
releases and are not meant for general use.

## Releases

Each release holds `ghc-<version>-aarch64-unknown-mingw32.tar.gz`, a
relocatable bindist with llvm-mingw's Windows AArch64 toolchain bundled as
`mingw/`, plus its SHA-256. Unpack it anywhere and run `bin\ghc.exe`.

The release notes give the GHC commit each build comes from.

### Current: `ghc-10.1.20261114-9b46c83fd6`

A prerelease for GHC developers, built by cross-compiling from x86_64 Linux
(the `validate` flavour, native bignum, the native code generator,
tables-next-to-code off, library haddocks included). The source is GHC master
`13408a2b59` plus
[!16979](https://gitlab.haskell.org/ghc/ghc/-/merge_requests/16979) (Support
building and testing GHC natively on Windows AArch64, by Nithin Aashik), plus
five test-side commits that touch only the test driver and one test's
assembly file:

- `testsuite: pass {top} to commands with forward slashes`
- `testsuite: write TOP into the test Makefile with forward slashes`
- `testsuite driver: keep ${pkgroot} entries off PATH on Windows`
- `testsuite: don't read config.top as a regex replacement template`
- `testsuite CallConv: enter the pushed return address per the no-TNTC
  convention`

The compiler, RTS linker and RTS code are !16979's. The test-side commits are
on branches of [meop/ghc](https://github.com/meop/ghc). The assembled source
commit is not published, because it carries the MR's commits.

Assets, each with a `.sha256` file:

- `ghc-10.1.20261114-aarch64-unknown-mingw32.tar.gz`: the bindist.
- `ghc-src-9b46c83fd6.tar.gz`: `git archive` of the source commit
  (submodules not included; their commits are pinned in the tree).
- `testsuite-9b46c83fd6-libs.tar.gz`: the matching test tree, with the tests
  in `libraries/*/tests`.
- `testsuite-tools-074195374c.zip`: the five prebuilt AArch64 test tools
  (`check-ppr`, `check-exact`, `dump-decls`, `count-deps`, `changelog-d`)
  that the testsuite calls. They were built with the compiler of the
  previous commit, which differs from this one only in a test file.
- `hsc2hs-0ac065c.tar.gz`: GHC's in-tree hsc2hs. The Hackage release of
  hsc2hs does not yet support Windows AArch64.

**Testsuite result.** GHC's full testsuite at speed 1 (`-Speed 1 -Threads 3`),
run natively on Windows 11 ARM64 against this exact bindist with the test tree
and tools above: 11485 tests (the same set as the x86_64 Windows CI job),
11796 expected passes, 142 expected failures, 0 unexpected failures,
0 unexpected passes, 0 framework failures, 39 fragile. It took 2 h 44 min.

Known gaps: the code generator still needs workarounds (tables-next-to-code
off, large address space off, among others), and their effect has not been
measured. C++ exceptions work but print `libunwind: pc not in table`. T9405
fails under MSYS2 only, because MSYS2's `kill -INT` has no ARM64 helper and
falls back to `TerminateProcess`.

### Earlier releases

Earlier releases were built on branch `wip/windows-aarch64-native` (GHC
master plus):

- `hadrian: use the stage's target executable suffix for programs`
- `hadrian: enable binary-dist-dir-stage3 and recache it with a host ghc-pkg`
- `rts/linker: load AArch64 COFF objects on Windows` (the RTS linker, needed
  for GHCi, `ghc -e` and Template Haskell)
- `hadrian: build the cross-built target ghc with its interpreter`
- `rts/linker: register PE exception tables on AArch64 too`
- `rts/linker: resolve COFF LABEL symbols section-relative` (the `$L.text_1`
  labels LLVM adds in large AArch64 sections)
- `testsuite: don't read config.top as a regex replacement template` (test
  driver only)

Each release's notes say which of these it includes. That branch also holds
the scripts that build and package a bindist (`windows-aarch64/`). The
current release's linker is !16979's, not this branch's.

## Workflows

- `test-ghc.yml`: downloads a release and checks that GHC runs natively and
  builds working programs: hello world, `text`/`bytestring`/`containers`,
  `-threaded`, C FFI, `ghc -e`, Template Haskell, and a quasiquoter. It runs
  when a release is published.

- `test-packages.yml`: builds cabal-install natively with the release's GHC
  (an x64 cabal release drives that first build under emulation), then builds
  real packages with that native cabal and runs their test suites (default:
  ShellCheck and hadolint). It also runs when a release is published.

- `test-testsuite.yml` (manual): runs GHC's own testsuite with the make
  driver against a release's GHC, from the source tree it was built from (the
  release's `ghc-src-<commit>.tar.gz`). The fast speed takes about 2.5 hours.
  It does not use the release's test tree and tools, and its runner script is
  older than the one that produced the result above, so it does not reproduce
  that result.

The scripts in `scripts/` are copies from the GHC branch's
`windows-aarch64/` directory, which is where they are maintained. They are
not all current: `scripts/testsuite-on-host.ps1` is older than the branch's
runner. Releases also carry the hsc2hs source from GHC's tree: the Hackage
release of hsc2hs does not yet support Windows AArch64. `scripts/patches/`
holds the package patches the build needs, with the reason in each.

## Licenses

GHC is under a BSD-style license (`LICENSE` in the bindist). The bundled
toolchain is [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) (LLVM's
Apache 2.0 with LLVM exceptions, plus the mingw-w64 licenses).
