#!/usr/bin/env bash
#
# bootstrap.sh — шаги 1-3 установки (система, SSH, firewall).
# Выполняется НА СЕРВЕРЕ, вызывается удалённо из setup.sh (домашний ПК)
# через ssh, по одной подкоманде за раз. Ничего не знает про VPN —
# чистая подготовка Debian-хоста. См. install/README.md, разделы 5-7.
#
# Использование:
#   bootstrap.sh <subcommand> [args...]
#
# Подкоманды, требующие root, проверяют EUID сами — им всё равно,
# вызваны они напрямую по root-сессии или через `sudo -S`.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
log()  { printf '[bootstrap] %s\n' "$*" >&2; }
die()  { printf '[bootstrap] ОШИБКА: %s\n' "$*" >&2; exit 1; }
need_root() { [[ "$(id -u)" -eq 0 ]] || die "подкоманда '$1' требует root (запусти через sudo)"; }

# ---------------------------------------------------------------------------
# страховка «проверка перед разрушением» (принцип 4): перед любой правкой,
# способной отрезать SSH (nftables, sshd), ставим self-timer на откат через
# 5 минут. Если домашний ПК подтвердит новое соединение — таймер снимается
# командой *-confirm. Не подтвердили вовремя — сервер откатится сам.
schedule_safety_rollback() {
  local name="$1" cmd="$2"
  systemd-run --unit="ovpn-stack-safety-${name}" --on-active=300 \
    --description="ovpn-stack: автооткат ${name}, если не подтверждено" \
    /bin/bash -c "$cmd" >/dev/null
  log "страховочный таймер '${name}' поставлен на 5 минут"
}
cancel_safety_rollback() {
  local name="$1"
  systemctl stop "ovpn-stack-safety-${name}.timer" >/dev/null 2>&1 || true
  systemctl reset-failed "ovpn-stack-safety-${name}.service" >/dev/null 2>&1 || true
  log "страховочный таймер '${name}' снят — изменение подтверждено"
}

APT_OPTS=(-o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confold)
DROPIN_SSHD=/etc/ssh/sshd_config.d/99-ovpn-stack.conf
SOCKET_DROPIN_DIR=/etc/systemd/system/ssh.socket.d
SOCKET_DROPIN=$SOCKET_DROPIN_DIR/99-ovpn-stack.conf
NFTABLES_CONF=/etc/nftables.conf
STATE_DIR=/opt/ovpn-stack/state
INSTALL_DIR=/opt/ovpn-stack

# ---------------------------------------------------------------------------
# шаг 1 — подготовка системы
# ---------------------------------------------------------------------------
cmd_system_prep() {
  need_root system-prep
  mkdir -p "$STATE_DIR"

  log "жду освобождения dpkg-lock (cloud-init мог его занять)"
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a

  log "apt update"
  apt-get "${APT_OPTS[@]}" update -qq

  log "apt dist-upgrade"
  apt-get "${APT_OPTS[@]}" -y dist-upgrade -qq

  if ! command -v sudo >/dev/null 2>&1; then
    log "ставлю sudo (на минимальных образах его нет)"
    apt-get "${APT_OPTS[@]}" -y install -qq sudo
  else
    log "sudo уже установлен"
  fi

  log "часовой пояс Europe/Moscow"
  timedatectl set-timezone Europe/Moscow

  if ! systemctl is-active --quiet systemd-timesyncd; then
    log "включаю systemd-timesyncd"
    systemctl enable --now systemd-timesyncd
  fi
  # даём синку до 10с — расхождение времени ломает TLS-хендшейк Reality
  for _ in $(seq 1 10); do
    timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes && break
    sleep 1
  done
  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ]]; then
    log "предупреждение: время ещё не синхронизировано (NTPSynchronized=no), продолжаю"
  fi

  log "unattended-upgrades (только security, авто-ребут 04:00)"
  if ! dpkg -l unattended-upgrades >/dev/null 2>&1; then
    apt-get "${APT_OPTS[@]}" -y install -qq unattended-upgrades
  fi

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

  # только security-источник — вычищаем остальные Origins-Pattern,
  # оставляя ровно один; идемпотентно перезаписываем весь блок.
  local uu_conf=/etc/apt/apt.conf.d/50unattended-upgrades-ovpn-stack.conf
  cat > "$uu_conf" <<'EOF'
