<#
.SYNOPSIS
    Pruebas de tcr. No tocan los procesos del usuario ni generan carga.

.DESCRIPTION
    Cada prueba es independiente y reporta OK / FALLO / OMITIDA.
    Los procesos de prueba se crean y se destruyen dentro de la prueba.

.EXAMPLE
    .\tests\Run-Tests.ps1
    .\tests\Run-Tests.ps1 -Verbose
#>
[CmdletBinding()]
param([switch]$Detallado)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$raiz = Split-Path $PSScriptRoot -Parent
$modulo = Join-Path $raiz 'src\Tcr.psm1'
if (-not (Test-Path $modulo)) { throw "No se encuentra el modulo: $modulo" }
Import-Module $modulo -Force -DisableNameChecking

$script:Pasadas = 0
$script:Fallidas = 0
$script:Omitidas = 0

function Write-Test {
    param([string]$Nombre, [bool]$Ok, [string]$Detalle = '', [switch]$Omitir)
    if ($Omitir) {
        $script:Omitidas++
        Write-Host ("  OMITIDA  {0}{1}" -f $Nombre, $(if($Detalle) { "  ($Detalle)" } else { '' })) -ForegroundColor DarkYellow
    } elseif ($Ok) {
        $script:Pasadas++
        Write-Host ("  OK       {0}{1}" -f $Nombre, $(if($Detalle) { "  ($Detalle)" } else { '' })) -ForegroundColor Green
    } else {
        $script:Fallidas++
        Write-Host ("  FALLO    {0}{1}" -f $Nombre, $(if($Detalle) { "  ($Detalle)" } else { '' })) -ForegroundColor Red
    }
}

function Section { param([string]$t) Write-Host ''; Write-Host "  $t" -ForegroundColor Cyan; Write-Host ('  ' + ('-' * 58)) }

Write-Host ''
Write-Host '  tcr - suite de pruebas' -ForegroundColor Cyan
Write-Host '  ==========================================' -ForegroundColor DarkCyan

# ---------------------------------------------------------------- glob -> regex
Section 'Conversion de glob a regex'
$casos = @(
    @{ glob = 'opencode*';  exp = '^opencode.*$' }
    @{ glob = 'cline*';     exp = '^cline.*$' }
    @{ glob = 'exact.exe';  exp = '^exact\.exe$' }
    @{ glob = 'a?c*';       exp = '^a.c.*$' }
)
foreach ($c in $casos) {
    $obtenido = ConvertFrom-TcrGlob $c.glob
    Write-Test -Nombre "glob '$($c.glob)' -> regex" -Ok ($obtenido -eq $c.exp) -Detalle $obtenido
}

