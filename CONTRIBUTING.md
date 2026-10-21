# Cómo contribuir

Gracias por el interés. `tcr` es pequeño a propósito: un solo script de CLI y
un módulo con la lógica.

## Puesta en marcha

```powershell
git clone https://github.com/<tu-usuario>/tcr.git
cd tcr
.\tests\Run-Tests.ps1
```

Las pruebas no tocan tus procesos reales: usan un proceso desechable propio.

## Antes de enviar un cambio

```powershell
# 1. Las pruebas pasan
.\tests\Run-Tests.ps1

# 2. La sintaxis es válida
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    '.\tcr.ps1', [ref]$null, [ref]$errors)
```

## Estilo

- PowerShell 5.1, sin dependencias externas.
- Comentarios y documentación en español.
- Sangría de 4 espacios.
- Los archivos de texto se guardan en UTF-8 con BOM (ver `.editorconfig`), para
  que Windows 5.1 los lea sin problemas con los acentos.
- Funciones con el verbo `Get-`/`Set-`/`New-`/`Remove-` según el cmdlet de
  PowerShell al que se parecen.

## Reglas de implementación

Estas reglas no son negociables; vienen de trampas reales de PowerShell y de
Windows:

1. **No uses `-like` con un array de patrones a la derecha.** Filtra en silencio
   de más o de menos. Convierte los globs a regex con `ConvertFrom-TcrGlob`.

2. **No uses `break` dentro de `Where-Object`.** Corta el pipeline entero, no
   solo el bucle interno.

3. **La estructura de CPU rate control debe medir exactamente 8 bytes.** Con un
   campo `Reserved` adicional, `SetInformationJobObject` falla con
   `ERROR_BAD_LENGTH`.

4. **Un proceso no puede salir de un Job Object.** Por eso la afinidad de CPU es
   el mecanismo principal y el Job Object es opcional. Si añades un mecanismo
   nuevo, que pueda fallar sin romper el conjunto.

5. **No busques procesos elevados por su línea de comandos.** Sin privilegios,
   la consulta devuelve cadena vacía en lugar de un error. Guarda el PID en un
   archivo, como hace el guardián.

6. **No generes carga de CPU en las pruebas.** Usa procesos que esperen
   (`Start-Sleep`), no bucles cerrados.

## Commits

Mensajes en inglés, estilo imperativo, con prefijo de área cuando toque:

```
Add fan-speed limit via Job Object
Fix affinity mask when restoring limits
docs: explain why -like fails with arrays
```

## Documentación

Si cambias un comportamiento, actualiza:

- El README (uso y ejemplos).
- `docs/MECANISM.md` (el detalle de Windows).
- `docs/TROUBLESHOOTING.md` (si introduce un síntoma nuevo).
- `CHANGELOG.md`, en la sección *No publicado*.
