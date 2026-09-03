# Хардненинг хоста под ovpn-stack

Чек-лист для VPS, на котором крутится стек. Проверено на Debian 13 (trixie),
команды даны для Debian/Ubuntu. Сам стек уже настроен безопасно (см. раздел
«Что даёт стек из коробки»); всё остальное — на хосте.

## Что даёт стек из коробки

Действий не требует, просто держите в уме:

- Панель — за Basic Auth на nginx, `.htpasswd` собирается из `.env` при старте
  и в репозиторий не попадает.
- OpenVPN — только по клиентскому сертификату (EC prime256v1), `tls-crypt`,
  `AES-256-GCM`, `auth SHA256`, `tls-version-min 1.2`.
- Наружу публикуются только `80/tcp`, `443/tcp`, `7777/udp`. `ovpn-admin:8080`
  живёт в compose-сети и наружу не выставляется.
- `.env` с паролями — держите `chmod 600`, владелец root.

## 1. Firewall (ufw)

```bash
sudo apt-get install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw default deny routed         # форвардингом рулит docker/openvpn сам
sudo ufw allow OpenSSH               # или конкретный порт ssh
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 7777/udp
sudo ufw enable
sudo ufw status verbose
```

Периодически проверяйте `ufw status` — не осталось ли открытых портов от старых
экспериментов (частый случай: `6080/tcp` от noVNC, порты панелей и т.п.).

## 2. SSH

Только по ключу, root запрещён. Drop-in, чтобы не трогать основной конфиг:

```bash
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers deploy
EOF
sudo sshd -t && sudo systemctl reload ssh
```

Обязательно: **до закрытия текущей сессии** откройте новое подключение и
убедитесь, что заходит. `AllowUsers` замените на своего пользователя.

На Debian 13 ssh может быть на сокет-активации (`ssh.socket`). Если после
манипуляций с `apt`/`systemctl` порт 22 отвечает «Connection refused» —
с консоли провайдера: `systemctl enable --now ssh.socket` (или `ssh.service`).

## 3. sysctl

```bash
sudo tee /etc/sysctl.d/99-hardening.conf >/dev/null <<'EOF'
kernel.kptr_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.dmesg_restrict = 1
net.ipv4.conf.all.log_martians = 1
EOF
sudo sysctl -p /etc/sysctl.d/99-hardening.conf
```

`net.ipv4.ip_forward` включает контейнер openvpn сам, руками ставить не нужно.

## 4. Автообновления безопасности

```bash
sudo apt-get install -y unattended-upgrades
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
```

Не запускайте `systemctl enable --now unattended-upgrades` — `--now` инициирует
немедленный прогон; на Debian 13 это спровоцировало каскад `daemon-reload` и
падение сокет-активированного sshd. Достаточно файла выше — обновления пойдут
по `apt-daily-upgrade.timer`.

Ядро обновляется, но активируется только после перезагрузки — раз в пару недель
проверяйте `ls /var/run/reboot-required` и перезагружайтесь в удобное окно.
Стек поднимется сам (`restart: unless-stopped`), клиентам OpenVPN нужно ~1–2 мин
на переподключение.

## 5. fail2ban

```bash
sudo apt-get install -y fail2ban
```

`[sshd]` включите штатно. Для панели — конфиг в каталоге `fail2ban/` репозитория,
установка описана в `fail2ban/README.md`. Ключевой момент: бан идёт правилом в
цепочке `DOCKER-USER` (трафик к портам контейнера минует `INPUT`), поэтому
обычный `banaction = ufw` панель не защищает, а SSH хоста — рубит.

## 6. Минимум пакетов

VPN-шлюзу не нужен графический стек. Если на боксе оказались XFCE / GNOME /
LightDM / Xorg / VNC / браузер — снесите:

```bash
sudo systemctl disable --now lightdm
sudo systemctl set-default multi-user.target
sudo apt-get purge -y 'xserver-xorg*' 'xfce4*' lightdm* tigervnc* novnc websockify chromium*
sudo apt-get autoremove --purge -y
```

Аналогично `avahi-daemon` (mDNS, слушает `0.0.0.0:5353`):

```bash
sudo systemctl disable --now avahi-daemon
sudo apt-get purge -y avahi-daemon avahi-utils libnss-mdns
```

После — проверьте, что слушает наружу:

```bash
sudo ss -tulnp | grep -vE '127.0.0.1|::1'
# ожидаемо: только 22, 80, 443/tcp и 7777/udp
```

## 7. Регулярное обслуживание

- `ls /var/run/reboot-required` → перезагрузка при обновлении ядра.
- `sudo fail2ban-client status sshd` → бан работает, реальные атаки ловятся.
- `docker compose ps` → все healthy; после ребута дождаться переподключения клиентов.
- Резервировать `./data/` (PKI с приватными ключами, ccd, `stat/traffic.db`).
- TLS-сертификат: `acme.sh --cron` в root-cron; reloadcmd —
  `docker exec ovpn-stack-nginx-1 nginx -s reload`.
- Отзывать выданные CI/деплою токены (GitHub PAT и т.п.), когда они больше не нужны.
