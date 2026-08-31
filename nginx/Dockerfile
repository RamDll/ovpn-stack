FROM nginx:1.27-alpine

# htpasswd для генерации Basic Auth из переменных окружения
RUN apk add --no-cache apache2-utils

# скрипт отрабатывает автоматически перед стартом nginx
# (штатный механизм образа: /docker-entrypoint.d/*.sh)
COPY 40-htpasswd.sh /docker-entrypoint.d/40-htpasswd.sh
RUN chmod +x /docker-entrypoint.d/40-htpasswd.sh
