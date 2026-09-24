#!/usr/bin/env bash
# shellcheck disable=SC2034  # fixtures assign variables read by the sourced script
set -uo pipefail

ROOT_DIR="${PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$ROOT_DIR/script/simple-backup.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/bootstrap-home"
mkdir -p "$TEST_HOME/.config/simple-backup"
old_home="$HOME"
trap - INT TERM HUP
HOME="$TEST_HOME"
# shellcheck disable=SC1090
source "$SCRIPT"
HOME="$old_home"
trap - INT TERM HUP

PASS=0
FAIL=0

ok() { printf 'ok - %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'not ok - %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
run_test() {
  local name="$1"; shift
  if [[ -n "${TEST_FILTER:-}" && "$name" != *"$TEST_FILTER"* ]]; then return 0; fi
  if ( set -uo pipefail; "$@" ); then ok "$name"; else fail "$name"; fi
}

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]]
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" != *"$needle"* ]]
}

strip_ansi() {
  sed -E $'s/\\x1B\\[[0-9;?]*[[:alpha:]]//g'
}

file_hash() { sha256sum -- "$1" | awk '{print $1}'; }

# rsync argv equality ignoring the random temp path of --log-file.
same_argv() {
  cmp -s <(sed 's/^--log-file=.*/--log-file=TMP/' "$1") <(sed 's/^--log-file=.*/--log-file=TMP/' "$2")
}

make_fake_bin() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/zenity" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
  cat > "$dir/xdg-user-dir" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  DOCUMENTS) printf '%s\n' "$HOME/Documents" ;;
  MUSIC) printf '%s\n' "$HOME/Music" ;;
  PICTURES) printf '%s\n' "$HOME/Pictures" ;;
  VIDEOS) printf '%s\n' "$HOME/Videos" ;;
  DOWNLOAD) printf '%s\n' "$HOME/Downloads" ;;
  DESKTOP) printf '%s\n' "$HOME/Desktop" ;;
  PUBLICSHARE) printf '%s\n' "$HOME/Public" ;;
  TEMPLATES) printf '%s\n' "$HOME/Templates" ;;
  *) exit 1 ;;
esac
EOS
  chmod +x "$dir/zenity" "$dir/xdg-user-dir"
}

