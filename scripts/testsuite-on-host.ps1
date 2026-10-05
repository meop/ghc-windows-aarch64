# Runs on the Windows AArch64 host, normally from a scheduled task started by
# testsuite-on-host.sh, so a long run survives SSH disconnects. Runs GHC's
# testsuite (the make driver, testsuite/mk/test.mk) against the GHC that
# test-on-host.ps1 installed, using MSYS2's make and sh and the host's Python.
# Writes $Work\logs\testsuite.log, summary.txt, junit.xml and state.txt.
param(
    [Parameter(Mandatory)] [string] $Archive,   # git archive of the GHC tree
    [Parameter(Mandatory)] [string] $Work,
    [Parameter(Mandatory)] [string] $Msys2,     # e.g. C:\msys2\ghc
    [int] $Speed = 2,                            # 2 fast, 1 normal, 0 slow
    [int] $Threads = 4,
    [string] $Only = ''                          # space-separated test names
)
$ErrorActionPreference = 'Stop'
$logs = Join-Path $Work 'logs'
New-Item -ItemType Directory -Force $logs | Out-Null
$state = Join-Path $logs 'state.txt'
function State([string] $s) { "$((Get-Date).ToUniversalTime().ToString('u')) $s" | Add-Content $state; $s }

try {
    State 'started'
    $root = Join-Path $env:LOCALAPPDATA 'ghc-windows-aarch64-test'
    $ghc = (Get-ChildItem (Join-Path $root 'install') -Directory | Select-Object -First 1).FullName + '\bin\ghc.exe'
    $src = Join-Path $Work 'src'
    if (Test-Path $src) { cmd /c rd /s /q $src }   # Remove-Item hangs on this tree
    New-Item -ItemType Directory -Force $src | Out-Null
    tar -xzf $Archive -C $src
    if ($LASTEXITCODE -ne 0) { throw "tar failed: $LASTEXITCODE" }
    State "unpacked; ghc $(& $ghc --numeric-version) at $ghc"

    # MSYS2 paths for make: C:\x\y -> /c/x/y
    function MsysPath([string] $p) { '/' + $p.Substring(0, 1).ToLower() + ($p.Substring(2) -replace '\\', '/') }
    $python = (Get-Command python).Source
    # inherit: keep the Windows PATH in MSYS2's login shell (the driver runs git).
    $env:MSYSTEM = 'MSYS'; $env:CHERE_INVOKING = '1'; $env:MSYS2_PATH_TYPE = 'inherit'
    $env:PATH = "$(Join-Path $Msys2 'usr\bin');$env:PATH"
    $only = if ($Only) { "TEST='$Only'" } else { '' }
    $cmd = "make -C testsuite/tests test TEST_HC='$(MsysPath $ghc)' PYTHON='$(MsysPath $python)' " +
           "THREADS=$Threads SPEED=$Speed SUMMARY_FILE='$(MsysPath (Join-Path $logs 'summary.txt'))' " +
           "JUNIT_FILE='$(MsysPath (Join-Path $logs 'junit.xml'))' $only"
    State "running: $cmd"
    Push-Location $src
    try {
        & (Join-Path $Msys2 'usr\bin\bash.exe') -lc $cmd *> (Join-Path $logs 'testsuite.log')
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    State "finished: make exit $code"
} catch {
    State "error: $($_.Exception.Message)"
}
