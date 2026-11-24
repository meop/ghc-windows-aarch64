# Runs on the Windows AArch64 host, from the caller's shell (in the foreground,
# or as a background command the caller tracks). Runs GHC's testsuite (the make driver,
# testsuite/mk/test.mk) against an installed GHC, using MSYS2's make and sh and
# the host's Python.
#
# Writes $Work\logs\testsuite.log, summary.txt, junit.xml, perf-metrics.tsv and state.txt.
# The last line of state.txt is always "finished: <reason>" (written in a
# finally block), unless the process itself is killed.
#
# Protections:
#   - TMP/TEMP/TMPDIR point at a per-run directory, $Work\tmp-<utc-stamp>,
#     removed in the finally block. MSYS2's /etc/profile resets TMP and TEMP to
#     /tmp (C:\msys64\tmp) in every login shell, so they are exported again
#     inside the bash command line; that is what keeps GHC's leaked ghc*_tmp_*
#     directories out of C:\msys64\tmp.
#   - Free space on the drive of $Work: refuse to start below -MinFreeGB (15),
#     append a "free-space:" line to state.txt every -LogEveryMinutes (10), and
#     abort the run (killing its process tree) below -AbortFreeGB (5).
#   - -ExpectGhc / -ExpectTree: abort unless `ghc --info`'s "Project Git commit
#     id" and the test tree's COMMIT file start with the expected hash.
#
# Test tree layout in the archive: testsuite-tree/testsuite/... plus
# testsuite-tree/COMMIT (what T04 produces), or the older layout with
# testsuite/ at the archive root (no COMMIT; -ExpectTree then fails).
#
# Test tools: the testsuite calls check-ppr, check-exact, dump-decls, count-deps and
# changelog-d from <tree>\inplace\bin (testsuite/mk/boilerplate.mk), which a bindist run
# does not have. -Tools <zip> (e.g. testsuite-tools-<hash>.zip: the five .exe files, built
# natively with the compiler under test) is extracted there after the tree is in place, also
# with -NoExtract (an existing inplace\bin is overwritten file by file, nothing else is removed).
# make also gets CHANGELOG_D=<inplace\bin\changelog-d.exe>, because tests/linters/Makefile does
# not include boilerplate.mk and hadrian is what normally passes it.
#
# Coverage flags (T24). testsuite/mk/test.mk, the make driver, never passes config.have_ncg
# (Hadrian does, RunTest.hs) and takes config.debug_rts from the compiler's list of RTS
# ways ("RTS ways" in `ghc --info`, which names every way the install ships, debug among
# them) instead of the way the compiler itself runs with. Left alone, have_ncg() is False
# on a native-code-generator build, so llvm_build() is True: every th ext-interp case becomes
# fragile_for(16087), `optasm` is dropped from numeric/should_run, and the NCG-only tests are
# skipped; and debug_rts() is True, which runs T23142 and T25374 (they need `ghc +RTS -Di`)
# and skips InternalCounters. So the runner does what Hadrian does, from this compiler, and
# passes both through EXTRA_RUNTEST_OPTS:
#   config.have_ncg   = `ghc --info` "Have native code generator" is YES
#   config.debug_rts  = the "RTS way" of `ghc +RTS --info` (the way ghc.exe itself runs) has "debug" in it
# Both values are written to state.txt at the start of a run.
#
# Environment of the make child: NoDefaultCurrentDirectoryInExePath is removed (an agent harness sets it, a user's shell
# does not; with it cmd.exe does not search the current directory, so a test that runs a bare program name through
# System.Process.shell fails), and TEST_HC is exported next to the make variable of the same name (Hadrian puts it in the
# test environment; T18382 reads it). Both are recorded in `env:` lines of state.txt.
#
# Perf tests: runtests.py skips every performance test (forceSkipPerfTests) when the tree is
# not a git checkout and there is no --metrics-file. The runner passes METRICS_FILE=
# <Work>\logs\perf-metrics.tsv, so they run; the file collects their metrics (test, way, metric,
# value) as the run appends them at its end. The metrics file alone is not enough: report_stats()
# in testlib.py returns before it records anything unless `git rev-parse HEAD` works in the
# tests directory (a perf test that runs outside a git checkout passes and stores nothing). So
# the runner gives an extracted tree a throwaway git repository with one empty commit (the tree
# has no hie.yaml in `git ls-files`, so req_ls_files tests stay skipped). With no baseline in
# git notes a new metric trivially passes: perf tests here measure and record, not compare.
#
# python3 and python for the test shell (T27). Some tests run a bare `python3` or `python` from a pre_cmd/cmd
# (perf/compiler/all.T: T14766 runs `python3 genT14766.py`), and the make driver's sh looks them up on PATH. The
# runner passes the interpreter it uses as PYTHON (-Python, by default ~\.local\bin\python.exe, a uv shim), but that
# directory is on the PATH only of the user's own pwsh profile, not of an agent harness's shell, and msys has no
# python: sh said `python3: command not found` (exit 127). So the runner creates $Work\pyshim with python3.exe and
# python.exe, copies of the -Python file (a uv shim is a small launcher that finds the real interpreter by the path
# stored in it, so a copy runs the same interpreter), and puts that directory first on the PATH of the make child.
# That is narrower than prepending the directory of -Python, which would also expose everything else in it (here
# claude.exe, gh.exe, glab.exe) to every test, and it works for sh and for native CreateProcess alike. Before make
# starts, a login shell with the same environment (shell-check.sh in the logs dir) must resolve python3 and python
# to the shim and run python3, or the run is refused (exit 13). The PATH the make child gets is written to
# state.txt in the Windows form and in the msys form (`env: PATH ...` lines), with the shell's python3 lookup.
#
# Stability (T34).
#   - Per-process memory cap. The make child is started suspended, put in a Windows Job object whose limit is
#     JOB_OBJECT_LIMIT_PROCESS_MEMORY (each process may commit at most -ProcessMemoryMB; 0 = no limit, the job then
#     only does the accounting), and resumed, so every process the run starts (make, python, timeout, ghc, the test
#     programs) is in it. It is a per-process limit, not a whole-job one: a test that runs away fails alone, with
#     the allocation failing inside it (a GHC program reports `getMBlocks: VirtualAlloc MEM_COMMIT failed`, as it did
#     when concprog001 exhausted the host in T29), while the other tests still get memory. Jobs nest on Windows 8 and
#     later, so testsuite/timeout (timeout.exe puts its child in a job of its own, with no breakaway) keeps working
#     and the cap still applies to the process inside it. A process that hits the cap is logged to state.txt
#     ("memory-cap:" line: time, pid, name, private commit) from the job's completion port, and the largest commit of
#     any process in the run (the job's PeakProcessMemoryUsed) is logged with every free-space line and at the end.
#     The job does not kill its processes when the runner exits, and the cap never applies to the runner itself.
#     Default 4096 MB (T34, from measurements on acrylic): the largest commit of any process in 48 of the
#     heaviest perf/allocation tests was 1.37 GB, and concprog001(threaded2) (fragile, "can diverge") commits 1.7 to
#     2.5 GB when it passes, so the cap has to stay above 2.5 GB; one diverging run reached the 13.6 GB that took
#     down a T29 run, and now stops at 4 GB. Three tests run at once, so three runaways at most hold 12 GB of the
#     host's 20 GB commit limit. A test that really needs more than the cap needs -ProcessMemoryMB raised.
#   - Fresh metrics file. If logs\perf-metrics.tsv exists at the start (the driver appends to it) it is moved to
#     perf-metrics-<UTC last-write stamp>.tsv in the same directory, and the move is logged (a file with no rows,
#     what a run without perf tests leaves, is just removed).
#   - Per-test timestamps. The driver prints a start line `=====> <test>(<way>) <n> of <N> [...]` for every test case
#     at -v3 (make's VERBOSE=3; at the default it prints one line in a hundred) and `*** unexpected failure for ...`
#     style lines when a test ends badly. It does not time-stamp them, and its stdout is block-buffered when
#     redirected, so the runner passes `-e sys.stdout.reconfigure(line_buffering=True)` (a driver option, through
#     EXTRA_RUNTEST_OPTS; only the driver's own output is line-buffered, not the tests' python children) and a
#     background thread of the job helper polls testsuite.log every 250 ms and appends `<UTC time>\t<line>` for
#     those marker lines (=====>, ***, Wrong exit code, Timeout happened) to logs\timeline.tsv. The log itself is
#     unchanged (it is only longer at -v3: every command line is echoed). Start time = the stamp of the `=====>` line
#     (+- 0.25 s); end time = start + the junit time, or the stamp of the `***` line for a failure. -NoTimeline
#     turns it off (default verbosity, no thread).
#   - The make command now lives in logs\run-make.sh (run with bash -l), not in a -lc string, so that the double
#     quotes of the -e option need no extra quoting layer.
#
# Sweep of finished iserv files (T40; the cause is in runs\2026-11-16-T33-tmp\NOTES.md). A test that starts GHC's external
# interpreter (th ext-interp, ghci-ext: a splice or a ghci evaluation) leaves ghc<pid>_tmp_<n>\ghc_tmp_1.iserv, a 27.5 MiB
# executable, in the run's temp dir: GHC deletes its temp files before it stops the interpreter, and Windows refuses to
# delete a running .exe. A full run piles up ~14 GiB that way until the temp dir is removed at the end. So every pass
# of the wait loop below (about every 15 s) the runner sweeps the run's temp dir:
#   - it tries to delete every ghc<pid>_tmp_*\*.iserv, and ignores the error for a file that is still in use (a running
#     interpreter keeps its file locked, so such a file survives);
#   - it only looks at a directory whose owner, the ghc process named by <pid>, no longer exists. Being unlocked is not
#     enough: GHC links the iserv eagerly (initInterpreter) but starts it lazily at the first splice, so a live ghc
#     can have an unlocked .iserv it has not started yet, and deleting that would break the test;
#   - it removes a ghc<pid>_tmp_* directory (non-recursively, so only an empty one goes) that is empty, whose owner is
#     gone and that was created more than 3 minutes ago;
#   - it deletes nothing else.
# Each sweep that removes something writes one `iserv-sweep:` line (files, MiB freed, run total so far) to state.txt, and the
# end-of-run lines carry the run's total. -NoIservSweep turns the sweep off (the temp dir then grows as before and is
# removed at the end). A sweep that fails is logged once and does not stop the run.
#
# Exit code: make's exit code if it ran; otherwise 10 refused (low disk at
# start), 11 aborted (low disk during the run), 12 commit mismatch, 13 other
# error.
param(
    [string] $Archive = '',                      # tar.gz of the test tree; not needed with -NoExtract
    [Parameter(Mandatory)] [string] $Work,
    [Parameter(Mandatory)] [string] $Msys2,      # e.g. C:\msys64
    [int] $Speed = 2,                            # 2 fast, 1 normal, 0 slow
    [int] $Threads = 4,
    [string] $Only = '',                         # space-separated test names
    [string] $Python = (Join-Path $HOME '.local\bin\python.exe'),
    [switch] $NoExtract,                         # reuse an already-extracted $Work\src
    [string] $Tools = '',                        # zip of test tool exes, extracted into <tree>\inplace\bin
    [string] $ExpectTree = '',                   # commit the test tree must be (prefix match)
    [string] $ExpectGhc = '',                    # commit the compiler must be (prefix match)
    [string] $Ghc = '',                          # ghc.exe to test; default: the only install\ghc-* dir
    [double] $MinFreeGB = 15,
    [double] $AbortFreeGB = 5,
    [int] $LogEveryMinutes = 10,
    [int] $ProcessMemoryMB = 4096,               # per-process commit cap (job object); 0 = no cap
    [switch] $NoTimeline,                        # no -v3, no timeline.tsv
    [switch] $NoIservSweep                       # do not delete finished ghc*_tmp_*\*.iserv files during the run
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$tarExe = 'C:\Windows\System32\tar.exe'
# Always the full path to cmd.exe. C:\msys64\usr\bin holds a file named `cmd` (no extension); with that directory
# first on PATH a bare `cmd` resolves to it and Windows shows "Select an app to open 'cmd'". (Earlier versions of
# this script put it first on PATH; now only the MSYS2 login shell does, for itself.)
$cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
$logs = Join-Path $Work 'logs'
New-Item -ItemType Directory -Force $logs | Out-Null
$state = Join-Path $logs 'state.txt'
function State([string] $s) {
    $line = "$((Get-Date).ToUniversalTime().ToString('u')) $s"
    $line | Add-Content -Encoding utf8 $state
    Write-Host $line
}

$drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot((Resolve-Path $Work).ProviderPath))
function FreeGB { [math]::Round($drive.AvailableFreeSpace / 1GB, 2) }
# MSYS2 paths for make: C:\x\y -> /c/x/y
function MsysPath([string] $p) { '/' + $p.Substring(0, 1).ToLower() + ($p.Substring(2) -replace '\\', '/') }
function MsysGhcTmpCount {
    @(Get-ChildItem (Join-Path $Msys2 'tmp') -Directory -Filter 'ghc*_tmp_*' -ErrorAction SilentlyContinue).Count
}
function Same-Commit([string] $a, [string] $b) {
    $a = $a.Trim().ToLower(); $b = $b.Trim().ToLower()
    $a.Length -ge 7 -and $b.Length -ge 7 -and ($a.StartsWith($b) -or $b.StartsWith($a))
}
# The newest *.run directory under the tests is the test most recently started.
function LatestTest([string] $tests) {
    try {
        $d = Get-ChildItem $tests -Recurse -Directory -Filter '*.run' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($d) { $d.Name -replace '\.run$', '' } else { '-' }
    } catch { '-' }
}
function KillTree([int] $id) { & "$env:SystemRoot\System32\taskkill.exe" /T /F /PID $id *> $null }
# Anything left that runs from the work dir or was started with it (tests, ghc, iserv, python driver).
function SweepStragglers {
    Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $PID -and ($_.ExecutablePath -like "$Work\*" -or
            ($_.CommandLine -and $_.CommandLine -like "*$Work\src*"))
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        State "swept straggler $($_.ProcessId) $($_.Name)" | Out-Null
    }
}