syntax_and_static_contract_test() {
  bash -n "$SCRIPT" || return 1

  local -A used=() key
  while IFS= read -r key; do
    [[ -n "$key" ]] && used["$key"]=1
  done < <(grep -oE '\$\(ui [A-Za-z0-9_]+' "$SCRIPT" | sed 's/.*ui //' | sort -u)

  local count=0 en_keys=""
  for key in "${!used[@]}"; do
    ((count+=1))
    [[ -n "${UI_EN[$key]+x}" && -n "${UI_ES[$key]+x}" ]] || {
      printf 'missing catalog key: %s\n' "$key" >&2
      return 1
    }
    en_keys+="$key\n"
    local en="${UI_EN[$key]}" es="${UI_ES[$key]}" en_fmt es_fmt
    [[ -n "$en" && -n "$es" ]] || return 1
    en_fmt="$(grep -oE '%[sd]' <<<"$en" | tr '\n' ' ')"
    es_fmt="$(grep -oE '%[sd]' <<<"$es" | tr '\n' ' ')"
    [[ "$en_fmt" == "$es_fmt" ]] || { printf 'placeholder mismatch: %s\n' "$key" >&2; return 1; }
  done
  (( count == ${#UI_EN[@]} )) || {
    printf 'catalog/usage mismatch: used=%d catalog=%d\n' "$count" "${#UI_EN[@]}" >&2
    return 1
  }
  for key in "${!UI_EN[@]}"; do
    [[ -n "${used[$key]+x}" ]] || {
      printf 'catalog key is not used by main script: %s\n' "$key" >&2
      return 1
    }
  done

  # Exclude the UI_EN=()/UI_ES=() catalog blocks: they legitimately hold
  # Spanish text as data (this used to be lang.sh, outside $SCRIPT's scope,
  # so this grep never had to skip it before). Everything else in $SCRIPT
  # must still go through ui(), never hardcode localized text directly.
  if sed '/^[[:space:]]*#/d' "$SCRIPT" | sed '/^UI_EN=($/,/^)$/d; /^UI_ES=($/,/^)$/d' | grep -nE '"(Cancelar|Cancelado|Copiar|Copia|Configuraci|Uso:|Elige|Salir|Destino|Origen|Falta|No se puede|No se pudo|Tarea|Historial|Activar|Desactivar)'; then
    printf 'possible hardcoded localized UI text found in main script\n' >&2
    return 1
  fi
}
run_test 'syntax + UI contract: every used key exists in both catalogs and no user-facing Spanish remains hardcoded' syntax_and_static_contract_test

language_resolution_test() {
  # The language catalog/functions now live inside $SCRIPT (no more standalone
  # lang.sh), so each probe sources the full script. It needs its own HOME
  # (no config.conf there, so nothing overrides UI_LANGUAGE) and must receive
  # the script path via an env var, not a positional argument: $SCRIPT itself
  # parses "$1" as a CLI flag, so passing the path as $1 would be misread as
  # an unknown option.
  local lang resolve_home="$TMP_DIR/lang-resolve-home"
  mkdir -p "$resolve_home"
  for lang in es_ES.UTF-8 es_MX.UTF-8 es_ES@euro; do
    local out
    out="$(env -u LC_ALL -u LC_MESSAGES LANG="$lang" HOME="$resolve_home" SB_SCRIPT="$SCRIPT" bash -c 'source "$SB_SCRIPT"; UI_LANGUAGE=auto; resolve_app_language; printf "%s" "$APP_LANG"' 2>/dev/null)" || return 1
    [[ "$out" == es ]] || return 1
  done
  for lang in C.UTF-8 en_US.UTF-8 pt_BR.UTF-8 de_DE.UTF-8; do
    local out
    out="$(env -u LC_ALL -u LC_MESSAGES LANG="$lang" HOME="$resolve_home" SB_SCRIPT="$SCRIPT" bash -c 'source "$SB_SCRIPT"; UI_LANGUAGE=auto; resolve_app_language; printf "%s" "$APP_LANG"' 2>/dev/null)" || return 1
    [[ "$out" == en ]] || return 1
  done
  local out
  out="$(LC_ALL=C.UTF-8 LC_MESSAGES=es_ES.UTF-8 LANG=es_ES.UTF-8 HOME="$resolve_home" SB_SCRIPT="$SCRIPT" bash -c 'source "$SB_SCRIPT"; UI_LANGUAGE=auto; resolve_app_language; printf "%s" "$APP_LANG"' 2>/dev/null)" || return 1
  [[ "$out" == en ]] || return 1
  local out
  # UI_LANGUAGE must be set AFTER sourcing: $SCRIPT itself initializes
  # UI_LANGUAGE="auto" unconditionally, so a value exported beforehand would
  # just be overwritten (this line lived only in simple-backup.sh, never in
  # the old standalone lang.sh, so the previous "set env var, then source"
  # order no longer applies once lang.sh is merged in).
  out="$(LC_ALL=C.UTF-8 LANG=en_US.UTF-8 HOME="$resolve_home" SB_SCRIPT="$SCRIPT" bash -c 'source "$SB_SCRIPT"; UI_LANGUAGE=es; resolve_app_language; printf "%s" "$APP_LANG"')" || return 1
  [[ "$out" == es ]] || return 1
  out="$(LC_ALL=C.UTF-8 LANG=C.UTF-8 HOME="$resolve_home" SB_SCRIPT="$SCRIPT" bash -c 'source "$SB_SCRIPT"; UI_LANGUAGE=en; resolve_app_language; printf "%s" "$APP_LANG"')" || return 1
  [[ "$out" == en ]] || return 1
  out="$(LANG=C.UTF-8 HOME="$resolve_home" SB_SCRIPT="$SCRIPT" bash -c 'source "$SB_SCRIPT"; UI_LANGUAGE=bogus; resolve_app_language; printf "%s" "$APP_LANG"')" || return 1
  [[ "$out" == en ]]
}
run_test 'language resolution: locale precedence, Spanish-family detection and explicit override' language_resolution_test

catalog_quality_test() {
  local k en es
  for k in "${!UI_EN[@]}"; do
    [[ -n "${UI_ES[$k]+x}" ]] || return 1
    en="${UI_EN[$k]}"; es="${UI_ES[$k]}"
    [[ "$en" != "$es" || "$k" =~ ^(enabled|disabled|log_ok|log_error|log_filesystem)$ || "$en" =~ ^[Yy]/[Nn]$ ]] || {
      printf 'suspicious untranslated key: %s\n' "$k" >&2
      return 1
    }
    grep -q $'\r' <<<"$en$es" && return 1
  done
  APP_LANG=en; [[ "$(ui menu_language)" == *'Switch language'* ]] || return 1
  APP_LANG=es; [[ "$(ui menu_language)" == *'Cambiar idioma'* ]] || return 1
  APP_LANG=en; [[ "$(ui select_prompt)" == 'Choose a number: ' ]] || return 1
  APP_LANG=es; [[ "$(ui select_prompt)" == 'Elige un número: ' ]] || return 1
  APP_LANG=en; [[ "$(ui cancel_option)" == 'Cancel' ]] || return 1
  APP_LANG=es; [[ "$(ui cancel_option)" == 'Cancelar' ]] || return 1
  local -A expected_en=(
    [welcome]='Welcome to %s!'
    [menu_language]='  L) Switch language (EN/ES)'
    [menu_exit]='  0) Exit'
    [choose_option]='Choose an option: '
    [backup_title]='Incremental backup'
    [backup_ok]='Backup finished without errors.'
    [auto_summary]='Automatic backup: errors: %s; warnings: %s. Log: %s'
    [copy_error]='Error copying %s (rsync exit code: %s)'
    [copied_warn]='Completed with minor warnings: %s (rsync exit code: %s, %s)'
    [task_added]='Scheduled task added successfully.'
    [task_removed]='Scheduled task removed.'
    [no_task]='No scheduled %s task was found.'
    [timeshift_comment]='Automatic backup %s'
  )
  local -A expected_es=(
    [welcome]='¡Bienvenido a %s!'
    [menu_language]='  L) Cambiar idioma (EN/ES)'
    [menu_exit]='  0) Salir'
    [choose_option]='Elige una opción: '
    [backup_title]='Copia de seguridad incremental'
    [backup_ok]='Copia finalizada sin errores.'
    [auto_summary]='Backup automático: errores: %s; avisos: %s. Log: %s'
    [copy_error]='Error al copiar %s (código rsync: %s)'
    [copied_warn]='Completado con avisos menores: %s (código rsync: %s, %s)'
    [task_added]='Tarea programada añadida correctamente.'
    [task_removed]='Tarea programada eliminada.'
    [timeshift_comment]='Backup automático %s'
  )
  for k in "${!expected_en[@]}"; do [[ "${UI_EN[$k]}" == "${expected_en[$k]}" ]] || { printf 'unexpected EN wording: %s\n' "$k" >&2; return 1; }; done
  for k in "${!expected_es[@]}"; do [[ "${UI_ES[$k]}" == "${expected_es[$k]}" ]] || { printf 'unexpected ES wording: %s\n' "$k" >&2; return 1; }; done
  for key in "${!expected_en[@]}"; do [[ "${UI_EN[$key]}" == "${expected_en[$key]}" ]] || { printf 'unexpected EN wording: %s\n' "$key" >&2; return 1; }; done
  for key in "${!expected_es[@]}"; do [[ "${UI_ES[$key]}" == "${expected_es[$key]}" ]] || { printf 'unexpected ES wording: %s\n' "$key" >&2; return 1; }; done
}
run_test 'catalog quality: translated content, Unicode hygiene and critical UI wording' catalog_quality_test

documentation_links_and_language_test() {
  local f
  for f in README.md README.es.md .github/CONTRIBUTING.md .github/SECURITY.md .github/CODE_OF_CONDUCT.md .github/PULL_REQUEST_TEMPLATE.md .github/ISSUE_TEMPLATE/bug_report.md .github/ISSUE_TEMPLATE/feature_request.md; do
    [[ -f "$f" ]] || return 1
  done
  [[ -f LICENSE.txt ]] || return 1
  grep -Fq 'LICENSE.txt' script/simple-backup.sh || return 1
  ! grep -Fq 'archivo LICENSE para' script/simple-backup.sh || return 1
  python3 - <<'PY2'
from pathlib import Path
import re
files=[Path(x) for x in ['README.md','README.es.md','.github/CONTRIBUTING.md','.github/SECURITY.md','.github/CODE_OF_CONDUCT.md','.github/PULL_REQUEST_TEMPLATE.md','.github/ISSUE_TEMPLATE/bug_report.md','.github/ISSUE_TEMPLATE/feature_request.md']]
for f in files:
    text=f.read_text(encoding='utf-8')
    for href in re.findall(r'\[[^\]]+\]\(([^)]+)\)', text):
        if href.startswith(('#','http://','https://','mailto:')):
            continue
        target=href.split('#',1)[0]
        if target and not (f.parent / target).exists():
            raise SystemExit(f'missing relative link: {f} -> {href}')
PY2
  local out
  out="$(APP_LANG=en ui rsync_reason_changed)"
  [[ "$out" == 'source files that disappeared during the copy; this can be normal' ]] || return 1
  return 0
}
run_test 'documentation links and English-facing wording' documentation_links_and_language_test

# Regression: zenity is optional and must only be offered for install on the
# very first run, not nagged about on every later startup.
zenity_optional_dependency_test() {
  local bin="$TMP_DIR/zenity-dep-bin" out
  rm -rf "$bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/rsync"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/xdg-user-dir"
  chmod +x "$bin/rsync" "$bin/xdg-user-dir"
  export PATH="$bin:$PATH"
  APP_LANG=en
  IS_FIRST_RUN=true
  out="$(check_dependencies </dev/null 2>&1)"
  assert_contains "$out" 'zenity' || return 1
  IS_FIRST_RUN=false
  out="$(check_dependencies </dev/null 2>&1)"
  [[ -z "$out" ]] || return 1
}
run_test 'dependency check: a missing zenity is only offered for install on the first run, not every startup' zenity_optional_dependency_test

config_roundtrip_test() {
  local home="$TMP_DIR/config-home" old_home="$HOME"
  rm -rf "$home"; mkdir -p "$home/.config/simple-backup"
  HOME="$home"
  CONFIG_DIR="$home/.config/simple-backup"
  CONFIG_FILE="$CONFIG_DIR/config.conf"
  SOURCE_DIRS=("$home/My Documents" "$home/Álbumes/rock & roll" "$home/a[b]")
  EXCLUDES=("*.tmp" "space name" "á*" "quote'\"")
  DEST_DIR="$home/Backup Drive/50% done"
  USE_DELETE=yes
  UI_LANGUAGE=es
  save_config
  [[ -f "$CONFIG_FILE" ]] || return 1
  chmod_mode="$(stat -c %a "$CONFIG_FILE")"; [[ "$chmod_mode" == 600 ]] || return 1
  SOURCE_DIRS=(); EXCLUDES=(); DEST_DIR=; USE_DELETE=no; UI_LANGUAGE=auto
  load_config
  [[ "${SOURCE_DIRS[0]}" == "$home/My Documents" && "${SOURCE_DIRS[1]}" == "$home/Álbumes/rock & roll" && "${SOURCE_DIRS[2]}" == "$home/a[b]" ]] || return 1
  [[ "${EXCLUDES[0]}" == '*.tmp' && "${EXCLUDES[3]}" == "quote'\"" ]] || return 1
  [[ "$DEST_DIR" == "$home/Backup Drive/50% done" && "$USE_DELETE" == yes && "$UI_LANGUAGE" == es ]] || return 1
  HOME="$old_home"
}
run_test 'configuration round-trip preserves paths, patterns, booleans and selected language' config_roundtrip_test

cli_boundary_test() {
  local home="$TMP_DIR/cli-home" out rc marker="$TMP_DIR/malicious-ran"
  rm -rf "$home"; mkdir -p "$home/.config/simple-backup"
  cat > "$home/.config/simple-backup/config.conf" <<EOF2
UI_LANGUAGE=es
$(printf 'touch %q\n' "$marker")
EOF2
  set +e
  out="$(HOME="$home" bash "$SCRIPT" --help 2>&1)"; rc=$?
  set -e
  [[ $rc -eq 0 ]] || return 1
  [[ "$out" == *'Uso:'* && "$out" != *'Usage:'* ]] || return 1
  [[ ! -e "$marker" ]] || return 1
  printf 'UI_LANGUAGE=en\n' > "$home/.config/simple-backup/config.conf"
  out="$(HOME="$home" bash "$SCRIPT" --help 2>&1)" || return 1
  [[ "$out" == *'Usage:'* && "$out" != *'Uso:'* ]] || return 1
  set +e
  out="$(HOME="$home" bash "$SCRIPT" --bad-option 2>&1)"; rc=$?
  set -e
  [[ $rc -eq 1 && "$out" == *'Unknown option: --bad-option'* ]] || return 1
  set +e
  out="$(HOME="$home" bash "$SCRIPT" a b 2>&1)"; rc=$?
  set -e
  [[ $rc -eq 1 && "$out" == *'Too many arguments.'* ]] || return 1
}
run_test 'CLI boundaries: localized help/errors without executing user config' cli_boundary_test

language_toggle_persistence_test() {
  local home="$TMP_DIR/toggle-home" fake="$TMP_DIR/toggle-bin" out
  rm -rf "$home" "$fake"; mkdir -p "$home/.config/simple-backup" "$fake"
  make_fake_bin "$fake"
  cat > "$home/.config/simple-backup/config.conf" <<'EOF2'
SOURCE_DIRS=()
EXCLUDES=()
DEST_DIR=''
USE_DELETE=no
UI_LANGUAGE=en
EOF2
  out="$(printf 'l\n0\n' | HOME="$home" PATH="$fake:$PATH" TERM=xterm bash "$SCRIPT" 2>&1)" || return 1
  [[ "$out" == *'Cambiar idioma (EN/ES)'* ]] || return 1
  grep -q '^UI_LANGUAGE=es$' "$home/.config/simple-backup/config.conf" || return 1
  out="$(printf 'L\n0\n' | HOME="$home" PATH="$fake:$PATH" TERM=xterm bash "$SCRIPT" 2>&1)" || return 1
  [[ "$out" == *'Switch language (EN/ES)'* ]] || return 1
  grep -q '^UI_LANGUAGE=en$' "$home/.config/simple-backup/config.conf" || return 1
  APP_LANG=en; UI_LANGUAGE=en; toggle_app_language; [[ "$APP_LANG" == es && "$UI_LANGUAGE" == es ]] || return 1
  toggle_app_language; [[ "$APP_LANG" == en && "$UI_LANGUAGE" == en ]] || return 1
  APP_LANG=en; ui_yes y || return 1; ! ui_yes s || return 1
  APP_LANG=es; ui_yes s || return 1; ! ui_yes y || return 1
}
run_test 'interactive language switch: l/L, persistence and localized yes/no semantics' language_toggle_persistence_test

localized_confirmation_contract_test() {
  local key
  for key in install_missing add_anyway create_folder continue_anyway install_timeshift create_snapshot confirm_ts_destination mirror_prompt detect_personal; do
    [[ "${UI_EN[$key]}" == *'(y/n)'* || "${UI_EN[$key]}" == *'(y/n,'* ]] || { printf 'EN prompt missing y/n contract: %s\n' "$key" >&2; return 1; }
    [[ "${UI_ES[$key]}" == *'(s/n)'* || "${UI_ES[$key]}" == *'(s/n,'* ]] || { printf 'ES prompt missing s/n contract: %s\n' "$key" >&2; return 1; }
  done
  APP_LANG=en; ui_yes y || return 1; ! ui_yes s || return 1
  APP_LANG=es; ui_yes s || return 1; ! ui_yes y || return 1
  ! grep -Fq '[[ "$crear" =~ ^[sS]$ ]]' "$SCRIPT" || return 1
  ! grep -Fq '[[ ! "$ans" =~ ^[sS]$ ]]' "$SCRIPT" || return 1
}
run_test 'localized confirmation contract: every y/n prompt is matched by language-aware acceptance logic' localized_confirmation_contract_test

menu_navigation_contract_test() {
  local key lang out home="$TMP_DIR/nav-home" fake="$TMP_DIR/nav-bin"
  for key in enter_source_path exclusion_pattern enter_cancel_prompt hour_prompt day_prompt log_number; do
    [[ "${UI_EN[$key]}" == *'(Enter to cancel)'* && "${UI_ES[$key]}" == *'(Enter para cancelar)'* ]] || { printf 'cancel wording differs: %s\n' "$key" >&2; return 1; }
  done
  rm -rf "$home" "$fake"; mkdir -p "$home/.config/simple-backup" "$fake"
  make_fake_bin "$fake"
  for lang in en es; do
    printf 'SOURCE_DIRS=()\nEXCLUDES=()\nDEST_DIR=\nUSE_DELETE=no\nUI_LANGUAGE=%s\n' "$lang" > "$home/.config/simple-backup/config.conf"
    # q leaves a submenu, h/H/? open the help and come back, Q exits the program.
    out="$(printf '1\nq\nh\n\nH\n\n?\n\nQ\n' | HOME="$home" PATH="$fake:$PATH" TERM=xterm bash "$SCRIPT" 2>&1)" || return 1
    local -n cat_ref="UI_${lang^^}"
    assert_not_contains "$out" "${cat_ref[invalid_option]}" || return 1
    assert_contains "$out" "${cat_ref[goodbye]}" || return 1
    (( $(grep -cF -- "${cat_ref[help_keys]}" <<<"$out") == 3 )) || return 1
  done
}
run_test 'menu navigation contract: q aliases 0, h/H/? open the quick help, and all text prompts share one cancel wording' menu_navigation_contract_test

pty_ui_test() {
  local home="$TMP_DIR/pty-home" fake="$TMP_DIR/pty-bin"
  rm -rf "$home" "$fake"; mkdir -p "$home/.config/simple-backup" "$fake"
  make_fake_bin "$fake"
  for lang in en es; do
    printf 'SOURCE_DIRS=()\nEXCLUDES=()\nDEST_DIR=%q\nUSE_DELETE=no\nUI_LANGUAGE=%s\n' "$home/dest" "$lang" > "$home/.config/simple-backup/config.conf"
    mkdir -p "$home/dest"
    local out clean
    out="$(printf '0\n' | HOME="$home" PATH="$fake:$PATH" TERM=xterm script -qefc "bash '$SCRIPT'" /dev/null 2>&1)" || return 1
    clean="$(printf '%s' "$out" | strip_ansi)"
    assert_contains "$clean" 'SIMPLE-BACKUP' || return 1
    assert_contains "$clean" 'Linux Mint' || return 1
    if [[ "$lang" == en ]]; then
      assert_contains "$clean" 'Switch language (EN/ES)' || return 1
      assert_contains "$clean" 'Choose an option:' || return 1
      assert_contains "$clean" '0) Exit' || return 1
      assert_not_contains "$clean" 'Cambiar idioma' || return 1
    else
      assert_contains "$clean" 'Cambiar idioma (EN/ES)' || return 1
      assert_contains "$clean" 'Elige una opción:' || return 1
      assert_contains "$clean" '0) Salir' || return 1
      assert_not_contains "$clean" 'Switch language' || return 1
    fi
    if ! printf '%s' "$clean" | python3 -c 'import sys,unicodedata; bad=[(sum(1 for c in l if not unicodedata.combining(c)),l) for l in sys.stdin.read().splitlines() if sum(1 for c in l if not unicodedata.combining(c))>80]; [print(f"80-col overflow ({w}): {l}", file=sys.stderr) for w,l in bad]; raise SystemExit(1 if bad else 0)'; then
      return 1
    fi
  done
}
run_test 'real TTY UI: 80-column rendering, prompts and language-specific main menu' pty_ui_test

backup_semantics_test() {
  local root="$TMP_DIR/backup" src dst home
  rm -rf "$root"; mkdir -p "$root"; src="$root/src"; dst="$root/dst"; home="$root/home"
  mkdir -p "$src/Documentos/dir with spaces" "$src/Documentos/.cache" "$src/Documentos/sub" "$home"
  printf 'alpha\n' > "$src/Documentos/dir with spaces/file one.txt"
  printf 'do-not-copy\n' > "$src/Documentos/.cache/hidden.txt"
  printf 'unicode\n' > "$src/Documentos/é.txt"
  printf 'stable\n' > "$src/Documentos/sub/stable.txt"
  ln -s 'sub/stable.txt' "$src/Documentos/link.txt"
  HOME="$home" APP_LANG=en UI_LANGUAGE=en SOURCE_DIRS=("$src/Documentos") EXCLUDES=(.cache) DEST_DIR="$dst" USE_DELETE=no
  same_filesystem() { return 1; }
  check_destination_mounted_auto() { return 0; }
  run_auto >"$root/run1.out" 2>&1 || return 1
  [[ -f "$dst/Documentos/dir with spaces/file one.txt" && -f "$dst/Documentos/é.txt" ]] || return 1
  [[ -L "$dst/Documentos/link.txt" ]] || return 1
  [[ ! -e "$dst/Documentos/.cache/hidden.txt" ]] || return 1
  local stable_hash inode1 mtime1
  stable_hash="$(file_hash "$dst/Documentos/sub/stable.txt")"; inode1="$(stat -c %i "$dst/Documentos/sub/stable.txt")"; mtime1="$(stat -c %Y "$dst/Documentos/sub/stable.txt")"
  sleep 1
  run_auto >"$root/run2.out" 2>&1 || return 1
  [[ "$(file_hash "$dst/Documentos/sub/stable.txt")" == "$stable_hash" ]] || return 1
  [[ "$(stat -c %i "$dst/Documentos/sub/stable.txt")" == "$inode1" ]] || return 1
  [[ "$(stat -c %Y "$dst/Documentos/sub/stable.txt")" == "$mtime1" ]] || return 1
  printf 'changed\n' > "$src/Documentos/sub/stable.txt"
  run_auto >"$root/run3.out" 2>&1 || return 1
  [[ "$(cat "$dst/Documentos/sub/stable.txt")" == changed ]] || return 1
  printf 'destination-only\n' > "$dst/Documentos/keep.txt"
  mkdir -p "$dst/Documentos/.cache"
  printf 'excluded-destination\n' > "$dst/Documentos/.cache/keep.txt"
  rm "$src/Documentos/dir with spaces/file one.txt"
  USE_DELETE=yes
  APP_LANG=es; UI_LANGUAGE=es
  run_auto >"$root/run4.out" 2>&1 || return 1
  [[ ! -e "$dst/Documentos/dir with spaces/file one.txt" ]] || return 1
  [[ ! -e "$dst/Documentos/keep.txt" ]] || return 1
  [[ -f "$dst/Documentos/.cache/keep.txt" ]] || return 1
  assert_contains "$(cat "$root/run4.out")" 'Backup automático: errores: 0; avisos: 0.' || return 1
}
run_test 'real backup contract: spaces/Unicode/symlink, incremental no-op, update, exclusion and mirror semantics' backup_semantics_test

auto_same_disk_test() {
  # An internal destination is treated like an external one: warn in the log, never abort.
  local root="$TMP_DIR/auto-same-disk"
  rm -rf "$root"; mkdir -p "$root/home" "$root/src" "$root/dst" "$root/logs"
  printf 'data\n' > "$root/src/f.txt"
  HOME="$root/home" APP_LANG=en UI_LANGUAGE=en SOURCE_DIRS=("$root/src") EXCLUDES=() DEST_DIR="$root/dst" USE_DELETE=no
  LOG_DIR="$root/logs"; LOG_FILE="$root/logs/a.log"
  same_filesystem() { return 0; }
  check_destination_mounted_auto || return 1
  run_auto >"$root/out" 2>&1 || return 1
  [[ -f "$root/dst/src/f.txt" ]] || return 1
  assert_contains "$(<"$LOG_FILE")" 'same disk as the system' || return 1
}
run_test 'automatic mode: destination on the same disk only logs a warning and the backup still runs' auto_same_disk_test

dest_mount_setup() {
  # Fake findmnt/same_filesystem: FAKE_DISK=system|drive, FAKE_MOUNT=<current mount point>.
  local root="$1"
  rm -rf "$root"; mkdir -p "$root/home" "$root/src" "$root/dst" "$root/cfg" "$root/logs" "$root/bin"
  printf 'data\n' > "$root/src/f.txt"
  cat > "$root/bin/findmnt" <<'EOS'
#!/usr/bin/env bash
case "$*" in *FSTYPE*) echo ext4 ;; *) echo "${FAKE_MOUNT:-/}" ;; esac
EOS
  chmod +x "$root/bin/findmnt"
  PATH="$root/bin:$PATH"
  HOME="$root/home" APP_LANG=en UI_LANGUAGE=en SOURCE_DIRS=("$root/src") EXCLUDES=() DEST_DIR="$root/dst" USE_DELETE=no DEST_MOUNT=""
  CONFIG_DIR="$root/cfg" CONFIG_FILE="$root/cfg/config.conf" LOG_DIR="$root/logs" LOG_FILE="$root/logs/a.log"
  same_filesystem() { [[ "${FAKE_DISK:-drive}" == system ]]; }
}

