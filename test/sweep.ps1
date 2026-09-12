# sweep.ps1 -- run one test across a range of diversification seeds
# Usage: powershell -NoProfile -File sweep.ps1 [-Max 12] [testname ...]
param([int]$Max = 12, [Parameter(ValueFromRemainingArguments=$true)][string[]]$Names)

$root = 'C:\Users\Rainy\Desktop\Project\Luac2c'
$here = "$root\test"
$gcc  = 'C:\environments\GCC-16.2.0\bin\gcc.exe'
$lib  = "$root\lua-5.5.1\build\liblua.a"
$inc  = @('-I', "$root\lua-5.5.1\src", '-I', "$root\lua5.5-include")
Set-Location $root

# Rebuild the translator first: the sweep must exercise the current source.
& $gcc 'luac2c.c' '-std=c99' '-w' '-O0' '-o' 'luac2c.exe' 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { 'FATAL: luac2c.c failed to build' | Set-Content "$here\_sweep.txt" -Encoding UTF8; exit 1 }

# artifacts stay inside test\
Set-Location $here

if ($Names.Count -eq 0) { $Names = @('test_meta','test_closure','test_loop','test_goto','test_vararg','test_bitwise') }

$log = New-Object System.Collections.Generic.List[string]
foreach ($n in $Names) {
    & "$root\luac.exe" -o "$n.luac" "$n.lua" 2>&1 | Out-Null
    $exp = (& "$root\lua.exe" "$n.lua" 2>&1 | Out-String)
    $ok = 0; $bad = @()
    foreach ($s in 0..$Max) {
        $c = "_sw.c"; $e = "_sw.exe"
        & "$root\luac2c.exe" "$n.luac" -o $c --seed $s 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $bad += "seed${s}:GEN"; continue }
        & $gcc $c @inc '-std=c99' '-w' '-O0' '-o' $e $lib '-lm' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $bad += "seed${s}:GCC"; continue }
        $act = (& "$here\$e" 2>&1 | Out-String)
        $rc  = $LASTEXITCODE
        if ($act -eq $exp -and $rc -eq 0) { $ok++ } else { $bad += "seed${s}:DIFF(rc=$rc)" }
    }
    # the --static baseline (identity layout, reproducible) must also pass
    & "$root\luac2c.exe" "$n.luac" -o "_sws.c" --static 2>&1 | Out-Null
    & $gcc '_sws.c' @inc '-std=c99' '-w' '-O0' '-o' '_sws.exe' $lib '-lm' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $bad += "static:GCC" }
    else {
        $sact = (& "$here\_sws.exe" 2>&1 | Out-String)
        $src  = $LASTEXITCODE
        if ($sact -eq $exp -and $src -eq 0) { $ok++ } else { $bad += "static:DIFF(rc=$src)" }
    }
    $log.Add("$n : ok=$ok/$($Max+2)  bad=[$($bad -join ' ')]")
}
$log | Set-Content "$here\_sweep.txt" -Encoding UTF8
