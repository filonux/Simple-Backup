#!/usr/bin/env bash
# ------------------------------------------------------------------------
# Simple-Backup - incremental backups for Linux Mint 22.3 (Cinnamon)
#
# Copyright (C) 2026 Filonux
# License: GNU GPLv3. See LICENSE.txt for the full text.
#
# - Copies personal files (Documents, Music, Pictures, Videos...) to
#   another drive - external or a second internal drive -, ONLY new
#   or modified files (no image is created; real, browsable files are copied).
# - Includes an option to create system snapshots with Timeshift.
# - Allows automatic backups to be scheduled with cron.
#
# First use: make the script executable before running it:
#                 chmod +x simple-backup.sh
#
# Usage: ./simple-backup.sh [--auto|--version|--help]   (--help for details)
# ------------------------------------------------------------------------

set -uo pipefail
on_terminate() {
  local sig="$1" code="$2"
  echo
  # Fallback wording in case the signal arrives before ui()/msg_*() exist yet
  # (narrow window at startup); avoids "command not found".
  if declare -F ui msg_warn msg_err >/dev/null 2>&1; then
    if [[ "$sig" == "INT" ]]; then
      msg_warn "$(ui cancelled)"
    else
      msg_err "$(ui interrupted_signal "$sig")"
    fi
  elif [[ "$sig" == "INT" ]]; then
    echo "Cancelled." >&2
  else
    echo "Process interrupted (signal $sig)." >&2
  fi
  # Only a run holding the lock (a real backup) gets a log line: Ctrl+C at a
  # menu must not leave a stray "Backup interrupted" log behind.
  local was_running="${LOCK_FD:-}"
  declare -F release_lock >/dev/null && release_lock
  [[ -n "$was_running" ]] && declare -F log >/dev/null && log "$(ui log_interrupted "$sig")" 2>/dev/null
  # Avoid leaking the rsync-output tempfile (and its .tally/.list companions)
  # if we were interrupted mid-copy or mid-preview.
  [[ -n "${CURRENT_TMP_FILE:-}" ]] && rm -f -- "$CURRENT_TMP_FILE" "$CURRENT_TMP_FILE".* 2>/dev/null
  exit "$code"
}
trap 'on_terminate INT 130' INT
trap 'on_terminate TERM 143' TERM
trap 'on_terminate HUP 129' HUP

if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
  echo "Error: the HOME environment variable is not set (or does not point to an existing folder); cannot continue. If this runs from cron, make sure HOME is set in the crontab." >&2
  exit 1
fi

APP_NAME="Simple-Backup"
VERSION="1.2.2"
UI_LANGUAGE="auto"
CONFIG_DIR="$HOME/.config/simple-backup"
CONFIG_FILE="$CONFIG_DIR/config.conf"

# --------------------------------------------------------------------------
# UI strings (EN/ES)
# --------------------------------------------------------------------------
declare -A UI_EN UI_ES

UI_EN=(
  [cancelled]='Cancelled.'
  [interrupted_signal]='Process interrupted (signal %s).'
  [log_interrupted]='=== Backup interrupted (signal %s) ==='
  [too_many_args]='Too many arguments. Try: %s --help'
  [select_prompt]='Choose a number: '
  [unknown_option]='Unknown option: %s'
  [try_help]='Try: %s --help'
  [config_dirs_error]='Error: could not create configuration directories.'
  [config_save_error]='Error: could not save the configuration file.'
  [log_config_save_error]="ERROR: could not save configuration to '%s'"
  [press_enter]='Press Enter to continue...'
  [help_usage]='Usage:'
  [help_interactive]='%s               Open the interactive menu'
  [help_auto]='%s --auto        Run the configured backup without the interactive menu (cron)'
  [help_version]='%s --version|-v  Show the installed version'
  [help_help]='%s --help|-h     Show this help'
  [dep_required]='Missing required dependencies: %s'
  [dep_optional]='Missing optional dependency: %s (graphical folder picker).'
  [install_missing]='Install them now with apt? (y/n): '
  [dep_install_fail]='Could not install: %s. The script will not work correctly without them.'
  [dep_installed]='Dependencies installed successfully.'
  [dep_may_fail]='The script may fail later without these dependencies: %s'
  [sudo_missing]='sudo is not available: install the missing packages manually (as root, or with your distribution package manager).'
  [same_real_folder]="'%s' resolves to the same folder as '%s' (already configured), although the entered path is different."
  [nested_source]="'%s' is already inside '%s', which is configured as a source."
  [parent_source]="'%s' (already configured) is inside '%s': its contents would be copied twice."
  [paths_config]='Path configuration'
  [current_sources]='Current source folders:'
  [none_configured]='  (none configured)'
  [not_configured]='not configured'
  [currently]='Currently: '
  [external]='external'
  [internal]='internal'
  [unknown_type]='unknown type'
  [no_label]='no label'
  [timeshift_comment]='Automatic backup %s'
  [timeshift_snapshot_notification]='System snapshot created.'
  [auto_finished]='Automatic backup finished. Warnings: %s.'
  [auto_finished_errors]='Automatic backup finished. Errors: %s; warnings: %s.'
  [log_backup_start]='=== Backup started (%s v%s) ==='
  [log_backup_ok]='=== Backup finished successfully ==='
  [log_backup_warn]='=== Backup finished with %s minor warning(s) ==='
  [log_ok]='OK: %s -> %s'
  [log_warn]='WARN (%s): %s -> %s'
  [log_error]='ERROR (%s): %s -> %s'
  [log_cleanup]='Old log files removed: %s; kept the %s most recent.'
  [log_backup_errors]='=== Backup finished with %s error(s) ==='
  [log_collision]='WARNING: duplicate folder name; '\''%s'\'' is stored as '\''%s'\'' to avoid mixing it with another source of the same name.'
  [log_fat]='WARNING: %s file(s) larger than 4 GiB do not fit on a FAT32 destination:'
  [log_filesystem]='Destination filesystem: '\''%s'\'', rsync flags: %s'
  [log_auto_start]='=== AUTO: scheduled backup started (%s v%s) ==='
  [log_auto_end]='=== AUTO: backup finished, errors=%s, warnings=%s ==='
  [log_auto_config]='AUTO: configuration incomplete, aborting'
  [log_auto_rsync]='AUTO: rsync is not installed, aborting'
  [log_auto_destination]='AUTO: destination is unavailable, aborting'
  [log_auto_same_disk]='WARNING: destination is on the same disk as the system (root or home filesystem); continuing as configured'
  [log_auto_mount_lost]="AUTO: the destination is no longer on its drive (expected mount point: '%s'); aborting so the system disk is not filled"
  [log_auto_lock]='AUTO: a backup is already running; scheduled run aborted'
  [log_cron_error]='Could not install the scheduled task: %s'
  [log_low_space]='WARNING: little free space remains on the destination; backup will be attempted anyway'
  [log_source_missing]='ERROR: source is inaccessible; skipping: %s'
  [log_source_empty]='WARNING: source is empty and mirror mode is on; skipped so its backup is not wiped: %s'
  [log_target_create]="ERROR: could not create '%s'"
  [backup_notification]='Backup finished. Warnings: %s.'
  [backup_error_notification]='Backup finished. Errors: %s; warnings: %s.'
  [detect_sources]='  1) Detect personal folders automatically (Documents, Music, Pictures, Videos, Downloads...)'
  [add_folder]='  2) Add a folder manually'
  [remove_folder]='  3) Remove a folder from the list'
  [clear_sources]='  4) Clear source list'
  [configure_destination]='  5) Configure destination disk (external or internal)'
  [configure_excludes]='  6) Configure exclusions'
  [estimate_space]='  7) Estimate space needed'
  [back]='  0) Back'
  [choose_option]='Choose an option: '
  [detect_no_new]='No new personal folders were detected to add.'
  [detect_ask]='Add %s (%s)? (y/n): '
  [detect_added_none]='No folders were added.'
  [choose_folder]='Choose the folder to include in the backup'
  [enter_source_path]='Full path of the folder to include (Enter to cancel): '
  [cancelled_op]='Operation cancelled.'
  [folder_missing]='That folder does not exist.'
  [path_not_absolute]='Enter a full path starting with / or ~ (not a relative one).'
  [already_source]='That folder is already in the source list.'
  [add_anyway]='Add anyway? (y/n): '
  [added_path]='Added: %s'
  [no_sources_remove]='There are no folders to remove.'
  [invalid_option_retry]='Invalid option, try again.'
  [removed_path]='Removed: %s'
  [sources_cleared]='Source list cleared.'
  [clear_sources_confirm]='Remove all %s configured source folder(s) from the list? (y/n): '
  [invalid_option]='Invalid option'
  [internal_storage]="'%s' is on internal (non-removable) storage, not an external disk."
  [internal_ok]='If this is intentional (e.g. a second internal disk), you do not need to do anything else.'
  [destination_disk]='Destination disk'
  [current_destination]='Current destination: %s'
  [detected_drives]='Detected drives (each is marked as internal or external):'
  [no_other_drive]='No other mounted drive detected (neither external nor a second internal disk).'
  [mount_drive]='Connect or mount the drive and try again, or enter the path manually.'
  [select_drive]='Enter the number of a detected drive, press '\''g'\'' to choose the'
  [select_drive2]='folder with the classic graphical picker, or paste the full path'
  [select_drive3]='(you can add a subfolder, for example: /media/user/MyDisk/Backups).'
  [choose_destination]='Choose the backup destination folder'
  [no_folder_selected]='No folder was selected (operation cancelled or Zenity is unavailable).'
  [create_folder]='The folder '\''%s'\'' does not exist. Create it now? (y/n): '
  [destination_set]='Destination configured: %s'
  [destination_not_writable]='The path does not exist or is not writable (the disk may be read-only).'
  [exclusions]='Current exclusions'
  [none]='  (none)'
  [add_exclusion]='  a) Add exclusion'
  [remove_exclusion]='  r) Remove exclusion'
  [exclusion_pattern]='Pattern to exclude, e.g. *.tmp, .cache, folder_name (Enter to cancel): '
  [enter_cancel_prompt]='(Enter to cancel) > '
  [exclusion_duplicate]='That pattern is already in the exclusion list.'
  [exclusion_added]='Exclusion added: %s'
  [exclusion_removed]='Exclusion removed: %s'
  [no_exclusions_remove]='There are no exclusions to remove.'
  [no_destination]='No destination disk configured. In the main menu, choose option 1 and then option 5.'
  [destination_missing]="The destination folder '%s' does not exist. Is the destination drive connected/mounted?"
  [destination_inside]='The destination %s is inside one of your source folders.'
  [recursive_copy]='That would create a recursive copy of the folder into itself. Choose another destination path.'
  [same_disk]='The destination is on the SAME disk as the system (root or home filesystem), not on a separate drive.'
  [same_disk_hint]='If you are using an external drive or a second internal disk, it may not be connected or mounted yet.'
  [continue_anyway]='Continue anyway? (y/n): '
  [no_write]="Cannot write to '%s'."
  [ntfs_readonly]="If this is an NTFS disk, it may be read-only because it was not cleanly unmounted in Windows (repair with chkdsk in Windows, or 'sudo ntfsfix' on Linux)."
  [collision]="'%s' will be stored as '%s' (another source has the same folder name)."
  [fat_limit]='Files over 4 GiB: %s. FAT32 does not support them, so they will not be copied (filesystem limitation, not a script error).'
  [fat_detail]='Full details are in the log. To preserve these files, use an exFAT or NTFS destination.'
  [no_unix_metadata]="The destination uses the '%s' filesystem: Unix permissions and owner are not preserved (filesystem limitation; your files are not otherwise affected)."
  [rsync_reason_changed]='source files that disappeared during the copy; this can be normal'
  [rsync_reason_fat]='normal on FAT/exFAT/NTFS filesystems'
  [rsync_reason_log]='check the log; some files may not have been copied'
  [syncing]='[%d/%d] Synchronizing: %s'
  [copied]='Completed: %s'
  [copied_warn]='Completed with minor warnings: %s (rsync exit code: %s, %s)'
  [copy_error]='Error copying %s (rsync exit code: %s)'
  [backup_title]='Incremental backup'
  [no_source_config]='No source folders are configured.'
  [rsync_missing]='rsync is not installed (sudo apt install rsync). Install it and try again.'
  [low_space]='There is little free space left on the destination. The backup may not complete.'
  [estimate_used]='Estimated size of the selected folders: ~%s'
  [estimate_free]='Free space at the destination: ~%s'
  [estimate_fits]='This fits within the free space available at the destination.'
  [estimate_wait]='Calculating sizes (may take a while on large folders)...'
  [estimate_no_fit]='A full copy would NOT fit in the free space at the destination. Files already copied there need no extra space: the backup preview shows what is really new.'
  [estimate_no_dest_free]='Free space could not be checked (no destination configured, or it is not accessible right now).'
  [lock_error]="A backup is already running (or a previous lock remains in '%s')."
  [lock_hint]='Wait for it to finish, or remove that file if you know no backup is active.'
  [origins]='Source folders:'
  [destination]='Destination: %s'
  [backup_confirm_title]='Backup summary'
  [backup_summary_folders]='Folders to copy: %s'
  [backup_summary_mirror]='Mirror mode (--delete): %s'
  [backup_summary_mirror_warn]='Mirror mode is ON: files removed from (or missing in) the source will also be DELETED from the destination.'
  [backup_confirm_prompt]='Start the backup now? (y/n, p = preview): '
  [preview_title]='Backup preview (simulation: nothing is copied or deleted)'
  [preview_checking]='[%d/%d] Checking: %s'
  [preview_result]='To copy: %s file(s) (%s); to delete: %s item(s)'
  [preview_total]='Total: %s file(s) to copy (%s), %s item(s) to delete.'
  [preview_uptodate]='Nothing to copy or delete: the destination is already up to date.'
  [preview_delete_warn]='Mirror mode is ON: %s item(s) would be DELETED from the destination.'
  [preview_no_fit]='The new data does NOT fit in the free space at the destination.'
  [preview_problem]='rsync reported problems (code %s); the preview may be incomplete.'
  [preview_view_prompt]='View the full list of changes? (y/n): '
  [preview_legend]='+ new file    ~ updated file    - deleted (mirror mode)'
  [preview_after_mirror_prompt]='Preview now what a backup would copy and delete? (y/n): '
  [source_missing]="The source '%s' no longer exists (moved, deleted, or disconnected drive?). Skipping."
  [source_empty_mirror]="The source '%s' is empty and mirror mode is ON: copying it would DELETE everything already backed up for it."
  [target_create_error]="Could not create '%s' on the destination. Skipping this folder."
  [backup_ok]='Backup finished without errors.'
  [backup_warn]='Backup finished with %s minor warning(s); see the log.'
  [backup_errors]='Backup finished with errors in %s source folder(s). Check the log.'
  [run_stats]='Duration: %s. Copied: %s (%s file(s)).'
  [last_backup]='Last backup: %s (%s), %s in %s'
  [last_backup_none]='Last backup: none yet'
  [result_ok]='OK'
  [result_warn]='%s warning(s)'
  [result_err]='%s error(s)'
  [auto_summary]='Automatic backup: errors: %s; warnings: %s. Log: %s'
  [auto_config]='Automatic backup failed: source and/or destination is not configured.'
  [auto_rsync]='Automatic backup failed: rsync is not installed.'
  [auto_destination]='Automatic backup failed: destination drive is not available.'
  [timeshift_space]='Timeshift reports that there is not enough space on the configured destination.'
  [timeshift_estimate]='The Timeshift destination has ~%s GB free, while your root partition (/) uses ~%s GB.'
  [timeshift_uncompressed]='The first RSYNC snapshot is uncompressed: it may not fit and could fail partway through.'
  [timeshift_title]='System snapshot (Timeshift)'
  [timeshift_missing]='Timeshift is not installed.'
  [install_timeshift]='Install it now? (y/n): '
  [timeshift_install_fail]='Could not install Timeshift. Check the previous apt messages.'
  [timeshift_installed]='Timeshift installed successfully.'
  [ts_create]='  1) Create a snapshot now'
  [ts_list]='  2) Show existing snapshots (also shows the current destination)'
  [ts_gui]='  3) Open Timeshift (graphical interface)'
  [ts_dest]='  4) Configure snapshot destination disk'
  [create_snapshot]='Try the snapshot anyway? (y/n): '
  [creating_snapshot]='Creating system snapshot; this may take a few minutes...'
  [snapshot_ok]='Snapshot created successfully.'
  [snapshot_error]='Error creating snapshot.'
  [snapshot_error_cause]='Most common cause: it did not fit in the destination (Timeshift removes a partial snapshot on failure; this is its normal behavior and deletes nothing else).'
  [timeshift_log]='Detailed Timeshift log (kept even if the snapshot is removed): /var/log/timeshift/'
  [timeshift_config_hint]='If the destination was never configured manually, use option 4 in this menu and choose it (external drive or second internal disk).'
  [open_timeshift]='Opening Timeshift (it will ask for the administrator password in a graphical window)...'
  [timeshift_fallback]='Neither '\''timeshift-launcher'\'' nor '\''pkexec'\'' was found; sudo will be used (it may ask for the password here in the terminal).'
  [timeshift_gui_missing]='Timeshift graphical interface (timeshift-gtk) was not found.'
  [ts_destination]='Timeshift snapshot destination'
  [ts_choose_folder]='Choose any folder on the disk (external or a second internal disk).'
  [ts_detect_partition]='The script will detect the actual partition.'
  [ts_partition_root]='Timeshift stores snapshots at the ROOT of that partition (folder '\''timeshift'\''), not in a subfolder.'
  [ts_choose_folder_dialog]='Choose a folder on the disk for Timeshift snapshots'
  [ts_partition_error]="Could not determine the real partition for '%s'."
  [chosen_folder]='Chosen folder: %s'
  [detected_partition]='Detected partition: %s'
  [confirm_ts_destination]="Configure '%s' as the Timeshift snapshot destination? (y/n): "
  [ts_cancelled]='Cancelled.'
  [ts_dest_ok]='Timeshift destination configured at: %s'
  [ts_dest_error]='Could not configure the destination. Check the previous message.'
  [schedule_title]='Schedule automatic backup'
  [schedule_info]='This adds a task to your user crontab to run the backup automatically, without opening the menu.'
  [cron_desc_daily]='daily at %s:00'
  [cron_desc_weekly]='weekly (%s) at %s:00'
  [current_task]='Current scheduled task: %s'
  [current_task_none]='No scheduled task is configured yet.'
  [daily]='  1) Daily (choose time)'
  [weekly]='  2) Weekly (choose day and time)'
  [remove_task]='  3) Remove existing scheduled task'
  [hour_prompt]='Time of day, 0-23 (Enter to cancel): '
  [hour_invalid]='Invalid hour. It must be an integer between 0 and 23.'
  [day_prompt]='Day of week, 0=Sunday ... 6=Saturday (Enter to cancel): '
  [day_invalid]='Invalid day. It must be a number between 0 (Sunday) and 6 (Saturday).'
  [cron_remove_confirm]='Remove the current scheduled task? (y/n): '
  [no_task]='No scheduled %s task was found.'
  [task_removed]='Scheduled task removed.'
  [cron_update_error]='Could not update the crontab. Is the cron service installed?'
  [task_added]='Scheduled task added successfully.'
  [cron_install_error]='Could not install the scheduled task. Check that cron is installed and active (systemctl status cron).'
  [logs_title]='Backup history'
  [no_logs]='There are no backup logs yet.'
  [log_number]='Log number to view (Enter to cancel): '
  [number_range]='Number out of range.'
  [mirror_title]='Mirror mode (--delete)'
  [enabled]='ENABLED'
  [disabled]='DISABLED'
  [mirror_warn]='If enabled: files deleted from the source will also be deleted from the destination (exact mirror copy).'
  [mirror_info]='If disabled (recommended): the destination only accumulates copies and never deletes anything, even if you delete the original.'
  [mirror_prompt]='Enable mirror deletion? (y/n, Enter = no change): '
  [response_unknown]='Unrecognized response. No changes made.'
  [welcome]='Welcome to %s!'
  [first_run]='This is the first time you have run the script. We will configure it in a moment.'
  [detect_personal]='Detect your personal folders automatically (Documents, Music, Pictures...)? (y/n): '
  [detected_count]='Folders added: %s'
  [menu_sources]='Configured source folders: %s'
  [menu_destination]='Destination: %s'
  [menu_paths]='  1) Configure source and destination paths'
  [menu_backup]='  2) Run backup now'
  [menu_timeshift]='  3) Create system snapshot (Timeshift)'
  [menu_schedule]='  4) Schedule automatic backup'
  [menu_logs]='  5) View log history'
  [menu_mirror]='  6) Enable/disable mirror deletion (--delete)'
  [menu_verify]='  7) Verify configuration'
  [verify_title]='Configuration check'
  [verify_rsync_ok]='rsync is installed.'
  [verify_source_ok]='Source accessible: %s'
  [verify_source_bad]='Source NOT accessible: %s'
  [verify_dest_ok]='Destination available and writable: %s'
  [verify_cron_noexec]="The scheduled task cannot run: '%s' is not executable (chmod +x)."
  [verify_cron_inactive]='The cron service is not running: scheduled backups will not start (sudo systemctl enable --now cron).'
  [verify_all_ok]='Everything looks good: a backup should run without problems.'
  [verify_warned]='No blocking problems, but there are %s warning(s) to review.'
  [verify_failed]='%s problem(s) found: fix them before running a backup.'
  [menu_language]='  L) Switch language (EN/ES)'
  [menu_exit]='  0) Exit'
  [nav_tip]='Tip: q works like 0.'
  [menu_help]='  H) Quick help'
  [help_title]='Quick help'
  [help_keys]='0 or q: back/exit.  Enter: cancel a text prompt.  Ctrl+C: quit.'
  [help_start]='First time: option 1 (folders + destination), then option 2 (run backup).'
  [help_preview]='At the backup summary, press p to preview what would be copied or deleted.'
  [help_mirror]='Mirror mode (option 6) also removes deleted files from the destination.'
  [help_logs]='Logs: %s'
  [help_config]='Settings: %s'
  [eof_exit]='Input closed (EOF). Exiting.'
  [cancel_option]='Cancel'
  [goodbye]='Goodbye.'
)

