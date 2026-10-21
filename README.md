# tcr

**Tool for Constraining Resources** — limita el uso de CPU y memoria de herramientas
locales (agentes de IA, IDEs, compiladores) en Windows, sin instalar nada y sin
dejar procesos de fondo.

`tcr` nació de un problema concreto: en una laptop HP 255R con un Ryzen 3 7335U,
varios agentes de IA (opencode, cline, qodercli) encendían compilaciones en
background que dejaban el equipo a 74 % de CPU y la máquina a 85 °C, con el
ventilador apenas audible. Ninguna de las herramientas traía forma de
autolimitarse.

---

## Por qué no basta con bajar el consumo de las herramientas

Medir el proceso "principal" de una herramienta da una imagen incompleta. En el
caso real, el consumo venía de una cadena de procesos hijos:

```
qodercli.exe
  └─ bash.exe
      └─ node.exe  rom_smoke.js
          └─ node.exe  ccache.js
              └─ clang.exe  ×2      ← 16 % de la CPU
```

Limitar solo `qodercli.exe` no habría servido de nada. `tcr` busca por nombre de
proceso, así que cubre tanto al padre como a los hijos que nascen después (el
modo vigilancia los recoge).

---

## Instalación

No requiere instalación: clona y usa.

```powershell
git clone https://github.com/<tu-usuario>/tcr.git
cd tcr
.\tcr.ps1 doctor
```

Requiere PowerShell 5.1 (incluido en Windows 10 y 11). Para registrar la tarea
programada o limitar procesos de otro usuario, ejecuta como administrador.

Los datos de ejecución (configuración y registro) viven fuera del repo, en
`%LOCALAPPDATA%\tcr\`, para que un clon no arrastre el estado de otra
instalación.

---

## Uso rápido

```powershell
# Ver el estado actual
.\tcr.ps1 status

# Limitar a 2 de 8 núcleos (25 % de CPU máximo) con prioridad BelowNormal
.\tcr.ps1 apply -Cores 2

# Instalar la tarea programada: aplica los límites al iniciar sesión
.\tcr.ps1 install

# Quitar todo
.\tcr.ps1 remove
```

### Comandos

| Comando | Qué hace |
|---|---|
| `apply` | Aplica los límites a los procesos que coincidan y guarda la configuración. |
| `status` | Muestra afinidad, prioridad y uso actual de cada proceso, y el estado de la tarea programada. |
| `remove` | Restaura la afinidad completa y la prioridad `Normal`. |
| `install` | Registra la tarea programada que aplica los límites al iniciar sesión. |
| `uninstall` | Elimina la tarea programada y restaura los procesos. |
| `watch` | Modo daemon: reaplica los límites a los procesos nuevos. Lo usa la tarea programada. |
| `doctor` | Diagnóstico del sistema: privilegios, capacidades y procesos monitorizados. |
| `help` | Ayuda. |

### Opciones

| Opción | Por defecto | Descripción |
|---|---|---|
| `-Patterns` | `opencode*`, `cline*`, `qodercli*` | Patrones glob de los procesos a limitar. |
| `-Cores` | `2` | Núcleos lógicos por proceso. `0` = sin límite. |
| `-JobCpu` | `0` | Tope de CPU por porcentaje real vía Job Object (1-100). |
| `-MemoryMaxMB` | `0` | Memoria máxima por proceso en MB. |
| `-Priority` | `BelowNormal` | `Normal`, `BelowNormal` o `Idle`. |
| `-Interval` | `10` | Segundos entre rondas del modo vigilancia. |
| `-ExcludeSession` | activo | No limita la sesión actual ni sus ancestros. |
| `-IncludeSession` | — | Limita también la sesión actual. |

---

## Los dos mecanismos

### 1. Afinidad de CPU (mecanismo principal)

Restringe cada proceso a un número limitado de núcleos lógicos. Con 2 de 8
núcleos, el proceso no puede superar el 25 % de la máquina, sin importar cuántos
hilos use.

Es el mecanismo principal por una razón concreta: **un proceso ya no puede
sacarse de un Job Object**, pero la afinidad de CPU se puede cambiar en
cualquier momento y no tiene restricciones. Por eso `tcr` la usa siempre, y
deja el Job Object como complemento opcional.

### 2. Job Object (opcional, `-JobCpu`)

Tope de CPU por porcentaje real y límite de memoria por proceso, usando la API
de Windows (`SetInformationJobObject`).

Limitación conocida: `AssignProcessToJobObject` devuelve `ACCESS_DENIED` si el
proceso ya pertenece a otro Job Object. Eso es habitual en agentes de IA, que
nacen dentro del job de su padre. `tcr` lo detecta, lo informa y continúa: la
afinidad de CPU sigue garantizando el límite.

### 3. Prioridad

`BelowNormal` hace que el planificador del sistema ejecute el proceso solo
cuando hay CPU libre. Reduce el impacto sobre tu trabajo interactivo aunque la
herramienta esté trabajando.

---

## Ejemplos

Limitar una herramienta concreta sin tocar las demás:

```powershell
.\tcr.ps1 apply -Patterns 'node*' -Cores 1
```

Añadir un tope duro de porcentaje y un límite de memoria:

```powershell
.\tcr.ps1 apply -Patterns 'opencode*','cline*' -Cores 2 -JobCpu 15 -MemoryMaxMB 1500
```

Vigilancia más agresiva, para procesos que aparecen y desaparecen:

```powershell
.\tcr.ps1 install -Cores 2 -Interval 5
```

Configurar una tarea programada con otros patrones:

```powershell
.\tcr.ps1 install -Patterns 'code*','idea64*','devenv*' -Cores 3 -Priority Idle
```

---

## Verificar que funciona

```powershell
.\tcr.ps1 status
```

```
  Proceso             PID     Nucleos   CPU max   Memoria   Prioridad
  -----------------------------------------------------
  opencode.exe        1752    2/8      25%          422 MB   BelowNormal
  cline.exe           6640    2/8      25%           41 MB   BelowNormal
  qodercli.exe        3068    2/8      25%          289 MB   BelowNormal
