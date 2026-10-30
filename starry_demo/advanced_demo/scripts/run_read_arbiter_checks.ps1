[CmdletBinding()]
param(
    [string]$OutputDir = '',
    [switch]$NoWave
)

$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path $taskRoot 'output/read_arbiter' }
$iverilogExe = (Get-Command iverilog -ErrorAction Stop).Source
$vvpExe = (Get-Command vvp -ErrorAction Stop).Source
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$outputPath = (Resolve-Path -LiteralPath $OutputDir).Path
$binaryPath = Join-Path $outputPath 'read_arbiter.vvp'
$logPath = Join-Path $outputPath 'read_arbiter.log'

Start-Transcript -Path $logPath -Force | Out-Null
try {
    Write-Host "Icarus: $iverilogExe"
    $compileArgs = @('-g2005-sv', '-Wall', '-s', 'tb_ddr_read_arbiter', '-o', $binaryPath,
        (Join-Path $taskRoot 'rtl/framebuffer/ddr_read_arbiter.v'),
        (Join-Path $taskRoot 'sim/tb_ddr_read_arbiter.v'))
    & $iverilogExe @compileArgs | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw 'Read arbiter compilation failed.' }
    Push-Location -LiteralPath $outputPath
    try {
        $runtimeArgs = @($binaryPath)
        if (-not $NoWave) { $runtimeArgs += '+VCD' }
        $simulationOutput = @(& $vvpExe @runtimeArgs)
        $simulationExit = $LASTEXITCODE
        $simulationOutput | ForEach-Object { Write-Host $_ }
        if ($simulationExit -ne 0 -or -not ($simulationOutput -match '^PASS READ ARBITER:')) {
            throw 'Read arbiter simulation failed.'
        }
        if (-not $NoWave) {
            $wavePath = Join-Path $outputPath 'read_arbiter.vcd'
            if (-not (Test-Path -LiteralPath $wavePath) -or (Get-Item -LiteralPath $wavePath).Length -eq 0) {
                throw 'Expected read arbiter waveform was not generated.'
            }
            Write-Host "Waveform: $wavePath"
        }
        $guardOutput = @(& $vvpExe $binaryPath '+SWAP_RESPONSES')
        $guardExit = $LASTEXITCODE
        $guardOutput | Set-Content -LiteralPath (
            Join-Path $outputPath 'routing_expected_failure.log'
        ) -Encoding UTF8
        if ($guardExit -eq 0 -or -not ($guardOutput -match 'Read response routed to wrong master')) {
            throw 'Routing scoreboard did not detect intentionally swapped client responses.'
        }
        Write-Host 'PASS routing negative control: swapped client responses detected.'
    } finally { Pop-Location }
    Write-Host 'PASS independent read arbiter checks. System tests run separately with run_d_checks.py --graphics; Efinity/board verification pending.'
    Write-Host "Log: $logPath"
} finally { Stop-Transcript | Out-Null }