# One sweep of the run's temp dir for finished iserv files (see the header). Updates the totals, logs one line per
# sweep that removed something. Never throws.
$script:sweepFiles = 0; $script:sweepBytes = [long] 0; $script:sweepDirs = 0; $script:sweepErrorLogged = $false
function IservSweep([string] $tmp) {
    try {
        $live = New-Object 'System.Collections.Generic.HashSet[int]'
        foreach ($p in [Diagnostics.Process]::GetProcesses()) { [void] $live.Add($p.Id); $p.Dispose() }
        $files = 0; $bytes = [long] 0; $dirs = 0
        $young = (Get-Date).ToUniversalTime().AddMinutes(-3)
        foreach ($d in @(Get-ChildItem -LiteralPath $tmp -Directory -Filter 'ghc*_tmp_*' -Force -ErrorAction SilentlyContinue)) {
            $owner = 0
            if ($d.Name -notmatch '^ghc(\d+)_tmp_' -or -not [int]::TryParse($Matches[1], [ref] $owner)) { continue }
            if ($live.Contains($owner)) { continue }   # its ghc may still start the interpreter
            foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -File -Filter '*.iserv' -Force -ErrorAction SilentlyContinue)) {
                if ($f.Extension -ne '.iserv') { continue }
                $len = $f.Length
                try { [IO.File]::Delete($f.FullName) } catch { }   # in use (a running interpreter): leave it
                if (-not [IO.File]::Exists($f.FullName)) { $files++; $bytes += $len }
            }
            if ($d.CreationTimeUtc -lt $young -and @(Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                try { [IO.Directory]::Delete($d.FullName, $false); $dirs++ } catch { }
            }
        }
        $script:sweepFiles += $files; $script:sweepBytes += $bytes; $script:sweepDirs += $dirs
        if ($files -gt 0) {
            State "iserv-sweep: removed $files .iserv file(s), $([math]::Round($bytes / 1MB, 1)) MiB freed ($dirs empty ghc*_tmp_* dir(s) removed); run total so far $($script:sweepFiles) files, $([math]::Round($script:sweepBytes / 1MB, 1)) MiB" | Out-Null
        }
    } catch {
        if (-not $script:sweepErrorLogged) { $script:sweepErrorLogged = $true; State "iserv-sweep: error (logged once, the run goes on): $($_.Exception.Message)" | Out-Null }
    }
}

