<#
.SYNOPSIS
    tcr - Tool for Constraining Resources.

.DESCRIPTION
    Limita el uso de CPU y memoria de herramientas locales (agentes de IA, IDEs,
    compiladores) en Windows, sin instalar nada y sin procesos de fondo.

    Mecanismos:
      * Afinidad de CPU: restringe cada proceso a un numero de nucleos logicos.
        Es el metodo principal: instantaneo, no requiere demonio y funciona
        aunque el proceso ya pertenezca a otro Job Object.
      * Job Object: tope real de CPU por porcentaje y limite de memoria por
        proceso. Opcional, requiere que el proceso no este ya en otro job.
      * Prioridad: BelowNormal hace que el planificador ceda CPU antes a tus
        aplicaciones que a las herramientas limitadas.

.EXAMPLE
    tcr apply -Cores 2
    Aplica los limites guardados (o los de por defecto) de inmediato.

.EXAMPLE
    tcr apply -Patterns 'opencode*','node*' -Cores 2 -Priority BelowNormal
    Aplica limites a patrones concretos y los guarda como configuracion.

.EXAMPLE
    tcr status
    Muestra el estado actual de los limites y de la tarea programada.

.EXAMPLE
    tcr install
    Instala una tarea programada que aplica los limites al iniciar sesion.

.EXAMPLE
    tcr remove
    Retira los limites de todos los procesos y restaura la afinidad completa.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('apply', 'status', 'remove', 'install', 'uninstall', 'watch', 'doctor', 'help')]
    [string]$Command = 'help',

    # Que procesos limitar (patrones glob). Por defecto: opencode*, cline*, qodercli*
    [string[]]$Patterns,

    # Cuantos nucleos logicos puede usar cada proceso. 0 = sin limite.
    [int]$Cores = -1,

    # Tope de CPU por porcentaje real (1-100) via Job Object. 0 = no usar.
    [int]$JobCpu = -1,

    # Memoria maxima por proceso en MB. 0 = sin limite.
    [int]$MemoryMaxMB = -1,

    # Prioridad del proceso: Normal, BelowNormal, Idle.
    [ValidateSet('Normal', 'BelowNormal', 'Idle')]
    [string]$Priority,

    # Ruta alterna de configuracion.
    [string]$ConfigPath,

    # Intervalo del modo vigilancia, en segundos.
    [int]$Interval = -1,

    # No limitar la sesion actual ni sus procesos ancestros.
    [switch]$ExcludeSession,

    # Limitar tambien la sesion actual (lo contrario de -ExcludeSession).
    [switch]$IncludeSession
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'src\Tcr.psm1'
if (-not (Test-Path $modulePath)) {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Tcr.psm1'
}
Import-Module $modulePath -Force -DisableNameChecking

# --------------------------------------------------------------- configuracion
$config = Get-TcrConfig
if ($ConfigPath) { $config.ConfigPath = $ConfigPath }

$changed = $false
if ($PSBoundParameters.ContainsKey('Patterns') -and $Patterns) { $config.Patterns = $Patterns; $changed = $true }
if ($PSBoundParameters.ContainsKey('Cores')       -and $Cores -ge 0) { $config.CpuCores = $Cores; $changed = $true }
if ($PSBoundParameters.ContainsKey('JobCpu')      -and $JobCpu -ge 0) { $config.JobCpuPercent = $JobCpu; $changed = $true }
if ($PSBoundParameters.ContainsKey('MemoryMaxMB') -and $MemoryMaxMB -ge 0) { $config.MemoryMaxMB = $MemoryMaxMB; $changed = $true }
if ($PSBoundParameters.ContainsKey('Priority'))  { $config.Priority = $Priority; $changed = $true }
if ($PSBoundParameters.ContainsKey('Interval')   -and $Interval -ge 1) { $config.WatchIntervalSec = $Interval; $changed = $true }
if ($IncludeSession) { $config.ExcludeSession = $false; $changed = $true }
if ($ExcludeSession) { $config.ExcludeSession = $true;  $changed = $true }

function Show-TcrHeader {
    Write-Host ''
    Write-Host '  tcr - Tool for Constraining Resources' -ForegroundColor Cyan
    Write-Host '  -----------------------------------------' -ForegroundColor DarkCyan
}

