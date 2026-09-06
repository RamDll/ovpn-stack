#!/usr/bin/env bash
#
# setup.sh — единственная точка входа установщика (install/README.md).
# Запускается на домашнем ПК (Linux / macOS / WSL) с root-паролем свежего
# VPS под рукой. Ведёт сервер от голого root-пароля до рабочего VLESS
# Reality и/или OpenVPN, вызывая bootstrap.sh и install-vpn.sh на сервере
# по одной подкоманде за раз.
#
# Использование (полный список флагов — ./setup.sh --help):
#   ./setup.sh [--vless|--openvpn|--all] [--ip <addr>] [--user <name>] \
#              [--ssh-port <p>] [--sni <domain>] [--staging]
#
# Секреты нигде не передаются аргументами (см. `ps`) — root-пароль и пароль
# пользователя всегда через скрытый ввод/stdin.

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE_ROOT="$SCRIPT_DIR/.state"
REPO_URL="https://github.com/RamDll/ovpn-stack.git"
GIT_BRANCH="${OVPN_STACK_BRANCH:-master}"

# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_RST=$'\e[0m'
else
  C_RED=; C_GRN=; C_YEL=; C_BLU=; C_RST=
fi
step() { printf '\n%s==>%s %s\n' "$C_BLU" "$C_RST" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%sОШИБКА:%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<EOF
Установщик ovpn-stack — см. install/README.md

Использование:
  $0 [--vless|--openvpn|--all] [--ip <addr>] [--user <name>] \\
     [--ssh-port <port>] [--sni <domain>] [--staging] [--no-key-copy]

Флаги:
  --vless          режим: только VLESS Reality
  --openvpn        режим: только OpenVPN
  --all            режим: оба
  --ip <addr>      IP сервера (иначе спросит)
  --user <name>    имя sudo-пользователя (иначе спросит, дефолт — whoami)
  --ssh-port <p>   порт SSH после хардненинга (иначе случайный 20000-60000)
  --sni <domain>   домен для REALITY SNI (иначе спросит; Enter в промпте —
                   случайный из встроенного пула; при повторном прогоне
                   берётся из state.env)
  --staging        ACME staging Let's Encrypt — серт НЕ доверенный браузером,
                   но высокие лимиты: для повторных тест-прогонов установщика
  --no-key-copy    не копировать приватный ключ в ~/.ssh (по умолчанию —
                   копирует в ~/.ssh/id_ed25519, если слот свободен, иначе
                   в ~/.ssh/ovpn-stack-<ip>; ~/.ssh/config не трогается)
  -h, --help       эта справка

root-пароль всегда вводится интерактивно; пароль пользователя — тоже
(Enter — сгенерировать). Секреты нельзя передать флагом (не в git/ps).
EOF
}

# ---------------------------------------------------------------------------
# аргументы
# ---------------------------------------------------------------------------
MODE=""
IP=""
SSH_USER_ARG=""
SSH_PORT_ARG=""
SNI_ARG=""
ACME_STAGING=""
NO_KEY_COPY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vless)    MODE="vless" ;;
    --openvpn)  MODE="openvpn" ;;
    --all)      MODE="all" ;;
    --ip)       IP="${2:?}"; shift ;;
    --user)     SSH_USER_ARG="${2:?}"; shift ;;
    --ssh-port) SSH_PORT_ARG="${2:?}"; shift ;;
    --sni)      SNI_ARG="${2:?}"; shift ;;
    --staging)  ACME_STAGING="staging" ;;
    --no-key-copy) NO_KEY_COPY=1 ;;
    -h|--help)  usage; exit 0 ;;
    *) die "неизвестный флаг: $1 (см. --help)" ;;
  esac
  shift
done

for c in ssh scp ssh-keygen ssh-keyscan awk sed mktemp openssl; do
  command -v "$c" >/dev/null 2>&1 || die "нужен '$c' в PATH — на Linux/macOS/WSL он обычно уже есть"
done

# необязательные удобства локальной машины (не сервера — принцип 5 про
# curl|sh здесь не при чём). Ставим сами через пакетный менеджер, который
# найдём, и только с явного согласия — это чужая машина пользователя.
install_optional_dep() {
  local bin="$1" pkg="$2" purpose="$3"
  command -v "$bin" >/dev/null 2>&1 && return 0
  [[ -t 0 ]] || { warn "'$bin' не найден ($purpose) — неинтерактивный запуск, пропускаю установку"; return 1; }

  local pm=""
  if command -v apt-get >/dev/null 2>&1; then pm="apt-get"
  elif command -v pacman >/dev/null 2>&1; then pm="pacman"
  elif command -v dnf >/dev/null 2>&1; then pm="dnf"
  elif command -v brew >/dev/null 2>&1; then pm="brew"
  fi
  if [[ -z "$pm" ]]; then
    warn "'$bin' не найден ($purpose), не смог определить пакетный менеджер — поставь вручную"
    return 1
  fi

  warn "'$bin' не найден ($purpose)"
  read -rp "  Поставить пакет '$pkg' через $pm? (нужен sudo) [y/N]: " reply
  [[ "$reply" =~ ^[Yy]$ ]] || return 1

  case "$pm" in
    apt-get) sudo apt-get update -qq && sudo apt-get install -y "$pkg" ;;
    pacman)  sudo pacman -Sy --noconfirm "$pkg" ;;
    dnf)     sudo dnf install -y "$pkg" ;;
    brew)    brew install "$pkg" ;;
  esac

  if command -v "$bin" >/dev/null 2>&1; then
    ok "'$bin' установлен"
  else
    warn "установка '$pkg' не дала '$bin' в PATH — продолжаю без него"
    return 1
  fi
}
# root-пароль первого подключения скармливается ssh через SSH_ASKPASS
# (см. ssh_root ниже) — sshpass больше не нужен. OpenSSH >= 8.4 для
# SSH_ASKPASS_REQUIRE=force; на старее — фолбэк на ручной ввод N раз.
SSH_ASKPASS_OK=0
if ssh_ver="$(ssh -V 2>&1)" && [[ "$ssh_ver" =~ OpenSSH_([0-9]+)\.([0-9]+) ]]; then
  if (( BASH_REMATCH[1] > 8 || (BASH_REMATCH[1] == 8 && BASH_REMATCH[2] >= 4) )); then
    SSH_ASKPASS_OK=1
  fi
