#!/usr/bin/env bash
#
# install-vpn.sh — шаги 4-6 установки (Docker, сервисы, первый VLESS-инбаунд,
# сводка). Выполняется НА СЕРВЕРЕ, вызывается удалённо из setup.sh по одной
# подкоманде за раз, уже по ключевой SSH-сессии от имени sudo-пользователя
# (после того как bootstrap.sh закрыл root и старый парольный вход).
# См. install/README.md, разделы 8-10.
#
# Использование:
#   install-vpn.sh <subcommand> [args...]

set -Eeuo pipefail

log()  { printf '[install-vpn] %s\n' "$*" >&2; }
die()  { printf '[install-vpn] ОШИБКА: %s\n' "$*" >&2; exit 1; }
need_root() { [[ "$(id -u)" -eq 0 ]] || die "подкоманда '$1' требует root (запусти через sudo)"; }

REPO_URL="https://github.com/RamDll/ovpn-stack.git"
INSTALL_DIR=/opt/ovpn-stack
RENDER_DIR="$INSTALL_DIR/install-render"
TMPL_DIR="$INSTALL_DIR/install/templates"
STATE_DIR="$INSTALL_DIR/state"
ACME_HOME="$INSTALL_DIR/.acme.sh"
ACME_BIN="$ACME_HOME/acme.sh"
ACME_TAG="3.1.4"   # пин версии — никаких curl|sh с апстрима, только git clone на тег.
                    # 3.0.9 не умеет --cert-profile (нужен для IP-сертификатов
                    # Let's Encrypt, профиль появился в 3.1.2+)

# ---------------------------------------------------------------------------
# шаг 4.0 — Docker (репозиторий apt, БЕЗ convenience-скрипта get.docker.com —
# это ровно тот `curl | sh`, который запрещён принципом 5)
# ---------------------------------------------------------------------------
cmd_docker_install() {
  need_root docker-install
  if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
    log "Docker уже установлен — пропускаю"
    return 0
  fi

  log "ставлю зависимости"
  apt-get -o DPkg::Lock::Timeout=120 -y install -qq ca-certificates curl gnupg

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  local codename
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable
EOF

  apt-get -o DPkg::Lock::Timeout=120 update -qq
  apt-get -o DPkg::Lock::Timeout=120 -y install -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  log "Docker установлен"
}

cmd_docker_group_add() {
  need_root docker-group-add
  local username="${1:?usage: docker-group-add <username>}"
  if id -nG "$username" | tr ' ' '\n' | grep -qx docker; then
    log "$username уже в группе docker"
  else
    usermod -aG docker "$username"
    log "$username добавлен в группу docker (переподключение по SSH подхватит группу)"
  fi
}

# ---------------------------------------------------------------------------
# репозиторий стека — берём отсюда admin/ (openvpn + ovpn-admin) build context
# ---------------------------------------------------------------------------
cmd_repo_sync() {
  local git_url="${1:-$REPO_URL}"
  local branch="${2:-master}"

  mkdir -p "$INSTALL_DIR"
  if [[ ! -d "$INSTALL_DIR/.git" ]]; then
    # НЕ git clone: к этому моменту в $INSTALL_DIR уже могли появиться
    # state/ и другие наши каталоги (user-create создаёт state/ ещё в root-
    # фазе) — git clone требует пустую директорию. init+fetch+checkout
    # тот же результат, но переживает непустой каталог.
    log "инициализирую git в $INSTALL_DIR ($git_url, $branch)"
    git -C "$INSTALL_DIR" init -q
    git -C "$INSTALL_DIR" remote add origin "$git_url"
  fi
  log "git fetch $branch"
  git -C "$INSTALL_DIR" fetch --depth 1 origin "$branch"
  git -C "$INSTALL_DIR" checkout -q -B "$branch" FETCH_HEAD
  git -C "$INSTALL_DIR" reset --hard FETCH_HEAD
  git -C "$INSTALL_DIR" clean -fd -e state -e data -e install-render -e .acme.sh
  log "repo-sync готово"
}

