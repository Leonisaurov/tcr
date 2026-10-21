<#
.SYNOPSIS
    Instala tcr para poder invocarlo como 'tcr' desde cualquier terminal.

.DESCRIPTION
    Crea un lanzador (shim) en una carpeta que ya este en el PATH y, si hace
    falta, anade esa carpeta al PATH del usuario.

    El lanzador apunta al script del repositorio, no a una copia: asi el
    repositorio sigue siendo la unica fuente de verdad y las actualizaciones
    se aplican sin reinstalar.

    Si mueves el repositorio, define la variable de entorno TCR_HOME con la
    nueva ruta (o vuelve a ejecutar este instalador).

.PARAMETER BinDir
    Carpeta donde crear el lanzador. Por defecto, la primera carpeta del PATH
    que este bajo el perfil del usuario, o %USERPROFILE%\.local\bin.

.PARAMETER ConTarea
    Registrar ademas la tarea programada que aplica los limites al iniciar
    sesion. Requiere privilegios de administrador.

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -ConTarea

.EXAMPLE
    .\install.ps1 -BinDir 'C:\tools\bin'
#>
[CmdletBinding()]
param(
    [string]$BinDir,
    [switch]$ConTarea
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
$script  = Join-Path $repoRoot 'tcr.ps1'

if (-not (Test-Path $script)) {
    throw "No se encuentra tcr.ps1 en $repoRoot"
}

# ------------------------------------------------------------- carpeta destino
function Get-DefaultBinDir {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $candidates = @()
    if ($userPath) { $candidates += $userPath -split ';' }
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath) { $candidates += $machinePath -split ';' }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables($c.Trim())
        if ($expanded.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path $expanded)) {
            return $expanded
        }
    }
    return (Join-Path $env:USERPROFILE '.local\bin')
}

if (-not $BinDir) { $BinDir = Get-DefaultBinDir }
$BinDir = [Environment]::ExpandEnvironmentVariables($BinDir.Trim())

Write-Host ''
Write-Host '  tcr - instalador' -ForegroundColor Cyan
Write-Host '  -----------------' -ForegroundColor DarkCyan
Write-Host ''
Write-Host ("  Repositorio : {0}" -f $repoRoot)
Write-Host ("  Script      : {0}" -f $script)
Write-Host ("  Destino     : {0}" -f $BinDir)
Write-Host ''

# --------------------------------------------------------------- crear lanzador
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

$shimPath = Join-Path $BinDir 'tcr.cmd'
$shim = @"
@echo off
REM Lanzador de tcr. Generado por install.ps1; no editar a mano.
setlocal
set "TCR_SCRIPT=%TCR_HOME%\tcr.ps1"
if not exist "%TCR_SCRIPT%" set "TCR_SCRIPT=$script"
if not exist "%TCR_SCRIPT%" (
  echo tcr: no se encuentra tcr.ps1. Define TCR_HOME con la ruta del repositorio.
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%TCR_SCRIPT%" %*
exit /b %ERRORLEVEL%
"@
Set-Content -Path $shimPath -Value $shim -Encoding ASCII
Write-Host ("  Lanzador creado : {0}" -f $shimPath) -ForegroundColor Green

# ------------------------------------------------------------------ anadir PATH
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$inPath = $false
if ($userPath) {
    $inPath = @($userPath -split ';' | Where-Object {
        $_ -and ([Environment]::ExpandEnvironmentVariables($_.Trim()).TrimEnd('\') -ieq $BinDir.TrimEnd('\'))
    }).Count -gt 0
}

if (-not $inPath) {
    $nuevo = if ([string]::IsNullOrWhiteSpace($userPath)) { $BinDir } else { "$userPath;$BinDir" }
    [Environment]::SetEnvironmentVariable('Path', $nuevo, 'User')
    Write-Host ("  PATH de usuario anadido : {0}" -f $BinDir) -ForegroundColor Green
    Write-Host '  Abre una terminal nueva para que el cambio tenga efecto.' -ForegroundColor DarkGray
} else {
    Write-Host ("  El PATH de usuario ya contenia {0}" -f $BinDir) -ForegroundColor DarkGray
}

# -------------------------------------------------------------- tarea programada
if ($ConTarea) {
    Write-Host ''
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) {
        Write-Host '  Para registrar la tarea hace falta ejecutar como administrador.' -ForegroundColor Yellow
        Write-Host '  Vuelve a ejecutar este instalador desde un shell elevado.' -ForegroundColor DarkGray
    } else {
        & $script install
    }
}

# --------------------------------------------------------------------- resumen
Write-Host ''
Write-Host '  Instalacion completada.' -ForegroundColor Green
Write-Host ''
Write-Host '  Prueba:' -ForegroundColor White
Write-Host '    tcr doctor'
Write-Host '    tcr status'
Write-Host ''
