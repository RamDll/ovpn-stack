#!/bin/sh
# Генерирует /etc/nginx/.htpasswd из BASIC_AUTH_USER / BASIC_AUTH_PASSWORD.
# Запускается автоматически штатным entrypoint'ом nginx перед стартом сервера.
set -e

if [ -z "${BASIC_AUTH_USER}" ] || [ -z "${BASIC_AUTH_PASSWORD}" ]; then
    echo >&2 "[40-htpasswd] BASIC_AUTH_USER / BASIC_AUTH_PASSWORD не заданы — Basic Auth не настроен, отказ."
    exit 1
fi

htpasswd -bc /etc/nginx/.htpasswd "${BASIC_AUTH_USER}" "${BASIC_AUTH_PASSWORD}" >/dev/null 2>&1
echo "[40-htpasswd] .htpasswd сгенерирован для пользователя '${BASIC_AUTH_USER}'"
