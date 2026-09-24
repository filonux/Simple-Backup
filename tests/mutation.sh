#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="${PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

KILLED=0
SURVIVED=0
ERRORS=0
TOTAL=10

mutate() {
  local name="$1" file="$2" mode="$3" filter="$4" dir="$WORK/$1" rc
  cp -a "$ROOT_DIR" "$dir"
  python3 - "$dir/$file" "$mode" <<'PY' || { printf 'mutation runner error (stale target): %s\n' "$name" >&2; ERRORS=$((ERRORS + 1)); return 0; }
from pathlib import Path
import sys

p = Path(sys.argv[1])
mode = sys.argv[2]
text = p.read_text()
mutations = {
    'toggle-language': (
        'toggle_app_language() {\n  if [[ "${APP_LANG:-en}" == "es" ]]; then',
        'toggle_app_language() {\n  if [[ "${APP_LANG:-en}" == "en" ]]; then',
    ),
    'spanish-menu': (
        "[menu_exit]='  0) Salir'",
        "[menu_exit]='  0) BROKEN'",
    ),
    'exclude-contract': (
        'for e in "${EXCLUDES[@]}"; do RSYNC_ARGS+=(--exclude="$e"); done',
        'for e in "${EXCLUDES[@]}"; do :; done',
    ),
    'delete-contract': (
        '[[ "$USE_DELETE" == "yes" ]] && RSYNC_ARGS+=(--delete)',
        ':',
    ),
    'rsync-24-classification': (
        '24) echo "warn"',
        '24) echo "error"',
    ),
    'rsync-23-conservative-classification': (
        '[[ -n "$output_file" ]] && rsync_23_metadata_warning "$output_file" && echo "warn" || echo "error"',
        'echo "warn"',
    ),
    'relative-path-guard': (
        'is_absolute_path() { [[ "$1" == /* ]]; }',
        'is_absolute_path() { true; }',
    ),
    'interrupt-log-guard': (
        '[[ -n "$was_running" ]] && declare -F log >/dev/null',
        'declare -F log >/dev/null',
    ),
    'picker-locale-env': (
        '  env LANGUAGE="${APP_LANG:-en}" "${lc_fix[@]}" zenity',
        '  LANGUAGE="${APP_LANG:-en}" "${lc_fix[@]}" zenity',
    ),
    'placeholder-contract': (
        "[auto_summary]='Automatic backup: errors: %s; warnings: %s. Log: %s'",
        "[auto_summary]='Automatic backup: errors: %d; warnings: %s. Log: %s'",
    ),
}
old, new = mutations[mode]
count = text.count(old)
if count != 1:
    raise SystemExit(f'expected exactly one mutation target, found {count}: {mode}')
p.write_text(text.replace(old, new, 1))
PY

  timeout 20 env PROJECT_ROOT="$dir" TEST_FILTER="$filter" bash "$dir/tests/test.sh" >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0)
      printf 'mutation survived: %s\n' "$name" >&2
      SURVIVED=$((SURVIVED + 1))
      ;;
    124|125|126|127)
      printf 'mutation runner error (%s): %s\n' "$rc" "$name" >&2
      ERRORS=$((ERRORS + 1))
      ;;
    *)
      printf 'killed - %s\n' "$name"
      KILLED=$((KILLED + 1))
      ;;
  esac
}

mutate 'toggle-language' script/simple-backup.sh toggle-language 'interactive language switch'
mutate 'spanish-menu' script/simple-backup.sh spanish-menu 'real TTY UI'
mutate 'exclude-contract' script/simple-backup.sh exclude-contract 'rsync argument contract'
mutate 'delete-contract' script/simple-backup.sh delete-contract 'rsync argument contract'
mutate 'rsync-24-classification' script/simple-backup.sh rsync-24-classification 'rsync exit contract'
mutate 'rsync-23-conservative-classification' script/simple-backup.sh rsync-23-conservative-classification 'rsync exit contract'
mutate 'placeholder-contract' script/simple-backup.sh placeholder-contract 'catalog quality'
mutate 'relative-path-guard' script/simple-backup.sh relative-path-guard 'interactive regression'
mutate 'interrupt-log-guard' script/simple-backup.sh interrupt-log-guard 'interrupt contract'
mutate 'picker-locale-env' script/simple-backup.sh picker-locale-env 'folder picker'

score=$(( KILLED * 100 / TOTAL ))
printf 'Mutation score: %d/%d targeted regressions detected (%d%%)\n' "$KILLED" "$TOTAL" "$score"
(( SURVIVED == 0 && ERRORS == 0 && KILLED == TOTAL ))