# ---------------------------------------------------------------------------
# каталоги для volume — создаём один раз, повторный прогон НЕ трогает
# существующие (PKI, база 3x-ui, приватный ключ Reality)
# ---------------------------------------------------------------------------
cmd_dirs_init() {
  local mode="${1:?usage: dirs-init <mode>}"
  mkdir -p "$RENDER_DIR" "$STATE_DIR"
  mkdir -p "$RENDER_DIR/nginx/ssl" "$RENDER_DIR/nginx/acme" "$RENDER_DIR/nginx/html"

  if [[ "$mode" == "vless" || "$mode" == "all" ]]; then
    mkdir -p "$INSTALL_DIR/data/xui"
  fi
  if [[ "$mode" == "openvpn" || "$mode" == "all" ]]; then
    mkdir -p "$INSTALL_DIR/data/easyrsa" "$INSTALL_DIR/data/ccd" "$INSTALL_DIR/data/stat"
  fi
  log "dirs-init готово (mode=$mode) — существующие каталоги не тронуты"
}

# ---------------------------------------------------------------------------
# рендер шаблонов (простая подстановка @@VAR@@ через sed, без envsubst —
# он не всегда стоит на минимальном образе)
# ---------------------------------------------------------------------------
render_tmpl() {
  local src="$1" dst="$2"; shift 2
  local sed_args=()
  local pair
  for pair in "$@"; do
    local key="${pair%%=*}" val="${pair#*=}"
    val="${val//\\/\\\\}"; val="${val//\//\\/}"; val="${val//&/\\&}"
    sed_args+=(-e "s/@@${key}@@/${val}/g")
  done
  sed "${sed_args[@]}" "$src" > "$dst"
}

# strip_block <file> <BEGIN marker> <END marker> — вырезает блок целиком,
# если режим его не требует (маркеры — HTML/YAML-комментарии в шаблоне)
strip_block() {
  local file="$1" begin="$2" end="$3"
  sed -i "/${begin}/,/${end}/d" "$file"
}
keep_block_markers_only() {
  local file="$1" begin="$2" end="$3"
  sed -i -e "/${begin}/d" -e "/${end}/d" "$file"
}

# render-compose <mode> <ovpn_udp_port> <public_ip>
cmd_render_compose() {
  local mode="${1:?usage: render-compose <mode> <ovpn_udp_port> <public_ip>}"
  local ovpn_port="${2:-}"
  local public_ip="${3:?public_ip required}"
  local tmpl="$TMPL_DIR/docker-compose.yml.tmpl"
  local out="$RENDER_DIR/docker-compose.yml"
  [[ -f "$tmpl" ]] || die "не найден $tmpl"

  render_tmpl "$tmpl" "$out" \
    "OVPN_UDP_PORT=${ovpn_port:-1194}" \
    "PUBLIC_IP=${public_ip}" \
    "REPO_ROOT=${INSTALL_DIR}"

  if [[ "$mode" != "vless" && "$mode" != "all" ]]; then
    strip_block "$out" "# BEGIN VLESS" "# END VLESS"
  else
    keep_block_markers_only "$out" "# BEGIN VLESS" "# END VLESS"
  fi
  if [[ "$mode" != "openvpn" && "$mode" != "all" ]]; then
    strip_block "$out" "# BEGIN OPENVPN" "# END OPENVPN"
  else
    keep_block_markers_only "$out" "# BEGIN OPENVPN" "# END OPENVPN"
  fi

  log "render-compose готово -> $out"
}