function Show-TcrHelp {
    Show-TcrHeader
    Write-Host ''
    Write-Host '  USO' -ForegroundColor White
    Write-Host '    tcr apply      [-Patterns <glob>] [-Cores <n>] [-JobCpu <pct>] [-MemoryMaxMB <mb>] [-Priority <p>]'
    Write-Host '    tcr status     [-Patterns <glob>]'
    Write-Host '    tcr remove     [-Patterns <glob>]'
    Write-Host '    tcr install    [-Patterns <glob>] [-Cores <n>] ...'
    Write-Host '    tcr uninstall'
    Write-Host '    tcr watch      [-Interval <seg>]'
    Write-Host '    tcr doctor'
    Write-Host ''
    Write-Host '  OPCIONES' -ForegroundColor White
    Write-Host '    -Patterns      Patrones glob de los procesos a limitar.'
    Write-Host '                   Por defecto: opencode*, cline*, qodercli*'
    Write-Host '    -Cores         Nucleos logicos por proceso (0 = sin limite).'
    Write-Host '                   2 de 8 nucleos = maximo 25% de CPU.'
    Write-Host '    -JobCpu        Tope de CPU por porcentaje via Job Object (1-100).'
    Write-Host '                   Solo aplica a procesos que no esten en otro job.'
    Write-Host '    -MemoryMaxMB   Memoria maxima por proceso en MB.'
    Write-Host '    -Priority      Normal | BelowNormal | Idle. Por defecto BelowNormal.'
    Write-Host '    -Interval      Segundos entre rondas del modo vigilancia.'
    Write-Host '    -ExcludeSession  No limita la sesion actual ni sus ancestros.'
    Write-Host '    -IncludeSession  Si limita tambien la sesion actual.'
    Write-Host ''
    Write-Host '  EJEMPLOS' -ForegroundColor White
    Write-Host '    tcr apply -Cores 2'
    Write-Host '    tcr apply -Patterns ''opencode*'',''node*'' -Cores 2 -MemoryMaxMB 1500'
    Write-Host '    tcr install -Cores 2 -Interval 5'
    Write-Host '    tcr remove'
    Write-Host ''
}

