<p align="center">
  <img src="assets/icon.png" alt="Icono de Simple-Backup" width="140">
</p>

<h1 align="center">Simple-Backup</h1>

<p align="center">
  Copias de seguridad incrementales para Linux Mint (Cinnamon), en un pequeño proyecto en bash. Mantén tus archivos (fotos, documentos, programas...) siempre sincronizados con tu disco externo, sin tener que adivinar nunca qué falta por actualizar.
</p>

<p align="center">
  <a href="LICENSE.txt"><img alt="Licencia GPLv3" src="https://img.shields.io/badge/Licencia-GPLv3-blue.svg"></a>
  <img alt="Bash" src="https://img.shields.io/badge/bash-%3E%3D4.3-4EAA25?logo=gnubash&logoColor=white">
  <img alt="Linux Mint" src="https://img.shields.io/badge/Linux%20Mint-22.3%20Cinnamon-87CF3E?logo=linuxmint&logoColor=white">
</p>

> **Idioma:** el proyecto está disponible en español e inglés. El script detecta automáticamente si el locale efectivo del sistema es español; en cualquier otro caso arranca en inglés. Pulsa **`l`** o **`L`** en el menú principal para alternar entre español e inglés. La elección queda guardada para las siguientes ejecuciones.
>
> [Read in English / Leer en inglés](README.md)

---

Simple-Backup es un script interactivo que copia tus carpetas personales (Documentos, Música, Imágenes, Vídeos, Descargas...) a otro disco —normalmente externo, aunque también vale uno interno— usando `rsync`. No crea una imagen: copia archivos reales y navegables, que puedes abrir desde el explorador de archivos de cualquier PC. También permite crear snapshots completos del sistema con Timeshift y programarlo todo por cron, sin tocar la terminal cada vez.

<img width="649" height="444" alt="menu-simple-backup-es" src="https://github.com/user-attachments/assets/75472f59-70ad-4efd-b395-bece5b13db6b" />
<img width="653" height="439" alt="config-simple-backup-es" src="https://github.com/user-attachments/assets/8e557bc9-7ba0-4fbf-b524-c810433b1027" />
<img width="650" height="443" alt="simple-backup-automatic-backup-es" src="https://github.com/user-attachments/assets/4f84145e-b1ec-42d4-8e8a-ec40ded74966" />
<img width="655" height="446" alt="simple-backup-config-check-es" src="https://github.com/user-attachments/assets/6aab7373-e7f3-4088-9cf1-4e5e7d05c2f2" />
<img width="653" height="440" alt="simple-backup-mirror-delete-es" src="https://github.com/user-attachments/assets/79189082-da84-4ab7-9083-e24df23fa277" />
<img width="652" height="446" alt="simple-backup-quick-help-es" src="https://github.com/user-attachments/assets/a2fcd702-773a-48a7-bf1a-be70b7cdf766" />

## ¿Por qué este script y no otra cosa?

Para copias de seguridad en Linux se suele recurrir a una **imagen de disco** (`dd`, Clonezilla...) o a **snapshots del sistema** (Timeshift, Déjà Dup...). Ninguna resuelve bien el caso más común —tener tus fotos, documentos y música también en el disco externo, tal cual, por si el ordenador muere mañana—, porque una imagen no se puede abrir para coger un solo archivo sin restaurarla entera. Simple-Backup usa `rsync` para copiar solo lo nuevo o modificado en cada ejecución, dejando en el disco externo la misma estructura de carpetas que tienes en casa: enchufas el disco en cualquier PC y ahí están tus archivos, sin depender de ningún software para recuperarlos.

Encima de un `rsync -a` a mano, el script aporta:

- **No borra nada por accidente.** Nunca elimina archivos del destino aunque los borres en el origen (el modo espejo es opcional y hay que activarlo a propósito).
- **Evita los despistes típicos**: avisa de backups infinitos (destino dentro de un origen), disco externo no montado, destino en el mismo disco que tu carpeta personal, o carpetas de origen homónimas que podrían mezclarse.
- **Se adapta al disco de destino**, ajustando `rsync` automáticamente si está en FAT32, exFAT o NTFS.
- **Combina backup de archivos y snapshots del sistema** desde el mismo menú.
- **Todo en un proyecto pequeño**: sin dependencias raras ni paquete `.deb`, solo permisos de ejecución.

## Tabla de contenidos

