# ovpn-stack

Self-hosted OpenVPN с веб-панелью управления. После подготовки `.env` и
TLS-сертификата поднимается одной командой `docker compose up -d --build`.

## Быстрая установка на свежий сервер

```bash
# wget входит в базовую установку Debian (priority: standard), curl — нет:
wget -qO install.sh https://raw.githubusercontent.com/RamDll/ovpn-stack/master/install.sh
# либо, если curl уже установлен:
# curl -fsSL https://raw.githubusercontent.com/RamDll/ovpn-stack/master/install.sh -o install.sh

sudo bash install.sh
```

Внутри скрипта `curl` не требуется до шага установки зависимостей — он ставится
там вместе с Docker. Единственное, что работает раньше и зависит от `curl`, —
автоопределение публичного IP; без `curl` этот шаг тихо пропускается, и IP
нужно ввести вручную (или передать флагом `--ip`).

Скрипт `install.sh` (Debian/Ubuntu) в интерактиве спрашивает и делает:

1. **проверяет** дистрибутив, наличие `/dev/net/tun`, синхронизацию времени;
2. **ставит** Docker + compose-плагин, git, fail2ban;
3. **спрашивает**: домен *или* публичный IP (публичный IP определяется сам —
   перебор `icanhazip.com` / `checkip.amazonaws.com` / `api.ipify.org`, при
   расхождении с адресом интерфейса предупреждает про NAT, значение можно
   переопределить), логин и пароль панели (пустой — сгенерирует), UDP-порт
   OpenVPN (по умолчанию `7777`), каталог установки (по умолчанию
   `/opt/ovpn-stack`), e-mail для Let's Encrypt;
4. **клонирует** репозиторий, пишет `.env`, поднимает стек (`docker compose up`);
5. **открывает порты** — определяет, какой файрвол уже стоит:
   `ufw`/`firewalld` — добавляет правила сам (80/tcp, 443/tcp, `<ovpn>`/udp
   и **все порты SSH**, которые нашёл); голый `nftables`/`iptables` со своим
   набором правил **не трогает**, только печатает нужные команды; если файрвола
   нет — предлагает поставить `ufw`. При включении `ufw` ставит страховочный
   таймер отката на 5 минут — успей подтвердить в новой SSH-сессии;
