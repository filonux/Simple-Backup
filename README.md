<p align="center">
  <img src="assets/icon.png" alt="Icono de Simple-Backup" width="140">
</p>

<h1 align="center">Simple-Backup</h1>

<p align="center">
  Copias de seguridad incrementales para Linux Mint (Cinnamon), en un único script de bash.
</p>

<p align="center">
  <a href="LICENSE"><img alt="Licencia GPLv3" src="https://img.shields.io/badge/Licencia-GPLv3-blue.svg"></a>
  <img alt="Bash" src="https://img.shields.io/badge/bash-%3E%3D4.3-4EAA25?logo=gnubash&logoColor=white">
  <img alt="Linux Mint" src="https://img.shields.io/badge/Linux%20Mint-22.3%20Cinnamon-87CF3E?logo=linuxmint&logoColor=white">
</p>

> **Nota sobre el idioma:** este proyecto (script, menús, documentación) está en español. Si veo interés de gente que lo necesite en inglés, prepararé una traducción — más detalles al final del documento, en [Roadmap](#roadmap).

---

Simple-Backup es un script interactivo que copia tus carpetas personales (Documentos, Música, Imágenes, Vídeos, Descargas...) a otro disco —normalmente uno externo, aunque también puede ser un segundo disco interno— usando `rsync`. No crea una imagen del disco: copia archivos reales, navegables, que puedes abrir directamente desde el explorador de archivos en cualquier PC. Además, deja crear snapshots completos del sistema con Timeshift y programar todo por cron, sin tener que tocar la terminal cada vez.

## ¿Por qué este script y no otra cosa?

Hay dos formas habituales de hacer copias de seguridad en Linux: crear una **imagen del disco** (con `dd`, Clonezilla...) o usar una herramienta de **snapshots del sistema** (Timeshift, Déjà Dup...). Ambas son útiles, pero ninguna resuelve bien el caso más común: *"quiero que mis fotos, documentos y música estén también en el disco externo, tal cual, por si el ordenador muere mañana"*.

Con una imagen no puedes entrar y coger un solo archivo sin restaurarla entera. Simple-Backup, en cambio, usa `rsync` para copiar **solo lo nuevo o modificado** en cada ejecución, dejando en el disco externo la misma estructura de carpetas que tienes en casa. Enchufas el disco en cualquier ordenador y ahí están tus archivos, sin depender de ningún software para recuperarlos.

Lo que aporta el script encima de un simple `rsync -a` a mano:

- **No borra nada por accidente.** Por defecto nunca elimina archivos del destino aunque los borres en el origen (el modo espejo es opcional y hay que activarlo a propósito).
- **Evita los despistes típicos**: te avisa si el destino está dentro de una carpeta de origen (backup infinito), si el disco externo no está montado, si el destino resulta ser el mismo disco que tu carpeta personal, o si dos carpetas de origen se llaman igual y podrían mezclarse.
- **Se adapta al disco de destino.** Si formateas el disco externo en FAT32, exFAT o NTFS (habitual si también lo usas en Windows), el script ajusta automáticamente las opciones de `rsync` para no llenar la pantalla de errores de permisos que no son reales.
- **Combina backup de archivos + snapshot del sistema** desde el mismo menú, en vez de tener que aprender y configurar dos herramientas por separado.
- **Todo en un archivo.** Sin dependencias raras, sin instalar un paquete .deb: descargas el `.sh`, le das permisos y ya está.

## Tabla de contenidos

- [¿Por qué este script y no otra cosa?](#por-qué-este-script-y-no-otra-cosa)
- [Funciones](#funciones)
- [Instalación](#instalación)
- [Uso](#uso)
- [Compatibilidad](#compatibilidad)
- [Crea un lanzador de escritorio con Scriptya](#crea-un-lanzador-de-escritorio-con-scriptya)
- [Dónde guarda sus cosas](#dónde-guarda-sus-cosas)
- [Roadmap](#roadmap)
- [Licencia](#licencia)
- [Contribuir](#contribuir)

## Funciones

### Copia de seguridad de archivos personales

- **Detección automática de carpetas.** Usa `xdg-user-dirs`, así que reconoce Documentos, Música, Imágenes, Vídeos, Descargas, Escritorio, Plantillas y Público en el idioma que tengas configurado en el sistema.
- **Añadir carpetas a mano**, con un selector gráfico clásico (si tienes `zenity` instalado) o escribiendo la ruta directamente si no.
- **Aviso de solapamiento.** Si intentas añadir una carpeta que ya está contenida en otra (o al revés), o que apunta al mismo sitio por un enlace simbólico, el script te avisa antes de duplicar contenido.
- **Exclusiones configurables**, con una lista por defecto ya sensata (`.cache`, `*.tmp`, `*.part`, `*.crdownload`, `*.download`, `node_modules`, `.thumbnails`, `lost+found`) que puedes ampliar o editar desde el propio menú.
- **Sin mezclar carpetas con el mismo nombre.** Si configuras dos orígenes distintos que se llaman igual (por ejemplo, dos carpetas "Proyectos" en rutas diferentes), el script renombra automáticamente cada una en el destino (anteponiendo la carpeta padre) para que no se mezcle su contenido, y te avisa de qué carpeta quedó guardada con qué nombre.
- **Se adapta al sistema de archivos del destino**, ajustando las opciones de `rsync` si el disco está en FAT32, exFAT o NTFS (sistemas que no soportan permisos ni propietario de Unix), para que no aparezcan avisos de "operación no permitida" por algo que no es un fallo real. Si el destino es FAT32, también avisa antes de copiar si hay archivos de más de 4 GiB (ese formato no los admite), y los excluye de forma limpia para que la copia no se quede a medias.
- **Detección de unidades montadas**, internas y externas, usando `lsblk`: muestra etiqueta, tamaño y de qué tipo es cada una. Eliges la que quieras con un número, escribiendo la ruta a mano, o con el selector gráfico si tienes `zenity`.
- **Modo espejo opcional (`--delete`)**, desactivado por defecto. Actívalo solo si quieres que el destino sea una copia exacta del origen, borrados incluidos.
- **Comprobaciones antes de copiar**: destino accesible, con permisos de escritura, que no esté dentro de un origen, que no sea el mismo disco que tu carpeta personal, y aviso si queda poco espacio libre. (Al elegir el destino, además, avisa si el disco no parece extraíble, por si has confundido una partición interna.)
- **Bloqueo de ejecución.** Si lanzas una copia y ya hay otra en marcha (por ejemplo, una programada por cron), el script lo detecta y no las deja pisarse.
- **Barra de progreso** por carpeta durante la copia, y un resumen final que separa los avisos sin importancia (por ejemplo, un archivo que cambió mientras se copiaba) de los errores reales, en vez de tratarlos todos igual.
- **Notificaciones de escritorio** al terminar (correcto, con avisos, o con errores), también en las ejecuciones automáticas por cron.

### Snapshots del sistema completo (Timeshift)

Aparte de tus archivos personales, el menú incluye acceso directo a [Timeshift](https://github.com/linuxmint/timeshift) para snapshots del sistema (el sistema operativo entero, no tus documentos): crear una snapshot al momento, ver las existentes, abrir la interfaz gráfica, o configurar en qué disco/partición se guardan. Si no tienes Timeshift instalado, el script se ofrece a instalarlo.

### Automatización

- **Programación por cron** desde el propio menú: copia diaria (eliges la hora) o semanal (día y hora), sin editar el crontab a mano. También puedes quitar la tarea programada desde ahí mismo.
- **Modo `--auto`**: ejecuta el backup ya configurado sin abrir ningún menú, pensado para lanzarse solo por cron. Si el disco externo no está conectado o falta configuración, no falla en silencio: lo deja registrado en el log y (si hay sesión de escritorio) manda una notificación.

### Otras cosas útiles

- **Registro (log) de cada ejecución**, consultable desde el menú, con limpieza automática de los más antiguos (se conservan los últimos 90).
- **Asistente de primer uso**: la primera vez que ejecutas el script, te guía para detectar tus carpetas y elegir el disco de destino, sin tener que buscar la opción en el menú.
- **Comprobación de dependencias** al arrancar, con opción de instalar automáticamente lo que falte (`rsync`, `xdg-user-dirs`, y opcionalmente `zenity`).

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
cd simple-backup
chmod +x script/simple-backup.sh
./script/simple-backup.sh
```

Con eso ya se lanza el asistente de primer uso.

## Uso

**Menú interactivo** (uso normal):

```bash
./script/simple-backup.sh
```

El menú principal tiene seis opciones: configurar rutas de origen y destino, ejecutar la copia ahora, crear una snapshot del sistema, programar copias automáticas, ver el historial de logs, y activar o desactivar el modo espejo.

**De cero a copias automáticas, paso a paso:**

1. **Primera ejecución.** Al no encontrar configuración previa, el script lanza el asistente de primer uso él solo, sin que tengas que buscar nada en el menú. Pregunta si quieres detectar tus carpetas personales automáticamente (Documentos, Música, Imágenes...) y, si dices que sí, te lleva directo a elegir el disco de destino de una lista de unidades montadas (con etiqueta, tamaño, y si son internas o externas).
2. **Primera copia.** Ya en el menú principal, con origen y destino configurados, la opción 2 lanza la copia: el script comprueba que el destino esté accesible, con permisos de escritura y espacio suficiente, y copia carpeta por carpeta con una barra de progreso.
3. **Automatizar.** Si quieres que se repita sola, la opción 4 solo pide la frecuencia (diaria o semanal), la hora y, si es semanal, el día: el script añade la tarea al crontab por ti, sin que tengas que tocarlo a mano.
4. **A partir de ahí.** Cada vez que abras el script entras directo al menú principal —el asistente no vuelve a aparecer—, y las copias programadas corren solas en segundo plano, avisándote por notificación de escritorio de cómo fue cada una.

En resumen: clonas el repositorio, contestas un par de preguntas y eliges el disco de una lista numerada. En un par de minutos tienes copias automáticas funcionando, sin haber escrito una línea de `rsync` ni haber tocado el crontab a mano.

**Otros comandos:**

```bash
./script/simple-backup.sh --auto     # Ejecuta el backup ya configurado, sin menús (para cron)
./script/simple-backup.sh --version  # Muestra la versión instalada
./script/simple-backup.sh --help     # Muestra la ayuda
```

No hace falta que llames tú mismo a `--auto`: si programas una copia desde el menú (opción 4), el script se encarga de añadir la línea correspondiente al crontab.

## Compatibilidad

Desarrollado y probado en **Linux Mint 22.3 (Cinnamon)**. Al ser bash + `rsync` + herramientas estándar de GNU/Linux, debería funcionar sin cambios en cualquier distribución basada en Debian/Ubuntu (otras ediciones de Mint, Ubuntu, Pop!_OS, etc.), incluso con otros entornos de escritorio: las partes que dependen de Cinnamon en concreto son mínimas (principalmente los iconos de las notificaciones).

Un matiz: la instalación *automática* de dependencias que falten usa `apt`, así que en distribuciones que no lo usen (Fedora, Arch...) tendrás que instalar tú mismo `rsync`, `xdg-user-dirs` y, si quieres, `zenity` y `timeshift` con el gestor de paquetes correspondiente. Una vez instalados, el resto del script funciona igual.

## Crea un lanzador de escritorio con Scriptya

Simple-Backup es un script, así que por defecto se lanza desde la terminal. Si prefieres tenerlo como una aplicación normal, con su propio icono en el menú de Cinnamon y/o en el escritorio, puedes usar [**Scriptya**](https://github.com/filonux/Scriptya), otra herramienta del mismo autor.

Scriptya convierte cualquier script en una aplicación independiente, con icono propio, integrada en el menú y/o el escritorio. Y de paso, desde ese mismo lanzador puedes volver a abrir Scriptya en cualquier momento para actualizar el script envuelto o desinstalar la aplicación, sin líneas de comandos.

## Dónde guarda sus cosas

Simple-Backup no toca nada fuera de tu carpeta personal salvo el propio disco de destino que tú elijas:

| Qué | Dónde |
|---|---|
| Configuración (carpetas, destino, exclusiones...) | `~/.config/simple-backup/config.conf` |
| Logs de cada copia | `~/.local/share/simple-backup/logs/` |
| Bloqueo de ejecución | `~/.config/simple-backup/backup.lock` |

El archivo de configuración se genera y se sobrescribe automáticamente desde el menú: no hace falta (ni se recomienda) editarlo a mano.

## Roadmap

Nada urgente, pero algunas ideas para cuando haya tiempo (o interés de la gente que lo use):

- [ ] **Versión en inglés** del script y de este README, si veo que hay gente fuera del ámbito hispanohablante interesada. Si es tu caso, abre una issue y así sé que merece la pena priorizarlo.
- [ ] **Paquete `.deb`** opcional, para quien prefiera instalar y actualizar con `apt` en vez de clonar el repositorio. El `.sh` suelto seguirá funcionando igual para quien lo prefiera así.
- [ ] Alternativa a cron basada en `systemd --user timers`, para quien prefiera no depender de cron.
- [ ] Soporte para más de un disco de destino configurado a la vez.

## Licencia

Publicado bajo licencia **GNU GPLv3**. Consulta el archivo [LICENSE](LICENSE) para el texto completo.

## Contribuir

Las aportaciones son bienvenidas. Antes de abrir una issue o un pull request, échale un vistazo a [CONTRIBUTING.md](.github/CONTRIBUTING.md) y al [código de conducta](.github/CODE_OF_CONDUCT.md). Para reportar un fallo o pedir una función nueva, usa las plantillas correspondientes en [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/). Si encuentras un problema de seguridad, sigue el proceso descrito en [SECURITY.md](.github/SECURITY.md) en vez de abrir una issue pública.

---

Hecho por **Filonux**.
