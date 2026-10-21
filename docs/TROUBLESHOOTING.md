# Resolución de problemas

## `tcr status` no muestra ningún proceso

Los patrones por defecto son `opencode*`, `cline*` y `qodercli*`. Si tus
herramientas tienen otro nombre:

```powershell
.\tcr.ps1 status -Patterns 'miagente*','node*'
```

Comprueba primero qué procesos tienes:

```powershell
Get-Process | Sort-Object CPU -Descending | Select-Object -First 15 Name, Id, CPU
```

---

## Los límites no se aplican

### "no se pudo asignar ... ya pertenece a otro job"

Esto **no es un error**. Significa que el proceso ya está dentro de otro Job
Object (habitual en agentes de IA, que nacen dentro del job de su padre) y
Windows no permite moverlo.

Un proceso no puede salir de un Job Object, así que el tope por porcentaje
(`-JobCpu`) no se puede aplicar en ese caso. La afinidad de CPU sí se aplica y
garantiza el límite de forma efectiva, que es el motivo de ser del mecanismo
principal.

Si quieres el tope por porcentaje, aplica `-JobCpu` a procesos que no estén
anidados, por ejemplo herramientas lanzadas directamente desde el explorador.

### Los límites se pierden cuando el proceso se reinicia

La afinidad de CPU y la prioridad son propiedades del proceso: si el proceso
muere, se pierden. Para que persistan:

```powershell
.\tcr.ps1 install
```

Esto registra una tarea programada que reaplica los límites cada N segundos.

---

## El proceso sigue consumiendo mucha CPU

Un límite de afinidad es un tope por *núcleo*, no un porcentaje fino. Con
`-Cores 2` en una máquina de 8 núcleos, el proceso puede usar hasta el 25 %,
pero si solo tiene un hilo activo consumirá alrededor del 12.5 % real.

Comprueba el consumo real:

```powershell
$p = Get-Process cline
$p.CPU; $p.ProcessorAffinity
```

Si necesitas un tope más estricto, combina con el modo `Idle`:

```powershell
.\tcr.ps1 apply -Cores 1 -Priority Idle
```

---

## La tarea programada no se registra

```
ERROR: El acceso al registro solicitado no se ha concedido.
```

`Register-ScheduledTask` requiere privilegios de administrador. Ejecuta PowerShell
como administrador, o usa la opción de "Ejecutar como administrador" desde el
menú contextual.

Comprueba el estado con:

```powershell
.\tcr.ps1 doctor
```

---

## El guardián no aparece en la lista de procesos

Los procesos elevados no exponen su línea de comandos a un proceso sin
privilegios: la consulta devuelve cadena vacía en lugar de un error. Por eso
buscar por texto falla de forma silenciosa.

`tcr` lo resuelve guardando el PID en `%LOCALAPPDATA%\tcr\config.json` y
comprobando el nombre del proceso. Para ver el registro:

```powershell
Get-Content "$env:LOCALAPPDATA\tcr\tcr.log" -Tail 20
```

---

## Los límites se deshacen solos

Comprueba que la tarea programada esté activa:

```powershell
.\tcr.ps1 status
```

Si la tarea aparece como `Ready` pero los límites no se mantienen, mira el
registro de la tarea:

```powershell
Get-ScheduledTaskInfo -TaskName tcr
```

Un `LastTaskResult` distinto de `0` indica un fallo al arrancar.

---

## La máquina sigue caliente

`tcr` reduce la carga de CPU, que es lo que dispara el ventilador. Pero si la
temperatura de reposo ya es alta (unos 50 °C con el equipo prácticamente
inactivo), el problema es físico, no de software:

- **Polvo en el disipador o en el ventilador.** Es la causa más frecuente en
  laptops de varios años. Limpia las rejillas con aire comprimido y abre la
  tapa si sabes hacerlo.
- **Pasta térmica seca.** Se endurece con los años y reduce la transferencia de
  calor al disipador.
- **Superficie de apoyo.** El equipo sobre una cama o una manta bloquea las
  rejillas de entrada.
- **Ventilador del BIOS.** En los modelos HP de consumo, el BIOS tiene un menú
  *Thermal* con la velocidad mínima del ventilador. Reinicia, pulsa `F10` y
  busca *Power → Thermal*.

`tcr` no controla el ventilador: en los modelos de consumo HP la API oficial de
control térmico (la misma que usa la app de HP) responde "no soportado", y la
curva de ventilador vive en el firmware, sin interfaz de software.

---

## Dos instancias de `tcr` a la vez

Cada instancia crea su propio Job Object. La afinidad de CPU es idempotente
(asignarla dos veces con la misma máscara no tiene efecto), pero los Jobs
Objects se acumulan.

Comprueba y limpia:

```powershell
.\tcr.ps1 uninstall
Get-Content "$env:LOCALAPPDATA\tcr\tcr.log" -Tail 30
```

---

## Comprobación rápida de que todo funciona

```powershell
.\tcr.ps1 doctor
```

Imprime los privilegios actuales, las capacidades de Job Object disponibles y
el estado de afinidad y prioridad de cada proceso monitorizado.
