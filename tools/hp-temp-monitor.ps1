<#
.SYNOPSIS
    Monitor de temperatura para laptops HP con zona termica ACPI.

.DESCRIPTION
    Muestra la temperatura del chasis (zona ACPI THRM) y la del procesador leida
    del sensor interno de HP a traves de WMI (root\wmi:hpqBIntM, comando 0x28).

    Es de solo lectura: no genera carga ni modifica nada.

    La lectura del sensor interno de HP no esta disponible en todas las
    maquinas. Si la zona ACPI no existe, se muestra "n/d".

    REQUIERE PRIVILEGIOS DE ADMINISTRADOR: las zonas termicas ACPI solo son
    legibles por un proceso elevado. Sin ellos las temperaturas salen "n/d".
    Usa "Ejecutar como administrador" o un shell elevada.

.PARAMETER Seconds
    Duracion del monitorizado en segundos. Por defecto 60.

.PARAMETER Interval
    Segundos entre muestras. Por defecto 2.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\hp-temp-monitor.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\hp-temp-monitor.ps1 -Seconds 300
#>
param(
    [int]$Seconds = 60,
    [int]$Interval = 2
)

$ErrorActionPreference = 'Continue'

function Get-THRM {
    try {
        $z = Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop |
             Where-Object { $_.InstanceName -like '*THRM*' } | Select-Object -First 1
        if ($z) { return [math]::Round(($z.CurrentTemperature / 10) - 273.15, 1) }
    } catch {}
    return $null
}

function Get-CpuTemp {
    # Sensor interno de HP via WMI BIOS (root\wmi:hpqBIntM, comando 0x28 prefijo 0x00)
    try {
        $m = Get-CimInstance -Namespace root\wmi -ClassName hpqBIntM -ErrorAction Stop |
             Where-Object { $_.InstanceName -like 'ACPI\PNP0C14\0_0' } | Select-Object -First 1
        if ($m) {
            $props = @{
                Sign        = [byte[]]@(0x53, 0x45, 0x43, 0x55)
                Command     = [uint32]1
                CommandType = [uint32]0x28
                Size        = [uint32]4
                hpqBData    = [byte[]]@(0x00, 0, 0, 0)
            }
            $in = New-CimInstance -Namespace root\wmi -ClassName hpqBDataIn -ClientOnly -Property $props
            $r = Invoke-CimMethod -InputObject $m -MethodName 'hpqBIOSInt128' -Arguments @{ InData = [CimInstance]$in }
            if ($r.OutData.rwReturnCode -eq 0) { return $r.OutData.Data[1] }
        }
    } catch {}
    return $null
}

Write-Host ""
Write-Host "  Monitor de temperatura - HP 255R 15.6 G10" -ForegroundColor Cyan
Write-Host "  Ctrl+C para salir" -ForegroundColor DarkGray

# Las zonas termicas ACPI solo son legibles con privilegios elevados.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "  AVISO: sin privilegios de administrador las temperaturas saldran 'n/d'." -ForegroundColor Yellow
    Write-Host "         Ejecuta este script como administrador." -ForegroundColor DarkGray
}
Write-Host ""
Write-Host ("  {0,-9} {1,-10} {2,-10} {3,-8}" -f 'Hora', 'Chassis', 'CPU HP', 'Carga%') -ForegroundColor White
Write-Host ("  " + ('-' * 42))

$end = (Get-Date).AddSeconds($Seconds)
$peakC = 0; $peakT = 0
while ((Get-Date) -lt $end) {
    $t = Get-THRM
    $c = Get-CpuTemp
    $load = (Get-CimInstance Win32_Processor).LoadPercentage
    if ($t -and $t -gt $peakT) { $peakT = $t }
    if ($c -and $c -gt $peakC) { $peakC = $c }

    $col = 'Gray'
    if ($t -and $t -ge 80) { $col = 'Red' }
    elseif ($t -and $t -ge 70) { $col = 'Yellow' }

    Write-Host ("  {0,-9} {1,-10} {2,-10} {3,-8}" -f (Get-Date -Format 'HH:mm:ss'),
        $(if ($t) { "$t C" } else { 'n/d' }),
        $(if ($c) { "$c C" } else { 'n/d' }),
        "$load%") -ForegroundColor $col

    Start-Sleep -Seconds $Interval
}

Write-Host ("  " + ('-' * 42))
Write-Host ("  PEAK:  Chassis {0} C   CPU {1} C" -f $peakT, $peakC) -ForegroundColor Yellow
Write-Host ""
