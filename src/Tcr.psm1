<#
.SYNOPSIS
    Modulo interno de tcr (Tool for Constraining Resources).

.DESCRIPTION
    Contiene toda la logica: descubrimiento de procesos, calculo de mascaras de
    afinidad, aplicacion y retirada de limites, instalacion de la tarea
    programada y reporte de estado.

    No invocar directamente: use tcr.ps1.
#>

Set-StrictMode -Version Latest

# --------------------------------------------------------------- rutas globales
$script:TcrDataDir = Join-Path $env:LOCALAPPDATA 'tcr'
$script:TcrConfig  = Join-Path $script:TcrDataDir 'config.json'
$script:TcrLog     = Join-Path $script:TcrDataDir 'tcr.log'
$script:TcrTaskName = 'tcr'

# --------------------------------------------------------------- utilidades
function Write-TcrLog {
    param([Parameter(Mandatory)][string]$Message)
    try {
        New-Item -ItemType Directory -Force -Path $script:TcrDataDir | Out-Null
        Add-Content -Path $script:TcrLog -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    } catch { }
}

function Get-TcrDataDir { $script:TcrDataDir }
function Get-TcrConfigPath { $script:TcrConfig }
function Get-TcrLogPath { $script:TcrLog }
function Get-TcrTaskName { $script:TcrTaskName }

function Get-TcrLogicalCpuCount {
    try { return [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors }
    catch { return [int][Environment]::ProcessorCount }
}

<#
    Convierte un patron glob a regex.
    '*' -> cualquier secuencia, '?' -> un unico caracter.
    Se usa regex porque el operador -like de PowerShell NO acepta un array de
    patrones en el lado derecho (comportamiento silencioso y facil de confundir).
#>
function ConvertFrom-TcrGlob {
    param([Parameter(Mandatory)][string]$Glob)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Glob.ToCharArray()) {
        switch ($ch) {
            '*' { [void]$sb.Append('.*') }
            '?' { [void]$sb.Append('.')  }
            default { [void]$sb.Append([regex]::Escape([string]$ch)) }
        }
    }
    return '^' + $sb.ToString() + '$'
}

function Get-TcrProcessRegex {
    param([string[]]$Patterns)
    if (-not $Patterns -or $Patterns.Count -eq 0) { return $null }
    return (($Patterns | ForEach-Object { ConvertFrom-TcrGlob $_ }) -join '|')
}

<#
    Devuelve los procesos que coinciden con los patrones.
    -ExcludeSession: descarta la sesion actual y todos sus ancestros, para no
    auto-limitar el proceso que nos hospeda.
#>
function Get-TcrTargetProcess {
    param(
        [string[]]$Patterns,
        [switch]$ExcludeSession
    )
    $rx = Get-TcrProcessRegex -Patterns $Patterns
    if (-not $rx) { return @() }

    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match $rx })

    if ($ExcludeSession) {
        $excluded = New-Object 'System.Collections.Generic.HashSet[int]'
        $current = $PID
        for ($i = 0; $i -lt 12 -and $current -gt 0; $i++) {
            [void]$excluded.Add($current)
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
            if (-not $proc -or -not $proc.ParentProcessId) { break }
            $current = $proc.ParentProcessId
        }
        $all = @($all | Where-Object { -not $excluded.Contains([int]$_.ProcessId) })
    }
    return $all
}

<#
    Construye la mascara de afinidad para los primeros $Count nucleos logicos.
    Devuelve IntPtr::Zero cuando no hay limite (0 o todos los nucleos).
#>
function Get-TcrAffinityMask {
    param([int]$Count, [int]$Total)
    if ($Count -le 0 -or $Count -ge $Total) { return [IntPtr]::Zero }
    $mask = [int64]0
    for ($i = 0; $i -lt $Count; $i++) { $mask = $mask -bor ([int64]1 -shl $i) }
    return [IntPtr]$mask
}

<#
    Mascara que habilita TODOS los nucleos. A diferencia de Get-TcrAffinityMask,
    esta si devuelve un valor utilizable: es la que se usa para restaurar.
    Devuelve IntPtr::Zero si la maquina tiene mas de 64 nucleos, caso en el que
    no se puede representar la mascara completa.
