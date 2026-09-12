# hashes.ps1 -- digest of the generated C per (test, mode), to show that
# diversification really varies the translation.
$root = 'C:\Users\Rainy\Desktop\Project\Luac2c'
$gcc  = 'C:\environments\GCC-16.2.0\bin\gcc.exe'
Set-Location $root

# its own binary so an interactive rebuild cannot interfere
& $gcc luac2c.c -std=c99 -w -O0 -o luac2c_hash.exe
if ($LASTEXITCODE -ne 0) { 'build failed' | Set-Content "$root\_hashes.txt" -Encoding UTF8; exit 1 }

$tests = @('test_arith','test_meta','test_loop','test_table','test_genfor','test_vararg')
$modes = @()
for ($s = 0; $s -le 5; $s++) { $modes += ,@('--seed', "$s") }
$modes += ,@('--static')

$lines = New-Object System.Collections.Generic.List[string]
foreach ($t in $tests) { & .\luac.exe -o "$t.luac" "$t.lua" 2>$null | Out-Null }

$hdr = "test".PadRight(12) + ($modes | ForEach-Object { ($_ -join ' ').PadRight(10) }) -join ''
$lines.Add($hdr)
foreach ($t in $tests) {
    $row = $t.PadRight(12)
    foreach ($m in $modes) {
        & .\luac2c_hash.exe "$t.luac" -o "_h.c" @m 2>$null | Out-Null
        $h = (Get-FileHash "_h.c" -Algorithm SHA256).Hash.Substring(0,8)
        $row += $h.PadRight(10)
    }
    $lines.Add($row)
}
# distinct-output counts per test
$lines.Add("")
$lines.Add("distinct digests per test over seeds 0-5:")
foreach ($t in $tests) {
    $set = @{}
    for ($s = 0; $s -le 5; $s++) {
        & .\luac2c_hash.exe "$t.luac" -o "_h.c" --seed $s 2>$null | Out-Null
        $set[(Get-FileHash "_h.c" -Algorithm SHA256).Hash] = 1
    }
    $lines.Add("  $t : $($set.Count) distinct / 6")
}
Remove-Item "_h.c" -ErrorAction SilentlyContinue
($lines -join "`n") | Set-Content "$root\_hashes.txt" -Encoding UTF8
