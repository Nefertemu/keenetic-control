#!/bin/bash
# Проверяет пароль веб-панели Keenetic тем же алгоритмом, что и приложение.
# Пароль вводится скрыто и никуда не уходит: только на сам роутер.
#
#   ./check-rci-password.sh https://адрес-роутера/ [пользователь]

set -uo pipefail

BASE="${1:-}"
USER_NAME="${2:-admin}"

if [ -z "$BASE" ]; then
    echo "Укажи адрес: $0 https://адрес-роутера/ [пользователь]"
    exit 2
fi
BASE="${BASE%/}"

JAR="$(mktemp)"
trap 'rm -f "$JAR"' EXIT

HEADERS="$(curl -sS -m 15 -L -c "$JAR" -D - -o /dev/null "$BASE/auth" 2>&1)" || {
    echo "Роутер не ответил: $HEADERS"; exit 1
}

CODE=$(printf '%s' "$HEADERS"  | grep -iE '^HTTP/' | tail -1 | awk '{print $2}')
REALM=$(printf '%s' "$HEADERS" | grep -i '^X-NDM-Realm:'     | tail -1 | sed 's/[^:]*: *//' | tr -d '\r')
CHAL=$(printf '%s' "$HEADERS"  | grep -i '^X-NDM-Challenge:' | tail -1 | sed 's/[^:]*: *//' | tr -d '\r')

echo "адрес:        $BASE"
echo "ответ /auth:  HTTP $CODE"
echo "realm:        ${REALM:-<нет>}"

if [ "$CODE" = "200" ]; then
    echo "Роутер уже пускает без пароля — сессия открыта."
    exit 0
fi
if [ -z "$REALM" ] || [ -z "$CHAL" ]; then
    echo "Это не веб-панель Keenetic: нет X-NDM-Realm/X-NDM-Challenge."
    exit 1
fi

printf 'пароль для «%s» (ввод скрыт): ' "$USER_NAME"
stty -echo; IFS= read -r PASS; stty echo; printf '\n'

MD5=$(printf '%s' "$USER_NAME:$REALM:$PASS" | md5 -q)
SHA=$(printf '%s' "$CHAL$MD5" | shasum -a 256 | cut -d' ' -f1)
PASS=""

RESULT=$(curl -sS -m 15 -b "$JAR" -c "$JAR" -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -d "{\"login\":\"$USER_NAME\",\"password\":\"$SHA\"}" \
    "$BASE/auth")

echo "ответ на вход: HTTP $RESULT"
case "$RESULT" in
    2*) echo
        echo "ПАРОЛЬ ВЕРНЫЙ. Значит дело в приложении — покажи этот вывод."
        CFG=$(curl -sS -m 30 -b "$JAR" -o /dev/null -w '%{http_code} %{size_download} байт' \
              "$BASE/ci/running-config.txt")
        echo "конфигурация:  HTTP $CFG"
        ;;
    401) echo
         echo "ПАРОЛЬ НЕ ПОДОШЁЛ. Веб-панель ждёт другой пароль, чем SSH,"
         echo "либо пользователь не «$USER_NAME»."
         ;;
    400) echo
         echo "Запрос пришёл вне сессии — проблема с cookie, а не с паролем."
         ;;
    *)   echo
         echo "Неожиданный ответ."
         ;;
esac