# ---------------------------------------------------------------------------
# сертификат на голый IP — acme.sh (Certbot в Debian репах пока без
# поддержки webroot для IP, см. README раздел 8)
# ---------------------------------------------------------------------------
cmd_acme_install() {
  # standalone-режим (cert-issue) поднимает свой HTTP-сервер через socat —
  # без него acme.sh падает на "Please install socat tools first."
  # Проверяем и ставим при каждом вызове, не только при первой установке
  # acme.sh — иначе повторный прогон на уже настроенном сервере пропустит
  # эту проверку через ранний return ниже.
  if ! command -v socat >/dev/null 2>&1; then
    log "ставлю socat (нужен acme.sh для standalone-режима)"
    apt-get -o DPkg::Lock::Timeout=120 -y install -qq socat
  fi

  if [[ -x "$ACME_BIN" ]]; then
    local installed_ver
    installed_ver="$("$ACME_BIN" --home "$ACME_HOME" --version 2>/dev/null | tail -1 | awk -F'v' '{print $NF}')"
    if [[ "$installed_ver" == "$ACME_TAG" ]]; then
      log "acme.sh $ACME_TAG уже установлен"
      return 0
    fi
    log "acme.sh установлен как $installed_ver, нужен $ACME_TAG — переустанавливаю"
  fi
  log "ставлю acme.sh (git clone, тег $ACME_TAG — без curl|sh)"
  local tmp; tmp=$(mktemp -d)
  git clone --depth 1 --branch "$ACME_TAG" https://github.com/acmesh-official/acme.sh.git "$tmp"
  ( cd "$tmp" && ./acme.sh --install --home "$ACME_HOME" --no-cron )
  rm -rf "$tmp"
  # свой systemd-таймер вместо cron-строки acme.sh — проверка дважды в день,
  # renew у самого acme.sh идемпотентен (не выпускает, пока не истекает срок)
  cat > /etc/systemd/system/ovpn-stack-acme-renew.service <<EOF
[Unit]
Description=ovpn-stack: acme.sh renew

[Service]
Type=oneshot
Environment=LE_WORKING_DIR=${ACME_HOME}
ExecStart=${ACME_BIN} --cron --home ${ACME_HOME}
ExecStartPost=-/usr/bin/docker compose -f ${RENDER_DIR}/docker-compose.yml exec -T nginx nginx -s reload
EOF
  cat > /etc/systemd/system/ovpn-stack-acme-renew.timer <<'EOF'
[Unit]
Description=ovpn-stack: acme.sh renew twice a day (IP-сертификат живёт ~6 суток)

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=600
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now ovpn-stack-acme-renew.timer
  log "acme.sh + таймер продления готовы"
}

# cert-issue <ip> [email]
cmd_cert_issue() {
  local ip="${1:?usage: cert-issue <ip> [email]}"
  local email="${2:-}"
  local cert_dir="$RENDER_DIR/nginx/ssl"

  if [[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]]; then
    log "сертификат уже есть в $cert_dir — не перевыпускаю (см. cert-renew)"
    return 0
  fi

  log "выпускаю IP-сертификат Let's Encrypt через acme.sh (standalone, порт 80)"
  local email_arg=()
  [[ -n "$email" ]] && email_arg=(--accountemail "$email")

  "$ACME_BIN" --home "$ACME_HOME" --issue --standalone \
    --server letsencrypt \
    -d "$ip" \
    --cert-profile shortlived \
    --days 3 \
    "${email_arg[@]}"

  "$ACME_BIN" --home "$ACME_HOME" --install-cert -d "$ip" \
    --key-file       "$cert_dir/privkey.pem" \
    --fullchain-file "$cert_dir/fullchain.pem" \
    --reloadcmd      "docker compose -f ${RENDER_DIR}/docker-compose.yml exec -T nginx nginx -s reload || true"

  log "cert-issue готово"
}