UI_ES=(
  [cancelled]='Cancelado.'
  [interrupted_signal]='Proceso interrumpido (señal %s).'
  [log_interrupted]='=== Backup interrumpido (señal %s) ==='
  [too_many_args]='Demasiados argumentos. Prueba: %s --help'
  [select_prompt]='Elige un número: '
  [unknown_option]='Opción no reconocida: %s'
  [try_help]='Prueba: %s --help'
  [config_dirs_error]='Error: no se pudieron crear las carpetas de configuración.'
  [config_save_error]='Error: no se pudo guardar el archivo de configuración.'
  [log_config_save_error]="ERROR: no se pudo guardar la configuración en '%s'"
  [press_enter]='Pulsa Enter para continuar...'
  [help_usage]='Uso:'
  [help_interactive]='%s               Abre el menú interactivo'
  [help_auto]='%s --auto        Ejecuta el backup configurado sin menús (cron)'
  [help_version]='%s --version|-v  Muestra la versión instalada'
  [help_help]='%s --help|-h     Muestra esta ayuda'
  [dep_required]='Faltan dependencias necesarias: %s'
  [dep_optional]='Falta una dependencia opcional: %s (explorador gráfico de carpetas).'
  [install_missing]='¿Instalarlas ahora con apt? (s/n): '
  [dep_install_fail]='No se pudieron instalar: %s. El script no funcionará correctamente sin ellas.'
  [dep_installed]='Dependencias instaladas correctamente.'
  [dep_may_fail]='El script puede fallar más adelante sin: %s'
  [sudo_missing]='sudo no está disponible: instala los paquetes que faltan manualmente (como root, o con el gestor de paquetes de tu distribución).'
  [same_real_folder]="'%s' apunta a la misma carpeta real que '%s' (ya configurada), aunque la ruta escrita sea distinta."
  [nested_source]="'%s' ya está dentro de '%s', que ya tienes configurada como origen."
  [parent_source]="'%s' (ya configurada) está dentro de '%s': su contenido se copiaría dos veces."
  [paths_config]='Configuración de rutas'
  [current_sources]='Carpetas de origen actuales:'
  [none_configured]='  (ninguna configurada)'
  [not_configured]='sin configurar'
  [currently]='Actualmente: '
  [external]='externo'
  [internal]='interno'
  [unknown_type]='tipo desconocido'
  [no_label]='sin etiqueta'
  [timeshift_comment]='Backup automático %s'
  [timeshift_snapshot_notification]='Snapshot del sistema creado.'
  [auto_finished]='Backup automático finalizado. Avisos: %s.'
  [auto_finished_errors]='Backup automático finalizado. Errores: %s; avisos: %s.'
  [log_backup_start]='=== Inicio de backup (%s v%s) ==='
  [log_backup_ok]='=== Backup finalizado correctamente ==='
  [log_backup_warn]='=== Backup finalizado con %s aviso(s) menor(es) ==='
  [log_ok]='OK: %s -> %s'
  [log_warn]='AVISO (%s): %s -> %s'
  [log_error]='ERROR (%s): %s -> %s'
  [log_cleanup]='Logs antiguos eliminados: %s; se conservan los %s más recientes.'
  [log_backup_errors]='=== Backup finalizado con %s error(es) ==='
  [log_collision]='AVISO: nombre de carpeta duplicado; '\''%s'\'' se guarda en el destino como '\''%s'\'' para no mezclarla con otro origen del mismo nombre.'
  [log_fat]='AVISO: %s archivo(s) de más de 4 GiB no caben en un destino FAT32:'
  [log_filesystem]='Sistema de archivos del destino: '\''%s'\'', banderas rsync: %s'
  [log_auto_start]='=== AUTO: inicio de backup programado (%s v%s) ==='
  [log_auto_end]='=== AUTO: backup finalizado, errores=%s, avisos=%s ==='
  [log_auto_config]='AUTO: configuración incompleta, abortando'
  [log_auto_rsync]='AUTO: rsync no está instalado, abortando'
  [log_auto_destination]='AUTO: destino no disponible, abortando'
  [log_auto_same_disk]='AVISO: el destino está en el mismo disco que el sistema (raíz o carpeta personal); se continúa según la configuración'
  [log_auto_mount_lost]="AUTO: el destino ya no está en su unidad (punto de montaje esperado: '%s'); se aborta para no llenar el disco del sistema"
  [log_auto_lock]='AUTO: ya hay una copia en curso, se aborta esta ejecución programada'
  [log_cron_error]='No se pudo instalar la tarea programada: %s'
  [log_low_space]='AVISO: queda poco espacio libre en el destino, se intenta el backup de todas formas'
  [log_source_missing]='ERROR: origen inaccesible, se omite: %s'
  [log_source_empty]='AVISO: origen vacío con modo espejo activado; se omite para no borrar su copia: %s'
  [log_target_create]="ERROR: no se pudo crear '%s'"
  [backup_notification]='Backup finalizado. Avisos: %s.'
  [backup_error_notification]='Backup finalizado. Errores: %s; avisos: %s.'
  [detect_sources]='  1) Detectar automáticamente (Documentos, Música, Imágenes, Vídeos, Descargas...)'
  [add_folder]='  2) Añadir una carpeta manualmente'
  [remove_folder]='  3) Quitar una carpeta de la lista'
  [clear_sources]='  4) Vaciar lista de orígenes'
  [configure_destination]='  5) Configurar disco de destino (externo o interno)'
  [configure_excludes]='  6) Configurar exclusiones'
  [estimate_space]='  7) Estimar espacio necesario'
  [back]='  0) Volver'
  [choose_option]='Elige una opción: '
  [detect_no_new]='No se detectaron carpetas personales nuevas para añadir.'
  [detect_ask]='¿Añadir %s (%s)? (s/n): '
  [detect_added_none]='No se añadió ninguna carpeta.'
  [choose_folder]='Elige la carpeta a incluir en la copia'
  [enter_source_path]='Ruta completa de la carpeta a incluir (Enter para cancelar): '
  [cancelled_op]='Operación cancelada.'
  [folder_missing]='Esa carpeta no existe.'
  [path_not_absolute]='Escribe una ruta completa que empiece por / o ~ (no una relativa).'
  [already_source]='Esa carpeta ya está en la lista de orígenes.'
  [add_anyway]='¿Añadir de todas formas? (s/n): '
  [added_path]='Añadida: %s'
  [no_sources_remove]='No hay carpetas para quitar.'
  [invalid_option_retry]='Opción no válida, prueba de nuevo.'
  [removed_path]='Eliminada: %s'
  [sources_cleared]='Lista de orígenes vaciada.'
  [clear_sources_confirm]='¿Quitar las %s carpeta(s) de origen configuradas de la lista? (s/n): '
  [invalid_option]='Opción no válida'
  [internal_storage]="'%s' está en almacenamiento interno (no extraíble), no en un disco externo."
  [internal_ok]='Si es a propósito (p. ej. un segundo disco interno), no tienes que hacer nada más.'
  [destination_disk]='Disco de destino'
  [current_destination]='Destino actual: %s'
  [detected_drives]='Unidades detectadas (se indica si cada una es interna o externa):'
  [no_other_drive]='No se detectó ninguna otra unidad montada (ni externa ni un segundo disco interno).'
  [mount_drive]='Conecta o monta el disco y vuelve a intentarlo, o escribe la ruta manualmente.'
  [select_drive]='Escribe el número de la unidad detectada, pulsa '\''g'\'' para elegir la'
  [select_drive2]='carpeta con el explorador gráfico clásico, o pega la ruta completa'
  [select_drive3]='(puedes añadir una subcarpeta, por ejemplo: /media/usuario/MiDisco/Backups).'
  [choose_destination]='Elige la carpeta de destino de las copias'
  [no_folder_selected]='No se seleccionó ninguna carpeta (¿cancelado, o zenity no disponible?).'
  [create_folder]='La carpeta '\''%s'\'' no existe. ¿Crearla ahora? (s/n): '
  [destination_set]='Destino configurado: %s'
  [destination_not_writable]='La ruta no existe o no se puede escribir en ella (¿disco en solo lectura?).'
  [exclusions]='Exclusiones actuales'
  [none]='  (ninguna)'
  [add_exclusion]='  a) Añadir exclusión'
  [remove_exclusion]='  r) Quitar exclusión'
  [exclusion_pattern]='Patrón a excluir, ej.: *.tmp, .cache, nombre_carpeta (Enter para cancelar): '
  [enter_cancel_prompt]='(Enter para cancelar) > '
  [exclusion_duplicate]='Ese patrón ya está en la lista de exclusiones.'
  [exclusion_added]='Exclusión añadida: %s'
  [exclusion_removed]='Exclusión eliminada: %s'
  [no_exclusions_remove]='No hay exclusiones para quitar.'
  [no_destination]='No hay disco de destino configurado. En el menú principal, elige la opción 1 y luego la 5.'
  [destination_missing]="La carpeta de destino '%s' no existe. ¿Está conectada/montada la unidad de destino?"
  [destination_inside]='El destino %s está dentro de una de tus carpetas de origen.'
  [recursive_copy]='Eso crearía una copia recursiva de la carpeta dentro de sí misma. Elige otra ruta de destino.'
  [same_disk]='El destino está en el MISMO disco que el sistema (raíz o carpeta personal), no en una unidad aparte.'
  [same_disk_hint]='Si usas un disco externo o un segundo disco interno, puede que no esté conectado o montado todavía.'
  [continue_anyway]='¿Continuar de todas formas? (s/n): '
  [no_write]="No se puede escribir en '%s'."
  [ntfs_readonly]="Si es un disco NTFS, puede estar en solo lectura por no haberse desmontado bien en Windows (repara con chkdsk en Windows, o 'sudo ntfsfix' en Linux)."
  [collision]="'%s' se guardará como '%s' (hay otro origen con el mismo nombre de carpeta)."
  [fat_limit]='Archivos de más de 4 GiB: %s. FAT32 no los admite y no se copiarán (limitación del formato del disco, no del script).'
  [fat_detail]='Detalle completo en el log. Para guardarlos, usa un destino exFAT o NTFS.'
  [no_unix_metadata]="El destino usa el sistema de archivos '%s': no conserva permisos Unix ni propietario (limitación del propio disco, tus archivos no se ven afectados)."
  [rsync_reason_changed]='archivos que desaparecieron del origen durante la copia; puede ser normal'
  [rsync_reason_fat]='normal en discos FAT/exFAT/NTFS'
  [rsync_reason_log]='revisa el log, puede haber archivos que no se copiaron'
  [syncing]='[%d/%d] Sincronizando: %s'
  [copied]='Completado: %s'
  [copied_warn]='Completado con avisos menores: %s (código rsync: %s, %s)'
  [copy_error]='Error al copiar %s (código rsync: %s)'
  [backup_title]='Copia de seguridad incremental'
  [no_source_config]='No hay carpetas de origen configuradas.'
  [rsync_missing]='rsync no está instalado (sudo apt install rsync). Instálalo y vuelve a intentarlo.'
  [low_space]='Queda poco espacio libre en el destino. La copia podría no completarse.'
  [estimate_used]='Tamaño estimado de las carpetas seleccionadas: ~%s'
  [estimate_free]='Espacio libre en el destino: ~%s'
  [estimate_fits]='Esto cabe en el espacio libre disponible en el destino.'
  [estimate_wait]='Calculando tamaños (puede tardar en carpetas grandes)...'
  [estimate_no_fit]='Una copia completa NO cabría en el espacio libre del destino. Los archivos ya copiados allí no ocupan espacio extra: la vista previa de la copia muestra lo que es realmente nuevo.'
  [estimate_no_dest_free]='No se pudo comprobar el espacio libre (no hay destino configurado, o no está accesible ahora mismo).'
  [lock_error]="Ya hay una copia de seguridad en curso (o quedó un bloqueo previo en '%s')."
  [lock_hint]='Espera a que termine, o borra ese fichero si sabes que no hay ninguna copia activa.'
  [origins]='Origen(es):'
  [destination]='Destino: %s'
  [backup_confirm_title]='Resumen de la copia'
  [backup_summary_folders]='Carpetas a copiar: %s'
  [backup_summary_mirror]='Modo espejo (--delete): %s'
  [backup_summary_mirror_warn]='Modo espejo ACTIVADO: los archivos borrados (o ausentes) en el origen también se BORRARÁN en el destino.'
  [backup_confirm_prompt]='¿Iniciar la copia ahora? (s/n, v = vista previa): '
  [preview_title]='Vista previa de la copia (simulación: no se copia ni se borra nada)'
  [preview_checking]='[%d/%d] Comprobando: %s'
  [preview_result]='A copiar: %s archivo(s) (%s); a borrar: %s elemento(s)'
  [preview_total]='Total: %s archivo(s) a copiar (%s), %s elemento(s) a borrar.'
  [preview_uptodate]='Nada que copiar ni borrar: el destino ya está al día.'
  [preview_delete_warn]='Modo espejo ACTIVADO: se BORRARÍAN %s elemento(s) del destino.'
  [preview_no_fit]='Los datos nuevos NO caben en el espacio libre del destino.'
  [preview_problem]='rsync indicó problemas (código %s); la vista previa puede estar incompleta.'
  [preview_view_prompt]='¿Ver la lista completa de cambios? (s/n): '
  [preview_legend]='+ archivo nuevo    ~ archivo actualizado    - borrado (modo espejo)'
  [preview_after_mirror_prompt]='¿Ver ahora una vista previa de lo que copiaría y borraría una copia? (s/n): '
  [source_missing]="El origen '%s' ya no existe (¿se movió, se borró, o es un disco desconectado?). Se omite."
  [source_empty_mirror]="El origen '%s' está vacío y el modo espejo está ACTIVADO: copiarlo BORRARÍA todo lo ya guardado de él."
  [target_create_error]="No se pudo crear '%s' en el destino. Se omite esta carpeta."
  [backup_ok]='Copia finalizada sin errores.'
  [backup_warn]='Copia finalizada con %s aviso(s) menor(es); revisa el log.'
  [backup_errors]='Copia finalizada con errores en %s carpeta(s) de origen. Revisa el log.'
  [run_stats]='Duración: %s. Copiado: %s (%s archivo(s)).'
  [last_backup]='Última copia: %s (%s), %s en %s'
  [last_backup_none]='Última copia: ninguna todavía'
  [result_ok]='correcta'
  [result_warn]='%s aviso(s)'
  [result_err]='%s error(es)'
  [auto_summary]='Backup automático: errores: %s; avisos: %s. Log: %s'
  [auto_config]='Backup automático fallido: falta configurar origen y/o destino.'
  [auto_rsync]='Backup automático fallido: falta instalar rsync.'
  [auto_destination]='Backup automático fallido: la unidad de destino no está disponible.'
  [timeshift_space]='Timeshift indica que no hay espacio suficiente en el destino configurado.'
  [timeshift_estimate]='El destino de Timeshift tiene ~%s GB libres, y tu partición raíz (/) usa ~%s GB.'
  [timeshift_uncompressed]='El primer snapshot de RSYNC no está comprimido: puede no caber y fallar a medias.'
  [timeshift_title]='Snapshot del sistema (Timeshift)'
  [timeshift_missing]='Timeshift no está instalado.'
  [install_timeshift]='¿Deseas instalarlo ahora? (s/n): '
  [timeshift_install_fail]='No se pudo instalar Timeshift. Revisa los mensajes de apt anteriores.'
  [timeshift_installed]='Timeshift instalado correctamente.'
  [ts_create]='  1) Crear un snapshot ahora'
  [ts_list]='  2) Ver snapshots existentes (muestra también el destino actual)'
  [ts_gui]='  3) Abrir Timeshift (interfaz gráfica)'
  [ts_dest]='  4) Configurar disco de destino de las snapshots'
  [create_snapshot]='¿Intentar la snapshot de todas formas? (s/n): '
  [creating_snapshot]='Creando snapshot del sistema, esto puede tardar unos minutos...'
  [snapshot_ok]='Snapshot creado correctamente.'
  [snapshot_error]='Error al crear el snapshot.'
  [snapshot_error_cause]='Causa más habitual: no cabía en el destino (Timeshift elimina el snapshot parcial al fallar; es su comportamiento normal y no borra nada más).'
  [timeshift_log]='Log detallado de Timeshift (se conserva aunque borres la snapshot): /var/log/timeshift/'
  [timeshift_config_hint]='Si el destino nunca se configuró a mano, ve a la opción 4 de este menú y elígelo (disco externo o un segundo disco interno).'
  [open_timeshift]='Abriendo Timeshift (te pedirá la contraseña de administrador en una ventana gráfica)...'
  [timeshift_fallback]='No se encontró '\''timeshift-launcher'\'' ni '\''pkexec'\''; se usará sudo (puede pedir la contraseña aquí en la terminal).'
  [timeshift_gui_missing]='No se encontró la interfaz gráfica de Timeshift (timeshift-gtk).'
  [ts_destination]='Destino de las snapshots de Timeshift'
  [ts_choose_folder]='Elige cualquier carpeta del disco (externo, o un segundo disco interno).'
  [ts_detect_partition]='El script detectará la partición real.'
  [ts_partition_root]='Timeshift guarda las snapshots en la RAÍZ de esa partición (carpeta '\''timeshift'\''), no en una subcarpeta.'
  [ts_choose_folder_dialog]='Elige una carpeta del disco para las snapshots de Timeshift'
  [ts_partition_error]="No se pudo determinar la partición real de '%s'."
  [chosen_folder]='Carpeta elegida: %s'
  [detected_partition]='Partición detectada: %s'
  [confirm_ts_destination]="¿Configurar '%s' como destino de las snapshots de Timeshift? (s/n): "
  [ts_cancelled]='Cancelado.'
  [ts_dest_ok]='Destino de Timeshift configurado en: %s'
  [ts_dest_error]='No se pudo configurar el destino. Revisa el mensaje anterior.'
  [schedule_title]='Programar copia automática'
  [schedule_info]='Esto añade una tarea a tu crontab de usuario para ejecutar la copia automáticamente, sin abrir el menú.'
  [cron_desc_daily]='diaria a las %s:00'
  [cron_desc_weekly]='semanal (%s) a las %s:00'
  [current_task]='Tarea programada actual: %s'
  [current_task_none]='Todavía no hay ninguna tarea programada.'
  [daily]='  1) Diaria (elige hora)'
  [weekly]='  2) Semanal (elige día y hora)'
  [remove_task]='  3) Quitar tarea programada existente'
  [hour_prompt]='Hora del día, 0-23 (Enter para cancelar): '
  [hour_invalid]='Hora no válida. Debe ser un número entero entre 0 y 23.'
  [day_prompt]='Día de la semana, 0=domingo ... 6=sábado (Enter para cancelar): '
  [day_invalid]='Día no válido. Debe ser un número entre 0 (domingo) y 6 (sábado).'
  [cron_remove_confirm]='¿Eliminar la tarea programada actual? (s/n): '
  [no_task]='No había ninguna tarea programada de %s.'
  [task_removed]='Tarea programada eliminada.'
  [cron_update_error]='No se pudo actualizar el crontab. ¿Está instalado el servicio de cron?'
  [task_added]='Tarea programada añadida correctamente.'
  [cron_install_error]='No se pudo instalar la tarea programada. Revisa que el servicio de cron esté instalado y activo (systemctl status cron).'
  [logs_title]='Historial de copias'
  [no_logs]='Todavía no hay registros de copias.'
  [log_number]='Número de log a ver (Enter para cancelar): '
  [number_range]='Número fuera de rango.'
  [mirror_title]='Modo espejo (--delete)'
  [enabled]='ACTIVADO'
  [disabled]='DESACTIVADO'
  [mirror_warn]='Si lo activas: los archivos borrados en el origen también se borrarán en el destino (copia espejo exacta).'
  [mirror_info]='Si lo dejas desactivado (recomendado): el destino solo acumula copias y nunca borra nada, aunque borres el original.'
  [mirror_prompt]='¿Activar borrado espejo? (s/n, Enter = sin cambios): '
  [response_unknown]='Respuesta no reconocida. Sin cambios.'
  [welcome]='¡Bienvenido a %s!'
  [first_run]='Es la primera vez que ejecutas el script. Vamos a configurarlo en un momento.'
  [detect_personal]='¿Detectar automáticamente tus carpetas personales (Documentos, Música, Imágenes...)? (s/n): '
  [detected_count]='Carpetas añadidas: %s'
  [menu_sources]='Carpetas de origen configuradas: %s'
  [menu_destination]='Destino: %s'
  [menu_paths]='  1) Configurar rutas de origen y destino'
  [menu_backup]='  2) Ejecutar copia de seguridad ahora'
  [menu_timeshift]='  3) Crear snapshot del sistema (Timeshift)'
  [menu_schedule]='  4) Programar copia automática'
  [menu_logs]='  5) Ver historial de logs'
  [menu_mirror]='  6) Activar/desactivar borrado espejo (--delete)'
  [menu_verify]='  7) Verificar configuración'
  [verify_title]='Verificación de la configuración'
  [verify_rsync_ok]='rsync está instalado.'
  [verify_source_ok]='Origen accesible: %s'
  [verify_source_bad]='Origen NO accesible: %s'
  [verify_dest_ok]='Destino disponible y con permiso de escritura: %s'
  [verify_cron_noexec]="La tarea programada no podrá ejecutarse: '%s' no es ejecutable (chmod +x)."
  [verify_cron_inactive]='El servicio cron no está en marcha: las copias programadas no se iniciarán (sudo systemctl enable --now cron).'
  [verify_all_ok]='Todo correcto: una copia debería ejecutarse sin problemas.'
  [verify_warned]='Sin problemas bloqueantes, pero hay %s aviso(s) que revisar.'
  [verify_failed]='Se encontraron %s problema(s): corrígelos antes de ejecutar una copia.'
  [menu_language]='  L) Cambiar idioma (EN/ES)'
  [menu_exit]='  0) Salir'
  [nav_tip]='Consejo: q equivale a 0.'
  [menu_help]='  H) Ayuda rápida'
  [help_title]='Ayuda rápida'
  [help_keys]='0 o q: volver/salir.  Enter: cancelar un texto.  Ctrl+C: salir.'
  [help_start]='La primera vez: opción 1 (carpetas y destino) y luego la 2 (copiar).'
  [help_preview]='En el resumen previo, pulsa v para ver qué se copiaría o borraría.'
  [help_mirror]='Modo espejo (opción 6): también borra del destino lo borrado en el origen.'
  [help_logs]='Registros: %s'
  [help_config]='Configuración: %s'
  [eof_exit]='Entrada cerrada (EOF). Saliendo.'
  [cancel_option]='Cancelar'
  [goodbye]='Hasta la próxima.'
)