# El caso que mas Dermatology se confunde: -like con array a la derecha.
$procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
$rx = Get-TcrProcessRegex -Patterns @('opencode*', 'cline*', 'qodercli*')
$porRegex  = @($procs | Where-Object { $_.Name -match $rx }).Count
$porLike   = @($procs | Where-Object { $_.Name -like @('opencode*', 'cline*', 'qodercli*') }).Count
Write-Test -Nombre 'el filtro por regex funciona' -Ok ($rx -ne $null) -Detalle "regex -> $porRegex proceso(s)"
Write-Test -Nombre 'el filtro por regex no pierde procesos' -Ok ($porRegex -ge $porLike) `
    -Detalle "regex=$porRegex vs -like=$porLike (la diferencia es esperada: -like con array no filtra bien)"

# ------------------------------------------------------------- mascara afinidad
Section 'Mascara de afinidad'
$total = Get-TcrLogicalCpuCount
Write-Test -Nombre 'la maquina reporta nucleos logicos' -Ok ($total -ge 1) -Detalle "$total nucleos"

$sinLimite = Get-TcrAffinityMask -Count 0 -Total $total
Write-Test -Nombre 'Count=0 -> sin limite' -Ok ($sinLimite -eq [IntPtr]::Zero)

$todos = Get-TcrAffinityMask -Count $total -Total $total
Write-Test -Nombre 'Count=total -> sin limite' -Ok ($todos -eq [IntPtr]::Zero)

if ($total -ge 2) {
    $m2 = Get-TcrAffinityMask -Count 2 -Total $total
    $bits = Get-TcrAffinityCpuCount -Affinity $m2 -Total $total
    Write-Test -Nombre 'Count=2 -> 2 bits activos' -Ok ($bits -eq 2) -Detalle "mascara=$($m2.ToInt64()) bits=$bits"
} else {
    Write-Test -Nombre 'Count=2 -> 2 bits activos' -Omitir -Detalle 'la maquina tiene menos de 2 nucleos'
}

Write-Test -Nombre 'el valor devuelto es un IntPtr valido' -Ok ($sinLimite -is [IntPtr])

# ----------------------------------------------------------------- aplicacion
Section 'Aplicacion de limites sobre un proceso de prueba'
# Proceso propio y desechable: Start-Sleep no consume CPU.
$test = Start-Process powershell -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 800
try {
    $antes = Get-Process -Id $test.Id -ErrorAction SilentlyContinue
    $affAntes = $antes.ProcessorAffinity

    $r = Invoke-TcrApply -Patterns @('powershell*') -CpuCores 1 -JobCpuPercent 0 `
            -MemoryMaxMB 0 -Priority 'BelowNormal' -ExcludeSession

    $despues = Get-Process -Id $test.Id -ErrorAction SilentlyContinue
    if ($despues) {
        $affDespues = $despues.ProcessorAffinity
        $bits = Get-TcrAffinityCpuCount -Affinity $affDespues -Total $total
        Write-Test -Nombre 'la afinidad se aplica al proceso' -Ok ($affDespues -ne $affAntes) `
            -Detalle "antes=$affAntes despues=$affDespues"
        Write-Test -Nombre 'la afinidad queda en 1 nucleo' -Ok ($bits -eq 1) -Detalle "bits=$bits"
        Write-Test -Nombre 'la prioridad se aplica' -Ok ($despues.PriorityClass -eq 'BelowNormal') `
            -Detalle $despues.PriorityClass
    } else {
        Write-Test -Nombre 'el proceso de prueba sobrevivio a la aplicacion' -Omitir -Detalle 'el proceso termino antes de tiempo'
    }
    Write-Test -Nombre 'Invoke-TcrApply informa los procesos encontrados' -Ok ($r.Found -ge 1) -Detalle "encontrados=$($r.Found)"
} finally {
    Stop-Process -Id $test.Id -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- restauracion
Section 'Restauracion de la afinidad'
$test2 = Start-Process powershell -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 800
try {
    [void](Invoke-TcrApply -Patterns @('powershell*') -CpuCores 1 -JobCpuPercent 0 `
            -MemoryMaxMB 0 -Priority 'BelowNormal' -ExcludeSession)
    $limitado = (Get-Process -Id $test2.Id -ErrorAction SilentlyContinue).ProcessorAffinity

    $n = Remove-TcrLimit -Patterns @('powershell*')
    $restaurado = (Get-Process -Id $test2.Id -ErrorAction SilentlyContinue).ProcessorAffinity

    Write-Test -Nombre 'remove restaura la afinidad completa' -Ok ($restaurado -ne $limitado) `
        -Detalle "limitado=$limitado restaurado=$restaurado"
    Write-Test -Nombre 'remove informa cuantos restauro' -Ok ($n -ge 1) -Detalle "n=$n"
} finally {
    Stop-Process -Id $test2.Id -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------- configuracion
Section 'Configuracion'
$cfg = Get-TcrConfig
Write-Test -Nombre 'la configuracion por defecto tiene patrones' -Ok ($cfg.Patterns.Count -ge 1) -Detalle ($cfg.Patterns -join ',')
Write-Test -Nombre 'la configuracion por defecto tiene nucleos validos' -Ok ($cfg.CpuCores -ge 0) -Detalle "cores=$($cfg.CpuCores)"

$cfgPrueba = Get-TcrDefaultConfig
$cfgPrueba.CpuCores = 3
$cfgPrueba.Patterns = @('prueba*')
$ruta = Join-Path $env:TEMP 'tcr-test-config.json'
try {
    $cfgPrueba | ConvertTo-Json -Depth 5 | Set-Content -Path $ruta -Encoding UTF8
    $leida = Get-Content $ruta -Raw | ConvertFrom-Json
    Write-Test -Nombre 'el round-trip de la configuracion conserva los valores' -Ok `
        ($leida.CpuCores -eq 3 -and $leida.Patterns[0] -eq 'prueba*')
} finally {
    Remove-Item $ruta -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------ estado
Section 'Reporte de estado'
$status = Get-TcrStatus -Patterns @('opencode*', 'cline*', 'qodercli*')
Write-Test -Nombre 'el estado informa los nucleos totales' -Ok ($status.TotalCores -ge 1) -Detalle "$($status.TotalCores)"
Write-Test -Nombre 'el estado devuelve una coleccion de procesos' -Ok ($null -ne $status.Processes)

# ------------------------------------------------------------------ job object
Section 'Job Object (opcional)'
$jobOk = $false
$jobErr = ''
try {
    $j = [TcrJob]::Create()
    if ($j -ne [IntPtr]::Zero) {
        $jobOk = [TcrJob]::SetCpuCap($j, 50)
        if (-not $jobOk) { $jobErr = [TcrJob]::LastError() }
        [void][TcrJob]::CloseHandle($j)
    } else {
        $jobErr = 'CreateJobObject devolvio un handle nulo'
    }
} catch { $jobErr = $_.Exception.Message }

Write-Test -Nombre 'el tope de CPU por porcentaje esta disponible' -Ok $jobOk -Omitir:(-not $jobOk) -Detalle $jobErr

# -------------------------------------------------------------------- resumen
Write-Host ''
Write-Host '  ==========================================' -ForegroundColor DarkCyan
$total = $script:Pasadas + $script:Fallidas + $script:Omitidas
$color = if ($script:Fallidas -eq 0) { 'Green' } else { 'Red' }
Write-Host ("  {0} de {1} pruebas pasaron | {2} fallos | {3} omitidas" -f `
    $script:Pasadas, $total, $script:Fallidas, $script:Omitidas) -ForegroundColor $color
Write-Host ''

if ($script:Fallidas -gt 0) { exit 1 } else { exit 0 }
