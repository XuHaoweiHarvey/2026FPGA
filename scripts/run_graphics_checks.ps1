[CmdletBinding()]
param(
    [string]$OutputDir = '',
    [string]$PythonExe = '',
    [switch]$NoWave
)

$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path $taskRoot 'output/graphics' }
$iverilogExe = (Get-Command iverilog -ErrorAction Stop).Source
$vvpExe = (Get-Command vvp -ErrorAction Stop).Source
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$outputPath = (Resolve-Path -LiteralPath $OutputDir).Path
$logPath = Join-Path $outputPath 'graphics.log'
$sourcePaths = @(
    'sim/tb_graphics_engine.v', 'sim/tb_blit_engine.v',
    'rtl/accelerator/graphics_engine.v', 'rtl/accelerator/fill_rect_writer.v',
    'rtl/accelerator/blit_engine.v'
) | ForEach-Object { Join-Path $taskRoot $_ }

function Invoke-GraphicsSimulation {
    param([string]$Name, [string[]]$Overrides, [switch]$Wave,
          [string]$Top = 'tb_graphics_engine', [string]$PassPattern = '^PASS GRAPHICS:')
    $caseDir = Join-Path $outputPath $Name
    New-Item -ItemType Directory -Path $caseDir -Force | Out-Null
    $binaryPath = Join-Path $caseDir 'graphics.vvp'
    $compileSources = $sourcePaths
    if ($Top -eq 'tb_graphics_contract') {
        $compileSources += @('sim/tb_graphics_contract.v', 'rtl/framebuffer/buffer_manager.v') |
            ForEach-Object { Join-Path $taskRoot $_ }
    }
    $compileArgs = @('-g2005-sv', '-Wall', '-s', $Top) + $Overrides +
        @('-o', $binaryPath) + $compileSources
    Write-Host "Compile/run: $Name"
    & $iverilogExe @compileArgs | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "Compilation failed: $Name" }
    Push-Location -LiteralPath $caseDir
    try {
        $runtimeArgs = @($binaryPath)
        if ($Wave) { $runtimeArgs += '+VCD' }
        $simulationOutput = @(& $vvpExe @runtimeArgs)
        $simulationExit = $LASTEXITCODE
        $simulationOutput | ForEach-Object { Write-Host $_ }
        if ($simulationExit -ne 0 -or -not ($simulationOutput -match $PassPattern)) {
            throw "Simulation failed: $Name"
        }
        if ($Wave) {
            $waveFile = Join-Path $caseDir 'graphics.vcd'
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
    Invoke-GraphicsSimulation -Name 'basic' -Overrides @() -Wave:(-not $NoWave)
    Invoke-GraphicsSimulation -Name 'single_beat_remapped' -Overrides @(
        '-Ptb_graphics_engine.MAX_BURST_BEATS=1',
        '-Ptb_graphics_engine.OP_FILL=7', '-Ptb_graphics_engine.OP_BLIT=9'
    )
    Invoke-GraphicsSimulation -Name 'manager_contract' -Overrides @() `
        -Top 'tb_graphics_contract' -PassPattern '^PASS GRAPHICS CONTRACT:'

    Write-Host 'Check scoreboard: deliberately corrupt a pixel and require rejection'
    Push-Location -LiteralPath (Join-Path $outputPath 'basic')
    try {
        $guardOutput = @(& $vvpExe (Join-Path $outputPath 'basic/graphics.vvp') '+CORRUPT_WRITE')
        $guardExit = $LASTEXITCODE
    } finally { Pop-Location }
    $guardOutput | Set-Content -LiteralPath (Join-Path $outputPath 'scoreboard_expected_failure.log') -Encoding UTF8
    if ($guardExit -eq 0 -or -not ($guardOutput -match 'Target pixel')) {
        throw 'The scoreboard did not reject the deliberately corrupted pixel.'
    }
    Write-Host 'PASS scoreboard negative control: incorrect pixel detected.'

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
        & $PythonExe @pythonArgs (Join-Path $PSScriptRoot 'render_blit_preview.py') `
            (Join-Path $outputPath 'basic') --names checker_source 01_fill 02_blit 03_overlay |
            ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { throw 'PNG preview conversion failed.' }
    } else {
        Write-Host 'PNG previews skipped: optional Python 3 not found. PPMs and RTL checks are available.'
    }
    Write-Host 'PASS all graphics dispatcher simulations. No APB/DDR/HDMI integration or board validation.'
    if (-not $NoWave) { Write-Host ('Waveform: ' + (Join-Path $outputPath 'basic/graphics.vcd')) }
    Write-Host "Log: $logPath"
} finally { Stop-Transcript | Out-Null }
