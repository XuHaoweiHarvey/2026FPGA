[CmdletBinding()]
param(
    [string]$OutputDir = '',
    [string]$PythonExe = '',
    [switch]$NoWave
)

$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path $taskRoot 'output/blit' }
$iverilogExe = (Get-Command iverilog -ErrorAction Stop).Source
$vvpExe = (Get-Command vvp -ErrorAction Stop).Source
$rtlPath = Join-Path $taskRoot 'rtl/accelerator/blit_engine.v'
$tbPath = Join-Path $taskRoot 'sim/tb_blit_engine.v'
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$outputPath = (Resolve-Path -LiteralPath $OutputDir).Path
$logPath = Join-Path $outputPath 'blit.log'

function Invoke-BlitSimulation {
    param([string]$Name, [string[]]$Overrides, [switch]$Wave)
    $caseDir = Join-Path $outputPath $Name
    New-Item -ItemType Directory -Path $caseDir -Force | Out-Null
    $binaryPath = Join-Path $caseDir 'blit.vvp'
    $compileArgs = @('-g2005-sv', '-Wall', '-s', 'tb_blit_engine') + $Overrides +
        @('-o', $binaryPath, $tbPath, $rtlPath)
    Write-Host "Compile/run: $Name"
    & $iverilogExe @compileArgs | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "Compilation failed: $Name" }
    Push-Location -LiteralPath $caseDir
    try {
        $runtimeArgs = @($binaryPath)
        if ($Wave) { $runtimeArgs += '+VCD' }
        $sawPass = $false
        & $vvpExe @runtimeArgs | ForEach-Object {
            Write-Host $_
            if ($_ -match '^PASS BLIT:') { $sawPass = $true }
        }
        if ($LASTEXITCODE -ne 0 -or -not $sawPass) { throw "Simulation failed: $Name" }
        if ($Wave) {
            $waveFile = Join-Path $caseDir 'blit.vcd'
            if (-not (Test-Path -LiteralPath $waveFile) -or (Get-Item -LiteralPath $waveFile).Length -eq 0) {
                throw 'Expected waveform was not generated.'
            }
        }
    } finally { Pop-Location }
}

Start-Transcript -Path $logPath -Force | Out-Null
try {
    Write-Host "Icarus: $iverilogExe"
    Write-Host "Artifacts: $outputPath"
    Invoke-BlitSimulation -Name 'basic' -Overrides @() -Wave:(-not $NoWave)
    Invoke-BlitSimulation -Name 'boundaries' -Overrides @(
        '-Ptb_blit_engine.FRAME_WIDTH=1088', '-Ptb_blit_engine.EDGE_ONLY=1'
    )
    Invoke-BlitSimulation -Name 'single_beat_buffer' -Overrides @(
        '-Ptb_blit_engine.FRAME_WIDTH=1088', '-Ptb_blit_engine.EDGE_ONLY=1',
        '-Ptb_blit_engine.MAX_BURST_BEATS=1'
    )
    Invoke-BlitSimulation -Name 'address_space_end' -Overrides @(
        '-Ptb_blit_engine.ADDRESS_EDGE_ONLY=1', '-Ptb_blit_engine.SOURCE_BASE=4294901760'
    )

    Write-Host 'Check scoreboard: deliberately corrupt a pixel and require rejection'
    $guardBinary = Join-Path $outputPath 'basic/blit.vvp'
    Push-Location -LiteralPath (Join-Path $outputPath 'basic')
    try {
        $guardOutput = @(& $vvpExe $guardBinary '+CORRUPT_WRITE')
        $guardExit = $LASTEXITCODE
    } finally { Pop-Location }
    $guardOutput | Set-Content -LiteralPath (Join-Path $outputPath 'scoreboard_expected_failure.log') -Encoding UTF8
    if ($guardExit -eq 0 -or -not ($guardOutput -match 'Target pixel')) {
        throw 'The negative control did not detect the deliberately corrupted pixel.'
    }
    Write-Host 'PASS scoreboard negative control: incorrect pixel was detected as expected.'

    $pythonArgs = @()
    if (-not $PythonExe) {
        foreach ($candidate in @('py', 'python', 'python3')) {
            $pythonCommand = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue
            if ($pythonCommand) {
                $candidateArgs = @()
                if ($candidate -eq 'py') { $candidateArgs = @('-3') }
                try {
                    $probeOutput = @(& $pythonCommand.Source @candidateArgs --version 2>&1)
                    if ($LASTEXITCODE -eq 0 -and ($probeOutput -match '^Python 3\.')) {
                        $PythonExe = $pythonCommand.Source
                        $pythonArgs = $candidateArgs
                        break
                    }
                } catch {
                    # Skip launchers or Store aliases that cannot start Python.
                }
            }
        }
    }
    if ($PythonExe) {
        & $PythonExe @pythonArgs (Join-Path $PSScriptRoot 'render_blit_preview.py') (Join-Path $outputPath 'basic') |
            ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { throw 'PNG preview conversion failed.' }
    } else {
        Write-Host 'PNG previews skipped: optional Python 3 not found. PPM pixels and simulation results are available.'
    }
    Write-Host 'PASS all BLIT unit simulations. No Efinity or board validation was performed.'
    if (-not $NoWave) { Write-Host ('Waveform: ' + (Join-Path $outputPath 'basic/blit.vcd')) }
    Write-Host "Log: $logPath"
} finally { Stop-Transcript | Out-Null }