dest_mount_contract_test() {
  local root="$TMP_DIR/dest-mount"; dest_mount_setup "$root"
  export FAKE_DISK=system FAKE_MOUNT=/
  [[ -z "$(current_dest_mount)" ]] && ! dest_mount_lost || return 1
  remember_dest_mount; [[ -z "$DEST_MOUNT" && ! -e "$CONFIG_FILE" ]] || return 1
  export FAKE_DISK=drive FAKE_MOUNT=/media/u/X
  [[ "$(current_dest_mount)" == /media/u/X ]] || return 1
  remember_dest_mount
  [[ "$DEST_MOUNT" == /media/u/X ]] && grep -Fqx 'DEST_MOUNT=/media/u/X' "$CONFIG_FILE" || return 1
  ! dest_mount_lost && check_destination_mounted_auto || return 1
  FAKE_MOUNT=/media/u/Y; dest_mount_lost || return 1
  FAKE_DISK=system FAKE_MOUNT=/; dest_mount_lost || return 1
  ! check_destination_mounted_auto || return 1
}
run_test 'destination drive contract: mount point is remembered and a lost drive is detected' dest_mount_contract_test

auto_mount_lost_test() {
  local root="$TMP_DIR/auto-lost"; dest_mount_setup "$root"
  DEST_MOUNT=/media/u/X
  export FAKE_DISK=system FAKE_MOUNT=/
  run_auto >"$root/out" 2>&1 && return 1
  [[ ! -e "$root/dst/src" ]] || return 1
  assert_contains "$(<"$LOG_FILE")" 'no longer on its drive' || return 1
  export FAKE_DISK=drive FAKE_MOUNT=/media/u/X
  run_auto >"$root/out" 2>&1 || return 1
  [[ -f "$root/dst/src/f.txt" ]]
}
run_test 'automatic mode: aborts without copying when the destination drive is no longer mounted' auto_mount_lost_test

