# install/ — журнал отладки и решений

Дополняет `README.md` (там — архитектура). Здесь — что ломалось на живых
прогонах и почему код такой. Новые находки дописывать сверху.

---

## 2026-09-06 — «неправильные ссылки на подписки» = баг nginx `$host`

Проверено на живом `REDACTED-IP` (3x-ui v3.4.2, `ghcr.io/mhsanaei/3x-ui:v3.4.2`)
curl'ом по реальным эндпоинтам + чтением `x-ui.db` и `docker logs` nginx.

### Что оказалось на самом деле

Раньше NOTES утверждали, что QR/«копировать» в панели за прокси на `:8443`
«склеивают URL без пути». **Это не воспроизвелось.** В v3.4.2 фронтенд
(`frontend/src/pages/clients/SubLinksModal.tsx`, `ClientQrModal.tsx`) строит
ссылку клиента буквально как `subURI + subId`, и показывает её только если
`subURI` непустой. Пока `xui-enable-sub` прописывает `subURI` (полный
`https://<ip>:8443<subPath>`), кнопка и QR дают корректный полный URL.

Реальная поломка — в другом: 3x-ui собирает **абсолютные** URL (ссылки в
самой подписке, заголовок `Profile-Web-Page-Url`, request-derived база в
`SubService.ResolveRequest` / `BuildURLs`) из заголовка `Host` запроса и
`X-Forwarded-Proto`. Живой `nginx.conf` слал `proxy_set_header Host $host`,
а `$host` **срезает порт**. Результат по curl:

    Profile-Web-Page-Url: https://REDACTED-IP/sub-.../<subId>   ← без :8443

то есть ссылка на страницу подписки указывала на `:443` (REALITY-заглушка).
С `Host: <ip>:8443` вручную заголовок сразу правильный. Панельный `location`
к тому же не слал `X-Forwarded-Proto` → scheme мог выйти `http`.

