#!/usr/bin/env bash
#
# setup.sh — единственная точка входа установщика (install/README.md).
# Запускается на домашнем ПК (Linux / macOS / WSL) с root-паролем свежего
# VPS под рукой. Ведёт сервер от голого root-пароля до рабочего VLESS
# Reality и/или OpenVPN, вызывая bootstrap.sh и install-vpn.sh на сервере
# по одной подкоманде за раз.
#
# Использование:
#   ./setup.sh [--vless|--openvpn|--all] [--ip <addr>] [--user <name>]
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
  $0 [--vless|--openvpn|--all] [--ip <addr>] [--user <name>] [--ssh-port <port>]

Флаги:
  --vless          режим: только VLESS Reality
  --openvpn        режим: только OpenVPN
  --all            режим: оба
  --ip <addr>      IP сервера (иначе спросит)
  --user <name>    имя sudo-пользователя (иначе \$USER в нижнем регистре)
  --ssh-port <p>   порт SSH после хардненинга (иначе случайный 20000-60000)
  -h, --help       эта справка

root-пароль и пароль пользователя ВСЕГДА вводятся интерактивно — их нельзя
передать флагом (см. install/README.md, принцип «секреты не в git/ps»).
EOF
}

# ---------------------------------------------------------------------------
# аргументы
# ---------------------------------------------------------------------------
MODE=""
IP=""
SSH_USER_ARG=""
SSH_PORT_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vless)    MODE="vless" ;;
    --openvpn)  MODE="openvpn" ;;
    --all)      MODE="all" ;;
    --ip)       IP="${2:?}"; shift ;;
    --user)     SSH_USER_ARG="${2:?}"; shift ;;
    --ssh-port) SSH_PORT_ARG="${2:?}"; shift ;;
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
    brew)
      # sshpass убрали из homebrew-core (политика против автоматизации
      # парольного SSH) — только через сторонний tap
      if [[ "$bin" == "sshpass" ]]; then
        brew install esolitos/ipa/sshpass
      else
        brew install "$pkg"
      fi
      ;;
  esac

  if command -v "$bin" >/dev/null 2>&1; then
    ok "'$bin' установлен"
  else
    warn "установка '$pkg' не дала '$bin' в PATH — продолжаю без него"
    return 1
  fi
}
install_optional_dep sshpass sshpass "чтобы не вводить root-пароль по нескольку раз при первом подключении" || true
install_optional_dep qrencode qrencode "чтобы показать QR-код VLESS-ссылки в конце" || true

HAVE_SSHPASS=0; command -v sshpass >/dev/null 2>&1 && HAVE_SSHPASS=1
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

SSH_USER=""; SSH_PORT=""; USER_PASSWORD=""; INSTALLED_MODES=""
# shellcheck disable=SC1090
[[ -f "$STATE_ENV" ]] && source "$STATE_ENV"

[[ -n "$SSH_USER_ARG" ]] && SSH_USER="$SSH_USER_ARG"
[[ -n "$SSH_PORT_ARG" ]] && SSH_PORT="$SSH_PORT_ARG"

save_state() {
  umask 077
  cat > "$STATE_ENV" <<EOF
SSH_USER='$SSH_USER'
SSH_PORT='$SSH_PORT'
USER_PASSWORD='$USER_PASSWORD'
INSTALLED_MODES='$INSTALLED_MODES'
EOF
  chmod 600 "$STATE_ENV"
}

