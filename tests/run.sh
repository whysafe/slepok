#!/usr/bin/env bash
# Тесты slepok без внешних фреймворков: bash tests/run.sh
# Интеграционные тесты пропускаются, если нет rsync или flock;
# с SLEPOK_REQUIRE_ALL=1 (так в CI) пропуск считается провалом.
#
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2154
set -o nounset -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLEPOK="$ROOT/slepok"
PASSED=0
FAILED=0
SKIPPED=0
WORK=""

fail() { printf '      %s\n' "$*" >&2; return 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "ожидалось «$2», получено «$1»"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "нет «$2» в выводе:"$'\n'"$1"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "лишнее «$2» в выводе:"$'\n'"$1"; }
assert_missing() { [[ ! -e "$1" ]] || fail "не должно существовать: $1"; }
need() {
  local tool
  for tool in "$@"; do command -v "$tool" > /dev/null || return 77; done
}
inode() { stat -c %i -- "$1"; }

run_test() {
  local name="$1" rc
  WORK="$(mktemp -d)"
  ( set -o errexit; "$name" )
  rc=$?
  case $rc in
    0)  PASSED=$((PASSED + 1)); printf 'ok    %s\n' "$name" ;;
    77) SKIPPED=$((SKIPPED + 1)); printf 'skip  %s (нет rsync или flock)\n' "$name" ;;
    *)  FAILED=$((FAILED + 1)); printf 'FAIL  %s\n' "$name" ;;
  esac
  chmod -R u+w "$WORK" 2> /dev/null
  rm -rf "$WORK"
}

# Конфиг с источником $WORK/src и хранилищем $WORK/backup; доп. строки со stdin.
write_config() {
  mkdir -p "$WORK/src"
  { printf 'dest = %s\nsource = %s\n' "$WORK/backup" "$WORK/src"; cat; } > "$WORK/slepok.conf"
}
slepok() { "$SLEPOK" -c "$WORK/slepok.conf" "$@"; }
backup_at() { SLEPOK_NOW="$1" slepok -q backup; }
in_snapshot() { printf '%s\n' "$WORK/backup/$1$WORK/src/$2"; }

# Два снимка: в 10:00 и в 11:00, между ними один файл изменён, один удалён, один добавлен.
make_two_snapshots() {
  write_config <<'EOF'
keep_last = 10
exclude = *.tmp
EOF
  printf 'не меняется\n' > "$WORK/src/same.txt"
  printf 'v1\n' > "$WORK/src/changed.txt"
  printf 'скоро удалят\n' > "$WORK/src/removed.txt"
  printf 'мусор\n' > "$WORK/src/cache.tmp"
  backup_at "2026-01-01 10:00:00"
  printf 'version 2 longer\n' > "$WORK/src/changed.txt"
  rm "$WORK/src/removed.txt"
  printf 'новый\n' > "$WORK/src/new.txt"
  backup_at "2026-01-01 11:00:00"
}

daily_names() {  # $1 = первый день, $2 = сколько дней
  local i
  for (( i = 0; i < $2; i++ )); do date -d "$1 +$i day" +%Y-%m-%d_030000; done
}

kept() { plan_retention "$@" | awk -F '\t' '$1 == "keep" { print $2 }' | paste -sd ' ' -; }

# --- конфиг ---

test_config_parsing() {
  write_config <<'EOF'
# комментарий
   keep_daily   =  3
exclude = *.tmp
exclude = node_modules/
pre_hook = echo "a = b"
keep_weekly = 08
EOF
  source "$SLEPOK"
  load_config "$WORK/slepok.conf"
  assert_eq "$KEEP_DAILY" 3
  assert_eq "$KEEP_WEEKLY" 8
  assert_eq "${#EXCLUDES[@]}" 2
  assert_eq "${EXCLUDES[1]}" "node_modules/"
  assert_eq "$PRE_HOOK" 'echo "a = b"'
  assert_eq "$DEST" "$WORK/backup"
}

expect_config_error() {
  local out
  if out="$(slepok list 2>&1)"; then fail "конфиг должен быть отклонён"; fi
  assert_contains "$out" "$1"
}

