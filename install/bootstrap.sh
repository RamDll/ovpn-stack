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

# копия файла в <file>.bak.<epoch> с обрезкой истории до последних 3 —
# скрипт идемпотентный и запускается много раз, иначе в sshd_config.d/
# накапливаются десятки .bak.* (безвредны для sshd, но мусор)
backup_capped() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  cp -a "$file" "${file}.bak.$(date +%s)"
  local old
  mapfile -t old < <(ls -1t "${file}".bak.* 2>/dev/null | tail -n +4)
  [[ ${#old[@]} -gt 0 ]] && rm -f -- "${old[@]}"
  return 0
}

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

APT_OPTS=(-o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold)

# Свежий VPS в первые минуты держит dpkg-lock под cloud-init / apt-daily /
# unattended-upgrades. Вместо того чтобы ждать, пока они отвоюют lock, —
# останавливаем их таймеры и сервисы: наш apt берёт lock сразу. Свой
# unattended-upgrades скрипт настраивает заново дальше по ходу.
stop_apt_daily() {
  systemctl stop --no-block \
    apt-daily.timer apt-daily-upgrade.timer \
    apt-daily.service apt-daily-upgrade.service \
    unattended-upgrades.service >/dev/null 2>&1 || true
}

# после stop_apt_daily lock обычно свободен за секунды; ждём коротко — вдруг
# уже запущенный apt/dpkg (cloud-init) ещё дорабатывает. Потом пробуем всё
# равно — apt подождёт остаток сам (DPkg::Lock::Timeout).
wait_dpkg_lock() {
  local w=0 max=180
  while pgrep -x 'apt|apt-get|dpkg|aptitude|unattended-upgr|packagekitd' >/dev/null 2>&1 \
     || fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
    (( w >= max )) && { log "dpkg-lock ещё занят после ${max}с — пробую всё равно (apt подождёт сам)"; return 0; }
    (( w % 20 == 0 )) && log "dpkg-lock занят (cloud-init) — жду... ${w}/${max}с"
    sleep 5; w=$((w + 5))
  done
  (( w > 0 )) && log "dpkg-lock освободился за ${w}с"
  return 0
}

# apt с ретраями — на свежем сервере lock может перехватиться между командами
apt_do() {
  local try
  for try in 1 2 3; do
    wait_dpkg_lock
    if apt-get "${APT_OPTS[@]}" "$@"; then return 0; fi
    log "apt-get $* — попытка $try не удалась, жду 20с и повторяю"
    sleep 20
  done
  die "apt-get $* не прошёл после 3 попыток (dpkg-lock/сеть?)"
}
# Сборка образа ovpn-admin (vue-tsc + vite build фронта, go build бэка) на
# < ~2 ГБ RAM без swap ловит OOM-kill. Если памяти мало и swap не активен —
# делаем /swapfile 2 ГБ. Идемпотентно; на OpenVZ/LXC (swapon не поддержан)
# тихо продолжаем без него.
SWAPFILE=/swapfile
ensure_swap() {
  local mem_kb mem_mb
  mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  mem_mb=$(( mem_kb / 1024 ))
  local swap_kb
  swap_kb=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)

  if (( mem_mb >= 1900 )); then
    log "RAM ${mem_mb} МБ — swap не нужен"
    return 0
  fi
  if (( swap_kb > 512 * 1024 )); then
    log "RAM ${mem_mb} МБ, но swap уже есть ($(( swap_kb / 1024 )) МБ) — оставляю как есть"
    return 0
  fi
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
    log "$SWAPFILE уже подключён"
    return 0
  fi

  local free_mb
  free_mb=$(df -Pm / | awk 'NR==2{print $4}')
  if (( free_mb < 2600 )); then
    log "RAM ${mem_mb} МБ, но на / всего ${free_mb} МБ свободно — swap не делаю (сборка образов может упасть по памяти)"
    return 0
  fi

  log "RAM ${mem_mb} МБ — создаю ${SWAPFILE} 2 ГБ (иначе сборка ovpn-admin рискует OOM)"
  rm -f "$SWAPFILE"
  if ! fallocate -l 2G "$SWAPFILE" 2>/dev/null; then
    dd if=/dev/zero of="$SWAPFILE" bs=1M count=2048 status=none
  fi
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE" >/dev/null
  if ! swapon "$SWAPFILE" 2>/dev/null; then
    log "swapon не сработал (OpenVZ/LXC без поддержки swap?) — продолжаю без swap"
    rm -f "$SWAPFILE"
    return 0
  fi
  grep -qxF "$SWAPFILE none swap sw 0 0" /etc/fstab || echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
  printf 'vm.swappiness = 10\n' > /etc/sysctl.d/99-ovpn-stack-swap.conf
  sysctl -q -p /etc/sysctl.d/99-ovpn-stack-swap.conf 2>/dev/null || true
  log "swap подключён: $(swapon --show=NAME,SIZE --noheadings 2>/dev/null | tr '\n' ' ')"
}

# префикс 00- — чтобы наш drop-in читался ПЕРВЫМ: для большинства
# директив sshd берёт первое вхождение, а cloud-init кладёт
# 50-cloud-init.conf с «PasswordAuthentication yes», который иначе
# побеждает. Старое имя (99-) сносим при харднинге и откате.
DROPIN_SSHD=/etc/ssh/sshd_config.d/00-ovpn-stack.conf
DROPIN_SSHD_LEGACY=/etc/ssh/sshd_config.d/99-ovpn-stack.conf
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

  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a

  log "останавливаю apt-daily / unattended-upgrades, чтобы не воевали за dpkg-lock"
  stop_apt_daily

  # если прошлый прогон прервали посреди apt — привести dpkg в порядок
  wait_dpkg_lock
  dpkg --configure -a >/dev/null 2>&1 || true

  log "apt update"
  apt_do update -qq

  log "apt dist-upgrade"
  apt_do -y dist-upgrade -qq

  # инструменты, без которых установщик не отработает независимо от режима:
  # sudo (управление), nftables (firewall, шаг 3), python3 (правка x-ui.db /
  # JSON в install-vpn.sh). Обычно в Debian есть, но минимальные образы
  # некоторых хостеров их вырезают — тогда установка падала посреди процесса
  # ("nft: command not found" и т.п.).
  local need=() b
  for b in sudo:sudo nft:nftables python3:python3; do
    command -v "${b%%:*}" >/dev/null 2>&1 || need+=("${b#*:}")
  done
  if [[ ${#need[@]} -gt 0 ]]; then
    log "доставляю: ${need[*]}"
    apt_do -y install -qq "${need[@]}"
  else
    log "sudo / nftables / python3 уже на месте"
  fi

  ensure_swap

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
    apt_do -y install -qq unattended-upgrades
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
  # вернуть apt-daily таймеры, которые останавливали в начале (наш apt уже
  # отработал) — иначе авто-security-обновления не запустятся до ребута
  systemctl start apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

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

  # подстраховка: system-prep обычно ставит nftables, но если сюда пришли
  # без него (прямой вызов / минимальный образ) — доставить, иначе nft ниже
  # упадёт "command not found".
  if ! command -v nft >/dev/null 2>&1; then
    log "nft не найден — ставлю nftables"
    export DEBIAN_FRONTEND=noninteractive
    apt_do -y install -qq nftables
  fi

  local tmpl="$INSTALL_DIR/install/templates/nftables.conf.tmpl"
  [[ -f "$tmpl" ]] || die "не найден шаблон $tmpl"

  local vless_block=""
  if [[ "$mode" == "vless" || "$mode" == "all" ]]; then
    # 3x-ui слушает 0.0.0.0 на 2053 (панель) и 2096 (sub-сервер) —
    # 127.0.0.1 недостижим из netns nginx, см. install-vpn.sh xui-configure.
    # Поэтому в INPUT, а не только в forward: пускаем оба порта исключительно
    # с docker-интерфейсов (nginx проксирует их на :8443 по неочевидным
    # путям), наружу в интернет они закрыты политикой drop.
    vless_block="        tcp dport 443 accept  # Xray (3x-ui) — VLESS Reality\n        iifname \"docker0\" tcp dport 2053 accept  # 3x-ui панель — только для nginx-прокси\n        iifname \"br-*\" tcp dport 2053 accept\n        iifname \"docker0\" tcp dport 2096 accept  # 3x-ui sub-сервер — только для nginx-прокси\n        iifname \"br-*\" tcp dport 2096 accept"
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

  backup_capped "$DROPIN_SSHD"
  rm -f "$DROPIN_SSHD_LEGACY"

  cat > "$DROPIN_SSHD" <<EOF
# управляется install/bootstrap.sh — не редактировать руками
Port ${port}
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
KbdInteractiveAuthentication no
EOF

  # Заглушаем конкурирующие «yes» в остальных конфигах. sshd берёт первое
  # вхождение директивы, а cloud-init/образ провайдера часто кладёт
  # 50-cloud-init.conf с «PasswordAuthentication yes» или правит сам
  # /etc/ssh/sshd_config — тогда наш drop-in игнорируется даже с 00-.
  local cf
  for cf in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "$cf" && "$cf" != "$DROPIN_SSHD" ]] || continue
    grep -qiE '^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PermitRootLogin)[[:space:]]+yes' "$cf" || continue
    backup_capped "$cf"
    sed -ri 's/^([[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PermitRootLogin)[[:space:]]+yes.*)/# \1  # off: ovpn-stack/I' "$cf"
    log "заглушил доступ по паролю/root в $cf"
  done

  if socket_active; then
    log "обнаружена socket-активация ssh.socket (trixie) — правлю ListenStream"
    mkdir -p "$SOCKET_DROPIN_DIR"
    backup_capped "$SOCKET_DROPIN"
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

  # авторитетная проверка: что реально видит sshd после всех drop-in
  local sshd_eff pw_eff root_eff
  sshd_eff="$(sshd -T 2>/dev/null || true)"
  pw_eff="$(awk '$1=="passwordauthentication"{print $2}' <<<"$sshd_eff")"
  root_eff="$(awk '$1=="permitrootlogin"{print $2}' <<<"$sshd_eff")"
  if [[ "$pw_eff" != "no" || "$root_eff" == "yes" ]]; then
    log "ВНИМАНИЕ: sshd -T показывает passwordauthentication=$pw_eff permitrootlogin=$root_eff —"
    log "доступ по паролю НЕ закрыт. Конкурирующие строки (закомментируй вручную):"
    grep -rniE '^[[:space:]]*(PasswordAuthentication|PermitRootLogin)[[:space:]]+(yes|prohibit-password)' \
      /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | grep -vF "$DROPIN_SSHD" \
      | while read -r l; do log "  $l"; done || true
  else
    log "sshd -T подтверждает: доступ по паролю выключен, root закрыт"
  fi

  log "sshd-harden готово, новый порт $port слушает локально — жду sshd-confirm с домашнего ПК (иначе откат через 5 мин)"
}

cmd_sshd_confirm() { cancel_safety_rollback sshd; }

cmd_sshd_rollback() {
  need_root sshd-rollback
  log "откатываю правки sshd к дефолту"
  rm -f "$DROPIN_SSHD" "$DROPIN_SSHD_LEGACY"
  rm -f "$SOCKET_DROPIN"
  # восстанавливаем самый свежий бэкап конфигов, которые правил sed-ом
  local cf bak
  for cf in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    bak="$(ls -1t "${cf}".bak.* 2>/dev/null | head -1)" || true
    [[ -n "$bak" && -f "$bak" ]] && { cp -a "$bak" "$cf"; log "восстановил $cf из $bak"; }
  done
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
