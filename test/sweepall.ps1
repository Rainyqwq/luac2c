# sweepall.ps1 -- single-process sweep: every test across seeds 0..MaxSeed and --static.
# Builds its own translator binary so it never races with an interactive rebuild.
param([int]$MaxSeed = 9)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
if ($env:LUAC2C_ROOT) { $root = $env:LUAC2C_ROOT }
$here = $PSScriptRoot
$gcc  = 'gcc'
if ($env:GCC) { $gcc = $env:GCC }
else { $gc = Get-Command gcc -ErrorAction SilentlyContinue; if ($gc) { $gcc = $gc.Source } }
$lib  = "$root\lua-5.5.1\build\liblua.a"
$inc  = @('-I', "$root\lua-5.5.1\src", '-I', "$root\lua5.5-include")
$cfl  = @('-std=c99', '-w', '-O0')
$tmp  = "$env:TEMP\l2c_sw.txt"
$l2c  = "$root\luac2c_sweep.exe"

Set-Location $root

function Run([string]$exe, [string[]]$a) {
    $global:LASTEXITCODE = 0
    & $exe @a *> $tmp
    $code = $LASTEXITCODE
    $o = Get-Content $tmp -Raw -ErrorAction SilentlyContinue
    if ($null -eq $o) { $o = '' }
    return @{ Code = $code; Out = ($o -replace "`r", '').Trim() }
}

$b = Run $gcc (@('luac2c.c') + $cfl + @('-o', $l2c))
if ($b.Code -ne 0) { "FATAL build:`n$($b.Out)" | Set-Content "$here\_sweep.txt" -Encoding UTF8; exit 1 }

# artifacts stay inside test\
Set-Location $here

$names = Get-ChildItem "$here\test_*.lua" | ForEach-Object { $_.BaseName } | Sort-Object

# Compile each test to bytecode once (mode independent).
foreach ($n in $names) { (Run "$root\luac.exe" @('-o', "$n.luac", "$n.lua")) | Out-Null }

# Reference output from the real interpreter, once.
$ref = @{}
foreach ($n in $names) { $ref[$n] = Run "$root\lua.exe" @("$n.lua") }

$log = New-Object System.Collections.Generic.List[string]
$modes = @()
for ($s = 0; $s -le $MaxSeed; $s++) { $modes += ,@('--seed', "$s") }
$modes += ,@('--static')

$totalPass = 0; $totalFail = 0
foreach ($m in $modes) {
    $label = $m -join ' '
    $p = 0; $f = 0
    foreach ($n in $names) {
        $c = "$n`_sw.c"; $exe = "$n`_sw.exe"
        $r = Run $l2c (@("$n.luac", '-o', $c) + $m)
        if ($r.Code -ne 0) { $log.Add("FAIL [$label] $n : luac2c: $($r.Out)"); $f++; continue }
        $r = Run $gcc (@($c) + $inc + $cfl + @('-o', $exe, $lib, '-lm'))
        if ($r.Code -ne 0) { $log.Add("FAIL [$label] $n : gcc: $($r.Out)"); $f++; continue }
        $a = Run "$here\$exe" @()
        $e = $ref[$n]
        if ($e.Out -eq $a.Out -and $e.Code -eq $a.Code) { $p++ }
        else {
            $f++
            $log.Add("FAIL [$label] $n")
            $log.Add("   expect(exit=$($e.Code)): $($e.Out)")
            $log.Add("   actual(exit=$($a.Code)): $($a.Out)")
        }
    }
    $log.Add("$label -> $p passed, $f failed")
    $totalPass += $p; $totalFail += $f
}
$log.Add("SWEEP TOTAL: $totalPass passed, $totalFail failed over $($modes.Count) modes x $($names.Count) tests")
($log -join "`n") | Set-Content "$here\_sweep.txt" -Encoding UTF8
