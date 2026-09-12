# test.ps1 -- luac2c end-to-end harness
# Usage: powershell -NoProfile -File test.ps1 [testname ...]
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Names)

$ErrorActionPreference = 'Continue'
$root = 'C:\Users\Rainy\Desktop\Project\Luac2c'
$here = "$root\test"
$gcc  = 'C:\environments\GCC-16.2.0\bin\gcc.exe'
$lib  = "$root\lua-5.5.1\build\liblua.a"
$inc  = @('-I', "$root\lua-5.5.1\src", '-I', "$root\lua5.5-include")
$cfl  = @('-std=c99', '-w', '-O0')
$to   = "$env:TEMP\l2c_out.txt"

Set-Location $root

function Invoke-Cmd([string]$exe, [string[]]$ArgList) {
    $global:LASTEXITCODE = 0
    & $exe @ArgList *>&1 | Out-File $to -Encoding utf8
    $code = $LASTEXITCODE
    $o = (Get-Content $to -Raw -ErrorAction SilentlyContinue)
    if ($null -eq $o) { $o = '' }
    return @{ Code = $code; Out = $o.Trim() }
}

$log = New-Object System.Collections.Generic.List[string]
function Say($s) { $log.Add($s) }

$b = Invoke-Cmd $gcc (@('luac2c.c') + $cfl + @('-o', 'luac2c.exe'))
if ($b.Code -ne 0) {
    Say "FATAL: luac2c.c failed to build:`n$($b.Out)"
    Set-Content "$here\_test_report.txt" $log -Encoding UTF8
    exit 1
}
Say "luac2c.exe rebuilt OK"

# artifacts (.luac / _out.c / _out.exe) stay inside test\
Set-Location $here

if ($Names.Count -eq 0) {
    $Names = Get-ChildItem "$here\test_*.lua" | ForEach-Object { $_.BaseName }
}

$pass = 0; $fail = 0
foreach ($n in $Names) {
    $lua  = "$n.lua"
    $luac = "$n.luac"
    $c    = "$n`_out.c"
    $exe  = "$n`_out.exe"
    if (-not (Test-Path "$here\$lua")) { Say "SKIP $n (no $lua)"; continue }

    Say "`n===== $n ====="

    $r = Invoke-Cmd "$root\luac.exe" @('-o', $luac, $lua)
    if ($r.Code -ne 0) { Say "  luac FAILED: $($r.Out)"; $fail++; continue }

    $r = Invoke-Cmd "$root\luac2c.exe" @($luac, '-o', $c)
    if ($r.Code -ne 0) { Say "  luac2c FAILED: $($r.Out)"; $fail++; continue }

    $r = Invoke-Cmd $gcc (@($c) + $inc + $cfl + @('-o', $exe, $lib, '-lm'))
    if ($r.Code -ne 0) { Say "  gcc FAILED:`n$($r.Out)"; $fail++; continue }

    $exp = Invoke-Cmd "$root\lua.exe"    @($lua)
    $act = Invoke-Cmd "$here\$exe"       @()

    $eOut = $exp.Out; $aOut = $act.Out
    Say "  expect(exit=$($exp.Code)): $eOut"
    Say "  actual(exit=$($act.Code)): $aOut"
    if ($eOut -eq $aOut -and $exp.Code -eq $act.Code) {
        Say "  PASS"; $pass++
    } else {
        Say "  FAIL"; $fail++
    }
}

Say "`n===== SUMMARY: $pass passed, $fail failed ====="
Set-Content "$root\_test_report.txt" $log -Encoding UTF8
