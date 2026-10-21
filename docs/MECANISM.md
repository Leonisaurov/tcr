# Mecanismos de Windows usados por `tcr`

Este documento explica qué hace Windows por debajo cuando `tcr` aplica un
límite, y por qué cada mecanismo se eligió.

---

## 1. Afinidad de CPU (`ProcessorAffinity`)

Cada proceso tiene una máscara de bits, uno por núcleo lógico. El núcleo de
Windows solo puede ejecutar un proceso en un núcleo que esté en su máscara.

```powershell
$p = Get-Process cline
$p.ProcessorAffinity          # máscara actual
$p.ProcessorAffinity = 3      # núcleos 0 y 1
```

En una máquina de 8 núcleos lógicos, la máscara `3` permite como máximo 2
núcleos a pantalla completa: **25 % de la CPU**, sin importar cuántos hilos
tenga el proceso.

**Ventajas**

- Se aplica al instante, sin reiniciar el proceso.
- No requiere ningún proceso auxiliar que mantenga vivo nada.
- No tiene conflictos: funciona aunque el proceso ya esté dentro de un Job
  Object, dentro de un contenedor, oarbitrado.
- Es reversible en cualquier momento.

**Limitaciones**

- Es un tope por *núcleo*, no por porcentaje fino. "2 de 8" no es lo mismo que
  "25 %" cuando el proceso usa un solo hilo: puede quedarse con un 12.5 % real.
- Un proceso puede crear hijos; los hijos heredan la afinidad del padre, lo cual
  en la práctica es lo que se quiere.

---

## 2. Job Objects y `SetInformationJobObject`

Un Job Object es un contenedor de procesos con límites del kernel. Windows los
aplica sin overhead por proceso.

La API relevante es `SetInformationJobObject`, con la clase
`JobObjectCpuRateControlInformation` (15), que recibe:

```c
typedef struct _JOBOBJECT_CPU_RATE_CONTROL_INFORMATION {
  DWORD ControlFlags;   // JOB_OBJECT_CPU_RATE_CONTROL_ENABLE | _HARD_CAP
  DWORD CpuRate;        // 1..10000, donde 100 = 1 %
} JOBOBJECT_CPU_RATE_CONTROL_INFORMATION;
```

Con `HARD_CAP`, la suma de CPU de **todos** los procesos del job nunca supera
`CpuRate` por ciento. El kernel lo reparte entre ellos según la demanda.

### El detalle que costó encontrar

La estructura anterior tiene un campo `Reserved` en la documentación original de
algunas referencias. Con ese campo, `Marshal.SizeOf` devuelve 12 y la llamada
falla:

```
SetInformationJobObject → False
GetLastWin32Error()     → "El programa lanzó un comando pero la longitud del
                            comando es incorrecta."  (ERROR_BAD_LENGTH)
```

Con la estructura de exactamente **8 bytes** (`ControlFlags` + `CpuRate`) la
misma llamada funciona. `tcr` lo implementa así y lo documenta en el código.

### Restricción fundamental

**Un proceso no puede salir de un Job Object.** Una vez asignado, permanece en
él hasta que termina. Si el proceso ya pertenece a otro job, la llamada
`AssignProcessToJobObject` falla con `ERROR_ACCESS_DENIED`.

Esto es habitual en agentes de IA: nacen dentro del Job Object de su proceso
padre, así que el límite por porcentaje no se les puede aplicar.

Por eso `tcr` trata la afinidad como mecanismo principal y el Job Object como
complemento opcional: cuando la asignación falla, se avisa y se continúa.

### Límite de memoria

Con `JobObjectExtendedLimitInformation` (9) y los flags
`JOB_OBJECT_LIMIT_PROCESS_MEMORY` y `JOB_OBJECT_LIMIT_JOB_MEMORY` se puede
limitar la memoria por proceso y la suma del job. Un proceso que intente
exceder su límite recibe un error de asignación en vez de crecer.

---

## 3. Prioridad de proceso

`PriorityClass` afecta al orden en que el planificador del kernel ejecuta el
proceso cuando hay competencia por CPU.

| Valor | Efecto |
|---|---|
| `Normal` | Por defecto. |
| `BelowNormal` | Se ejecuta solo cuando no hay nada mejor que ejecutar. |
| `Idle` | Solo cuando el sistema está prácticamente inactivo. |

Es la palanca más suave de las tres, y la más útil para el caso de uso real: no
impide que la herramienta trabaje, pero deja de robarte la máquina.

---

## 4. Tarea programada

`tcr install` registra una tarea que arranca al iniciar sesión:

```powershell
New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '... -File vigia.ps1'
New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive
```

El script `vigia.ps1` que genera invoca `tcr watch`, que es un bucle que
reaplica los límites cada N segundos. Esto es necesario porque:

- Un proceso nuevo que aparece después no hereda automáticamente los límites
  aplicados a su padre (afinidad sí se hereda; Job Object, no siempre).
- Los agentes de IA se relanzan con frecuencia.

### Nota sobre privilegios

`RunLevel Highest` es necesario para registrar la tarea. Sin privilegios de
administrador, `tcr` puede aplicarle límites a los procesos del propio usuario,
pero no registrar la tarea ni tocar procesos de otros usuarios.

---

## 5. Detección de procesos

`tcr` enumera con `Get-CimInstance Win32_Process` y filtra por nombre.

Dos trampas de PowerShell que la implementación evita:

```powershell
# MAL: -like no acepta un array a la derecha. Filtra de más o de menos,
# en silencio.
$procs | Where-Object { $_.Name -like @('opencode*', 'cline*') }

# BIEN: convertir el glob a regex
$rx = ($patterns | ForEach-Object { globToRegex $_ }) -join '|'
$procs | Where-Object { $_.Name -match $rx }
```

```powershell
# MAL: break dentro de Where-Object corta el pipeline entero.
$procs | Where-Object { foreach ($p in $pat) { if ($m -like $p) { $hit=$true; break } }; $hit }

# BIEN: resolver por fuera y filtrar por el resultado.
$rx = ...
$procs | Where-Object { $_.Name -match $rx }
```

### Detectar el proceso guardián

Un proceso elevado no expone su línea de comandos a un proceso sin privilegios:
la consulta devuelve cadena vacía en lugar de un error. Buscar por texto en la
línea de comandos falla de forma silenciosa.

`tcr` lo resuelve guardando el PID del guardián en un archivo y comprobando
además el nombre del proceso.

---

## Resumen de responsabilidades

| Mecanismo | Dónde se aplica | Reversible | Requiere admin |
|---|---|---|---|
| Afinidad de CPU | En el proceso | Sí, al instante | No (para procesos propios) |
| Job Object | En el job | No, hasta que el proceso termine | Sí |
| Prioridad | En el proceso | Sí, al instante | No (para procesos propios) |
| Tarea programada | En el sistema | Sí, borrando la tarea | Sí |
