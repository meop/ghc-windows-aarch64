# Runs on the Windows AArch64 host (copied there by test-on-host.sh). Unpacks
# the distribution and checks that GHC runs natively and can build working
# programs with its bundled toolchain. Prints PASS/FAIL per check and exits
# nonzero if any check failed.
param(
    [Parameter(Mandatory)] [string] $Tarball,
    [Parameter(Mandatory)] [string] $Dest
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$failed = 0

function Check([string] $name, [scriptblock] $body) {
    try {
        $detail = & $body
        "PASS  $name  $detail"
    } catch {
        "FAIL  $name  $($_.Exception.Message)"
        $script:failed++
    }
}

# Image machine from the PE header: 0xAA64 is ARM64, 0x8664 is x64.
function Get-PEMachine([string] $path) {
    # .NET resolves relative paths against the process directory, not PowerShell's location.
    $b = [IO.File]::ReadAllBytes((Resolve-Path $path).ProviderPath)
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    '0x{0:X4}' -f [BitConverter]::ToUInt16($b, $pe + 4)
}

function Invoke-Native([string] $exe, [string[]] $argv) {
    $out = & $exe @argv 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "exit $LASTEXITCODE`n$out" }
    $out.Trim()
}

"host: $([Runtime.InteropServices.RuntimeInformation]::OSArchitecture), Windows $([Environment]::OSVersion.Version)"
"process: $([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"

if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
New-Item -ItemType Directory -Force $Dest | Out-Null
tar -xzf $Tarball -C $Dest
if ($LASTEXITCODE -ne 0) { throw "tar failed: $LASTEXITCODE" }
$top = Get-ChildItem $Dest -Directory | Select-Object -First 1
$ghc = Join-Path $top.FullName 'bin\ghc.exe'
"unpacked: $($top.FullName)"

$work = Join-Path $Dest 'work'
New-Item -ItemType Directory -Force $work | Out-Null
Push-Location $work
try {
    Check 'ghc.exe is ARM64' { $m = Get-PEMachine $ghc; if ($m -ne '0xAA64') { throw $m }; $m }
    Check 'ghc --version' { Invoke-Native $ghc @('--version') }
    Check 'ghc --info target' {
        $info = Invoke-Native $ghc @('--info')
        $t = ($info -split "`n" | Select-String '"target platform string"').ToString().Trim()
        if ($t -notmatch 'aarch64-unknown-mingw32|aarch64-w64-mingw32') { throw $t }
        $t
    }
    # Built with --docs=none, so every package warns that its Haddock files are
    # missing; anything else in the output is a real problem.
    Check 'ghc-pkg check' {
        $out = Invoke-Native (Join-Path $top.FullName 'bin\ghc-pkg.exe') @('check')
        $other = $out -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^Warning: haddock-(interfaces|html): ' }
        if ($other) { throw ($other -join "`n") }
        'ok (only missing-Haddock warnings)'
    }

    Set-Content hello.hs 'main :: IO ()
main = putStrLn "hello from native Windows AArch64 GHC"'
    Check 'compile hello' { Invoke-Native $ghc @('-v0', 'hello.hs', '-o', 'hello.exe'); 'ok' }
    Check 'run hello' { Invoke-Native '.\hello.exe' @() }
    Check 'hello.exe is ARM64' { $m = Get-PEMachine '.\hello.exe'; if ($m -ne '0xAA64') { throw $m }; $m }

    Set-Content libs.hs '{-# LANGUAGE OverloadedStrings #-}
import qualified Data.ByteString.Char8 as B
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.IO as T
main :: IO ()
main = do
  T.putStrLn (T.toUpper "text ok")
  B.putStrLn (B.reverse "ko gnirtsetyb")
  print (M.toList (M.fromListWith (+) [(c, 1 :: Int) | c <- "mississippi"]))'
    Check 'compile text/bytestring/containers' { Invoke-Native $ghc @('-v0', '-O', 'libs.hs', '-o', 'libs.exe'); 'ok' }
    Check 'run text/bytestring/containers' { Invoke-Native '.\libs.exe' @() }

    Set-Content threaded.hs 'import Control.Concurrent
import Control.Monad
main :: IO ()
main = do
  n <- getNumCapabilities
  done <- newEmptyMVar
  forM_ [1 .. 8 :: Int] $ \i -> forkIO (putMVar done $! sum [1 .. i * 100000])
  rs <- replicateM 8 (takeMVar done)
  putStrLn ("capabilities " ++ show n ++ ", sum " ++ show (sum rs))'
    Check 'compile -threaded' { Invoke-Native $ghc @('-v0', '-threaded', '-rtsopts', 'threaded.hs', '-o', 'threaded.exe'); 'ok' }
    Check 'run +RTS -N' { Invoke-Native '.\threaded.exe' @('+RTS', '-N', '-RTS') }

    Set-Content ffi.hs 'foreign import ccall unsafe "math.h cbrt" c_cbrt :: Double -> Double
main :: IO ()
main = print (c_cbrt 27)'
    Check 'C FFI (cbrt)' { Invoke-Native $ghc @('-v0', 'ffi.hs', '-o', 'ffi.exe'); Invoke-Native '.\ffi.exe' @() }
    # Milestone 3: the interpreter and Template Haskell load object code with
    # the RTS linker.
    Check 'ghc -e (interpreter)' {
        $out = Invoke-Native $ghc @('-e', 'print (sum [1 .. 10 :: Int])')
        if ($out -ne '55') { throw "got: $out" }
        $out
    }

    Set-Content th.hs '{-# LANGUAGE TemplateHaskell #-}
import Language.Haskell.TH
main :: IO ()
main = print ($(litE (integerL (product [1 .. 20]))) :: Integer, $(stringE . show =<< runIO (pure (6 * 7 :: Int))))'
    Check 'Template Haskell splice' {
        Invoke-Native $ghc @('-v0', 'th.hs', '-o', 'th.exe') | Out-Null
        Invoke-Native '.\th.exe' @()
    }

    # A quasiquoter defined in one module and used in another, as OsPath's
    # [osp|...|] is.
    Set-Content QQ.hs 'module QQ (shout) where
import Data.Char (toUpper)
import Language.Haskell.TH
import Language.Haskell.TH.Quote
shout :: QuasiQuoter
shout = QuasiQuoter { quoteExp = stringE . map toUpper, quotePat = undefined, quoteType = undefined, quoteDec = undefined }'
    # Not qq.hs: Windows file names are case-insensitive, so it would replace QQ.hs.
    Set-Content useqq.hs '{-# LANGUAGE QuasiQuotes #-}
import QQ
main :: IO ()
main = putStrLn [shout|quasiquoted|]'
    Check 'quasiquoter' {
        Invoke-Native $ghc @('-v0', 'useqq.hs', '-o', 'qq.exe') | Out-Null
        $out = Invoke-Native '.\qq.exe' @()
        if ($out -ne 'QUASIQUOTED') { throw "got: $out" }
        $out
    }
} finally {
    Pop-Location
}

if ($failed) { "$failed check(s) failed"; exit 1 }
'all checks passed'
