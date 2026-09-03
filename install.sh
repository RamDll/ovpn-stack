#!/usr/bin/env bash
#
# ovpn-stack — установка на свежий сервер.
#
#   # wget есть в базовой Debian (priority: standard), curl — нет:
#   wget -qO install.sh https://raw.githubusercontent.com/RamDll/ovpn-stack/master/install.sh
#   # либо, если стоит curl:
#   curl -fsSL https://raw.githubusercontent.com/RamDll/ovpn-stack/master/install.sh -o install.sh
#
#   sudo bash install.sh
#
# Что делает: проверяет дистрибутив, ставит зависимости (Docker, git, fail2ban),
# клонирует репозиторий, спрашивает логин/пароль панели и адрес (домен или IP),
# поднимает стек, выпускает TLS-сертификат через acme.sh, настраивает фильтр
# fail2ban и — в зависимости от того, какой файрвол уже стоит — открывает порты
# 80/tcp, 443/tcp, <ovpn>/udp и текущий порт SSH.
#
# Флаги для неинтерактивного запуска: см. --help.

set -Eeuo pipefail

# --- порт SSH текущей сессии — снять ДО любых sudo/su, потом $SSH_CONNECTION теряется
SSH_CONNECTION_SAVED="${SSH_CONNECTION:-}"

# ---------------------------------------------------------------------------
# Константы
# ---------------------------------------------------------------------------
REPO_URL="https://github.com/RamDll/ovpn-stack.git"
DEFAULT_DIR="/opt/ovpn-stack"
NGINX_CONTAINER="ovpn-stack-nginx-1"

# ---------------------------------------------------------------------------
# Параметры (значения по умолчанию; переопределяются флагами и промптами)
# ---------------------------------------------------------------------------
ASSUME_YES=0
NONINTERACTIVE=0
DOMAIN=""
PUBLIC_IP=""
PANEL_USER="admin"
PANEL_PASS=""
OVPN_PORT="7777"
INSTALL_DIR="$DEFAULT_DIR"
ACME_EMAIL=""
GIT_BRANCH="master"
DO_FIREWALL=1
DO_FAIL2BAN=1
DO_ACME=1
DO_SELF_SIGNED_ONLY=0

# ---------------------------------------------------------------------------
# Логирование
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

trap 'err "прервано на строке $LINENO (код $?). Стек мог подняться не полностью — проверь: docker compose ps в $INSTALL_DIR"' ERR

# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
ovpn-stack installer

Использование:
  sudo bash install.sh [флаги]

Флаги:
  --domain <name>       выпустить TLS на доменное имя (нужна A-запись на этот сервер)
  --ip <addr>           публичный IP (если не задан и нет --domain — определится сам)
  --user <name>         логин Basic Auth панели (по умолчанию: admin)
  --password <pass>     пароль Basic Auth (иначе спросит; в --yes обязателен)
  --password-file <f>   пароль из файла (первая строка)
  --email <addr>        e-mail для регистрации в Let's Encrypt
  --ovpn-port <n>       UDP-порт OpenVPN наружу (по умолчанию: 7777)
  --dir <path>          куда клонировать (по умолчанию: $DEFAULT_DIR)
  --branch <name>       ветка репозитория (по умолчанию: master)
  --no-firewall         не трогать файрвол
  --no-fail2ban         не ставить fail2ban
  --no-acme             не выпускать Let's Encrypt (оставить self-signed)
  --self-signed         принудительно self-signed (синоним --no-acme)
  --yes                 не задавать вопросов (нужны --password и --domain|--ip)
  -h, --help            эта справка
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)        DOMAIN="${2:?}"; shift 2 ;;
      --ip)            PUBLIC_IP="${2:?}"; shift 2 ;;
      --user)          PANEL_USER="${2:?}"; shift 2 ;;
      --password)      PANEL_PASS="${2:?}"; shift 2 ;;
      --password-file) PANEL_PASS="$(head -n1 "${2:?}")"; shift 2 ;;
      --email)         ACME_EMAIL="${2:?}"; shift 2 ;;
      --ovpn-port)     OVPN_PORT="${2:?}"; shift 2 ;;
      --dir)           INSTALL_DIR="${2:?}"; shift 2 ;;
      --branch)        GIT_BRANCH="${2:?}"; shift 2 ;;
      --no-firewall)   DO_FIREWALL=0; shift ;;
      --no-fail2ban)   DO_FAIL2BAN=0; shift ;;
      --no-acme)       DO_ACME=0; shift ;;
      --self-signed)   DO_ACME=0; DO_SELF_SIGNED_ONLY=1; shift ;;
      --yes)           ASSUME_YES=1; NONINTERACTIVE=1; shift ;;
      -h|--help)       usage; exit 0 ;;
      *)               die "неизвестный флаг: $1 (см. --help)" ;;
    esac
  done
}