test_config_errors() {
  write_config <<< 'keep_dayly = 3'
  expect_config_error "неизвестный ключ «keep_dayly»"
  write_config <<< 'keep_daily = много'
  expect_config_error "целым числом"
  write_config <<< 'просто строка'
  expect_config_error "ключ = значение"
  printf 'dest = backup\nsource = /etc\n' > "$WORK/slepok.conf"
  expect_config_error "абсолютным путём"
  printf 'dest = /mnt/b\n' > "$WORK/slepok.conf"
  expect_config_error "нет ни одной строки source"
}

# --- ротация ---

test_retention_daily_weekly_monthly() {
  source "$SLEPOK"
  KEEP_LAST=0 KEEP_DAILY=3 KEEP_WEEKLY=2 KEEP_MONTHLY=2 KEEP_YEARLY=0
  local -a names
  mapfile -t names < <(daily_names 2026-01-01 90)  # по 31 марта включительно
  # дни: 31, 30, 29 марта; недели: W14 -> 31.03 и W13 -> 29.03 уже взяты;
  # месяцы: март -> 31.03, февраль -> 28.02
  assert_eq "$(kept "${names[@]}")" "2026-02-28_030000 2026-03-29_030000 2026-03-30_030000 2026-03-31_030000"
}

test_retention_weeks_use_iso_calendar() {
  source "$SLEPOK"
  KEEP_LAST=0 KEEP_DAILY=0 KEEP_WEEKLY=3 KEEP_MONTHLY=0 KEEP_YEARLY=0
  local -a names
  mapfile -t names < <(daily_names 2025-12-15 21)  # по 4 января 2026
  # 2026-01-01 четверг, ISO-неделя W01 начинается 29 декабря 2025
  assert_eq "$(kept "${names[@]}")" "2025-12-21_030000 2025-12-28_030000 2026-01-04_030000"
}

test_retention_same_day_and_keep_last() {
  source "$SLEPOK"
  local -a names=(2026-05-01_010000 2026-05-01_020000 2026-05-01_030000)
  KEEP_LAST=0 KEEP_DAILY=1 KEEP_WEEKLY=0 KEEP_MONTHLY=0 KEEP_YEARLY=0
  assert_eq "$(kept "${names[@]}")" "2026-05-01_030000"
  KEEP_LAST=2
  assert_eq "$(kept "${names[@]}")" "2026-05-01_020000 2026-05-01_030000"
}

test_retention_yearly_and_reasons() {
  source "$SLEPOK"
  KEEP_LAST=0 KEEP_DAILY=0 KEEP_WEEKLY=0 KEEP_MONTHLY=1 KEEP_YEARLY=2
  local plan
  plan="$(plan_retention 2023-06-01_120000 2024-06-01_120000 2025-06-01_120000 2026-06-01_120000)"
  assert_contains "$plan" $'drop\t2023-06-01_120000'
  assert_contains "$plan" $'drop\t2024-06-01_120000'
  assert_contains "$plan" $'keep\t2025-06-01_120000\tгод'
  assert_contains "$plan" $'keep\t2026-06-01_120000\tмесяц, год'
}

test_retention_refuses_empty_policy() {
  source "$SLEPOK"
  KEEP_LAST=0 KEEP_DAILY=0 KEEP_WEEKLY=0 KEEP_MONTHLY=0 KEEP_YEARLY=0
  local out
  if out="$( (plan_retention 2026-01-01_000000) 2>&1)"; then fail "пустая политика должна быть ошибкой"; fi
  assert_contains "$out" "удалили бы все снимки"
}

test_resolve_snapshot() {
  source "$SLEPOK"
  DEST="$WORK/backup"
  mkdir -p "$DEST"/{2026-01-01_100000,2026-01-02_100000,2026-01-02_200000,not-a-snapshot}
  assert_eq "$(resolve_snapshot latest)" "2026-01-02_200000"
  assert_eq "$(resolve_snapshot previous)" "2026-01-02_100000"
  assert_eq "$(resolve_snapshot 2026-01-01)" "2026-01-01_100000"
  local out
  if out="$( (resolve_snapshot 2026-01-02) 2>&1)"; then fail "префикс неоднозначен"; fi
  assert_contains "$out" "к нескольким снимкам"
}

