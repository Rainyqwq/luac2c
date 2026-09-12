# runall.ps1 -- run every test_*.lua through the full pipeline and report.
# Self-contained: builds luac2c.exe once, then compiles+runs each case.
param([int]$Seed = -1, [switch]$Static, [switch]$All)

$ErrorActionPreference = 'Continue'
$root = 'C:\Users\Rainy\Desktop\Project\Luac2c'
$here = "$root\test"
$gcc  = 'C:\environments\GCC-16.2.0\bin\gcc.exe'
$lib  = "$root\lua-5.5.1\build\liblua.a"
$inc  = @('-I', "$root\lua-5.5.1\src", '-I', "$root\lua5.5-include")
$cfl  = @('-std=c99', '-w', '-O0')
$tmp  = "$env:TEMP\l2c_run.txt"

Set-Location $root

function Run([string]$exe, [string[]]$args2) {
    $global:LASTEXITCODE = 0
    & $exe @args2 *> $tmp
    $code = $LASTEXITCODE
    $o = Get-Content $tmp -Raw -ErrorAction SilentlyContinue
    if ($null -eq $o) { $o = '' }
    return @{ Code = $code; Out = ($o -replace "`r", '').Trim() }
}

# --- build the translator -------------------------------------------------
$b = Run $gcc (@('luac2c.c') + $cfl + @('-o', 'luac2c.exe'))
if ($b.Code -ne 0) { Set-Content "$here\_test_report.txt" "FATAL build:`n$($b.Out)" -Encoding UTF8; exit 1 }

# artifacts (.luac / _out.c / _out.exe) stay inside test\
Set-Location $here

$mode = if ($Static) { @('--static') } elseif ($Seed -ge 0) { @('--seed', "$Seed") } else { @() }

$names = Get-ChildItem "$here\test_*.lua" | ForEach-Object { $_.BaseName } | Sort-Object
$log = New-Object System.Collections.Generic.List[string]
$log.Add("mode: $(if ($mode.Count) { $mode -join ' ' } else { '(default diversify)' })  tests: $($names.Count)")

$pass = 0; $fail = 0
foreach ($n in $names) {
    $c   = "$n`_out.c"
    $exe = "$n`_out.exe"
    $r = Run "$root\luac.exe" @('-o', "$n.luac", "$n.lua")
    if ($r.Code -ne 0) { $log.Add("FAIL $n : luac error: $($r.Out)"); $fail++; continue }
    $r = Run "$root\luac2c.exe" (@("$n.luac", '-o', $c) + $mode)
    if ($r.Code -ne 0) { $log.Add("FAIL $n : luac2c error: $($r.Out)"); $fail++; continue }
    $r = Run $gcc (@($c) + $inc + $cfl + @('-o', $exe, $lib, '-lm'))
    if ($r.Code -ne 0) { $log.Add("FAIL $n : gcc error: $($r.Out)"); $fail++; continue }
    $e = Run "$root\lua.exe" @("$n.lua")
    $a = Run "$here\$exe" @()
    if ($e.Out -eq $a.Out -and $e.Code -eq $a.Code) { $pass++; $log.Add("pass $n") }
    else {
        $fail++
        $log.Add("FAIL $n")
        $log.Add("   expect(exit=$($e.Code)): $($e.Out)")
        $log.Add("   actual(exit=$($a.Code)): $($a.Out)")
    }
}
$log.Add("SUMMARY: $pass passed, $fail failed")
$log -join "`n" | Set-Content "$here\_test_report.txt" -Encoding UTF8