# переключить выпущенный сертификат на webroot-режим продления (nginx уже
# держит :80 к этому моменту — standalone больше не сработает)
cmd_cert_switch_to_webroot() {
  local ip="${1:?usage: cert-switch-to-webroot <ip>}"
  local webroot="$RENDER_DIR/nginx/acme"
  "$ACME_BIN" --home "$ACME_HOME" --set-notify-hook null >/dev/null 2>&1 || true
  # meняем challenge-alias на webroot без переиздания сертификата
  sed -i "s#^Le_Webroot=.*#Le_Webroot='${webroot}'#" "$ACME_HOME/${ip}_ecc/${ip}.conf" 2>/dev/null || \
    "$ACME_BIN" --home "$ACME_HOME" --issue -d "$ip" -w "$webroot" --server letsencrypt --cert-profile shortlived --days 3 --force
  log "cert-switch-to-webroot готово"
}

# htpasswd-generate <user> <pass> — nginx:alpine здесь без своего Dockerfile
# (в отличие от старого деплоя с apache2-utils в образе), поэтому хэш
# считаем сами через openssl (apr1 — совместимый с nginx auth_basic_user_file
# формат, проверено на живом сервере: 401 без пароля, 200 с верным).
cmd_htpasswd_generate() {
  local user="${1:?usage: htpasswd-generate <user> <pass>}"
  local pass="${2:?usage: htpasswd-generate <user> <pass>}"
  mkdir -p "$RENDER_DIR/nginx"
  printf '%s:%s\n' "$user" "$(openssl passwd -apr1 "$pass")" > "$RENDER_DIR/nginx/htpasswd"
  # 644, не 600: файл читает nginx внутри контейнера под своим uid,
  # не совпадающим с хостовым — 600 дал "Permission denied" на живом
  # сервере. Внутри только apr1-хэш, не голый пароль — ознакомительный
  # доступ на чтение не проблема.
  chmod 644 "$RENDER_DIR/nginx/htpasswd"
  log "htpasswd-generate готово (user=$user)"
}

# ---------------------------------------------------------------------------
# nginx — рендер конфига и запуск последним
# ---------------------------------------------------------------------------
# render-nginx <mode> <xui_base_path> <xui_port> <ovpn_admin_path>
cmd_render_nginx() {
  local mode="${1:?usage: render-nginx <mode> <xui_base_path> <xui_port> <ovpn_admin_path>}"
  local xui_path="${2:-}"
  local xui_port="${3:-2053}"
  local ovpn_admin_path="${4:-}"
  local tmpl="$TMPL_DIR/nginx.conf.tmpl"
  local out="$RENDER_DIR/nginx/conf.d/default.conf"
  mkdir -p "$RENDER_DIR/nginx/conf.d"
  [[ -f "$tmpl" ]] || die "не найден $tmpl"

  render_tmpl "$tmpl" "$out" \
    "XUI_BASE_PATH=${xui_path}" \
    "XUI_PORT=${xui_port}" \
    "OVPN_ADMIN_PATH=${ovpn_admin_path}"

  if [[ "$mode" != "vless" && "$mode" != "all" ]]; then
    strip_block "$out" "# BEGIN VLESS" "# END VLESS"
  else
    keep_block_markers_only "$out" "# BEGIN VLESS" "# END VLESS"
  fi
  if [[ "$mode" != "openvpn" && "$mode" != "all" ]]; then
    strip_block "$out" "# BEGIN OPENVPN" "# END OPENVPN"
  else
    keep_block_markers_only "$out" "# BEGIN OPENVPN" "# END OPENVPN"
  fi

  # docker-compose.yml всегда монтирует nginx/htpasswd (нужен только в
  # openvpn/all-режиме, для Basic Auth перед ovpn-admin) — в vless-only
  # его никто не сгенерирует через htpasswd-generate, а bind-mount
  # несуществующего файла Docker молча подменяет пустой директорией.
  if [[ ! -f "$RENDER_DIR/nginx/htpasswd" ]]; then
    : > "$RENDER_DIR/nginx/htpasswd"
  fi

  if [[ ! -f "$RENDER_DIR/nginx/html/index.html" ]]; then
    cat > "$RENDER_DIR/nginx/html/index.html" <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>It works</title></head>
<body><p>It works.</p></body></html>
EOF
  fi

  log "render-nginx готово -> $out"
}