rsync_exit_contract_test() {
  local bin="$TMP_DIR/fake-rsync" root="$TMP_DIR/rc-contract" rc out
  rm -rf "$bin" "$root"; mkdir -p "$bin" "$root/src" "$root/dst" "$root/home/logs"
  cat > "$bin/rsync" <<'EOS'
#!/usr/bin/env bash
case "${FAKE_RSYNC_MSG:-default}" in
  metadata) printf 'rsync: failed to set times on target: Operation not permitted\n' ;;
  permission) printf 'rsync: failed to transfer some files: Permission denied\n' ;;
  *) printf 'fake rsync output\n' ;;
esac
exit "${FAKE_RSYNC_RC:-0}"
EOS
  chmod +x "$bin/rsync"
  for rc in 0 24 1; do
    mkdir -p "$root/logs"
    LOG_FILE="$root/logs/$rc.log"; LOG_DIR="$root/logs"; RSYNC_FLAGS=(-a); EXCLUDES=(); USE_DELETE=no; APP_LANG=en
    DEST_FSTYPE=ext4
    export PATH="$bin:$PATH" FAKE_RSYNC_RC="$rc" FAKE_RSYNC_MSG=default
    sync_one_source "$root/src" "$root/dst" no
    got=$?
    case "$rc" in 0) [[ $got -eq 0 ]] || return 1;; 24) [[ $got -eq 2 ]] || return 1;; 1) [[ $got -eq 1 ]] || return 1;; esac
  done
  LOG_FILE="$root/logs/23-metadata.log"; LOG_DIR="$root/logs"; DEST_FSTYPE=exfat; APP_LANG=en
  export FAKE_RSYNC_RC=23 FAKE_RSYNC_MSG=metadata
  sync_one_source "$root/src" "$root/dst" no
  [[ $? -eq 2 ]] || return 1
  LOG_FILE="$root/logs/23-real-error.log"; DEST_FSTYPE=exfat
  export FAKE_RSYNC_RC=23 FAKE_RSYNC_MSG=permission
  sync_one_source "$root/src" "$root/dst" no
  [[ $? -eq 1 ]] || return 1
  LOG_FILE="$root/logs/23-ext4.log"; DEST_FSTYPE=ext4
  export FAKE_RSYNC_RC=23 FAKE_RSYNC_MSG=metadata
  sync_one_source "$root/src" "$root/dst" no
  [[ $? -eq 1 ]] || return 1
  LOG_FILE="$root/logs/interactive.log"; APP_LANG=es; export PATH="$bin:$PATH" FAKE_RSYNC_RC=24
  set +e
  out="$(sync_one_source "$root/src" "$root/dst" yes 1 1 2>&1)"
  rc=$?
  set -e
  [[ $rc -eq 2 && "$out" == *'Completado con avisos menores'* ]] || return 1
  assert_contains "$out" 'archivos que desaparecieron del origen durante la copia; puede ser normal' || return 1
}
run_test 'rsync exit contract: 23 is contextual; 0/24/other keep their status mapping' rsync_exit_contract_test