confirm() { # confirm "вопрос" [default y|n]
  local q="$1" d="${2:-y}" ans
  (( ASSUME_YES )) && return 0
  local hint="[Y/n]"; [[ "$d" == n ]] && hint="[y/N]"
  read -r -p "    $q $hint " ans || true
  ans="${ans:-$d}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
need_root() {
  [[ $EUID -eq 0 ]] || die "запусти от root:  sudo bash $0"
}

detect_os() {
  step "Проверка дистрибутива"
  [[ -r /etc/os-release ]] || die "нет /etc/os-release — дистрибутив не определить"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ok "$PRETTY_NAME — поддерживается" ;;
    *)
      warn "$PRETTY_NAME: скрипт рассчитан на Debian/Ubuntu (apt)."
      confirm "Продолжить на свой риск?" n || die "прервано"
      ;;
  esac
  command -v apt-get >/dev/null || die "нет apt-get — нужен Debian/Ubuntu"
}

check_prereqs() {
  step "Предварительные проверки"
  # TUN — на LXC/OpenVZ VPS часто отсутствует, без него OpenVPN не поднимется
  if [[ ! -c /dev/net/tun ]]; then
    modprobe tun 2>/dev/null || true
    [[ -c /dev/net/tun ]] || warn "/dev/net/tun недоступен — на OpenVZ/LXC VPS OpenVPN не запустится. Попроси у хостера включить TUN/TAP."
  fi
  [[ -c /dev/net/tun ]] && ok "/dev/net/tun есть"
  # часы — TLS и OpenVPN чувствительны к времени
  if command -v timedatectl >/dev/null && ! timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
    warn "время не синхронизировано по NTP — TLS/renew может отвалиться. timedatectl set-ntp true"
  fi
  ok "архитектура: $(uname -m)"
}

# ---------------------------------------------------------------------------
valid_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# IP на интерфейсе (для обычного VPS = публичный; за NAT — приватный)
local_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true
}

# HTTP GET одним из доступных клиентов (curl на этом этапе может быть ещё
# не установлен — на свежей Debian есть wget, но не curl).
http_get() {
  if command -v curl >/dev/null; then
    curl -fsS -4 --max-time 6 "$1" 2>/dev/null
  elif command -v wget >/dev/null; then
    wget -qO- --timeout=6 --inet4-only "$1" 2>/dev/null
  else
    return 1
  fi
}

# Внешний IP, как его видят снаружи. Перебор трёх независимых сервисов
# (Cloudflare / AWS / ipify) — берём первый валидный IPv4.
external_ip() {
  local svc out
  for svc in https://icanhazip.com https://checkip.amazonaws.com https://api.ipify.org; do
    out="$(http_get "$svc" | tr -d '[:space:]' || true)"
    if valid_ipv4 "$out"; then printf '%s' "$out"; return 0; fi
  done
  return 1
}

gen_pass() { # 20 буквенно-цифровых символов, без SIGPIPE-падения под pipefail
  local out
  out="$( (LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null || true) | head -c 20 || true)"
  printf '%s' "$out"
}