test_human_size() {
  source "$SLEPOK"
  assert_eq "$(human_size 512)" "512 B"
  assert_eq "$(human_size 1536)" "1.5 KiB"
  assert_eq "$(human_size $((3 * 1024 * 1024 * 1024)))" "3.0 GiB"
}

# --- установка ---

test_install_into_destdir() {
  DESTDIR="$WORK/root" PREFIX=/opt/slepok bash "$ROOT/install.sh" > /dev/null
  [[ -x "$WORK/root/opt/slepok/bin/slepok" ]] || fail "нет исполняемого файла"
  [[ -f "$WORK/root/etc/slepok/main.conf" ]] || fail "нет конфига"
  [[ -f "$WORK/root/etc/systemd/system/slepok@.timer" ]] || fail "нет таймера"
  assert_contains "$(cat "$WORK/root/etc/systemd/system/slepok@.service")" "ExecStart=/opt/slepok/bin/slepok -c /etc/slepok/%i.conf backup"
  printf 'dest = /x\n' > "$WORK/root/etc/slepok/main.conf"
  DESTDIR="$WORK/root" PREFIX=/opt/slepok bash "$ROOT/install.sh" > /dev/null
  assert_eq "$(cat "$WORK/root/etc/slepok/main.conf")" "dest = /x"
  DESTDIR="$WORK/root" PREFIX=/opt/slepok bash "$ROOT/install.sh" --uninstall > /dev/null
  assert_missing "$WORK/root/opt/slepok/bin/slepok"
}

# --- копирование (нужны rsync и flock) ---

test_backup_uses_hard_links() {
  need rsync flock || return 77
  make_two_snapshots
  local a=2026-01-01_100000 b=2026-01-01_110000
  assert_eq "$(inode "$(in_snapshot $a same.txt)")" "$(inode "$(in_snapshot $b same.txt)")"
  [[ "$(inode "$(in_snapshot $a changed.txt)")" != "$(inode "$(in_snapshot $b changed.txt)")" ]] ||
    fail "изменённый файл не должен быть жёсткой ссылкой"
  assert_eq "$(cat "$(in_snapshot $a changed.txt)")" "v1"
  assert_eq "$(cat "$(in_snapshot $b changed.txt)")" "version 2 longer"
  assert_missing "$(in_snapshot $b removed.txt)"
  assert_missing "$(in_snapshot $a cache.tmp)"
  assert_eq "$(readlink "$WORK/backup/latest")" "$b"
  assert_eq "$(find "$WORK/backup" -maxdepth 1 -name '.inprogress-*' | wc -l)" 0
}

test_list_diff_history_restore() {
  need rsync flock || return 77
  make_two_snapshots
  local out

  out="$(slepok list)"
  assert_contains "$out" "2026-01-01_100000"
  assert_contains "$out" "<- latest"
  assert_contains "$out" "Снимков: 2"

  out="$(slepok diff)"
  assert_contains "$out" "+ $WORK/src/new.txt"
  assert_contains "$out" "~ $WORK/src/changed.txt"
  assert_contains "$out" "- $WORK/src/removed.txt"
  assert_not_contains "$out" "same.txt"
  assert_contains "$out" "Добавлено: 1, изменено: 1, удалено: 1"

  out="$(slepok history "$WORK/src/changed.txt")"
  assert_contains "$out" "Версий: 2"
  out="$(slepok history "$WORK/src/same.txt")"
  assert_contains "$out" "Версий: 1"
  out="$(slepok history "$WORK/src/removed.txt")"
  assert_contains "$out" "2026-01-01_110000  удалён"

  slepok -q restore 2026-01-01_10 "$WORK/src/changed.txt" "$WORK/out"
  assert_eq "$(cat "$WORK/out/changed.txt")" "v1"
  slepok -q restore latest "$WORK/src" "$WORK/out-dir"
  assert_eq "$(cat "$WORK/out-dir/src/new.txt")" "новый"
}

