[CmdletBinding()]
param(
    [string]$OutputDir = '',
    [string]$PythonExe = '',
    [switch]$NoWave
)

$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDir) { $OutputDir = Join-Path $taskRoot 'output/graphics/color_key' }
$iverilogExe = (Get-Command iverilog -ErrorAction Stop).Source
$vvpExe = (Get-Command vvp -ErrorAction Stop).Source
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$outputPath = (Resolve-Path -LiteralPath $OutputDir).Path
$sourcePaths = @(
    'sim/tb_color_key_blit.v', 'sim/tb_blit_engine.v',
    'rtl/accelerator/color_key_blit_engine.v', 'rtl/accelerator/blit_engine.v'
) | ForEach-Object { Join-Path $taskRoot $_ }

function Invoke-ColorKeySimulation {
    param([string]$Name, [string[]]$Overrides, [switch]$Wave)
    $caseDir = Join-Path $outputPath $Name
    New-Item -ItemType Directory -Path $caseDir -Force | Out-Null
    $binaryPath = Join-Path $caseDir 'color_key.vvp'
    $compileArgs = @('-g2005-sv', '-Wall', '-s', 'tb_color_key_blit') + $Overrides +
        @('-o', $binaryPath) + $sourcePaths
    Write-Host "Compile/run: $Name"
    & $iverilogExe @compileArgs
    if ($LASTEXITCODE -ne 0) { throw "Compilation failed: $Name" }
    Push-Location -LiteralPath $caseDir
    try {
        $runtimeArgs = @($binaryPath)
        if ($Wave) { $runtimeArgs += '+VCD' }
        $sawPass = $false
        & $vvpExe @runtimeArgs | ForEach-Object {
            Write-Host $_
            if ($_ -match '^PASS COLOR KEY:') { $sawPass = $true }
        }
        if ($LASTEXITCODE -ne 0 -or -not $sawPass) { throw "Simulation failed: $Name" }
        if ($Wave) {
            $waveFile = Join-Path $caseDir 'color_key.vcd'
            if (-not (Test-Path -LiteralPath $waveFile) -or (Get-Item -LiteralPath $waveFile).Length -eq 0) {
                throw 'Expected waveform was not generated.'
            }
        }
    } finally { Pop-Location }
}

$logPath = Join-Path $outputPath 'color_key.log'
Start-Transcript -Path $logPath -Force | Out-Null
try {
    Write-Host "Icarus: $iverilogExe"
    Write-Host "Artifacts: $outputPath"
    Invoke-ColorKeySimulation -Name 'basic' -Overrides @() -Wave:(-not $NoWave)
    Invoke-ColorKeySimulation -Name 'boundaries' -Overrides @('-Ptb_color_key_blit.FRAME_WIDTH=1088')
    Invoke-ColorKeySimulation -Name 'single_beat' -Overrides @('-Ptb_color_key_blit.MAX_BURST_BEATS=1')

    # Prove the reference-pixel checker catches incorrect data, not just DONE.
    Push-Location -LiteralPath (Join-Path $outputPath 'basic')
    try {
        $guardOutput = @(& $vvpExe (Join-Path $outputPath 'basic/color_key.vvp') '+CORRUPT_WRITE')
        $guardExit = $LASTEXITCODE
    } finally { Pop-Location }
    $guardOutput | Set-Content -LiteralPath (Join-Path $outputPath 'scoreboard_expected_failure.log') -Encoding UTF8
    if ($guardExit -eq 0 -or -not ($guardOutput -match 'Target pixel')) {
        throw 'The pixel checker did not detect the deliberately corrupted write.'
    }
    Write-Host 'PASS negative control: incorrect pixel rejected as expected.'

    $pythonArgs = @()
    if (-not $PythonExe) {
        foreach ($candidate in @('py', 'python', 'python3')) {
            $pythonCommand = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue
            if (-not $pythonCommand) { continue }
            $candidateArgs = @()
            if ($candidate -eq 'py') { $candidateArgs = @('-3') }
            try {
                $probeOutput = @(& $pythonCommand.Source @candidateArgs --version 2>&1)
                if ($LASTEXITCODE -eq 0 -and ($probeOutput -match '^Python 3\.')) {
                    $PythonExe = $pythonCommand.Source; $pythonArgs = $candidateArgs; break
                }
            } catch { }
        }
    }
    if ($PythonExe) {
        & $PythonExe @pythonArgs (Join-Path $PSScriptRoot 'render_blit_preview.py') (Join-Path $outputPath 'basic') `
            --names sprite_source background opaque_copy color_key_copy | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { throw 'PNG preview conversion failed.' }
    } else {
        Write-Host 'PNG conversion skipped: optional Python 3 not found; PPM pixels remain available.'
    }
    Write-Host 'PASS all color-key unit simulations. Formal v4 APB/top integration and board validation are pending.'
    Write-Host "Log: $logPath"
} finally { Stop-Transcript | Out-Null }