prompt_config() {
  step "Параметры установки"

  # --- определить внешний IP заранее (пригодится и для домена, и для голого IP) ---
  local ext="" lan=""
  if [[ -z "$PUBLIC_IP" ]]; then
    info "Определяю публичный IP…"
    ext="$(external_ip || true)"
    lan="$(local_ip)"
    if [[ -n "$ext" && -n "$lan" && "$ext" != "$lan" ]]; then
      warn "внешний IP: $ext,  адрес интерфейса: $lan  — вероятно NAT / floating IP"
    elif [[ -n "$ext" ]]; then
      info "публичный IP: $ext"
    else
      warn "автоматически определить IP не вышло (сервисы недоступны)"
    fi
  fi

  # --- адрес: домен или IP ---
  if [[ -z "$DOMAIN" && -z "$PUBLIC_IP" ]]; then
    (( NONINTERACTIVE )) && die "в режиме --yes нужен --domain или --ip"
    info ""
    info "TLS можно выпустить на домен (надёжнее) или на этот IP"
    info "(Let's Encrypt для IP — короткоживущий профиль ~6 дней, обновляется автоматически)."
    read -r -p "    Домен (Enter — использовать IP): " DOMAIN || true
    if [[ -z "$DOMAIN" ]]; then
      if [[ -n "$ext" ]]; then
        read -r -p "    Публичный IP [$ext] (Enter — принять, или впиши правильный): " PUBLIC_IP || true
        PUBLIC_IP="${PUBLIC_IP:-$ext}"
      else
        while [[ -z "$PUBLIC_IP" ]]; do read -r -p "    Публичный IP (обязательно): " PUBLIC_IP || true; done
      fi
    fi
  fi

  if [[ -n "$DOMAIN" ]]; then
    ADDR="$DOMAIN"
    local resolved; resolved="$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')"
    if [[ -n "$resolved" && -n "$ext" && "$resolved" != "$ext" ]]; then
      warn "A-запись $DOMAIN → $resolved, а внешний IP сервера — $ext. Проверь DNS, иначе acme http-01 не пройдёт."
      confirm "Всё равно продолжить?" n || die "прервано"
    fi
  else
    [[ -n "$PUBLIC_IP" ]] || PUBLIC_IP="$ext"
    valid_ipv4 "$PUBLIC_IP" || die "не похоже на IPv4: '$PUBLIC_IP' (задай --ip или --domain)"
    ADDR="$PUBLIC_IP"
  fi
  # адрес, по которому клиенты подключаются (домен или IP) — он же в .ovpn и .env
  PUBLIC_IP="$ADDR"
  ok "адрес подключения: $ADDR"

  # --- логин/пароль панели ---
  if (( ! NONINTERACTIVE )); then
    read -r -p "    Логин панели [$PANEL_USER]: " _u || true
    PANEL_USER="${_u:-$PANEL_USER}"
  fi
  if [[ -z "$PANEL_PASS" ]]; then
    (( NONINTERACTIVE )) && die "в режиме --yes нужен --password"
    local p1 p2
    while :; do
      read -r -s -p "    Пароль панели (Enter — сгенерировать): " p1; echo
      if [[ -z "$p1" ]]; then
        p1="$(gen_pass)"
        info "сгенерирован: $p1"
        PANEL_PASS="$p1"; break
      fi
      read -r -s -p "    Ещё раз: " p2; echo
      [[ "$p1" == "$p2" ]] || { warn "не совпадает"; continue; }
      PANEL_PASS="$p1"; break
    done
  fi
  # спецсимволы ломают .env / htpasswd -b
  if [[ "$PANEL_PASS" =~ [\$\"\'\\\#\ ] ]]; then
    die "пароль содержит один из: \$ \" ' \\ # пробел — они ломают .env. Возьми другой."
  fi
  ok "панель: $PANEL_USER / (пароль задан)"

  # --- порт OpenVPN ---
  if (( ! NONINTERACTIVE )); then
    read -r -p "    UDP-порт OpenVPN наружу [$OVPN_PORT]: " _p || true
    OVPN_PORT="${_p:-$OVPN_PORT}"
  fi
  if ! [[ "$OVPN_PORT" =~ ^[0-9]+$ ]] || (( OVPN_PORT < 1 || OVPN_PORT > 65535 )); then
    die "плохой порт: $OVPN_PORT"
  fi
  ok "OpenVPN: $OVPN_PORT/udp"

  # --- каталог ---
  if (( ! NONINTERACTIVE )); then
    read -r -p "    Каталог установки [$INSTALL_DIR]: " _d || true
    INSTALL_DIR="${_d:-$INSTALL_DIR}"
  fi
  ok "каталог: $INSTALL_DIR"

  # --- email для acme ---
  if (( DO_ACME && ! NONINTERACTIVE )) && [[ -z "$ACME_EMAIL" ]]; then
    read -r -p "    E-mail для Let's Encrypt (Enter — пропустить): " ACME_EMAIL || true
  fi
  return 0
}

# ---------------------------------------------------------------------------
apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" >/dev/null
}

install_packages() {
  step "Установка зависимостей"
  apt-get update -q >/dev/null
  apt_install ca-certificates curl git openssl jq
  ok "базовые пакеты"

  if ! command -v docker >/dev/null; then
    info "ставлю Docker (get.docker.com)…"
    curl -fsSL https://get.docker.com | sh >/dev/null
    systemctl enable --now docker >/dev/null 2>&1 || true
    ok "Docker $(docker --version | awk '{print $3}' | tr -d ,)"
  else
    ok "Docker уже стоит: $(docker --version | awk '{print $3}' | tr -d ,)"
  fi
  docker compose version >/dev/null 2>&1 || die "нет 'docker compose' (плагин v2). Обнови Docker."

  if (( DO_FAIL2BAN )); then apt_install fail2ban; ok "fail2ban"; fi
  return 0
}

# ---------------------------------------------------------------------------
clone_repo() {
  step "Репозиторий"
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    ok "$INSTALL_DIR уже клонирован — git pull"
    git -C "$INSTALL_DIR" fetch -q origin
    git -C "$INSTALL_DIR" checkout -q "$GIT_BRANCH"
    git -C "$INSTALL_DIR" reset --hard -q "origin/$GIT_BRANCH"
  else
    [[ -e "$INSTALL_DIR" ]] && die "$INSTALL_DIR существует и это не git-клон — убери его или задай --dir"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone -q --branch "$GIT_BRANCH" "$REPO_URL" "$INSTALL_DIR"
    ok "клонирован $GIT_BRANCH → $INSTALL_DIR"
  fi
  cd "$INSTALL_DIR"
}

write_env() {
  step "Конфигурация (.env)"
  if [[ -f .env ]]; then
    warn ".env уже есть — не трогаю (значения ниже игнорируются). Удали его для чистой настройки."
  else
    umask 077
    cat > .env <<EOF
VPS_PUBLIC_IP=$ADDR
BASIC_AUTH_USER=$PANEL_USER
BASIC_AUTH_PASSWORD=$PANEL_PASS
OVPN_SERVER_NAME=
EOF
    umask 022
    ok ".env создан (chmod 600)"
  fi

  # нестандартный порт OpenVPN — через локальный override
  if [[ "$OVPN_PORT" != "7777" ]]; then
    cat > docker-compose.override.yaml <<EOF
services:
  openvpn:
    ports: !override ["$OVPN_PORT:1194/udp"]
  ovpn-admin:
    environment:
      OVPN_SERVER: "$ADDR:$OVPN_PORT:udp"
EOF
    ok "docker-compose.override.yaml — порт $OVPN_PORT"
  fi
  return 0
}

gen_selfsigned() {
  [[ -s nginx/ssl/fullchain.pem && -s nginx/ssl/privkey.pem ]] && return 0
  step "Временный self-signed сертификат"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout nginx/ssl/privkey.pem -out nginx/ssl/fullchain.pem \
    -subj "/CN=$ADDR" >/dev/null 2>&1
  ok "self-signed на $ADDR (заменится на Let's Encrypt ниже)"
}

compose_up() {
  step "Сборка и запуск стека (первый раз — несколько минут)"
  # --progress plain (глобальный флаг compose): без него BuildKit пытается
  # захватить консоль и падает с "failed to get console: provided file is
  # not a console" при не-TTY выводе.
  docker compose --progress plain build
  docker compose up -d --wait --wait-timeout 300
  ok "все сервисы healthy"
  docker compose ps --format 'table {{.Service}}\t{{.Status}}' | sed 's/^/    /'
}

# ---------------------------------------------------------------------------
# SSH: собрать ВСЕ порты, на которых он может слушать
# ---------------------------------------------------------------------------
ssh_ports() {
  {
    [[ -n "$SSH_CONNECTION_SAVED" ]] && awk '{print $4}' <<<"$SSH_CONNECTION_SAVED"
    sshd -T 2>/dev/null | awk '/^port /{print $2}' || true
    ss -tlnpH 2>/dev/null | awk '/users:\(\("?sshd"?/ {n=split($4,a,":"); print a[n]}' || true
    systemctl show ssh.socket -p Listen 2>/dev/null  | grep -oE '[0-9]+ \(Stream\)' | grep -oE '^[0-9]+' || true
    systemctl show sshd.socket -p Listen 2>/dev/null | grep -oE '[0-9]+ \(Stream\)' | grep -oE '^[0-9]+' || true
  } | grep -E '^[0-9]+$' | sort -un || true
}

# ---------------------------------------------------------------------------
# Файрвол: определить бэкенд
# ---------------------------------------------------------------------------
detect_firewall() {
  # ufw / firewalld — структурные, ими управляем.
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    echo ufw; return
  fi
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    echo firewalld; return
  fi
  # Свой ruleset: политика input=drop (Docker её не меняет) или сохранённые правила.
  if command -v nft >/dev/null && nft -a list chains 2>/dev/null \
       | grep -qE 'hook input .*policy drop'; then
    echo nftables; return
  fi
  if command -v iptables >/dev/null \
       && { iptables -S INPUT 2>/dev/null | grep -q '^-P INPUT DROP' \
            || [[ -s /etc/iptables/rules.v4 ]]; }; then
    echo iptables; return
  fi
  if command -v ufw >/dev/null; then echo ufw-inactive; return; fi
  echo none
}

configure_firewall() {
  (( DO_FIREWALL )) || { warn "файрвол пропущен (--no-firewall)"; return 0; }
  step "Файрвол"

  local sshp; sshp="$(ssh_ports)"
  [[ -z "$sshp" ]] && sshp=22
  info "порты SSH: $(tr '\n' ' ' <<<"$sshp")"
  info "нужно открыть: 80/tcp, 443/tcp, $OVPN_PORT/udp + SSH"

  local fw; fw="$(detect_firewall)"
  info "обнаружен файрвол: $fw"

  case "$fw" in
    ufw)
      for p in $sshp; do ufw allow "$p"/tcp >/dev/null; done
      ufw allow 80/tcp >/dev/null
      ufw allow 443/tcp >/dev/null
      ufw allow "$OVPN_PORT"/udp >/dev/null
      ok "правила добавлены в ufw"
      ;;
    firewalld)
      for p in $sshp; do firewall-cmd --permanent --add-port="$p"/tcp >/dev/null; done
      firewall-cmd --permanent --add-port=80/tcp >/dev/null
      firewall-cmd --permanent --add-port=443/tcp >/dev/null
      firewall-cmd --permanent --add-port="$OVPN_PORT"/udp >/dev/null
      firewall-cmd --reload >/dev/null
      ok "правила добавлены в firewalld"
      ;;
    ufw-inactive|none)
      if [[ "$fw" == none ]]; then
        info "активного файрвола нет."
        if confirm "Установить и настроить ufw (SSH + 80/443/$OVPN_PORT)?" y; then
          apt_install ufw
        else
          warn "файрвол не настроен. Открой 80,443/tcp и $OVPN_PORT/udp во внешнем файрволе хостера, если он есть."
          return 0
        fi
      else
        confirm "ufw установлен, но выключен. Включить с набором SSH + 80/443/$OVPN_PORT?" y || { warn "ufw не тронут"; return 0; }
      fi
      ufw --force reset >/dev/null
      ufw default deny incoming >/dev/null
      ufw default allow outgoing >/dev/null
      for p in $sshp; do ufw allow "$p"/tcp >/dev/null; done
      ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; ufw allow "$OVPN_PORT"/udp >/dev/null
      # страховка от локаута: откат через 5 минут, отменяемый после подтверждения
      command -v at >/dev/null || apt_install at 2>/dev/null || true
      systemctl enable --now atd 2>/dev/null || systemctl enable --now at 2>/dev/null || true
      if command -v at >/dev/null && systemctl is-active --quiet atd 2>/dev/null; then
        local job; job="$(echo 'ufw --force disable' | at now + 5 minutes 2>&1 | awk '/job/{print $2}')"
        ufw --force enable >/dev/null
        ok "ufw включён. ОТКАТ через 5 мин, если не подтвердишь."
        if (( ASSUME_YES )); then
          [[ -n "$job" ]] && atrm "$job" 2>/dev/null || true
        else
          warn "ОТКРОЙ НОВУЮ SSH-СЕССИЮ и убедись, что заходит."
          read -r -p "    Enter — оставить ufw включённым (или Ctrl-C — откат сработает сам): " _ || true
          [[ -n "$job" ]] && atrm "$job" 2>/dev/null || true
          ok "ufw закреплён"
        fi
      else
        ufw --force enable >/dev/null
        warn "ufw включён без страховочного таймера (пакет 'at' не поставился). Проверь SSH в новой сессии!"
      fi
      ;;
    nftables|iptables)
      warn "на сервере уже свой набор правил $fw — НЕ ТРОГАЮ его."
      info "Добавь вручную (порты для стека):"
      if [[ "$fw" == nftables ]]; then
        info "  nft add rule inet filter input tcp dport {80,443} accept"
        info "  nft add rule inet filter input udp dport $OVPN_PORT accept"
        for p in $sshp; do info "  (SSH $p/tcp уже должен быть разрешён)"; done
      else
        info "  iptables -I INPUT -p tcp -m multiport --dports 80,443 -j ACCEPT"
        info "  iptables -I INPUT -p udp --dport $OVPN_PORT -j ACCEPT"
      fi
      info "Docker сам открывает опубликованные порты через цепочку DOCKER — трафик к"
      info "контейнерам может пойти и без этих правил; они нужны, если у тебя строгий DROP в FORWARD."
      ;;
  esac
  warn "Внешний (облачный) файрвол хостера скрипт не видит — проверь там 80,443/tcp и $OVPN_PORT/udp."
}

