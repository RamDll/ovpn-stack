# ovpn-stack

Единый стек для self-hosted OpenVPN с веб-панелью и мониторингом. Поднимается
одной командой `docker compose up -d`.

Объединяет три ранее раздельных репозитория:

| Каталог             | Источник                                                             | Роль |
|---------------------|---------------------------------------------------------------------|------|
| `admin/`            | [ovpn-admin-hardened](https://github.com/RamDll/ovpn-admin-hardened) | OpenVPN-сервер (hardened) + панель управления ovpn-admin |
| `monitoring/`       | [openvpn-monitoring](https://github.com/RamDll/openvpn-monitoring)   | Prometheus + Grafana + node-exporter |
| `nginx/`            | [vps-nginx-config](https://github.com/RamDll/vps-nginx-config)       | reverse proxy: TLS + Basic Auth |

## Что внутри

```
ovpn-stack/
├── docker-compose.yaml        единый стек: openvpn + ovpn-admin + prometheus + grafana + node-exporter + nginx
├── .env.example               шаблон секретов
├── admin/                     вендоренный ovpn-admin-hardened (Dockerfile.openvpn, Dockerfile.ovpn-admin, Go-код, фронтенд, setup/)
├── monitoring/
│   ├── prometheus/
│   │   └── prometheus.yml
│   └── grafana/
│       ├── provisioning/      datasource + провайдер дашбордов (подключаются автоматически)
│       └── dashboards/
│           └── ovpn-admin.json
└── nginx/
    ├── Dockerfile             nginx-alpine + apache2-utils (генерация .htpasswd)
    ├── 40-htpasswd.sh         генерит .htpasswd из BASIC_AUTH_* при старте
    ├── conf.d/ovpn-admin.conf
    ├── ssl/                   сюда положить fullchain.pem + privkey.pem (в .gitignore)
    └── acme/                  webroot для ACME http-01 challenge (в .gitignore)
```

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
  --cert-file    "$(pwd)/nginx/ssl/cert.pem" \
  --key-file     "$(pwd)/nginx/ssl/privkey.pem" \
  --fullchain-file "$(pwd)/nginx/ssl/fullchain.pem" \
  --reloadcmd    "docker compose -f $(pwd)/docker-compose.yaml exec nginx nginx -s reload"
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
curl -sk https://<IP>/grafana/api/health
```

Панель: `https://<IP>/` · Grafana: `https://<IP>/grafana/` (обе за Basic Auth).
В Grafana datasource Prometheus и дашборд **Ovpn-Admin** уже подключены.

## Обновление / остановка

```bash
docker compose pull && docker compose up -d --build   # обновить образы и пересобрать
docker compose down                                   # остановить (данные в volume сохраняются)
docker compose down -v                                # + удалить данные Prometheus/Grafana
```

PKI OpenVPN лежит в `./data/` (в `.gitignore`) — резервируйте этот каталог.

## Отличия от исходных репозиториев

- Единый `docker-compose.yaml` вместо трёх; общая compose-сеть `ovpn-stack`
  вместо внешней `openvpn-master_default`.
- Всем сервисам добавлен `restart: unless-stopped`.
- Healthcheck для `openvpn` (`pidof openvpn`) и `ovpn-admin` (HTTP `:8080/`).
- Секреты (Basic Auth, пароль Grafana) вынесены в `.env`; `.htpasswd`
  генерируется из него при старте nginx и не хранится в репозитории.
- nginx контейнеризован; проксирует на имена сервисов (`openvpn:8080`,
  `grafana:3000`) вместо `127.0.0.1`, с TLS 1.2/1.3 и HSTS.
- Grafana datasource и дашборд провижнятся автоматически; дашборд
  `ovpn-admin.json` перенесён из `ovpn-admin-hardened/dashboard/` в
  `monitoring/grafana/dashboards/` (переменная datasource запинена на `uid=prometheus`).
- `openvpn`: добавлен `sysctl net.ipv4.ip_forward=1` (нужен для redirect-gateway).
- Образы `prometheus` / `grafana` / `node-exporter` запинены на конкретные
  версии вместо `:latest`.
- `admin/Dockerfile.*`: `ARG TARGETARCH` получил дефолт `=amd64` — сборка
  работает и без BuildKit (для multi-arch BuildKit подставит реальную арку).