language_behavior_equivalence_test() {
  local bin="$TMP_DIR/lang-equivalence-bin" root="$TMP_DIR/lang-equivalence" args_en="$TMP_DIR/lang-en.args" args_es="$TMP_DIR/lang-es.args"
  rm -rf "$bin" "$root"; mkdir -p "$bin" "$root/src/sub" "$root/dst" "$root/logs"
  printf 'same-content\n' > "$root/src/sub/file.txt"
  ln -s 'sub/file.txt' "$root/src/link.txt"
  cat > "$bin/rsync" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${RSYNC_ARGS_FILE:?}"
exec /usr/bin/rsync "$@"
EOS
  chmod +x "$bin/rsync"
  export PATH="$bin:$PATH"
  EXCLUDES=('*.tmp' 'cache dir'); USE_DELETE=no; RSYNC_FLAGS=(-a); DEST_FSTYPE=ext4
  for lang in en es; do
    rm -rf "$root/dst"; mkdir -p "$root/dst"
    LOG_FILE="$root/logs/$lang.log"; LOG_DIR="$root/logs"; APP_LANG="$lang"
    RSYNC_ARGS_FILE="$args_en"; [[ "$lang" == es ]] && RSYNC_ARGS_FILE="$args_es"
    export RSYNC_ARGS_FILE
    sync_one_source "$root/src" "$root/dst" no || return 1
    [[ -f "$root/dst/sub/file.txt" && -L "$root/dst/link.txt" ]] || return 1
  done
  same_argv "$args_en" "$args_es" || { printf 'language changed rsync argv\n' >&2; return 1; }
  return 0
}
run_test 'language equivalence: identical backup operation and rsync argv in EN/ES' language_behavior_equivalence_test