# ---------------------------------------------------------------------------
# username по умолчанию — $USER домашнего ПК, нижний регистр
# ---------------------------------------------------------------------------
valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]] && [[ ${#1} -le 32 ]]; }

if [[ -z "$SSH_USER" ]]; then
  candidate="$(whoami | tr '[:upper:]' '[:lower:]')"
  if valid_username "$candidate"; then
    SSH_USER="$candidate"
  else
    warn "имя '$candidate' не подходит под ^[a-z_][a-z0-9_-]*\$"
  fi
fi
while ! valid_username "${SSH_USER:-}"; do
  read -rp "Имя пользователя на сервере (латиница, нижний регистр): " SSH_USER
done

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
  read -rsp "root-пароль: " ROOT_PASSWORD; echo
  [[ -n "$ROOT_PASSWORD" ]] || die "пустой пароль"

  info "забираю host key..."
  if ! ssh-keyscan -p 22 -T 10 -t ed25519 "$IP" > "$HOSTKEY_RAW" 2>/dev/null || [[ ! -s "$HOSTKEY_RAW" ]]; then
    ssh-keyscan -p 22 -T 10 "$IP" > "$HOSTKEY_RAW" 2>/dev/null
  fi
  [[ -s "$HOSTKEY_RAW" ]] || die "не получил host key — сервер не отвечает на 22/tcp?"

  echo
  echo "  Fingerprint (сверь с панелью управления сервером):"
  ssh-keygen -lf "$HOSTKEY_RAW" | sed 's/^/    /'
  echo
  read -rp "  Совпадает? Продолжить (yes/no): " CONFIRM
  [[ "$CONFIRM" == "yes" ]] || die "отменено пользователем"
  cp "$HOSTKEY_RAW" "$KNOWN_HOSTS"

  ssh_root() {
    if [[ "$HAVE_SSHPASS" -eq 1 ]]; then
      sshpass -p "$ROOT_PASSWORD" ssh -o "UserKnownHostsFile=$KNOWN_HOSTS" -o StrictHostKeyChecking=yes -p 22 "root@$IP" "$@"
    else
      ssh -o "UserKnownHostsFile=$KNOWN_HOSTS" -o StrictHostKeyChecking=yes -p 22 "root@$IP" "$@"
    fi
  }
  scp_root() {
    if [[ "$HAVE_SSHPASS" -eq 1 ]]; then
      sshpass -p "$ROOT_PASSWORD" scp -o "UserKnownHostsFile=$KNOWN_HOSTS" -o StrictHostKeyChecking=yes -P 22 "$@"
    else
      scp -o "UserKnownHostsFile=$KNOWN_HOSTS" -o StrictHostKeyChecking=yes -P 22 "$@"
    fi
  }
  [[ "$HAVE_SSHPASS" -eq 0 ]] && warn "sshpass не найден — пароль root спросят вручную несколько раз подряд"

  info "проверяю вход по паролю..."
  ssh_root true >/dev/null || die "не удалось войти по root-паролю"
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

  if ! sudo_key true; then
    die "sudo у $SSH_USER не работает. root и пароль НЕ тронуты — это блокер, см. README §6 п.4."
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
  OVPN_PORT="${OVPN_PORT:-$(( (RANDOM % 40001) + 20000 ))}"
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
sudo_key "${INSTALLVPN} cert-issue '${IP}'"
ok "сертификат выпущен (standalone, порт 80)"

# -------------------------------------------------------------------------
XUI_BASE_PATH=""
XUI_PORT="2053"
OVPN_ADMIN_PATH=""
if [[ "$MODE" == "vless" || "$MODE" == "all" ]]; then
  XUI_BASE_PATH="/x-$(openssl rand -hex 4)/"
  XUI_ADMIN_USER="admin"
  XUI_ADMIN_PASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
  step "Настраиваю 3x-ui (webBasePath, логин панели)"
  ssh_key "${INSTALLVPN} xui-configure 3x-ui '${XUI_BASE_PATH}' '${XUI_ADMIN_USER}' '${XUI_ADMIN_PASS}' '${XUI_PORT}'"
fi
if [[ "$MODE" == "openvpn" || "$MODE" == "all" ]]; then
  OVPN_ADMIN_PATH="/ovpn-$(openssl rand -hex 4)/"
fi

step "Рендер и запуск nginx (последним — сертификат уже есть)"
ssh_key "${INSTALLVPN} render-nginx '${MODE}' '${XUI_BASE_PATH}' '${XUI_PORT}' '${OVPN_ADMIN_PATH}'"
ssh_key "${INSTALLVPN} compose-up-service nginx"
ssh_key "${INSTALLVPN} nginx-reload"
sudo_key "${INSTALLVPN} cert-switch-to-webroot '${IP}'"
ok "nginx поднят, продление сертификата переключено на webroot"

# ===========================================================================
# шаг 5 — первый VLESS+Reality инбаунд
# ===========================================================================
VLESS_LINE=""
if [[ "$MODE" == "vless" || "$MODE" == "all" ]]; then
  step "Шаг 5 — первый VLESS+Reality инбаунд"
  DEST=""
  while [[ -z "$DEST" ]]; do
    read -rp "Домен для dest (TLS1.3+H2, не за CDN, см. README §9): " DEST
    info "проверяю xray tls ping..."
    tls_status="$(ssh_key "${INSTALLVPN} tls-ping '${DEST}'" | tail -1)"
    if [[ "$tls_status" != "OK" ]]; then
      warn "'$DEST' не прошёл проверку (TLS1.3+H2 через ALPN) — выбери другой домен"
      DEST=""
    fi
  done
  ok "dest подтверждён: $DEST"

  XUI_BASE_URL="http://127.0.0.1:${XUI_PORT}${XUI_BASE_PATH}"
  VLESS_OUT="$(ssh_key "${INSTALLVPN} vless-create '${XUI_BASE_URL}' '${XUI_ADMIN_USER}' '${XUI_ADMIN_PASS}' '${DEST}' '${DEST}'")"
  VLESS_UUID="$(awk -F= '/^VLESS_UUID=/{print $2}' <<<"$VLESS_OUT")"
  VLESS_PUBKEY="$(awk -F= '/^VLESS_PUBKEY=/{print $2}' <<<"$VLESS_OUT")"
  VLESS_SHORTID="$(awk -F= '/^VLESS_SHORTID=/{print $2}' <<<"$VLESS_OUT")"
  if [[ -n "$VLESS_UUID" && -n "$VLESS_PUBKEY" ]]; then
    VLESS_LINE="vless://${VLESS_UUID}@${IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=chrome&pbk=${VLESS_PUBKEY}&sid=${VLESS_SHORTID}&type=tcp#ovpn-stack"
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

{
  echo "ovpn-stack — сводка установки"
  echo "Сгенерировано: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "== Доступ =="
  echo "ssh -i '${KEY_FILE}' -p ${SSH_PORT} ${SSH_USER}@${IP}"
  echo "пароль пользователя (для sudo): ${USER_PASSWORD}"
  echo
  echo "== Порты =="
  echo "SSH:      ${SSH_PORT}/tcp"
  echo "Xray/3x-ui: 443/tcp"
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
    echo "(логин/пароль панели — задай при первом входе, см. её собственную документацию)"
    echo
  fi
  if [[ -n "$VLESS_LINE" ]]; then
    echo "== Первый VLESS-ключ =="
    echo "$VLESS_LINE"
    echo
  fi
  echo "== Напоминания =="
  echo "- автообновления с ребутом каждую ночь в 04:00 (Automatic-Reboot-WithUsers=false)"
  echo "- IP-сертификат живёт ~6 суток, продление настроено (systemd-таймер, дважды в день)"
  echo "- при полной потере SSH-доступа остаётся консоль в панели управления сервером"
  echo "- смена IP сервера убьёт сертификат — потребуется перевыпуск"
} > "$SUMMARY_FILE"
chmod 600 "$SUMMARY_FILE"

ok "сводка записана: $SUMMARY_FILE"
if [[ "$HAVE_QRENCODE" -eq 1 && -n "$VLESS_LINE" ]]; then
  echo
  qrencode -t ANSIUTF8 "$VLESS_LINE" || true
fi

echo
ok "Готово. Подключение: ssh -i '${KEY_FILE}' -p ${SSH_PORT} ${SSH_USER}@${IP}"
