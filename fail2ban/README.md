# fail2ban для ovpn-stack

Стек за nginx с Basic Auth (панель `/`). OpenVPN здесь только по сертификату
(`tls-crypt` + CA), брутфорса на `:7777/udp` нет — пакет без валидного HMAC
молча отбрасывается. Реальная поверхность перебора — Basic Auth на `:443`,
её и закрывает fail2ban.

nginx контейнеризован и пишет логи в stdout/stderr. Чтобы fail2ban (работает на
хосте) их видел, `server`-блок дублирует лог в `./nginx/f2b-log/` — каталог
смонтирован в контейнер как `/var/log/f2b` (см. `docker-compose.yaml`).

## Установка на хост

```bash
sudo cp fail2ban/action.d/docker-user.conf   /etc/fail2ban/action.d/
sudo cp fail2ban/jail.d/ovpn-stack.local     /etc/fail2ban/jail.d/
# поправьте logpath в ovpn-stack.local, если стек лежит не в /home/deploy/ovpn-stack
sudo systemctl restart fail2ban          # именно restart: reload не пересоздаёт banaction
sudo fail2ban-client status nginx-http-auth
```

> `fail2ban-client reload` не меняет `banaction` уже работающего джейла —
> при установке или смене действия нужен `systemctl restart fail2ban`.

Используется штатный фильтр `nginx-http-auth` (идёт в комплекте fail2ban) —
джейл переопределяет `logpath` на лог контейнера и `banaction` на `docker-user`.
Порог: 5 отказов Basic Auth за 10 минут → бан на час.

`docker-user` (`action.d/docker-user.conf`) добавляет `iptables -I DOCKER-USER
-s <ip> -j DROP`. Пакеты к опубликованным портам контейнера идут через
`FORWARD` → `DOCKER-USER`, а не через `INPUT`, поэтому обычный бан
`ufw`/`iptables -I INPUT` их не блокирует (а ufw-бан ещё и рубит SSH на хосте).

## Проверка

```bash
# с ДРУГОГО адреса (5 попыток → бан):
for i in $(seq 1 5); do curl -sk -o /dev/null -u admin:wrong https://<IP>/; done
sudo fail2ban-client status nginx-http-auth     # Banned IP list: <ваш ip>
sudo iptables -S DOCKER-USER                    # -A DOCKER-USER -s <ip> -j DROP
sudo fail2ban-client unban <ip>                 # снять
```

Бан режет доступ к `:443` (и `:7777`), но НЕ к SSH на хосте — если случайно
забанил себя, зайти по ssh и `fail2ban-client unban` всегда можно.