fi

install_optional_dep qrencode qrencode "чтобы показать QR-код VLESS-ссылки в конце" || true
HAVE_QRENCODE=0; command -v qrencode >/dev/null 2>&1 && HAVE_QRENCODE=1

# ---------------------------------------------------------------------------
# режим и IP
# ---------------------------------------------------------------------------
if [[ -z "$MODE" ]]; then
  echo "Что ставим?"
  echo "  1) VLESS Reality"
  echo "  2) OpenVPN"
  echo "  3) оба"
  read -rp "Выбор [1-3]: " choice
  case "$choice" in
    1) MODE="vless" ;;
    2) MODE="openvpn" ;;
    3) MODE="all" ;;
    *) die "непонятный выбор" ;;
  esac
fi

if [[ -z "$IP" ]]; then
  read -rp "IP сервера: " IP
fi
[[ -n "$IP" ]] || die "IP обязателен"

# ---------------------------------------------------------------------------
# состояние на этот сервер (не в git — install/.gitignore)
# ---------------------------------------------------------------------------
SAFE_IP="${IP//[.:]/_}"
STATE_DIR="$STATE_ROOT/$SAFE_IP"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_ROOT" "$STATE_DIR" 2>/dev/null || true

KEY_FILE="$STATE_DIR/id_ed25519"
KNOWN_HOSTS="$STATE_DIR/known_hosts"
SUMMARY_FILE="$STATE_DIR/summary.txt"
STATE_ENV="$STATE_DIR/state.env"
HOSTKEY_RAW="$STATE_DIR/hostkey.raw"

# всё, что должно быть СТАБИЛЬНО между прогонами — генерится один раз,
# сохраняется в state.env, при повторном прогоне переиспользуется. Иначе
# каждый прогон менял бы webBasePath / пути подписки / пароли панелей и
# ломал бы уже розданные ссылки.
SSH_USER=""; SSH_PORT=""; USER_PASSWORD=""; INSTALLED_MODES=""; DEST=""
XUI_BASE_PATH=""; SUB_PATH=""; SUB_JSON_PATH=""; XUI_ADMIN_PASS=""
OVPN_ADMIN_PATH=""; OVPN_ADMIN_PASS=""; OVPN_PORT=""
SSH_KEY_HOME=""; SSH_KEY_DEFAULT=0

# Пул доменов для REALITY SNI (см. блок «Шаг 5»). Крупные, всегда живые
# HTTPS-сайты на TLS 1.3, которые почти нигде не блокируют. Дефолт —
# случайный из пула: если у всех один и тот же SNI, это лишний признак
# для DPI. Свой домен — флаг --sni.
SNI_POOL=(
  www.microsoft.com  www.bing.com       www.apple.com     www.icloud.com
  swscan.apple.com   dl.google.com      www.samsung.com   www.nvidia.com
  www.amd.com        www.intel.com      www.cloudflare.com
  cdn.jsdelivr.net   www.tesla.com      www.sap.com       www.oracle.com
)
# shellcheck disable=SC1090
[[ -f "$STATE_ENV" ]] && source "$STATE_ENV"

[[ -n "$SSH_USER_ARG" ]] && SSH_USER="$SSH_USER_ARG"
[[ -n "$SSH_PORT_ARG" ]] && SSH_PORT="$SSH_PORT_ARG"
[[ -n "$SNI_ARG" ]]      && DEST="$SNI_ARG"

save_state() {
  umask 077
  cat > "$STATE_ENV" <<EOF
SSH_USER='$SSH_USER'
SSH_PORT='$SSH_PORT'
USER_PASSWORD='$USER_PASSWORD'
INSTALLED_MODES='$INSTALLED_MODES'
DEST='$DEST'
XUI_BASE_PATH='$XUI_BASE_PATH'
SUB_PATH='$SUB_PATH'
SUB_JSON_PATH='$SUB_JSON_PATH'
XUI_ADMIN_PASS='$XUI_ADMIN_PASS'
OVPN_ADMIN_PATH='$OVPN_ADMIN_PATH'
OVPN_ADMIN_PASS='$OVPN_ADMIN_PASS'
OVPN_PORT='$OVPN_PORT'
EOF
  chmod 600 "$STATE_ENV"
}

