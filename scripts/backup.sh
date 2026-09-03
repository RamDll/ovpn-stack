#!/usr/bin/env bash
#
# Бэкап / восстановление рантайм-данных ovpn-stack.
#
# Бэкапится то, чего НЕТ в git и без чего стек не восстановить:
#   data/                          — PKI (CA + приватные ключи!), ccd, stat/traffic.db
#   .env                           — секреты (Basic Auth)
#   docker-compose.override.yaml   — если есть (кастомный порт / host-TLS)
#   nginx/ssl/                      — текущий TLS-серт (чтобы nginx стартовал до renew)
#
# Использование:
#   sudo scripts/backup.sh                      # → ./backups/ovpn-stack-<ts>.tar.gz
#   sudo scripts/backup.sh --out /srv/bak --keep 7
#   sudo scripts/backup.sh --restore <file.tar.gz> [--yes]
#
# Для cron (root):
#   17 4 * * *  /opt/ovpn-stack/scripts/backup.sh --out /var/backups/ovpn --keep 14

set -Eeuo pipefail

# корень репозитория: рядом со скриптом (scripts/backup.sh), иначе вверх от cwd,
# иначе --dir
find_repo() {
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || true)"
  [[ -f "$d/docker-compose.yaml" && -f "$d/.env.example" ]] && { printf '%s' "$d"; return; }
  d="$PWD"
  while [[ "$d" != / ]]; do
    [[ -f "$d/docker-compose.yaml" && -f "$d/.env.example" ]] && { printf '%s' "$d"; return; }
    d="$(dirname "$d")"
  done
  return 1
}

REPO=""
OUT=""
KEEP=0
RESTORE=""
ASSUME_YES=0

ITEMS=(data .env docker-compose.override.yaml nginx/ssl)

msg()  { printf '%s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die()  { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)     OUT="${2:?}"; shift 2 ;;
    --keep)    KEEP="${2:?}"; shift 2 ;;
    --restore) RESTORE="${2:?}"; shift 2 ;;
    --dir)     REPO="${2:?}"; shift 2 ;;
    --yes)     ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         die "неизвестный флаг: $1" ;;
  esac
done

[[ -n "$REPO" ]] || REPO="$(find_repo || true)"
[[ -n "$REPO" && -f "$REPO/docker-compose.yaml" ]] || die "не нашёл каталог стека — запусти из него или задай --dir"
[[ -n "$OUT" ]] || OUT="$REPO/backups"
[[ $EUID -eq 0 ]] || die "нужен root (в data/ есть файлы root:0600) — запусти через sudo"
cd "$REPO"
command -v docker >/dev/null || die "нет docker"

# ---------------------------------------------------------------------------
if [[ -n "$RESTORE" ]]; then
  [[ -f "$RESTORE" ]] || die "файл не найден: $RESTORE"
  tar -tzf "$RESTORE" >/dev/null 2>&1 || die "не читается как .tar.gz: $RESTORE"
  msg "Восстановление из $RESTORE в $REPO"
  tar -tzf "$RESTORE" | sed 's/^/  /' | head -20
  if (( ! ASSUME_YES )); then
    read -r -p "Стек будет остановлен, файлы перезаписаны. Продолжить? [y/N] " a || true
    [[ "$a" =~ ^[Yy]$ ]] || die "отменено"
  fi
  docker compose down 2>/dev/null || true
  tar -xzf "$RESTORE" -C "$REPO"
  msg "Файлы распакованы. Поднимаю стек…"
  docker compose up -d --wait --wait-timeout 300
  docker compose ps
  warn "проверь: панель отвечает, клиенты на месте; для домена/IP-серта — при"
  warn "необходимости перевыпусти TLS (acme.sh)."
  exit 0
fi

# ---------------------------------------------------------------------------
mkdir -p "$OUT"
TS="$(date +%Y%m%d-%H%M%S)"
DEST="$OUT/ovpn-stack-$TS.tar.gz"

present=()
for i in "${ITEMS[@]}"; do
  [[ -e "$i" ]] && present+=("$i")
done
[[ ${#present[@]} -gt 0 ]] || die "нечего бэкапить (нет data/ .env … — стек разворачивали?)"

tar -czf "$DEST" --numeric-owner -C "$REPO" "${present[@]}"
chmod 600 "$DEST"
msg "Бэкап: $DEST  ($(du -h "$DEST" | cut -f1))"
tar -tzf "$DEST" | sed 's/^/  /' | grep -E '/$|\.(env|yaml|db|key|crt|pem)$' | head -15

# ротация
if (( KEEP > 0 )); then
  # имена вида ovpn-stack-YYYYMMDD-HHMMSS.tar.gz — спецсимволов нет, ls -1t ок
  # shellcheck disable=SC2012
  mapfile -t old < <(ls -1t "$OUT"/ovpn-stack-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)))
  if [[ ${#old[@]} -gt 0 ]]; then
    rm -f "${old[@]}"
    msg "Удалено старых бэкапов: ${#old[@]} (оставлено $KEEP)"
  fi
fi