// Управляется install/bootstrap.sh — не редактировать руками.
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF

  systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
  # таймер апстрима не должен стартовать параллельно с нашим apt прямо сейчас
  if systemctl is-active --quiet apt-daily-upgrade.timer 2>/dev/null; then
    log "apt-daily-upgrade.timer активен (штатно, сработает по расписанию)"
  fi

  log "system-prep готово"
}

cmd_reboot_if_needed() {
  need_root reboot-if-needed
  if [[ -f /var/run/reboot-required ]]; then
    log "требуется ребут (обновилось ядро) — планирую через 2с"
    # отвязываем от текущей ssh-сессии, чтобы команда успела вернуть управление
    nohup bash -c 'sleep 2 && systemctl reboot' >/dev/null 2>&1 &
    disown || true
    echo "REBOOTING"
  else
    echo "NO_REBOOT_NEEDED"
  fi
}

# ---------------------------------------------------------------------------
# шаг 1.7-1.8 — пользователь
# ---------------------------------------------------------------------------
cmd_user_create() {
  need_root user-create
  local username="${1:?usage: user-create <username> (пароль на stdin)}"

  if id "$username" >/dev/null 2>&1; then
    log "пользователь $username уже существует — не трогаю учётку"
  else
    log "создаю пользователя $username"
    useradd -m -s /bin/bash "$username"
  fi

  # пароль через chpasswd (stdin), НЕ useradd -p — иначе виден в ps
  local password
  IFS= read -r password
  [[ -n "$password" ]] || die "пустой пароль пользователя на stdin"
  printf '%s:%s\n' "$username" "$password" | chpasswd

  if ! id -nG "$username" | tr ' ' '\n' | grep -qx sudo; then
    log "добавляю $username в группу sudo"
    usermod -aG sudo "$username"
  else
    log "$username уже в группе sudo"
  fi

  # отдельная проверка членства — до первого реального использования sudo
  if ! id -nG "$username" | tr ' ' '\n' | grep -qx sudo; then
    die "usermod -aG sudo не сработал для $username — останавливаюсь"
  fi

  mkdir -p "$INSTALL_DIR"
  chown "$username:$username" "$INSTALL_DIR"
  mkdir -p "$STATE_DIR"

  log "user-create готово"
}

# ---------------------------------------------------------------------------
# шаг 2.2 — публичный ключ в authorized_keys (дописать, не перезаписать)
# ---------------------------------------------------------------------------
cmd_install_authorized_key() {
  need_root install-authorized-key
  local username="${1:?usage: install-authorized-key <username>}"
  local pubkey
  IFS= read -r pubkey
  [[ -n "$pubkey" ]] || die "пустой публичный ключ на stdin"

  id "$username" >/dev/null 2>&1 || die "пользователь $username не существует"
  local home; home=$(getent passwd "$username" | cut -d: -f6)
  local ssh_dir="$home/.ssh"
  local ak_file="$ssh_dir/authorized_keys"

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  touch "$ak_file"
  chmod 600 "$ak_file"

  if grep -qxF "$pubkey" "$ak_file" 2>/dev/null; then
    log "публичный ключ уже есть в authorized_keys — не дублирую"
  else
    printf '%s\n' "$pubkey" >> "$ak_file"
    log "публичный ключ добавлен в authorized_keys"
  fi

  chown -R "$username:$username" "$ssh_dir"
  log "install-authorized-key готово"
}

# ---------------------------------------------------------------------------
# шаг 3 — nftables
# ---------------------------------------------------------------------------
port_in_use() {
  local port="$1"
  ss -H -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
}

cmd_check_port_free() {
  local port="${1:?usage: check-port-free <port>}"
  if [[ "$port" == "443" ]]; then
    echo "BUSY"; return 0
  fi
  if port_in_use "$port"; then echo "BUSY"; else echo "FREE"; fi
}