# ------------------------------------------------------------------------ sub
switch ($Command) {

    'help' {
        Show-TcrHelp
        break
    }

    'apply' {
        Show-TcrHeader
        if ($changed) { Save-TcrConfig -Config $config }
        Write-Host ''
        $total = Get-TcrLogicalCpuCount
        Write-Host ("  Nucleos por proceso : {0}" -f $(if($config.CpuCores -gt 0) { "$($config.CpuCores) de $total" } else { 'sin limite' }))
        Write-Host ("  Limite de CPU       : {0}" -f $(if($config.CpuCores -gt 0) { "max $([math]::Round($config.CpuCores / $total * 100))% de la maquina ($($config.CpuCores)/$total nucleos)" } else { 'sin limite' }))
        Write-Host ("  Tope Job Object      : {0}" -f $(if($config.JobCpuPercent -gt 0) { "$($config.JobCpuPercent)%" } else { 'no' }))
        Write-Host ("  Memoria por proceso  : {0}" -f $(if($config.MemoryMaxMB -gt 0) { "$($config.MemoryMaxMB) MB" } else { 'sin limite' }))
        Write-Host ("  Prioridad            : {0}" -f $config.Priority)
        Write-Host ("  Excluir sesion       : {0}" -f $config.ExcludeSession)
        Write-Host ("  Procesos             : {0}" -f ($config.Patterns -join ', '))
        Write-Host ''

        $result = Invoke-TcrApply `
            -Patterns $config.Patterns `
            -CpuCores $config.CpuCores `
            -JobCpuPercent $config.JobCpuPercent `
            -MemoryMaxMB $config.MemoryMaxMB `
            -Priority $config.Priority `
            -ExcludeSession:([bool]$config.ExcludeSession)

        Write-Host ("  Procesos encontrados : {0}" -f $result.Found) -ForegroundColor White
        Write-Host ("  Con limite aplicado  : {0}" -f $result.Limited) -ForegroundColor Green
        if ($result.JobRejected -gt 0) {
            Write-Host ("  Sin tope de Job Object: {0} (ya estaban en otro job; la afinidad de CPU si aplica)" -f $result.JobRejected) -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host '  Estado: tcr status    |   Deshacer: tcr remove' -ForegroundColor DarkGray
        Write-Host ''
        break
    }

    'status' {
        Show-TcrHeader
        $status = Get-TcrStatus -Patterns $config.Patterns
        Write-Host ''
        Write-Host ("  Nucleos logicos de la maquina : {0}" -f $status.TotalCores)
        if ($status.Task) {
            Write-Host ("  Tarea programada : {0}   ultimo resultado: {1}" -f $status.Task.State, $status.Task.LastResult) -ForegroundColor Green
        } else {
            Write-Host '  Tarea programada : no instalada' -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host '  Proceso             PID     Nucleos   CPU max   Memoria   Prioridad' -ForegroundColor White
        Write-Host '  -----------------------------------------------------' -ForegroundColor DarkGray
        if (-not $status.Processes -or $status.Processes.Count -eq 0) {
            Write-Host '  (ninguno en ejecucion)' -ForegroundColor DarkGray
        } else {
            foreach ($p in $status.Processes) {
                Write-Host ("  {0,-18} {1,-7} {2}/{3,-6} {4,6}%   {5,6} MB   {6}" -f `
                    $p.Name, $p.Pid, $p.Cores, $status.TotalCores, $p.CpuLimit, $p.MemMB, $p.Priority)
            }
        }
        Write-Host ''
        Write-Host ("  Registro: {0}" -f (Get-TcrLogPath)) -ForegroundColor DarkGray
        Write-Host ''
        break
    }

    'remove' {
        Show-TcrHeader
        Write-Host ''
        $n = Remove-TcrLimit -Patterns $config.Patterns
        Write-Host ("  {0} proceso(s) restaurados a afinidad completa y prioridad Normal." -f $n) -ForegroundColor Green
        Write-Host ''
        break
    }

    'install' {
        Show-TcrHeader
        if ($changed) { Save-TcrConfig -Config $config }
        $self = $PSCommandPath
        if (-not $self) { $self = Join-Path $PSScriptRoot 'tcr.ps1' }
        Install-TcrTask -ScriptPath $self -Config $config | Out-Null
        Write-Host ''
        Write-Host ("  Tarea programada '{0}' instalada." -f (Get-TcrTaskName)) -ForegroundColor Green
        Write-Host '  Se aplica al iniciar sesion y mantiene los limites activos.' -ForegroundColor DarkGray
        Write-Host '  Para retirar: tcr uninstall' -ForegroundColor DarkGray
        Write-Host ''
        break
    }

    'uninstall' {
        Show-TcrHeader
        Write-Host ''
        $existed = Uninstall-TcrTask
        $n = Remove-TcrLimit -Patterns $config.Patterns
        if ($existed) { Write-Host '  Tarea programada retirada.' -ForegroundColor Green }
        else { Write-Host '  No habia tarea programada instalada.' -ForegroundColor DarkGray }
        Write-Host ("  {0} proceso(s) restaurados." -f $n) -ForegroundColor Green
        Write-Host ''
        break
    }

    'watch' {
        # Modo daemon: reaplica los limites a los procesos que van apareciendo.
        $cfg = Get-TcrConfig
        if ($changed) { Save-TcrConfig -Config $config; $cfg = $config }
        Write-TcrLog "vigilando: cores=$($cfg.CpuCores) jobCpu=$($cfg.JobCpuPercent) mem=$($cfg.MemoryMaxMB) prio=$($cfg.Priority) intervalo=$($cfg.WatchIntervalSec)s"
        while ($true) {
            try {
                Invoke-TcrApply `
                    -Patterns $cfg.Patterns `
                    -CpuCores $cfg.CpuCores `
                    -JobCpuPercent $cfg.JobCpuPercent `
                    -MemoryMaxMB $cfg.MemoryMaxMB `
                    -Priority $cfg.Priority `
                    -ExcludeSession:([bool]$cfg.ExcludeSession) | Out-Null
            } catch {
                Write-TcrLog "error en el ciclo de vigilancia: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds $cfg.WatchIntervalSec
        }
        break
    }

    'doctor' {
        Show-TcrHeader
        Write-Host ''
        $total = Get-TcrLogicalCpuCount
        Write-Host ("  Nucleos logicos            : {0}" -f $total)
        Write-Host ("  PowerShell                 : {0}" -f $PSVersionTable.PSVersion)
        Write-Host ("  Sistema                    : {0}" -f [System.Environment]::OSVersion.VersionString)
        $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Write-Host ("  Ejecutando como administrador: {0}" -f $admin) -ForegroundColor $(if($admin){'Green'}else{'Yellow'})
        if (-not $admin) {
            Write-Host '    Recomendado: ejecutar como administrador para poder aplicar limites' -ForegroundColor DarkGray
            Write-Host '    a otros usuarios y registrar la tarea programada.' -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host '  Capacidades comprobadas:' -ForegroundColor White
        Write-Host ("    Job Object (CreateJobObject)   : {0}" -f $(try { $j = [TcrJob]::Create(); if ($j -eq [IntPtr]::Zero) { 'no disponible' } else { [void][TcrJob]::CloseHandle($j); 'disponible' } } catch { 'no disponible' }))
        Write-Host ("    Tope de CPU por porcentaje    : {0}" -f $(try { $j = [TcrJob]::Create(); $ok = [TcrJob]::SetCpuCap($j, 50); [void][TcrJob]::CloseHandle($j); if ($ok) { 'disponible' } else { 'rechazado por el firmware' } } catch { 'no disponible' }))
        Write-Host ("    Tareas programadas            : {0}" -f $(try {
            $null = Get-ScheduledTask -TaskName 'tcr' -ErrorAction Stop
            'disponibles (tarea de tcr instalada)'
        } catch [Microsoft.PowerShell.CmdletInvocationException] {
            'disponibles (sin tarea de tcr instalada)'
        } catch {
            'no comprobables: se necesitan privilegios de administrador'
        }))
        Write-Host ''
        Write-Host '  Procesos monitorizados:' -ForegroundColor White
        $status = Get-TcrStatus -Patterns $config.Patterns
        if (-not $status.Processes -or $status.Processes.Count -eq 0) {
            Write-Host '    (ninguno en ejecucion)' -ForegroundColor DarkGray
        } else {
            foreach ($p in $status.Processes) {
                Write-Host ("    {0,-18} PID {1,-7} nucleos {2}/{3}  prio {4}" -f $p.Name, $p.Pid, $p.Cores, $status.TotalCores, $p.Priority)
            }
        }
        Write-Host ''
        break
    }
}