ui() {
  local key="$1"
  shift
  local template
  if [[ "${APP_LANG:-en}" == "es" ]]; then
    template="${UI_ES[$key]:-${UI_EN[$key]:-$key}}"
  else
    template="${UI_EN[$key]:-$key}"
  fi
  # shellcheck disable=SC2059  # the template comes from the catalog, by design
  printf "$template" "$@"
}

ui_yes() {
  local a="${1:-}"
  case "${APP_LANG:-en}:${a,,}" in
    es:s|es:si|es:sí|es:sÍ|en:y|en:yes) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_app_language() {
  local configured="${UI_LANGUAGE:-auto}" locale_value
  if [[ "$configured" == "es" || "$configured" == "en" ]]; then
    APP_LANG="$configured"
    return
  fi
  locale_value="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
  if [[ "$locale_value" =~ ^([eE][sS])([_.@-]|$) ]]; then
    APP_LANG="es"
  else
    APP_LANG="en"
  fi
}

toggle_app_language() {
  if [[ "${APP_LANG:-en}" == "es" ]]; then
    APP_LANG="en"
  else
    APP_LANG="es"
  fi
  UI_LANGUAGE="$APP_LANG"
}

if [[ -f "$CONFIG_FILE" ]]; then
  saved_language="$(sed -n 's/^UI_LANGUAGE=\(es\|en\|auto\)$/\1/p' "$CONFIG_FILE" | tail -n 1)"
  [[ -n "$saved_language" ]] && UI_LANGUAGE="$saved_language"