rsync_argument_contract_test() {
  local bin="$TMP_DIR/rsync-args-bin" root="$TMP_DIR/rsync-args" args_en="$TMP_DIR/rsync-en.args" args_es="$TMP_DIR/rsync-es.args"
  rm -rf "$bin" "$root"; mkdir -p "$bin" "$root/src" "$root/dst" "$root/logs"
  cat > "$bin/rsync" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${RSYNC_ARGS_FILE:?}"
exit 0
EOS
  chmod +x "$bin/rsync"
  export PATH="$bin:$PATH"
  LOG_DIR="$root/logs"; RSYNC_FLAGS=(-a); EXCLUDES=('cache dir' '*.tmp'); USE_DELETE=yes
  for lang in en es; do
    local args="$args_en"
    [[ "$lang" == es ]] && args="$args_es"
    export RSYNC_ARGS_FILE="$args"
    LOG_FILE="$root/logs/$lang.log"; APP_LANG="$lang"
    sync_one_source "$root/src" "$root/dst" no || return 1
    grep -Fqx -- '--exclude=cache dir' "$args" || return 1
    grep -Fqx -- '--exclude=*.tmp' "$args" || return 1
    grep -Fqx -- '--delete' "$args" || return 1
  done
  same_argv "$args_en" "$args_es" || { printf 'language changed rsync argv\n' >&2; return 1; }
  USE_DELETE=no; APP_LANG=en; export RSYNC_ARGS_FILE="$args_en"
  sync_one_source "$root/src" "$root/dst" no || return 1
  ! grep -Fqx -- '--delete' "$args_en" || return 1
}
run_test 'rsync argument contract: excludes are preserved and mirror deletion is opt-in' rsync_argument_contract_test

mirror_empty_source_test() {
  local root="$TMP_DIR/mirror-empty" home src dst
  home="$root/home"; src="$root/src/Documentos"; dst="$root/dst"
  rm -rf "$root"; mkdir -p "$src" "$dst/Documentos" "$home"
  printf 'kept\n' > "$dst/Documentos/keep.txt"
  HOME="$home" APP_LANG=en UI_LANGUAGE=en SOURCE_DIRS=("$src") EXCLUDES=() DEST_DIR="$dst" USE_DELETE=yes
  same_filesystem() { return 1; }
  check_destination_mounted_auto() { return 0; }
  run_auto >/dev/null 2>&1 || return 1
  [[ -f "$dst/Documentos/keep.txt" ]] || return 1
  assert_contains "$(cat "$LOG_FILE")" 'mirror mode is on' || return 1
  # Interactive mode still lets the user confirm on purpose (declining keeps the skip).
  printf 'n\n' | mirror_would_wipe "$src" yes || return 1
  ( printf 'y\n' | mirror_would_wipe "$src" yes ) && return 1
  # A source with content is never treated as a wipe risk, even if it was empty before.
  touch "$src/file.txt"
  mirror_would_wipe "$src" no && return 1
  return 0
}
run_test 'mirror mode contract: an empty source (e.g. an unmounted drive) is skipped instead of wiping its backup' mirror_empty_source_test

safety_and_path_contract_test() {
  local root="$TMP_DIR/safety"
  rm -rf "$root"; mkdir -p "$root/home" "$root/src" "$root/src/nested" "$root/dst"
  HOME="$root/home" SOURCE_DIRS=("$root/src")
  dest_inside_a_source "$root/src/nested" || return 1
  ! dest_inside_a_source "$root/dst" || return 1
  local rc
  set +e; check_destination_mounted_auto; rc=$?; set -e
  [[ $rc -eq 1 ]] || return 1
  mkdir -p "$root/dst2"
  same_filesystem() { return 0; }
  dest_is_writable() { return 0; }
  printf 's\n' | DEST_DIR="$root/dst2" check_destination_mounted >/dev/null 2>&1 || true
  compute_target_names
  [[ "${TARGET_NAMES[0]}" == src ]] || return 1
  SOURCE_DIRS=("$root/a/Project" "$root/b/Project" "$root/c/Other")
  mkdir -p "${SOURCE_DIRS[@]}"
  compute_target_names
  [[ "${TARGET_NAMES[0]}" == a__Project && "${TARGET_NAMES[1]}" == b__Project && "${TARGET_NAMES[2]}" == Other ]] || return 1
  [[ "$(rsync_flags_for_fstype ext4)" == '-a' ]] || return 1
  [[ "$(rsync_flags_for_fstype exfat)" == '-rt --modify-window=2' ]] || return 1
  [[ "$(rsync_flags_for_fstype vfat)" == *'--max-size=4294967295' ]] || return 1
}
run_test 'safety/path contract: recursion guard, writable-destination flow, collision naming and filesystem flags' safety_and_path_contract_test

lock_contract_test() {
  local root="$TMP_DIR/lock" lock="$TMP_DIR/lock/backup.lock" pid
  rm -rf "$root"; mkdir -p "$root"; LOCK_FILE="$lock"
  ( acquire_lock; sleep 2; release_lock ) &
  pid=$!
  sleep 0.1
  acquire_lock && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; return 1; }
  wait "$pid"
  acquire_lock || return 1
  release_lock
}
run_test 'execution-lock contract: concurrent backup is rejected and lock can be acquired again after release' lock_contract_test

