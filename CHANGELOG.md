# Changelog

Todas las versiones relevantes de `tcr`.

El formato sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/)
y este proyecto adheres a [Versionado Semántico](https://semver.org/lang/es/).

## [No publicado]

### Añadido
- Instalador (`install.ps1`) que crea un lanzador `tcr` en una carpeta del PATH
  y, si hace falta, añade esa carpeta al PATH del usuario. El lanzador apunta
  al script del repositorio, no a una copia, de modo que el repositorio sigue
  siendo la única fuente de verdad.
- Mecanismo principal de límite por afinidad de CPU, con máscara de núcleos
  lógicos por proceso.
- Límite opcional de CPU por porcentaje real mediante Job Object
  (`JobObjectCpuRateControlInformation`).
- Límite opcional de memoria por proceso (`JobObjectExtendedLimitInformation`).
- Ajuste de prioridad de proceso (`Normal`, `BelowNormal`, `Idle`).
- Subcomandos `apply`, `status`, `remove`, `install`, `uninstall`, `watch`,
  `doctor` y `help`.
- Modo vigilancia que reaplica los límites a los procesos nuevos.
- Tarea programada que aplica los límites al iniciar sesión.
- Exclusión de la sesión actual y sus ancestros (`-ExcludeSession`).
- Configuración persistente en `%LOCALAPPDATA%\tcr\config.json`.
- Registro de actividad en `%LOCALAPPDATA%\tcr\tcr.log`.
- Suite de pruebas sin efectos secundarios sobre los procesos del usuario.
- Documentación de los mecanismos de Windows y guía de resolución de problemas.
- Esquema JSON de la configuración.

### Corregido
- `Get-TcrConfig` enumeraba las claves del hashtable mientras lo modificaba,
  lo que lanzaba "Colección modificada" y hacía que la configuración se
  descartara en silencio.
- `Remove-TcrLimit` usaba la máscara de afinidad, que devuelve cero cuando se
  piden todos los núcleos, por lo que restaurar la afinidad completa no tenía
  efecto. Se añadió `Get-TcrFullAffinityMask`.
- La estructura de CPU rate control debe medir exactamente 8 bytes y su nombre
  de tipo chocaba con el de un campo.

### Notas
- La estructura de CPU rate control debe medir exactamente 8 bytes; con un
  campo `Reserved` adicional la llamada a `SetInformationJobObject` falla con
  `ERROR_BAD_LENGTH`.
- `AssignProcessToJobObject` devuelve `ACCESS_DENIED` para procesos que ya
  pertenecen a otro Job Object. Un proceso no puede salir de un job, por lo que
  en ese caso el límite por porcentaje no es aplicable; la afinidad de CPU
  sigue garantizando el límite.
- El filtrado de procesos usa regex porque `-like` no acepta un array de
  patrones en el lado derecho en PowerShell.
