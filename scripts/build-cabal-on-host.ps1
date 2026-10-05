# Runs on the Windows AArch64 host (copied there by build-cabal-on-host.sh).
# Builds a native AArch64 cabal.exe with the GHC that test-on-host.ps1
# installed. cabal publishes no Windows AArch64 build, so the official x64
# cabal.exe drives this first build under Windows' x64 emulation; it only
# orchestrates, and every compile runs on the native AArch64 GHC. Then the
# native cabal builds itself again as a check that it works.
param(
    [Parameter(Mandatory)] [string] $Ghc,
    [Parameter(Mandatory)] [string] $Work,
    [Parameter(Mandatory)] [string] $CabalVersion,
    [Parameter(Mandatory)] [string] $CabalSha256,
    # The cabal-install to build, from Hackage, which can lag the binary releases.
    [Parameter(Mandatory)] [string] $BuildVersion,
    # A GHC development snapshot ships boot libraries newer than released
    # packages' bounds allow; relax only those.
    [string] $AllowNewer = 'base,ghc-prim,ghc-bignum,template-haskell,containers,time,deepseq,bytestring,text,directory,filepath,process,Win32,array,os-string,file-io,stm,mtl,transformers,parsec,exceptions,binary,semaphore-compat',
    # GHC's own copy of hsc2hs (utils/hsc2hs), which has Windows AArch64
    # support that the Hackage release (0.68.10) lacks.
    [Parameter(Mandatory)] [string] $Hsc2hsArchive,
    # Directory of <package>-<version>.patch files (windows-aarch64/patches):
    # each package is unpacked into the project and patched.
    [Parameter(Mandatory)] [string] $PatchesDir,
    [int] $Jobs = 2
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$failed = 0

function Check([string] $name, [scriptblock] $body) {
    $start = Get-Date
    try {
        $detail = & $body
        "PASS  $name  $detail  ($([math]::Round(((Get-Date) - $start).TotalMinutes, 1)) min)"
    } catch {
        "FAIL  $name  $($_.Exception.Message)"
        $script:failed++
    }
}

function Get-PEMachine([string] $path) {
    $b = [IO.File]::ReadAllBytes((Resolve-Path $path).ProviderPath)
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    '0x{0:X4}' -f [BitConverter]::ToUInt16($b, $pe + 4)
}

# Runs a native command with its output in $Work\logs\<log>.log; throws on a
# nonzero exit with the last lines of output.
function Invoke-Logged([string] $log, [string] $exe, [string[]] $argv) {
    $path = Join-Path $Work "logs\$log.log"
    # Collect first: piping no output to Set-Content creates no file.
    $out = @(& $exe @argv 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    Set-Content -Encoding utf8 -Path $path -Value $out
    if ($code -ne 0) {
        throw "exit $code (see $log.log):`n$((Get-Content $path | Select-Object -Last 15) -join "`n")"
    }
    Get-Content $path
}

New-Item -ItemType Directory -Force (Join-Path $Work 'logs'), (Join-Path $Work 'x64'), (Join-Path $Work 'bin') | Out-Null
# GHC-built tools (hsc2hs among them) write files in the console code page;
# over SSH that is a legacy one, so a package with non-ASCII source fails
# ("cannot encode character"). Use UTF-8, as a UTF-8 desktop setup would.
chcp.com 65001 | Out-Null
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# A private cabal directory (store, package index, config), so this leaves
# no trace in the user's own %APPDATA%\cabal.
$env:CABAL_DIR = Join-Path $Work 'cabal-dir'

"ghc: $Ghc ($(& $Ghc --numeric-version), $(Get-PEMachine $Ghc))"

$zip = Join-Path $Work "cabal-install-$CabalVersion-x86_64-mingw64.zip"
$x64Cabal = Join-Path $Work 'x64\cabal.exe'
Check "x64 cabal $CabalVersion (emulated)" {
    if (-not (Test-Path $zip)) {
        Invoke-WebRequest "https://downloads.haskell.org/~cabal/cabal-install-$CabalVersion/cabal-install-$CabalVersion-x86_64-mingw64.zip" -OutFile $zip
    }
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $CabalSha256) { throw "sha256 $hash, expected $CabalSha256" }
    Expand-Archive -Force $zip (Join-Path $Work 'x64')
    "$(& $x64Cabal --numeric-version), $(Get-PEMachine $x64Cabal)"
}

Check 'cabal update' { Invoke-Logged 'cabal-update' $x64Cabal @('update') | Select-Object -Last 1 }

# Packages with build-type Configure need a POSIX sh; Git for Windows has one.
$gitSh = Join-Path $env:ProgramFiles 'Git\usr\bin'
if (Test-Path (Join-Path $gitSh 'sh.exe')) { $env:PATH = "$env:PATH;$gitSh" }

# A project rather than `cabal install cabal-install-X`, so that workarounds
# can apply: hsc2hs from GHC's tree, hashable seeing ghc-bignum (which GHC
# master no longer exposes the way hashable expects), and avoiding Template
# Haskell until the RTS linker supports AArch64 PE.
$project = Join-Path $Work 'project'
Check "cabal get cabal-install-$BuildVersion" {
    if (Test-Path $project) { Remove-Item -Recurse -Force $project }
    New-Item -ItemType Directory -Force (Join-Path $project 'hsc2hs') | Out-Null
    Push-Location $project
    try { Invoke-Logged 'cabal-get' $x64Cabal @('get', "cabal-install-$BuildVersion") | Out-Null } finally { Pop-Location }
    tar -xzf $Hsc2hsArchive -C (Join-Path $project 'hsc2hs')
    if ($LASTEXITCODE -ne 0) { throw "tar failed: $LASTEXITCODE" }
    $patched = @()
    foreach ($patch in Get-ChildItem $PatchesDir -Filter '*.patch') {
        $pkg = $patch.BaseName
        Push-Location $project
        try { Invoke-Logged "cabal-get-$pkg" $x64Cabal @('get', $pkg) | Out-Null } finally { Pop-Location }
        Push-Location (Join-Path $project $pkg)
        try { Invoke-Logged "patch-$pkg" 'git' @('apply', '-p1', $patch.FullName) | Out-Null } finally { Pop-Location }
        $patched += "$pkg/"
    }
    @(
        "packages: cabal-install-$BuildVersion/ hsc2hs/ $($patched -join ' ')"
        "allow-newer: $AllowNewer"
        # tar 0.6 uses OsPath quasiquotes (0.6.4 also via directory-ospath-streaming);
        # quasiquotes need Template Haskell, which needs the RTS linker (milestone 3).
        'constraints: tar < 0.6'
        'package hashable'
        '  ghc-options: -package ghc-bignum'
    ) | Set-Content -Encoding utf8 (Join-Path $project 'cabal.project')
    "patched: $(if ($patched) { $patched -join ', ' } else { 'none' })"
}

function Build-Cabal([string] $log, [string] $cabal, [string] $installDir) {
    Push-Location $project
    try {
        Invoke-Logged $log $cabal @(
            'install', 'exe:cabal', "--with-compiler=$Ghc", "-j$Jobs",
            '--install-method=copy', '--overwrite-policy=always', "--installdir=$installDir"
        ) | Out-Null
    } finally { Pop-Location }
    $m = Get-PEMachine (Join-Path $installDir 'cabal.exe')
    if ($m -ne '0xAA64') { throw "cabal.exe is $m" }
    "cabal.exe $m"
}

$nativeCabal = Join-Path $Work 'bin\cabal.exe'
Check 'build cabal-install with x64 cabal and AArch64 GHC' { Build-Cabal 'build-cabal-1' $x64Cabal (Join-Path $Work 'bin') }
Check 'native cabal --version' { (Invoke-Logged 'native-version' $nativeCabal @('--version')) -join ' ' }
# Self-host: the native cabal builds cabal-install again into a second dir.
Check 'native cabal rebuilds cabal-install' { Build-Cabal 'build-cabal-2' $nativeCabal (Join-Path $Work 'bin-selfhost') }

if ($failed) { "$failed check(s) failed"; exit 1 }
"native cabal: $nativeCabal"
'all checks passed'