```

Para medir el consumo real antes y después:

```powershell
Get-Process opencode,cline,qodercli |
    Select-Object Name, Id, CPU, @{n='Cores';e={$_.ProcessorAffinity}}
```

---

## Notas de implementación

Detalles que costaron encontrar y que conviene documentar:

- **`-like` no acepta un array de patrones.** En PowerShell, `$nombre -like @('a*','b*')`
  no filtra nada: se evalúa como un escalar contra el array y el resultado es
  silenciosamente incorrecto. `tcr` convierte los globs a regex antes de filtrar.

- **`break` dentro de `Where-Object` corta el pipeline entero**, no solo el
  bucle interno. `tcr` evita ese patrón.

- **Enumerar las claves de un hashtable mientras se modifica lanza "Colección
  modificada".** `Get-TcrConfig` recorre una copia de la lista de claves.

- **La estructura de CPU rate control debe medir exactamente 8 bytes.** Con un
  campo `Reserved` adicional (12 bytes) `SetInformationJobObject` falla con
  `ERROR_BAD_LENGTH` ("la longitud del comando es incorrecta").

- **Un proceso no puede salir de un Job Object.** Una vez asignado, permanece
  ahí hasta que termina. De ahí que la afinidad de CPU sea el mecanismo
  principal.

- **El vigilante detecta procesos por PID, no por línea de comandos.** Sin
  privilegios de administrador no se puede leer la línea de comandos de un
  proceso elevado, así que buscar por texto falla de forma silenciosa.

- **Restaurar la afinidad completa necesita una máscara real.** La función que
  construye la máscara devuelve cero cuando se piden todos los núcleos (eso
  significa "sin límite" al aplicar), así que para restaurar hay una función
  aparte.

---

## Contexto: por qué existe esta herramienta

Nació de un caso concreto en una laptop HP 255R con Ryzen 3 7335U y 8 GB de RAM.
Varios agentes de IA (opencode, cline, qodercli) se lanzaban desde la sesión
y dejaban el equipo a 74 % de CPU y 85 °C, con el ventilador casi inaudible.

Dos cosas se aprendieron por el camino y quedan documentadas aquí porque
condicionan el diseño:

**El consumo no está en el proceso principal.** El culprits era una cadena de
hijos:

```
qodercli.exe → bash.exe → node.exe → node.exe → clang.exe ×2
```

Los agentes CLI lanzan compilaciones, y el trabajo pesado ocurre en los
nietos. `tcr` busca por nombre de proceso, así que los cubre; el modo
vigilancia recoge los que nacen después.

**El ventilador no se puede controlar por software en estos equipos.** La API
oficial de control térmico de HP (la misma que usa la app de HP para los modos
Balanceado / Refrigeración / Rendimiento) responde "no soportado" en los modelos
de consumo: el firmware no implementa el comando y la app oculta la tarjeta
correspondiente. La curva de ventilador vive en el BIOS, sin interfaz de
software.

Para el ventilador, las palancas reales son:

- **BIOS → Power → Thermal**, donde se fija la velocidad mínima.
- **Limpieza física.** Si el equipo está a 50 °C en reposo, el problema es
  polvo en el disipador o pasta térmica seca, no software.
- **Reducir la carga**, que es lo que hace `tcr`.

`tcr` ataca el tercer punto. El segundo y el primero requieren intervención
física o en el BIOS.

---

## Estructura del repositorio

```
tcr/
├── tcr.ps1              # punto de entrada (CLI)
├── src/
│   └── Tcr.psm1         # lógica: procesos, máscaras, límites, tarea programada
├── docs/
│   ├── MECANISM.md      # detalle de los mecanismos de Windows
│   └── TROUBLESHOOTING.md
├── tests/
│   └── Run-Tests.ps1    # pruebas sin efectos secundarios
├── config/
│   └── ejemplo.json     # configuración de referencia
├── CHANGELOG.md
├── CONTRIBUTING.md
├── LICENSE
└── README.md
```

---

## Pruebas

```powershell
.\tests\Run-Tests.ps1
```

Las pruebas son de solo lectura o usan un proceso desechable propio; no tocan
los procesos del usuario ni generan carga significativa.

---

## Licencia

MIT. Ver [LICENSE](LICENSE).
