#!/usr/bin/env bash
# Установка slepok: sudo ./install.sh   Удаление: sudo ./install.sh --uninstall
# PREFIX меняет каталог установки, DESTDIR нужен для сборки пакетов и тестов.
set -o errexit -o nounset -o pipefail

PREFIX="${PREFIX:-/usr/local}"
DESTDIR="${DESTDIR:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN_DIR="$DESTDIR$PREFIX/bin"
COMPLETION_DIR="$DESTDIR$PREFIX/share/bash-completion/completions"
UNIT_DIR="$DESTDIR/etc/systemd/system"
CONFIG_DIR="$DESTDIR/etc/slepok"

reload_systemd() {
  if [[ -z "$DESTDIR" ]] && command -v systemctl > /dev/null && [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload
  fi
}

uninstall() {
  rm -f "$BIN_DIR/slepok" "$COMPLETION_DIR/slepok" \
        "$UNIT_DIR/slepok@.service" "$UNIT_DIR/slepok@.timer"
  reload_systemd
  echo "slepok удалён. Конфиги в $CONFIG_DIR и сами снимки не тронуты."
}

install_all() {
  install -Dm755 "$HERE/slepok" "$BIN_DIR/slepok"
  install -Dm644 "$HERE/completions/slepok.bash" "$COMPLETION_DIR/slepok"
  install -d "$UNIT_DIR"
  sed "s|/usr/local/bin/slepok|$PREFIX/bin/slepok|" "$HERE/systemd/slepok@.service" > "$UNIT_DIR/slepok@.service"
  install -m644 "$HERE/systemd/slepok@.timer" "$UNIT_DIR/slepok@.timer"
  chmod 644 "$UNIT_DIR/slepok@.service"

  install -d -m755 "$CONFIG_DIR"
  if [[ ! -e "$CONFIG_DIR/main.conf" ]]; then
    install -m600 "$HERE/slepok.conf.example" "$CONFIG_DIR/main.conf"
    echo "Создан $CONFIG_DIR/main.conf: впишите dest и source."
  fi
  reload_systemd

  cat <<MSG
slepok установлен в $PREFIX/bin/slepok
Дальше:
  sudoedit /etc/slepok/main.conf
  sudo slepok check
  sudo systemctl enable --now slepok@main.timer
MSG
}

case "${1:-}" in
  "") install_all ;;
  --uninstall) uninstall ;;
  *) echo "использование: $0 [--uninstall]" >&2; exit 2 ;;
esac
