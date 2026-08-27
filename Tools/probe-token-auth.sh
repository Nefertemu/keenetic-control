#!/bin/bash
# Перебирает способы передать токен доступа Keenetic в HTTP-запросе.
# Токен вводится скрыто, никуда кроме твоего роутера не уходит.
#
#   ./probe-token-auth.sh https://адрес-роутера/ [пользователь]

set -uo pipefail

BASE="${1:-}"
USER_NAME="${2:-admin}"
[ -z "$BASE" ] && { echo "Укажи адрес: $0 https://адрес-роутера/ [пользователь]"; exit 2; }
BASE="${BASE%/}"

PROBE="$BASE/rci/show/version"

printf 'токен доступа (ввод скрыт): '
stty -echo; IFS= read -r T; stty echo; printf '\n\n'
[ -z "$T" ] && { echo "Пустой токен."; exit 2; }

echo "проверяю: $PROBE"
echo "успехом считается HTTP 200 с непустым телом"
echo

WINNERS=""

# $1 — описание, дальше — аргументы curl
try() {
    local name="$1"; shift
    local out code size
    out=$(curl -sS -m 12 -o /dev/null -w '%{http_code} %{size_download}' "$@" 2>/dev/null) || out="000 0"
    code="${out%% *}"; size="${out##* }"
    printf '  %-42s HTTP %-4s %s байт\n' "$name" "$code" "$size"
    if [ "$code" = "200" ] && [ "$size" -gt 2 ]; then
        WINNERS="$WINNERS
  $name"
    fi
}

echo "— заголовки —"
try "Authorization: Bearer"        -H "Authorization: Bearer $T"        "$PROBE"
try "Authorization: Token"         -H "Authorization: Token $T"         "$PROBE"
try "Authorization: <токен>"       -H "Authorization: $T"               "$PROBE"
try "X-NDM-Token"                  -H "X-NDM-Token: $T"                 "$PROBE"
try "X-NDM-Auth"                   -H "X-NDM-Auth: $T"                  "$PROBE"
try "X-Ndmp-Tkn"                   -H "X-Ndmp-Tkn: $T"                  "$PROBE"
try "X-NDM-Tkn"                    -H "X-NDM-Tkn: $T"                   "$PROBE"
try "X-Auth-Token"                 -H "X-Auth-Token: $T"                "$PROBE"

echo
echo "— cookie —"
try "Cookie: ndmp-tkn"             -H "Cookie: ndmp-tkn=$T"             "$PROBE"
try "Cookie: token"                -H "Cookie: token=$T"                "$PROBE"
try "Cookie: auth-token"           -H "Cookie: auth-token=$T"           "$PROBE"

echo
echo "— параметр запроса —"
try "?token="                      "$PROBE?token=$T"
try "?tkn="                        "$PROBE?tkn=$T"
try "?access_token="               "$PROBE?access_token=$T"

echo
echo "— HTTP Basic —"
try "Basic  пользователь:токен"    -u "$USER_NAME:$T"                   "$PROBE"
try "Basic  токен:<пусто>"         -u "$T:"                             "$PROBE"

echo
echo "— обмен на сессию через /auth —"
for BODY in "{\"token\":\"$T\"}" \
            "{\"login\":\"$USER_NAME\",\"token\":\"$T\"}" \
            "{\"tkn\":\"$T\"}" \
            "{\"login\":\"$USER_NAME\",\"password\":\"$T\"}"; do
    JAR=$(mktemp)
    POST=$(curl -sS -m 12 -c "$JAR" -o /dev/null -w '%{http_code}' \
           -H 'Content-Type: application/json' -d "$BODY" "$BASE/auth" 2>/dev/null) || POST="000"
    SHOWN=$(printf '%s' "$BODY" | sed "s/$T/<токен>/")
    if [ "$POST" = "200" ] || [ "$POST" = "204" ]; then
        try "/auth $SHOWN → сессия" -b "$JAR" "$PROBE"
    else
        printf '  %-42s HTTP %s\n' "/auth $SHOWN" "$POST"
    fi
    rm -f "$JAR"
done

T=""
echo
if [ -n "$WINNERS" ]; then
    echo "СРАБОТАЛО:$WINNERS"
    echo
    echo "Покажи эту строку — встрою в приложение."
else
    echo "Ни один способ не подошёл."
    echo "Значит токены рассчитаны только на службы Keenetic (NDMP) и как"
    echo "обычные HTTP-креденшелы не работают. Тогда остаётся SSH или ndw4."
fi