#>
function Get-TcrFullAffinityMask {
    param([int]$Total)
    if ($Total -le 0 -or $Total -gt 64) { return [IntPtr]::Zero }
    $mask = [int64]0
    for ($i = 0; $i -lt $Total; $i++) { $mask = $mask -bor ([int64]1 -shl $i) }
    return [IntPtr]$mask
}

function Get-TcrAffinityCpuCount {
    param([IntPtr]$Affinity, [int]$Total)
    $value = $Affinity.ToInt64()
    if ($value -eq 0) { return 0 }
    $count = 0
    for ($i = 0; $i -lt $Total; $i++) {
        if ($value -band ([int64]1 -shl $i)) { $count++ }
    }
    return $count
}

# ------------------------------------------------------- Job Object (opcional)
if (-not ('TcrJob' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class TcrJob {
    // La estructura que acepta SetInformationJobObject para
    // JobObjectCpuRateControlInformation debe medir EXACTAMENTE 8 bytes.
    // Con un campo Reserved adicional (12 bytes) la llamada falla con
    // ERROR_BAD_LENGTH. Verificado empiricamente en Windows 11 26xxx.
    [StructLayout(LayoutKind.Sequential)]
    public struct CpuRateControl {
        public uint ControlFlags;
        public uint CpuRate;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct BasicLimit {
        public long  PerProcessUserTimeLimit;
        public long  PerJobUserTimeLimit;
        public uint  LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint  ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint  PriorityClass;
        public uint  SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct IoCounters {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount,
                    ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ExtendedLimit {
        public BasicLimit BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateJobObject(IntPtr attrs, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetInformationJobObject(IntPtr job, int cls, IntPtr info, uint len);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr handle);

    public const uint ProcessSetQuota   = 0x0100;
    public const uint ProcessTerminate   = 0x0001;
    public const uint ProcessQueryInfo  = 0x0400;

    public const int JobObjectExtendedLimitInformation   = 9;
    public const int JobObjectCpuRateControlInformation = 15;

    public const uint CpuEnable   = 0x0001;
    public const uint CpuHardCap  = 0x0004;
    public const uint LimitJobMemory     = 0x0200;
    public const uint LimitProcessMemory = 0x0100;

    public static IntPtr Create() { return CreateJobObject(IntPtr.Zero, null); }

    // pct = 1..100 de la maquina completa.
    public static bool SetCpuCap(IntPtr job, uint pct) {
        CpuRateControl c = new CpuRateControl();
        c.ControlFlags = CpuEnable | CpuHardCap;
        c.CpuRate = pct * 100;               // 1% = 100
        int size = Marshal.SizeOf(typeof(CpuRateControl));
        IntPtr p = Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(c, p, false);
            return SetInformationJobObject(job, JobObjectCpuRateControlInformation, p, (uint)size);
        } finally { Marshal.FreeHGlobal(p); }
    }

    public static bool SetMemoryLimit(IntPtr job, ulong perProcessBytes, ulong jobBytes) {
        ExtendedLimit e = new ExtendedLimit();
        e.BasicLimitInformation.LimitFlags = LimitJobMemory | LimitProcessMemory;
        e.ProcessMemoryLimit = (UIntPtr)perProcessBytes;
        e.JobMemoryLimit = (UIntPtr)jobBytes;
        int size = Marshal.SizeOf(typeof(ExtendedLimit));
        IntPtr p = Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(e, p, false);
            return SetInformationJobObject(job, JobObjectExtendedLimitInformation, p, (uint)size);
        } finally { Marshal.FreeHGlobal(p); }
    }

    public static bool Assign(IntPtr job, uint pid) {
        IntPtr h = OpenProcess(ProcessSetQuota | ProcessTerminate | ProcessQueryInfo, false, pid);
        if (h == IntPtr.Zero) return false;
        try { return AssignProcessToJobObject(job, h); }
        finally { CloseHandle(h); }
    }

    public static string LastError() {
        return new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()).Message;
    }
}
'@
}

# ---------------------------------------------------------------- configuracion
function Get-TcrDefaultConfig {
    @{
        Patterns        = @('opencode*', 'cline*', 'qodercli*')
        CpuCores        = 2
        JobCpuPercent   = 0
        MemoryMaxMB     = 0
        Priority        = 'BelowNormal'
        ExcludeSession  = $true
        WatchIntervalSec = 10
    }
}

function Get-TcrConfig {
    if (Test-Path $script:TcrConfig) {
        try {
            $raw = Get-Content $script:TcrConfig -Raw | ConvertFrom-Json
            $cfg = Get-TcrDefaultConfig
            foreach ($p in $cfg.Keys) {
                if ($raw.PSObject.Properties.Name -contains $p) { $cfg[$p] = $raw.$p }
            }
            return $cfg
        } catch {
            Write-TcrLog "configuracion ilegible, se usan los valores por defecto: $($_.Exception.Message)"
        }
    }
    return Get-TcrDefaultConfig
}

function Save-TcrConfig {
    param([Parameter(Mandatory)]$Config)
    New-Item -ItemType Directory -Force -Path $script:TcrDataDir | Out-Null
    $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $script:TcrConfig -Encoding UTF8
}

# ------------------------------------------------------------------ aplicacion
<#
    Aplica los limites a los procesos indicados.
    Devuelve un objeto con el detalle de lo aplicado.
#>
function Invoke-TcrApply {
    param(
        [string[]]$Patterns,
        [int]$CpuCores,
        [int]$JobCpuPercent,
        [int]$MemoryMaxMB,
        [string]$Priority,
        [switch]$ExcludeSession
    )
    $total = Get-TcrLogicalCpuCount
    $mask  = Get-TcrAffinityMask -Count $CpuCores -Total $total

    $job = $null
    if ($JobCpuPercent -gt 0 -or $MemoryMaxMB -gt 0) {
        $job = [TcrJob]::Create()
        if ($job -eq [IntPtr]::Zero) {
            Write-TcrLog 'no se pudo crear el Job Object'
        } else {
            if ($JobCpuPercent -gt 0) {
                if ([TcrJob]::SetCpuCap($job, [uint32]$JobCpuPercent)) {
                    Write-TcrLog "job: tope de CPU $JobCpuPercent% aplicado"
                } else {
                    Write-TcrLog "job: ERROR al fijar el tope de CPU - $([TcrJob]::LastError())"
                }
            }
            if ($MemoryMaxMB -gt 0) {
                $per  = [uint64]$MemoryMaxMB * 1MB
                $all  = [uint64]$MemoryMaxMB * 1MB * 8
                if ([TcrJob]::SetMemoryLimit($job, $per, $all)) {
                    Write-TcrLog "job: limite de memoria $MemoryMaxMB MB por proceso aplicado"
                } else {
                    Write-TcrLog "job: ERROR al fijar el limite de memoria - $([TcrJob]::LastError())"
                }
            }
        }
    }

    $found = 0; $limited = 0; $jobFailed = 0
    foreach ($p in @(Get-TcrTargetProcess -Patterns $Patterns -ExcludeSession:$ExcludeSession)) {
        $found++
        $proc = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if (-not $proc) { continue }

        $applied = $false
        if ($mask -ne [IntPtr]::Zero) {
            try { $proc.ProcessorAffinity = $mask; $applied = $true } catch { }
        }
        if ($Priority -and $Priority -ne 'Normal') {
            try { $proc.PriorityClass = $Priority } catch { }
            if (-not $applied) { $applied = $true }
        }
        if ($applied) { $limited++ }

        if ($job -ne $null) {
            $assigned = $false
            try { $assigned = [TcrJob]::Assign($job, [uint32]$p.ProcessId) } catch { }
            if (-not $assigned) {
                # ACCESS_DENIED: el proceso ya pertenece a otro Job Object.
                # Un proceso no puede salir de un job, asi que el limite por
                # porcentaje no es aplicable en ese caso. No es un error fatal:
                # la afinidad de CPU sigue garantizando el limite de forma
                # efectiva.
                $jobFailed++
                Write-TcrLog "job: $($p.Name) PID $($p.ProcessId) no se pudo asignar ($([TcrJob]::LastError())) - ya pertenece a otro job"
            }
        }
    }

    if ($job -ne $null) { [void][TcrJob]::CloseHandle($job) }

    Write-TcrLog "aplicados: $limited de $found proceso(s) (cores=$CpuCores/$total jobCpu=$JobCpuPercent mem=$MemoryMaxMB prio=$Priority)"
    return [pscustomobject]@{
        Found       = $found
        Limited     = $limited
        JobRejected = $jobFailed
        TotalCores  = $total
    }
}

function Remove-TcrLimit {
    param([string[]]$Patterns)
    $total = Get-TcrLogicalCpuCount
    $full  = Get-TcrFullAffinityMask -Total $total
    $restored = 0
    foreach ($p in @(Get-TcrTargetProcess -Patterns $Patterns)) {
        $proc = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        try {
            if ($full -ne [IntPtr]::Zero) { $proc.ProcessorAffinity = $full }
            $proc.PriorityClass = 'Normal'
            $restored++
        } catch { }
    }
    Write-TcrLog "restaurados $restored proceso(s) a afinidad completa y prioridad Normal"
    return $restored
}

# ------------------------------------------------------------ tarea programada
function Install-TcrTask {
    param([string]$ScriptPath, $Config)
    $vigiaDir = Get-TcrDataDir
    New-Item -ItemType Directory -Force -Path $vigiaDir | Out-Null
    $vigia = Join-Path $vigiaDir 'vigia.ps1'

    $patterns = ($Config.Patterns | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    $text = @"
`$ErrorActionPreference = 'Continue'
& '$ScriptPath' watch -ConfigPath '$script:TcrConfig'
"@
    Set-Content -Path $vigia -Value $text -Encoding UTF8

    Unregister-ScheduledTask -TaskName $script:TcrTaskName -Confirm:$false -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $vigia) -join ' ')
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive
    Register-ScheduledTask -TaskName $script:TcrTaskName -Action $action -Trigger $trigger `
        -Principal $principal `
        -Description 'Aplica los limites de recursos definidos por tcr al iniciar sesion.' | Out-Null

    Write-TcrLog "tarea programada '$($script:TcrTaskName)' instalada"
    return $true
}

function Uninstall-TcrTask {
    $existed = $null -ne (Get-ScheduledTask -TaskName $script:TcrTaskName -ErrorAction SilentlyContinue)
    Unregister-ScheduledTask -TaskName $script:TcrTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-TcrLog "tarea programada retirada (existia=$existed)"
    return $existed
}

function Get-TcrTaskStatus {
    $task = Get-ScheduledTask -TaskName $script:TcrTaskName -ErrorAction SilentlyContinue
    if (-not $task) { return $null }
    $info = Get-ScheduledTaskInfo -TaskName $script:TcrTaskName -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        State     = $task.State
        LastRun   = $info.LastRunTime
        LastResult = $info.LastTaskResult
    }
}

# --------------------------------------------------------------------- estado
function Get-TcrStatus {
    param([string[]]$Patterns)
    $total = Get-TcrLogicalCpuCount
    $rows = @()
    $rx = Get-TcrProcessRegex -Patterns $Patterns
    if ($rx) {
        foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match $rx })) {
            $proc = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
            if (-not $proc) { continue }
            $cores = Get-TcrAffinityCpuCount -Affinity $proc.ProcessorAffinity -Total $total
            $pct = if ($cores -gt 0) { [math]::Round($cores / $total * 100) } else { 100 }
            $rows += [pscustomobject]@{
                Name     = $p.Name
                Pid      = $p.ProcessId
                Cores    = $cores
                CpuLimit = $pct
                MemMB    = [math]::Round($proc.WorkingSet64 / 1MB)
                Priority = $proc.PriorityClass
            }
        }
    }
    return [pscustomobject]@{
        TotalCores = $total
        Task       = (Get-TcrTaskStatus)
        Processes  = $rows
    }
}

Export-ModuleMember -Function @(
    'Write-TcrLog', 'Get-TcrDataDir', 'Get-TcrConfigPath', 'Get-TcrLogPath', 'Get-TcrTaskName',
    'Get-TcrLogicalCpuCount', 'ConvertFrom-TcrGlob', 'Get-TcrProcessRegex',
    'Get-TcrTargetProcess', 'Get-TcrAffinityMask', 'Get-TcrFullAffinityMask', 'Get-TcrAffinityCpuCount',
    'Get-TcrDefaultConfig', 'Get-TcrConfig', 'Save-TcrConfig',
    'Invoke-TcrApply', 'Remove-TcrLimit',
    'Install-TcrTask', 'Uninstall-TcrTask', 'Get-TcrTaskStatus', 'Get-TcrStatus'
)