fi
resolve_app_language

if [[ $# -gt 1 ]]; then
  printf '%s\n' "$(ui too_many_args "$(basename "$0")")" >&2
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

$(ui help_usage)
  $(ui help_interactive "$(basename "$0")")
  $(ui help_auto "$(basename "$0")")
  $(ui help_version "$(basename "$0")")
  $(ui help_help "$(basename "$0")")
EOF
    exit 0
    ;;
  --auto|"") ;;  # valid; handled below once the functions are defined
  *)
    printf '%s\n' "$(ui unknown_option "${1:-}")" >&2
    printf '%s\n' "$(ui try_help "$(basename "$0")")" >&2
    exit 1
    ;;
esac

# --------------------------------------------------------------------------
# Paths and constants
# --------------------------------------------------------------------------
LOG_DIR="$HOME/.local/share/simple-backup/logs"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/backup_${TIMESTAMP}_$$.log"  # PID: TIMESTAMP has only 1-second resolution
SCRIPT_PATH="$(readlink -f "$0")"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" || {
  printf '%s\n' "$(ui config_dirs_error)" >&2
  exit 1
}
chmod 700 "$CONFIG_DIR" 2>/dev/null || true

# --------------------------------------------------------------------------
# Colors (disabled when output is not a terminal)
# --------------------------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'
  BLUE=$'\e[34m'; MAGENTA=$'\e[35m'; CYAN=$'\e[36m'
else
  BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""
fi

# --------------------------------------------------------------------------
# Default configuration (overridden when config.conf is loaded)
# --------------------------------------------------------------------------
declare -a SOURCE_DIRS=()
declare -a EXCLUDES=(".cache" "*.tmp" "*.part" "*.crdownload" "*.download" "node_modules" ".thumbnails" "lost+found")
declare -a RSYNC_FLAGS=(-a)
declare -a RSYNC_ARGS=()
declare -a TARGET_NAMES=()
RUN_FILES=0  # files copied / bytes copied in the current run (see sync_one_source)
RUN_BYTES=0
DEST_FSTYPE=""
DEST_DIR=""
DEST_MOUNT=""  # mount point of the destination drive; empty if on the system disk
USE_DELETE="no"
LOCK_FILE="$CONFIG_DIR/backup.lock"
LAST_STATUS_FILE="$CONFIG_DIR/last_backup.info"
PS3=$'\n'"$(ui select_prompt)"

# --------------------------------------------------------------------------
# Interface utilities
# --------------------------------------------------------------------------
hr() { printf "%s%s%s\n" "$DIM" "────────────────────────────────────────────────────────────" "$RESET"; }