# The make child's job object (per-process commit cap, peak accounting, cap events) and the timeline tail thread; see the header.
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public sealed class RunnerJob : IDisposable
{
    const uint JOB_OBJECT_LIMIT_PROCESS_MEMORY = 0x100;
    const int JobObjectAssociateCompletionPortInformation = 7;
    const int JobObjectExtendedLimitInformation = 9;
    const uint JOB_OBJECT_MSG_PROCESS_MEMORY_LIMIT = 9;
    const uint CREATE_SUSPENDED = 0x4, CREATE_UNICODE_ENVIRONMENT = 0x400, CREATE_NO_WINDOW = 0x08000000;
    static readonly UIntPtr PortKey = new UIntPtr(1), StopKey = new UIntPtr(2);

    [StructLayout(LayoutKind.Sequential)]
    struct BASIC_LIMIT { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS { public ulong a, b, c, d, e, f; }
    [StructLayout(LayoutKind.Sequential)]
    struct EXT_LIMIT { public BASIC_LIMIT Basic; public IO_COUNTERS Io; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
    [StructLayout(LayoutKind.Sequential)]
    struct ASSOC_PORT { public UIntPtr CompletionKey; public IntPtr CompletionPort; }
    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFO { public uint cb; public IntPtr lpReserved, lpDesktop, lpTitle; public uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags; public ushort wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public uint dwProcessId, dwThreadId; }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr attrs, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int cls, ref EXT_LIMIT info, int len);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int cls, ref ASSOC_PORT info, int len);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(IntPtr job, int cls, out EXT_LIMIT info, int len, IntPtr ret);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proc);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateIoCompletionPort(IntPtr file, IntPtr existing, UIntPtr key, uint threads);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetQueuedCompletionStatus(IntPtr port, out uint bytes, out UIntPtr key, out IntPtr overlapped, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool PostQueuedCompletionStatus(IntPtr port, uint bytes, UIntPtr key, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr proc, out uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateProcess(IntPtr proc, uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern uint GetConsoleCP();

    readonly IntPtr job, port;
    readonly long limitBytes;
    readonly string logPath, timelinePath;
    IntPtr proc = IntPtr.Zero;
    Thread portThread, tailThread;
    readonly ManualResetEvent stopTail = new ManualResetEvent(false);
    readonly ConcurrentQueue<string> events = new ConcurrentQueue<string>();
    readonly HashSet<uint> seen = new HashSet<uint>();
    long timelineLines;
    bool disposed;

    public int Pid { get; private set; }
    public long LimitBytes { get { return limitBytes; } }
    public long TimelineLines { get { return Interlocked.Read(ref timelineLines); } }

    // limitMB 0: no per-process limit (the job is then only used for accounting). timelinePath null: no tail thread.
    public RunnerJob(long limitMB, string logPath, string timelinePath)
    {
        limitBytes = limitMB * 1024L * 1024L;
        this.logPath = logPath; this.timelinePath = string.IsNullOrEmpty(timelinePath) ? null : timelinePath;
        job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new InvalidOperationException("CreateJobObject failed: " + Marshal.GetLastWin32Error());
        EXT_LIMIT ext = new EXT_LIMIT();
        if (limitBytes > 0)
        {
            ext.Basic.LimitFlags = JOB_OBJECT_LIMIT_PROCESS_MEMORY;
            ext.ProcessMemoryLimit = new UIntPtr((ulong)limitBytes);
        }
        if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref ext, Marshal.SizeOf(typeof(EXT_LIMIT))))
            throw new InvalidOperationException("SetInformationJobObject(limits) failed: " + Marshal.GetLastWin32Error());
        port = CreateIoCompletionPort(new IntPtr(-1), IntPtr.Zero, UIntPtr.Zero, 1);
        if (port == IntPtr.Zero) throw new InvalidOperationException("CreateIoCompletionPort failed: " + Marshal.GetLastWin32Error());
        ASSOC_PORT ap = new ASSOC_PORT(); ap.CompletionKey = PortKey; ap.CompletionPort = port;
        if (!SetInformationJobObject(job, JobObjectAssociateCompletionPortInformation, ref ap, Marshal.SizeOf(typeof(ASSOC_PORT))))
            throw new InvalidOperationException("SetInformationJobObject(port) failed: " + Marshal.GetLastWin32Error());
        portThread = new Thread(PortLoop); portThread.IsBackground = true; portThread.Start();
    }

    // Starts the command line suspended, puts the process in the job, resumes it. The child inherits the caller's
    // console and standard handles and environment, as Start-Process -NoNewWindow does.
    public int Start(string commandLine, string workDir)
    {
        STARTUPINFO si = new STARTUPINFO(); si.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
        PROCESS_INFORMATION pi;
        uint flags = CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT;
        if (GetConsoleCP() == 0) flags |= CREATE_NO_WINDOW;   // the caller has no console: do not pop one up
        if (!CreateProcessW(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, true, flags, IntPtr.Zero, workDir, ref si, out pi))
            throw new InvalidOperationException("CreateProcess failed: " + Marshal.GetLastWin32Error());
        proc = pi.hProcess; Pid = (int)pi.dwProcessId;
        if (!AssignProcessToJobObject(job, proc))
        {
            int err = Marshal.GetLastWin32Error();
            TerminateProcess(proc, 1); CloseHandle(pi.hThread);
            throw new InvalidOperationException("AssignProcessToJobObject failed: " + err);
        }
        if (timelinePath != null) { tailThread = new Thread(TailLoop); tailThread.IsBackground = true; tailThread.Start(); }
        ResumeThread(pi.hThread);
        CloseHandle(pi.hThread);
        return Pid;
    }

    public bool WaitForExit(int ms) { return WaitForSingleObject(proc, (uint)ms) == 0; }
    public int ExitCode { get { uint c; if (!GetExitCodeProcess(proc, out c)) return -1; return unchecked((int)c); } }
    public void Kill() { TerminateJobObject(job, 1); }

    public long PeakProcessBytes
    {
        get { EXT_LIMIT e; if (!QueryInformationJobObject(job, JobObjectExtendedLimitInformation, out e, Marshal.SizeOf(typeof(EXT_LIMIT)), IntPtr.Zero)) return -1; return (long)(ulong)e.PeakProcessMemoryUsed; }
    }

    public string[] DrainEvents() { List<string> l = new List<string>(); string s; while (events.TryDequeue(out s)) l.Add(s); return l.ToArray(); }

    static string Now() { return DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'"); }

    void PortLoop()
    {
        while (true)
        {
            uint msg; UIntPtr key; IntPtr ov;
            if (!GetQueuedCompletionStatus(port, out msg, out key, out ov, 0xFFFFFFFF)) { if (ov == IntPtr.Zero) return; continue; }
            if (key == StopKey) return;
            if (msg != JOB_OBJECT_MSG_PROCESS_MEMORY_LIMIT) continue;
            uint pid = (uint)ov.ToInt64();
            lock (seen) { if (!seen.Add(pid)) continue; if (seen.Count > 500) continue; }
            string what = "";
            try
            {
                using (Process p = Process.GetProcessById((int)pid))
                    what = " " + p.ProcessName + ", private commit now " + (p.PrivateMemorySize64 >> 20) + " MB";
            }
            catch (Exception) { what = " (already gone)"; }
            events.Enqueue(Now() + " process hit the per-process commit limit of " + (limitBytes >> 20) + " MB: pid " + pid + what);
        }
    }

    static readonly string[] Markers = { "=====> ", "*** ", "Wrong exit code", "Timeout happened" };

    void TailLoop()
    {
        long off = 0; string pending = "";
        using (StreamWriter w = new StreamWriter(new FileStream(timelinePath, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete), new UTF8Encoding(false)))
        {
            bool last = false;
            while (true)
            {
                bool stop = stopTail.WaitOne(250);
                try
                {
                    using (FileStream fs = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                    {
                        if (fs.Length < off) { off = 0; pending = ""; }
                        fs.Seek(off, SeekOrigin.Begin);
                        byte[] buf = new byte[1 << 20]; int n; string now = Now();
                        while ((n = fs.Read(buf, 0, buf.Length)) > 0)
                        {
                            off += n;
                            pending += Encoding.Latin1.GetString(buf, 0, n);
                            int nl;
                            while ((nl = pending.IndexOf('\n')) >= 0)
                            {
                                string line = pending.Substring(0, nl).TrimEnd('\r'); pending = pending.Substring(nl + 1);
                                foreach (string m in Markers)
                                    if (line.StartsWith(m, StringComparison.Ordinal)) { w.Write(now); w.Write('\t'); w.WriteLine(line); Interlocked.Increment(ref timelineLines); break; }
                            }
                        }
                    }
                    w.Flush();
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
                if (last) return;
                last = stop;   // one more pass after the stop request, to pick up the end of the log
            }
        }
    }

    public void Dispose()
    {
        if (disposed) return; disposed = true;
        stopTail.Set();
        if (tailThread != null) tailThread.Join(10000);
        PostQueuedCompletionStatus(port, 0, StopKey, IntPtr.Zero);
        portThread.Join(5000);
        if (proc != IntPtr.Zero) CloseHandle(proc);
        CloseHandle(port);
        CloseHandle(job);
    }
}
'@

$reason = ''        # set when the run ends for a reason other than an unexpected exception
$exitCode = 13
$runTmp = ''
$aborted = $false
$job = $null
try {
    State "started: Work=$Work Msys2=$Msys2 Speed=$Speed Threads=$Threads Only='$Only' NoExtract=$NoExtract Tools='$Tools' ExpectTree='$ExpectTree' ExpectGhc='$ExpectGhc' ProcessMemoryMB=$ProcessMemoryMB NoTimeline=$NoTimeline NoIservSweep=$NoIservSweep"

    # NoDefaultCurrentDirectoryInExePath=1 (an agent harness sets it in its own process environment; a user's shell does not)
    # makes cmd.exe skip the current directory when it looks for a program, which breaks tests that run a bare program name
    # through System.Process.shell (hWaitForInput-accurate-stdin). Remove it for this run: the runner is a child process,
    # so the caller's environment keeps it.
    $noDefCwd = [Environment]::GetEnvironmentVariable('NoDefaultCurrentDirectoryInExePath')
    Remove-Item Env:NoDefaultCurrentDirectoryInExePath -ErrorAction SilentlyContinue
    State "env: SystemRoot=$env:SystemRoot COMSPEC=$env:COMSPEC PATHEXT=$env:PATHEXT NoDefaultCurrentDirectoryInExePath=$(if ($null -eq $noDefCwd) { '(unset)' } else { "'$noDefCwd' in the caller, removed for the run" }) (inherited; the runner only sets TMP/TEMP/TMPDIR, removes NoDefaultCurrentDirectoryInExePath, and adds MSYSTEM, CHERE_INVOKING, MSYS2_PATH_TYPE and TEST_HC; PATH only gets the pyshim dir in front, see the later PATH lines)"

    # --- free space at start
    $free = FreeGB
    State "free-space: $free GB on $($drive.Name) at start (refuse below $MinFreeGB GB, abort below $AbortFreeGB GB)" | Out-Null
    if ($free -lt $MinFreeGB) { $reason = "refused: $free GB free on $($drive.Name), below $MinFreeGB GB"; $exitCode = 10; throw $reason }

    # --- tools
    if (-not (Test-Path $tarExe)) { throw "missing $tarExe" }
    if (-not (Test-Path $Python)) { throw "python not found at $Python (pass -Python)" }
    $bash = Join-Path $Msys2 'usr\bin\bash.exe'
    if (-not (Test-Path $bash)) { throw "missing $bash" }

    # --- compiler
    $root0 = Join-Path $env:LOCALAPPDATA 'ghc-windows-aarch64-test'
    if ($Ghc) { $ghc = $Ghc } else {
        $dirs = @(Get-ChildItem (Join-Path $root0 'install') -Directory -Filter 'ghc-*' |
                  Where-Object { Test-Path (Join-Path $_.FullName 'bin\ghc.exe') })
        if ($dirs.Count -ne 1) { throw "expected exactly one install\ghc-* dir, found $($dirs.Count) ($($dirs.Name -join ', ')); pass -Ghc <path to ghc.exe>" }
        $ghc = Join-Path $dirs[0].FullName 'bin\ghc.exe'
    }
    $info = (& $ghc --info) -join "`n"
    $ghcCommit = if ($info -match '\("Project Git commit id","([^"]*)"\)') { $Matches[1] } else { '' }
    State "ghc $(& $ghc --numeric-version) at $ghc; Project Git commit id: '$ghcCommit'" | Out-Null
    if ($ExpectGhc -and -not (Same-Commit $ghcCommit $ExpectGhc)) {
        $reason = "commit mismatch: ghc is '$ghcCommit', expected '$ExpectGhc'"; $exitCode = 12; throw $reason
    }

    # --- coverage flags, derived from the compiler the way Hadrian does (see the header)
    $haveNcg = $info -match '\("Have native code generator","YES"\)'
    $rtsInfo = (& $ghc +RTS --info) -join "`n"
    if ($rtsInfo -notmatch '\("RTS way",\s*"([^"]*)"\)') { throw 'no "RTS way" in the output of ghc +RTS --info' }
    $rtsWay = $Matches[1]
    $debugRts = $rtsWay -match 'debug'
    $extraOpts = "-e config.have_ncg=$(if ($haveNcg) { 'True' } else { 'False' }) -e config.debug_rts=$(if ($debugRts) { 'True' } else { 'False' })"
    State "coverage: ghc --info Have native code generator=$(if ($haveNcg) { 'YES' } else { 'not YES' }); ghc +RTS --info RTS way='$rtsWay'; EXTRA_RUNTEST_OPTS='$extraOpts'" | Out-Null

    # --- test tree
    $src = Join-Path $Work 'src'
    if ($NoExtract) {
        if (-not (Test-Path $src)) { throw "-NoExtract but $src does not exist" }
        State "reusing extracted tree in $src" | Out-Null
    } else {
        if (-not $Archive) { throw '-Archive is required unless -NoExtract is given' }
        if (-not (Test-Path $Archive)) { throw "archive not found: $Archive" }
        if (Test-Path $src) { & $cmdExe /c rd /s /q $src }   # Remove-Item hangs on this tree
        New-Item -ItemType Directory -Force $src | Out-Null
        & $tarExe -xzf $Archive -C $src
        if ($LASTEXITCODE -ne 0) { throw "tar failed: $LASTEXITCODE" }
        State "unpacked $Archive with $tarExe" | Out-Null
    }
    $root = if (Test-Path (Join-Path $src 'testsuite-tree\testsuite\tests')) { Join-Path $src 'testsuite-tree' }
            elseif (Test-Path (Join-Path $src 'testsuite\tests')) { $src }
            else { throw "no testsuite\tests under $src (neither testsuite-tree\ nor top-level layout)" }
    $commitFile = Join-Path $root 'COMMIT'
    $treeCommit = if (Test-Path $commitFile) { (Get-Content $commitFile -TotalCount 1).Trim() } else { '' }
    State "test tree root $root; COMMIT: '$treeCommit'" | Out-Null
    if ($ExpectTree -and -not (Same-Commit $treeCommit $ExpectTree)) {
        $reason = "commit mismatch: test tree is '$treeCommit', expected '$ExpectTree'"; $exitCode = 12; throw $reason
    }

    # --- test tools (inplace\bin), after the tree is in place; also with -NoExtract
    if ($Tools) {
        if (-not (Test-Path $Tools)) { throw "tools zip not found: $Tools" }
        $inplaceBin = Join-Path $root 'inplace\bin'
        New-Item -ItemType Directory -Force $inplaceBin | Out-Null
        & $tarExe -xf $Tools -C $inplaceBin
        if ($LASTEXITCODE -ne 0) { throw "tar failed on $Tools : $LASTEXITCODE" }
        State "tools: $Tools -> $inplaceBin : $((Get-ChildItem $inplaceBin -File).Name -join ' ')" | Out-Null
    }

    # --- throwaway git repo so that perf metrics are recorded (see the header)
    if (-not (Test-Path (Join-Path $root '.git'))) {
        $git = Get-Command git -ErrorAction Stop
        & $git.Source -C $root init -q
        & $git.Source -C $root -c user.name=testsuite -c user.email=testsuite@localhost commit -q --allow-empty -m "testsuite tree $treeCommit"
        if ($LASTEXITCODE -ne 0) { throw "git commit in $root failed: $LASTEXITCODE" }
        State "git: empty repository with one commit in $root (perf metrics need git rev-parse HEAD)" | Out-Null
    }

    # --- per-run temp dir
    $runTmp = Join-Path $Work ('tmp-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
    New-Item -ItemType Directory -Force $runTmp | Out-Null
    $env:TMP = $runTmp; $env:TEMP = $runTmp; $env:TMPDIR = $runTmp
    $msysTmpBefore = MsysGhcTmpCount
    State "temp dir $runTmp; $Msys2\tmp has $msysTmpBefore ghc*_tmp_* dirs before the run" | Out-Null

    # inherit: keep the Windows PATH in MSYS2's login shell (the driver runs git).
    $env:MSYSTEM = 'MSYS'; $env:CHERE_INVOKING = '1'; $env:MSYS2_PATH_TYPE = 'inherit'

    # python3 / python for the test shell: copies of $Python in a runner-owned dir, first on PATH (see the header).
    $shim = Join-Path $Work 'pyshim'
    New-Item -ItemType Directory -Force $shim | Out-Null
    $pyHash = (Get-FileHash $Python).Hash
    foreach ($n in 'python3.exe', 'python.exe') {
        $d = Join-Path $shim $n
        if (-not (Test-Path $d) -or (Get-FileHash $d).Hash -ne $pyHash) { Copy-Item -Force $Python $d }
    }
    $env:PATH = "$shim;$env:PATH"
    State "env: PATH of the make child, Windows form ($($env:PATH.Length) chars; pyshim first) = $env:PATH" | Out-Null
    # What a login shell with this environment sees: its PATH, and where python3/python resolve (also from `sh -c`, how the driver runs pre_cmd).
    $chk = Join-Path $logs 'shell-check.sh'
    $chkText = @'
printf 'PATH=%s\n' "$PATH"
printf 'python3=%s\n' "$(command -v python3)"
printf 'python=%s\n' "$(command -v python)"
printf 'sh-python3=%s\n' "$(sh -c 'command -v python3')"
printf 'python3-version=%s\n' "$(python3 -c 'import sys; print(sys.version.split()[0], sys.executable)')"
'@
    [IO.File]::WriteAllText($chk, ($chkText -replace "`r`n", "`n") + "`n")
    $chkOut = @(& $bash -l (MsysPath $chk) 2>&1 | ForEach-Object { "$_" })
    $chkRc = $LASTEXITCODE
    $chkMap = @{}
    foreach ($l in $chkOut) { if ($l -match '^(PATH|python3|python|sh-python3|python3-version)=(.*)$') { $chkMap[$Matches[1]] = $Matches[2] } }
    State "env: PATH of the test shell, msys form (bash -l, same environment; $($chkMap['PATH'].Length) chars) = $($chkMap['PATH'])" | Out-Null
    State "env: test shell resolves python3=$($chkMap['python3']) python=$($chkMap['python']) sh -c python3=$($chkMap['sh-python3']); python3 runs: $($chkMap['python3-version']) (shell exit $chkRc)" | Out-Null
    $shimMsys = (MsysPath $shim).ToLower()
    foreach ($k in 'python3', 'python', 'sh-python3') {
        if (-not $chkMap[$k] -or -not $chkMap[$k].ToLower().StartsWith($shimMsys + '/')) {
            $reason = "test shell does not resolve $k to the pyshim dir ($shimMsys): '$($chkMap[$k])'"; $exitCode = 13; throw $reason
        }
    }
    if ($chkRc -ne 0 -or -not $chkMap['python3-version']) { $reason = "python3 does not run in the test shell (exit $chkRc): $($chkOut -join ' | ')"; $exitCode = 13; throw $reason }
    $only = if ($Only) { "TEST='$Only'" } else { '' }
    $mt = MsysPath $runTmp

    # --- fresh perf metrics file: the driver appends to METRICS_FILE, so keep an earlier run's file aside (T34)
    $metrics = Join-Path $logs 'perf-metrics.tsv'
    if ((Test-Path $metrics) -and -not (Select-String -Path $metrics -Pattern '\S' -Quiet)) {
        # a run with no perf test leaves a file with no rows: nothing to keep
        Remove-Item $metrics
        State "metrics: an earlier perf-metrics.tsv had no rows and was removed; this run starts a fresh $metrics" | Out-Null
    } elseif (Test-Path $metrics) {
        $old = Get-Item $metrics
        $oldRows = @(Get-Content $metrics | Where-Object { $_.Trim() }).Count
        $aside = Join-Path $logs ('perf-metrics-' + $old.LastWriteTimeUtc.ToString('yyyyMMddTHHmmssZ') + '.tsv')
        for ($i = 1; Test-Path $aside; $i++) { $aside = Join-Path $logs ('perf-metrics-' + $old.LastWriteTimeUtc.ToString('yyyyMMddTHHmmssZ') + "-$i.tsv") }
        Move-Item $metrics $aside
        State "metrics: an earlier perf-metrics.tsv ($oldRows rows, $($old.Length) bytes, last written $($old.LastWriteTimeUtc.ToString('u'))) was moved to $aside; this run starts a fresh $metrics" | Out-Null
    } else {
        State "metrics: no earlier perf-metrics.tsv; this run starts a fresh $metrics" | Out-Null
    }
    # tests/linters/Makefile does not include boilerplate.mk, so it only sees CHANGELOG_D when hadrian passes it;
    # do the same when the tools are there. (The other tools get their default from boilerplate.mk.)
    $changelogD = Join-Path $root 'inplace\bin\changelog-d.exe'
    $toolVars = if ($Tools -and (Test-Path $changelogD)) { "CHANGELOG_D='$(MsysPath $changelogD)' " } else { '' }
    # /etc/profile resets TMP and TEMP to /tmp, so export them again after login.
    # TEST_HC is also exported, as Hadrian does (hadrian/src/Rules/Test.hs); some tests read it from the environment (T18382).
    # Per-test timestamps (see the header): -v3 makes the driver print a start line for every test case, and its own
    # stdout is made line-buffered (not the python children's) so the lines reach the log when they are printed.
    $runOpts = $extraOpts
    $verbose = ''
    if (-not $NoTimeline) {
        $runOpts += ' -e "sys.stdout.reconfigure(line_buffering=True)"'
        $verbose = 'VERBOSE=3 '
    }
    $cmd = "export TMP='$mt' TEMP='$mt' TMPDIR='$mt' TEST_HC='$(MsysPath $ghc)'; " +
           "make -C testsuite/tests test TEST_HC='$(MsysPath $ghc)' PYTHON='$(MsysPath $Python)' " +
           "THREADS=$Threads SPEED=$Speed SUMMARY_FILE='$(MsysPath (Join-Path $logs 'summary.txt'))' " +
           "JUNIT_FILE='$(MsysPath (Join-Path $logs 'junit.xml'))' " +
           "METRICS_FILE='$(MsysPath $metrics)' " +
           "EXTRA_RUNTEST_OPTS='$runOpts' $verbose$toolVars$only"
    State "env: TEST_HC=$(MsysPath $ghc) exported to the make child (msys form, as passed to make)" | Out-Null
    State "running: $cmd" | Out-Null
    # The command goes in a script, run by a login shell like shell-check.sh above (no quoting layer for the -e option).
    $runMake = Join-Path $logs 'run-make.sh'
    [IO.File]::WriteAllText($runMake, $cmd + "`n")

    # cmd.exe merges stdout and stderr into the log; taskkill /T takes the whole tree. The make child is started
    # inside the job object (see the header): -ProcessMemoryMB per process, 0 = no cap.
    if ($ProcessMemoryMB -ne 0 -and $ProcessMemoryMB -lt 512) { throw "-ProcessMemoryMB must be 0 (no cap) or at least 512, got $ProcessMemoryMB" }
    $log = Join-Path $logs 'testsuite.log'
    $timeline = Join-Path $logs 'timeline.tsv'
    $cmdline = "`"$cmdExe`" /s /c `"`"$bash`" -l `"$(MsysPath $runMake)`" > `"$log`" 2>&1`""
    $job = New-Object RunnerJob -ArgumentList $ProcessMemoryMB, $log, $(if ($NoTimeline) { $null } else { $timeline })
    State "job: make child in a job object with a per-process commit limit of $(if ($ProcessMemoryMB) { "$ProcessMemoryMB MB (JOB_OBJECT_LIMIT_PROCESS_MEMORY)" } else { 'none (accounting only)' }); timeline: $(if ($NoTimeline) { 'off' } else { "$timeline (VERBOSE=3, polled every 250 ms)" })" | Out-Null
    $procId = $job.Start($cmdline, $root)
    $tests = Join-Path $root 'testsuite\tests'
    $every = [TimeSpan]::FromMinutes($LogEveryMinutes)
    $next = Get-Date
    while (-not $job.WaitForExit(15000)) {
        foreach ($e in $job.DrainEvents()) { State "memory-cap: $e" | Out-Null }
        if (-not $NoIservSweep) { IservSweep $runTmp }
        $free = FreeGB
        if ($free -lt $AbortFreeGB) {
            $aborted = $true
            $reason = "aborted: $free GB free on $($drive.Name), below $AbortFreeGB GB (latest test: $(LatestTest $tests))"
            $exitCode = 11
            State "free-space: $free GB; $reason; killing process tree $procId" | Out-Null
            KillTree $procId
            $job.Kill()
            break
        }
        if ((Get-Date) -ge $next) {
            State "free-space: $free GB on $($drive.Name); latest test: $(LatestTest $tests); peak commit of any process so far: $([math]::Round($job.PeakProcessBytes / 1MB)) MB" | Out-Null
            $next = (Get-Date) + $every
        }
    }
    foreach ($e in $job.DrainEvents()) { State "memory-cap: $e" | Out-Null }
    if (-not $aborted) {
        $code = $job.ExitCode
        $reason = "make exit $code"
        $exitCode = $code
    }
    State "job: peak commit of any single process in the run: $([math]::Round($job.PeakProcessBytes / 1MB)) MB (limit $(if ($ProcessMemoryMB) { "$ProcessMemoryMB MB" } else { 'none' }))" | Out-Null
    State "free-space: $(FreeGB) GB on $($drive.Name) after the run; $Msys2\tmp has $(MsysGhcTmpCount) ghc*_tmp_* dirs (before: $msysTmpBefore)" | Out-Null
} catch {
    if (-not $reason) { $reason = "error: $($_.Exception.Message)"; $exitCode = 13 }
} finally {
    try {
        if ($aborted) { SweepStragglers }
        if ($job) {
            foreach ($e in $job.DrainEvents()) { State "memory-cap: $e" | Out-Null }
            $job.Dispose()   # stops the timeline thread after a last pass over the log
            if (-not $NoTimeline) { State "timeline: $($job.TimelineLines) marker lines in $(Join-Path $logs 'timeline.tsv')" | Out-Null }
        }
        State "iserv-sweep: run total $($script:sweepFiles) .iserv file(s), $([math]::Round($script:sweepBytes / 1MB, 1)) MiB removed during the run, $($script:sweepDirs) empty ghc*_tmp_* dir(s) removed (sweep $(if ($NoIservSweep) { 'off: -NoIservSweep' } else { 'on' }))" | Out-Null
        if ($runTmp -and (Test-Path $runTmp)) {
            $leaked = @(Get-ChildItem $runTmp -Force -ErrorAction SilentlyContinue).Count
            # A program still running from the temp dir (GHC's temp executables) keeps it locked: stop it, then retry.
            for ($i = 1; $i -le 6; $i++) {
                & $cmdExe /c rd /s /q $runTmp 2>$null
                if (-not (Test-Path $runTmp)) { break }
                Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like "$runTmp\*" } | ForEach-Object {
                    State "stopping $($_.ProcessId) $($_.ExecutablePath), still running from the temp dir" | Out-Null
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                }
                Start-Sleep 5
            }
            $gone = if (Test-Path $runTmp) { 'FAILED to remove: ' + ((Get-ChildItem $runTmp -Force -ErrorAction SilentlyContinue).Name -join ' ') } else { "removed (attempt $i)" }
            State "temp dir $runTmp ($leaked entries at the end): $gone" | Out-Null
        }
    } catch { State "cleanup error: $($_.Exception.Message)" | Out-Null }
    State "free-space: $(FreeGB) GB at the end" | Out-Null
    State "finished: $reason" | Out-Null
}
exit $exitCode
