# ovpn-stack

Единый стек для self-hosted OpenVPN с веб-панелью и мониторингом. После
подготовки `.env` и TLS-сертификата поднимается одной командой
`docker compose up -d --build`.

Объединяет три ранее раздельных репозитория:

| Каталог       | Источник                                                            | Роль |
|---------------|--------------------------------------------------------------------|------|
| `admin/`      | [ovpn-admin-hardened](https://github.com/RamDll/ovpn-admin-hardened) | OpenVPN-сервер (hardened) + панель управления ovpn-admin |
| `monitoring/` | [openvpn-monitoring](https://github.com/RamDll/openvpn-monitoring)   | Prometheus + Grafana + node-exporter |
| `nginx/`      | [vps-nginx-config](https://github.com/RamDll/vps-nginx-config)       | reverse proxy: TLS + Basic Auth |

## Что внутри

```
ovpn-stack/
├── docker-compose.yaml        стек: openvpn + ovpn-admin + prometheus + grafana + node-exporter + nginx
├── .env.example               шаблон секретов (скопировать в .env)
├── .github/                   CI (docker compose smoke test) + конфиг Dependabot
├── admin/                     форк ovpn-admin-hardened (Apache-2.0, см. admin/LICENSE)
│   ├── Dockerfile.openvpn        OpenVPN-сервер с усиленной конфигурацией
│   ├── Dockerfile.ovpn-admin     Go-бэкенд + сборка фронтенда, статика вшита через //go:embed
│   ├── *.go                      бэкенд панели
│   ├── frontend/                 панель: Vue 3 + Vite + TypeScript (переписана с нуля, v3)
│   └── setup/                    configure.sh — генерация PKI и конфига при первом старте
├── monitoring/
│   ├── prometheus/prometheus.yml       скрейп ovpn-admin, node-exporter, самого Prometheus
│   └── grafana/
│       ├── provisioning/               datasource Prometheus + провайдер дашбордов (авто)
│       └── dashboards/
│           ├── ovpn-admin.json         клиенты, сроки сертификатов
│           └── traffic.json            «OpenVPN — Трафик»: скорость и объёмы по клиентам
└── nginx/
    ├── Dockerfile             nginx-alpine + apache2-utils (генерация .htpasswd)
    ├── 40-htpasswd.sh         генерит .htpasswd из BASIC_AUTH_* при старте
    ├── conf.d/ovpn-admin.conf
    ├── ssl/                   сюда положить fullchain.pem + privkey.pem (в .gitignore)
    └── acme/                  webroot для ACME http-01 challenge (в .gitignore)
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
  сводка, разбивка по клиентам, ссылка в Grafana.

Бэкенд отдаёт метрики Prometheus по `:8080/metrics` (подключённые клиенты, сроки
годности CA и серверного сертификата, счётчики трафика `ovpn_client_traffic_*`).

## Сеть и порты

Наружу публикуются только:

| Порт        | Сервис  | Назначение |
|-------------|---------|------------|
| `443/tcp`   | nginx   | панель ovpn-admin (`/`) и Grafana (`/grafana/`), TLS + Basic Auth |
| `80/tcp`    | nginx   | редирект на HTTPS + ACME challenge |
| `7777/udp`  | openvpn | OpenVPN |

Всё остальное (`ovpn-admin:8080`, `grafana:3000`, `prometheus:9090`,
`node-exporter:9100`) живёт во внутренней сети стека `ovpn-stack` и наружу
не выставляется. `ovpn-admin` делит сетевой namespace с `openvpn`
(`network_mode: service:openvpn`), поэтому его метрики Prometheus скрейпит
по адресу `openvpn:8080`.

## Порядок запуска

### 1. Секреты — `.env`

```bash
cp .env.example .env
# отредактируйте: VPS_PUBLIC_IP, BASIC_AUTH_USER/PASSWORD, GRAFANA_ADMIN_PASSWORD
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

Первый старт долгий: контейнер `openvpn` генерирует CA, серверный сертификат и
DH-параметры (может занять несколько минут на 1 vCPU). `ovpn-admin` стартует
после того, как `openvpn` станет healthy.

Проверка:

```bash
docker compose ps          # все сервисы Up, openvpn/ovpn-admin — healthy
set -a; . ./.env; set +a
curl -sk -u "$BASIC_AUTH_USER:$BASIC_AUTH_PASSWORD" https://<IP>/grafana/api/health
```

Панель: `https://<IP>/` · Grafana: `https://<IP>/grafana/` (обе за Basic Auth).
В Grafana datasource Prometheus и дашборды **Ovpn-Admin** и **OpenVPN — Трафик**
уже подключены.

## Обновление / остановка

```bash
git pull && docker compose up -d --build              # подтянуть изменения и пересобрать
docker compose down                                   # остановить (данные в volume сохраняются)
docker compose down -v                                # + удалить данные Prometheus/Grafana
```

Данные OpenVPN лежат в `./data/` (в `.gitignore`): `easyrsa/` — PKI с приватными
ключами, `ccd/` — client-config-dir, `stat/traffic.db` — учёт трафика.
Резервируйте этот каталог.

## Развёртывание на новом сервере

`git clone` + шаги 1–3 выше поднимают **новый** VPN: контейнер `openvpn`
сгенерирует собственный CA и серверный сертификат, `.htpasswd` соберётся из `.env`,
дашборды Grafana подключатся провижнингом.

**Чтобы перенести существующий сервер** (сохранив рабочие клиентские `.ovpn`),
до первого `up` скопируйте со старой машины:

- `data/easyrsa/` и `data/ccd/` — тот же CA и сертификаты клиентов;
- `data/stat/traffic.db` — если нужна история трафика;
- volume'ы `ovpn-stack_grafana_data` / `ovpn-stack_prometheus_data` — если нужна
  история графиков (сами дашборды и datasource и так из репозитория).

Для нестандартного размещения TLS (например, сертификат acme.sh с хоста)
используйте локальный `docker-compose.override.yaml` — он не в репозитории.

## Отличия от исходных репозиториев

- Единый `docker-compose.yaml` вместо трёх; общая compose-сеть `ovpn-stack`
  вместо внешней `openvpn-master_default`.
- Всем сервисам добавлен `restart: unless-stopped`.
- Healthcheck для `openvpn` (`pidof openvpn`) и `ovpn-admin` (HTTP `:8080/`).
- Секреты (Basic Auth, пароль Grafana) вынесены в `.env`; `.htpasswd`
  генерируется из него при старте nginx и не хранится в репозитории.
- nginx контейнеризован; проксирует на имена сервисов (`openvpn:8080`,
  `grafana:3000`) вместо `127.0.0.1`, с TLS 1.2/1.3 и HSTS.
- Grafana datasource и дашборды провижнятся автоматически; `ovpn-admin.json`
  перенесён из `ovpn-admin-hardened/dashboard/`, добавлен `traffic.json`
  (переменная datasource запинена на `uid=prometheus`).
- Фронтенд панели переписан с нуля (Vue 3 + Vite + TypeScript, i18n ru/en,
  тёмная/светлая темы, страница «Статистика»).
- Помесячный учёт трафика: bbolt-хранилище `data/stat/traffic.db`, эндпоинт
  `api/statistic`, счётчики Prometheus `ovpn_client_traffic_{received,sent}_total`.
- `openvpn`: добавлен `sysctl net.ipv4.ip_forward=1` (нужен для redirect-gateway).
- Образы `prometheus` / `grafana` / `node-exporter` запинены на конкретные
  версии вместо `:latest`.
- `admin/Dockerfile.*`: `ARG TARGETARCH` получил дефолт `=amd64` — сборка
  работает и без BuildKit (для multi-arch BuildKit подставит реальную арку).
- CI (`.github/workflows/ci.yml`): на каждый push/PR поднимает стек целиком и
  прогоняет smoke-проверки. Обновления зависимостей — через Dependabot.

## Лицензия

Код этого репозитория (compose-стек, конфигурация nginx, фронтенд панели,
дашборды) — [MIT](LICENSE).

Каталог `admin/` — форк [palark/ovpn-admin](https://github.com/palark/ovpn-admin),
распространяется под Apache License 2.0 (`admin/LICENSE`).
