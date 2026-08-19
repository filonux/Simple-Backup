#!/usr/bin/env bash
# ------------------------------------------------------------------------
# Simple-Backup - copias de seguridad incrementales para Linux Mint 22.3
# (Cinnamon)
#
# Copyright (C) 2026 Filonux
# Licencia: GNU GPLv3. Consulte el archivo LICENSE para el texto completo.
#
# - Copia archivos personales (Documentos, Musica, Imagenes, Videos...) a
#   otro disco -externo o un segundo disco interno-, SOLO los archivos
#   nuevos o modificados (no crea una imagen, copia archivos reales y navegables).
# - Incluye una opcion para crear snapshots del sistema con Timeshift.
# - Permite programar la copia automatica mediante cron.
#
# Primer uso: dale permiso de ejecucion antes de lanzarlo:
#                 chmod +x simple-backup.sh
#
# Uso: ./simple-backup.sh [--auto|--version|--help]   (--help para detalle)
# ------------------------------------------------------------------------

set -uo pipefail
on_terminate() {
  local sig="$1" code="$2"
  echo
  if [[ "$sig" == "INT" ]]; then
    echo "Cancelado por el usuario."
  else
    echo "Proceso interrumpido (senal $sig)."
  fi
  # Por si la senal llega antes de definir release_lock/log.
  declare -F release_lock >/dev/null && release_lock
  declare -F log >/dev/null && log "=== Backup interrumpido (senal $sig) ===" 2>/dev/null
  exit "$code"
}
trap 'on_terminate INT 130' INT
trap 'on_terminate TERM 143' TERM
trap 'on_terminate HUP 129' HUP

APP_NAME="Simple-Backup"
VERSION="1.2.2"

if [[ $# -gt 1 ]]; then
  echo "Demasiados argumentos. Prueba: $(basename "$0") --help" >&2
  exit 1
fi

case "${1:-}" in
  --version|-v)
    echo "$APP_NAME $VERSION"
    exit 0
    ;;
  --help|-h)
    cat <<EOF
$APP_NAME $VERSION

Uso:
  $(basename "$0")               Abre el menu interactivo
  $(basename "$0") --auto        Ejecuta el backup ya configurado, sin menus (pensado para cron)
  $(basename "$0") --version|-v  Muestra la version instalada
  $(basename "$0") --help|-h     Muestra esta ayuda
EOF
    exit 0
    ;;
  --auto|"") ;;  # validos, se gestionan mas abajo una vez definidas las funciones
  *)
    echo "Opcion no reconocida: ${1:-}" >&2
    echo "Prueba: $(basename "$0") --help" >&2
    exit 1
    ;;
esac

# --------------------------------------------------------------------------
# Rutas y constantes
# --------------------------------------------------------------------------
CONFIG_DIR="$HOME/.config/simple-backup"
CONFIG_FILE="$CONFIG_DIR/config.conf"
LOG_DIR="$HOME/.local/share/simple-backup/logs"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/backup_${TIMESTAMP}_$$.log"  # PID: TIMESTAMP solo tiene resolucion de 1s
SCRIPT_PATH="$(readlink -f "$0")"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" || {
  echo "Error: no se pudieron crear las carpetas de configuracion." >&2
  exit 1
}
chmod 700 "$CONFIG_DIR" 2>/dev/null || true

# --------------------------------------------------------------------------
# Colores (se desactivan si la salida no es una terminal)
# --------------------------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'
  BLUE=$'\e[34m'; MAGENTA=$'\e[35m'; CYAN=$'\e[36m'
else
  BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""
fi

# --------------------------------------------------------------------------
# Configuracion por defecto (se sobreescribe al cargar config.conf)
# --------------------------------------------------------------------------
declare -a SOURCE_DIRS=()
declare -a EXCLUDES=(".cache" "*.tmp" "*.part" "*.crdownload" "*.download" "node_modules" ".thumbnails" "lost+found")
declare -a RSYNC_FLAGS=(-a)
declare -a TARGET_NAMES=()
DEST_FSTYPE=""
DEST_DIR=""
USE_DELETE="no"
LOCK_FILE="$CONFIG_DIR/backup.lock"
PS3=$'\nElige un numero: '

# --------------------------------------------------------------------------
# Utilidades de interfaz
# --------------------------------------------------------------------------
hr() { printf "%s%s%s\n" "$DIM" "────────────────────────────────────────────────────────────" "$RESET"; }

header() {
  clear
  printf "%s%s" "$CYAN" "$BOLD"
  cat <<'EOF'
  ╔══════════════════════════════════════════════════════════╗
  ║                SIMPLE-BACKUP · Linux Mint                ║
  ╚══════════════════════════════════════════════════════════╝
EOF
  printf "%s%s  v%s%s\n" "$RESET" "$DIM" "$VERSION" "$RESET"
}

msg_ok()   { printf "%s✔ %s%s\n" "$GREEN" "$1" "$RESET"; }
msg_err()  { printf "%s✘ %s%s\n" "$RED" "$1" "$RESET"; }
msg_warn() { printf "%s⚠ %s%s\n" "$YELLOW" "$1" "$RESET"; }
msg_info() { printf "%sℹ %s%s\n" "$BLUE" "$1" "$RESET"; }

pause() { read -rp "$(printf '%sPulsa Enter para continuar...%s' "$DIM" "$RESET")" _; }

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

# --------------------------------------------------------------------------
# Configuracion: cargar / guardar
# --------------------------------------------------------------------------
load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
}