test_backup_prunes_old_snapshots() {
  need rsync flock || return 77
  write_config <<'EOF'
keep_daily = 2
keep_weekly = 0
keep_monthly = 0
EOF
  printf 'x\n' > "$WORK/src/file"
  backup_at "2026-03-01 09:00"
  backup_at "2026-03-02 09:00"
  backup_at "2026-03-02 18:00"
  backup_at "2026-03-03 09:00"
  assert_eq "$(slepok list --names | paste -sd ' ' -)" "2026-03-02_180000 2026-03-03_090000"
}

test_dry_run_changes_nothing() {
  need rsync flock || return 77
  write_config <<< 'keep_last = 5'
  printf 'x\n' > "$WORK/src/file"
  SLEPOK_NOW="2026-03-01 09:00" slepok -n backup > /dev/null
  assert_eq "$(slepok list --names)" ""
  backup_at "2026-03-01 09:00"
  backup_at "2026-03-01 10:00"
  printf 'keep_daily = 0\nkeep_weekly = 0\nkeep_monthly = 0\nkeep_last = 1\n' >> "$WORK/slepok.conf"
  local out
  out="$(slepok prune --dry-run)"
  assert_contains "$out" "удалить   2026-03-01_090000  (пробный запуск)"
  [[ -d "$WORK/backup/2026-03-01_090000" ]] || fail "пробный prune удалил снимок"
}

test_failed_rsync_leaves_no_snapshot() {
  need rsync flock || return 77
  write_config <<EOF
source = $WORK/does-not-exist
on_error = echo "\$SLEPOK_EXIT_CODE" > "$WORK/error.flag"
EOF
  local out
  if out="$(SLEPOK_NOW="2026-03-01 09:00" slepok backup 2>&1)"; then fail "backup должен упасть"; fi
  assert_contains "$out" "rsync завершился с кодом"
  assert_eq "$(slepok list --names)" ""
  assert_eq "$(find "$WORK/backup" -maxdepth 1 -name '.inprogress-*' | wc -l)" 0
  assert_eq "$(cat "$WORK/error.flag")" 1
}

test_pre_hook_failure_cancels_backup() {
  need rsync flock || return 77
  write_config <<'EOF'
pre_hook = echo "дамп базы не удался" >&2; exit 3
EOF
  local out
  if out="$(slepok backup 2>&1)"; then fail "backup должен упасть"; fi
  assert_contains "$out" "pre_hook завершился с кодом 3"
  assert_eq "$(slepok list --names)" ""
}

test_lock_blocks_second_run() {
  need rsync flock || return 77
  write_config < /dev/null
  mkdir -p "$WORK/backup"
  exec 8> "$WORK/backup/.lock"
  flock -n 8
  local out
  if out="$(slepok backup 2>&1)"; then fail "второй запуск должен быть заблокирован"; fi
  assert_contains "$out" "другой запуск slepok"
}

test_check_reports_stale_backup() {
  need rsync flock || return 77
  write_config <<< 'max_age_hours = 24'
  backup_at "2026-03-01 09:00"
  local out
  out="$(SLEPOK_NOW="2026-03-01 20:00" slepok check)"
  assert_contains "$out" "Всё в порядке"
  if out="$(SLEPOK_NOW="2026-03-03 09:00" slepok check)"; then fail "check должен сообщить о старой копии"; fi
  assert_contains "$out" "48 ч назад"
}

tests=(
  test_config_parsing
  test_config_errors
  test_retention_daily_weekly_monthly
  test_retention_weeks_use_iso_calendar
  test_retention_same_day_and_keep_last
  test_retention_yearly_and_reasons
  test_retention_refuses_empty_policy
  test_resolve_snapshot
  test_human_size
  test_install_into_destdir
  test_backup_uses_hard_links
  test_list_diff_history_restore
  test_backup_prunes_old_snapshots
  test_dry_run_changes_nothing
  test_failed_rsync_leaves_no_snapshot
  test_pre_hook_failure_cancels_backup
  test_lock_blocks_second_run
  test_check_reports_stale_backup
)
for t in "${tests[@]}"; do run_test "$t"; done

printf '\nпройдено: %d, провалено: %d, пропущено: %d\n' "$PASSED" "$FAILED" "$SKIPPED"
if (( FAILED > 0 )); then exit 1; fi
if (( SKIPPED > 0 )) && [[ "${SLEPOK_REQUIRE_ALL:-0}" == 1 ]]; then exit 1; fi
