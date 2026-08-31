# ovpn-admin-hardened

Форк [palark/ovpn-admin](https://github.com/palark/ovpn-admin) с усиленной конфигурацией OpenVPN-сервера.

## Что изменено относительно оригинала

- **Протокол**: UDP вместо TCP по умолчанию (`setup/configure.sh`)
- **Шифрование**: `AES-256-GCM` вместо `AES-128-CBC`
- **TLS**: `tls-crypt` вместо `tls-auth`, `tls-version-min 1.2`, `auth SHA256`
- **Redirect-gateway**: весь трафик клиента идёт через VPN (`templates/client.conf.tpl`)
- **DNS**: кастомные DNS-серверы вместо DNS провайдера
- **Аутентификация**: только по сертификату, без пароля (`OVPN_AUTH: "false"`)

## Быстрый старт

1. Клонировать репозиторий:
```bash
   git clone git@github.com:RamDll/ovpn-admin-hardened.git
   cd ovpn-admin-hardened
```

2. Создать `.env` с публичным IP вашего сервера:
```bash
   echo "VPS_PUBLIC_IP=ВАШ_IP" > .env
```

3. Запустить:
```bash
   ./start.sh
```

Панель ovpn-admin будет доступна на `127.0.0.1:8080` внутри сервера — снаружи рекомендуется закрывать через reverse proxy (nginx) с TLS и Basic Auth, порт наружу не публиковать напрямую.

## Требования

- Docker + Docker Compose
- Порт `7777/udp` открыт в firewall