Апстрим-обсуждение и рекомендация — [`MHSanaei/3x-ui#3289`](https://github.com/MHSanaei/3x-ui/issues/3289)
и доки [Reverse Proxy](https://docs.sanaei.dev/docs/operations/reverse-proxy/):
`Host $http_host`, `X-Forwarded-Proto`, проброс `Range`/`If-Range`.
`proxy_redirect off` из того обсуждения **не берём** — там `proxy_pass`
без пути + `rewrite`, а у нас `proxy_pass` с базовым путём, где default
`proxy_redirect` как раз нужен, чтобы не утёк upstream-хост в `Location`.

### Фикс (в этом коммите)

`templates/nginx.conf.tmpl`, все `location` секций VLESS + OpenVPN:
- `Host $host` → `Host $http_host` (сохраняет `:8443`);
- `X-Forwarded-Proto $scheme` добавлен в панельный и ovpn-admin блоки;
- `Range`/`If-Range` проброшены в sub- и json-sub-блоки.

Проверено на живом сервере: до фикса `curl` подписки отдавал
`Profile-Web-Page-Url: https://REDACTED-IP/sub-…` (без порта), после
патча `Host $http_host` + reload nginx — `https://REDACTED-IP:8443/sub-…`.

Сам контент подписки был корректен и до фикса: `externalProxy` даёт
`vless://…@<public_ip>:443`, `fp=firefox`, `pbk`/`sid`/`sni` на месте;
Happ на Android тянул подписку с кодом 200 (видно в `docker logs nginx`).

### Решили ли это в свежих 3x-ui? — Нет, механизм тот же

v3.5 → v3.7 (v3.6.0 «Subscription Correctness»). `SubService.ResolveRequest`
всё так же строит абсолютные URL как `X-Forwarded-Host || Request.Host` +
`X-Forwarded-Proto`. То есть nginx с `Host $host` (без порта) даёт кривой
URL и на v3.7 — лечится только `$http_host`, либо `X-Forwarded-Host` с
портом, либо `subURI`. Кнопка/QR в панели по-прежнему `subURI + subId`.

Что **добавили** в v3.6.0 (PR #6135, `internal/sub/forwarded_trust.go`):
настройку **`trustedProxyCIDRs`** (дефолт `127.0.0.1/32,::1/128`). Если её
увести от дефолта, 3x-ui доверяет `X-Forwarded-*` только когда
`RemoteAddr` прокси попадает в эти CIDR, иначе **игнорирует** форвард-хедеры
и берёт хост запроса + пишет варнинг («set subURI, or add the proxy…»).
Пока значение = дефолту, хедеры принимаются от кого угодно (обратная
совместимость). **Для нас:** nginx-контейнер стучится к host-mode 3x-ui с
адреса docker-моста (172.x), не с loopback. Если когда-нибудь тронем
`trustedProxyCIDRs` — вписать туда `172.16.0.0/12` (или просто
полагаться на `subURI`, он у нас и так выставлен).

Прочие sub-фиксы v3.6.0 (Clash YAML-скаляры, VLESS flow в JSON, дубль
fingerprint в externalProxy tlsSettings, имена внешних ссылок) — общая
корректность, нашей проблемы не касаются.

### Ещё замечено на тест-сервере (не баг кода)

- `subJsonEnable`/`subJsonURI` в `x-ui.db` **не выставлены** → `/json-…/`
  отдаёт 404, панель прячет JSON-ссылки. `cmd_xui_enable_sub` их пишет —
  на этом сервере правили руками до того. Чистый `setup.sh` поставит.
- `spx` (spiderX) в ссылке рандомится на каждый запрос — так устроен
  3x-ui v3.4.2, не поломка.

### Доступ к тест-серверу

sshd захардён (`bootstrap.sh sshd-harden`): порт **28848**, `PermitRootLogin no`,
рабочий юзер — `ramdll` (группы `sudo`, `docker`). Не `root` на 22, как можно
подумать. Копия `x-ui.db` осталась в `~/xui-inspect/` на сервере (там `secret`,
`panelGuid` — можно удалить).

## 2026-09-05 — телефон не подключался по VLESS

Диагностика велась на тестовом сервере `REDACTED-IP` (Debian 13),
сравнением с эталонным `YukiKras/vless-scripts` 3x-ui на том же IP.

### Три причины, все в установщике, все пофикшены

1. **Пустой `pbk` в ссылке (парсинг `xray x25519`).**
   `install-vpn.sh` доставал публичный ключ через `grep 'Public'`.
   xray-core ≥ 25.x (в запиненной 3x-ui v3.4.2 это xray 25.8.29)
   переименовал строку вывода в `Password:`. `pub` выходил пустым,
   ссылка уходила с `pbk=` пустым, REALITY не аутентифицировался.
   Фикс: матчим `password|public`, валидируем 43-символьный base64url.
   Коммит `473fd6f`.

2. **`fp=chrome` режется мобильным оператором.**
   С валидным `pbk` хэндшейк проходил (`XtlsPadding`/`splice` в логе
   клиента), но трафик не шёл — `dial ... operation was canceled`.
   Побайтовый перебор параметров ссылки против рабочего YukiKras:
   SNI (`<ip>.sslip.io` vs случайный `.ru`), `xver`, `allowInsecure`,
   контент заглушки, длина `shortId` — **всё исключено**. Решает `fp`:
   `chrome` (самый массовый uTLS-отпечаток → наиболее сигнатурно
   отслеживаемый DPI) не работает, `firefox` при прочих равных —
   работает. Дефолт сменён на `firefox` в `install-vpn.sh` и `setup.sh`.
   README §9 раньше советовал `chrome` — логика инвертировалась.
   Коммит `43dcc02`. **Замечание:** это, возможно, специфично для
   конкретного оператора; если `firefox` тоже начнёт резать — пробовать
   `safari`/`ios`, значение в `cmd_vless_create`, локальная переменная.

3. **Ссылки из панели 3x-ui — с пустым `pbk`.**
   `streamSettings` инбаунда содержал `realitySettings.privateKey`, но
   не `realitySettings.settings.publicKey`. xray на инбаунде это поле
   игнорирует, а 3x-ui читает ИМЕННО его при построении клиентских
   ссылок/QR/подписки. Любая ссылка, созданная через панель (второй
   клиент, перегенерённый QR), уходила с `pbk=` пустым.
   Фикс: пишем `settings.{publicKey,fingerprint,serverName,spiderX}`.
   Коммит `63bf3be`.

### Что НЕ подтвердилось из первичного аудита

- Авто-ребут `unattended-upgrades` 04:00 — **в коде и на сервере
  корректен**, пишется в `50unattended-upgrades-ovpn-stack.conf`
  (смотрел не тот файл).
- nftables — рендерится в `/etc/nftables.conf`, ruleset грузится,
  панель `2053` закрыта политикой drop. Всё как задумано.

### Happ — это xray-core, не sing-box

README раньше писал «sing-box (Happ)». Happ использует xray-core для
прокси, sing-box — только для TUN-режима. Есть форк `Happ-proxy/Xray-core`.

### «Ошибка TLS-рукопожатия» во встроенном пинге клиента

Тест задержки в Happ/др. делает обычный TLS-хендшейк к `IP:443` с SNI,
без слоя REALITY → получает self-signed сертификат fakesite → «ошибка».
Это норма, не поломка. Диагностировать VLESS только по реальному трафику.

### Подписка 3x-ui (добавлена как фича, ветка feat/subscriptions)

Изначально не поддерживалась. Что сделано:
- `bootstrap.sh` — nftables пускает `2096` с `docker0`/`br-*` (как `2053`).
- `nginx.conf.tmpl` — `location` для `@@SUB_PATH@@` и `@@SUB_JSON_PATH@@`
  → `host.docker.internal:2096`.
- `install-vpn.sh xui-enable-sub` — правит `x-ui.db` напрямую (флагов
  в `x-ui setting` нет, panel-API требует CSRF): `subEnable`,
  `subPort=2096`, `subPath`/`subJsonPath` рандомные, `subURI` =
  полный базовый URL с путём.
- `vless-create` — `externalProxy` на `<public_ip>:443` (иначе адрес
  в подписке = `172.x` от прокси); первому клиенту ставит `subId`.
- `setup.sh` — генерит пути, прокидывает, печатает URL подписки в сводку.

**Ограничение:** QR/«копировать» в панели 3x-ui за прокси на `:8443`
без домена дают битый URL (без пути). Рабочий = `subURI + subId`,
он в сводке; для новых клиентов собирать вручную. Патчить фронтенд
3x-ui сочли не стоящим того.

### Прочее в этой серии (коммит 473fd6f)

- `.gitignore` — `install-render/` и `/state/` (секреты при запуске
  установщика из git-чекаута, напр. `/opt/ovpn-stack`).
- `bootstrap.sh` — обрезка `sshd_config.d/*.bak.*` до 3 последних
  (накапливались десятки на идемпотентных прогонах).
- README — xray в 3x-ui v3.4.2 это **25.8.29**, не 26.6.27.

### Состояние тестового сервера

На `REDACTED-IP` всё выше применено **вручную** (правка `x-ui.db`,
nginx-конфига, `/etc/nftables.conf`) — до того, как это стало кодом.
Это **не эталонный** чистый прогон. Чистый `setup.sh` с текущим кодом
сделает то же самое штатно. Снапшот прежнего состояния:
`/root/ovpn-stack-snapshot-<ts>`. Пароль панели сброшен на
`admin`/`Testpass123` — сменить. Временный доступ (sudoers drop-in +
ssh-ключ) — снять.

### Открытые вопросы

- `webPort`/`subPort` панель считает «широко известными» (2053/2096).
  Наружу закрыты firewall'ом, реальная точка входа — `:8443` по
  неочевидному пути. Рандомизировать внутренние порты — можно (правка
  nginx + nftables), но выгода мала. Не сделано.
- Идемпотентность: `setup.sh` генерит новые `subPath`/`webBasePath` на
  каждом прогоне → старые URL подписок/панели ломаются при доустановке
  режима. Так же ведёт себя `webBasePath` панели (README §5). Возможно,
  стоит сделать пути стабильными между прогонами.