- [¿Por qué este script y no otra cosa?](#por-qué-este-script-y-no-otra-cosa)
- [Funciones](#funciones)
- [Instalación](#instalación)
- [Uso](#uso)
- [Compatibilidad](#compatibilidad)
- [Dónde guarda sus cosas](#dónde-guarda-sus-cosas)
- [Idioma](#idioma)
- [Roadmap](#roadmap)
- [Licencia](#licencia)
- [Contribuir](#contribuir)

## Funciones

### Copia de seguridad de archivos personales

- **Detección automática de carpetas** vía `xdg-user-dirs`: reconoce Documentos, Música, Imágenes, Vídeos, Descargas, Escritorio, Plantillas y Público en el idioma del sistema.
- **Añadir carpetas a mano**, con selector gráfico (`zenity`) o escribiendo la ruta.
- **Aviso de solapamiento** si una carpeta ya está contenida en otra, o apunta al mismo sitio por enlace simbólico.
- **Exclusiones configurables** (`.cache`, `*.tmp`, `*.part`, `*.crdownload`, `*.download`, `node_modules`, `.thumbnails`, `lost+found` por defecto), editables desde el menú.
- **Carpetas homónimas sin mezclarse**: si dos orígenes se llaman igual, cada una se renombra en destino anteponiendo su carpeta padre, avisando con qué nombre quedó cada una.
- **Adaptado al filesystem de destino**: ajusta las opciones de `rsync` en FAT32, exFAT o NTFS para evitar falsos avisos de permisos, y en FAT32 excluye limpiamente los archivos de más de 4 GiB.
- **Detección de unidades montadas** (`lsblk`), con etiqueta, tamaño y tipo; se eligen por número, ruta escrita o selector gráfico.
- **Modo espejo opcional** (`--delete`, desactivado por defecto) para que el destino sea una copia exacta del origen, borrados incluidos.
- **Comprobaciones antes de copiar**: destino accesible y escribible, que no esté dentro de un origen ni sea el mismo disco que tu carpeta personal, espacio libre suficiente, y aviso si el disco no parece extraíble.
- **Bloqueo de ejecución** para que dos copias (por ejemplo manual y programada) no se pisen.
- **Barra de progreso** por carpeta, y un resumen final que separa avisos menores de errores reales.
- **Notificaciones de escritorio** al terminar (éxito, avisos o errores), también en ejecuciones automáticas por cron.

### Snapshots del sistema completo (Timeshift)

El menú da acceso directo a [Timeshift](https://github.com/linuxmint/timeshift) para snapshots del sistema completo (no tus documentos): crear uno al momento, ver los existentes, abrir su interfaz gráfica o elegir el disco/partición donde se guardan. Si no está instalado, el script se ofrece a instalarlo.

### Automatización

- **Programación por cron** desde el menú (diaria o semanal, con hora y día), sin editar el crontab a mano; la tarea también se puede quitar desde ahí.
- **Modo `--auto`**: ejecuta el backup ya configurado sin menús, pensado para cron. Si el disco no está conectado o falta configuración, lo registra en el log y notifica si hay sesión de escritorio, en vez de fallar en silencio.

### Otras cosas útiles

- **Registro de cada ejecución**, consultable desde el menú, con limpieza automática (se conservan los últimos 90).
- **Verificación de la configuración** (opción 7): sin copiar nada, comprueba que `rsync` esté instalado, que los orígenes y el destino sean accesibles, el espacio libre, y si la tarea de cron (cuando la hay) podrá ejecutarse; al terminar resume si todo está bien, hay avisos, o hay problemas que corregir.
- **Asistente de primer uso** que detecta tus carpetas y te lleva a elegir el disco de destino sin buscar la opción en el menú.
- **Comprobación de dependencias** al arrancar, con instalación automática de lo que falte (`rsync`, `xdg-user-dirs` y, opcionalmente, `zenity`).

## Instalación

**Requisitos:**

| Paquete | Necesario para | ¿Obligatorio? |
|---|---|---|
| `bash` ≥ 4.3 | Ejecutar el script | Sí |
| `rsync` | Hacer las copias | Sí |
| `xdg-user-dirs` | Detectar tus carpetas personales | Sí |
| `zenity` | Selector gráfico de carpetas | No (si falta, se escriben las rutas a mano) |
| `libnotify-bin` | Notificaciones de escritorio | No |
| `timeshift` | Snapshots del sistema | No, solo si usas esa función |
| `cron` | Copias programadas | No, solo si usas esa función |

Si te falta algo de lo obligatorio, el propio script lo detecta al arrancar y te ofrece instalarlo con `apt`.

**Pasos:**

```bash
git clone https://github.com/filonux/Simple-Backup.git
cd Simple-Backup
chmod +x script/simple-backup.sh
./script/simple-backup.sh
```

Con eso ya se lanza el asistente de primer uso.

**¿Prefieres no depender de la terminal?** [**Scriptya**](https://github.com/filonux/Scriptya), otra herramienta del mismo autor, permite lanzar, instalar, desinstalar y cambiar el icono de Simple-Backup como si fuera cualquier otra aplicación, con menú propio y sin escribir comandos. Basta con apuntarla a la carpeta `script/` de este repositorio.

## Uso

**Menú interactivo** (uso normal):

```bash
./script/simple-backup.sh
```

El menú principal tiene siete opciones: configurar rutas de origen y destino, ejecutar la copia ahora, crear una snapshot del sistema, programar copias automáticas, ver el historial de logs, activar o desactivar el modo espejo, y verificar la configuración sin copiar nada.

**De cero a copias automáticas:** la primera ejecución lanza el asistente de primer uso, que detecta tus carpetas y te lleva a elegir el disco de destino de una lista de unidades montadas. Con eso configurado, la opción 2 lanza la primera copia, y la opción 4 solo pide frecuencia (diaria o semanal), hora y, si aplica, día, para dejarla programada en el crontab por ti. A partir de ahí entras siempre directo al menú principal, y las copias programadas corren solas, avisándote por notificación de escritorio del resultado de cada una — todo sin escribir una línea de `rsync` ni tocar el crontab a mano.

**Otros comandos:**

```bash
./script/simple-backup.sh --auto     # Ejecuta el backup ya configurado, sin menús (para cron)
./script/simple-backup.sh --version  # Muestra la versión instalada
./script/simple-backup.sh --help     # Muestra la ayuda
```

No hace falta que llames tú mismo a `--auto`: si programas una copia desde el menú (opción 4), el script se encarga de añadir la línea correspondiente al crontab.

## Compatibilidad

Desarrollado y probado en **Linux Mint 22.3 (Cinnamon)**. Al usar bash, `rsync` y herramientas estándar de GNU/Linux, debería funcionar sin cambios en cualquier distribución basada en Debian/Ubuntu y con otros entornos de escritorio (lo específico de Cinnamon se reduce casi todo a los iconos de las notificaciones). La única salvedad es que la instalación automática de dependencias usa `apt`: en distribuciones que no lo usen (Fedora, Arch...) tendrás que instalar `rsync`, `xdg-user-dirs` y, si quieres, `zenity` y `timeshift` tú mismo; el resto del script funciona igual.

## Dónde guarda sus cosas

Simple-Backup no toca nada fuera de tu carpeta personal salvo el propio disco de destino que tú elijas:

| Qué | Dónde |
|---|---|
| Configuración (carpetas, destino, exclusiones...) | `~/.config/simple-backup/config.conf` |
| Logs de cada copia | `~/.local/share/simple-backup/logs/` |
| Bloqueo de ejecución | `~/.config/simple-backup/backup.lock` |

Se genera y sobrescribe automáticamente desde el menú: no hace falta (ni se recomienda) editarlo a mano.

## Idioma

La selección de idioma es independiente del locale del sistema: en una configuración nueva, Simple-Backup comprueba `LC_ALL`, `LC_MESSAGES` y `LANG`, en ese orden, y arranca en español solo si detecta un locale español (`es`, `es_ES`, `es-ES`...); cualquier otro caso arranca en inglés. El atajo **`l`/`L`** del menú principal cambia entre ambos y guarda la elección en `UI_LANGUAGE` (dentro de `~/.config/simple-backup/config.conf`), que a partir de ahí manda sobre la detección automática; las configuraciones existentes sin ese campo se comportan como `auto`.

El código se comenta en inglés; la interfaz y la documentación están traducidas.

### Pruebas

Incluye una batería de regresión centrada en contratos de comportamiento: catálogos de idioma, precedencia del locale, comportamiento real de `rsync`, exclusiones, borrado espejo, bloqueo, integración con cron, helpers de Timeshift y clasificación de códigos de salida, entre otros — con fixtures temporales y mocks deterministas para que cada fallo señale un contrato concreto. Ejecútala con `bash tests/test.sh`; `bash tests/mutation.sh` comprueba que regresiones intencionadas (cambio de idioma, textos del menú, exclusiones, borrado espejo...) se detectan de verdad.

## Roadmap

- [x] Traducción de la interfaz al inglés — el proyecto empezó solo en español; ahora está disponible en español e inglés (ver [Idioma](#idioma)).
- [ ] Posible paquete `.deb` opcional, para quien prefiera instalar y actualizar con `apt` en vez de clonar el repositorio. El `.sh` suelto seguirá funcionando igual para quien lo prefiera así.

## Licencia

Publicado bajo licencia **GNU GPLv3**. Consulta el archivo [LICENSE.txt](LICENSE.txt) para el texto completo.

## Contribuir

Las aportaciones son bienvenidas. Antes de abrir una issue o un pull request, échale un vistazo a [CONTRIBUTING.md](.github/CONTRIBUTING.md) y al [código de conducta](.github/CODE_OF_CONDUCT.md). Para reportar un fallo o pedir una función nueva, usa las plantillas correspondientes en [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/). Si encuentras un problema de seguridad, sigue el proceso descrito en [SECURITY.md](.github/SECURITY.md) en vez de abrir una issue pública.

---

Hecho por **[Filonux](https://github.com/filonux)**.