header() {
  [[ -t 1 ]] && clear 2>/dev/null
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

pause() { read -rp "$(printf '%s%s%s' "$DIM" "$(ui press_enter)" "$RESET")" _; }

# Shows files (or stdin) in $PAGER, which may carry arguments ("less -R").
# Without a usable pager it falls back to cat and returns 99 so callers can pause.
run_pager() {
  local -a pager
  read -ra pager <<< "${PAGER:-less}"
  if ! command -v "${pager[0]:-}" &>/dev/null; then cat -- "$@"; return 99; fi
  "${pager[@]}" "$@"
}

is_quit() { [[ "${1,,}" == q ]]; }
# "0" and "q" both mean back/cancel in numbered prompts (select, log number).
is_back() { [[ "$1" == 0 ]] || is_quit "$1"; }
# A relative path would resolve against wherever the script was launched from
# (and cron's working directory differs), so typed paths must be absolute.
is_absolute_path() { [[ "$1" == /* ]]; }

# Menu prompt: reads the choice into "opt" ("q" is an alias of "0"); fails on EOF. $1 = indent.
read_menu_option() {
  printf '%s%s%s%s\n' "${1:-}" "$DIM" "$(ui nav_tip)" "$RESET"
  read -rp "${1:-}$(ui choose_option)" opt || return 1
  is_quit "$opt" && opt=0
  return 0
}

quick_help() {
  header
  printf "%s%s%s\n" "$BOLD" "$(ui help_title)" "$RESET"
  hr
  printf '  %s\n\n' "$(ui help_keys)" "$(ui help_start)" "$(ui help_preview)" "$(ui help_mirror)"
  printf '  %s\n' "$(ui help_logs "$LOG_DIR")" "$(ui help_config "$CONFIG_FILE")"
  echo
  pause
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

# Bytes -> "1.5 GiB" (integer math only: no locale/decimal-separator issues).
human_size() {
  local b="${1:-0}" i=0 d=0 u=(B KiB MiB GiB TiB)
  while (( b >= 1024 && i < 4 )); do d=$(( b % 1024 * 10 / 1024 )); b=$(( b / 1024 )); ((i+=1)); done
  if (( i )); then printf '%d.%d %s' "$b" "$d" "${u[i]}"; else printf '%d B' "$b"; fi
}

format_duration() { local s="${1:-0}"; printf '%02d:%02d:%02d' $((s / 3600)) $((s % 3600 / 60)) $((s % 60)); }

# One-line summary of the current run (RUN_FILES/RUN_BYTES); $1 = elapsed seconds.
run_stats_line() {
  printf '%s' "$(ui run_stats "$(format_duration "$1")" "$(human_size "$RUN_BYTES")" "$RUN_FILES")"
}

# Totals from rsync itemized lines ("%i %l ..."): prints "<files copied> <bytes> <deleted>".
# $2 = leading columns to skip (3 in an rsync --log-file: date, time, [pid]).
tally_transfers() {
  awk -v s="${2:-0}" '$(s+1) ~ /^>f/ {f++; b+=$(s+2)} $(s+1) == "*deleting" {d++}
    END {printf "%d %.0f %d\n", f, b, d}' "$1" 2>/dev/null
}

# --------------------------------------------------------------------------
# Configuration: load / save
# --------------------------------------------------------------------------
load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
}

save_config() {
  # No "declare -p": load_config() sources this file inside a function, and
  # "declare" would create local vars that shadow the globals.
  # Atomic write: write to a temp file in the same dir, fsync it, then
  # rename(2) it over config.conf, so a crash mid-save can't leave it
  # empty or half-written; a final fsync on the dir makes the rename durable.
  local x tmp_file
  # Sweep temp files orphaned by a save killed before its final "mv" (e.g.
  # Ctrl+C); 10 min avoids touching one from a concurrent save elsewhere.
  find "$CONFIG_DIR" -maxdepth 1 -name '.sb-config.*' -mmin +10 -delete 2>/dev/null || true
  tmp_file="$(mktemp "$CONFIG_DIR/.sb-config.XXXXXX" 2>/dev/null)" || {
    msg_err "$(ui config_save_error)"
    log "$(ui log_config_save_error "$CONFIG_FILE")"
    return 1
  }
  if {
    echo "# $APP_NAME configuration - generated automatically, do not edit by hand"
    printf 'SOURCE_DIRS=('
    for x in "${SOURCE_DIRS[@]}"; do printf '%q ' "$x"; done
    printf ')\n'
    printf 'EXCLUDES=('
    for x in "${EXCLUDES[@]}"; do printf '%q ' "$x"; done
    printf ')\n'
    printf 'DEST_DIR=%q\n' "$DEST_DIR"
    printf 'DEST_MOUNT=%q\n' "$DEST_MOUNT"
    printf 'USE_DELETE=%q\n' "$USE_DELETE"
    printf 'UI_LANGUAGE=%q\n' "$UI_LANGUAGE"
  } > "$tmp_file"; then
    chmod 600 "$tmp_file" 2>/dev/null   # mktemp already creates it 0600; belt and suspenders
    sync -d -- "$tmp_file" 2>/dev/null  # flush content before the rename
    if mv -f -- "$tmp_file" "$CONFIG_FILE"; then
      sync -- "$CONFIG_DIR" 2>/dev/null # flush the rename itself
      return 0
    fi
  fi
  rm -f -- "$tmp_file" 2>/dev/null
  msg_err "$(ui config_save_error)"
  log "$(ui log_config_save_error "$CONFIG_FILE")"
  return 1
}

# --------------------------------------------------------------------------
# Execution lock (prevents two backups from writing to the same destination)
# --------------------------------------------------------------------------
# Never add "2>/dev/null" to a bare "exec": it is permanent for the whole shell
# and hides later prompts (read -p writes to stderr). Use a { } group instead.
acquire_lock() {
  { exec {LOCK_FD}>"$LOCK_FILE"; } 2>/dev/null || return 1
  if ! flock -n "$LOCK_FD"; then
    # Another backup is running: close the fd so retries don't leak descriptors.
    { exec {LOCK_FD}>&-; } 2>/dev/null
    unset LOCK_FD
    return 1
  fi
}

release_lock() {
  if [[ -n "${LOCK_FD:-}" ]]; then
    flock -u "$LOCK_FD" 2>/dev/null
    { exec {LOCK_FD}>&-; } 2>/dev/null
    unset LOCK_FD
  fi
  return 0
}

# --------------------------------------------------------------------------
# Dependencies
# --------------------------------------------------------------------------
require_sudo() {
  command -v sudo &>/dev/null && return 0
  msg_err "$(ui sudo_missing)"
  return 1
}

check_dependencies() {
  local missing=() missing_optional=()
  command -v rsync        &>/dev/null || missing+=("rsync")
  command -v xdg-user-dir  &>/dev/null || missing+=("xdg-user-dirs")
  # zenity is optional (without it paths are typed by hand): offered on the
  # first run only, so declining it is not asked again on every start.
  ${IS_FIRST_RUN:-false} && { command -v zenity &>/dev/null || missing_optional+=("zenity"); }

  if [[ ${#missing[@]} -gt 0 || ${#missing_optional[@]} -gt 0 ]]; then
    [[ ${#missing[@]} -gt 0 ]] && msg_warn "$(ui dep_required "${missing[*]}")"
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
      msg_warn "$(ui dep_optional "${missing_optional[*]}")"
    fi
    read -rp "$(ui install_missing)" ans
    if ui_yes "$ans"; then
      require_sudo && sudo apt update && sudo apt install -y "${missing[@]}" "${missing_optional[@]}"
      # Recheck: "apt install" can fail part-way through without returning an error.
      local still_missing=()
      command -v rsync        &>/dev/null || still_missing+=("rsync")
      command -v xdg-user-dir  &>/dev/null || still_missing+=("xdg-user-dirs")
      if [[ ${#still_missing[@]} -gt 0 ]]; then
        msg_err "$(ui dep_install_fail "${still_missing[*]}")"
      else
        msg_ok "$(ui dep_installed)"
      fi
    else
      [[ ${#missing[@]} -gt 0 ]] && msg_warn "$(ui dep_may_fail "${missing[*]}")"
    fi
    pause
  fi
}

# --------------------------------------------------------------------------
# Graphical folder picker (zenity). Prints nothing and fails if zenity or a
# graphical session is unavailable; the caller then asks for the path manually.
# --------------------------------------------------------------------------
pick_folder_dialog() {
  local title="$1" start_dir="${2:-$HOME}"
  command -v zenity &>/dev/null || return 1
  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] || return 1
  [[ -d "$start_dir" ]] || start_dir="$HOME"
  # LANGUAGE alone is ignored by gettext when the active locale is still
  # "C"/"POSIX" (e.g. a minimal shell), so zenity's own buttons would stay
  # untranslated even with LANGUAGE set. Force a UTF-8 locale only in that
  # case so LANGUAGE actually takes effect and matches APP_LANG.
  local lc_fix=()
  [[ "${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}" =~ ^(C|POSIX)(\.|$) ]] && lc_fix=(LC_ALL=C.UTF-8)
  # "env": an assignment coming out of an array expansion is not an assignment but a command name.
  env LANGUAGE="${APP_LANG:-en}" "${lc_fix[@]}" zenity --file-selection --directory --title="$title" --filename="${start_dir%/}/" 2>/dev/null
}

# --------------------------------------------------------------------------
# Detect standard personal folders (respects the system language)
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

# Interactive per-folder selection for auto-detected personal folders: asks
# y/n for each detected folder not already configured, instead of adding all
# of them at once (e.g. lets the user skip Downloads). Used by configure_paths
# and first_run_wizard. Sets DETECT_NEW_COUNT (candidates offered) and
# DETECT_ADDED_COUNT (how many the user accepted).
select_detected_sources() {
  local candidates=() c ans
  while IFS= read -r c; do [[ -n "$c" ]] && candidates+=("$c"); done < <(autodetect_sources)
  local -a new=()
  for c in "${candidates[@]}"; do
    array_contains "$c" "${SOURCE_DIRS[@]}" || new+=("$c")
  done
  DETECT_NEW_COUNT=${#new[@]}
  DETECT_ADDED_COUNT=0
  (( DETECT_NEW_COUNT == 0 )) && return 0
  for c in "${new[@]}"; do
    check_source_overlap "$c" || true  # prints a warning if it overlaps a configured source
    read -rp "$(ui detect_ask "$(basename "$c")" "$c")" ans
    if ui_yes "$ans"; then
      SOURCE_DIRS+=("$c")
      ((DETECT_ADDED_COUNT+=1))
    fi
  done
}

remove_from_array_by_value() {
  # $1 = array name (by reference), $2 = value to remove
  local -n arr_ref="$1"
  local target="$2"
  local tmp=()
  local x
  for x in "${arr_ref[@]}"; do
    [[ "$x" != "$target" ]] && tmp+=("$x")
  done
  arr_ref=("${tmp[@]}")
}

# Expands "~" or "~/rest" to $HOME. Unlike "${v/#\~/$HOME}", it does NOT touch
# "~otheruser/..." (which would turn the path into an invented, incorrect path).
expand_tilde() {
  local v="${1%$'\r'}"
  # shellcheck disable=SC2088  # literal text comparison; no shell expansion
  [[ "$v" == "~" || "$v" == "~/"* ]] && v="$HOME${v#\~}"
  printf '%s' "$v"
}

# Warn if the new folder matches, contains, or is contained by an
# existing source (including via symlink): harmless, but duplicates content.
check_source_overlap() {
  local cand="$1" rp_new rp_s s
  rp_new="$(readlink -f "$cand" 2>/dev/null)" || return 1
  for s in "${SOURCE_DIRS[@]}"; do
    rp_s="$(readlink -f "$s" 2>/dev/null)" || continue
    [[ -z "$rp_s" ]] && continue
    if [[ "$rp_s" == "$rp_new" ]]; then
      msg_warn "$(ui same_real_folder "$cand" "$s")"
      return 0
    fi
    if [[ "$rp_new" == "$rp_s"/* ]]; then
      msg_warn "$(ui nested_source "$cand" "$s")"
      return 0
    fi
    if [[ "$rp_s" == "$rp_new"/* ]]; then
      msg_warn "$(ui parent_source "$s" "$cand")"
      return 0
    fi
  done
  return 1
}

# --------------------------------------------------------------------------
# Menu: configure source folders
# --------------------------------------------------------------------------
configure_paths() {
  while true; do
    header
    printf "%s%s%s\n" "$BOLD" "$(ui paths_config)" "$RESET"
    hr
    msg_info "$(ui current_sources)"
    if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
      printf '%s\n' "$(ui none_configured)"
    else
      local d
      for d in "${SOURCE_DIRS[@]}"; do echo "  - $d"; done
    fi
    echo
    printf '%s\n' "$(ui detect_sources)"
    printf '%s\n' "$(ui add_folder)"
    printf '%s\n' "$(ui remove_folder)"
    printf '%s\n' "$(ui clear_sources)"
    printf '%s\n' "$(ui configure_destination)"
    printf '%s\n' "$(ui configure_excludes)"
    printf '%s\n' "$(ui estimate_space)"
    printf '%s\n' "$(ui back)"
    hr
    read_menu_option || return
    case "$opt" in
      1)
        select_detected_sources
        if (( DETECT_NEW_COUNT == 0 )); then
          msg_warn "$(ui detect_no_new)"
        elif (( DETECT_ADDED_COUNT == 0 )); then
          msg_warn "$(ui detect_added_none)"
        else
          save_config
          msg_ok "$(ui detected_count "$DETECT_ADDED_COUNT")"
        fi
        pause
        ;;
      2)
        local newdir=""
        newdir="$(pick_folder_dialog "$(ui choose_folder)" "$HOME")"
        if [[ -z "$newdir" ]]; then
          # No zenity/graphical session, or the user pressed "Cancel": ask manually.
          read -rp "$(ui enter_source_path)" newdir
        fi
        newdir="$(expand_tilde "$newdir")"
        [[ "$newdir" != "/" ]] && newdir="${newdir%/}"
        if [[ -z "$newdir" ]]; then
          msg_warn "$(ui cancelled_op)"
        elif ! is_absolute_path "$newdir"; then
          msg_err "$(ui path_not_absolute)"
        elif [[ ! -d "$newdir" ]]; then
          msg_err "$(ui folder_missing)"
        elif array_contains "$newdir" "${SOURCE_DIRS[@]}"; then
          msg_warn "$(ui already_source)"
        else
          local add_ok=1
          if check_source_overlap "$newdir"; then
            read -rp "$(ui add_anyway)" ans
            ui_yes "$ans" || add_ok=0
          fi
          if [[ "$add_ok" -eq 1 ]]; then
            SOURCE_DIRS+=("$newdir")
            save_config
            msg_ok "$(ui added_path "$newdir")"
          else
            msg_warn "$(ui cancelled_op)"
          fi
        fi
        pause
        ;;
      3)
        if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
          msg_warn "$(ui no_sources_remove)"
        else
          select d in "${SOURCE_DIRS[@]}" "$(ui cancel_option)"; do
            if [[ "$d" == "$(ui cancel_option)" ]] || is_back "$REPLY"; then break; fi
            if [[ -z "$d" ]]; then msg_err "$(ui invalid_option_retry)"; continue; fi
            remove_from_array_by_value SOURCE_DIRS "$d"
            save_config
            msg_ok "$(ui removed_path "$d")"
            break
          done
        fi
        pause
        ;;
      4)
        if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
          msg_warn "$(ui no_sources_remove)"
        else
          read -rp "$(ui clear_sources_confirm "${#SOURCE_DIRS[@]}")" ans
          if ui_yes "$ans"; then
            SOURCE_DIRS=()
            save_config
            msg_ok "$(ui sources_cleared)"
          else
            msg_warn "$(ui cancelled_op)"
          fi
        fi
        pause
        ;;
      5) configure_destination ;;
      6) configure_excludes ;;
      7) estimate_space_action; pause ;;
      0) return ;;
      *) msg_err "$(ui invalid_option)"; sleep 1 ;;
    esac
  done
}

# --------------------------------------------------------------------------
# Menu: configure destination disk
# --------------------------------------------------------------------------
# RM ("removable") of the physical disk containing lsblk device $1
# (e.g. "sdb1"). Output: "1" removable, "0" internal, "" if unknown.
disk_removable_flag() {
  local name="$1" pk
  [[ -n "$name" ]] || return 0
  pk="$(lsblk -no PKNAME "/dev/$name" 2>/dev/null)"
  [[ -z "$pk" ]] && pk="$name"
  # -r (raw): without it, lsblk pads RM with spaces ("0" -> " 0") and
  # comparisons with "0"/"1" in callers never match.
  lsblk -dnro RM "/dev/$pk" 2>/dev/null
}

list_mounted_drives() {
  # Lists mounted drives, internal or external (a 2nd internal disk is as
  # valid a destination as an external one), excluding system mount points.
  # Uses "-P" (KEY="VALUE") so a label/mount point with spaces isn't split.
  local line name type mp size label kind
  lsblk -P -o NAME,TYPE,MOUNTPOINT,SIZE,LABEL 2>/dev/null | while IFS= read -r line; do
    type="$(grep -oP 'TYPE="\K[^"]*' <<<"$line")"
    # Not only "part": also include disks without a partition table and LUKS ("crypt") devices.
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
      1) kind="$(ui external)" ;;
      0) kind="$(ui internal)" ;;
      *) kind="$(ui unknown_type)" ;;
    esac
    printf '%s\t%s\t%s\t%s\n' "$mp" "$size" "${label:-$(ui no_label)}" "$kind"
  done
}

warn_if_not_removable() {
  # Informational warning (non-blocking): if it is internal rather than removable,
  # the backup still works; this only confirms that it is the intended drive.
  local path="$1" src rm
  command -v findmnt &>/dev/null && command -v lsblk &>/dev/null || return 0
  src="$(findmnt -no SOURCE --target "$path" 2>/dev/null)" || return 0
  src="${src%%\[*}"  # remove the btrfs subvolume suffix, e.g. /dev/sdb1[/@data]
  rm="$(disk_removable_flag "$(basename "$src")")"
  if [[ "$rm" == "0" ]]; then
    msg_info "$(ui internal_storage "$path")"
    msg_info "$(ui internal_ok)"
  fi
}

configure_destination() {
  header
  printf "%s%s%s\n" "$BOLD" "$(ui destination_disk)" "$RESET"
  hr
  msg_info "$(ui current_destination "${DEST_DIR:-$(ui not_configured)}")"
  echo
  msg_info "$(ui detected_drives)"
  local found_paths=() found_display=()
  local mp size label kind
  while IFS=$'\t' read -r mp size label kind; do
    [[ -n "$mp" ]] || continue
    found_paths+=("$mp")
    found_display+=("$mp  ($label, $size, $kind)")
  done < <(list_mounted_drives)

  if [[ ${#found_paths[@]} -eq 0 ]]; then
    msg_warn "$(ui no_other_drive)"
    msg_warn "$(ui mount_drive)"
  else
    local i=1 f
    for f in "${found_display[@]}"; do
      echo "  $i) $f"
      ((i+=1))
    done
  fi
  echo
  printf '%s\n' "$(ui select_drive)"
  printf '%s\n' "$(ui select_drive2)"
  printf '%s\n' "$(ui select_drive3)"
  read -rp "$(ui enter_cancel_prompt)" sel
  is_quit "$sel" && sel=""
  local chosen=""
  if [[ "$sel" =~ ^[0-9]+$ ]] && (( 10#$sel >= 1 && 10#$sel <= ${#found_paths[@]} )); then
    chosen="${found_paths[$((10#$sel - 1))]}"
  elif [[ "$sel" == "g" || "$sel" == "G" ]]; then
    local start_dir="${found_paths[0]:-/media/${USER:-}}"
    chosen="$(pick_folder_dialog "$(ui choose_destination)" "$start_dir")"
    if [[ -z "$chosen" ]]; then
      msg_warn "$(ui no_folder_selected)"
      pause; return
    fi
  else
    chosen="$(expand_tilde "$sel")"
  fi
  # Zenity usually returns the path with a trailing "/"; normalize it so
  # DEST_DIR is the same regardless of how it was selected.
  [[ -n "$chosen" && "$chosen" != "/" ]] && chosen="${chosen%/}"

  if [[ -z "$chosen" ]]; then
    msg_warn "$(ui cancelled_op)"
    pause; return
  fi
  if ! is_absolute_path "$chosen"; then
    msg_err "$(ui path_not_absolute)"
    pause; return
  fi

  if [[ ! -d "$chosen" ]]; then
    read -rp "$(ui create_folder "$chosen")" ans
    ui_yes "$ans" && mkdir -p "$chosen" 2>/dev/null
  fi

  if [[ -d "$chosen" ]] && dest_is_writable "$chosen"; then
    DEST_DIR="$chosen"
    DEST_MOUNT="$(current_dest_mount)"
    save_config
    msg_ok "$(ui destination_set "$DEST_DIR")"
    warn_if_not_removable "$DEST_DIR"
  else
    msg_err "$(ui destination_not_writable)"
  fi
  pause
}

# --------------------------------------------------------------------------
# Menu: exclusions
# --------------------------------------------------------------------------
configure_excludes() {
  while true; do
    header
    printf "%s%s%s\n" "$BOLD" "$(ui exclusions)" "$RESET"
    hr
    if [[ ${#EXCLUDES[@]} -eq 0 ]]; then
      printf '%s\n' "$(ui none)"
    else
      local i=1 e
      for e in "${EXCLUDES[@]}"; do echo "  $i) $e"; ((i+=1)); done
    fi
    echo
    printf '%s\n' "$(ui add_exclusion)"
    printf '%s\n' "$(ui remove_exclusion)"
    printf '%s\n' "$(ui back)"
    hr
    read_menu_option || return
    case "${opt,,}" in
      a)
        read -rp "$(ui exclusion_pattern)" pat
        if [[ -z "$pat" ]]; then
          msg_warn "$(ui cancelled_op)"
        elif array_contains "$pat" "${EXCLUDES[@]}"; then
          msg_warn "$(ui exclusion_duplicate)"
        else
          EXCLUDES+=("$pat")
          save_config
          msg_ok "$(ui exclusion_added "$pat")"
        fi
        pause
        ;;
      r)
        if [[ ${#EXCLUDES[@]} -eq 0 ]]; then
          msg_warn "$(ui no_exclusions_remove)"
        else
          select e in "${EXCLUDES[@]}" "$(ui cancel_option)"; do
            if [[ "$e" == "$(ui cancel_option)" ]] || is_back "$REPLY"; then break; fi
            if [[ -z "$e" ]]; then msg_err "$(ui invalid_option_retry)"; continue; fi
            remove_from_array_by_value EXCLUDES "$e"
            save_config
            msg_ok "$(ui exclusion_removed "$e")"
            break
          done
        fi
        pause
        ;;
      0) return ;;
      *) msg_err "$(ui invalid_option)"; sleep 1 ;;
    esac
  done
}

# --------------------------------------------------------------------------
# Validate the destination before copying
# --------------------------------------------------------------------------
same_filesystem() {
  # Compares the device number from stat, not "mountpoint -q" (which needs
  # the exact mount-point root and breaks storing backups in a subfolder).
  local a="$1" b="$2" da db
  da="$(stat -c '%d' "$a" 2>/dev/null)" || return 1
  db="$(stat -c '%d' "$b" 2>/dev/null)" || return 1
  [[ "$da" == "$db" ]]
}

dest_on_system_disk() {
  same_filesystem "$DEST_DIR" "$HOME" || same_filesystem "$DEST_DIR" "/"
}

# Mount point holding DEST_DIR when it is on its own drive; empty otherwise.
current_dest_mount() {
  dest_on_system_disk || findmnt -fno TARGET --target "$DEST_DIR" 2>/dev/null
}

# True if the destination was on its own drive when configured and is no
# longer mounted there (unplugged drive whose mount-point folder remains).
dest_mount_lost() {
  [[ -n "$DEST_MOUNT" && "$(current_dest_mount)" != "$DEST_MOUNT" ]]
}

# Learns the mount point for configs saved before DEST_MOUNT existed.
remember_dest_mount() {
  [[ -z "$DEST_MOUNT" ]] || return 0
  DEST_MOUNT="$(current_dest_mount)"
  [[ -z "$DEST_MOUNT" ]] || save_config
}

dest_inside_a_source() {
  # If the destination is inside a source, rsync would copy a folder
  # into itself: each run would nest another copy.
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

# "-w" only checks permission bits: an uncleanly-unmounted NTFS disk mounts
# read-only despite them, so verify with an actual test write instead.
dest_is_writable() {
  local d="$1" probe
  probe="$(mktemp "${d%/}/.sb-write-test.XXXXXX" 2>/dev/null)" || return 1
  rm -f -- "$probe" 2>/dev/null
  return 0
}

check_destination_mounted() {
  if [[ -z "$DEST_DIR" ]]; then
    msg_err "$(ui no_destination)"
    return 1
  fi
  if [[ ! -d "$DEST_DIR" ]]; then
    msg_err "$(ui destination_missing "$DEST_DIR")"
    return 1
  fi
  if dest_inside_a_source "$DEST_DIR"; then
    msg_err "$(ui destination_inside "$DEST_DIR")"
    msg_err "$(ui recursive_copy)"
    return 1
  fi
  if dest_on_system_disk; then
    msg_warn "$(ui same_disk)"
    msg_warn "$(ui same_disk_hint)"
    read -rp "$(ui continue_anyway)" ans
    ui_yes "$ans" || return 1
  fi
  if ! dest_is_writable "$DEST_DIR"; then
    msg_err "$(ui no_write "$DEST_DIR")"
    msg_err "$(ui ntfs_readonly)"
    return 1
  fi
  return 0
}

check_destination_mounted_auto() {
  [[ -n "$DEST_DIR" && -d "$DEST_DIR" ]] || return 1
  dest_mount_lost && return 1
  dest_inside_a_source "$DEST_DIR" && return 1
  dest_is_writable "$DEST_DIR" || return 1
  return 0
}

# Non-interactive destination check shared by the preview and the config
# verification: prints why the destination is unusable and fails, else silent.
check_destination_usable() {
  if [[ -z "$DEST_DIR" ]]; then msg_err "$(ui no_destination)"
  elif [[ ! -d "$DEST_DIR" ]] || dest_mount_lost; then msg_err "$(ui destination_missing "$DEST_DIR")"
  elif dest_inside_a_source "$DEST_DIR"; then msg_err "$(ui destination_inside "$DEST_DIR")"
  else return 0
  fi
  return 1
}

# Early (non-blocking) low-space warning; this does not replace
# rsync error handling. "Best effort": if "df" fails, simply do not warn.
LOW_SPACE_THRESHOLD_KB=512000  # ~500 MB

check_disk_space_low() {
  local avail_kb
  avail_kb="$(df -Pk "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ "$avail_kb" =~ ^[0-9]+$ ]] || return 1
  (( avail_kb < LOW_SPACE_THRESHOLD_KB ))
}

# Available bytes at DEST_DIR, or failure if it cannot be determined (not
# configured, not mounted, "df" unavailable...).
dest_free_bytes() {
  local avail_kb
  [[ -n "$DEST_DIR" && -d "$DEST_DIR" ]] || return 1
  dest_mount_lost && return 1
  avail_kb="$(df -Pk "$DEST_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ "$avail_kb" =~ ^[0-9]+$ ]] || return 1
  printf '%d' $((avail_kb * 1024))
}

# Approximate size of each source honoring EXCLUDES: one "bytes<TAB>path" line
# per source plus a final total line (du -c). An estimate only: "du" pattern
# matching does not exactly mirror rsync's --exclude semantics.
estimate_sources_size() {
  local -a du_args=(-s -c -b)
  local e
  for e in "${EXCLUDES[@]}"; do du_args+=(--exclude="$e"); done
  du "${du_args[@]}" -- "${SOURCE_DIRS[@]}" 2>/dev/null
}

# On-demand (menu item: "du" over large folders can be slow): size of each
# source, biggest first, and the total against the free space at the
# destination, so the user can decide what to include before copying.
estimate_space_action() {
  if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
    msg_warn "$(ui no_source_config)"
    return 0
  fi
  msg_info "$(ui estimate_wait)"
  local -a rows=()
  local row total_bytes=0 free_bytes
  mapfile -t rows < <(estimate_sources_size)
  if (( ${#rows[@]} )); then
    total_bytes="${rows[-1]%%$'\t'*}"
    [[ "$total_bytes" =~ ^[0-9]+$ ]] || total_bytes=0
    unset 'rows[-1]'
    while IFS= read -r row; do
      [[ -n "$row" ]] && printf '  %10s  %s\n' "$(human_size "${row%%$'\t'*}")" "${row#*$'\t'}"
    done < <(printf '%s\n' "${rows[@]}" | sort -t$'\t' -k1,1nr)
  fi
  msg_info "$(ui estimate_used "$(human_size "$total_bytes")")"
  if free_bytes="$(dest_free_bytes)"; then
    msg_info "$(ui estimate_free "$(human_size "$free_bytes")")"
    if (( total_bytes > free_bytes )); then
      msg_warn "$(ui estimate_no_fit)"
    else
      msg_ok "$(ui estimate_fits)"
    fi
  else
    msg_warn "$(ui estimate_no_dest_free)"
  fi
}

# --------------------------------------------------------------------------
# Resolve destination folder names
# --------------------------------------------------------------------------
# Two sources sharing a basename (e.g. two "Projects" folders) would both
# map to "$DEST_DIR/Projects" and mix together; this renames only the
# actual collisions (prefixing the parent folder), deterministically.
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

  # Final safeguard: if two sources also share the same parent folder name
  # (rare edge case), number them to avoid mixing content.
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

# Reports (screen if interactive=yes, always in the log) any source folder
# renamed at the destination due to a name collision.
warn_target_name_collisions() {
  local interactive="${1:-yes}"
  local i base
  for ((i = 0; i < ${#SOURCE_DIRS[@]}; i++)); do
    base="$(basename "${SOURCE_DIRS[$i]}")"
    [[ "${TARGET_NAMES[$i]}" == "$base" ]] && continue
    log "$(ui log_collision "${SOURCE_DIRS[$i]}" "${TARGET_NAMES[$i]}")"
    if [[ "$interactive" == "yes" ]]; then
      msg_warn "$(ui collision "${SOURCE_DIRS[$i]}" "${TARGET_NAMES[$i]}")"
    fi
  done
}

# --------------------------------------------------------------------------
# rsync flags by destination filesystem
# --------------------------------------------------------------------------
# FAT/exFAT/NTFS lack Unix permissions/ownership ("-a" would report rc 23
# even on a correct copy) and 1s timestamp precision (--modify-window).
# FAT32 also rejects files >= 4 GiB; --max-size skips them cleanly (rc 0)
# instead of failing mid-copy (rc 11). --inplace is never used, so each
# copied file keeps rsync's default atomic temp-file+rename write.
FAT_MAX_FILE_BYTES=4294967295  # 4 GiB - 1

rsync_flags_for_fstype() {
  local fstype="$1"
  case "$fstype" in
    # No -l: FAT/NTFS (ntfs-3g/ntfs3) don't create symlinks unless specially
    # mounted; with -l, rsync failed on them with "Operation not permitted".
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
  log "$(ui log_fat "${#big[@]}")"
  for f in "${big[@]}"; do log "  - $f"; done
  if [[ "$interactive" == "yes" ]]; then
    msg_warn "$(ui fat_limit "${#big[@]}")"
    msg_warn "$(ui fat_detail)"
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
      [[ "$interactive" == "yes" ]] && msg_warn "$(ui no_unix_metadata "$fstype")"
      ;;
  esac
  case "$fstype" in
    vfat|fat|fat32|msdos) check_fat_file_size_limit "$interactive" ;;
  esac
  log "$(ui log_filesystem "${fstype:-unknown}" "${RSYNC_FLAGS[*]}")"
}

# True when rsync's exit code 23 is fully explained by metadata this
# destination filesystem can't store (permissions/owner/timestamps),
# rather than a real transfer problem.
rsync_23_metadata_warning() {
  local output_file="$1"
  case "$DEST_FSTYPE" in
    vfat|fat|fat32|msdos|exfat|ntfs|ntfs3|fuseblk) ;;
    *) return 1 ;;
  esac
  grep -Eiq 'failed to (set|preserve) (times|permissions|owner|group)|Operation not permitted.*(times|permission|owner|group)|chown .*Operation not permitted|chmod .*Operation not permitted|utimens(at|ate).*Operation not permitted' "$output_file" || return 1
  if grep -Eiq 'No space left on device|Read-only file system|Permission denied|Input/output error|not a directory|stale file handle|cannot open|mkstemp|rename|unlink|delete.*failed|failed to transfer|some files were not transferred' "$output_file"; then
    return 1
  fi
  return 0
}

# Maps an rsync exit code to "ok" / "warn" / "error" for the caller.
classify_rsync_rc() {
  local rc="$1" output_file="${2:-}"
  case "$rc" in
    0) echo "ok" ;;
    24) echo "warn" ;;
    23)
      [[ -n "$output_file" ]] && rsync_23_metadata_warning "$output_file" && echo "warn" || echo "error"
      ;;
    *) echo "error" ;;
  esac
}

# Explains a "minor" warning (rc 23/24): code 23 also happens on plain
# permission errors on Unix filesystems (ext4, btrfs...), not just FAT/NTFS.
rsync_warn_reason() {
  local rc="$1"
  if [[ "$rc" == "24" ]]; then
    printf '%s\n' "$(ui rsync_reason_changed)"
    return
  fi
  case "$DEST_FSTYPE" in
    vfat|fat|fat32|msdos|exfat|ntfs|ntfs3|fuseblk)
      printf '%s\n' "$(ui rsync_reason_fat)" ;;
    *)
      printf '%s\n' "$(ui rsync_reason_log)" ;;
  esac
}

# A notification failure (e.g. cron with no DISPLAY/DBUS) must never affect
# the exit status, or a correct backup would be reported as failed.
send_notification_safe() {
  local icon="$1" text="$2"
  command -v notify-send &>/dev/null || return 0
  notify-send -i "$icon" "$APP_NAME" "$text" >/dev/null 2>&1 || true
  return 0
}

# Daily cron runs would otherwise accumulate thousands of logs over the
# years; keep only the latest LOGS_TO_KEEP after each backup.
LOGS_TO_KEEP=90

cleanup_old_logs() {
  shopt -s nullglob
  local logs=("$LOG_DIR"/backup_*.log)
  shopt -u nullglob
  local count=${#logs[@]}
  if (( count > LOGS_TO_KEEP )); then
    local to_delete=$(( count - LOGS_TO_KEEP ))
    # Log filenames are fixed by this script (backup_<timestamp>_<pid>.log,
    # no spaces or glob characters), so sorting them with "ls -t" is safe.
    # shellcheck disable=SC2012
    ls -1t "$LOG_DIR"/backup_*.log | tail -n "$to_delete" | while IFS= read -r f; do
      rm -f -- "$f"
    done
    log "$(ui log_cleanup "$to_delete" "$LOGS_TO_KEEP")"
  fi
}

# Arguments shared by the real run and the preview, so the preview can never
# drift from what will actually run. --partial-dir resumes interrupted large
# files instead of recopying them.
build_rsync_args() {
  local e
  RSYNC_ARGS=("${RSYNC_FLAGS[@]}" --partial-dir=.rsync-partial-tmp)
  for e in "${EXCLUDES[@]}"; do RSYNC_ARGS+=(--exclude="$e"); done
  [[ "$USE_DELETE" == "yes" ]] && RSYNC_ARGS+=(--delete)
  return 0
}

# Mirror mode + an empty source (e.g. a drive that is not mounted) would make
# --delete wipe that folder's backup. True = skip it. $2: "yes" asks the user
# (real run), "preview" only warns, "no" (cron) skips silently. Logs when skipped.
mirror_would_wipe() {
  local src="$1" mode="$2" ans
  [[ "$USE_DELETE" == "yes" ]] || return 1
  [[ -z "$(find -H "$src" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || return 1
  [[ "$mode" == no ]] || msg_warn "$(ui source_empty_mirror "$src")"
  if [[ "$mode" == yes ]]; then
    read -rp "$(ui continue_anyway)" ans
    ui_yes "$ans" && return 1
  fi
  log "$(ui log_source_empty "$src")"
  return 0
}

# --------------------------------------------------------------------------
# Synchronizes ONE source with rsync and classifies the result. Always logs;
# screen messages/progress only if interactive=yes. Shared by run_backup and
# run_auto. Returns: 0=ok  1=error  2=minor warning (details in LOG_FILE).
# --------------------------------------------------------------------------
sync_one_source() {
  local src="$1" target="$2" interactive="$3" idx="${4:-}" total="${5:-}"
  local rc rc_class outfd rsync_output tally f=0 b=0
  rsync_output="$(mktemp "${TMPDIR:-/tmp}/simple-backup-rsync.XXXXXX")" || {
    log "$(ui log_error 1 "$src" "$target")"
    return 1
  }
  CURRENT_TMP_FILE="$rsync_output"  # so on_terminate() can remove it (and its .tally) if interrupted
  # rsync writes one "%i %l" line per copied file here: files/bytes without printing --stats.
  tally="$rsync_output.tally"
  build_rsync_args

  if [[ "$interactive" == "yes" ]]; then
    echo
    printf "%s%s%s%s\n" "$MAGENTA" "$BOLD" "$(ui syncing "$idx" "$total" "$src")" "$RESET"
    hr
    # Real pipe here, NOT "2> >(tee...)": with process substitution, tee
    # outlives this function in the background, so a later "read -rp" (e.g.
    # the final pause) could see EOF instead of the user's input.
    exec {outfd}>&1
    rsync "${RSYNC_ARGS[@]}" --info=progress2 --log-file="$tally" --log-file-format='%i %l' \
      "$src"/ "$target"/ 2>&1 1>&"$outfd" | tee -a "$LOG_FILE" "$rsync_output" >&2
    rc=${PIPESTATUS[0]}
    exec {outfd}>&-
  else
    rsync "${RSYNC_ARGS[@]}" --log-file="$tally" --log-file-format='%i %l' \
      "$src"/ "$target"/ >"$rsync_output" 2>&1
    rc=$?
    cat "$rsync_output" >>"$LOG_FILE"
  fi
  rc_class="$(classify_rsync_rc "$rc" "$rsync_output")"
  read -r f b _ <<<"$(tally_transfers "$tally" 3)"
  RUN_FILES=$((RUN_FILES + ${f:-0})); RUN_BYTES=$((RUN_BYTES + ${b:-0}))
  rm -f -- "$rsync_output" "$tally"
  CURRENT_TMP_FILE=""
  case "$rc_class" in
    ok)
      [[ "$interactive" == "yes" ]] && msg_ok "$(ui copied "$(basename "$target")")"
      log "$(ui log_ok "$src" "$target")"
      return 0 ;;
    warn)
      [[ "$interactive" == "yes" ]] && msg_warn "$(ui copied_warn "$(basename "$target")" "$rc" "$(rsync_warn_reason "$rc")")"
      log "$(ui log_warn "$rc" "$src" "$target")"
      return 2 ;;
    *)
      [[ "$interactive" == "yes" ]] && msg_err "$(ui copy_error "$(basename "$target")" "$rc")"
      log "$(ui log_error "$rc" "$src" "$target")"
      return 1 ;;
  esac
}

# --------------------------------------------------------------------------
# Preview (rsync --dry-run): what a real run would copy or delete, touching
# nothing. Same rsync arguments as the real run (build_rsync_args).
# --------------------------------------------------------------------------
preview_changes() {
  local LOG_FILE=/dev/null  # dynamic scope: a preview must not create a backup log
  if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then msg_err "$(ui no_source_config)"; return 1; fi
  if ! command -v rsync &>/dev/null; then msg_err "$(ui rsync_missing)"; return 1; fi
  check_destination_usable || return 1

  echo
  printf "%s%s%s\n" "$BOLD" "$(ui preview_title)" "$RESET"
  hr
  build_rsync_flags yes
  compute_target_names
  build_rsync_args
  local raw list src base rc f b d n=0 total=${#SOURCE_DIRS[@]} tf=0 tb=0 td=0 free
  raw="$(mktemp "${TMPDIR:-/tmp}/simple-backup-preview.XXXXXX")" || return 1
  list="$raw.list"
  CURRENT_TMP_FILE="$raw"
  for src in "${SOURCE_DIRS[@]}"; do
    base="${TARGET_NAMES[$n]}"
    ((n+=1))
    printf "%s%s%s\n" "$MAGENTA" "$(ui preview_checking "$n" "$total" "$src")" "$RESET"
    if [[ ! -d "$src" ]]; then msg_err "$(ui source_missing "$src")"; continue; fi
    mirror_would_wipe "$src" preview && continue
    rsync "${RSYNC_ARGS[@]}" --dry-run --out-format='%i %l %n' "$src"/ "$DEST_DIR/$base"/ >"$raw" 2>&1
    rc=$?
    if (( rc != 0 && rc != 24 )); then
      msg_warn "$(ui preview_problem "$rc")"
      grep -m2 '^rsync' "$raw"
    fi
    read -r f b d <<<"$(tally_transfers "$raw" 0)"
    printf '    %s\n' "$(ui preview_result "${f:-0}" "$(human_size "${b:-0}")" "${d:-0}")"
    ((tf+=${f:-0})); ((tb+=${b:-0})); ((td+=${d:-0}))
    # Labeled list for the pager: "+" new, "~" updated, "-" deleted (mirror mode).
    P="$base/" awk '$1 == "*deleting" {l = "-"} $1 ~ /^>f/ {l = ($1 ~ /^>f\+/) ? "+" : "~"}
      l {sub(/^[^ ]+ +[^ ]+ +/, ""); print l " " ENVIRON["P"] $0; l = ""}' "$raw" >>"$list"
  done

  echo; hr
  if (( tf == 0 && td == 0 )); then
    msg_ok "$(ui preview_uptodate)"
  else
    msg_info "$(ui preview_total "$tf" "$(human_size "$tb")" "$td")"
    (( td > 0 )) && msg_warn "$(ui preview_delete_warn "$td")"
    if (( tb > 0 )) && free="$(dest_free_bytes)"; then
      msg_info "$(ui estimate_free "$(human_size "$free")")"
      (( tb > free )) && msg_warn "$(ui preview_no_fit)"
    fi
  fi
  if [[ -s "$list" ]]; then
    read -rp "$(ui preview_view_prompt)" ans
    if ui_yes "$ans"; then
      { printf '%s\n\n' "$(ui preview_legend)"; cat -- "$list"; } | run_pager
    fi
  fi
  rm -f -- "$raw" "$list"
  CURRENT_TMP_FILE=""
  return 0
}

# Remembers the outcome of the last run for the main menu.
# One line: epoch|errors|warnings|seconds|bytes|files. Args: errors warnings seconds.
save_last_status() {
  local status_tmp="$LAST_STATUS_FILE.tmp"
  { printf '%s|%s|%s|%s|%s|%s\n' "$(date +%s)" "$1" "$2" "$3" "$RUN_BYTES" "$RUN_FILES" > "$status_tmp" \
      && mv -f -- "$status_tmp" "$LAST_STATUS_FILE"; } 2>/dev/null || rm -f -- "$status_tmp" 2>/dev/null
  return 0
}

# --------------------------------------------------------------------------
# Run the backup (interactive)
# --------------------------------------------------------------------------
run_backup() {
  header
  printf "%s%s%s\n" "$BOLD" "$(ui backup_title)" "$RESET"
  hr

  if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
    msg_err "$(ui no_source_config)"
    pause; return
  fi

  if ! command -v rsync &>/dev/null; then
    msg_err "$(ui rsync_missing)"
    pause; return
  fi

  if ! check_destination_mounted; then
    pause; return
  fi
  remember_dest_mount

  if check_disk_space_low; then
    msg_warn "$(ui low_space)"
    read -rp "$(ui continue_anyway)" ans
    ui_yes "$ans" || { pause; return; }
  fi

  echo
  hr
  printf "%s%s%s\n" "$BOLD" "$(ui backup_confirm_title)" "$RESET"
  msg_info "$(ui backup_summary_folders "${#SOURCE_DIRS[@]}")"
  msg_info "$(ui destination "$DEST_DIR")"
  if [[ "$USE_DELETE" == "yes" ]]; then
    printf "%s%s%s\n" "$YELLOW" "$(ui backup_summary_mirror "$(ui enabled)")" "$RESET"
    msg_warn "$(ui backup_summary_mirror_warn)"
  else
    msg_info "$(ui backup_summary_mirror "$(ui disabled)")"
  fi
  echo
  while true; do
    read -rp "$(ui backup_confirm_prompt)" ans
    case "${ans,,}" in
      p|v) preview_changes; echo ;;
      *) break ;;
    esac
  done
  if ! ui_yes "$ans"; then
    msg_warn "$(ui cancelled_op)"
    pause; return
  fi

  if ! acquire_lock; then
    msg_err "$(ui lock_error "$LOCK_FILE")"
    msg_err "$(ui lock_hint)"
    pause; return
  fi

  build_rsync_flags
  compute_target_names
  warn_target_name_collisions yes

  msg_info "$(ui origins)"
  local s
  for s in "${SOURCE_DIRS[@]}"; do echo "  - $s"; done
  msg_info "$(ui destination "$DEST_DIR")"
  echo
  log "$(ui log_backup_start "$APP_NAME" "$VERSION")"

  local total=${#SOURCE_DIRS[@]} n=0 errors=0 warnings=0 t0=$SECONDS
  RUN_FILES=0; RUN_BYTES=0

  local src
  for src in "${SOURCE_DIRS[@]}"; do
    local base target
    base="${TARGET_NAMES[$n]}"
    target="$DEST_DIR/$base"
    ((n+=1))
    if [[ ! -d "$src" ]]; then
      msg_err "$(ui source_missing "$src")"
      log "$(ui log_source_missing "$src")"
      ((errors+=1))
      continue
    fi
    if mirror_would_wipe "$src" yes; then ((warnings+=1)); continue; fi
    if ! mkdir -p "$target"; then
      msg_err "$(ui target_create_error "$target")"
      log "$(ui log_target_create "$target")"
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
    msg_ok "$(ui backup_ok)"
    log "$(ui log_backup_ok)"
  elif [[ $errors -eq 0 ]]; then
    msg_ok "$(ui backup_warn "$warnings")"
    log "$(ui log_backup_warn "$warnings")"
  else
    msg_warn "$(ui backup_errors "$errors")"
    log "$(ui log_backup_errors "$errors")"
  fi
  local stats_line
  stats_line="$(run_stats_line $((SECONDS - t0)))"
  msg_info "$stats_line"
  log "$stats_line"
  save_last_status "$errors" "$warnings" $((SECONDS - t0))

  if [[ $errors -eq 0 ]]; then
    send_notification_safe "drive-harddisk" "$(ui backup_notification "$warnings")"
  else
    send_notification_safe "dialog-error" "$(ui backup_error_notification "$errors" "$warnings")"
  fi

  release_lock
  cleanup_old_logs
  pause
}

# --------------------------------------------------------------------------
# Automatic execution (for cron, no interaction)
# --------------------------------------------------------------------------
run_auto() {
  RUN_FILES=0; RUN_BYTES=0
  # An aborted scheduled run counts as a failed attempt in the main-menu status.
  if [[ ${#SOURCE_DIRS[@]} -eq 0 || -z "$DEST_DIR" ]]; then
    log "$(ui log_auto_config)"
    send_notification_safe "dialog-error" "$(ui auto_config)"
    save_last_status 1 0 0
    return 1
  fi
  if ! command -v rsync &>/dev/null; then
    log "$(ui log_auto_rsync)"
    send_notification_safe "dialog-error" "$(ui auto_rsync)"
    save_last_status 1 0 0
    return 1
  fi
  if ! check_destination_mounted_auto; then
    dest_mount_lost && log "$(ui log_auto_mount_lost "$DEST_MOUNT")"
    log "$(ui log_auto_destination)"
    send_notification_safe "dialog-error" "$(ui auto_destination)"
    save_last_status 1 0 0
    return 1
  fi
  remember_dest_mount

  if ! acquire_lock; then
    log "$(ui log_auto_lock)"
    return 0
  fi

  if check_disk_space_low; then
    log "$(ui log_low_space)"
  fi

  build_rsync_flags no
  compute_target_names
  warn_target_name_collisions no

  log "$(ui log_auto_start "$APP_NAME" "$VERSION")"
  dest_on_system_disk && log "$(ui log_auto_same_disk)"
  local errors=0 warnings=0 src base target n=0 t0=$SECONDS
  for src in "${SOURCE_DIRS[@]}"; do
    base="${TARGET_NAMES[$n]}"
    ((n+=1))
    target="$DEST_DIR/$base"
    if [[ ! -d "$src" ]]; then
      log "$(ui log_source_missing "$src")"
      ((errors+=1))
      continue
    fi
    if mirror_would_wipe "$src" no; then ((warnings+=1)); continue; fi
    if ! mkdir -p "$target"; then
      log "$(ui log_target_create "$target")"
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
  log "$(run_stats_line $((SECONDS - t0)))"
  save_last_status "$errors" "$warnings" $((SECONDS - t0))
  log "$(ui log_auto_end "$errors" "$warnings")"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(ui auto_summary "$errors" "$warnings" "$LOG_FILE")"
  if [[ $errors -eq 0 ]]; then
    send_notification_safe "drive-harddisk" "$(ui auto_finished "$warnings")"
  else
    send_notification_safe "dialog-error" "$(ui auto_finished_errors "$errors" "$warnings")"
  fi
  release_lock
  cleanup_old_logs

  # The exit code (used by "exit $?" when this function is called) must
  # reflect only real errors, not the result of the desktop notification
  # (which often "fails" under cron without a graphical session).
  if [[ $errors -eq 0 ]]; then
    return 0
  else
    return 1
  fi
}

# --------------------------------------------------------------------------
# Timeshift: best-effort low-space warning before creating a snapshot
# --------------------------------------------------------------------------
# Common cause of partial failure: not enough space at the destination (the
# first RSYNC snapshot is uncompressed, roughly the size of "/"). LC_ALL=C
# forces English output for a reliable match; Spanish is matched too as a
# safety net in case a given Timeshift build ignores LC_ALL for its own text.
timeshift_check_space_low() {
  local list_output free_num free_unit free_gb_int root_used_kb root_used_gb
  list_output="$(LC_ALL=C sudo timeshift --list 2>/dev/null)" || return 1

  # Direct Timeshift signal: also covers the first snapshot (without
  # previous snapshots it does not print "GB free", so the other check would miss it).
  if grep -qE "Not enough disk space|Falta espacio en el disco" <<<"$list_output"; then
    msg_warn "$(ui timeshift_space)"
    return 0
  fi

  # Complementary estimate: applies only when previous snapshots already exist
  # (when Timeshift shows free space in its listing).
  free_num="$(grep -oP '[0-9]+(\.[0-9]+)?(?=\s*[KMGT]?B free)' <<<"$list_output" | head -n1)"
  free_unit="$(grep -oP '[0-9.]+\s*\K[KMGT]?B(?= free)' <<<"$list_output" | head -n1)"
  [[ -n "$free_num" && -n "$free_unit" ]] || return 1
  [[ "$free_unit" == "GB" ]] || return 1  # TB: ample; MB/KB/B: already covered above
  root_used_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $3}')"
  [[ "$root_used_kb" =~ ^[0-9]+$ ]] || return 1
  root_used_gb=$(( root_used_kb / 1024 / 1024 ))
  free_gb_int=${free_num%%.*}
  if (( free_gb_int < root_used_gb )); then
    msg_warn "$(ui timeshift_estimate "${free_num}" "${root_used_gb}")"
    msg_warn "$(ui timeshift_uncompressed)"
    return 0
  fi
  return 1
}

# --------------------------------------------------------------------------
# Timeshift: system snapshot
# --------------------------------------------------------------------------
timeshift_backup() {
  header
  printf "%s%s%s\n" "$BOLD" "$(ui timeshift_title)" "$RESET"
  hr

  if ! command -v timeshift &>/dev/null; then
    msg_warn "$(ui timeshift_missing)"
    read -rp "$(ui install_timeshift)" ans
    if ui_yes "$ans"; then
      require_sudo && sudo apt update && sudo apt install -y timeshift
      if ! command -v timeshift &>/dev/null; then
        msg_err "$(ui timeshift_install_fail)"
        pause; return
      fi
      msg_ok "$(ui timeshift_installed)"
    else
      pause; return
    fi
  fi

  printf '%s\n' "$(ui ts_create)"
  printf '%s\n' "$(ui ts_list)"
  printf '%s\n' "$(ui ts_gui)"
  printf '%s\n' "$(ui ts_dest)"
  printf '%s\n' "$(ui back)"
  hr
  read_menu_option || return
  case "$opt" in
    1)
      if timeshift_check_space_low; then
        read -rp "$(ui create_snapshot)" ans
        ui_yes "$ans" || { pause; return; }
      fi
      msg_info "$(ui creating_snapshot)"
      log "=== $(ui creating_snapshot) ==="
      if sudo timeshift --create --comments "$(ui timeshift_comment "$(date '+%Y-%m-%d %H:%M')")" --scripted 2>&1 | tee -a "$LOG_FILE"; then
        msg_ok "$(ui snapshot_ok)"
        log "$(ui snapshot_ok)"
        command -v notify-send &>/dev/null && notify-send -i drive-harddisk "$APP_NAME" "$(ui timeshift_snapshot_notification)"
      else
        msg_err "$(ui snapshot_error)"
        msg_err "$(ui snapshot_error_cause)"
        msg_info "$(ui timeshift_log)"
        msg_info "$(ui timeshift_config_hint)"
        log "ERROR: $(ui snapshot_error)"
      fi
      pause
      ;;
    2)
      sudo timeshift --list
      pause
      ;;
    3)
      # "sudo timeshift-gtk" alone often fails (root lacks X11 access). Prefer
      # "timeshift-launcher" (pkexec-based); else pkexec+DISPLAY, else plain sudo.
      if command -v timeshift-launcher &>/dev/null; then
        msg_info "$(ui open_timeshift)"
        nohup timeshift-launcher &>/dev/null &
        disown
      elif command -v timeshift-gtk &>/dev/null && command -v pkexec &>/dev/null; then
        msg_info "$(ui open_timeshift)"
        nohup pkexec env DISPLAY="${DISPLAY:-}" XAUTHORITY="${XAUTHORITY:-}" timeshift-gtk &>/dev/null &
        disown
      elif command -v timeshift-gtk &>/dev/null; then
        msg_warn "$(ui timeshift_fallback)"
        xhost +si:localuser:root &>/dev/null || true
        sudo timeshift-gtk
        xhost -si:localuser:root &>/dev/null || true
      else
        msg_err "$(ui timeshift_gui_missing)"
      fi
      pause
      ;;
    4) configure_timeshift_destination ;;
    0) return ;;
    *) msg_err "$(ui invalid_option)"; sleep 1 ;;
  esac
}

# --------------------------------------------------------------------------
# Timeshift: configure the snapshot destination disk/partition
# --------------------------------------------------------------------------
# Timeshift (unlike the personal backup) only allows selecting a full
# disk/partition as the destination, not a subfolder.
configure_timeshift_destination() {
  header
  printf "%s%s%s\n" "$BOLD" "$(ui ts_destination)" "$RESET"
  hr
  msg_info "$(ui ts_choose_folder)"
  msg_info "$(ui ts_detect_partition)"
  msg_info "$(ui ts_partition_root)"
  echo

  msg_info "$(ui detected_drives)"
  local found_paths=() found_display=()
  local mp size label kind
  while IFS=$'\t' read -r mp size label kind; do
    [[ -n "$mp" ]] || continue
    found_paths+=("$mp")
    found_display+=("$mp  ($label, $size, $kind)")
  done < <(list_mounted_drives)

  if [[ ${#found_paths[@]} -eq 0 ]]; then
    msg_warn "$(ui no_other_drive)"
  else
    local i=1 f
    for f in "${found_display[@]}"; do
      echo "  $i) $f"
      ((i+=1))
    done
  fi
  echo
  printf '%s\n' "$(ui select_drive)"
  printf '%s\n' "$(ui select_drive2)"
  read -rp "$(ui enter_cancel_prompt)" sel
  is_quit "$sel" && sel=""
  local chosen=""
  if [[ "$sel" =~ ^[0-9]+$ ]] && (( 10#$sel >= 1 && 10#$sel <= ${#found_paths[@]} )); then
    chosen="${found_paths[$((10#$sel - 1))]}"
  elif [[ "$sel" == "g" || "$sel" == "G" ]]; then
    local start_dir="${found_paths[0]:-/media/${USER:-}}"
    chosen="$(pick_folder_dialog "$(ui ts_choose_folder_dialog)" "$start_dir")"
    if [[ -z "$chosen" ]]; then
      msg_warn "$(ui no_folder_selected)"
      pause; return
    fi
  else
    chosen="$(expand_tilde "$sel")"
  fi
  [[ -n "$chosen" && "$chosen" != "/" ]] && chosen="${chosen%/}"

  if [[ -z "$chosen" ]]; then
    msg_warn "$(ui cancelled_op)"
    pause; return
  fi
  if ! is_absolute_path "$chosen"; then
    msg_err "$(ui path_not_absolute)"
    pause; return
  fi

  if [[ ! -d "$chosen" ]]; then
    msg_err "$(ui destination_missing "$chosen")"
    pause; return
  fi

  local device
  device="$(findmnt -no SOURCE --target "$chosen" 2>/dev/null)"
  device="${device%%\[*}"  # remove the btrfs subvolume suffix, e.g. /dev/sdb1[/@data]
  if [[ -z "$device" ]]; then
    msg_err "$(ui ts_partition_error "$chosen")"
    pause; return
  fi

  msg_info "$(ui chosen_folder "$chosen")"
  msg_info "$(ui detected_partition "$device")"
  warn_if_not_removable "$chosen"
  echo
  read -rp "$(ui confirm_ts_destination "$device")" ans
  if ! ui_yes "$ans"; then
    msg_warn "$(ui ts_cancelled)"
    pause; return
  fi

  if sudo timeshift --snapshot-device "$device" --yes 2>&1 | tee -a "$LOG_FILE"; then
    msg_ok "$(ui ts_dest_ok "$device")"
    log "$(ui ts_dest_ok "$device") [$chosen]"
  else
    msg_err "$(ui ts_dest_error)"
    log "ERROR: $(ui ts_dest_error): $device"
  fi
  pause
}

# --------------------------------------------------------------------------
# Schedule automatic backups (cron)
# --------------------------------------------------------------------------
dow_name() {
  local -a names_en=(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)
  local -a names_es=(domingo lunes martes miércoles jueves viernes sábado)
  if [[ "${APP_LANG:-en}" == es ]]; then printf '%s' "${names_es[$1]:-$1}"
  else printf '%s' "${names_en[$1]:-$1}"; fi
}

# SCRIPT_PATH as stored in the crontab line ("%" is escaped there, see build_cron_line).
cron_script_path() { printf '%s' "${SCRIPT_PATH//%/\\%}"; }

# Active (non-comment) crontab lines that run this script.
cron_entry() { crontab -l 2>/dev/null | grep -v '^[[:space:]]*#' | grep -F -- "$(cron_script_path)"; }

# The crontab without this script's active lines; comments and other jobs stay.
cron_without_entry() {
  crontab -l 2>/dev/null | P="$(cron_script_path)" awk '/^[[:space:]]*#/ || !index($0, ENVIRON["P"])'
}

# Prints a human-readable description of the scheduled task, or fails (no
# output) if there is none. Used by the main menu and by schedule_task.
describe_cron_schedule() {
  local line hh dow
  line="$(cron_entry | head -n1)"
  [[ -n "$line" ]] || return 1
  hh="$(awk '{print $2}' <<<"$line")"
  dow="$(awk '{print $5}' <<<"$line")"
  hh="$(printf '%02d' "$((10#$hh))" 2>/dev/null || echo "$hh")"
  if [[ "$dow" == "*" ]]; then
    printf '%s' "$(ui cron_desc_daily "$hh")"
  else
    printf '%s' "$(ui cron_desc_weekly "$(dow_name "$dow")" "$hh")"
  fi
}

# Crontab line for running this script with --auto. Escape "%" (cron treats it
# as a line break) in case SCRIPT_PATH/LOG_DIR contains one.
build_cron_line() {
  local hh="$1" dow="${2:-*}"
  local esc_path esc_log="${LOG_DIR//%/\\%}"
  esc_path="$(cron_script_path)"
  printf '0 %s * * %s "%s" --auto >> "%s/cron.log" 2>&1' "$hh" "$dow" "$esc_path" "$esc_log"
}

# Asks for the hour (0-23) into "hh". Fails after saying why if the user
# cancelled (Enter) or typed something invalid.
ask_cron_hour() {
  read -rp "$(ui hour_prompt)" hh
  if [[ -z "$hh" ]]; then
    msg_warn "$(ui cancelled_op)"
  elif ! [[ "$hh" =~ ^(0?[0-9]|1[0-9]|2[0-3])$ ]]; then
    msg_err "$(ui hour_invalid)"
  else
    return 0
  fi
  return 1
}

schedule_task() {
  header
  printf "%s%s%s\n" "$BOLD" "$(ui schedule_title)" "$RESET"
  hr
  msg_info "$(ui schedule_info)"
  echo
  local existing
  if existing="$(describe_cron_schedule)"; then
    msg_ok "$(ui current_task "$existing")"
  else
    msg_warn "$(ui current_task_none)"
  fi
  echo
  printf '%s\n' "$(ui daily)"
  printf '%s\n' "$(ui weekly)"
  printf '%s\n' "$(ui remove_task)"
  printf '%s\n' "$(ui back)"
  hr
  read_menu_option || return
  local cron_line=""
  case "$opt" in
    1)
      ask_cron_hour || { pause; return; }
      cron_line="$(build_cron_line "$((10#$hh))")"
      ;;
    2)
      read -rp "$(ui day_prompt)" dow
      if [[ -z "$dow" ]]; then
        msg_warn "$(ui cancelled_op)"
        pause; return
      elif ! [[ "$dow" =~ ^[0-6]$ ]]; then
        msg_err "$(ui day_invalid)"
        pause; return
      fi
      ask_cron_hour || { pause; return; }
      cron_line="$(build_cron_line "$((10#$hh))" "$dow")"
      ;;
    3)
      if [[ -z "$(cron_entry)" ]]; then
        msg_info "$(ui no_task "$APP_NAME")"
        pause; return
      fi
      read -rp "$(ui cron_remove_confirm)" ans
      if ! ui_yes "$ans"; then
        msg_warn "$(ui cancelled_op)"
        pause; return
      fi
      if (cron_without_entry || true) | crontab -; then
        msg_ok "$(ui task_removed)"
        log "$(ui task_removed)"
      else
        msg_err "$(ui cron_update_error)"
      fi
      pause; return
      ;;
    0) return ;;
    *) msg_err "$(ui invalid_option)"; pause; return ;;
  esac
  if ( cron_without_entry; echo "$cron_line" ) | crontab -; then
    msg_ok "$(ui task_added)"
    log "$(ui task_added): $cron_line"
  else
    msg_err "$(ui cron_install_error)"
    log "$(ui log_cron_error "$cron_line")"
  fi
  pause
}

# --------------------------------------------------------------------------
# View log history
# --------------------------------------------------------------------------
view_logs() {
  header
  printf "%s%s%s\n" "$BOLD" "$(ui logs_title)" "$RESET"
  hr
  shopt -s nullglob
  local logs=("$LOG_DIR"/backup_*.log)
  shopt -u nullglob
  if [[ ${#logs[@]} -eq 0 ]]; then
    msg_warn "$(ui no_logs)"
    pause; return
  fi
  # Same reasoning as in cleanup_old_logs: log filenames are controlled by
  # this script, so "ls -t" is safe to use for sorting.
  local -a shown
  # shellcheck disable=SC2012
  mapfile -t shown < <(ls -1t "$LOG_DIR"/backup_*.log | head -n 15)
  local i=1 f
  for f in "${shown[@]}"; do printf "%3d\t%s\n" "$i" "$f"; ((i+=1)); done
  echo
  read -rp "$(ui log_number)" n
  if [[ -n "$n" ]] && ! is_back "$n"; then
    # Resolved against "shown" (the displayed list): a hidden log can't be selected.
    if [[ "$n" =~ ^[0-9]+$ ]] && (( 10#$n >= 1 && 10#$n <= ${#shown[@]} )); then
      run_pager "${shown[$((10#$n - 1))]}"
      (( $? != 99 )) || pause
    else
      msg_err "$(ui number_range)"
      pause
    fi
  fi
}

# --------------------------------------------------------------------------
# Enable / disable mirror mode (--delete)
# --------------------------------------------------------------------------
toggle_delete() {
  header
  printf "%s%s%s\n" "$BOLD" "$(ui mirror_title)" "$RESET"
  hr
  if [[ "$USE_DELETE" == "yes" ]]; then
    printf "%s%s%s%s\n" "$GREEN" "$(ui currently)" "$(ui enabled)" "$RESET"
  else
    printf "%s%s%s%s\n" "$YELLOW" "$(ui currently)" "$(ui disabled)" "$RESET"
  fi
  echo
  msg_warn "$(ui mirror_warn)"
  msg_info "$(ui mirror_info)"
  echo
  local was_delete="$USE_DELETE"
  read -rp "$(ui mirror_prompt)" ans
  if ui_yes "$ans"; then
    USE_DELETE="yes"
  elif [[ "${ans,,}" =~ ^no?$ ]]; then
    USE_DELETE="no"
  elif [[ -n "$ans" ]]; then
    msg_err "$(ui response_unknown)"
  fi
  save_config
  if [[ "$USE_DELETE" == "yes" && "$was_delete" != "yes" && ${#SOURCE_DIRS[@]} -gt 0 && -n "$DEST_DIR" ]]; then
    read -rp "$(ui preview_after_mirror_prompt)" ans
    ui_yes "$ans" && preview_changes
  fi
  pause
}

# --------------------------------------------------------------------------
# Verify configuration: everything a real or scheduled backup needs, without
# copying anything (only the same write probe the real run does).
# --------------------------------------------------------------------------
verify_config() {
  header
  printf "%s%s%s\n" "$BOLD" "$(ui verify_title)" "$RESET"
  hr
  local bad=0 warn=0 s free task
  if command -v rsync &>/dev/null; then
    msg_ok "$(ui verify_rsync_ok)"
  else
    msg_err "$(ui rsync_missing)"; ((bad+=1))
  fi

  [[ ${#SOURCE_DIRS[@]} -eq 0 ]] && { msg_err "$(ui no_source_config)"; ((bad+=1)); }
  for s in "${SOURCE_DIRS[@]}"; do
    if [[ -d "$s" && -r "$s" && -x "$s" ]]; then
      msg_ok "$(ui verify_source_ok "$s")"
    else
      msg_err "$(ui verify_source_bad "$s")"; ((bad+=1))
    fi
  done

  if check_destination_usable; then
    if dest_is_writable "$DEST_DIR"; then
      msg_ok "$(ui verify_dest_ok "$DEST_DIR")"
    else
      msg_err "$(ui no_write "$DEST_DIR")"; ((bad+=1))
    fi
    dest_on_system_disk && { msg_warn "$(ui same_disk)"; ((warn+=1)); }
    if free="$(dest_free_bytes)"; then
      msg_info "$(ui estimate_free "$(human_size "$free")")"
      check_disk_space_low && { msg_warn "$(ui low_space)"; ((warn+=1)); }
    fi
  else
    ((bad+=1))
  fi

  if task="$(describe_cron_schedule)"; then
    msg_ok "$(ui current_task "$task")"
    [[ -x "$SCRIPT_PATH" ]] || { msg_err "$(ui verify_cron_noexec "$SCRIPT_PATH")"; ((bad+=1)); }
    # Only when the cron unit exists (systemd): otherwise there is nothing to query.
    if command -v systemctl &>/dev/null && systemctl cat cron.service &>/dev/null \
       && ! systemctl is-active --quiet cron.service; then
      msg_err "$(ui verify_cron_inactive)"; ((bad+=1))
    fi
  else
    msg_info "$(ui current_task_none)"
  fi

  echo; hr
  if (( bad )); then msg_err "$(ui verify_failed "$bad")"
  elif (( warn )); then msg_warn "$(ui verify_warned "$warn")"
  else msg_ok "$(ui verify_all_ok)"; fi
  pause
}

# --------------------------------------------------------------------------
# First-run wizard
# --------------------------------------------------------------------------
first_run_wizard() {
  header
  printf "%s%s%s\n" "$BOLD" "$(ui welcome "$APP_NAME")" "$RESET"
  hr
  msg_info "$(ui first_run)"
  echo
  read -rp "$(ui detect_personal)" ans
  if ui_yes "$ans"; then
    select_detected_sources
    if (( DETECT_NEW_COUNT == 0 || DETECT_ADDED_COUNT == 0 )); then
      msg_warn "$(ui detect_added_none)"
    else
      msg_ok "$(ui detected_count "$DETECT_ADDED_COUNT")"
    fi
  fi
  save_config
  pause
  configure_destination
}

# --------------------------------------------------------------------------
# Main menu
# --------------------------------------------------------------------------
# Status lines: outcome of the last run (color-coded) and the scheduled task.
menu_status() {
  local ts="" err="" warn="" secs="" bytes="" files="" res color task
  [[ -r "$LAST_STATUS_FILE" ]] && IFS='|' read -r ts err warn secs bytes files < "$LAST_STATUS_FILE"
  if [[ "$ts|$err|$warn|$secs|$bytes|$files" =~ ^[0-9]+(\|[0-9]+){5}$ ]]; then
    if (( err > 0 )); then color="$RED"; res="$(ui result_err "$err")"
    elif (( warn > 0 )); then color="$YELLOW"; res="$(ui result_warn "$warn")"
    else color="$GREEN"; res="$(ui result_ok)"; fi
    printf "  %s%s%s\n" "$color" "$(ui last_backup "$(date -d "@$ts" '+%Y-%m-%d %H:%M')" "$res" \
      "$(human_size "$bytes")" "$(format_duration "$secs")")" "$RESET"
  else
    printf "  %s%s%s\n" "$DIM" "$(ui last_backup_none)" "$RESET"
  fi
  if task="$(describe_cron_schedule)"; then
    printf "  %s%s%s\n" "$BOLD" "$(ui current_task "$task")" "$RESET"
  else
    printf "  %s%s%s\n" "$DIM" "$(ui current_task_none)" "$RESET"
  fi
}

main_menu() {
  while true; do
    header
    printf "  %s%s%s\n" "$BOLD" "$(ui menu_sources "${#SOURCE_DIRS[@]}")" "$RESET"
    printf "  %s%s%s\n" "$BOLD" "$(ui menu_destination "${DEST_DIR:-$(ui not_configured)}")" "$RESET"
    menu_status
    hr
    printf '%s\n' "$(ui menu_paths)"
    printf '%s\n' "$(ui menu_backup)"
    printf '%s\n' "$(ui menu_timeshift)"
    printf '%s\n' "$(ui menu_schedule)"
    printf '%s\n' "$(ui menu_logs)"
    printf '%s\n' "$(ui menu_mirror)"
    printf '%s\n' "$(ui menu_verify)"
    printf '%s\n' "$(ui menu_language)"
    printf '%s\n' "$(ui menu_help)"
    printf '%s\n' "$(ui menu_exit)"
    hr
    read_menu_option "  " || { echo; msg_warn "$(ui eof_exit)"; exit 0; }
    case "$opt" in
      1) configure_paths ;;
      2) run_backup ;;
      3) timeshift_backup ;;
      4) schedule_task ;;
      5) view_logs ;;
      6) toggle_delete ;;
      7) verify_config ;;
      l|L) toggle_app_language; PS3=$'\n'"$(ui select_prompt)"; save_config ;;
      h|H|\?) quick_help ;;
      0) echo; msg_ok "$(ui goodbye)"; exit 0 ;;
      *) msg_err "$(ui invalid_option)"; sleep 1 ;;
    esac
  done
}

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------
# Only runs when the script is executed directly, not when it is "source"d
# (e.g. by tests/test.sh, which needs the functions without triggering the
# menu or an automatic backup).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  IS_FIRST_RUN=false
  [[ -f "$CONFIG_FILE" ]] || IS_FIRST_RUN=true

  load_config
  [[ "$UI_LANGUAGE" == "es" || "$UI_LANGUAGE" == "en" || "$UI_LANGUAGE" == "auto" ]] || UI_LANGUAGE="auto"
  resolve_app_language
  PS3=$'\n'"$(ui select_prompt)"

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