# Копия приватного ключа в ~/.ssh. Ключ живёт только в
# install/.state/<ip>/ (в .gitignore, заново не создаётся), а на сервере
# после хардненинга нет ни root, ни пароля — удалить клон без копии ключа =
# потерять доступ. Копируем только файл ключа; ~/.ssh/config НЕ трогаем
# (личный файл пользователя).
#
# Если слот дефолтного имени ~/.ssh/id_ed25519 свободен (или там уже наш
# ключ) — кладём туда: ssh подхватывает его сам, в сводке команда без -i.
# Иначе (там чужой личный ключ) — кладём в ~/.ssh/ovpn-stack-<ip> и в
# сводке команда с -i. Перезаписывать чужой id_ed25519 нельзя.
install_ssh_key() {
  local ssh_dir="$HOME/.ssh"
  local def="$ssh_dir/id_ed25519"
  local named="$ssh_dir/ovpn-stack-${SAFE_IP}"
  local dst

  [[ -n "${HOME:-}" && -f "$KEY_FILE" ]] || {
    warn "пропускаю копию ключа в ~/.ssh (нет HOME/ключа) — доступ только через клон"
    return 0
  }

  mkdir -p "$ssh_dir"; chmod 700 "$ssh_dir"

  if [[ ! -e "$def" && ! -e "${def}.pub" ]]; then
    dst="$def"
  elif [[ -f "${def}.pub" ]] && cmp -s "${KEY_FILE}.pub" "${def}.pub"; then
    dst="$def"                       # там уже этот же ключ — просто обновим
  else
    dst="$named"
    warn "в ~/.ssh уже есть личный id_ed25519 — кладу ключ как $(basename "$named"),"
    warn "в команде подключения будет -i (ssh не берёт нестандартные имена сам)"
  fi

  cp -f "$KEY_FILE" "$dst"; chmod 600 "$dst"
  cp -f "${KEY_FILE}.pub" "${dst}.pub"; chmod 644 "${dst}.pub"

  if [[ "$dst" == "$def" ]]; then
    SSH_KEY_DEFAULT=1; SSH_KEY_HOME="$def"
    ok "ключ скопирован в $def (ssh берёт его сам) — каталог install/.state/ можно удалять"
  else
    SSH_KEY_DEFAULT=0; SSH_KEY_HOME="$named"
    ok "ключ скопирован в $named — каталог install/.state/ можно удалять"
  fi
}

