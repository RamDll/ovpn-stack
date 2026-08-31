# frontend v3 — прогресс

Переписывание фронтенда ovpn-admin с Vue 2 + bootstrap-vue + webpack на
**Vue 3 + Vite + TypeScript**, headless-примитивы (reka-ui) + собственный CSS
по макету (`~/ovpn-admin-mockup.html`).

Ветка: `frontend-v3`. Бэкенд (`main.go` и т.д.) не трогаем — общается по тем же
`/api/*`. Master остаётся деплоящимся.

## Контракт с бэкендом (не меняется)

Статика встраивается через `//go:embed frontend/static` и раздаётся файловым
сервером с `*listenBaseUrl` (по умолчанию `/`). SPA-роутинга нет → Vite собирает
в `frontend/static/`, `base: './'` (работает под любым `OVPN_LISTEN_BASE_URL`).

Эндпоинты (см. `src/api/ovpn.ts`):

| Путь | Метод | Тело | Ответ |
|---|---|---|---|
| `api/users/list` | GET | — | `OpenvpnClient[]` |
| `api/server/settings` | GET | — | `{ serverRole, modules[] }` |
| `api/sync/last/successful` | GET | — | string (slave) |
| `api/user/create` | POST form | username, password | 200 / текст ошибки |
| `api/user/change-password` | POST form | username, password | 200 / `{message}` |
| `api/user/rotate` | POST form | username, password | 200 / `{message}` |
| `api/user/delete` | POST form | username | 200 / `{message}` |
| `api/user/revoke` | POST form | username | 200 |
| `api/user/unrevoke` | POST form | username | 200 |
| `api/user/config/show` | POST form | username | string (.ovpn) |
| `api/user/ccd` | POST form | username | `Ccd` |
| `api/user/ccd/apply` | POST json | `Ccd` | 200 + текст / ошибка |
| `api/user/disconnect` | POST form | username | текст |
| `api/user/statistic` | POST form | username | `ClientStatus[]` (BytesReceived/Sent, ConnectedSince) |

`AccountStatus`: `Active` \| `Revoked` \| `Expired`. `modules`: `core`, `ccd`, `passwdAuth`.

## Чеклист

- [x] Ветка + PROGRESS.md
- [x] Скелет: Vite/TS/Vue3, конфиги, index.html
- [x] Дизайн-токены + база CSS (из макета)
- [x] API-слой: client.ts (fetch + form/json/multipart), types.ts, ovpn.ts
- [x] Композаблы: useToasts, useServerSettings, useUsers
- [x] Оболочка: AppShell (топбар, роль, nav)
- [x] Экран Users: Toolbar (поиск, hide revoked, add), UsersTable, StatusPill, MetricStrip
- [x] Сборка `npm run build` зелёная, `docker compose build` зелёный, стек поднимается, список юзеров грузится
- [x] Модалка Add user (валидация, ошибки)
- [x] Change password
- [x] Rotate (+пароль)
- [x] Revoke / Unrevoke / Delete / Disconnect (ConfirmModal)
- [x] Show / Copy / Download `.ovpn` (ConfigModal)
- [x] Редактор CCD-маршрутов (статич. адрес + подтаблица, master/slave readonly)
- [x] ModalShell на reka-ui Dialog (фокус-ловушка, Esc, ARIA, scroll-lock)
- [x] Персист фильтров (localStorage — в useUsers)
- [x] Прогон флоу через CDP: add / config / revoke / rotate / ccd — ок
- [x] Столбец трафика за сессию (`api/user/statistic`) + поллинг 15с
- [x] MetricStrip: живые данные (суммарный трафик + онлайн)
- [x] a11y: aria-hidden на svg, aria-label на +/✕, фокус входит в модалку (reka-ui)
- [x] Прогон через nginx+Basic Auth (headless CDP с Authorization) — рендерится, API 200
- [x] CI-smoke зелёный на всех коммитах ветки; бандл 169 kB / 60 kB gzip
- [x] PR #5 frontend-v3 → master — draft снят

## Осталось / проверить в реальном деплое

- цифры трафика в столбце — локально всегда «—» (никто не подключён);
  проверить с реальным OpenVPN-клиентом
- Basic Auth: браузер сам шлёт Authorization в fetch после ввода в prompt nginx —
  подтверждено эмуляцией, но стоит глянуть вживую
- при желании: self-host шрифтов IBM Plex вместо Google Fonts (сейчас внешняя
  зависимость на fonts.googleapis.com)
- вкладка Metrics (Grafana kiosk iframe) — не делал, решается вместе с судьбой Grafana

## Заметки / решения

- Компоненты: headless (reka-ui) + свой CSS. Библиотеку компонентов не берём —
  приложение маленькое, подгонять чужую тему под макет дороже.
- Состояние — composables, без Pinia и Router.
- `duplicate-cn` в setup выключен → столбец Connections убран (0/1 дублирует статус).
- Дата отзыва сертификата убрана из таблицы.
- **ovpn-admin отдаёт `Content-Type: text/plain` даже для JSON** — `client.ts`
  парсит по первому символу тела (`{`/`[`), иначе возвращает текст.
- TypeScript запинен на `^6` — `vue-tsc@3` несовместим с TS 7 (нативный порт,
  сломанный `./lib/tsc` в exports). `baseUrl` в tsconfig убран (deprecated в TS 7).
- Vite → `outDir: static`, `base: './'`. `Dockerfile.ovpn-admin` не менялся —
  `npm ci && npm run build` теперь запускает Vite. `.dockerignore`/`.gitignore`:
  `frontend/static/dist` → `frontend/static`.
- Basic Auth: браузер сам подставляет Authorization в same-origin `fetch` после
  ввода кред в prompt nginx. headless-Chrome с `user:pass@` в URL так не делает —
  тестировать фронт против прямого порта ovpn-admin (8080, без nginx).
- Дев-цикл: `docker run --network host node:22-alpine npm run dev` (Vite proxy
  `/api` → `127.0.0.1:8080`), нужен поднятый стек с проброшенным `127.0.0.1:8080:8080`.
