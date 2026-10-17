param([string]$Python='python',[string]$Iverilog='iverilog',[string]$Vvp='vvp')
$ErrorActionPreference='Stop'
& $Python (Join-Path $PSScriptRoot 'run_tests.py') --iverilog $Iverilog --vvp $Vvp
if ($LASTEXITCODE -ne 0) { throw 'C package verification failed. See test_results/simulation.log.' }