lock_keeps_stderr_test() {
  # Regression: "exec {fd}>file 2>/dev/null" silently redirected stderr for the
  # rest of the session, hiding every later "read -p" prompt.
  local root="$TMP_DIR/lock-stderr" err="$TMP_DIR/lock-stderr/err" pid
  rm -rf "$root"; mkdir -p "$root"; LOCK_FILE="$root/backup.lock"
  { acquire_lock; release_lock; echo after-release >&2; } 2>"$err"
  [[ "$(<"$err")" == after-release ]] || return 1
  ( acquire_lock; sleep 1; release_lock ) &
  pid=$!
  sleep 0.1
  { acquire_lock; echo after-busy >&2; } 2>"$err"
  wait "$pid"
  [[ "$(<"$err")" == after-busy ]]
}
run_test 'execution-lock contract: acquiring/releasing the lock never redirects stderr (prompts stay visible)' lock_keeps_stderr_test

cron_contract_test() {
  local state="$TMP_DIR/crontab" bin="$TMP_DIR/cron-bin" out
  rm -rf "$bin"; mkdir -p "$bin"
  cat > "$bin/crontab" <<'EOS'
#!/usr/bin/env bash
state="${FAKE_CRONTAB_STATE:?}"
if [[ "$1" == "-l" ]]; then cat "$state"; exit 0; fi
tmp="${state}.new"
cat >"$tmp" && mv -f -- "$tmp" "$state"
EOS
  chmod +x "$bin/crontab"
  printf '%s\n' '0 9 * * * "/tmp/other.sh" --auto' '0 7 * * * "/tmp/simple-backup.sh" --auto' > "$state"
  SCRIPT_PATH='/tmp/My%Script/simple-backup.sh'; LOG_DIR='/tmp/log%dir'
  out="$(build_cron_line 7 2)" || return 1
  [[ "$out" == '0 7 * * 2 "/tmp/My\%Script/simple-backup.sh" --auto >> "/tmp/log\%dir/cron.log" 2>&1' ]] || return 1
  export PATH="$bin:$PATH" FAKE_CRONTAB_STATE="$state" SCRIPT_PATH='/tmp/simple-backup.sh'
  (crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH" || true) | crontab - || return 1
  grep -qF '/tmp/other.sh' "$state" || return 1
  ! grep -qF '/tmp/simple-backup.sh' "$state" || return 1
}
run_test 'cron contract: percent escaping and removal preserves unrelated crontab entries' cron_contract_test

fake_crontab_bin() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/crontab" <<'EOS'
#!/usr/bin/env bash
state="${FAKE_CRONTAB_STATE:?}"
if [[ "$1" == "-l" ]]; then cat "$state"; exit 0; fi
tmp="${state}.new"; cat >"$tmp" && mv -f -- "$tmp" "$state"
EOS
  chmod +x "$bin/crontab"
}

# Regression: cron_entry/cron_without_entry (not a hand-rolled grep) must match
# a script path containing "%", which is stored escaped as "\%" in the crontab.
cron_percent_path_test() {
  local bin="$TMP_DIR/cron-percent-bin" state="$TMP_DIR/cron-percent-state" found
  rm -rf "$bin"; mkdir -p "$bin"
  fake_crontab_bin "$bin"
  SCRIPT_PATH='/home/user/scripts/100% backup/simple-backup.sh'
  printf '%s\n' '0 9 * * * "/tmp/other.sh" --auto' "$(build_cron_line 3)" > "$state"
  export PATH="$bin:$PATH" FAKE_CRONTAB_STATE="$state"
  found="$(cron_entry)"
  assert_contains "$found" '100\%' || return 1
  [[ "$(printf '%s\n' "$found" | wc -l)" -eq 1 ]] || return 1
  cron_without_entry | crontab -
  grep -qF '/tmp/other.sh' "$state" || return 1
  ! grep -q '100' "$state" || return 1
}
run_test 'cron contract: a script path containing "%" is matched and removed correctly' cron_percent_path_test

# Regression: a commented-out crontab line that merely mentions the script
# path must never be treated as the active scheduled task.
cron_comment_line_test() {
  local bin="$TMP_DIR/cron-comment-bin" state="$TMP_DIR/cron-comment-state" found
  rm -rf "$bin"; mkdir -p "$bin"
  fake_crontab_bin "$bin"
  SCRIPT_PATH='/home/user/simple-backup.sh'
  printf '%s\n' \
    "# 0 3 * * * \"$SCRIPT_PATH\" --auto (disabled, see issue #12)" \
    "$(build_cron_line 4)" \
    '* * * * * /otro/trabajo.sh' \
    > "$state"
  export PATH="$bin:$PATH" FAKE_CRONTAB_STATE="$state"
  found="$(cron_entry)"
  [[ "$(printf '%s\n' "$found" | wc -l)" -eq 1 ]] || return 1
  assert_not_contains "$found" '#' || return 1
  cron_without_entry | crontab -
  grep -qF 'disabled, see issue #12' "$state" || return 1
  grep -qF '/otro/trabajo.sh' "$state" || return 1
  ! grep -q '^0 4' "$state" || return 1
}
run_test 'cron contract: a commented-out line mentioning the script path is never treated as the active task' cron_comment_line_test

timeshift_contract_test() {
  local calls="$TMP_DIR/timeshift.calls" bin="$TMP_DIR/timeshift-bin" out rc
  rm -rf "$bin"; mkdir -p "$bin"; : > "$calls"
  cat > "$bin/sudo" <<'EOS'
#!/usr/bin/env bash
exec "$@"
EOS
  cat > "$bin/timeshift" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TS_CALLS:?}"
if [[ "$1" == --list ]]; then
  printf '%s\n' 'Not enough disk space'
fi
EOS
  chmod +x "$bin/timeshift" "$bin/sudo"
  export TS_CALLS="$calls" PATH="$bin:$PATH"
  APP_LANG=en; out="$(ui timeshift_comment '2026-09-10 12:34')"; [[ "$out" == 'Automatic backup 2026-09-10 12:34' ]] || return 1
  APP_LANG=es; out="$(ui timeshift_comment '2026-09-10 12:34')"; [[ "$out" == 'Backup automático 2026-09-10 12:34' ]] || return 1
  APP_LANG=es; out="$(timeshift_check_space_low 2>&1)"; rc=$?; [[ $rc -eq 0 ]] || return 1
  assert_contains "$out" 'Timeshift indica que no hay espacio suficiente' || return 1
}
run_test 'Timeshift contract: command construction and localized snapshot result' timeshift_contract_test

backup_failure_contract_test() {
  local root="$TMP_DIR/failure" bin="$TMP_DIR/failure-bin" out rc
  rm -rf "$root" "$bin"; mkdir -p "$root/home" "$root/src" "$root/dst" "$bin"
  printf 'x\n' > "$root/src/file.txt"
  cat > "$bin/rsync" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
  cat > "$bin/notify-send" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NOTIFY_LOG:?}"