# ---------------------------------------------------------------------------
setup_acme() {
  if (( ! DO_ACME )); then
    if (( DO_SELF_SIGNED_ONLY )); then warn "TLS: остаётся self-signed (--self-signed)"; else warn "TLS: acme пропущен (--no-acme)"; fi
    return 0
  fi
  step "TLS-сертификат (Let's Encrypt через acme.sh)"

  # acme.sh ставится в $HOME/.acme.sh; под sudo $HOME может остаться домашним
  # каталогом пользователя — фиксируем root.
  export HOME=/root
  local acme="/root/.acme.sh/acme.sh"
  if [[ ! -x "$acme" ]]; then
    info "ставлю acme.sh…"
    # get.acme.sh ждёт e-mail первым аргументом в виде "email=addr"
    # (любой --флаг первым аргументом он превращает в "----флаг" и падает).
    # Свою ошибку установки get.acme.sh проглатывает и выходит с кодом 0,
    # поэтому ниже отдельно проверяем, что бинарь реально появился.
    local ga=(); [[ -n "$ACME_EMAIL" ]] && ga=("email=$ACME_EMAIL")
    curl -fsSL https://get.acme.sh | sh -s -- "${ga[@]}" >/tmp/acme-install.log 2>&1 || true
    if [[ ! -x "$acme" ]]; then
      sed 's/^/    /' /tmp/acme-install.log >&2 || true
      die "не смог поставить acme.sh (лог: /tmp/acme-install.log)"
    fi
  fi
  ok "acme.sh $("$acme" --version 2>/dev/null | tail -1)"

  local issue_args=(--issue --server letsencrypt -d "$ADDR"
    -w "$INSTALL_DIR/nginx/acme" --keylength ec-256
    --fullchain-file "$INSTALL_DIR/nginx/ssl/fullchain.pem"
    --key-file       "$INSTALL_DIR/nginx/ssl/privkey.pem"
    --reloadcmd      "docker exec $NGINX_CONTAINER nginx -s reload")

  if [[ -z "$DOMAIN" ]]; then
    # голый IP — только короткоживущий профиль Let's Encrypt
    issue_args+=(--cert-profile shortlived)
    info "IP-сертификат: профиль 'shortlived' (~6 дней, авто-renew через крон acme.sh)"
  fi

  # accountDoesNotExist сразу после регистрации и прочие временные 5xx/JWS от
  # Let's Encrypt лечатся повтором — даём до трёх попыток.
  local rc=0 attempt
  for attempt in 1 2 3; do
    rc=0
    "$acme" "${issue_args[@]}" >/tmp/acme-issue.log 2>&1 || rc=$?
    (( rc == 0 || rc == 2 )) && break
    (( attempt == 3 )) && break
    warn "acme.sh: попытка $attempt не удалась (код $rc) — повтор через 15 с"
    sleep 15
  done
  case "$rc" in
    0)
      ok "сертификат выпущен и подставлен, nginx перезагружен"
      "$acme" --upgrade --auto-upgrade >/dev/null 2>&1 || true
      ;;
    2)
      # acme.sh: домены не изменились, действующий сертификат ещё живой
      ok "сертификат уже выпущен и действует — продлится по крону acme.sh"
      ;;
    *)
      warn "acme.sh не смог выпустить сертификат — остаётся текущий (self-signed). Лог: /tmp/acme-issue.log"
      warn "Частые причины: DNS не указывает сюда, порт 80 закрыт снаружи, для IP — лимиты Let's Encrypt."
      ;;
  esac
}