# ---------------------------------------------------------------------------
# compose up
# ---------------------------------------------------------------------------
cmd_compose_up() {
  local svc="${1:-}"
  ( cd "$RENDER_DIR" && docker compose -f docker-compose.yml up -d --build ${svc:+"$svc"} )
  log "compose-up готово"
}

cmd_compose_up_service() {
  local svc="${1:?usage: compose-up-service <service>}"
  ( cd "$RENDER_DIR" && docker compose -f docker-compose.yml up -d --build "$svc" )
}

# nginx-reload — `docker compose up` не трогает уже запущенный контейнер,
# если его спецификация (образ/порты/volume-список) не изменилась; сам
# bind-mounted конфиг он не хэширует. При повторном прогоне install/
# base-path панелей каждый раз новый (render-nginx перезаписывает файл
# на диске), а contain уже работает со СТАРЫМ конфигом, загруженным в
# воркеры при старте — без явного reload это тихо остаётся 404.
cmd_nginx_reload() {
  ( cd "$RENDER_DIR" && docker compose -f docker-compose.yml exec -T nginx nginx -s reload )
}

# ---------------------------------------------------------------------------
# 3x-ui: базовая настройка (webBasePath/webPort/логин) через встроенный CLI
# ---------------------------------------------------------------------------
# xui-configure <container_name> <base_path> <admin_user> <admin_pass> [web_port]
cmd_xui_configure() {
  local container="${1:?usage: xui-configure <container> <base_path> <admin_user> <admin_pass> [web_port]}"
  local base_path="$2" admin_user="$3" admin_pass="$4" web_port="${5:-2053}"

  for _ in $(seq 1 30); do
    docker exec "$container" true >/dev/null 2>&1 && break
    sleep 1
  done

  # 127.0.0.1 не работает: 3x-ui сидит в network_mode: host (свой netns
  # хоста), а nginx — в отдельной bridge-сети docker-compose. host.docker.internal
  # у nginx резолвится в docker0-gateway (172.17.0.1), а loopback-сокет
  # никогда не отвечает на пакеты, пришедшие на другой локальный адрес —
  # проверено на живом сервере, соединение молча висело по таймауту.
  # Слушаем на всех интерфейсах и защищаем на уровне nftables (INPUT
  # разрешает $web_port только с docker-интерфейсов, не из интернета).
  docker exec "$container" /app/x-ui setting \
    -webBasePath "$base_path" \
    -port "$web_port" \
    -listenIP "0.0.0.0" \
    -username "$admin_user" \
    -password "$admin_pass" >/dev/null

  docker restart "$container" >/dev/null
  for _ in $(seq 1 30); do
    docker exec "$container" true >/dev/null 2>&1 && break
    sleep 1
  done
  log "xui-configure готово (base_path=$base_path)"
}

