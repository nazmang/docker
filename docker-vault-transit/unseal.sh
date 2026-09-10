#!/usr/bin/env bash
#
# Unseal the transit Vault on dkr01 from your own machine.
#
#   ./unseal.sh          unseal, reading keys from $VAULT_TRANSIT_KEYS or a prompt
#   ./unseal.sh -s       report seal status only, change nothing
#
# Talks to Vault's HTTP API directly. No ssh, no docker, nothing to log into --
# the service publishes 8200 on the host and the API is all that is needed.
#
# Each key travels in the request body, fed to curl over stdin (-d @-). It never
# appears in a command line, so it cannot be read out of `ps` on either machine.
# An earlier version shelled out to `vault operator unseal` over ssh; that put
# the key either in argv or in a docker exec argument, and `unseal -` reading
# stdin did not survive the ssh/docker chain anyway.
#
# Keys come from, in order:
#   1. $VAULT_TRANSIT_KEYS -- a file with one base64 key per line
#   2. an interactive prompt (input hidden)
#
# The key file must never live in a git repository. ~/.vault-transit-keys with
# mode 600 is a reasonable home for it.

set -euo pipefail

ADDR="${VAULT_TRANSIT_ADDR:-http://10.163.11.105:8200}"
KEYFILE="${VAULT_TRANSIT_KEYS:-$HOME/.vault-transit-keys}"
CURL=(curl -sS --connect-timeout 10 --max-time 30)

seal_status() {
    "${CURL[@]}" "${ADDR}/v1/sys/seal-status"
}

report() {
    seal_status | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.stderr.write("не удалось разобрать ответ Vault\n")
    sys.exit(1)
print("  запечатан :", d.get("sealed"))
print("  прогресс  :", str(d.get("progress")) + "/" + str(d.get("t")))
print("  версия    :", d.get("version"))
'
}

is_unsealed() {
    seal_status | grep -q '"sealed":false'
}

main() {
    if ! seal_status >/dev/null 2>&1; then
        echo "Vault по адресу ${ADDR} не отвечает." >&2
        echo "Проверьте: ssh nazman@10.163.11.105 'sudo docker service ls | grep vault-transit'" >&2
        exit 1
    fi

    if [[ "${1:-}" == "-s" ]]; then
        report
        exit 0
    fi

    if is_unsealed; then
        echo "Уже распечатан, делать нечего."
        report
        exit 0
    fi

    local -a keys=()
    if [[ -f "$KEYFILE" ]]; then
        echo "Читаю ключи из ${KEYFILE}"
        while IFS= read -r line; do
            [[ -n "$line" && "$line" != \#* ]] && keys+=("$line")
        done < "$KEYFILE"
    else
        echo "Файла ${KEYFILE} нет — введите ключи вручную (пустая строка завершает ввод)."
        while true; do
            read -rsp "  ключ: " k; echo
            [[ -z "$k" ]] && break
            keys+=("$k")
        done
    fi

    if [[ ${#keys[@]} -eq 0 ]]; then
        echo "Ключей не получено." >&2
        exit 1
    fi

    local i=0
    for k in "${keys[@]}"; do
        i=$((i + 1))
        # -d @- keeps the key out of argv; python builds the JSON so that a key
        # containing quotes or backslashes cannot break out of the body.
        if ! printf '%s' "$k" | python3 -c 'import sys,json; print(json.dumps({"key": sys.stdin.read().strip()}))' \
             | "${CURL[@]}" -X PUT -d @- "${ADDR}/v1/sys/unseal" >/dev/null 2>&1; then
            echo "  ключ ${i}: запрос не прошёл" >&2
            continue
        fi
        if is_unsealed; then
            echo "Распечатан (использовано ключей: ${i})."
            report
            exit 0
        fi
    done

    echo "Ключи закончились, а Vault всё ещё запечатан." >&2
    report
    exit 1
}

main "$@"