save_config() {
  # OJO: no usar "declare -p" aqui: load_config() hace `source` dentro de una
  # funcion, y "declare" crearia variables LOCALES que tapan a las globales.
  local x
  {
    echo "# Configuracion de $APP_NAME - generado automaticamente, no editar a mano"
    printf 'SOURCE_DIRS=('
    for x in "${SOURCE_DIRS[@]}"; do printf '%q ' "$x"; done
    printf ')\n'
    printf 'EXCLUDES=('
    for x in "${EXCLUDES[@]}"; do printf '%q ' "$x"; done
    printf ')\n'
    printf 'DEST_DIR=%q\n' "$DEST_DIR"
    printf 'USE_DELETE=%q\n' "$USE_DELETE"
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

# --------------------------------------------------------------------------
# Bloqueo de ejecucion (evita dos copias simultaneas contra el mismo destino)
# --------------------------------------------------------------------------
acquire_lock() {
  exec {LOCK_FD}>"$LOCK_FILE" 2>/dev/null || return 1
  if ! flock -n "$LOCK_FD"; then
    # Ya hay otra copia en curso: cerramos el descriptor para no dejarlo
    # huerfano si el usuario reintenta varias veces en la misma sesion.
    exec {LOCK_FD}>&- 2>/dev/null
    unset LOCK_FD
    return 1
  fi
}

release_lock() {
  if [[ -n "${LOCK_FD:-}" ]]; then
    flock -u "$LOCK_FD" 2>/dev/null
    exec {LOCK_FD}>&- 2>/dev/null
    unset LOCK_FD
  fi
  return 0
}

# --------------------------------------------------------------------------
# Dependencias
# --------------------------------------------------------------------------
check_dependencies() {
  local missing=() missing_optional=()
  command -v rsync        &>/dev/null || missing+=("rsync")
  command -v xdg-user-dir  &>/dev/null || missing+=("xdg-user-dirs")
  # zenity es opcional: sin el, el script pide las rutas escritas a mano.
  command -v zenity        &>/dev/null || missing_optional+=("zenity")

  if [[ ${#missing[@]} -gt 0 || ${#missing_optional[@]} -gt 0 ]]; then
    [[ ${#missing[@]} -gt 0 ]] && msg_warn "Faltan dependencias necesarias: ${missing[*]}"
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
      msg_warn "Falta una dependencia opcional: ${missing_optional[*]} (explorador grafico de carpetas)."
    fi
    read -rp "¿Instalarlas ahora con apt? (s/n): " ans
    if [[ "$ans" =~ ^[sS]$ ]]; then
      sudo apt update && sudo apt install -y "${missing[@]}" "${missing_optional[@]}"
      # Se reverifica: "apt install" puede fallar a medias sin devolver error.
      local still_missing=()
      command -v rsync        &>/dev/null || still_missing+=("rsync")
      command -v xdg-user-dir  &>/dev/null || still_missing+=("xdg-user-dirs")
      if [[ ${#still_missing[@]} -gt 0 ]]; then
        msg_err "No se pudieron instalar: ${still_missing[*]}. El script no funcionara correctamente sin ellas."
      else
        msg_ok "Dependencias instaladas correctamente."
      fi
    else
      [[ ${#missing[@]} -gt 0 ]] && msg_warn "El script puede fallar mas adelante sin: ${missing[*]}"
    fi
    pause
  fi
}

# --------------------------------------------------------------------------
# Explorador grafico clasico de carpetas (zenity), con reserva a texto
# --------------------------------------------------------------------------
# Sin zenity o sin sesion grafica: no imprime nada y falla; quien llame
# debe pedir entonces la ruta escrita a mano.
pick_folder_dialog() {
  local title="$1" start_dir="${2:-$HOME}"
  command -v zenity &>/dev/null || return 1
  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] || return 1
  [[ -d "$start_dir" ]] || start_dir="$HOME"
  zenity --file-selection --directory --title="$title" --filename="${start_dir%/}/" 2>/dev/null
}

# --------------------------------------------------------------------------
# Deteccion de carpetas personales estandar (respeta idioma del sistema)
# --------------------------------------------------------------------------
autodetect_sources() {
  local keys=(DOCUMENTS MUSIC PICTURES VIDEOS DOWNLOAD DESKTOP PUBLICSHARE TEMPLATES)
  local dirs=()
  local k path
  for k in "${keys[@]}"; do
    path="$(xdg-user-dir "$k" 2>/dev/null || true)"
    if [[ -n "$path" && -d "$path" && "$path" != "$HOME" ]] && ! array_contains "$path" "${dirs[@]}"; then
      dirs+=("$path")
    fi
  done
  printf '%s\n' "${dirs[@]}"
}

array_contains() {
  local needle="$1"; shift
  local x
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

remove_from_array_by_value() {
  # $1 = nombre del array (por referencia), $2 = valor a quitar
  local -n arr_ref="$1"
  local target="$2"
  local tmp=()
  local x
  for x in "${arr_ref[@]}"; do
    [[ "$x" != "$target" ]] && tmp+=("$x")
  done
  arr_ref=("${tmp[@]}")
}

# Expande "~" o "~/resto" a $HOME. A diferencia de "${v/#\~/$HOME}", NO toca
# "~otrousuario/..." (eso convertiria la ruta en algo inventado e incorrecto).
expand_tilde() {
  local v="$1"
  # shellcheck disable=SC2088  # comparacion de texto literal, no expansion de shell
  [[ "$v" == "~" || "$v" == "~/"* ]] && v="$HOME${v#\~}"
  printf '%s' "$v"
}

# Avisa si la carpeta nueva coincide, contiene o esta contenida en un origen
# ya configurado (incluso via symlink): no rompe nada, pero duplica contenido.
check_source_overlap() {
  local new="$1" rp_new rp_s s
  rp_new="$(readlink -f "$new" 2>/dev/null)" || return 1
  for s in "${SOURCE_DIRS[@]}"; do
    rp_s="$(readlink -f "$s" 2>/dev/null)" || continue
    [[ -z "$rp_s" ]] && continue
    if [[ "$rp_s" == "$rp_new" ]]; then
      msg_warn "'$new' apunta a la misma carpeta real que '$s' (ya configurada), aunque la ruta escrita sea distinta."
      return 0
    fi
    if [[ "$rp_new" == "$rp_s"/* ]]; then
      msg_warn "'$new' ya esta dentro de '$s', que ya tienes configurada como origen."
      return 0
    fi
    if [[ "$rp_s" == "$rp_new"/* ]]; then
      msg_warn "'$s' (ya configurada) esta dentro de '$new': su contenido se copiaria dos veces."
      return 0
    fi
  done
  return 1
}

# --------------------------------------------------------------------------
# Menu: configurar carpetas de origen
# --------------------------------------------------------------------------
configure_paths() {
  while true; do
    header
    printf "%sConfiguracion de rutas%s\n" "$BOLD" "$RESET"
    hr
    msg_info "Carpetas de origen actuales:"
    if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
      echo "  (ninguna configurada)"
    else
      local d
      for d in "${SOURCE_DIRS[@]}"; do echo "  - $d"; done
    fi
    echo
    echo "  1) Detectar automaticamente (Documentos, Musica, Imagenes, Videos, Descargas...)"
    echo "  2) Anadir una carpeta manualmente"
    echo "  3) Quitar una carpeta de la lista"
    echo "  4) Vaciar lista de origenes"
    echo "  5) Configurar disco de destino (externo o interno)"
    echo "  6) Configurar exclusiones"
    echo "  0) Volver"
    hr
    read -rp "Elige una opcion: " opt || return  # entrada cerrada (EOF): no repetir para siempre, volver
    case "$opt" in
      1)
        local detected=()
        while IFS= read -r d; do [[ -n "$d" ]] && detected+=("$d"); done < <(autodetect_sources)
        local d
        for d in "${detected[@]}"; do
          array_contains "$d" "${SOURCE_DIRS[@]}" || SOURCE_DIRS+=("$d")
        done
        save_config
        msg_ok "Carpetas detectadas anadidas."
        pause
        ;;
      2)
        local newdir=""
        newdir="$(pick_folder_dialog "Elige la carpeta a incluir en la copia" "$HOME")"
        if [[ -z "$newdir" ]]; then
          # Sin zenity, sin sesion grafica, o el usuario pulso "Cancelar":
          # se ofrece escribir la ruta a mano como alternativa.
          read -rp "Ruta completa de la carpeta a incluir (Enter para cancelar): " newdir
        fi
        newdir="$(expand_tilde "$newdir")"
        [[ "$newdir" != "/" ]] && newdir="${newdir%/}"
        if [[ -z "$newdir" ]]; then
          msg_warn "Operacion cancelada."
        elif [[ ! -d "$newdir" ]]; then
          msg_err "Esa carpeta no existe."
        elif array_contains "$newdir" "${SOURCE_DIRS[@]}"; then
          msg_warn "Esa carpeta ya esta en la lista de origenes."
        else
          local add_ok=1
          if check_source_overlap "$newdir"; then
            read -rp "¿Anadir de todas formas? (s/n): " ans
            [[ "$ans" =~ ^[sS]$ ]] || add_ok=0
          fi
          if [[ "$add_ok" -eq 1 ]]; then
            SOURCE_DIRS+=("$newdir")
            save_config
            msg_ok "Anadida: $newdir"
          else
            msg_warn "Operacion cancelada."
          fi
        fi
        pause
        ;;
      3)
        if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
          msg_warn "No hay carpetas para quitar."
        else
          select d in "${SOURCE_DIRS[@]}" "Cancelar"; do
            if [[ "$d" == "Cancelar" ]]; then break; fi
            if [[ -z "$d" ]]; then msg_err "Opcion no valida, prueba de nuevo."; continue; fi
            remove_from_array_by_value SOURCE_DIRS "$d"
            save_config
            msg_ok "Eliminada: $d"
            break
          done
        fi
        pause
        ;;
      4)
        SOURCE_DIRS=()
        save_config
        msg_ok "Lista de origenes vaciada."
        pause
        ;;
      5) configure_destination ;;
      6) configure_excludes ;;
      0) return ;;
      *) msg_err "Opcion no valida"; sleep 1 ;;
    esac
  done
}

# --------------------------------------------------------------------------
# Menu: configurar disco de destino
# --------------------------------------------------------------------------
# RM ("removable") del disco fisico que contiene el dispositivo lsblk $1
# (p.ej. "sdb1"). Salida: "1" extraible, "0" interno, "" si no se determina.
disk_removable_flag() {
  local name="$1" pk
  [[ -n "$name" ]] || return 0
  pk="$(lsblk -no PKNAME "/dev/$name" 2>/dev/null)"
  [[ -z "$pk" ]] && pk="$name"
  # -r (raw): sin esto, lsblk rellena RM con espacios ("0"->" 0") y la
  # comparacion con "0"/"1" en las funciones que llaman a esto nunca cuadra.
  lsblk -dnro RM "/dev/$pk" 2>/dev/null
}

list_mounted_drives() {
  # "lsblk -P" (pares CLAVE="VALOR") en vez del modo columnas: si la
  # etiqueta o el punto de montaje llevan espacios ("Mi Disco Externo"),
  # el parseo por columnas los cortaria a mitad de ruta.
  # Se listan todas las unidades montadas, internas o externas: un segundo
  # disco interno es un destino tan valido como uno externo. Solo se
  # excluyen los puntos de montaje propios del sistema.
  local line name type mp size label kind
  lsblk -P -o NAME,TYPE,MOUNTPOINT,SIZE,LABEL 2>/dev/null | while IFS= read -r line; do
    type="$(grep -oP 'TYPE="\K[^"]*' <<<"$line")"
    # No solo "part": incluye discos sin tabla de particiones y unidades LUKS ("crypt").
    case "$type" in rom|loop) continue ;; esac
    mp="$(grep -oP 'MOUNTPOINT="\K[^"]*' <<<"$line")"
    [[ -n "$mp" ]] || continue
    case "$mp" in
      /|/home|/boot|/boot/efi|/efi|/var|/usr|/opt|/tmp|"[SWAP]") continue ;;
    esac
    name="$(grep -oP 'NAME="\K[^"]*' <<<"$line")"
    size="$(grep -oP 'SIZE="\K[^"]*' <<<"$line")"
    label="$(grep -oP 'LABEL="\K[^"]*' <<<"$line")"
    case "$(disk_removable_flag "$name")" in
      1) kind="externo" ;;
      0) kind="interno" ;;
      *) kind="tipo desconocido" ;;
    esac
    printf '%s\t%s\t%s\t%s\n' "$mp" "$size" "${label:-sin etiqueta}" "$kind"
  done
}

warn_if_not_removable() {
  # Aviso informativo (no bloqueante): si es interno en vez de extraible,
  # el backup funciona igual; es solo para confirmar que es la unidad correcta.
  local path="$1" src rm
  command -v findmnt &>/dev/null && command -v lsblk &>/dev/null || return 0
  src="$(findmnt -no SOURCE --target "$path" 2>/dev/null)" || return 0
  src="${src%%\[*}"  # quita sufijo de subvolumen btrfs, p.ej. /dev/sdb1[/@datos]
  rm="$(disk_removable_flag "$(basename "$src")")"
  if [[ "$rm" == "0" ]]; then
    msg_info "'$path' esta en almacenamiento interno (no extraible), no en un disco externo."
    msg_info "Si es a proposito (p.ej. un segundo disco interno), no tienes que hacer nada mas."
  fi
}

configure_destination() {
  header
  printf "%sDisco de destino%s\n" "$BOLD" "$RESET"
  hr
  msg_info "Destino actual: ${DEST_DIR:-(sin configurar)}"
  echo
  msg_info "Unidades detectadas (se indica si cada una es interna o externa):"
  local found_paths=() found_display=()
  local mp size label kind
  while IFS=$'\t' read -r mp size label kind; do
    [[ -n "$mp" ]] || continue
    found_paths+=("$mp")
    found_display+=("$mp  ($label, $size, $kind)")
  done < <(list_mounted_drives)

  if [[ ${#found_paths[@]} -eq 0 ]]; then
    msg_warn "No se detecto ninguna otra unidad montada (ni externa ni un segundo disco interno)."
    msg_warn "Conecta o monta el disco y vuelve a intentarlo, o escribe la ruta manualmente."
  else
    local i=1 f
    for f in "${found_display[@]}"; do
      echo "  $i) $f"
      ((i+=1))
    done
  fi
  echo
  echo "Escribe el numero de la unidad detectada, pulsa 'g' para elegir la"
  echo "carpeta con el explorador grafico clasico, o pega la ruta completa"
  echo "(puedes anadir una subcarpeta, por ejemplo: /media/usuario/MiDisco/Backups)."
  read -rp "> " sel
  local chosen=""
  if [[ "$sel" =~ ^[0-9]+$ ]] && (( 10#$sel >= 1 && 10#$sel <= ${#found_paths[@]} )); then
    chosen="${found_paths[$((10#$sel - 1))]}"
  elif [[ "$sel" == "g" || "$sel" == "G" ]]; then
    local start_dir="${found_paths[0]:-/media/${USER:-}}"
    chosen="$(pick_folder_dialog "Elige la carpeta de destino de las copias" "$start_dir")"
    if [[ -z "$chosen" ]]; then
      msg_warn "No se selecciono ninguna carpeta (¿cancelado, o zenity no disponible?)."
      pause; return
    fi
  else
    chosen="$(expand_tilde "$sel")"
  fi
  # Zenity suele devolver la ruta con "/" al final; se normaliza para que
  # DEST_DIR quede igual sin importar como se eligio.
  [[ -n "$chosen" && "$chosen" != "/" ]] && chosen="${chosen%/}"

  if [[ -z "$chosen" ]]; then
    msg_warn "Operacion cancelada."
    pause; return
  fi

  if [[ ! -d "$chosen" ]]; then
    read -rp "La carpeta '$chosen' no existe. ¿Crearla ahora? (s/n): " crear
    [[ "$crear" =~ ^[sS]$ ]] && mkdir -p "$chosen" 2>/dev/null
  fi

  if [[ -d "$chosen" ]] && dest_is_writable "$chosen"; then
    DEST_DIR="$chosen"
    save_config
    msg_ok "Destino configurado: $DEST_DIR"
    warn_if_not_removable "$DEST_DIR"
  else
    msg_err "La ruta no existe o no se puede escribir en ella (¿disco en solo lectura?)."
  fi
  pause
}

# --------------------------------------------------------------------------
# Menu: exclusiones
# --------------------------------------------------------------------------
configure_excludes() {
  while true; do
    header
    printf "%sExclusiones actuales%s\n" "$BOLD" "$RESET"
    hr
    if [[ ${#EXCLUDES[@]} -eq 0 ]]; then
      echo "  (ninguna)"
    else
      local i=1 e
      for e in "${EXCLUDES[@]}"; do echo "  $i) $e"; ((i+=1)); done
    fi
    echo
    echo "  a) Anadir exclusion"
    echo "  r) Quitar exclusion"
    echo "  0) Volver"
    hr
    read -rp "Elige una opcion: " opt || return  # entrada cerrada (EOF): volver en vez de repetir para siempre
    case "$opt" in
      a)
        read -rp "Patron a excluir (ej: *.tmp, .cache, nombre_carpeta): " pat
        if [[ -z "$pat" ]]; then
          :
        elif array_contains "$pat" "${EXCLUDES[@]}"; then
          msg_warn "Ese patron ya esta en la lista de exclusiones."
          pause
        else
          EXCLUDES+=("$pat")
          save_config
        fi
        ;;
      r)
        select e in "${EXCLUDES[@]}" "Cancelar"; do
          if [[ "$e" == "Cancelar" ]]; then break; fi
          if [[ -z "$e" ]]; then msg_err "Opcion no valida, prueba de nuevo."; continue; fi
          remove_from_array_by_value EXCLUDES "$e"
          save_config
          break
        done
        ;;
      0) return ;;
      *) msg_err "Opcion no valida"; sleep 1 ;;
    esac
  done
}

# --------------------------------------------------------------------------
# Comprobacion del destino antes de copiar
# --------------------------------------------------------------------------
same_filesystem() {
  # Compara el numero de dispositivo que reporta stat, no "mountpoint -q":
  # esa exige que la ruta sea la raiz exacta del punto de montaje, y rompe
  # el caso habitual de guardar los backups en una subcarpeta del disco.
  local a="$1" b="$2" da db
  da="$(stat -c '%d' "$a" 2>/dev/null)" || return 1
  db="$(stat -c '%d' "$b" 2>/dev/null)" || return 1
  [[ "$da" == "$db" ]]
}

dest_inside_a_source() {
  # Si el destino esta dentro de un origen, rsync copiaria una carpeta
  # dentro de si misma: cada ejecucion anidaria una copia mas.
  local d="$1" s rp_d rp_s
  rp_d="$(readlink -f "$d" 2>/dev/null)" || return 1
  for s in "${SOURCE_DIRS[@]}"; do
    rp_s="$(readlink -f "$s" 2>/dev/null)" || continue
    [[ -z "$rp_s" ]] && continue
    case "$rp_d" in
      "$rp_s"|"$rp_s"/*) return 0 ;;
    esac
  done
  return 1
}

# "-w" solo mira los permisos: si un disco NTFS no se desmonto limpiamente
# en Windows, Linux lo monta en solo lectura aunque los permisos digan que
# se puede escribir. Se comprueba con una escritura real de prueba.
dest_is_writable() {
  local d="$1" probe
  probe="$(mktemp "${d%/}/.sb-write-test.XXXXXX" 2>/dev/null)" || return 1
  rm -f -- "$probe" 2>/dev/null
  return 0
}

check_destination_mounted() {
  if [[ -z "$DEST_DIR" ]]; then
    msg_err "No hay disco de destino configurado. Ve a 'Configurar rutas'."
    return 1
  fi
  if [[ ! -d "$DEST_DIR" ]]; then
    msg_err "La carpeta de destino '$DEST_DIR' no existe. ¿Esta conectada/montada la unidad de destino?"
    return 1
  fi
  if dest_inside_a_source "$DEST_DIR"; then
    msg_err "El destino '$DEST_DIR' esta dentro de una de tus carpetas de origen."
    msg_err "Eso crearia una copia recursiva de la carpeta dentro de si misma. Elige otra ruta de destino."
    return 1
  fi
  if same_filesystem "$DEST_DIR" "$HOME" || same_filesystem "$DEST_DIR" "/"; then
    msg_warn "El destino esta en el MISMO disco que el sistema (raiz o carpeta personal), no en una unidad aparte."
    msg_warn "Si usas un disco externo o un segundo disco interno, puede que no este conectado o montado todavia."
    read -rp "¿Continuar de todas formas? (s/n): " ans
    [[ "$ans" =~ ^[sS]$ ]] || return 1
  fi
  if ! dest_is_writable "$DEST_DIR"; then
    msg_err "No se puede escribir en '$DEST_DIR'."
    msg_err "Si es un disco NTFS, puede estar en solo lectura por no haberse desmontado bien en Windows (repara con chkdsk en Windows, o 'sudo ntfsfix' en Linux)."
    return 1
  fi
  return 0
}

check_destination_mounted_auto() {
  [[ -n "$DEST_DIR" && -d "$DEST_DIR" ]] || return 1
  same_filesystem "$DEST_DIR" "$HOME" && return 1
  same_filesystem "$DEST_DIR" "/" && return 1
  dest_inside_a_source "$DEST_DIR" && return 1
  dest_is_writable "$DEST_DIR" || return 1
  return 0
}

# Aviso temprano (no bloqueante) de poco espacio; no sustituye al manejo de
# errores de rsync. "Best effort": si "df" falla, simplemente no avisa.
LOW_SPACE_THRESHOLD_KB=512000  # ~500 MB

check_disk_space_low() {
  local avail_kb
  avail_kb="$(df -Pk "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ "$avail_kb" =~ ^[0-9]+$ ]] || return 1
  (( avail_kb < LOW_SPACE_THRESHOLD_KB ))
}

# --------------------------------------------------------------------------
# Resolucion de nombres de carpeta destino
# --------------------------------------------------------------------------
# Si dos origenes distintos se llaman igual (p.ej. dos carpetas "Proyectos"
# en rutas distintas), ambos mapearian a "$DEST_DIR/Proyectos" y se
# mezclarian. Esta funcion renombra solo los que realmente colisionan
# (anteponiendo la carpeta padre), de forma estable sin importar el orden.
compute_target_names() {
  TARGET_NAMES=()
  local -a bases=()
  local s
  for s in "${SOURCE_DIRS[@]}"; do
    bases+=("$(basename "$s")")
  done

  local i j count name
  for ((i = 0; i < ${#SOURCE_DIRS[@]}; i++)); do
    count=0
    for ((j = 0; j < ${#bases[@]}; j++)); do
      [[ "${bases[$j]}" == "${bases[$i]}" ]] && ((count+=1))
    done
    if [[ $count -le 1 ]]; then
      name="${bases[$i]}"
    else
      name="$(basename "$(dirname "${SOURCE_DIRS[$i]}")")__${bases[$i]}"
    fi
    TARGET_NAMES+=("$name")
  done

  # Salvaguarda final: si dos origenes comparten tambien el nombre de su
  # carpeta padre (caso extremo), se numeran para no mezclar contenido.
  local -a seen=()
  local idx
  for ((i = 0; i < ${#TARGET_NAMES[@]}; i++)); do
    name="${TARGET_NAMES[$i]}"
    idx=2
    while array_contains "$name" "${seen[@]}"; do
      name="${TARGET_NAMES[$i]}__$idx"
      ((idx+=1))
    done
    seen+=("$name")
    TARGET_NAMES[i]="$name"
  done
}

# Avisa (en pantalla si interactive=yes, y siempre en el log) de que
# carpetas de origen se han renombrado en el destino por colision de
# nombres, para que el usuario sepa donde encontrar cada cosa.
warn_target_name_collisions() {
  local interactive="${1:-yes}"
  local i base
  for ((i = 0; i < ${#SOURCE_DIRS[@]}; i++)); do
    base="$(basename "${SOURCE_DIRS[$i]}")"
    [[ "${TARGET_NAMES[$i]}" == "$base" ]] && continue
    log "AVISO: nombre de carpeta duplicado; '${SOURCE_DIRS[$i]}' se guarda en el destino como '${TARGET_NAMES[$i]}' para no mezclarla con otro origen del mismo nombre."
    if [[ "$interactive" == "yes" ]]; then
      msg_warn "'${SOURCE_DIRS[$i]}' se guardara como '${TARGET_NAMES[$i]}' (hay otro origen con el mismo nombre de carpeta)."
    fi
  done
}

# --------------------------------------------------------------------------
# Banderas de rsync segun el sistema de archivos del destino
# --------------------------------------------------------------------------
# FAT/exFAT/NTFS no soportan permisos Unix ni propietario/grupo: con "-a"
# rsync avisaria "operation not permitted" (codigo 23) aunque la copia sea
# correcta. Tampoco guardan la hora con precision de segundo, asi que sin
# --modify-window rsync recopiaria archivos sin cambios reales.
#
# FAT32 (a diferencia de exFAT/NTFS) tampoco admite archivos de 4 GiB o mas:
# se detectan antes de copiar para avisar con claridad (ver check_fat_file_
# size_limit), y ademas se le anade --max-size para que rsync los OMITA de
# forma limpia (rc 0) en vez de intentarlos y fallar a mitad de copia (rc 11,
# como ocurre de verdad al agotarse el disco).
FAT_MAX_FILE_BYTES=4294967295  # 4 GiB - 1

rsync_flags_for_fstype() {
  local fstype="$1"
  case "$fstype" in
    # Sin -l: ni FAT ni NTFS (via ntfs-3g/ntfs3) crean symlinks salvo montaje
    # especial; con -l rsync fallaba con "Operation not permitted" en ellos.
    vfat|fat|fat32|msdos)
      echo "-rt --modify-window=2 --max-size=${FAT_MAX_FILE_BYTES}"
      ;;
    exfat|ntfs|ntfs3|fuseblk)
      echo "-rt --modify-window=2"
      ;;
    *)
      echo "-a"
      ;;
  esac
}

find_files_over_fat_limit() {
  local s
  for s in "${SOURCE_DIRS[@]}"; do
    [[ -d "$s" ]] || continue
    find "$s" -xdev -type f -size "+${FAT_MAX_FILE_BYTES}c" 2>/dev/null
  done
}

check_fat_file_size_limit() {
  local interactive="${1:-yes}"
  local -a big=()
  local f
  while IFS= read -r f; do big+=("$f"); done < <(find_files_over_fat_limit)
  [[ ${#big[@]} -eq 0 ]] && return 0
  log "AVISO: ${#big[@]} archivo(s) de mas de 4 GiB no caben en un destino FAT32:"
  for f in "${big[@]}"; do log "  - $f"; done
  if [[ "$interactive" == "yes" ]]; then
    msg_warn "${#big[@]} archivo(s) superan los 4 GiB: FAT32 no los admite y no se copiaran (limitacion del formato del disco, no del script)."
    msg_warn "Detalle completo en el log. Para guardarlos, usa un destino exFAT o NTFS."
  fi
}

build_rsync_flags() {
  local interactive="${1:-yes}"
  local fstype
  fstype="$(findmnt -no FSTYPE --target "$DEST_DIR" 2>/dev/null || true)"
  DEST_FSTYPE="$fstype"
  read -ra RSYNC_FLAGS <<< "$(rsync_flags_for_fstype "$fstype")"
  case "$fstype" in
    vfat|fat|fat32|msdos|exfat|ntfs|ntfs3|fuseblk)
      [[ "$interactive" == "yes" ]] && msg_warn "El destino usa el sistema de archivos '$fstype': no conserva permisos Unix ni propietario (limitacion del propio disco, tus archivos no se ven afectados)."
      ;;
  esac
  case "$fstype" in
    vfat|fat|fat32|msdos) check_fat_file_size_limit "$interactive" ;;
  esac
  log "Sistema de archivos del destino: '${fstype:-desconocido}', banderas rsync: ${RSYNC_FLAGS[*]}"
}

# Clasifica el codigo de salida de rsync: "ok" (0), "warn" (situaciones
# normales que no son un fallo real) o "error" (fallo real que hay que mirar).
classify_rsync_rc() {
  case "$1" in
    0) echo "ok" ;;
    24) echo "warn" ;;  # archivos que desaparecieron mientras se copiaba (normal)
    23) echo "warn" ;;  # transferencia parcial: ver rsync_warn_reason() para el motivo probable
    *) echo "error" ;;
  esac
}

# Explica el motivo mas probable de un aviso "menor" (rc 23/24): el codigo
# 23 tambien aparece por errores de permisos en discos con atributos Unix
# (ext4, btrfs...), no solo por limitaciones de FAT/exFAT/NTFS.
rsync_warn_reason() {
  local rc="$1"
  if [[ "$rc" == "24" ]]; then
    echo "archivos que cambiaron o se borraron mientras se copiaban, normal"
    return
  fi
  case "$DEST_FSTYPE" in
    vfat|fat|fat32|msdos|exfat|ntfs|ntfs3|fuseblk)
      echo "normal en discos FAT/exFAT/NTFS" ;;
    *)
      echo "revisa el log, puede haber archivos que no se copiaron" ;;
  esac
}

# Envia una notificacion de escritorio sin que un fallo (p.ej. cron sin
# sesion grafica activa, sin DISPLAY/DBUS) contamine el codigo de salida
# del script. Sin esto, un backup CORRECTO ejecutado por cron podia acabar
# reportando un fallo solo porque no habia sesion de escritorio disponible.
send_notification_safe() {
  local icon="$1" text="$2"
  command -v notify-send &>/dev/null || return 0
  notify-send -i "$icon" "$APP_NAME" "$text" >/dev/null 2>&1 || true
  return 0
}

# Con backups diarios por cron, un log por ejecucion acumularia miles de
# ficheros al cabo de los anos. Se conservan los ultimos LOGS_TO_KEEP y se
# borran los demas al terminar cada backup (interactivo o automatico).
LOGS_TO_KEEP=90

cleanup_old_logs() {
  shopt -s nullglob
  local logs=("$LOG_DIR"/backup_*.log)
  shopt -u nullglob
  local count=${#logs[@]}
  if (( count > LOGS_TO_KEEP )); then
    local to_delete=$(( count - LOGS_TO_KEEP ))
    # Nombres de log controlados, ver explicacion en view_logs.
    # shellcheck disable=SC2012
    ls -1t "$LOG_DIR"/backup_*.log | tail -n "$to_delete" | while IFS= read -r f; do
      rm -f -- "$f"
    done
    log "Limpieza: eliminados $to_delete log(s) antiguos (se conservan los ultimos $LOGS_TO_KEEP)"
  fi
}

# --------------------------------------------------------------------------
# Sincroniza UN origen con rsync y clasifica el resultado. El log siempre se
# escribe; mensajes en pantalla y progreso solo si interactive=yes. La usan
# tanto run_backup como run_auto (evita duplicar la logica de sincronizado).
# Devuelve: 0=ok  1=error  2=aviso menor (detalle en LOG_FILE).
# --------------------------------------------------------------------------
sync_one_source() {
  local src="$1" target="$2" interactive="$3" idx="${4:-}" total="${5:-}"
  local exclude_args=() e delete_flag=() rc rc_class outfd
  for e in "${EXCLUDES[@]}"; do exclude_args+=(--exclude="$e"); done
  [[ "$USE_DELETE" == "yes" ]] && delete_flag=(--delete)

  if [[ "$interactive" == "yes" ]]; then
    echo
    printf "%s%s[%d/%d] Sincronizando:%s %s\n" "$MAGENTA" "$BOLD" "$idx" "$total" "$RESET" "$src"
    hr
    # --partial-dir permite reanudar archivos grandes interrumpidos en vez de
    # recopiarlos enteros. El progreso solo va a pantalla; stderr si queda
    # tambien en el log.
    # Tuberia real, NO "2> >(tee...)": esa forma deja el tee en 2o plano sin
    # que bash lo espere, y si acaba justo cuando hay un "read" en curso (p.ej.
    # el aviso de "mismo disco" al reintentar), ese "read" puede leer EOF.
    exec {outfd}>&1
    rsync "${RSYNC_FLAGS[@]}" --info=progress2 --partial-dir=.rsync-partial-tmp \
      "${delete_flag[@]}" "${exclude_args[@]}" "$src"/ "$target"/ 2>&1 1>&"$outfd" | tee -a "$LOG_FILE" >&2
    rc=${PIPESTATUS[0]}
    exec {outfd}>&-
  else
    rsync "${RSYNC_FLAGS[@]}" --partial-dir=.rsync-partial-tmp \
      "${delete_flag[@]}" "${exclude_args[@]}" "$src"/ "$target"/ >>"$LOG_FILE" 2>&1
    rc=$?
  fi
  rc_class="$(classify_rsync_rc "$rc")"
  case "$rc_class" in
    ok)
      [[ "$interactive" == "yes" ]] && msg_ok "Completado: $(basename "$target")"
      log "OK: $src -> $target"
      return 0 ;;
    warn)
      [[ "$interactive" == "yes" ]] && msg_warn "Completado con avisos menores: $(basename "$target") (codigo rsync: $rc, $(rsync_warn_reason "$rc"))"
      log "WARN ($rc): $src -> $target"
      return 2 ;;
    *)
      [[ "$interactive" == "yes" ]] && msg_err "Errores al copiar $(basename "$target") (codigo rsync: $rc)"
      log "ERROR ($rc): $src -> $target"
      return 1 ;;
  esac
}

# --------------------------------------------------------------------------
# Ejecutar la copia de seguridad (interactiva)
# --------------------------------------------------------------------------
run_backup() {
  header
  printf "%sCopia de seguridad incremental%s\n" "$BOLD" "$RESET"
  hr

  if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
    msg_err "No hay carpetas de origen configuradas."
    pause; return
  fi

  if ! command -v rsync &>/dev/null; then
    msg_err "rsync no esta instalado (sudo apt install rsync). Instalalo y vuelve a intentarlo."
    pause; return
  fi

  if ! check_destination_mounted; then
    pause; return
  fi

  if check_disk_space_low; then
    msg_warn "Queda poco espacio libre en el destino. La copia podria no completarse."
    read -rp "¿Continuar de todas formas? (s/n): " ans
    [[ "$ans" =~ ^[sS]$ ]] || { pause; return; }
  fi

  if ! acquire_lock; then
    msg_err "Ya hay una copia de seguridad en curso (o quedo un bloqueo previo en '$LOCK_FILE')."
    msg_err "Espera a que termine, o borra ese fichero si sabes que no hay ninguna copia activa."
    pause; return
  fi

  build_rsync_flags
  compute_target_names
  warn_target_name_collisions yes

  msg_info "Origen(es):"
  local s
  for s in "${SOURCE_DIRS[@]}"; do echo "  - $s"; done
  msg_info "Destino: $DEST_DIR"
  echo
  log "=== Inicio de backup ($APP_NAME v$VERSION) ==="

  local total=${#SOURCE_DIRS[@]} n=0 errors=0 warnings=0

  local src
  for src in "${SOURCE_DIRS[@]}"; do
    local base target
    base="${TARGET_NAMES[$n]}"
    target="$DEST_DIR/$base"
    ((n+=1))
    if [[ ! -d "$src" ]]; then
      msg_err "El origen '$src' ya no existe (¿se movio, se borro, o es un disco desconectado?). Se omite."
      log "ERROR: origen inaccesible, se omite: $src"
      ((errors+=1))
      continue
    fi
    if ! mkdir -p "$target"; then
      msg_err "No se pudo crear '$target' en el destino. Se omite esta carpeta."
      log "ERROR: no se pudo crear '$target'"
      ((errors+=1))
      continue
    fi
    sync_one_source "$src" "$target" yes "$n" "$total"
    case $? in
      0) ;;
      2) ((warnings+=1)) ;;
      *) ((errors+=1)) ;;
    esac
  done

  echo
  hr
  if [[ $errors -eq 0 && $warnings -eq 0 ]]; then
    msg_ok "Copia finalizada sin errores."
    log "=== Backup finalizado correctamente ==="
  elif [[ $errors -eq 0 ]]; then
    msg_ok "Copia finalizada ($warnings aviso(s) menor(es) sin importancia, ver log)."
    log "=== Backup finalizado con $warnings aviso(s) menor(es) ==="
  else
    msg_warn "Copia finalizada con $errors carpeta(s) con errores. Revisa el log."
    log "=== Backup finalizado con $errors errores ==="
  fi

  if [[ $errors -eq 0 ]]; then
    send_notification_safe "drive-harddisk" "Backup finalizado: $warnings aviso(s)."
  else
    send_notification_safe "dialog-error" "Backup finalizado con $errors error(es) ($warnings aviso(s))."
  fi

  release_lock
  cleanup_old_logs
  pause
}

# --------------------------------------------------------------------------
# Ejecucion automatica (pensada para cron, sin interaccion)
# --------------------------------------------------------------------------
run_auto() {
  if [[ ${#SOURCE_DIRS[@]} -eq 0 || -z "$DEST_DIR" ]]; then
    log "AUTO: configuracion incompleta, abortando"
    send_notification_safe "dialog-error" "Backup automatico fallido: falta configurar origen y/o destino."
    return 1
  fi
  if ! command -v rsync &>/dev/null; then
    log "AUTO: rsync no esta instalado, abortando"
    send_notification_safe "dialog-error" "Backup automatico fallido: falta instalar rsync."
    return 1
  fi
  if ! check_destination_mounted_auto; then
    log "AUTO: destino no disponible, abortando"
    send_notification_safe "dialog-error" "Backup automatico fallido: la unidad de destino no esta disponible."
    return 1
  fi

  if ! acquire_lock; then
    log "AUTO: ya hay una copia en curso, se aborta esta ejecucion programada"
    return 0
  fi

  if check_disk_space_low; then
    log "AVISO: queda poco espacio libre en el destino, se intenta el backup de todas formas"
  fi

  build_rsync_flags no
  compute_target_names
  warn_target_name_collisions no

  log "=== AUTO: inicio de backup programado ($APP_NAME v$VERSION) ==="
  local errors=0 warnings=0 src base target n=0
  for src in "${SOURCE_DIRS[@]}"; do
    base="${TARGET_NAMES[$n]}"
    ((n+=1))
    target="$DEST_DIR/$base"
    if [[ ! -d "$src" ]]; then
      log "ERROR: origen inaccesible, se omite: $src"
      ((errors+=1))
      continue
    fi
    if ! mkdir -p "$target"; then
      log "ERROR: no se pudo crear '$target'"
      ((errors+=1))
      continue
    fi
    sync_one_source "$src" "$target" no
    case $? in
      0) ;;
      2) ((warnings+=1)) ;;
      *) ((errors+=1)) ;;
    esac
  done
  log "=== AUTO: backup finalizado, errores=$errors, avisos=$warnings ==="
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup automatico: $errors error(es), $warnings aviso(s). Log: $LOG_FILE"
  if [[ $errors -eq 0 ]]; then
    send_notification_safe "drive-harddisk" "Backup automatico finalizado ($warnings aviso(s))."
  else
    send_notification_safe "dialog-error" "Backup automatico finalizado con $errors error(es) ($warnings aviso(s))."
  fi
  release_lock
  cleanup_old_logs

  # El codigo de salida (usado por "exit $?" al llamar a esta funcion) debe
  # reflejar solo si hubo errores reales, no el resultado de la notificacion
  # de escritorio (que en cron, sin sesion grafica, suele "fallar" igual).
  if [[ $errors -eq 0 ]]; then
    return 0
  else
    return 1
  fi
}

# --------------------------------------------------------------------------
# Timeshift: aviso (best-effort) de poco espacio antes de crear snapshot
# --------------------------------------------------------------------------
# Causa habitual de fallo a medias: el destino no tiene sitio suficiente
# (la primera snapshot RSYNC no va comprimida, pesa ~lo mismo que "/").
# LC_ALL=C fuerza la salida en ingles: timeshift esta traducido, y sin esto
# el texto buscado no aparece en un sistema en espanol (aviso desactivado
# en silencio).
timeshift_check_space_low() {
  local list_output free_num free_unit free_gb_int root_used_kb root_used_gb
  list_output="$(LC_ALL=C sudo timeshift --list 2>/dev/null)" || return 1

  # Senal directa de timeshift: cubre tambien la primera snapshot (sin
  # snapshots previas no imprime "GB free" y el resto no lo detectaria).
  if grep -qE "Not enough disk space|Falta espacio en el disco" <<<"$list_output"; then
    msg_warn "Timeshift indica que no hay espacio suficiente en el destino configurado."
    return 0
  fi

  # Estimacion complementaria: solo aplica si ya hay snapshots previas
  # (cuando timeshift muestra el espacio libre en su listado).
  free_num="$(grep -oP '[0-9]+(\.[0-9]+)?(?=\s*[KMGT]?B free)' <<<"$list_output" | head -n1)"
  free_unit="$(grep -oP '[0-9.]+\s*\K[KMGT]?B(?= free)' <<<"$list_output" | head -n1)"
  [[ -n "$free_num" && -n "$free_unit" ]] || return 1
  [[ "$free_unit" == "GB" ]] || return 1  # TB: de sobra; MB/KB/B: ya cubierto arriba
  root_used_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $3}')"
  [[ "$root_used_kb" =~ ^[0-9]+$ ]] || return 1
  root_used_gb=$(( root_used_kb / 1024 / 1024 ))
  free_gb_int=${free_num%%.*}
  if (( free_gb_int < root_used_gb )); then
    msg_warn "El destino de Timeshift tiene ~${free_num} GB libres, y tu particion raiz (/) usa ~${root_used_gb} GB."
    msg_warn "Una primera snapshot RSYNC no va comprimida: es posible que no quepa completa y falle a medias."
    return 0
  fi
  return 1
}

# --------------------------------------------------------------------------
# Timeshift: snapshot del sistema
# --------------------------------------------------------------------------
timeshift_backup() {
  header
  printf "%sSnapshot del sistema (Timeshift)%s\n" "$BOLD" "$RESET"
  hr

  if ! command -v timeshift &>/dev/null; then
    msg_warn "Timeshift no esta instalado."
    read -rp "¿Deseas instalarlo ahora? (s/n): " ans
    if [[ "$ans" =~ ^[sS]$ ]]; then
      sudo apt update && sudo apt install -y timeshift
      if ! command -v timeshift &>/dev/null; then
        msg_err "No se pudo instalar Timeshift. Revisa los mensajes de apt anteriores."
        pause; return
      fi
      msg_ok "Timeshift instalado correctamente."
    else
      pause; return
    fi
  fi

  echo "  1) Crear un snapshot ahora"
  echo "  2) Ver snapshots existentes (muestra tambien el destino actual)"
  echo "  3) Abrir Timeshift (interfaz grafica)"
  echo "  4) Configurar disco de destino de las snapshots"
  echo "  0) Volver"
  hr
  read -rp "Elige una opcion: " opt || return  # entrada cerrada (EOF): volver en vez de mostrar "opcion no valida"
  case "$opt" in
    1)
      if timeshift_check_space_low; then
        read -rp "¿Intentar la snapshot de todas formas? (s/n): " ans
        [[ "$ans" =~ ^[sS]$ ]] || { pause; return; }
      fi
      msg_info "Creando snapshot del sistema, esto puede tardar unos minutos..."
      log "=== Inicio snapshot Timeshift ==="
      if sudo timeshift --create --comments "Backup automatico $(date '+%Y-%m-%d %H:%M')" --scripted 2>&1 | tee -a "$LOG_FILE"; then
        msg_ok "Snapshot creado correctamente."
        log "Snapshot Timeshift creado correctamente"
        command -v notify-send &>/dev/null && notify-send -i drive-harddisk "$APP_NAME" "Snapshot del sistema creado."
      else
        msg_err "Error al crear el snapshot."
        msg_err "Causa mas habitual: no cabia en el destino (Timeshift borra la snapshot a medias al fallar; es su comportamiento normal, no borra nada mas)."
        msg_info "Log detallado de Timeshift (se conserva aunque borre la snapshot): /var/log/timeshift/"
        msg_info "Si el destino nunca se configuro a mano, ve a la opcion 4 de este menu y eligelo (disco externo o un segundo disco interno)."
        log "ERROR creando snapshot Timeshift"
      fi
      pause
      ;;
    2)
      sudo timeshift --list
      pause
      ;;
    3)
      # "sudo timeshift-gtk" a secas suele fallar (root sin acceso X11). Se
      # prioriza "timeshift-launcher" (lanzador oficial via pkexec); si no
      # esta, se cae a pkexec+DISPLAY y, en ultimo caso, a sudo directo.
      if command -v timeshift-launcher &>/dev/null; then
        msg_info "Abriendo Timeshift (te pedira la contrasena de administrador en una ventana grafica)..."
        nohup timeshift-launcher &>/dev/null &
        disown
      elif command -v timeshift-gtk &>/dev/null && command -v pkexec &>/dev/null; then
        msg_info "Abriendo Timeshift (te pedira la contrasena de administrador en una ventana grafica)..."
        nohup pkexec env DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" timeshift-gtk &>/dev/null &
        disown
      elif command -v timeshift-gtk &>/dev/null; then
        msg_warn "No se encontro 'timeshift-launcher' ni 'pkexec'; se usara sudo (puede pedir la contrasena aqui en la terminal)."
        xhost +si:localuser:root &>/dev/null || true
        sudo timeshift-gtk
        xhost -si:localuser:root &>/dev/null || true
      else
        msg_err "No se encontro la interfaz grafica de Timeshift (timeshift-gtk)."
      fi
      pause
      ;;
    4) configure_timeshift_destination ;;
    0) return ;;
    *) msg_err "Opcion no valida"; sleep 1 ;;
  esac
}

# --------------------------------------------------------------------------
# Timeshift: configurar el disco/particion de destino de las snapshots
# --------------------------------------------------------------------------
# Timeshift (a diferencia del backup personal) solo permite elegir un
# disco/particion entero como destino, no una subcarpeta.
configure_timeshift_destination() {
  header
  printf "%sDestino de las snapshots de Timeshift%s\n" "$BOLD" "$RESET"
  hr
  msg_info "Elige cualquier carpeta del disco (externo, o un segundo disco interno):"
  msg_info "el script detectara la particion real. Timeshift guardara las snapshots"
  msg_info "en la RAIZ de esa particion (carpeta 'timeshift'), no en una subcarpeta."
  echo

  msg_info "Unidades detectadas (se indica si cada una es interna o externa):"
  local found_paths=() found_display=()
  local mp size label kind
  while IFS=$'\t' read -r mp size label kind; do
    [[ -n "$mp" ]] || continue
    found_paths+=("$mp")
    found_display+=("$mp  ($label, $size, $kind)")
  done < <(list_mounted_drives)

  if [[ ${#found_paths[@]} -eq 0 ]]; then
    msg_warn "No se detecto ninguna otra unidad montada (ni externa ni un segundo disco interno)."
  else
    local i=1 f
    for f in "${found_display[@]}"; do
      echo "  $i) $f"
      ((i+=1))
    done
  fi
  echo
  echo "Escribe el numero de la unidad detectada, pulsa 'g' para elegir la"
  echo "carpeta con el explorador grafico clasico, o pega la ruta completa."
  read -rp "> " sel
  local chosen=""
  if [[ "$sel" =~ ^[0-9]+$ ]] && (( 10#$sel >= 1 && 10#$sel <= ${#found_paths[@]} )); then
    chosen="${found_paths[$((10#$sel - 1))]}"
  elif [[ "$sel" == "g" || "$sel" == "G" ]]; then
    local start_dir="${found_paths[0]:-/media/${USER:-}}"
    chosen="$(pick_folder_dialog "Elige una carpeta del disco para las snapshots de Timeshift" "$start_dir")"
    if [[ -z "$chosen" ]]; then
      msg_warn "No se selecciono ninguna carpeta."
      pause; return
    fi
  else
    chosen="$(expand_tilde "$sel")"
  fi
  [[ -n "$chosen" && "$chosen" != "/" ]] && chosen="${chosen%/}"

  if [[ -z "$chosen" ]]; then
    msg_warn "Operacion cancelada."
    pause; return
  fi

  if [[ ! -d "$chosen" ]]; then
    msg_err "La carpeta '$chosen' no existe."
    pause; return
  fi

  local device
  device="$(findmnt -no SOURCE --target "$chosen" 2>/dev/null)"
  device="${device%%\[*}"  # quita el sufijo de subvolumen btrfs, p.ej. /dev/sdb1[/@datos]
  if [[ -z "$device" ]]; then
    msg_err "No se pudo determinar la particion real de '$chosen'."
    pause; return
  fi

  msg_info "Carpeta elegida: $chosen"
  msg_info "Particion detectada: $device"
  warn_if_not_removable "$chosen"
  echo
  read -rp "¿Configurar '$device' como destino de las snapshots de Timeshift? (s/n): " ans
  if [[ ! "$ans" =~ ^[sS]$ ]]; then
    msg_warn "Cancelado."
    pause; return
  fi

  if sudo timeshift --snapshot-device "$device" --yes 2>&1 | tee -a "$LOG_FILE"; then
    msg_ok "Destino de Timeshift configurado en: $device"
    log "Destino de Timeshift configurado: $device (carpeta elegida: $chosen)"
  else
    msg_err "No se pudo configurar el destino. Revisa el mensaje anterior."
    log "ERROR configurando destino de Timeshift: $device"
  fi
  pause
}

# --------------------------------------------------------------------------
# Programar copia automatica (cron)
# --------------------------------------------------------------------------
# Linea de crontab para ejecutar este script en --auto. Escapa "%" (cron lo
# trata como salto de linea) por si SCRIPT_PATH/LOG_DIR lo contuvieran.
build_cron_line() {
  local hh="$1" dow="${2:-*}"
  local esc_path="${SCRIPT_PATH//%/\\%}" esc_log="${LOG_DIR//%/\\%}"
  printf '0 %s * * %s "%s" --auto >> "%s/cron.log" 2>&1' "$hh" "$dow" "$esc_path" "$esc_log"
}

schedule_task() {
  header
  printf "%sProgramar copia automatica%s\n" "$BOLD" "$RESET"
  hr
  msg_info "Esto anade una tarea a tu crontab de usuario para ejecutar la copia automaticamente, sin abrir el menu."
  echo
  echo "  1) Diaria (elige hora)"
  echo "  2) Semanal (elige dia y hora)"
  echo "  3) Quitar tarea programada existente"
  echo "  0) Volver"
  hr
  read -rp "Elige una opcion: " opt || return  # entrada cerrada (EOF): volver en vez de mostrar "opcion no valida"
  local cron_line=""
  case "$opt" in
    1)
      read -rp "Hora del dia (0-23): " hh
      if ! [[ "$hh" =~ ^(0?[0-9]|1[0-9]|2[0-3])$ ]]; then
        msg_err "Hora no valida. Debe ser un numero entero entre 0 y 23."
        pause; return
      fi
      cron_line="$(build_cron_line "$((10#$hh))")"
      ;;
    2)
      read -rp "Dia de la semana (0=domingo ... 6=sabado): " dow
      read -rp "Hora del dia (0-23): " hh
      if ! [[ "$dow" =~ ^[0-6]$ ]]; then
        msg_err "Dia no valido. Debe ser un numero entre 0 (domingo) y 6 (sabado)."
        pause; return
      fi
      if ! [[ "$hh" =~ ^(0?[0-9]|1[0-9]|2[0-3])$ ]]; then
        msg_err "Hora no valida. Debe ser un numero entero entre 0 y 23."
        pause; return
      fi
      cron_line="$(build_cron_line "$((10#$hh))" "$dow")"
      ;;
    3)
      if ! crontab -l 2>/dev/null | grep -qF "$SCRIPT_PATH"; then
        msg_info "No habia ninguna tarea programada de $APP_NAME."
      elif (crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH" || true) | crontab -; then
        msg_ok "Tarea programada eliminada."
        log "Tarea cron eliminada"
      else
        msg_err "No se pudo actualizar el crontab. ¿Esta instalado el servicio de cron?"
      fi
      pause; return
      ;;
    0) return ;;
    *) msg_err "Opcion no valida"; pause; return ;;
  esac
  if ( crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH" ; echo "$cron_line" ) | crontab -; then
    msg_ok "Tarea programada anadida correctamente."
    log "Tarea cron anadida: $cron_line"
  else
    msg_err "No se pudo instalar la tarea programada. Revisa que el servicio de cron este instalado y activo (systemctl status cron)."
    log "ERROR: no se pudo instalar tarea cron: $cron_line"
  fi
  pause
}

# --------------------------------------------------------------------------
# Ver historial de logs
# --------------------------------------------------------------------------
view_logs() {
  header
  printf "%sHistorial de copias%s\n" "$BOLD" "$RESET"
  hr
  shopt -s nullglob
  local logs=("$LOG_DIR"/backup_*.log)
  shopt -u nullglob
  if [[ ${#logs[@]} -eq 0 ]]; then
    msg_warn "Todavia no hay registros de copias."
    pause; return
  fi
  # Nombres de log controlados por el propio script (sin espacios ni
  # comodines), por lo que ordenarlos via "ls -t" es seguro aqui.
  local -a shown
  # shellcheck disable=SC2012
  mapfile -t shown < <(ls -1t "$LOG_DIR"/backup_*.log | head -n 15)
  local i=1 f
  for f in "${shown[@]}"; do printf "%3d\t%s\n" "$i" "$f"; ((i+=1)); done
  echo
  read -rp "Numero de log a ver (Enter para volver): " n
  if [[ -n "$n" ]]; then
    # La seleccion se resuelve sobre "shown", la misma lista ya impresa:
    # asi nunca se puede elegir un log que no aparecio en pantalla.
    if [[ "$n" =~ ^[0-9]+$ ]] && (( 10#$n >= 1 && 10#$n <= ${#shown[@]} )); then
      less "${shown[$((10#$n - 1))]}"
    else
      msg_err "Numero fuera de rango."
      pause
    fi
  fi
}

# --------------------------------------------------------------------------
# Activar / desactivar modo espejo (--delete)
# --------------------------------------------------------------------------
toggle_delete() {
  header
  printf "%sModo espejo (--delete)%s\n" "$BOLD" "$RESET"
  hr
  if [[ "$USE_DELETE" == "yes" ]]; then
    printf "Actualmente: %sACTIVADO%s\n" "$GREEN" "$RESET"
  else
    printf "Actualmente: %sDESACTIVADO%s\n" "$YELLOW" "$RESET"
  fi
  echo
  msg_warn "Si lo activas: los archivos borrados en el origen tambien se borraran en el destino (copia espejo exacta)."
  msg_info "Si lo dejas desactivado (recomendado): el destino solo acumula copias y nunca borra nada, aunque borres el original."
  echo
  read -rp "¿Activar borrado espejo? (s/n, Enter = sin cambios): " ans
  if [[ "$ans" =~ ^[sS]$ ]]; then
    USE_DELETE="yes"
  elif [[ "$ans" =~ ^[nN]$ ]]; then
    USE_DELETE="no"
  elif [[ -n "$ans" ]]; then
    msg_err "Respuesta no reconocida. Sin cambios."
  fi
  save_config
  pause
}

# --------------------------------------------------------------------------
# Asistente de primer uso
# --------------------------------------------------------------------------
first_run_wizard() {
  header
  printf "%s¡Bienvenido a %s!%s\n" "$BOLD" "$APP_NAME" "$RESET"
  hr
  msg_info "Es la primera vez que ejecutas el script. Vamos a configurarlo en un momento."
  echo
  read -rp "¿Detectar automaticamente tus carpetas personales (Documentos, Musica, Imagenes...)? (s/n): " ans
  if [[ "$ans" =~ ^[sS]$ ]]; then
    local detected=()
    while IFS= read -r d; do [[ -n "$d" ]] && detected+=("$d"); done < <(autodetect_sources)
    SOURCE_DIRS=("${detected[@]}")
    msg_ok "Carpetas detectadas: ${#SOURCE_DIRS[@]}"
  fi
  save_config
  pause
  configure_destination
}

# --------------------------------------------------------------------------
# Menu principal
# --------------------------------------------------------------------------
main_menu() {
  while true; do
    header
    printf "  %sOrigen(es):%s %d carpeta(s) configurada(s)\n" "$BOLD" "$RESET" "${#SOURCE_DIRS[@]}"
    printf "  %sDestino:%s    %s\n" "$BOLD" "$RESET" "${DEST_DIR:-(sin configurar)}"
    hr
    echo "  1) Configurar rutas de origen y destino"
    echo "  2) Ejecutar copia de seguridad ahora"
    echo "  3) Crear snapshot del sistema (Timeshift)"
    echo "  4) Programar copia automatica"
    echo "  5) Ver historial de logs"
    echo "  6) Activar/desactivar borrado espejo (--delete)"
    echo "  0) Salir"
    hr
    read -rp "  Elige una opcion: " opt || { echo; msg_warn "Entrada cerrada (EOF). Saliendo."; exit 0; }
    case "$opt" in
      1) configure_paths ;;
      2) run_backup ;;
      3) timeshift_backup ;;
      4) schedule_task ;;
      5) view_logs ;;
      6) toggle_delete ;;
      0) echo; msg_ok "Hasta la proxima."; exit 0 ;;
      *) msg_err "Opcion no valida"; sleep 1 ;;
    esac
  done
}

# --------------------------------------------------------------------------
# Punto de entrada
# --------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  IS_FIRST_RUN=false
  [[ -f "$CONFIG_FILE" ]] || IS_FIRST_RUN=true

  load_config

  if [[ "${1:-}" == "--auto" ]]; then
    run_auto
    exit $?
  fi

  check_dependencies

  if $IS_FIRST_RUN; then
    first_run_wizard
  fi

  main_menu
fi