# ---------------------------------------------------------------------------
# fakesite — локальный TLS-сайт как dest для REALITY, вместо внешнего домена.
# ---------------------------------------------------------------------------
# REALITY на каждое входящее соединение СИНХРОННО дозванивается до dest —
# ДО чтения ClientHello клиента (github.com/xtls/reality tls.go, func Server:
# `target, err := config.DialContext(ctx, config.Type, config.Dest)` —
# самая первая строчка). На реальном внешнем домене (www.kth.se, сам по
# себе быстрый и надёжный — 10/10 curl с этого же сервера) это давало
# 0/10 успешных VLESS-хэндшейков подряд: сервер получал ClientHello,
# подтверждал TCP ACK и не отвечал вообще ничего — зависание внутри xray
# после dial, а не сетевая проблема. Локальный dest (127.0.0.1) убирает
# сетевой хоп полностью — тот же прогон дал 10/10. Тот же приём есть в
# проверенном рабочем скрипте github.com/YukiKras/vless-scripts
# (SelfSNI: self-signed сертификат + 127.0.0.1). SNI-домен остаётся
# правдоподобным именем для маскировки — сервер к нему не обращается.
FAKESITE_PORT=8444
cmd_fakesite_install() {
  need_root fakesite-install
  local domain="${1:?usage: fakesite-install <domain>}"
  if ! command -v nginx >/dev/null 2>&1; then
    log "ставлю nginx (хостовый, отдельно от Docker — только под локальный dest)"
    apt-get -o DPkg::Lock::Timeout=120 -y install -qq nginx
    # дефолтный сайт пакета слушает 0.0.0.0:80/[::]:80 — конфликтует с
    # портом 80 Docker-контейнера nginx (ACME). Нам он не нужен: наш
    # единственный vhost сидит на 127.0.0.1:${FAKESITE_PORT}.
    rm -f /etc/nginx/sites-enabled/default
  fi

  local certdir="/etc/ssl/ovpn-stack-fakesite"
  mkdir -p "$certdir"
  if [[ ! -f "$certdir/fullchain.pem" ]]; then
    log "self-signed сертификат для '$domain' — виден только серверу самому себе, не реальным клиентам"
    # -addext SAN обязателен: sing-box (в отличие от xray-core) проверяет
    # сертификат даже после успешной REALITY-аутентификации, и современный
    # Go отклоняет only-CN сертификаты — "x509: certificate relies on
    # legacy Common Name field, use SANs instead". Проверено вживую:
    # реальный клиент (Happ/sing-box) подключался, но трафик не шёл
    # именно из-за этого.
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout "$certdir/privkey.pem" -out "$certdir/fullchain.pem" \
      -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" >/dev/null 2>&1
  fi

  mkdir -p /var/www/ovpn-stack-fakesite
  if [[ ! -f /var/www/ovpn-stack-fakesite/index.html ]]; then
    cat > /var/www/ovpn-stack-fakesite/index.html <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${domain}</title></head><body></body></html>
EOF
  fi

  cat > /etc/nginx/conf.d/ovpn-stack-fakesite.conf <<EOF
# Управляется install-vpn.sh fakesite-install — не редактировать руками.
# Только dest для REALITY: bind на 127.0.0.1, наружу не торчит, в
# firewall правило не нужно (loopback уже разрешён).
server {
    listen 127.0.0.1:${FAKESITE_PORT} ssl;
    http2 on;
    server_name ${domain};
    ssl_certificate     ${certdir}/fullchain.pem;
    ssl_certificate_key ${certdir}/privkey.pem;
    root /var/www/ovpn-stack-fakesite;
    location / {
        index index.html;
    }
}
EOF

  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
  log "fakesite-install готово (127.0.0.1:${FAKESITE_PORT}, SNI=${domain})"
  # для setup.sh — единственное, что нужно передать в vless-create
  printf 'FAKESITE_DEST=127.0.0.1:%s\n' "$FAKESITE_PORT"
}