# ---------------------------------------------------------------------------
# sudo-пользователь на сервере: имя (дефолт — whoami домашнего ПК, в нижнем
# регистре; не переменная $USER — та может быть подменена/устаревшей) и пароль
# (Enter — сгенерировать). При повторном прогоне берутся из state.env,
# промпты пропускаются. Флаг --user переопределяет имя без вопроса.
# ---------------------------------------------------------------------------
valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]] && [[ ${#1} -le 32 ]]; }

if [[ -z "$SSH_USER" ]]; then
  candidate="$(whoami | tr '[:upper:]' '[:lower:]')"
  valid_username "$candidate" || candidate=""
  info "На сервере будет создан ОТДЕЛЬНЫЙ sudo-пользователь для управления"
  info "(вход по ключу, root после этого закрывается)."
  if [[ -n "$candidate" ]]; then
    info "Enter — назвать его как вас на этой машине ($candidate), либо впишите другое имя."
    read -rp "Имя пользователя на сервере [$candidate]: " SSH_USER
  else
    read -rp "Имя пользователя на сервере (латиница, с буквы/подчёркивания): " SSH_USER
  fi
  SSH_USER="${SSH_USER:-$candidate}"
fi
while ! valid_username "${SSH_USER:-}"; do
  read -rp "Некорректное имя. Латиница, цифры, - и _, с буквы или _, до 32 символов: " SSH_USER
done

if [[ -z "$USER_PASSWORD" ]]; then
  info "Пароль этого пользователя нужен только для sudo на сервере."
  read -rsp "Пароль для $SSH_USER (Enter — сгенерировать надёжный): " USER_PASSWORD; echo
  if [[ -n "$USER_PASSWORD" && ${#USER_PASSWORD} -lt 8 ]]; then
    warn "пароль короче 8 символов — на всякий случай генерирую вместо него"
    USER_PASSWORD=""
  fi
fi

# ---------------------------------------------------------------------------
# пробуем уже рабочий доступ по ключу (идемпотентный повторный прогон —
# root-пароль в этом случае вообще не нужен)
# ---------------------------------------------------------------------------
ssh_opts_key=(-o "UserKnownHostsFile=$KNOWN_HOSTS" -o StrictHostKeyChecking=yes -i "$KEY_FILE")
ALREADY_HAVE_ACCESS=0
if [[ -f "$KEY_FILE" && -n "$SSH_PORT" ]]; then
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "${ssh_opts_key[@]}" -p "$SSH_PORT" "$SSH_USER@$IP" true 2>/dev/null; then
    ALREADY_HAVE_ACCESS=1
  fi
fi

ssh_key() { ssh "${ssh_opts_key[@]}" -p "$CONN_PORT" "$SSH_USER@$IP" "$@"; }
scp_key() { scp "${ssh_opts_key[@]}" -P "$CONN_PORT" "$@"; }
sudo_key() { printf '%s\n' "$USER_PASSWORD" | ssh_key "sudo -S -p '' -- $*"; }

if [[ "$ALREADY_HAVE_ACCESS" -eq 1 ]]; then
  ok "уже есть рабочий доступ по ключу ($SSH_USER@$IP:$SSH_PORT) — пропускаю шаги 1-2"
  CONN_PORT="$SSH_PORT"
else
  # =========================================================================
  # ПЕРВОЕ ПОДКЛЮЧЕНИЕ — root-пароль, только здесь
  # =========================================================================
  step "Первое подключение к $IP"
  info "Нужен root-пароль сервера — тот, что прислал хостинг-провайдер"
  info "при создании VPS (в письме или в панели управления сервером)."
  info "Это единственный раз, когда он вводится; дальше — только по ключу."
  if [[ "$SSH_ASKPASS_OK" -eq 1 ]]; then
    read -rsp "root-пароль от провайдера: " ROOT_PASSWORD; echo
    [[ -n "$ROOT_PASSWORD" ]] || die "пустой пароль"
  else
    ROOT_PASSWORD=""   # без askpass пароль спросит сам ssh на TTY
  fi

  info "забираю host key... (root и пароль на сервере ещё не тронуты)"
  if ! ssh-keyscan -p 22 -T 10 -t ed25519 "$IP" > "$HOSTKEY_RAW" 2>/dev/null || [[ ! -s "$HOSTKEY_RAW" ]]; then
    ssh-keyscan -p 22 -T 10 "$IP" > "$HOSTKEY_RAW" 2>/dev/null
  fi
  [[ -s "$HOSTKEY_RAW" ]] || die "не получил host key — сервер не отвечает на 22/tcp?"

  # host key берём как есть (TOFU) и пиним в known_hosts проекта. Раньше тут
  # была интерактивная сверка fingerprint с панелью хостинга — убрали как
  # редко нужную и путающую; отпечаток печатаем в лог на всякий случай.
  info "host key: $(ssh-keygen -lf "$HOSTKEY_RAW" | awk '{print $2}')"
  cp "$HOSTKEY_RAW" "$KNOWN_HOSTS"

  # SSH_ASKPASS-хелпер: ssh берёт root-пароль из него (по разу на вызов,
  # без промптов). Пароль в файле НЕ лежит — хелпер печатает переменную
  # окружения, которую мы экспортим только на время первого подключения
  # и снимаем сразу после заливки ключа.
  ASKPASS="$STATE_DIR/.askpass"
  trap 'rm -f "${ASKPASS:-}" 2>/dev/null || true' EXIT
  if [[ "$SSH_ASKPASS_OK" -eq 1 ]]; then
    umask 077
    printf '#!/bin/sh\nprintf "%%s\\n" "$OVPN_STACK_SSH_PW"\n' > "$ASKPASS"
    chmod 700 "$ASKPASS"
    export OVPN_STACK_SSH_PW="$ROOT_PASSWORD"
    export SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force
    PW_PROMPTS=1   # одна попытка на вызов — повторный ввод крутим сами (ниже)
  else
    warn "OpenSSH старше 8.4 — root-пароль спросят вручную несколько раз подряд"
    PW_PROMPTS=3   # без askpass ssh сам даёт 3 попытки в одном вызове
  fi
  ssh_root() { ssh -o NumberOfPasswordPrompts="$PW_PROMPTS" -o "UserKnownHostsFile=$KNOWN_HOSTS" -o StrictHostKeyChecking=yes -p 22 "root@$IP" "$@"; }
  scp_root() { scp -o NumberOfPasswordPrompts="$PW_PROMPTS" -o "UserKnownHostsFile=$KNOWN_HOSTS" -o StrictHostKeyChecking=yes -P 22 "$@"; }

  # снять пароль из окружения и удалить хелпер, как только он больше не нужен
  drop_root_pw() {
    unset OVPN_STACK_SSH_PW SSH_ASKPASS SSH_ASKPASS_REQUIRE
    rm -f "$ASKPASS" 2>/dev/null || true
  }

  # неверный root-пароль на этом шаге — НЕ фатально: сервер ещё не тронут,
  # переспрашиваем (до 3 раз в askpass-режиме; без askpass 3 попытки даёт
  # сам ssh в одном вызове).
  info "проверяю вход по паролю..."
  attempt=1
  while ! ssh_root true >/dev/null 2>&1; do
    if [[ "$SSH_ASKPASS_OK" -ne 1 || "$attempt" -ge 3 ]]; then
      die "root-пароль не подошёл. Проверь пароль и IP ($IP), запусти снова — на сервере ничего не менялось."
    fi
    attempt=$((attempt + 1))
    warn "root-пароль не подошёл — попробуй ещё раз (${attempt}/3)"
    warn "это пароль от провайдера для root; не пароль пользователя $SSH_USER"
    read -rsp "root-пароль от провайдера: " ROOT_PASSWORD; echo
    [[ -n "$ROOT_PASSWORD" ]] || die "пустой пароль"
    export OVPN_STACK_SSH_PW="$ROOT_PASSWORD"
  done
  ok "вход по root-паролю работает"

  # -------------------------------------------------------------------------
  step "Шаг 1 — подготовка системы"
  scp_root "$SCRIPT_DIR/bootstrap.sh" "root@$IP:/root/ovpn-stack-bootstrap.sh" >/dev/null
  ssh_root "chmod +x /root/ovpn-stack-bootstrap.sh && /root/ovpn-stack-bootstrap.sh system-prep"
  ok "apt update/dist-upgrade, sudo, часовой пояс, unattended-upgrades готовы"

  REBOOT_STATUS="$(ssh_root '/root/ovpn-stack-bootstrap.sh reboot-if-needed' | tail -1)"
  if [[ "$REBOOT_STATUS" == "REBOOTING" ]]; then
    info "обновилось ядро — сервер уходит в ребут, жду возврата на 22/tcp"
    sleep 5
    waited=0
    until (exec 3<>"/dev/tcp/$IP/22") 2>/dev/null; do
      exec 3<&- 3>&- 2>/dev/null || true
      sleep 5; waited=$((waited+5))
      [[ $waited -ge 300 ]] && die "сервер не вернулся за 5 минут после ребута"
    done
    exec 3<&- 3>&- 2>/dev/null || true
    sleep 5
    ssh_root true >/dev/null || die "порт 22 открыт, но SSH ещё не готов — попробуй перезапустить setup.sh"
    ok "сервер вернулся после ребута"
  else
    info "ребут не требуется"
  fi

  # -------------------------------------------------------------------------
  step "Выбираю SSH-порт"
  if [[ -z "$SSH_PORT" ]]; then
    for _ in $(seq 1 20); do
      cand=$(( (RANDOM % 40001) + 20000 ))
      status="$(ssh_root "/root/ovpn-stack-bootstrap.sh check-port-free $cand" | tail -1)"
      if [[ "$status" == "FREE" ]]; then SSH_PORT="$cand"; break; fi
    done
    [[ -n "$SSH_PORT" ]] || die "не нашёл свободный порт за 20 попыток"
  fi
  ok "SSH-порт: $SSH_PORT"

  # ssh хранит host key для нестандартного порта под ключом "[ip]:port" —
  # добавляем такую запись сразу, чтобы после смены порта не словить
  # неожиданный prompt на верификацию (тот же хост, тот же ключ).
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    keytype_and_key="${line#* }"
    printf '[%s]:%s %s\n' "$IP" "$SSH_PORT" "$keytype_and_key" >> "$KNOWN_HOSTS"
  done < "$HOSTKEY_RAW"

  # -------------------------------------------------------------------------
  step "Шаг 1 — пользователь $SSH_USER"
  if [[ -z "$USER_PASSWORD" ]]; then
    USER_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)"
    info "пароль пользователя сгенерирован — будет в сводке"
  fi
  printf '%s\n' "$USER_PASSWORD" | ssh_root "/root/ovpn-stack-bootstrap.sh user-create '$SSH_USER'"
  ok "пользователь создан/подтверждён, добавлен в sudo"

  if [[ ! -f "$KEY_FILE" ]]; then
    info "генерирую отдельную ed25519-пару под этот сервер"
    ssh-keygen -t ed25519 -N '' -f "$KEY_FILE" -C "ovpn-stack-$IP" -q
  fi
  chmod 600 "$KEY_FILE"

  PUBKEY="$(cat "${KEY_FILE}.pub")"
  printf '%s\n' "$PUBKEY" | ssh_root "/root/ovpn-stack-bootstrap.sh install-authorized-key '$SSH_USER'"
  ok "публичный ключ добавлен в authorized_keys"

  # -------------------------------------------------------------------------
  step "Шаг 2 — проверка ключа и sudo НОВЫМ соединением"
  CONN_PORT=22
  if ! ssh -o BatchMode=yes "${ssh_opts_key[@]}" -p 22 "$SSH_USER@$IP" true; then
    die "вход по ключу не прошёл. root и пароль НЕ тронуты — почини вручную и перезапусти."
  fi
  ok "вход по ключу работает"
  drop_root_pw; unset ROOT_PASSWORD   # дальше только ключевая аутентификация

  if ! sudo_key true; then
    die "sudo у $SSH_USER не работает. root и пароль НЕ тронуты — это блокер, см. NOTES.md §6 п.4."
  fi
  ok "sudo подтверждён — с этого момента безопасно продолжать"

  save_state
fi

CONN_PORT="${CONN_PORT:-${SSH_PORT}}"

# ===========================================================================
# репозиторий на сервере (нужен для admin/ build context и install/templates)
# ===========================================================================
step "Синхронизирую репозиторий на сервере"
sudo_key "bash -c 'command -v git >/dev/null 2>&1 || (apt-get -o DPkg::Lock::Timeout=120 update -qq && apt-get -o DPkg::Lock::Timeout=120 -y install -qq git)'" >/dev/null
ssh_key "mkdir -p ~/.ovpn-stack-bootstrap"
scp_key "$SCRIPT_DIR/install-vpn.sh" "$SCRIPT_DIR/bootstrap.sh" "$SSH_USER@$IP:~/.ovpn-stack-bootstrap/" >/dev/null
ssh_key "chmod +x ~/.ovpn-stack-bootstrap/*.sh && ~/.ovpn-stack-bootstrap/install-vpn.sh repo-sync '$REPO_URL' '$GIT_BRANCH'"
ok "репозиторий синхронизирован в /opt/ovpn-stack"

BOOTSTRAP="/opt/ovpn-stack/install/bootstrap.sh"
INSTALLVPN="/opt/ovpn-stack/install/install-vpn.sh"

# ===========================================================================
# nftables + sshd — ОДНОЙ remote-командой (см. комментарий ниже: разрывать
# на два отдельных ssh-вызова нельзя, между ними firewall уже не пускает
# новые соединения на старый порт, а sshd ещё не слушает новый)
# ===========================================================================
step "Шаг 2/3 — firewall и sshd hardening"
OVPN_PORT_ARG=""
if [[ "$MODE" == "openvpn" || "$MODE" == "all" ]]; then
  # из state.env, если уже был — иначе случайный и сохраним (иначе каждый
  # прогон менял бы UDP-порт OpenVPN и ломал розданные .ovpn-конфиги)
  [[ -n "$OVPN_PORT" ]] || OVPN_PORT="$(( (RANDOM % 40001) + 20000 ))"
  OVPN_PORT_ARG="$OVPN_PORT"
fi

harden_cmd="sudo -S -p '' -- bash -c '${BOOTSTRAP} nftables-apply ${SSH_PORT} ${MODE} ${OVPN_PORT_ARG} && ${BOOTSTRAP} sshd-harden ${SSH_PORT}'"
if ! printf '%s\n' "$USER_PASSWORD" | ssh_key "$harden_cmd"; then
  die "nftables/sshd hardening не прошёл на сервере — соединение на порт $CONN_PORT должно быть ещё живо, почини вручную по логам выше"
fi
info "локальные проверки на сервере прошли — проверяю НОВЫМ соединением снаружи"

CONFIRMED=0
for _ in $(seq 1 12); do
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "${ssh_opts_key[@]}" -p "$SSH_PORT" "$SSH_USER@$IP" true 2>/dev/null; then
    CONFIRMED=1; break
  fi
  sleep 2
done

if [[ "$CONFIRMED" -eq 1 ]]; then
  CONN_PORT="$SSH_PORT"
  sudo_key "bash -c '${BOOTSTRAP} nftables-confirm && ${BOOTSTRAP} sshd-confirm'" >/dev/null
  ok "новое соединение на порту $SSH_PORT подтверждено — старый путь закрыт"
  save_state
else
  warn "внешнее соединение на новый порт $SSH_PORT не подтвердилось."
  warn "на сервере стоит страховочный таймер — он сам откатит nftables и sshd в течение 5 минут."
  die "подожди 5 минут и перезапусти setup.sh — доступ по порту 22 и паролю должен вернуться сам"
fi

# ===========================================================================
# шаг 4 — сервисы
# ===========================================================================
step "Шаг 4 — Docker и каталоги"
sudo_key "${INSTALLVPN} docker-install"
sudo_key "${INSTALLVPN} docker-group-add '${SSH_USER}'"
ssh_key "${INSTALLVPN} dirs-init '${MODE}'"
ok "Docker готов, каталоги под volume созданы"

step "Рендер docker-compose"
ssh_key "${INSTALLVPN} render-compose '${MODE}' '${OVPN_PORT_ARG:-1194}' '${IP}'"

step "Поднимаю первую очередь сервисов (без nginx — сертификата ещё нет)"
if [[ "$MODE" == "vless" || "$MODE" == "all" ]]; then
  ssh_key "${INSTALLVPN} compose-up-service 3x-ui"
fi
if [[ "$MODE" == "openvpn" || "$MODE" == "all" ]]; then
  ssh_key "${INSTALLVPN} compose-up-service openvpn"
  ssh_key "${INSTALLVPN} compose-up-service ovpn-admin"
fi
ok "сервисы подняты"

step "Сертификат (Let's Encrypt на IP, acme.sh)"
sudo_key "${INSTALLVPN} acme-install"
cert_rc=0
sudo_key "${INSTALLVPN} cert-issue '${IP}' '' '${ACME_STAGING}'" || cert_rc=$?
if [[ "$cert_rc" -ne 0 ]]; then
  # cert-issue (rc=3 при rate-limit) уже напечатал подробности выше.
  # Всё до этого шага идемпотентно и сохранено — перезапуск продолжит отсюда.
  die "выпуск сертификата не прошёл (см. вывод выше). Установка остановлена; перезапусти ту же команду позже — она продолжит с этого шага."
fi
ok "сертификат выпущен (standalone, порт 80)"

# -------------------------------------------------------------------------
XUI_PORT="2053"
gen_hex()  { openssl rand -hex "$1"; }
gen_pass() { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20; }
if [[ "$MODE" == "vless" || "$MODE" == "all" ]]; then
  # пути и пароль — из state.env, если уже есть; иначе генерим и сохраним ниже
  [[ -n "$XUI_BASE_PATH" ]] || XUI_BASE_PATH="/x-$(gen_hex 4)/"
  [[ -n "$SUB_PATH"      ]] || SUB_PATH="/sub-$(gen_hex 8)/"          # неочевидные, как у панели (NOTES.md §8, §11)
  [[ -n "$SUB_JSON_PATH" ]] || SUB_JSON_PATH="/json-$(gen_hex 8)/"
  [[ -n "$XUI_ADMIN_PASS" ]] || XUI_ADMIN_PASS="$(gen_pass)"
  XUI_ADMIN_USER="admin"
  step "Настраиваю 3x-ui (webBasePath, логин панели)"
  ssh_key "${INSTALLVPN} xui-configure 3x-ui '${XUI_BASE_PATH}' '${XUI_ADMIN_USER}' '${XUI_ADMIN_PASS}' '${XUI_PORT}'"
  step "Включаю подписку 3x-ui (за nginx :8443, путь ${SUB_PATH})"
  sudo_key "${INSTALLVPN} xui-enable-sub 3x-ui '${SUB_PATH}' '${SUB_JSON_PATH}' '${IP}'"
fi
if [[ "$MODE" == "openvpn" || "$MODE" == "all" ]]; then
  # ovpn-admin не умеет проверять пароль сам (в отличие от 3x-ui) —
  # секретный путь без Basic Auth перед ним означает вообще без защиты.
  [[ -n "$OVPN_ADMIN_PATH" ]] || OVPN_ADMIN_PATH="/ovpn-$(gen_hex 4)/"
  [[ -n "$OVPN_ADMIN_PASS" ]] || OVPN_ADMIN_PASS="$(gen_pass)"
  OVPN_ADMIN_USER="admin"
  step "Basic Auth для панели ovpn-admin"
  ssh_key "${INSTALLVPN} htpasswd-generate '${OVPN_ADMIN_USER}' '${OVPN_ADMIN_PASS}'"
fi

step "Рендер и запуск nginx (последним — сертификат уже есть)"
ssh_key "${INSTALLVPN} render-nginx '${MODE}' '${XUI_BASE_PATH}' '${XUI_PORT}' '${OVPN_ADMIN_PATH}' '${SUB_PATH}' '${SUB_JSON_PATH}'"
ssh_key "${INSTALLVPN} compose-up-service nginx"
ssh_key "${INSTALLVPN} nginx-reload"
sudo_key "${INSTALLVPN} cert-switch-to-webroot '${IP}' '${ACME_STAGING}'"
ok "nginx поднят, продление сертификата переключено на webroot"

# ===========================================================================
# шаг 5 — первый VLESS+Reality инбаунд
# ===========================================================================
VLESS_LINE=""
VLESS_SUBID=""
if [[ "$MODE" == "vless" || "$MODE" == "all" ]]; then
  step "Шаг 5 — первый VLESS+Reality инбаунд"
  if [[ -z "$DEST" ]]; then
    sni_default="${SNI_POOL[RANDOM % ${#SNI_POOL[@]}]}"
    if [[ -t 0 ]]; then
      cat >&2 <<EOF
    ── SNI для VLESS Reality ─────────────────────────────────────────
    SNI — это доменное имя, которое КЛИЕНТ вписывает в своё TLS-
    рукопожатие. Для наблюдателя (DPI провайдера) трафик выглядит как
    обычный HTTPS к этому сайту — в этом вся маскировка Reality.

    Сервер к этому домену НЕ подключается: реальный dest — локальная
    заглушка (nginx на 127.0.0.1:8444). Домен нужен только чтобы быть
    правдоподобным. Требования: крупный, всегда живой HTTPS-сайт на
    TLS 1.3, который НЕ заблокирован в твоей стране (иначе и твой VPN
    будет «блокирован» на вид). НЕ бери домен, который сам под баном.

    Значение уходит в ссылку клиента (sni=…) и в инбаунд 3x-ui. Смена
    потом = переделывать все розданные ссылки. Меняется флагом --sni.
    Enter — случайный из встроенного пула (у всех разный SNI — меньше
    шансов попасть под сигнатуру).
    ─────────────────────────────────────────────────────────────────
EOF
      read -rp "  Домен для SNI [Enter = $sni_default]: " DEST
    fi
    [[ -n "$DEST" ]] || DEST="$sni_default"
    info "SNI: $DEST"
  else
    info "SNI: $DEST (из --sni / state.env)"
  fi

  step "Локальный fakesite для dest (не внешний домен — см. NOTES.md §9)"
  FAKESITE_OUT="$(sudo_key "${INSTALLVPN} fakesite-install '${DEST}'")"
  FAKESITE_DEST="$(awk -F= '/^FAKESITE_DEST=/{print $2}' <<<"$FAKESITE_OUT")"
  [[ -n "$FAKESITE_DEST" ]] || die "fakesite-install не вернул адрес dest"
  ok "fakesite поднят на ${FAKESITE_DEST}, SNI=${DEST}"

  XUI_BASE_URL="http://127.0.0.1:${XUI_PORT}${XUI_BASE_PATH}"
  VLESS_OUT="$(ssh_key "${INSTALLVPN} vless-create '${XUI_BASE_URL}' '${XUI_ADMIN_USER}' '${XUI_ADMIN_PASS}' '${FAKESITE_DEST}' '${DEST}' '${IP}'")"
  VLESS_UUID="$(awk -F= '/^VLESS_UUID=/{print $2}' <<<"$VLESS_OUT")"
  VLESS_PUBKEY="$(awk -F= '/^VLESS_PUBKEY=/{print $2}' <<<"$VLESS_OUT")"
  VLESS_SHORTID="$(awk -F= '/^VLESS_SHORTID=/{print $2}' <<<"$VLESS_OUT")"
  VLESS_SUBID="$(awk -F= '/^VLESS_SUBID=/{print $2}' <<<"$VLESS_OUT")"
  VLESS_FP="$(awk -F= '/^VLESS_FP=/{print $2}' <<<"$VLESS_OUT")"
  VLESS_FP="${VLESS_FP:-firefox}"   # см. install-vpn.sh: chrome режет реальный оператор
  if [[ -n "$VLESS_UUID" && -n "$VLESS_PUBKEY" ]]; then
    VLESS_LINE="vless://${VLESS_UUID}@${IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=${VLESS_FP}&pbk=${VLESS_PUBKEY}&sid=${VLESS_SHORTID}&spx=%2F&type=tcp#ovpn-stack"
    ok "VLESS-инбаунд создан"
  else
    warn "инбаунд уже существовал (или вывод не распознан) — открой панель 3x-ui и проверь руками"
  fi
fi

# ===========================================================================
# шаг 6 — сводка
# ===========================================================================
step "Шаг 6 — сводка"
[[ "$MODE" != "openvpn" ]] && INSTALLED_MODES="${INSTALLED_MODES}vless "
[[ "$MODE" != "vless" ]]   && INSTALLED_MODES="${INSTALLED_MODES}openvpn "
save_state

if [[ "$NO_KEY_COPY" -eq 0 ]]; then
  install_ssh_key
else
  info "--no-key-copy: ключ только в ${KEY_FILE} — не удаляй каталог install/.state/"
fi

{
  echo "ovpn-stack — сводка установки"
  echo "Сгенерировано: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "== Доступ =="
  if [[ "$SSH_KEY_DEFAULT" -eq 1 ]]; then
    echo "ssh -p ${SSH_PORT} ${SSH_USER}@${IP}"
    echo "  (ключ в ${SSH_KEY_HOME} — ssh берёт его сам; install/.state/ можно удалять)"
  elif [[ -n "$SSH_KEY_HOME" ]]; then
    echo "ssh -i '${SSH_KEY_HOME}' -p ${SSH_PORT} ${SSH_USER}@${IP}"
    echo "  (ключ скопирован в ${SSH_KEY_HOME} — каталог install/.state/ можно удалять)"
  else
    echo "ssh -i '${KEY_FILE}' -p ${SSH_PORT} ${SSH_USER}@${IP}"
    echo "  ВНИМАНИЕ: ключ только в install/.state/ — не удаляй этот каталог"
  fi
  echo "пароль пользователя (для sudo): ${USER_PASSWORD}"
  echo
  echo "== Порты =="
  echo "SSH:      ${SSH_PORT}/tcp"
  [[ -n "$XUI_BASE_PATH" ]]  && echo "Xray/3x-ui: 443/tcp"
  echo "nginx (панели): 8443/tcp"
  echo "ACME:     80/tcp"
  [[ -n "$OVPN_PORT_ARG" ]] && echo "OpenVPN:  ${OVPN_PORT_ARG}/udp"
  echo
  if [[ -n "$XUI_BASE_PATH" ]]; then
    echo "== Панель 3x-ui =="
    echo "URL:   https://${IP}:8443${XUI_BASE_PATH}"
    echo "Логин: ${XUI_ADMIN_USER}"
    echo "Пароль: ${XUI_ADMIN_PASS}"
    echo
  fi
  if [[ -n "$OVPN_ADMIN_PATH" ]]; then
    echo "== Панель ovpn-admin =="
    echo "URL: https://${IP}:8443${OVPN_ADMIN_PATH}"
    echo "Basic Auth логин: ${OVPN_ADMIN_USER}"
    echo "Basic Auth пароль: ${OVPN_ADMIN_PASS}"
    echo "(у самого приложения своего логина нет — вход только через Basic Auth выше)"
    echo
  fi
  if [[ -n "$VLESS_LINE" ]]; then
    echo "== Первый VLESS-ключ =="
    echo "$VLESS_LINE"
    echo
  fi
  if [[ -n "$SUB_PATH" ]]; then
    echo "== Подписка 3x-ui =="
    if [[ -n "$VLESS_SUBID" ]]; then
      echo "URL первого клиента: https://${IP}:8443${SUB_PATH}${VLESS_SUBID}"
      echo "JSON-подписка:        https://${IP}:8443${SUB_JSON_PATH}${VLESS_SUBID}"
      echo
    fi
    echo "Для новых клиентов: URL = https://${IP}:8443${SUB_PATH} + его subId"
    echo "(поле Sub ID в карточке клиента в панели; QR и «копировать» в"
    echo "самой панели тоже дают правильную ссылку с путём)."
    echo
  fi
  echo "== Напоминания =="
  [[ -n "$ACME_STAGING" ]] && echo "- ВНИМАНИЕ: сертификат из ACME STAGING — браузер покажет «не защищено». Тестовый прогон, для боевого убери --staging и перевыпусти."
  echo "- автообновления с ребутом каждую ночь в 04:00 (Automatic-Reboot-WithUsers=false)"
  echo "- IP-сертификат живёт ~6 суток, продление настроено (systemd-таймер, дважды в день)"
  echo "- при полной потере SSH-доступа остаётся консоль в панели управления сервером"
  echo "- смена IP сервера убьёт сертификат — потребуется перевыпуск"
} > "$SUMMARY_FILE"
chmod 600 "$SUMMARY_FILE"

# копия сводки в домашней директории — чтобы не искать в install/.state/<ip>/
HOME_SUMMARY="$HOME/ovpn-stack-${SAFE_IP}-summary.txt"
cp "$SUMMARY_FILE" "$HOME_SUMMARY"
chmod 600 "$HOME_SUMMARY"

# и печатаем всё в терминал — сводка со всеми реквизитами прямо здесь
echo
printf '%s\n' "────────────────────────────────────────────────────────────"
cat "$SUMMARY_FILE"
printf '%s\n' "────────────────────────────────────────────────────────────"
echo
ok "сводка сохранена: $HOME_SUMMARY (и $SUMMARY_FILE)"

if [[ "$HAVE_QRENCODE" -eq 1 && -n "$VLESS_LINE" ]]; then
  echo
  echo "  QR-код первого VLESS-ключа — отсканировать в VLESS-клиенте"
  echo "  (Happ, v2rayNG, NekoBox, sing-box, Streisand и т.п.):"
  echo
  qrencode -t ANSIUTF8 "$VLESS_LINE" || true
fi

echo
if [[ "$SSH_KEY_DEFAULT" -eq 1 ]]; then
  ok "Готово. Подключение: ssh -p ${SSH_PORT} ${SSH_USER}@${IP}"
else
  ok "Готово. Подключение: ssh -i '${SSH_KEY_HOME:-$KEY_FILE}' -p ${SSH_PORT} ${SSH_USER}@${IP}"
fi
