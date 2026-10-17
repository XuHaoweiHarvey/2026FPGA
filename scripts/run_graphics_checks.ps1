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
    $compileSources = @()
    if ($Top -ne 'tb_blit_source_guard') { $compileSources += $sourcePaths }
    if ($Top -in @('tb_graphics_contract', 'tb_graphics_double_buffer')) {
        $compileSources += Join-Path $taskRoot 'rtl/framebuffer/buffer_manager.v'
    }
    if ($Top -in @('tb_blit_source_guard', 'tb_graphics_contract', 'tb_graphics_double_buffer')) {
        $compileSources += Join-Path $taskRoot 'rtl/framebuffer/blit_source_guard.v'
    }
    if ($Top -eq 'tb_blit_source_guard') {
        $compileSources += Join-Path $taskRoot 'sim/tb_blit_source_guard.v'
    }
    if ($Top -eq 'tb_graphics_contract') {
        $compileSources += Join-Path $taskRoot 'sim/tb_graphics_contract.v'
    }
    if ($Top -eq 'tb_graphics_double_buffer') {
        $compileSources += @('sim/tb_graphics_double_buffer.v', 'sim/graphics_double_buffer_memory.v') |
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
    $arbiterArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'run_read_arbiter_checks.ps1'),
        '-OutputDir', (Join-Path $outputPath 'read_arbiter'))
    if ($NoWave) { $arbiterArgs += '-NoWave' }
    & powershell.exe @arbiterArgs | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw 'Independent read arbiter checks failed.' }
    Invoke-GraphicsSimulation -Name 'source_guard_1080p' -Overrides @() -Wave:(-not $NoWave) `
        -Top 'tb_blit_source_guard' -PassPattern '^PASS SOURCE GUARD:'
    Invoke-GraphicsSimulation -Name 'source_guard_small' -Overrides @(
        '-Ptb_blit_source_guard.FRAME_WIDTH=64', '-Ptb_blit_source_guard.FRAME_HEIGHT=48'
    ) -Top 'tb_blit_source_guard' -PassPattern '^PASS SOURCE GUARD:'
    Invoke-GraphicsSimulation -Name 'basic' -Overrides @() -Wave:(-not $NoWave)
    Invoke-GraphicsSimulation -Name 'single_beat_remapped' -Overrides @(
        '-Ptb_graphics_engine.MAX_BURST_BEATS=1',
        '-Ptb_graphics_engine.OP_FILL=7', '-Ptb_graphics_engine.OP_BLIT=9'
    )
    Invoke-GraphicsSimulation -Name 'manager_contract' -Overrides @() `
        -Top 'tb_graphics_contract' -PassPattern '^PASS GRAPHICS CONTRACT:'
    Invoke-GraphicsSimulation -Name 'double_buffer' -Overrides @() -Wave:(-not $NoWave) `
        -Top 'tb_graphics_double_buffer' -PassPattern '^PASS GRAPHICS DOUBLE BUFFER:'
    Invoke-GraphicsSimulation -Name 'double_buffer_single_beat' -Overrides @(
        '-Ptb_graphics_double_buffer.MAX_BURST_BEATS=1'
    ) -Top 'tb_graphics_double_buffer' -PassPattern '^PASS GRAPHICS DOUBLE BUFFER:'

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

    Write-Host 'Check source guard negative control: bypass policy and require rejection'
    Push-Location -LiteralPath (Join-Path $outputPath 'manager_contract')
    try {
        $guardOutput = @(& $vvpExe (Join-Path $outputPath 'manager_contract/graphics.vvp') '+BYPASS_SOURCE_GUARD')
        $guardExit = $LASTEXITCODE
    } finally { Pop-Location }
    $guardOutput | Set-Content -LiteralPath (
        Join-Path $outputPath 'source_guard_expected_failure.log'
    ) -Encoding UTF8
    if ($guardExit -eq 0 -or -not ($guardOutput -match 'Rejected command exposed AXI')) {
        throw 'The contract test did not reject a bypassed source guard.'
    }
    Write-Host 'PASS source guard negative control: unsafe AXI request detected.'

    foreach ($guard in @(
        @{Name='double_buffer_scoreboard'; Argument='+CORRUPT_FRAME'; Pattern='Double-buffer pixel'},
        @{Name='double_buffer_base'; Argument='+STALE_BACK_BASE'; Pattern='AW outside locked Back'}
    )) {
        Write-Host ('Check double-buffer negative control: ' + $guard.Argument)
        Push-Location -LiteralPath (Join-Path $outputPath 'double_buffer')
        try {
            $guardOutput = @(& $vvpExe (Join-Path $outputPath 'double_buffer/graphics.vvp') $guard.Argument)
            $guardExit = $LASTEXITCODE
        } finally { Pop-Location }
        $guardOutput | Set-Content -LiteralPath (
            Join-Path $outputPath ($guard.Name + '_expected_failure.log')
        ) -Encoding UTF8
        if ($guardExit -eq 0 -or -not ($guardOutput -match $guard.Pattern)) {
            throw ('Double-buffer negative control did not reject: ' + $guard.Argument)
        }
        Write-Host ('PASS double-buffer negative control: ' + $guard.Name)
    }

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
        & $PythonExe @pythonArgs (Join-Path $PSScriptRoot 'render_blit_preview.py') `
            (Join-Path $outputPath 'double_buffer') --names 01_source_back 02_source_front `
                03_cleared_back 04_pending_front 05_copy_front 06_return_front 07_overlay_front |
            ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { throw 'Double-buffer PNG preview conversion failed.' }
    } else {
        Write-Host 'PNG previews skipped: optional Python 3 not found. PPMs and RTL checks are available.'
    }
    Write-Host 'PASS independent read arbiter, source guard, graphics dispatcher and double-buffer checks. Formal APB/DDR/HDMI/board integration pending.'
    if (-not $NoWave) {
        Write-Host ('Source guard waveform: ' + (Join-Path $outputPath 'source_guard_1080p/graphics.vcd'))
        Write-Host ('Waveform: ' + (Join-Path $outputPath 'basic/graphics.vcd'))
        Write-Host ('Double-buffer waveform: ' + (Join-Path $outputPath 'double_buffer/graphics.vcd'))
    }
    Write-Host "Log: $logPath"
} finally { Stop-Transcript | Out-Null }