# ---------------------------------------------------------------------------
# создание VLESS+Reality инбаунда через API 3x-ui
# ---------------------------------------------------------------------------
# vless-create <xui_base_url e.g. http://127.0.0.1:2053/base/> <user> <pass> <dest host:port, обычно 127.0.0.1:8444 — см. fakesite-install> <server_name (SNI)>
cmd_vless_create() {
  local base_url="${1:?usage: vless-create <base_url> <user> <pass> <dest> <server_name>}"
  local user="$2" pass="$3" dest="$4" server_name="$5"

  # uTLS-отпечаток, который клиент имитирует в ClientHello. Проверено
  # вживую на реальном мобильном операторе: `chrome` (самый массовый и
  # потому наиболее сигнатурно отслеживаемый) — хэндшейк проходит, но
  # трафик не идёт; `firefox` при тех же остальных параметрах работает.
  # Значение уходит и в инбаунд, и в ссылку клиенту (setup.sh) — держать
  # синхронно. Менять здесь, если firefox тоже начнёт резать.
  local fingerprint="firefox"
  base_url="${base_url%/}"
  local cookies; cookies=$(mktemp)
  # не trap ... RETURN: он не снимается сам и позже срабатывает повторно
  # на возврате из main() — там $cookies уже вне области видимости, и
  # под set -u это roняет весь скрипт "unbound variable" уже ПОСЛЕ того,
  # как инбаунд успешно создан. Чистим явно в обеих точках выхода.

  # CSRF: любой небезопасный метод (не GET/HEAD/OPTIONS/TRACE) без сессии
  # ещё не аутентифицирован Bearer-токеном — 3x-ui требует X-CSRF-Token,
  # выданный отдельным публичным GET-эндпоинтом, включая сам /login.
  local csrf_token
  csrf_token=$(curl -fsS -c "$cookies" "${base_url}/csrf-token" | \
    python3 -c 'import json,sys; print(json.load(sys.stdin)["obj"])' 2>/dev/null)
  [[ -n "$csrf_token" ]] || die "не удалось получить CSRF-токен 3x-ui"

  local login_resp
  login_resp=$(curl -fsS -b "$cookies" -c "$cookies" \
    -H "X-CSRF-Token: ${csrf_token}" \
    -d "username=${user}" -d "password=${pass}" \
    "${base_url}/login") || die "3x-ui login не прошёл"
  # 3x-ui отвечает HTTP 200 даже на логическую неудачу (success:false в
  # теле) — curl -f тут ничего не поймает, надо разбирать JSON руками.
  python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("success") else 1)' \
    <<<"$login_resp" || die "3x-ui login отклонён: $login_resp"

  local existing
  existing=$(curl -fsS -b "$cookies" "${base_url}/panel/api/inbounds/list" || echo '{}')
  if grep -q '"remark":"vless-reality"' <<<"$existing"; then
    log "инбаунд vless-reality уже существует — не создаю повторно"
    rm -f "$cookies"
    return 0
  fi

  # путь к бинарю xray внутри образа 3x-ui — проверено на mhsanaei/3x-ui,
  # при смене образа/версии может съехать, поэтому пробуем несколько
  # вариантов (текущий, на момент проверки: /app/bin/xray-linux-amd64)
  local keys
  keys=$(docker exec 3x-ui /app/bin/xray-linux-amd64 x25519 2>/dev/null || \
         docker exec 3x-ui /app/xray x25519 2>/dev/null || \
         docker exec 3x-ui xray x25519 2>/dev/null || true)
  # xray-core >= 25.x переименовал вывод `x25519`: публичный ключ теперь
  # печатается как "Password:", а не "Public key:" (в запиненной 3x-ui
  # v3.4.2 это xray 25.8.29). Старый `grep 'Public'` возвращал пустую
  # строку -> инбаунд создавался, но ссылка на клиента уходила с пустым
  # pbk= и телефон не проходил Reality-хендшейк. Матчим оба формата.
  local priv; priv=$(grep -iE 'private' <<<"$keys" | awk '{print $NF}' | head -1)
  local pub;  pub=$(grep -iE 'password|public' <<<"$keys" | awk '{print $NF}' | head -1)
  [[ -n "$priv" && -n "$pub" ]] || die "не разобрал вывод 'xray x25519' (формат сменился?): ${keys:-<пусто>}"
  # pbk — 43 символа base64url; если тут не так, ссылка всё равно будет битой
  [[ "$pub" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "публичный ключ Reality не похож на base64url-x25519: '$pub'"

  local uuid; uuid=$(cat /proc/sys/kernel/random/uuid)
  local short_id; short_id=$(openssl rand -hex 4)
  # email клиента должен быть уникален в рамках панели (3x-ui отклоняет
  # повтор с "Duplicate email" — HTTP 200, success:false, curl -f это не
  # ловит). Статичный "client1" убивал каждый повторный прогон после
  # первого — берём кусок uuid, гарантированно новый на каждый вызов.
  local client_email="client-${uuid:0:8}"

  local settings streamSettings sniffing
  settings=$(cat <<JSON
{"clients":[{"id":"${uuid}","flow":"xtls-rprx-vision","email":"${client_email}","enable":true}],"decryption":"none"}
JSON
)
  # realitySettings.settings — xray его на инбаунде игнорирует, но 3x-ui
  # читает ИМЕННО отсюда, когда строит клиентские ссылки/QR/подписку
  # в панели. Без publicKey тут все ссылки из панели уходят с пустым
  # pbk= (та же поломка, что чинил парсинг x25519 выше, только со
  # стороны панели). fingerprint/serverName/spiderX дублируем сюда же.
  streamSettings=$(cat <<JSON
{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":"${dest}","xver":0,"serverNames":["${server_name}"],"privateKey":"${priv}","shortIds":["${short_id}"],"settings":{"publicKey":"${pub}","fingerprint":"${fingerprint}","serverName":"","spiderX":"/"},"fingerprint":"${fingerprint}","spiderX":"/"}}
JSON
)
  sniffing='{"enabled":false,"destOverride":["http","tls"]}'

  local payload
  payload=$(cat <<JSON
{"up":0,"down":0,"total":0,"remark":"vless-reality","enable":true,"expiryTime":0,
"listen":"","port":443,"protocol":"vless",
"settings":$(printf '%s' "$settings" | tr -d '\n'),
"streamSettings":$(printf '%s' "$streamSettings" | tr -d '\n'),
"sniffing":$(printf '%s' "$sniffing" | tr -d '\n')}
JSON
)

  local add_resp
  add_resp=$(curl -fsS -b "$cookies" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: ${csrf_token}" \
    -d "$payload" \
    "${base_url}/panel/api/inbounds/add") || die "создание инбаунда не прошло"
  # Опять же: логическая ошибка (напр. "Duplicate email") приходит как
  # HTTP 200 + success:false — обнаружено вживую на этом самом сервере,
  # скрипт до этого молча репортовал успех при фактически пустой панели.
  python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("success") else 1)' \
    <<<"$add_resp" || die "создание инбаунда отклонено 3x-ui: $add_resp"
  rm -f "$cookies"

  log "VLESS+Reality инбаунд создан (uuid=$uuid shortId=$short_id publicKey=$pub)"
  # для сводки — единственное, что нужно домашнему ПК
  printf 'VLESS_UUID=%s\n'      "$uuid"
  printf 'VLESS_PUBKEY=%s\n'    "$pub"
  printf 'VLESS_SHORTID=%s\n'   "$short_id"
  printf 'VLESS_DEST=%s\n'      "$dest"
  printf 'VLESS_SNI=%s\n'       "$server_name"
  printf 'VLESS_FP=%s\n'        "$fingerprint"
}

# ---------------------------------------------------------------------------
main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    docker-install)           cmd_docker_install "$@" ;;
    docker-group-add)         cmd_docker_group_add "$@" ;;
    repo-sync)                cmd_repo_sync "$@" ;;
    dirs-init)                cmd_dirs_init "$@" ;;
    render-compose)           cmd_render_compose "$@" ;;
    acme-install)             cmd_acme_install "$@" ;;
    cert-issue)               cmd_cert_issue "$@" ;;
    cert-switch-to-webroot)   cmd_cert_switch_to_webroot "$@" ;;
    htpasswd-generate)        cmd_htpasswd_generate "$@" ;;
    render-nginx)             cmd_render_nginx "$@" ;;
    compose-up)               cmd_compose_up "$@" ;;
    compose-up-service)       cmd_compose_up_service "$@" ;;
    nginx-reload)             cmd_nginx_reload "$@" ;;
    xui-configure)            cmd_xui_configure "$@" ;;
    fakesite-install)         cmd_fakesite_install "$@" ;;
    vless-create)              cmd_vless_create "$@" ;;
    *) die "неизвестная подкоманда: '$sub'" ;;
  esac
}

main "$@"
