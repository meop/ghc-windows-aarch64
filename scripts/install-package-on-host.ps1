# Runs on the Windows AArch64 host (copied there by install-package-on-host.sh).
# Builds a Hackage package's executables with the native cabal and GHC from
# build-cabal-on-host.ps1, reusing that project's workarounds: GHC's hsc2hs,
# the patched packages, and relaxed bounds for GHC's boot libraries.
param(
    [Parameter(Mandatory)] [string] $Package,   # e.g. ShellCheck-0.11.0
    [string[]] $VersionArgs = @('--version'),
    [switch] $Test,                             # also build and run its test suites
    [string] $AllowNewer = 'base,ghc-prim,ghc-bignum,template-haskell,containers,time,deepseq,bytestring,text,directory,filepath,process,Win32,array,os-string,file-io,stm,mtl,transformers,parsec,exceptions,binary,semaphore-compat',
    [int] $Jobs = 2
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
chcp.com 65001 | Out-Null   # see build-cabal-on-host.ps1
$failed = 0

$root = Join-Path $env:LOCALAPPDATA 'ghc-windows-aarch64-test'
$work = Join-Path $root 'cabal'
$env:CABAL_DIR = Join-Path $work 'cabal-dir'
$gitSh = Join-Path $env:ProgramFiles 'Git\usr\bin'
if (Test-Path $gitSh) { $env:PATH = "$env:PATH;$gitSh" }
$ghc = (Get-ChildItem (Join-Path $root 'install') -Directory | Select-Object -First 1).FullName + '\bin\ghc.exe'
$cabal = Join-Path $work 'bin\cabal.exe'
$project = Join-Path $work "pkg-$Package"
$bin = Join-Path $project 'bin'
$logs = Join-Path $project 'logs'

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

function Invoke-Logged([string] $log, [string] $exe, [string[]] $argv) {
    $path = Join-Path $logs "$log.log"
    $out = @(& $exe @argv 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    Set-Content -Encoding utf8 -Path $path -Value $out
    if ($code -ne 0) {
        throw "exit $code (see $log.log):`n$(($out | Select-Object -Last 25) -join "`n")"
    }
    $out
}

if (-not (Test-Path $cabal)) { throw "no native cabal at $cabal; run build-cabal-on-host.sh first" }
if (Test-Path $project) { Remove-Item -Recurse -Force $project }
New-Item -ItemType Directory -Force $project, $bin, $logs | Out-Null
"ghc: $ghc"; "cabal: $cabal ($(Get-PEMachine $cabal))"

Check "cabal get $Package" {
    Push-Location $project
    try { Invoke-Logged 'cabal-get' $cabal @('get', $Package) | Out-Null } finally { Pop-Location }
    # GHC's hsc2hs from the cabal-install project, and every stored patch
    # (windows-aarch64/patches, copied here by install-package-on-host.sh)
    # applied to a fresh copy of its package.
    $candidates = @()
    foreach ($patch in Get-ChildItem (Join-Path $root 'patches') -Filter '*.patch') {
        $pkg = $patch.BaseName
        Push-Location $project
        try { Invoke-Logged "cabal-get-$pkg" $cabal @('get', $pkg) | Out-Null } finally { Pop-Location }
        Push-Location (Join-Path $project $pkg)
        try { Invoke-Logged "patch-$pkg" 'git' @('apply', '-p1', $patch.FullName) | Out-Null } finally { Pop-Location }
        $candidates += $pkg
    }
    function Write-Project([string[]] $patchedDirs) {
        @(
            "packages: $Package/ ../project/hsc2hs/ $(($patchedDirs | ForEach-Object { "$_/" }) -join ' ')"
            "allow-newer: $AllowNewer"
            'package hashable'
            '  ghc-options: -package ghc-bignum'
            # GHC master implicitly imports GHC.Essentials (from base) into every
            # module; this shim package does not depend on base.
            'package data-default-class'
            '  ghc-options: -package base'
        ) | Set-Content -Encoding utf8 (Join-Path $project 'cabal.project')
    }
    # Plan without the patched copies first, then add only those the solver
    # picks: a patched copy is a local package and would force its version.
    Write-Project @()
    Push-Location $project
    try {
        Invoke-Logged 'plan' $cabal @('build', ($Package -replace '-[0-9.]+$', ''), '--dry-run', "--with-compiler=$ghc") | Out-Null
        $plan = Get-Content (Join-Path $project 'dist-newstyle\cache\plan.json') -Raw | ConvertFrom-Json
    } finally { Pop-Location }
    $inPlan = $plan.'install-plan' | ForEach-Object { "$($_.'pkg-name')-$($_.'pkg-version')" } | Sort-Object -Unique
    $patched = @($candidates | Where-Object { $_ -in $inPlan })
    Write-Project $patched
    "patched (in the plan): $(if ($patched) { $patched -join ', ' } else { 'none' }); not needed: $(@($candidates | Where-Object { $_ -notin $patched }) -join ', ')"
}

Check "build $Package" {
    Push-Location $project
    try {
        Invoke-Logged 'build' $cabal @(
            'install', ($Package -replace '-[0-9.]+$', ''), "--with-compiler=$ghc", "-j$Jobs",
            '--install-method=copy', '--overwrite-policy=always', "--installdir=$bin"
        ) | Out-Null
    } finally { Pop-Location }
    $exes = Get-ChildItem $bin -Filter '*.exe'
    if (-not $exes) { throw 'no executables installed' }
    ($exes | ForEach-Object { "$($_.Name) $(Get-PEMachine $_.FullName)" }) -join ', '
}

foreach ($exe in Get-ChildItem $bin -Filter '*.exe' -ErrorAction SilentlyContinue) {
    Check "$($exe.Name) $($VersionArgs -join ' ')" {
        (Invoke-Logged "run-$($exe.BaseName)" $exe.FullName $VersionArgs | Select-Object -First 3) -join ' / '
    }
}

if ($Test) {
    Check "test $Package" {
        Push-Location $project
        try {
            $out = Invoke-Logged 'test' $cabal @(
                'test', ($Package -replace '-[0-9.]+$', ''), '--enable-tests', "--with-compiler=$ghc",
                "-j$Jobs", '--test-show-details=direct'
            )
        } finally { Pop-Location }
        ($out | Select-String -Pattern 'Test suite .* (passed|failed)|examples?, \d+ failures?|tests? passed|\d+ out of \d+ tests failed' |
            ForEach-Object { "$_".Trim() }) -join ' / '
    }
}

if ($failed) { "$failed check(s) failed"; exit 1 }
"executables: $bin"
'all checks passed'