# ---------------------------------------------------------------------------
setup_fail2ban() {
  (( DO_FAIL2BAN )) || { warn "fail2ban пропущен (--no-fail2ban)"; return 0; }
  step "fail2ban (бан перебора Basic Auth панели)"
  install -m644 "$INSTALL_DIR/fail2ban/action.d/docker-user.conf" /etc/fail2ban/action.d/docker-user.conf
  sed "s#^logpath.*#logpath   = $INSTALL_DIR/nginx/f2b-log/error.log#" \
    "$INSTALL_DIR/fail2ban/jail.d/ovpn-stack.local" > /etc/fail2ban/jail.d/ovpn-stack.local
  systemctl restart fail2ban
  sleep 1
  if fail2ban-client status nginx-http-auth >/dev/null 2>&1; then
    ok "джейл nginx-http-auth активен"
  else
    warn "джейл не поднялся — проверь: fail2ban-client status nginx-http-auth"
  fi
}

# ---------------------------------------------------------------------------
summary() {
  step "Готово"

  local url="https://$ADDR/" u p
  # логин/пароль — из .env (источник истины; на повторном запуске переменные
  # PANEL_* могут не совпадать с уже записанным .env)
  u="$(sed -n 's/^BASIC_AUTH_USER=//p'     "$INSTALL_DIR/.env" 2>/dev/null)"; u="${u:-$PANEL_USER}"
  p="$(sed -n 's/^BASIC_AUTH_PASSWORD=//p' "$INSTALL_DIR/.env" 2>/dev/null)"; p="${p:-$PANEL_PASS}"

  local tls="Let's Encrypt"
  (( DO_ACME )) || tls="self-signed (браузер будет ругаться на сертификат)"

  local text
  text="$(cat <<EOF
ovpn-stack — доступ и памятка
=============================

Панель управления
  Адрес:  $url
  Логин:  $u
  Пароль: $p
  (Basic Auth — окно входа в браузере)

OpenVPN
  Сервер: $ADDR
  Порт:   $OVPN_PORT/udp
  Подключение: панель → создать пользователя → скачать .ovpn →
               импортировать в клиент OpenVPN

TLS-сертификат: $tls

Каталог установки: $INSTALL_DIR

Управление (из каталога установки):
  docker compose ps                          статус сервисов
  docker compose logs -f ovpn-admin          логи панели
  git pull && docker compose up -d --build    обновление

Бэкап: $INSTALL_DIR/data/ — вся PKI и учёт трафика.
       Без этого каталога выпущенные .ovpn восстановить нельзя.

Документация: $INSTALL_DIR/docs/
Сгенерировано: $(date '+%Y-%m-%d %H:%M %Z')
EOF
)"

  printf '%s\n' "$text" | sed 's/^/    /'

  # та же памятка файлом в домашний каталог пользователя (с паролем → chmod 600)
  local owner="${SUDO_USER:-root}" home
  home="$(getent passwd "$owner" | cut -d: -f6)"
  [[ -d "$home" ]] || { owner=root; home=/root; }
  local sprav="$home/ovpn-stack-справка.txt"
  if printf '%s\n' "$text" > "$sprav" 2>/dev/null; then
    chmod 600 "$sprav"
    chown "$owner:" "$sprav" 2>/dev/null || true
    ok "памятка с логином и паролем сохранена: $sprav"
  else
    warn "не удалось записать памятку в $sprav (логин/пароль см. в $INSTALL_DIR/.env)"
  fi

  (( DO_ACME )) || warn "Сейчас self-signed — нормальный сертификат: см. README, раздел «TLS»."
}

# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  need_root
  detect_os
  check_prereqs
  prompt_config

  step "Сводка перед установкой"
  info "адрес подключения  $ADDR"
  info "панель  . . . . $PANEL_USER"
  info "OpenVPN порт  . $OVPN_PORT/udp"
  info "каталог . . . . $INSTALL_DIR"
  info "TLS . . . . . . $( ((DO_ACME)) && echo "Let's Encrypt ($( [[ -n $DOMAIN ]] && echo домен || echo IP/shortlived ))" || echo self-signed )"
  info "файрвол . . . . $( ((DO_FIREWALL)) && echo да || echo нет )    fail2ban: $( ((DO_FAIL2BAN)) && echo да || echo нет )"
  confirm "Начать установку?" y || die "отменено"

  install_packages
  clone_repo
  write_env
  gen_selfsigned
  compose_up
  configure_firewall
  setup_acme
  setup_fail2ban
  summary
}

main "$@"