# nftables-apply <ssh_port> <mode:vless|openvpn|all> [ovpn_udp_port]
cmd_nftables_apply() {
  need_root nftables-apply
  local ssh_port="${1:?usage: nftables-apply <ssh_port> <mode> [ovpn_udp_port]}"
  local mode="${2:?mode required: vless|openvpn|all}"
  local ovpn_port="${3:-}"
  mkdir -p "$STATE_DIR"

  local tmpl="$INSTALL_DIR/install/templates/nftables.conf.tmpl"
  [[ -f "$tmpl" ]] || die "не найден шаблон $tmpl"

  local vless_block=""
  if [[ "$mode" == "vless" || "$mode" == "all" ]]; then
    vless_block="        tcp dport 443 accept  # Xray (3x-ui) — VLESS Reality"
  fi

  local ovpn_block=""
  if [[ "$mode" == "openvpn" || "$mode" == "all" ]]; then
    [[ -n "$ovpn_port" ]] || die "режим $mode требует ovpn_udp_port"
    ovpn_block="        udp dport ${ovpn_port} accept  # OpenVPN"
  fi

  local rendered
  rendered=$(mktemp)
  sed \
    -e "s/@@SSH_PORT@@/${ssh_port}/g" \
    -e "s/@@VLESS_RULE@@/${vless_block//\//\\/}/g" \
    -e "s/@@OPENVPN_RULE@@/${ovpn_block//\//\\/}/g" \
    "$tmpl" > "$rendered"

  log "проверяю синтаксис нового ruleset (nft -c -f)"
  nft -c -f "$rendered" || { rm -f "$rendered"; die "nft -c -f не прошёл, ничего не применяю"; }

  local backup=""
  if [[ -f "$NFTABLES_CONF" ]]; then
    backup="${NFTABLES_CONF}.bak.$(date +%s)"
    cp -a "$NFTABLES_CONF" "$backup"
  fi
  echo "${backup}" > "$STATE_DIR/nftables-last-backup"
  install -m 0644 "$rendered" "$NFTABLES_CONF"
  rm -f "$rendered"

  schedule_safety_rollback nftables "/bin/bash $(readlink -f "$0") nftables-rollback"

  log "применяю ruleset"
  nft -f "$NFTABLES_CONF" || { cmd_nftables_rollback; die "nft -f упал после успешной -c -f проверки — откатил"; }

  # flush ruleset стирает и собственные NAT/MASQUERADE-правила Docker (он
  # добавляет их сам при старте демона, не отслеживает внешние изменения
  # firewall) — без ребута dockerd контейнеры остаются без сети до
  # следующего его собственного запуска. Идемпотентный повторный прогон
  # именно поэтому ловил "DNS: transient error" при сборке образов.
  if systemctl is-active --quiet docker 2>/dev/null; then
    log "перезапускаю docker — flush ruleset стёр его NAT-правила, dockerd сам их не восстановит"
    systemctl restart docker
  fi

  systemctl enable nftables >/dev/null 2>&1 || true
  log "nftables-apply готово (ssh_port=$ssh_port mode=$mode) — жду nftables-confirm с домашнего ПК"
}

# откат: если бэкап есть — вернуть его, иначе снять политику drop совсем
# (полностью открытый вход лучше потерянного сервера — принцип «неразрушающесть»)
cmd_nftables_rollback() {
  need_root nftables-rollback
  local backup=""
  [[ -f "$STATE_DIR/nftables-last-backup" ]] && backup=$(cat "$STATE_DIR/nftables-last-backup")
  if [[ -n "$backup" && -f "$backup" ]]; then
    log "откатываю nftables к $backup"
    nft -f "$backup" && cp -a "$backup" "$NFTABLES_CONF"
  else
    log "бэкапа нет (первый прогон) — открываю вход полностью (nft flush ruleset)"
    nft flush ruleset
  fi
  log "nftables-rollback готово"
}

cmd_nftables_confirm() { cancel_safety_rollback nftables; }

# ---------------------------------------------------------------------------
# шаг 2.5-2.8 — sshd hardening
# ---------------------------------------------------------------------------
socket_active() {
  systemctl list-unit-files ssh.socket >/dev/null 2>&1 && \
    systemctl is-enabled --quiet ssh.socket 2>/dev/null
}