exit 99
EOS
  chmod +x "$bin/rsync" "$bin/notify-send"
  HOME="$root/home"; LOG_DIR="$root/logs"; LOG_FILE="$root/logs/a.log"; mkdir -p "$root/logs"
  HOME="$root/home" APP_LANG=en UI_LANGUAGE=en SOURCE_DIRS=("$root/src") EXCLUDES=() DEST_DIR="$root/dst" USE_DELETE=no
  same_filesystem() { return 1; }
  check_destination_mounted_auto() { return 0; }
  export NOTIFY_LOG="$root/notify.log" PATH="$bin:$PATH"; run_auto >"$root/out" 2>&1
  rc=$?
  [[ $rc -eq 1 ]] || return 1
  assert_contains "$(cat "$root/out")" 'errors: 1; warnings: 0' || return 1
  [[ -s "$root/logs/a.log" ]] || return 1
  [[ -s "$root/notify.log" ]] || return 1
}
run_test 'failure contract: genuine rsync error propagates to automatic mode while notify failure does not mask it' backup_failure_contract_test


interactive_menu_regression_test() {
  local home="$TMP_DIR/reg-home" fake="$TMP_DIR/reg-bin" cwd="$TMP_DIR/reg-cwd" out
  rm -rf "$home" "$fake" "$cwd"; mkdir -p "$home/.config/simple-backup" "$home/Docs" "$home/.local/share/simple-backup/logs" "$fake" "$cwd/Docs"
  make_fake_bin "$fake"
  printf 'SOURCE_DIRS=(%q )\nEXCLUDES=(.cache)\nDEST_DIR=\nUSE_DELETE=no\nUI_LANGUAGE=en\n' "$home/Docs" > "$home/.config/simple-backup/config.conf"
  # Exclusions: every add/duplicate/remove ends in a pause that swallows the blank line;
  # were it missing, those lines would surface as "Invalid option". A/R work in upper case.
  out="$(printf '1\n6\na\n*.bak\n\nA\n*.bak\n\nA\n*.log\n\nR\n1\n\nr\n0\n\nq\nq\nq\n' | HOME="$home" PATH="$fake:$PATH" TERM=dumb bash "$SCRIPT" 2>&1)" || return 1
  assert_contains "$out" 'Exclusion added: *.bak' || return 1
  assert_contains "$out" 'already in the exclusion list' || return 1
  assert_contains "$out" 'Exclusion added: *.log' || return 1
  assert_contains "$out" 'Exclusion removed: .cache' || return 1
  assert_not_contains "$out" 'Invalid option' || return 1
  ( source "$home/.config/simple-backup/config.conf"; [[ "${EXCLUDES[*]}" == '*.bak *.log' ]] ) || return 1
  # "0" cancels numbered lists; relative source/destination paths are rejected, nothing is created.
  out="$(cd "$cwd" && printf '1\n3\n0\n\n2\nDocs\n\n5\nBackups\n\nq\nq\n' | HOME="$home" PATH="$fake:$PATH" TERM=dumb bash "$SCRIPT" 2>&1)" || return 1
  assert_not_contains "$out" 'Invalid option, try again' || return 1
  (( $(grep -cF 'Enter a full path starting with / or ~' <<<"$out") == 2 )) || return 1
  [[ ! -e "$cwd/Backups" ]] || return 1
  grep -qF "SOURCE_DIRS=($home/Docs )" "$home/.config/simple-backup/config.conf" || return 1
  # Log number prompt: "0" cancels too.
  : > "$home/.local/share/simple-backup/logs/backup_20260101_000000_1.log"
  out="$(printf '5\n0\nq\n' | HOME="$home" PATH="$fake:$PATH" TERM=dumb bash "$SCRIPT" 2>&1)" || return 1
  assert_not_contains "$out" 'Number out of range' || return 1
}
run_test 'interactive regression: exclusion feedback + A/R, "0" cancels numbered prompts, relative paths rejected' interactive_menu_regression_test

interrupt_log_contract_test() {
  local root="$TMP_DIR/int" rc
  rm -rf "$root"; mkdir -p "$root"
  # Ctrl+C/TERM at a menu (no backup running) leaves no log behind...
  ( LOG_FILE="$root/menu.log"; APP_LANG=en; on_terminate INT 130 >/dev/null 2>&1 ); rc=$?
  [[ $rc -eq 130 && ! -e "$root/menu.log" ]] || return 1
  # ...while a run holding the lock records the interruption and frees the lock.
  ( LOG_FILE="$root/run.log"; LOCK_FILE="$root/lock"; APP_LANG=en; acquire_lock; on_terminate TERM 143 >/dev/null 2>&1 ); rc=$?
  [[ $rc -eq 143 ]] && grep -q 'interrupted (signal TERM)' "$root/run.log" || return 1
  flock -n "$root/lock" true
}
run_test 'interrupt contract: a menu interrupt leaves no log; an interrupted backup is logged and unlocked' interrupt_log_contract_test

folder_picker_locale_test() {
  local root="$TMP_DIR/picker" out
  rm -rf "$root"; mkdir -p "$root/bin"
  printf '#!/usr/bin/env bash\nprintf "LC_ALL=%%s LANGUAGE=%%s\\n" "$LC_ALL" "$LANGUAGE"\n' > "$root/bin/zenity"; chmod +x "$root/bin/zenity"
  # Under a C/POSIX locale the picker must still run (LC_ALL forced to UTF-8) instead of failing silently.
  out="$( export DISPLAY=:0 LANG=C PATH="$root/bin:$PATH"; unset LC_ALL LC_MESSAGES; APP_LANG=es; pick_folder_dialog title "$root" )" || return 1
  assert_contains "$out" 'LC_ALL=C.UTF-8 LANGUAGE=es' || return 1
}
run_test 'folder picker: runs under a C/POSIX locale with LANGUAGE matching the UI language' folder_picker_locale_test

# Regression: PAGER may carry arguments ("less -R"); only the first word is
# the command to look up. A genuinely missing pager still falls back to cat.
pager_with_arguments_test() {
  local bin="$TMP_DIR/pager-bin" f="$TMP_DIR/pager-file.txt" result rc
  rm -rf "$bin"; mkdir -p "$bin"
  printf 'contenido\n' > "$f"
  printf '#!/usr/bin/env bash\nprintf "args:%%s\\n" "$*"\ncat -- "${@: -1}"\n' > "$bin/mypager"
  chmod +x "$bin/mypager"
  export PATH="$bin:$PATH"
  result="$(PAGER='mypager -R --long-prompt' run_pager "$f")"; rc=$?
  [[ $rc -eq 0 ]] || return 1
  assert_contains "$result" 'args:-R --long-prompt' || return 1
  assert_contains "$result" 'contenido' || return 1
  result="$(PAGER='no-such-pager -X' run_pager "$f")"; rc=$?
  [[ $rc -eq 99 && "$result" == 'contenido' ]] || return 1
}
run_test 'pager contract: a PAGER with arguments (e.g. "less -R") is honored; a missing pager falls back to cat' pager_with_arguments_test

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
