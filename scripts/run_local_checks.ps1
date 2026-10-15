param(
    [string]$Iverilog = 'iverilog',
    [string]$Vvp = 'vvp',
    [string]$Python = 'python',
    [switch]$Quick,
    [string]$UnicornPath = ''
)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
Push-Location $taskRoot
try {
    & $Python 'scripts/check_project.py'
    if ($LASTEXITCODE -ne 0) { throw 'Current project/register contract checks failed' }
    & $Python 'scripts/build_apb_software.py'
    if ($LASTEXITCODE -ne 0) { throw 'Checkpoint E software build failed' }
    if ($UnicornPath) {
        & $Python 'scripts/run_e_software_checks.py' '--unicorn-path' $UnicornPath
        if ($LASTEXITCODE -ne 0) { throw 'Checkpoint E software MMIO-model tests failed' }
    }
    $taskArgs = @('scripts/run_c_checks.py', '--iverilog', $Iverilog, '--vvp', $Vvp)
    if (-not $Quick) { $taskArgs += '--full-init' }
    & $Python @taskArgs
    if ($LASTEXITCODE -ne 0) { throw 'Checkpoint C simulations failed' }
    & $Python 'scripts/run_d_checks.py'
    if ($LASTEXITCODE -ne 0) { throw 'Checkpoint D ownership/display-protection simulations failed' }
    & $Python 'scripts/run_apb_checks.py' '--iverilog' $Iverilog '--vvp' $Vvp
    if ($LASTEXITCODE -ne 0) { throw 'APB compatibility regression failed' }
    & $Python 'scripts/run_rgb_checks.py' '--quick' '--iverilog' $Iverilog '--vvp' $Vvp
    if ($LASTEXITCODE -ne 0) { throw 'RGB regression/top elaboration failed' }
} finally {
    Pop-Location
}