# sshd-harden <new_port>
cmd_sshd_harden() {
  need_root sshd-harden
  local port="${1:?usage: sshd-harden <new_port>}"
  mkdir -p "$STATE_DIR"

  [[ -f "$DROPIN_SSHD" ]] && cp -a "$DROPIN_SSHD" "${DROPIN_SSHD}.bak.$(date +%s)"

  cat > "$DROPIN_SSHD" <<EOF
# управляется install/bootstrap.sh — не редактировать руками
Port ${port}
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
KbdInteractiveAuthentication no
EOF

  if socket_active; then
    log "обнаружена socket-активация ssh.socket (trixie) — правлю ListenStream"
    mkdir -p "$SOCKET_DROPIN_DIR"
    [[ -f "$SOCKET_DROPIN" ]] && cp -a "$SOCKET_DROPIN" "${SOCKET_DROPIN}.bak.$(date +%s)"
    cat > "$SOCKET_DROPIN" <<EOF
# управляется install/bootstrap.sh — не редактировать руками
[Socket]
ListenStream=
ListenStream=${port}
EOF
    echo socket > "$STATE_DIR/sshd-mode"
  else
    log "socket-активация не используется — обычный ssh.service"
    echo service > "$STATE_DIR/sshd-mode"
  fi

  log "проверяю конфиг (sshd -t)"
  if ! sshd -t; then
    log "sshd -t провалился — откатываю drop-in, ничего не перезапускаю"
    cmd_sshd_rollback
    die "sshd -t не прошёл, откат выполнен"
  fi

  schedule_safety_rollback sshd "/bin/bash $(readlink -f "$0") sshd-rollback"

  systemctl daemon-reload
  if [[ "$(cat "$STATE_DIR/sshd-mode" 2>/dev/null)" == "socket" ]]; then
    systemctl restart ssh.socket
    systemctl restart ssh.service 2>/dev/null || systemctl restart ssh 2>/dev/null || true
  else
    systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || systemctl restart ssh
  fi

  # локальная проверка на самом сервере — не ждём внешнего соединения,
  # это ловит промах с socket-активацией/портом ещё до звонка домой
  local up=0
  for _ in $(seq 1 10); do
    if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then exec 3<&- 3>&-; up=1; break; fi
    sleep 1
  done
  if [[ "$up" -ne 1 ]]; then
    log "новый порт $port не слушает даже локально — откатываю немедленно"
    cmd_sshd_rollback
    die "sshd не поднялся на новом порту, откат выполнен"
  fi

  log "sshd-harden готово, новый порт $port слушает локально — жду sshd-confirm с домашнего ПК (иначе откат через 5 мин)"
}

cmd_sshd_confirm() { cancel_safety_rollback sshd; }

cmd_sshd_rollback() {
  need_root sshd-rollback
  log "откатываю правки sshd к дефолту"
  rm -f "$DROPIN_SSHD"
  rm -f "$SOCKET_DROPIN"
  systemctl daemon-reload
  systemctl restart ssh.socket 2>/dev/null || true
  systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || systemctl restart ssh 2>/dev/null || true
  log "sshd-rollback готово — доступ по паролю/root снова как было"
}

# ---------------------------------------------------------------------------
main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    system-prep)            cmd_system_prep "$@" ;;
    reboot-if-needed)       cmd_reboot_if_needed "$@" ;;
    user-create)            cmd_user_create "$@" ;;
    install-authorized-key) cmd_install_authorized_key "$@" ;;
    check-port-free)        cmd_check_port_free "$@" ;;
    nftables-apply)         cmd_nftables_apply "$@" ;;
    nftables-rollback)      cmd_nftables_rollback "$@" ;;
    nftables-confirm)       cmd_nftables_confirm "$@" ;;
    sshd-harden)             cmd_sshd_harden "$@" ;;
    sshd-rollback)           cmd_sshd_rollback "$@" ;;
    sshd-confirm)            cmd_sshd_confirm "$@" ;;
    *) die "неизвестная подкоманда: '$sub'" ;;
  esac
}

main "$@"