6. **выпускает TLS** через `acme.sh` (домен — обычный http-01; голый IP —
   короткоживущий профиль Let's Encrypt, ~6 дней, авто-renew), с фолбэком на
   self-signed;
7. **настраивает fail2ban** (бан перебора Basic Auth), правит `logpath` под
   каталог установки;
8. печатает сводку: URL панели, где лежат креды, что бэкапить.

Неинтерактивно: `sudo bash install.sh --yes --domain vpn.example.com --password '…'`
(см. `--help` — флаги `--ip`, `--user`, `--ovpn-port`, `--dir`, `--no-firewall`,
`--no-fail2ban`, `--no-acme`, `--self-signed`).

Внешний (облачный) файрвол хостера скрипт не видит — если после установки панель
недоступна, открой `80,443/tcp` и `<ovpn>/udp` в панели провайдера.

Ручная установка по шагам — ниже.

---

Собран из двух ранее раздельных репозиториев:

| Каталог  | Источник                                                              | Роль |
|----------|---------------------------------------------------------------------|------|
| `admin/` | [ovpn-admin-hardened](https://github.com/RamDll/ovpn-admin-hardened) | OpenVPN-сервер (hardened) + панель управления ovpn-admin |
| `nginx/` | [vps-nginx-config](https://github.com/RamDll/vps-nginx-config)       | reverse proxy: TLS + Basic Auth |

## Что внутри

```
ovpn-stack/
├── install.sh                 установщик на месте: OpenVPN + ovpn-admin + nginx (запускать на сервере)
├── install/                   установщик с домашней машины: + VLESS Reality, SSH-хардненинг (см. install/README.md)
├── docker-compose.yaml        стек: openvpn + ovpn-admin + nginx
├── .env.example               шаблон секретов (скопировать в .env)
├── .github/                   CI (docker compose smoke test) + конфиг Dependabot
├── docs/hardening.md          чек-лист хардненинга хоста
├── admin/                     форк ovpn-admin-hardened (Apache-2.0, см. admin/LICENSE)
│   ├── Dockerfile.openvpn        OpenVPN-сервер с усиленной конфигурацией
│   ├── Dockerfile.ovpn-admin     Go-бэкенд + сборка фронтенда, статика вшита через //go:embed
│   ├── *.go                      бэкенд панели
│   ├── frontend/                 панель: Vue 3 + Vite + TypeScript (переписана с нуля, v3)
│   └── setup/                    configure.sh — генерация PKI и конфига при первом старте
├── nginx/
│   ├── Dockerfile             nginx-alpine + apache2-utils (генерация .htpasswd)
│   ├── 40-htpasswd.sh         генерит .htpasswd из BASIC_AUTH_* при старте
│   ├── conf.d/ovpn-admin.conf
│   ├── ssl/                   сюда положить fullchain.pem + privkey.pem (в .gitignore)
│   ├── acme/                  webroot для ACME http-01 challenge (в .gitignore)
│   └── f2b-log/               access/error лог для fail2ban (bind-mount, в .gitignore)
└── fail2ban/                  jail + action для бана перебора Basic Auth (ставится на хост)
```

Рантайм-данные (`.env`, `data/` с PKI, `nginx/ssl/`, `nginx/.htpasswd`) в
репозиторий не попадают — см. `.gitignore`.

## Панель

Фронтенд `admin/frontend/` переписан на Vue 3 + Vite + TypeScript (headless-компоненты
`reka-ui`, собственный CSS, тёмная/светлая темы). Возможности:

- список клиентов с сортировкой и фильтрами (онлайн / отозванные), под именем —
  IP, время сессии, трафик сессии, срок действия;
- создание, отзыв/восстановление, перевыпуск, удаление, разрыв сессии, редактор CCD-маршрутов;
- скачивание `.ovpn`;
- локализация ru/en, переключатели языка и темы в шапке;
- плитка «Сервер»: имя хоста, загрузка CPU, память (эндпоинт `api/server/stats`);
- страница «Статистика»: помесячный трафик (учёт в bbolt-хранилище `data/stat/traffic.db`),
  сводка, разбивка по клиентам.

## Сеть и порты

Наружу публикуются только:

| Порт        | Сервис  | Назначение |
|-------------|---------|------------|
| `443/tcp`   | nginx   | панель ovpn-admin (`/`), TLS + Basic Auth |
| `80/tcp`    | nginx   | редирект на HTTPS + ACME challenge |
| `7777/udp`  | openvpn | OpenVPN |

`ovpn-admin:8080` живёт во внутренней сети стека `ovpn-stack` и наружу не
выставляется. `ovpn-admin` делит сетевой namespace с `openvpn`
(`network_mode: service:openvpn`) ради доступа к mgmt-интерфейсу `127.0.0.1:8989`.

## Ручная установка (что делает `install.sh` по шагам)

### 1. Секреты — `.env`

```bash
cp .env.example .env
# отредактируйте: VPS_PUBLIC_IP, BASIC_AUTH_USER / BASIC_AUTH_PASSWORD
```

Необязательная переменная `OVPN_SERVER_NAME` переопределяет имя сервера в плитке
«Сервер». По умолчанию берётся имя хоста (`/etc/hostname` монтируется в контейнер
`ovpn-admin` только для чтения).

### 2. TLS-сертификат

Положите сертификат и ключ в `nginx/ssl/` под именами `fullchain.pem` и `privkey.pem`.

**Вариант A — self-signed (для теста):**

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout nginx/ssl/privkey.pem -out nginx/ssl/fullchain.pem \
  -subj "/CN=$(grep -E '^VPS_PUBLIC_IP=' .env | cut -d= -f2)"
```

**Вариант B — Let's Encrypt на голый IP через acme.sh (short-lived профиль):**

```bash
# nginx уже слушает :80 и отдаёт ./nginx/acme по /.well-known/acme-challenge/
acme.sh --issue --server letsencrypt -d <IP> \
  -w "$(pwd)/nginx/acme" \
  --key-file       "$(pwd)/nginx/ssl/privkey.pem" \
  --fullchain-file "$(pwd)/nginx/ssl/fullchain.pem" \
  --reloadcmd      "docker compose -f $(pwd)/docker-compose.yaml exec nginx nginx -s reload"
```

### 3. Запуск

```bash
docker compose up -d --build
```

При первом старте контейнер `openvpn` генерирует EC-PKI (CA + серверный
сертификат, prime256v1) — это несколько секунд. `ovpn-admin` стартует после
того, как `openvpn` станет healthy.

Проверка:

```bash
docker compose ps          # все сервисы Up, openvpn/ovpn-admin — healthy
set -a; . ./.env; set +a
curl -sk -o /dev/null -w '%{http_code}\n' \
  -u "$BASIC_AUTH_USER:$BASIC_AUTH_PASSWORD" https://<IP>/   # 200
```

Панель: `https://<IP>/` (за Basic Auth).

## Обновление / остановка

```bash
git pull && docker compose up -d --build   # подтянуть изменения и пересобрать
docker compose down                        # остановить (PKI в ./data/ сохраняется)
```

Данные OpenVPN лежат в `./data/` (в `.gitignore`): `easyrsa/` — PKI с приватными
ключами, `ccd/` — client-config-dir, `stat/traffic.db` — учёт трафика.
Резервируйте этот каталог.

## Развёртывание на новом сервере

`git clone` + шаги 1–3 выше поднимают **новый** VPN: контейнер `openvpn`
сгенерирует собственный CA и серверный сертификат, `.htpasswd` соберётся из `.env`.

**Чтобы перенести существующий сервер** (сохранив рабочие клиентские `.ovpn`),
до первого `up` скопируйте со старой машины:

- `data/easyrsa/` и `data/ccd/` — тот же CA и сертификаты клиентов;
- `data/stat/traffic.db` — если нужна история трафика.

Для нестандартного размещения TLS (например, сертификат acme.sh с хоста)
используйте локальный `docker-compose.override.yaml` — он не в репозитории.

## Безопасность

- Панель закрыта Basic Auth на nginx; `.htpasswd` генерируется из `.env` и не
  хранится в репозитории.
- OpenVPN — только по клиентскому сертификату (EC prime256v1), `tls-crypt`,
  `AES-256-GCM`, `auth SHA256`, `tls-version-min 1.2`.
- Наружу открыты только 443/tcp, 80/tcp (редирект + ACME) и 7777/udp.
- fail2ban (каталог `fail2ban/`): бан IP за перебор Basic Auth. Ставится на хост —
  nginx дублирует лог в `nginx/f2b-log/`, jail читает его оттуда. Инструкция —
  `fail2ban/README.md`.
- Хардненинг хоста (ufw, SSH, sysctl, автообновления, минимум пакетов) —
  чек-лист с командами в [`docs/hardening.md`](docs/hardening.md).

## Отличия от исходных репозиториев

- Единый `docker-compose.yaml` вместо раздельных; общая compose-сеть `ovpn-stack`.
- Всем сервисам добавлен `restart: unless-stopped` и ротация логов Docker
  (`json-file`, 10 МБ × 3).
- Healthcheck для `openvpn` (`pidof openvpn`) и `ovpn-admin` (HTTP `:8080/`).
- Секреты (Basic Auth) вынесены в `.env`; `.htpasswd` генерируется из него при
  старте nginx и не хранится в репозитории.
- nginx контейнеризован; проксирует на имя сервиса (`openvpn:8080`) вместо
  `127.0.0.1`, с TLS 1.2/1.3 и HSTS.
- Фронтенд панели переписан с нуля (Vue 3 + Vite + TypeScript, i18n ru/en,
  тёмная/светлая темы, страница «Статистика»).
- Помесячный учёт трафика: bbolt-хранилище `data/stat/traffic.db`, эндпоинт
  `api/statistic`.
- `openvpn`: добавлен `sysctl net.ipv4.ip_forward=1` (нужен для redirect-gateway).
- CI (`.github/workflows/ci.yml`): на каждый push/PR поднимает стек целиком и
  прогоняет smoke-проверки. Обновления зависимостей — через Dependabot.
- Каталог `fail2ban/` + дублирование лога nginx в `nginx/f2b-log/` для бана
  перебора Basic Auth (см. раздел «Безопасность»).

### Выпилено из форка `admin/`

Стек рассчитан на один self-hosted сервер, поэтому из форка `palark/ovpn-admin`
убраны сценарии, которые здесь не используются:

- **Kubernetes-бэкенд** (`STORAGE_BACKEND=kubernetes.secrets`): весь
  `kubernetes.go`, генерация PKI на Go (`certificates.go`), Helm-чарт,
  зависимости `k8s.io/*` (~35 модулей).
- **Парольная аутентификация** (`OVPN_AUTH`): сторонний бинарь `openvpn-user`,
  `auth.sh`, эндпоинт смены пароля, модуль `passwdAuth` в панели.
- **Режим slave и master/slave-репликация**: флаги `--role` / `--master.*`,
  эндпоинты `api/sync/*` и `api/data/*/download`, скачивание/распаковка архивов.
- **RSA + статические DH** → EC-PKI (prime256v1); `dh none`. Первый старт из
  минут превратился в секунды.
- Апстримные скрипты сборки (`Makefile`, `build*.sh`, `install-deps*.sh`,
  `werf.yaml`) и материалы README апстрима.
- Сборка `ovpn-admin` переведена на `CGO_ENABLED=0` (образ 98 → 43 МБ).

Совокупно `go.mod` ужался с 60 строк (9 прямых зависимостей + большое дерево
транзитивных) до 8 строк: `google/uuid`, `sirupsen/logrus`, `go.etcd.io/bbolt`,
`kingpin.v2` и 4 indirect. Бинарь `ovpn-admin` — ~9.8 МБ.

### Выпилен мониторинг

Убраны Prometheus, Grafana и node-exporter (каталог `monitoring/`, ~1.4 ГБ
образов, ~250 МБ RAM). Мгновенное состояние (CPU/ОЗУ/загрузка, онлайн, трафик
за сессию) и помесячный учёт трафика по клиентам остаются в панели — они не
зависели от Prometheus. Заодно из бэкенда убран Prometheus-инструментарий
(`prometheus/client_golang` и эндпоинт `:8080/metrics`): счётчики `ovpn_*`
дублировали данные, которые панель и так считает из mgmt-интерфейса и bbolt.

## Лицензия

Код этого репозитория (compose-стек, конфигурация nginx, фронтенд панели) —
[MIT](LICENSE).

Каталог `admin/` — форк [palark/ovpn-admin](https://github.com/palark/ovpn-admin),
распространяется под Apache License 2.0 (`admin/LICENSE`).
