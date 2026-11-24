#!/bin/bash
# pangolin-update.sh — автообновление стека Pangolin (Pangolin, Gerbil, Traefik,
# Badger, CrowdSec) с проверкой работоспособности и автоматическим откатом.
#
# Версия 1.0 (23.11.2026). История изменений — CHANGELOG.md.
# Настройки задаются в /etc/pangolin-update.conf (образец —
# pangolin-update.conf.example); значения ниже — встроенные по умолчанию,
# редактировать сам скрипт не нужно.

set -euo pipefail

PU_VERSION="1.0"

# ─── Коды выхода ─────────────────────────────────────────────────────────────
E_OK=0          # успех / обновлять нечего
E_FAIL=1        # операция не удалась, стек возвращён в прежнее состояние
E_CRIT=2        # откат тоже не удался — нужно ручное вмешательство
E_CROWDSEC=3    # стек в порядке, но CrowdSec не отвечает
E_PRECOND=4     # ничего не изменено: ошибка аргументов, окружения, сети, проверок

# ─── Файл конфигурации ───────────────────────────────────────────────────────
# Загружается ДО значений по умолчанию, поэтому всё, что в нём задано, имеет
# приоритет. Приоритет: файл конфигурации > переменные окружения > значения
# ниже. Файл исполняется от root, поэтому принимается только принадлежащий
# root (или текущему пользователю) и недоступный на запись группе/остальным.
CONFIG_FILE="${PANGOLIN_UPDATE_CONF:-/etc/pangolin-update.conf}"

load_config_file() {
    [[ -e "${CONFIG_FILE}" ]] || return 0
    local owner mode
    owner=$(stat -c '%u' "${CONFIG_FILE}")
    mode=$(stat -c '%a' "${CONFIG_FILE}")
    if [[ "${owner}" != "0" && "${owner}" != "$(id -u)" ]] || (( 8#${mode} & 8#022 )); then
        echo "ОШИБКА: ${CONFIG_FILE}: владелец должен быть root, запись для группы и остальных запрещена (сейчас uid=${owner}, права ${mode})." >&2
        echo "Исправьте: chown root:root ${CONFIG_FILE} && chmod 600 ${CONFIG_FILE}" >&2
        exit "${E_PRECOND}"
    fi
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
}
load_config_file

# ─── Значения по умолчанию ───────────────────────────────────────────────────
# Форма ${VAR-default}: пустое значение в файле конфигурации тоже считается
# заданным (например, HEALTH_IGNORE_SERVICES="" — не игнорировать ничего).

# Пути
PANGOLIN_DIR="${PANGOLIN_DIR-/root/pangolin}"
COMPOSE_FILE="${COMPOSE_FILE-${PANGOLIN_DIR}/docker-compose.yml}"
TRAEFIK_CONFIG="${TRAEFIK_CONFIG-${PANGOLIN_DIR}/config/traefik/traefik_config.yml}"
TRAEFIK_DYNAMIC_CONFIG="${TRAEFIK_DYNAMIC_CONFIG-${PANGOLIN_DIR}/config/traefik/dynamic_config.yml}"
PANGOLIN_DB="${PANGOLIN_DB-${PANGOLIN_DIR}/config/db/db.sqlite}"
LOG_FILE="${LOG_FILE-/var/log/pangolin-update.log}"
LOG_MAX_LINES="${LOG_MAX_LINES-5000}"       # ротация лога при превышении
LOG_KEEP="${LOG_KEEP-5}"                    # сколько ротированных логов (.gz) хранить
LOCK_FILE="${LOCK_FILE-/run/pangolin-update.lock}"
LOCK_WAIT="${LOCK_WAIT-120}"                # сколько секунд ждать другой запуск
STATE_DIR="${STATE_DIR-/var/lib/pangolin-update}"   # кэши и состояние между запусками

# Health check
HEALTH_INITIAL_WAIT="${HEALTH_INITIAL_WAIT-5}"   # пауза перед первой проверкой (сек)
HEALTH_INTERVAL="${HEALTH_INTERVAL-10}"          # интервал между проверками (сек)
HEALTH_RETRIES="${HEALTH_RETRIES-15}"            # максимум попыток
HEALTH_MIN_UPTIME="${HEALTH_MIN_UPTIME-15}"      # контейнер без healthcheck должен проработать столько секунд
RESTART_THRESHOLD="${RESTART_THRESHOLD-3}"       # столько перезапусков после старта = аномалия
HEALTH_IGNORE_SERVICES="${HEALTH_IGNORE_SERVICES-crowdsec-manager}"  # их сбой не вызывает откат
HEALTH_HTTP_CHECK="${HEALTH_HTTP_CHECK-true}"    # проверять запрос через Traefik
HEALTH_URL="${HEALTH_URL-}"                      # пусто = dashboard_url из config/config.yml
HEALTH_HTTP_RESOLVE_IP="${HEALTH_HTTP_RESOLVE_IP-127.0.0.1}"  # куда слать запрос (Traefik на этом хосте)

# Политика обновлений
MIN_RELEASE_AGE_HOURS="${MIN_RELEASE_AGE_HOURS-24}"  # не ставить релизы моложе (0 = сразу)
ALLOW_MAJOR_UPGRADE="${ALLOW_MAJOR_UPGRADE-false}"   # разрешить переход на новую мажорную версию
UPDATE_HOLD="${UPDATE_HOLD-false}"                   # true = обновления приостановлены
HOLD_FILE="${HOLD_FILE-${STATE_DIR}/hold}"           # файл паузы (создаётся -hold)
GITHUB_TOKEN="${GITHUB_TOKEN-}"                      # необязательно: выше лимит GitHub API
PRUNE_MODE="${PRUNE_MODE-previous}"                  # previous | immediate | none

# Резервные копии
BACKUP_DIR="${BACKUP_DIR-/root/pangolin-backups}"
BACKUP_KEEP="${BACKUP_KEEP-7}"                       # архивов и *.bak.* каждого файла
BACKUP_MODE="${BACKUP_MODE-hot}"                     # hot = без остановки стека, cold = с остановкой
BACKUP_MIN_FREE_MB="${BACKUP_MIN_FREE_MB-200}"       # запас свободного места сверх размера данных
LOGS_EXCLUDE="${LOGS_EXCLUDE-config/traefik/logs}"   # не включать в архив (растущие логи)

# Уведомления
NOTIFY_ON="${NOTIFY_ON-problems}"            # problems | all | none
NOTIFY_CMD="${NOTIFY_CMD-}"                  # своя команда; получает PU_LEVEL, PU_EVENT, PU_MESSAGE, PU_HOST, PU_TITLE
NOTIFY_URL="${NOTIFY_URL-}"                  # ntfy-совместимый URL (POST текста)
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID-}"
HEARTBEAT_URL="${HEARTBEAT_URL-}"            # healthchecks.io-совместимый: пинг <URL>/<код выхода>

# Cloudflare
CF_ENV_FILE="${CF_ENV_FILE-${PANGOLIN_DIR}/.cf-dns.env}"
CF_CRON_FILE="${CF_CRON_FILE-/etc/cron.d/pangolin-cf-dns}"
CF_SYNC_INTERVAL="${CF_SYNC_INTERVAL-5}"     # минуты
CF_FULL_RESYNC_MIN="${CF_FULL_RESYNC_MIN-360}"   # полная сверка с Cloudflare не реже (минуты)
CF_DELETE_STALE="${CF_DELETE_STALE-false}"   # удалять СВОИ записи удалённых ресурсов
CF_API="https://api.cloudflare.com/client/v4"
CF_MARK="pangolin-update autosync"           # комментарий записей, которыми управляет скрипт

# Badger и проба плагинов
BADGER_MODULE="github.com/fosrl/badger"
BADGER_PIN="${BADGER_PIN-}"                  # закрепить версию Badger, напр. "v1.7.0"
BADGER_PROBE="${BADGER_PROBE-true}"          # проверять Traefik+плагины до обновления
BADGER_PROBE_WAIT="${BADGER_PROBE_WAIT-30}"  # максимум секунд на пробу
PROBE_CACHE_HOURS="${PROBE_CACHE_HOURS-24}"  # сколько помнить результат пробы

# Сообщения Traefik, означающие, что плагины не загрузились
TRAEFIK_PLUGIN_ERR_RE='Plugins are disabled|unable to set up plugins|unable to download plugin|invalid hash|failed to (get|download|load|check) plugin|middleware "[^"]*(badger|crowdsec)[^"]*" does not exist'

# CrowdSec
CROWDSEC_SERVICE="${CROWDSEC_SERVICE-crowdsec}"
CROWDSEC_AUTO_UPDATE="${CROWDSEC_AUTO_UPDATE-true}"
CROWDSEC_HUB_UPDATE="${CROWDSEC_HUB_UPDATE-true}"

# Allowlist CrowdSec
ALLOWLIST_SYNC="${ALLOWLIST_SYNC-true}"
ALLOWLIST_NAME="${ALLOWLIST_NAME-pangolin-infra}"
ALLOWLIST_EXTRA="${ALLOWLIST_EXTRA-}"                     # IP/подсети через пробел
ALLOWLIST_NEWT="${ALLOWLIST_NEWT-true}"                   # добавлять IP сайтов Newt
ALLOWLIST_NEWT_EXCLUDE="${ALLOWLIST_NEWT_EXCLUDE-}"       # имена сайтов через запятую — не добавлять
ALLOWLIST_NEWT_MAX_AGE_DAYS="${ALLOWLIST_NEWT_MAX_AGE_DAYS-7}"
ALLOWLIST_CRON_FILE="${ALLOWLIST_CRON_FILE-/etc/cron.d/pangolin-allowlist}"
ALLOWLIST_SYNC_INTERVAL="${ALLOWLIST_SYNC_INTERVAL-10}"
SERVER_IP_CACHE_MIN="${SERVER_IP_CACHE_MIN-60}"           # кэш внешнего IP сервера (минуты)

# Установка CrowdSec (-crowdsec-install)
CROWDSEC_IMAGE_TAG="${CROWDSEC_IMAGE_TAG-v1.8.1}"
CROWDSEC_BOUNCER_MODULE="github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin"
CROWDSEC_BOUNCER_VERSION="${CROWDSEC_BOUNCER_VERSION-v1.8.1}"
CROWDSEC_INSTALL_MANAGER="${CROWDSEC_INSTALL_MANAGER-false}"   # веб-интерфейс: только по -with-manager
CROWDSEC_MANAGER_IMAGE="${CROWDSEC_MANAGER_IMAGE-docker.io/hhftechnology/crowdsec-manager:2.4.1@sha256:033dd76360e5f5da01b21084921e1f82cef226ebc53e33f77f4128da8d01be2e}"
CROWDSEC_ENTRYPOINT="${CROWDSEC_ENTRYPOINT-websecure}"
CROWDSEC_BOUNCER_NAME="${CROWDSEC_BOUNCER_NAME-traefik-bouncer}"
CROWDSEC_CLIENT_TRUSTED_IPS="${CROWDSEC_CLIENT_TRUSTED_IPS-}"  # клиенты в обход bouncer (через пробел)
TRAEFIK_LOGROTATE_FILE="${TRAEFIK_LOGROTATE_FILE-/etc/logrotate.d/pangolin-traefik}"
YQ_IMAGE="${YQ_IMAGE-docker.io/mikefarah/yq:4.53.6@sha256:cfc4eee658595834ef304eadb0c3ea721f3b7cb6404ad8b7cb909cc5b5145b23}"

# ─── Состояние выполнения (не настройки) ─────────────────────────────────────
ASSUME_YES=false
DATE_SUFFIX=""
ROLLBACK_DONE=false
ROLLBACK_DB=false
INFO_ONLY=false
DRY_RUN=false
NO_DELAY=false
EDITION_FLAG=""          # "" = авто, "ee" / "ce" = форсировать
ENTERPRISE=false
EDITION_SWITCH=false
ACTION=""
ACTION_ARG=""
MANAGER_FLAG=""
CF_TOKEN=""
CF_TARGET_IP=""
CF_PROXIED=false
STACK_STARTED_AT=""
STACK_STARTED_EPOCH=0
BADGER_HELD_BACK=false
TRAEFIK_HELD_BACK=false
OLD_PANGOLIN_V="" OLD_GERBIL_V="" OLD_TRAEFIK_V="" OLD_BADGER_V="" OLD_CROWDSEC_V=""
PANGOLIN_V="" GERBIL_V="" TRAEFIK_V="" BADGER_V="" CROWDSEC_V=""
PANGOLIN_TAG_EE="" PANGOLIN_TAG_DB="" PANGOLIN_TAG_VER="" PANGOLIN_TAG_ARCH=""
RECOVERY=""              # что делать, если работа прервётся: rollback | start_stack | cs_install | cs_uninstall
RUN_MODE=""              # update | info | dry_run | <действие>
NOTIFIED=false
LAST_ERROR=""
LAST_ARCHIVE=""
HTTP_BASELINE_OK=false
HEALTH_URL_EFFECTIVE=""
CHECK_FAILED=0
FAILED_CONTAINERS=()
PROBE_PULLED=()
CS_NET_SOURCE="" CS_TRAEFIK_CN="" CS_PANGOLIN_CN="" CS_GERBIL_CN=""
RUN_EPOCH=$(date +%s)

# ─── Цвета для вывода в терминал ─────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RESET="\033[0m"; C_GREEN="\033[32m"; C_YELLOW="\033[33m"
    C_RED="\033[31m";  C_CYAN="\033[36m";  C_BOLD="\033[1m"
else
    C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""; C_BOLD=""
fi

# ─── Логирование ─────────────────────────────────────────────────────────────
log() {
    local level="$1"; shift
    local line
    printf -v line '[%(%Y-%m-%d %H:%M:%S)T] [%s] %s' -1 "${level}" "$*"
    [[ "${level}" == ERROR ]] && LAST_ERROR="$*"
    printf '%s\n' "${line}" >> "${LOG_FILE}" 2>/dev/null || true
    case "${level}" in
        INFO)  printf '%b%s%b\n' "${C_CYAN}"   "${line}" "${C_RESET}" ;;
        OK)    printf '%b%s%b\n' "${C_GREEN}"  "${line}" "${C_RESET}" ;;
        WARN)  printf '%b%s%b\n' "${C_YELLOW}" "${line}" "${C_RESET}" ;;
        ERROR) printf '%b%s%b\n' "${C_RED}"    "${line}" "${C_RESET}" >&2 ;;
        *)     printf '%s\n' "${line}" ;;
    esac
}

log_separator() {
    local sep
    sep=$(printf '─%.0s' {1..60})
    printf '%s\n' "${sep}" >> "${LOG_FILE}" 2>/dev/null || true
    printf '%b%s%b\n' "${C_BOLD}" "${sep}" "${C_RESET}"
}

# Лог создаётся с правами 640: в него попадают логи контейнеров.
init_log_file() {
    mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
    if [[ ! -e "${LOG_FILE}" ]]; then
        (umask 027; : >> "${LOG_FILE}") 2>/dev/null || true
    else
        chmod o-rwx "${LOG_FILE}" 2>/dev/null || true
    fi
}

# Ротация: имя с датой и временем (без перезаписи), сжатие, хранится LOG_KEEP файлов.
rotate_log() {
    [[ -f "${LOG_FILE}" ]] || return 0
    local lines rotated
    lines=$(wc -l < "${LOG_FILE}")
    (( lines > LOG_MAX_LINES )) || return 0
    rotated="${LOG_FILE}.$(date +%Y%m%d_%H%M%S)"
    mv "${LOG_FILE}" "${rotated}"
    init_log_file
    gzip -f "${rotated}" 2>/dev/null || true
    find "$(dirname "${LOG_FILE}")" -maxdepth 1 -name "$(basename "${LOG_FILE}").*.gz" -print 2>/dev/null \
        | sort | head -n -"${LOG_KEEP}" | while IFS= read -r f; do rm -f -- "${f}"; done
    log INFO "Лог ротирован: ${rotated}.gz"
}

# ─── Уведомления ─────────────────────────────────────────────────────────────
# notify <INFO|OK|WARN|ERROR> <событие> <текст>. Сбой отправки не влияет на работу.
notify() {
    local level="$1" event="$2" msg="$3" host title prio tag
    case "${NOTIFY_ON}" in
        none) return 0 ;;
        all)  ;;
        *)    [[ "${level}" == WARN || "${level}" == ERROR ]] || return 0 ;;
    esac
    NOTIFIED=true
    host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo server)
    title="pangolin-update [${host}]: ${event}"
    if [[ -n "${NOTIFY_CMD}" ]]; then
        PU_LEVEL="${level}" PU_EVENT="${event}" PU_MESSAGE="${msg}" PU_HOST="${host}" PU_TITLE="${title}" \
            timeout 30 bash -c "${NOTIFY_CMD}" 9>&- >> "${LOG_FILE}" 2>&1 \
            || log WARN "Уведомление: NOTIFY_CMD завершился с ошибкой"
    fi
    if [[ -n "${NOTIFY_URL}" ]]; then
        prio=default; tag=information_source
        [[ "${level}" == WARN ]]  && { prio=high;   tag=warning; }
        [[ "${level}" == ERROR ]] && { prio=urgent; tag=rotating_light; }
        curl -sS -m 15 -o /dev/null -H "Title: ${title}" -H "Priority: ${prio}" -H "Tags: ${tag}" \
            --data-binary "${msg}" "${NOTIFY_URL}" 9>&- 2>> "${LOG_FILE}" \
            || log WARN "Уведомление: не удалось отправить на NOTIFY_URL"
    fi
    if [[ -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
        curl -sS -m 15 -o /dev/null --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=${title}"$'\n'"${msg}" \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" 9>&- 2>> "${LOG_FILE}" \
            || log WARN "Уведомление: не удалось отправить в Telegram"
    fi
}

# Уведомить один раз по ключу (не повторять одно и то же каждую ночь)
notify_once() {
    local key="$1"; shift
    local f="${STATE_DIR}/notified"
    if [[ -f "${f}" ]] && grep -qxF -- "${key}" "${f}"; then return 0; fi
    { printf '%s\n' "${key}"; tail -n 199 "${f}" 2>/dev/null || true; } > "${f}.tmp" 2>/dev/null \
        && mv "${f}.tmp" "${f}" 2>/dev/null || true
    notify "$@"
}

heartbeat() {
    [[ -n "${HEARTBEAT_URL}" ]] || return 0
    curl -fsS -m 10 --retry 2 -o /dev/null "${HEARTBEAT_URL%/}/$1" 9>&- 2>> "${LOG_FILE}" \
        || log WARN "Не удалось отправить heartbeat на HEARTBEAT_URL"
}

# ─── Общие утилиты ───────────────────────────────────────────────────────────
dc() { docker compose --project-directory "${PANGOLIN_DIR}" -f "${COMPOSE_FILE}" "$@"; }

# ID работающего контейнера сервиса этого стека (по меткам compose — без
# разбора compose-файла, это быстро для частых cron-запусков)
svc_cid() {
    local cid
    cid=$(docker ps -q --filter "label=com.docker.compose.project.working_dir=${PANGOLIN_DIR}" \
        --filter "label=com.docker.compose.service=$1" 2>/dev/null | head -n1 || true)
    [[ -z "${cid}" ]] && cid=$(dc ps -q "$1" 2>/dev/null | head -n1 || true)
    echo "${cid}"
}

to_epoch() { date -d "$1" +%s 2>/dev/null || echo 0; }

# Запомнить момент запуска стека (для чтения свежих логов и счётчика перезапусков)
mark_stack_start() {
    STACK_STARTED_EPOCH=$(date +%s)
    STACK_STARTED_AT=$(date -u -d "@${STACK_STARTED_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)
}

# Перезапустить сервис, если он не перезапускался с mark_stack_start
# (docker compose up -d не трогает контейнер, у которого не изменился compose)
ensure_fresh() {
    local svc="$1" cid started
    cid=$(svc_cid "${svc}")
    [[ -z "${cid}" ]] && return 0
    started=$(to_epoch "$(docker inspect -f '{{.State.StartedAt}}' "${cid}" 2>/dev/null)")
    if (( started < STACK_STARTED_EPOCH - 2 )); then
        log INFO "Перезапуск ${svc} для применения новой конфигурации..."
        dc restart "${svc}" >> "${LOG_FILE}" 2>&1 || log WARN "Не удалось перезапустить ${svc}"
    fi
}

file_age_min() {
    [[ -e "$1" ]] || { echo 999999; return; }
    echo $(( ( $(date +%s) - $(stat -c %Y "$1") ) / 60 ))
}

state_init() {
    mkdir -p "${STATE_DIR}" 2>/dev/null && chmod 700 "${STATE_DIR}" 2>/dev/null || true
}

rel_path() { echo "${1#"${PANGOLIN_DIR}"/}"; }

# Записать содержимое src в dst, сохранив inode и права dst (файлы примонтированы в контейнеры)
write_over() { cat "$1" > "$2"; }

confirm() {
    [[ "${ASSUME_YES}" == true ]] && return 0
    if [[ ! -t 0 ]]; then
        log ERROR "Нужно подтверждение: запустите в терминале или добавьте флаг -y"
        return 1
    fi
    local answer
    read -r -p "$1 [y/N] " answer
    [[ "${answer}" =~ ^[YyДд] ]]
}

# Значение KEY из файла вида KEY="value" — без исполнения файла
env_get() {
    sed -n -E "s/^[[:space:]]*$2=\"?([^\"#]*)\"?.*/\1/p" "$1" 2>/dev/null | tail -n1 | sed -E 's/[[:space:]]+$//'
}

# Файл с секретами: только root (или текущий пользователь), без доступа группе/остальным
check_secret_file() {
    local owner mode
    owner=$(stat -c '%u' "$1") mode=$(stat -c '%a' "$1")
    if [[ "${owner}" != "0" && "${owner}" != "$(id -u)" ]] || (( 8#${mode} & 8#077 )); then
        log ERROR "$1: небезопасные права (uid=${owner}, ${mode}). Исправьте: chown root:root $1 && chmod 600 $1"
        return 1
    fi
}

# ─── Очистка и восстановление при выходе ─────────────────────────────────────
# Если работа прервалась (ошибка, Ctrl-C, kill), пока стек был в переходном
# состоянии (RECOVERY не пуст), стек возвращается в прежнее состояние.
cleanup() {
    local rc=$?
    trap '' INT TERM
    set +e
    if (( rc != 0 )) && [[ -n "${RECOVERY}" ]]; then
        local what="${RECOVERY}" ok=false
        RECOVERY=""
        log ERROR "Работа прервана (код ${rc}), когда стек был в переходном состоянии — восстанавливаю прежнее состояние"
        case "${what}" in
            rollback)     do_rollback && ok=true ;;
            start_stack)  recover_start_stack && ok=true ;;
            cs_install)   crowdsec_install_rollback && ok=true ;;
            cs_uninstall) crowdsec_uninstall_recover && ok=true ;;
        esac
        if [[ "${ok}" == true ]]; then
            rc="${E_FAIL}"
            notify ERROR "interrupted" "Работа прервана; прежнее состояние стека восстановлено. Подробности: ${LOG_FILE}"
        else
            rc="${E_CRIT}"
            notify ERROR "critical" "Работа прервана, восстановить стек НЕ удалось — нужно ручное вмешательство. Подробности: ${LOG_FILE}"
        fi
    fi
    if (( rc != 0 )) && [[ "${ROLLBACK_DONE}" == false ]]; then
        log ERROR "Скрипт завершился с ошибкой (код: ${rc})"
    fi
    if (( rc != 0 )) && [[ "${NOTIFIED}" == false ]]; then
        case "${RUN_MODE}" in
            dns_sync|allowlist_sync)
                notify_once "${RUN_MODE}-fail-$(date +%Y%m%d)" WARN "${RUN_MODE}-failed" \
                    "Ошибка синхронизации: ${LAST_ERROR:-см. ${LOG_FILE}} (уведомление не чаще раза в сутки)" ;;
            ""|info|dry_run) ;;
            *)
                if (( rc == E_PRECOND )); then
                    notify WARN "${RUN_MODE}-skipped" "Ничего не изменено (код ${rc}): ${LAST_ERROR:-см. ${LOG_FILE}}"
                else
                    notify ERROR "${RUN_MODE}-failed" "Код ${rc}: ${LAST_ERROR:-см. ${LOG_FILE}}"
                fi ;;
        esac
    fi
    [[ "${RUN_MODE}" == update ]] && heartbeat "${rc}"
    exit "${rc}"
}

# ─── Проверка зависимостей ───────────────────────────────────────────────────
check_deps() {
    local missing=() cmd
    for cmd in curl jq docker sed awk tar gzip flock md5sum stat timeout; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done
    if (( ${#missing[@]} > 0 )); then
        log ERROR "Отсутствуют зависимости: ${missing[*]}"
        exit "${E_PRECOND}"
    fi
    if ! docker compose version >/dev/null 2>&1; then
        log ERROR "Не найден Docker Compose v2 (команда 'docker compose'). Установите пакет docker-compose-plugin."
        exit "${E_PRECOND}"
    fi
}

# ─── Защита от параллельного запуска ─────────────────────────────────────────
# flock на файле в /run (каталог только для root): атомарно, без гонок, и
# lock снимается сам при любом завершении процесса.
# Режимы: wait — подождать до LOCK_WAIT секунд; quiet — при занятом lock
# тихо выйти с кодом 0 (для частых cron-синхронизаций).
acquire_lock() {
    local mode="${1:-wait}"
    mkdir -p "$(dirname "${LOCK_FILE}")" 2>/dev/null || true
    if ! { exec 9>> "${LOCK_FILE}"; } 2>/dev/null; then
        log ERROR "Не удалось открыть lock-файл ${LOCK_FILE} (нужны права root)"
        exit "${E_PRECOND}"
    fi
    flock -n 9 && return 0
    [[ "${mode}" == quiet ]] && exit 0
    log INFO "Идёт другой запуск скрипта — жду до ${LOCK_WAIT}с..."
    flock -w "${LOCK_WAIT}" 9 && return 0
    log ERROR "Скрипт уже запущен: lock ${LOCK_FILE} занят дольше ${LOCK_WAIT}с"
    exit "${E_PRECOND}"
}

# ─── Сравнение версий ────────────────────────────────────────────────────────
# Приводит тег к X.Y.Z[-pre]: убирает префиксы ee-/postgresql-/v и суффиксы
# архитектуры и вариантов образа.
version_norm() {
    local v="${1#ee-}"
    v="${v#postgresql-}"; v="${v#v}"
    v="${v%-amd64}"; v="${v%-arm64}"; v="${v%-slim}"; v="${v%-debian}"
    echo "${v}"
}

version_major() { local v; v=$(version_norm "$1"); echo "${v%%.*}"; }

# Печатает -1, 0 или 1 (a<b, a=b, a>b). Релиз новее своих pre-release (1.2.0 > 1.2.0-rc.1).
version_cmp() {
    local a b ab bb ap="" bp=""
    a=$(version_norm "$1"); b=$(version_norm "$2")
    [[ "${a}" == "${b}" ]] && { echo 0; return; }
    ab="${a%%-*}"; bb="${b%%-*}"
    [[ "${a}" == *-* ]] && ap="${a#*-}"
    [[ "${b}" == *-* ]] && bp="${b#*-}"
    if [[ "${ab}" != "${bb}" ]]; then
        [[ "$(printf '%s\n%s\n' "${ab}" "${bb}" | sort -V | head -n1)" == "${ab}" ]] && echo -1 || echo 1
        return
    fi
    [[ -z "${ap}" ]] && { echo 1; return; }
    [[ -z "${bp}" ]] && { echo -1; return; }
    [[ "$(printf '%s\n%s\n' "${ap}" "${bp}" | sort -V | head -n1)" == "${ap}" ]] && echo -1 || echo 1
}

# Достаточно ли «отлежался» релиз (MIN_RELEASE_AGE_HOURS). Аргумент — published_at.
release_old_enough() {
    [[ "${NO_DELAY}" == true ]] && return 0
    (( MIN_RELEASE_AGE_HOURS > 0 )) || return 0
    [[ -n "$1" ]] || return 0
    local ts
    ts=$(to_epoch "$1")
    (( ts == 0 )) && return 0
    (( RUN_EPOCH - ts >= MIN_RELEASE_AGE_HOURS * 3600 ))
}

# Решение по одному компоненту: печатает целевую версию — кандидата или текущую.
# Не понижает версию, не переходит на новую мажорную ветку (без
# ALLOW_MAJOR_UPGRADE) и ждёт MIN_RELEASE_AGE_HOURS после публикации.
choose_target() {
    local name="$1" cur="$2" cand="$3" published="${4:-}" cmp
    if [[ -z "${cand}" || "${cand}" == "${cur}" ]]; then echo "${cur}"; return; fi
    cmp=$(version_cmp "${cand}" "${cur}")
    if (( cmp <= 0 )); then
        (( cmp < 0 )) && log INFO "${name}: установлена ${cur} — новее последнего релиза ${cand}, понижать не буду" >&2
        echo "${cur}"; return
    fi
    if [[ "${ALLOW_MAJOR_UPGRADE}" != true && "$(version_major "${cand}")" != "$(version_major "${cur}")" ]]; then
        log WARN "${name}: вышла новая мажорная версия ${cand} (текущая ${cur}) — автоматически не обновляю. Разрешить: ALLOW_MAJOR_UPGRADE=true" >&2
        echo "${cur}"; return
    fi
    if ! release_old_enough "${published}"; then
        log INFO "${name}: релиз ${cand} опубликован меньше ${MIN_RELEASE_AGE_HOURS} ч назад — обновлю при следующем запуске (сразу: -no-delay)" >&2
        echo "${cur}"; return
    fi
    echo "${cand}"
}

# ─── GitHub API ──────────────────────────────────────────────────────────────
# Повторы при сбоях, необязательный GITHUB_TOKEN и условные запросы по ETag
# (ответ 304 не расходует лимит). В пределах одного запуска ответ берётся из
# кэша. Если GitHub недоступен, используется последний сохранённый ответ.
gh_api() {
    local path="$1" dir="${STATE_DIR}/github" key cache etagf body hdr code etag
    key=$(printf '%s' "${path}" | md5sum | cut -c1-16)
    mkdir -p "${dir}" 2>/dev/null || true
    cache="${dir}/${key}.json"; etagf="${dir}/${key}.etag"
    if [[ -s "${cache}" ]] && (( $(stat -c %Y "${cache}") >= RUN_EPOCH )); then
        cat "${cache}"; return 0
    fi
    body=$(mktemp); hdr=$(mktemp)
    local -a args=(-sS --max-time 15 --retry 3 --retry-delay 3 -o "${body}" -D "${hdr}" -w '%{http_code}'
                   -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
    [[ -n "${GITHUB_TOKEN}" ]] && args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    [[ -s "${cache}" && -s "${etagf}" ]] && args+=(-H "If-None-Match: $(<"${etagf}")")
    code=$(curl "${args[@]}" "https://api.github.com/${path}" 2>> "${LOG_FILE}") || true
    code="${code:-000}"
    if [[ "${code}" == 200 ]] && jq -e . "${body}" >/dev/null 2>&1; then
        mv "${body}" "${cache}"
        etag=$(grep -i '^etag:' "${hdr}" | tail -n1 | cut -d' ' -f2- | tr -d '\r')
        if [[ -n "${etag}" ]]; then printf '%s' "${etag}" > "${etagf}"; else rm -f "${etagf}"; fi
    elif [[ "${code}" == 304 ]]; then
        touch "${cache}"
    elif [[ -s "${cache}" ]]; then
        log WARN "GitHub API ${path}: HTTP ${code} — использую сохранённый ответ от $(date -r "${cache}" '+%Y-%m-%d %H:%M')" >&2
    else
        rm -f "${body}" "${hdr}"
        log ERROR "GitHub API ${path}: HTTP ${code}" >&2
        return 1
    fi
    rm -f "${body}" "${hdr}"
    cat "${cache}"
}

# Последний релиз: «тег<TAB>published_at»
gh_latest_release() {
    local json
    json=$(gh_api "repos/$1/releases/latest") || return 1
    jq -r 'select(.tag_name != null) | [.tag_name, (.published_at // "")] | @tsv' <<< "${json}"
}

# Последний релиз Traefik в пределах мажорной ветки $1: «тег<TAB>published_at».
# Если /releases/latest указывает на другую ветку (например, вышел патч v2.11),
# берётся последняя стабильная версия своей ветки из списка релизов.
get_traefik_latest() {
    local major="$1" line="" tag
    line=$(gh_latest_release traefik/traefik) || line=""
    tag="${line%%$'\t'*}"
    if [[ -z "${tag}" || "${tag}" != v${major}.* ]]; then
        log WARN "Traefik: latest вернул '${tag}', ищу последнюю версию ветки v${major}" >&2
        line=$(gh_api "repos/traefik/traefik/releases?per_page=100" \
            | jq -r '.[] | select(.prerelease==false and .draft==false) | [.tag_name, (.published_at // "")] | @tsv' \
            | awk -F'\t' -v re="^v${major}[.][0-9]+[.][0-9]+$" '$1 ~ re' \
            | sort -t$'\t' -k1,1V | tail -n1) || line=""
    fi
    if [[ -z "${line}" ]]; then
        log ERROR "Не удалось получить версию Traefik v${major}" >&2
        return 1
    fi
    echo "${line}"
}

# ─── Теги образов в docker-compose.yml ───────────────────────────────────────
# Регулярка строки image: для репозитория $1 (с docker.io/ и library/ или без,
# в кавычках или без). Совпадает только с началом строки — закомментированные
# строки и traefik/whoami не попадают. Тег — третья группа.
img_re() { printf '%s' "^[[:space:]]*image:[[:space:]]*[\"']?(docker\\.io/)?(library/)?${1//./\\.}:"; }

get_image_tag() {
    local re
    re=$(img_re "$1")
    grep -E "${re}" "${2:-${COMPOSE_FILE}}" 2>/dev/null | head -n1 \
        | sed -E "s#${re}([^[:space:]\"'@]+).*#\\3#" || true
}

# Заменить тег (и закреплённый digest, если был) образа $1 на $2 в файле $3.
# Через временный файл и cat: inode сохраняется (compose-файл примонтирован
# в crowdsec-manager).
set_image_tag() {
    local repo="$1" tag="$2" file="${3:-${COMPOSE_FILE}}" re tmp
    re=$(img_re "${repo}")
    if grep -E "${re}" "${file}" | grep -q '@sha256:'; then
        log WARN "${repo}: digest-закрепление в compose заменяется тегом ${tag}"
    fi
    tmp=$(mktemp)
    sed -E "s#(${re})[^[:space:]\"']+#\\1${tag}#" "${file}" > "${tmp}"
    write_over "${tmp}" "${file}"
    rm -f "${tmp}"
}

image_tag_exists() { timeout 60 docker manifest inspect "$1" >/dev/null 2>&1; }

# Тег Pangolin: [ee-][postgresql-]X.Y.Z[-rc.N][-amd64|-arm64]. Префиксы и
# суффикс архитектуры сохраняются при обновлении (PostgreSQL-сборка остаётся
# PostgreSQL-сборкой). Плавающие теги (latest, 1.26) не поддерживаются.
parse_pangolin_tag() {
    [[ "$1" =~ ^(ee-)?(postgresql-)?(v?[0-9]+\.[0-9]+\.[0-9]+(-(rc|beta|alpha)[.0-9]*)?)(-(amd64|arm64))?$ ]] || return 1
    PANGOLIN_TAG_EE="${BASH_REMATCH[1]}"
    PANGOLIN_TAG_DB="${BASH_REMATCH[2]}"
    PANGOLIN_TAG_VER="${BASH_REMATCH[3]}"
    PANGOLIN_TAG_ARCH="${BASH_REMATCH[6]}"
}

# Тег образа Pangolin для версии $1 с учётом редакции и варианта сборки
pangolin_image_tag() {
    local v="$1" ee=""
    [[ "${ENTERPRISE}" == true ]] && ee="ee-"
    [[ -n "${ee}${PANGOLIN_TAG_DB}" ]] && v="${v#v}"
    echo "${ee}${PANGOLIN_TAG_DB}${v}${PANGOLIN_TAG_ARCH}"
}

stack_uses_postgres() {
    [[ -n "${PANGOLIN_TAG_DB}" ]] && return 0
    grep -qE "$(img_re fosrl/pangolin)(ee-)?postgresql-|^[[:space:]]*image:[[:space:]]*[\"']?[^[:space:]]*postgres" \
        "${COMPOSE_FILE}" 2>/dev/null
}

# ─── Версия Badger: чтение и запись строго внутри блока badger: ──────────────
# Структура traefik_config.yml (Pangolin):
#   experimental:
#     plugins:
#       badger:
#         moduleName: "github.com/fosrl/badger"
#         version: "v1.7.0"
get_badger_version() {
    awk '
        function indent(s) { match(s, /^[ ]*/); return RLENGTH }
        inb && NF && indent($0) <= bind { inb = 0 }
        inb && $1 == "version:" { v = $2; gsub(/["\047]/, "", v); print v; exit }
        /^[ ]*badger:[ ]*(#.*)?$/ { inb = 1; bind = indent($0) }
    ' "${1:-${TRAEFIK_CONFIG}}"
}

set_badger_version() {
    local ver="$1" file="${2:-${TRAEFIK_CONFIG}}" tmp
    tmp=$(mktemp) || return 1
    if ! awk -v ver="${ver}" '
        function indent(s) { match(s, /^[ ]*/); return RLENGTH }
        inb && NF && indent($0) <= bind { inb = 0 }
        inb && $1 == "version:" {
            q = ($0 ~ /version:[ ]*"/) ? "\"" : (($0 ~ /version:[ ]*\047/) ? "\047" : "")
            match($0, /^[ ]*version:[ ]*/)
            print substr($0, 1, RLENGTH) q ver q
            done = 1; inb = 0; next
        }
        /^[ ]*badger:[ ]*(#.*)?$/ { inb = 1; bind = indent($0) }
        { print }
        END { exit done ? 0 : 1 }
    ' "${file}" > "${tmp}"; then
        rm -f "${tmp}"
        log ERROR "Не найден ключ version в блоке badger: файла ${file}"
        return 1
    fi
    write_over "${tmp}" "${file}"
    rm -f "${tmp}"
}

# ─── Список плагинов Traefik из traefik_config.yml ───────────────────────────
# Строки «имя moduleName версия» для каждого плагина в experimental.plugins.
list_traefik_plugins() {
    awk '
        function indent(s) { match(s, /^[ ]*/); return RLENGTH }
        function val(s) { sub(/^[^:]*:[ ]*/, "", s); gsub(/["\047]/, "", s); sub(/[ ]+#.*$/, "", s); return s }
        function flush() { if (name != "" && mod != "" && ver != "") print name, mod, ver; name = mod = ver = "" }
        !NF || $1 ~ /^#/ { next }
        inp && indent($0) <= pind { flush(); inp = 0 }
        inp && cind == 0 { cind = indent($0) }
        inp && indent($0) == cind { flush(); name = $1; sub(/:$/, "", name); next }
        inp && $1 == "moduleName:" { mod = val($0); next }
        inp && $1 == "version:"    { ver = val($0); next }
        /^[ ]*plugins:[ ]*(#.*)?$/ { inp = 1; pind = indent($0); cind = 0 }
        END { if (inp) flush() }
    ' "${TRAEFIK_CONFIG}"
}

# ─── Проба: загрузит ли Traefik плагины с указанной версией Badger ───────────
# Одноразовый контейнер Traefik (без портов и конфигов стека) со ВСЕМИ
# плагинами из traefik_config.yml; Badger — в проверяемой версии. Traefik сам
# скачивает плагины из plugins.traefik.io и проходит ту же проверку
# целостности, что и боевой. Готовность определяется по /ping: плагины
# загружаются до старта entrypoint-ов, поэтому ответ /ping значит, что ошибок
# загрузки уже не будет. Результат кэшируется на PROBE_CACHE_HOURS.
# Возвращает: 0 — загрузились, 1 — НЕ загрузились, 2 — проверить не удалось.
probe_badger() {
    local traefik_tag="$1" badger_ver="$2"
    local name="pangolin-badger-probe-$$" logs="" state bad key cache="${STATE_DIR}/probe-cache"
    local -a plugin_args=(--ping=true) plugin_names=()
    local p_name p_mod p_ver have_badger=false ready=false waited=0 l

    while read -r p_name p_mod p_ver; do
        [[ -z "${p_name}" ]] && continue
        if [[ "${p_name}" == "badger" ]]; then
            p_ver="${badger_ver}"; have_badger=true
        fi
        plugin_args+=("--experimental.plugins.${p_name}.modulename=${p_mod}"
                      "--experimental.plugins.${p_name}.version=${p_ver}")
        plugin_names+=("${p_name}@${p_ver}")
    done < <(list_traefik_plugins; [[ -n "${PROBE_EXTRA_PLUGINS:-}" ]] && printf '%s\n' "${PROBE_EXTRA_PLUGINS}")
    if [[ "${have_badger}" == false ]]; then
        plugin_args+=("--experimental.plugins.badger.modulename=${BADGER_MODULE}"
                      "--experimental.plugins.badger.version=${badger_ver}")
        plugin_names+=("badger@${badger_ver}")
    fi

    key="traefik:${traefik_tag} ${plugin_names[*]}"
    if [[ -f "${cache}" ]]; then
        local hit
        hit=$(awk -F'\t' -v k="${key}" -v min="$(( RUN_EPOCH - PROBE_CACHE_HOURS * 3600 ))" \
            '$2 == k && $1 >= min && r == "" { r = $3 } END { print r }' "${cache}")
        if [[ -n "${hit}" ]]; then
            log INFO "[Проба] Traefik ${traefik_tag} + ${plugin_names[*]}: результат проверки за последние ${PROBE_CACHE_HOURS} ч — $([[ ${hit} == 0 ]] && echo 'загружаются' || echo 'НЕ загружаются')"
            return "${hit}"
        fi
    fi

    log INFO "[Проба] Traefik ${traefik_tag} + плагины: ${plugin_names[*]} (тестовый контейнер, до ${BADGER_PROBE_WAIT}с)..."
    if ! docker pull -q "docker.io/traefik:${traefik_tag}" >> "${LOG_FILE}" 2>&1; then
        log WARN "[Проба] Не удалось скачать образ traefik:${traefik_tag} — проверка невозможна"
        return 2
    fi
    PROBE_PULLED+=("traefik:${traefik_tag}")

    docker rm -f "${name}" >/dev/null 2>&1 || true
    if ! docker run -d --name "${name}" "docker.io/traefik:${traefik_tag}" \
            --log.level=INFO "${plugin_args[@]}" >/dev/null 2>> "${LOG_FILE}"; then
        log WARN "[Проба] Не удалось запустить тестовый контейнер Traefik — проверка невозможна"
        return 2
    fi

    while (( waited < BADGER_PROBE_WAIT )); do
        sleep 2
        (( waited += 2 ))
        logs=$(docker logs "${name}" 2>&1 || true)
        grep -qiE "${TRAEFIK_PLUGIN_ERR_RE}" <<< "${logs}" && break
        state=$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || echo "gone")
        [[ "${state}" != "running" ]] && break
        if docker exec "${name}" wget -q -O /dev/null http://127.0.0.1:8080/ping >/dev/null 2>&1; then
            ready=true
            sleep 2
            logs=$(docker logs "${name}" 2>&1 || true)
            break
        fi
    done
    state=$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || echo "gone")
    docker rm -f "${name}" >/dev/null 2>&1 || true

    local result=0
    bad=$(grep -iE "${TRAEFIK_PLUGIN_ERR_RE}" <<< "${logs}" | tail -n 3 || true)
    if [[ -n "${bad}" ]]; then
        log WARN "[Проба] Traefik ${traefik_tag} НЕ загрузил плагины (${plugin_names[*]}):"
        while IFS= read -r l; do log WARN "  traefik> ${l:0:300}"; done <<< "${bad}"
        result=1
    elif [[ "${state}" != "running" ]]; then
        log WARN "[Проба] Тестовый Traefik завершился раньше времени (${state}):"
        while IFS= read -r l; do log WARN "  traefik> ${l:0:300}"; done <<< "$(tail -n 3 <<< "${logs}")"
        result=1
    elif [[ "${ready}" == true ]]; then
        log OK "[Проба] Плагины ${plugin_names[*]} загружаются в Traefik ${traefik_tag} (за ${waited}с)"
    else
        log OK "[Проба] За ${BADGER_PROBE_WAIT}с ошибок загрузки плагинов нет (${plugin_names[*]}, Traefik ${traefik_tag})"
    fi
    { printf '%s\t%s\t%s\n' "${RUN_EPOCH}" "${key}" "${result}"; tail -n 99 "${cache}" 2>/dev/null || true; } \
        > "${cache}.tmp" 2>/dev/null && mv "${cache}.tmp" "${cache}" 2>/dev/null || true
    return "${result}"
}

# ─── CrowdSec: версия образа ─────────────────────────────────────────────────
# Целевой тег: последний релиз в той же мажорной ветке (с учётом
# MIN_RELEASE_AGE_HOURS), если тег уже опубликован в Docker Hub. Иначе — текущий.
# Плавающие теги (latest, slim, debian...) не трогаем — их предлагается закрепить.
resolve_crowdsec_target() {
    local cur="$1" line latest pub suffix="" target
    if [[ ! "${cur}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-(slim|debian))?$ ]]; then
        log WARN "CrowdSec: тег '${cur}' плавающий — автообновление пропущено." >&2
        log WARN "CrowdSec: закрепите версию в compose (напр. crowdsecurity/crowdsec:v1.8.1), тогда скрипт будет её обновлять и сможет откатить." >&2
        echo "${cur}"; return
    fi
    [[ "${cur}" =~ -(slim|debian)$ ]] && suffix="-${BASH_REMATCH[1]}"
    if ! line=$(gh_latest_release crowdsecurity/crowdsec) || [[ -z "${line}" ]]; then
        log WARN "CrowdSec: не удалось получить последний релиз — оставляю ${cur}" >&2
        echo "${cur}"; return
    fi
    latest="${line%%$'\t'*}"; pub="${line#*$'\t'}"
    target=$(choose_target CrowdSec "${cur}" "${latest}${suffix}" "${pub}")
    if [[ "${target}" != "${cur}" ]] && ! image_tag_exists "docker.io/crowdsecurity/crowdsec:${target}"; then
        log INFO "CrowdSec: релиз ${latest} ещё не опубликован в Docker Hub — оставляю ${cur}" >&2
        target="${cur}"
    fi
    echo "${target}"
}

# ─── CrowdSec: обновление правил Hub ─────────────────────────────────────────
# Сценарии, парсеры и правила AppSec обновляются из Hub независимо от версии
# образа. При изменениях CrowdSec перечитывает конфигурацию (SIGHUP).
# Возвращает 1, если после обновления CrowdSec перестал отвечать.
crowdsec_hub_update() {
    [[ "${CROWDSEC_HUB_UPDATE}" == true ]] || return 0
    local cid state before after
    cid=$(svc_cid "${CROWDSEC_SERVICE}")
    [[ -z "${cid}" ]] && return 0
    state=$(docker inspect -f '{{.State.Status}}' "${cid}" 2>/dev/null || echo "gone")
    if [[ "${state}" != "running" ]]; then
        log WARN "CrowdSec: контейнер не запущен (${state}) — обновление правил пропущено"
        return 0
    fi

    log INFO "CrowdSec: обновление правил из Hub (сценарии, AppSec)..."
    before=$(docker exec "${cid}" cscli hub list -o raw 2>/dev/null | md5sum)
    if ! docker exec "${cid}" cscli hub update >> "${LOG_FILE}" 2>&1; then
        log WARN "CrowdSec: cscli hub update завершился с ошибкой — правила не обновлены"
        return 0
    fi
    if ! docker exec "${cid}" cscli hub upgrade >> "${LOG_FILE}" 2>&1; then
        log WARN "CrowdSec: cscli hub upgrade завершился с ошибкой — подробности в ${LOG_FILE}"
    fi
    after=$(docker exec "${cid}" cscli hub list -o raw 2>/dev/null | md5sum)

    if [[ "${before}" == "${after}" ]]; then
        log OK "CrowdSec: правила актуальны"
        return 0
    fi

    log INFO "CrowdSec: правила обновлены — перечитываю конфигурацию (SIGHUP)"
    docker kill -s HUP "${cid}" >/dev/null 2>&1 || true
    sleep 10
    if docker exec "${cid}" cscli lapi status >/dev/null 2>&1; then
        log OK "CrowdSec: новые правила применены"
        return 0
    fi

    log WARN "CrowdSec: после перечитывания LAPI не отвечает — перезапускаю контейнер"
    dc restart "${CROWDSEC_SERVICE}" >> "${LOG_FILE}" 2>&1 || true
    sleep 20
    if docker exec "${cid}" cscli lapi status >/dev/null 2>&1; then
        log OK "CrowdSec: работает после перезапуска"
        return 0
    fi
    log ERROR "CrowdSec не отвечает после обновления правил! Если в bouncer включён"
    log ERROR "crowdsecAppsecUnreachableBlock, весь трафик сейчас блокируется."
    log ERROR "Диагностика: docker logs ${CROWDSEC_SERVICE}; cscli hub list"
    notify ERROR "crowdsec-down" "CrowdSec не отвечает после обновления правил Hub. Диагностика: docker logs ${CROWDSEC_SERVICE}"
    return 1
}

# ─── Allowlist CrowdSec: своя инфраструктура ─────────────────────────────────
# Адреса, которые нельзя банить: сам сервер и сайты Newt (бан IP сайта Newt
# обрывает туннель вместе со всеми ресурсами сайта). Автоматические записи
# помечаются описанием «auto: ...» и удаляются, когда пропадают из
# источников; записи с другими описаниями (ручные) скрипт не трогает.

# При тихом запуске из cron INFO/WARN не пишутся; изменения и ошибки — всегда.
ALLOWLIST_QUIET=false
alog() {
    [[ "${ALLOWLIST_QUIET}" == true && "$1" != "ERROR" && "$1" != "OK" ]] && return 0
    log "$@"
}

crowdsec_cid() { svc_cid "${CROWDSEC_SERVICE}"; }

# Печатает адрес, если он публичный (частные, loopback, link-local, CGNAT — нет).
# Принимает IPv4, IPv6, [IPv6] и IPv4-mapped (::ffff:1.2.3.4).
public_ip() {
    local ip="$1"
    ip="${ip#[}"; ip="${ip%]}"; ip="${ip#::ffff:}"; ip="${ip#::FFFF:}"
    if [[ "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        local o a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]}))
        for o in "${BASH_REMATCH[@]:1}"; do (( 10#${o} <= 255 )) || return 1; done
        if (( a == 0 || a == 10 || a == 127 || a >= 224 )) ||
           (( a == 172 && b >= 16 && b <= 31 )) ||
           (( a == 192 && b == 168 )) ||
           (( a == 169 && b == 254 )) ||
           (( a == 100 && b >= 64 && b <= 127 )); then
            return 1
        fi
        echo "$((10#${BASH_REMATCH[1]})).$((10#${BASH_REMATCH[2]})).$((10#${BASH_REMATCH[3]})).$((10#${BASH_REMATCH[4]}))"
        return 0
    fi
    if [[ "${ip}" == *:* && "${ip}" =~ ^[0-9a-fA-F:]+$ ]]; then
        ip="${ip,,}"
        [[ "${ip}" == "::1" || "${ip}" == "::" || "${ip}" == fe[89ab]* || "${ip}" == f[cd]* ]] && return 1
        echo "${ip}"
        return 0
    fi
    return 1
}

# Хост из endpoint вида 1.2.3.4:51820 или [2001:db8::1]:51820
endpoint_host() {
    local ep="$1"
    if [[ "${ep}" =~ ^\[([^]]+)\]:[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "${ep}" =~ ^([^:]+):[0-9]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "${ep}"
    fi
}

ip_from() {
    local r=""
    r=$(curl "-$1" -sf --max-time 8 "$2" 2>/dev/null | tr -d '[:space:]') || true
    public_ip "${r}" || true
}

# Внешний адрес сервера (семейство 4 или 6) по внешним сервисам. Принимается,
# только если его вернули хотя бы два сервиса из трёх: один подменённый или
# сбойный ответ не попадёт ни в allowlist, ни в DNS. Кэш — SERVER_IP_CACHE_MIN минут.
public_ip_consensus() {
    local fam="$1" cache="${STATE_DIR}/public-ipv$1" a="" b="" c="" v=""
    if [[ -s "${cache}" ]] && (( $(file_age_min "${cache}") < SERVER_IP_CACHE_MIN )); then
        cat "${cache}"; return 0
    fi
    local -a urls=(https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com)
    [[ "${fam}" == 6 ]] && urls[0]="https://api6.ipify.org"
    a=$(ip_from "${fam}" "${urls[0]}")
    b=$(ip_from "${fam}" "${urls[1]}")
    if [[ -n "${a}" && "${a}" == "${b}" ]]; then
        v="${a}"
    else
        c=$(ip_from "${fam}" "${urls[2]}")
        [[ -n "${c}" && ( "${c}" == "${a}" || "${c}" == "${b}" ) ]] && v="${c}"
    fi
    if [[ -n "${v}" ]]; then
        printf '%s\n' "${v}" > "${cache}" 2>/dev/null || true
        echo "${v}"; return 0
    fi
    if [[ -s "${cache}" ]]; then
        [[ -n "${a}${b}${c}" ]] && log WARN "Внешний IPv${fam}: сервисы ответили по-разному (${a:-—}/${b:-—}/${c:-—}) — использую сохранённый $(<"${cache}")" >&2
        cat "${cache}"; return 0
    fi
    [[ -n "${a}${b}${c}" ]] && log WARN "Внешний IPv${fam}: сервисы ответили по-разному (${a:-—}/${b:-—}/${c:-—}) — адрес не принят" >&2
    return 1
}

# Запрос к БД Pangolin (SQLite) только на чтение; строки через TAB.
# sqlite3 или python3 на хосте, иначе Node.js внутри контейнера pangolin.
pangolin_db_query() {
    local sql="$1" cid
    if stack_uses_postgres; then
        alog WARN "[Allowlist] Pangolin использует PostgreSQL — чтение сайтов Newt не поддерживается, добавьте их IP в ALLOWLIST_EXTRA" >&2
        return 1
    fi
    if [[ -f "${PANGOLIN_DB}" ]]; then
        if command -v sqlite3 >/dev/null 2>&1; then
            sqlite3 -readonly -separator $'\t' "${PANGOLIN_DB}" "${sql}" 2>> "${LOG_FILE}" && return 0
        fi
        if command -v python3 >/dev/null 2>&1; then
            python3 -I - "${PANGOLIN_DB}" "${sql}" 2>> "${LOG_FILE}" <<'PY' && return 0
import sqlite3, sys
con = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=10)
for row in con.execute(sys.argv[2]):
    print("\t".join("" if v is None else str(v) for v in row))
PY
        fi
    fi
    cid=$(svc_cid pangolin)
    [[ -z "${cid}" ]] && return 1
    # Маркер отличает «запрос выполнен, строк нет» от сбоя (иначе пустой ответ
    # привёл бы к удалению всех записей Newt из allowlist)
    local out marker="__PANGOLIN_DB_OK__"
    out=$(docker exec -w /app -e Q="${sql}" -e M="${marker}" "${cid}" node -e '
        const D = require("better-sqlite3");
        const db = new D("config/db/db.sqlite", { readonly: true, fileMustExist: true });
        for (const r of db.prepare(process.env.Q).raw().all())
            console.log(r.map(v => (v === null || v === undefined) ? "" : v).join("\t"));
        console.log(process.env.M);
    ' 2>> "${LOG_FILE}") || return 1
    [[ "$(tail -n1 <<< "${out}")" == "${marker}" ]] || return 1
    sed '$d' <<< "${out}"
}

# Сайт в ALLOWLIST_NEWT_EXCLUDE (имена через запятую)?
newt_site_excluded() {
    local item
    local -a items
    IFS=',' read -r -a items <<< "${ALLOWLIST_NEWT_EXCLUDE}"
    for item in "${items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"; item="${item%"${item##*[![:space:]]}"}"
        [[ -n "${item}" && "${item}" == "$1" ]] && return 0
    done
    return 1
}

# Публичные IP сайтов Newt: строки «ip<TAB>auto: newt <имя сайта>».
# sites.endpoint — адрес, с которого Newt пробивает туннель к Gerbil.
# Сайты без связи дольше ALLOWLIST_NEWT_MAX_AGE_DAYS и сайты из
# ALLOWLIST_NEWT_EXCLUDE пропускаются. Возвращает 1, если БД не прочитана.
get_newt_ips() {
    local rows now cutoff name _type ep hp lp seen host ip
    rows=$(pangolin_db_query "SELECT name, type, endpoint, COALESCE(lastHolePunch,0), COALESCE(lastPing,0) FROM sites WHERE endpoint IS NOT NULL AND endpoint <> ''") || return 1
    now=$(date +%s)
    cutoff=$(( now - ALLOWLIST_NEWT_MAX_AGE_DAYS * 86400 ))
    while IFS=$'\t' read -r name _type ep hp lp; do
        [[ -z "${ep}" ]] && continue
        if newt_site_excluded "${name}"; then
            alog INFO "[Allowlist] Сайт '${name}' в ALLOWLIST_NEWT_EXCLUDE — его адрес не добавляется" >&2
            continue
        fi
        [[ "${hp}" =~ ^[0-9]+$ ]] || hp=0
        [[ "${lp}" =~ ^[0-9]+$ ]] || lp=0
        (( hp > 100000000000 )) && hp=$(( hp / 1000 ))   # миллисекунды → секунды
        (( lp > 100000000000 )) && lp=$(( lp / 1000 ))
        seen=$(( hp > lp ? hp : lp ))
        if (( seen < cutoff )); then
            alog INFO "[Allowlist] Сайт '${name}' не на связи больше ${ALLOWLIST_NEWT_MAX_AGE_DAYS} дн. — его адрес не добавляется" >&2
            continue
        fi
        host=$(endpoint_host "${ep}")
        if ! ip=$(public_ip "${host}"); then
            continue   # частный адрес (сайт в той же сети) — его и так не банят
        fi
        printf '%s\t%s\n' "${ip}" "auto: newt ${name}"
    done <<< "${rows}"
    return 0
}

# Публичные IP самого сервера: строки «ip<TAB>auto: server».
# Глобальные адреса интерфейсов + внешние адреса (согласованные двумя сервисами)
# + CF_TARGET_IP из настроек Cloudflare.
get_server_ips() {
    {
        ip -o addr show scope global 2>/dev/null \
            | awk '$2 !~ /^(docker|br-|veth|wg|lo)/ { split($4, a, "/"); print a[1] }' || true
        public_ip_consensus 4 || true
        public_ip_consensus 6 || true
        if [[ -f "${CF_ENV_FILE}" ]]; then
            env_get "${CF_ENV_FILE}" CF_TARGET_IP
        fi
    } | while read -r ip; do
        [[ -n "${ip}" ]] && public_ip "${ip}" || true
    done | sort -u | awk '{ print $0 "\tauto: server" }'
}

# Проверка ручной записи: IPv4/IPv6 с необязательной маской
valid_ip_or_cidr() {
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ || "$1" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]]
}

allowlist_sync() {
    local cid verbose=false
    [[ -t 1 ]] && verbose=true
    cid=$(crowdsec_cid)
    if [[ -z "${cid}" ]]; then
        [[ "${verbose}" == true ]] && alog WARN "[Allowlist] CrowdSec не запущен — синхронизация пропущена"
        return 0
    fi

    # 1. Желаемое состояние из источников
    local desired="" server newt e server_ok=false newt_ok=false
    server=$(get_server_ips)
    if [[ -n "${server}" ]]; then
        server_ok=true
        desired+="${server}"$'\n'
    else
        alog WARN "[Allowlist] Не удалось определить публичный IP сервера — записи сервера не меняются"
    fi
    if [[ "${ALLOWLIST_NEWT}" != true ]]; then
        newt_ok=true    # учёт сайтов выключен: автоматические записи Newt будут убраны
    elif newt=$(get_newt_ips); then
        newt_ok=true
        [[ -n "${newt}" ]] && desired+="${newt}"$'\n'
    else
        alog WARN "[Allowlist] Не удалось прочитать сайты из БД Pangolin (${PANGOLIN_DB}) — записи Newt не меняются"
    fi
    for e in ${ALLOWLIST_EXTRA}; do
        if valid_ip_or_cidr "${e}"; then
            desired+="${e}"$'\t'"auto: config ALLOWLIST_EXTRA"$'\n'
        else
            alog WARN "[Allowlist] ALLOWLIST_EXTRA: '${e}' не похоже на IP/подсеть — пропущено"
        fi
    done
    # Один адрес — одна запись (первое описание выигрывает: server > newt > config)
    desired=$(printf '%s' "${desired}" | awk -F'\t' 'NF >= 2 && $1 != "" && !seen[$1]++')

    # Источники не изменились с прошлой успешной синхронизации — cscli не трогаем
    # (полная сверка всё равно раз в час: вдруг запись удалили вручную)
    local sig sigf="${STATE_DIR}/allowlist.sig"
    sig=$(printf '%s\n%s %s %s\n' "${desired}" "${ALLOWLIST_NAME}" "${server_ok}" "${newt_ok}" | md5sum | cut -d' ' -f1)
    if [[ "${verbose}" == false && -s "${sigf}" && "$(<"${sigf}")" == "${sig}" ]] && (( $(file_age_min "${sigf}") < 60 )); then
        return 0
    fi

    # 2. Allowlist существует?
    if ! docker exec "${cid}" cscli allowlists inspect "${ALLOWLIST_NAME}" -o json >/dev/null 2>&1; then
        if ! docker exec "${cid}" cscli allowlists create "${ALLOWLIST_NAME}" \
                -d "Pangolin: сервер и сайты Newt (управляется pangolin-update.sh)" >> "${LOG_FILE}" 2>&1; then
            log ERROR "[Allowlist] Не удалось создать allowlist '${ALLOWLIST_NAME}' (нужен CrowdSec 1.6.8+)"
            return 1
        fi
        log OK "[Allowlist] Создан allowlist '${ALLOWLIST_NAME}'"
    fi
    local current
    if ! current=$(docker exec "${cid}" cscli allowlists inspect "${ALLOWLIST_NAME}" -o json 2>> "${LOG_FILE}" \
            | jq -r '.items[]? | [.value, (.description // "")] | @tsv'); then
        log ERROR "[Allowlist] Не удалось прочитать allowlist '${ALLOWLIST_NAME}'"
        return 1
    fi

    local ip desc added=0 removed=0 failed=0 kept=0 flag
    # 3. Добавить недостающие
    while IFS=$'\t' read -r ip desc; do
        [[ -z "${ip}" ]] && continue
        if awk -F'\t' -v v="${ip}" '$1 == v { f = 1 } END { exit !f }' <<< "${current}"; then
            (( kept++ )) || true
            continue
        fi
        if docker exec "${cid}" cscli allowlists add "${ALLOWLIST_NAME}" "${ip}" -d "${desc}" >> "${LOG_FILE}" 2>&1; then
            log OK "[Allowlist] + ${ip} (${desc#auto: })"
            (( added++ )) || true
            # Если адрес уже успели забанить — снимаем бан
            flag="--ip"; [[ "${ip}" == */* ]] && flag="--range"
            docker exec "${cid}" cscli decisions delete "${flag}" "${ip}" >> "${LOG_FILE}" 2>&1 || true
        else
            log ERROR "[Allowlist] Не удалось добавить ${ip}"
            (( failed++ )) || true
        fi
    done <<< "${desired}"

    # 4. Удалить устаревшие автоматические записи
    while IFS=$'\t' read -r ip desc; do
        [[ -z "${ip}" ]] && continue
        [[ "${desc}" == "auto: "* ]] || continue                         # ручные — не трогаем
        [[ "${desc}" == "auto: newt"* && "${newt_ok}" == false ]] && continue
        [[ "${desc}" == "auto: server" && "${server_ok}" == false ]] && continue
        if awk -F'\t' -v v="${ip}" '$1 == v { f = 1 } END { exit !f }' <<< "${desired}"; then
            continue
        fi
        if docker exec "${cid}" cscli allowlists remove "${ALLOWLIST_NAME}" "${ip}" >> "${LOG_FILE}" 2>&1; then
            log OK "[Allowlist] − ${ip} (${desc#auto: }) — адреса больше нет в источниках"
            (( removed++ )) || true
        else
            log ERROR "[Allowlist] Не удалось удалить ${ip}"
            (( failed++ )) || true
        fi
    done <<< "${current}"

    if (( added > 0 || removed > 0 || failed > 0 )) || [[ "${verbose}" == true ]]; then
        log INFO "[Allowlist] '${ALLOWLIST_NAME}': добавлено ${added}, удалено ${removed}, без изменений ${kept}, ошибок ${failed}"
    fi
    (( failed > 0 )) && return 1
    printf '%s' "${sig}" > "${sigf}" 2>/dev/null || true
    return 0
}

# Действия CrowdSec после обычного запуска: правила Hub + allowlist.
# Возвращает результат обновления правил (1 = CrowdSec не отвечает).
post_run_crowdsec() {
    local rc=0
    crowdsec_hub_update || rc=$?
    if [[ "${ALLOWLIST_SYNC}" == true ]]; then
        allowlist_sync || log WARN "[Allowlist] Синхронизация завершилась с ошибками — см. ${LOG_FILE}"
    fi
    return "${rc}"
}

# ─── Режимы -allowlist-sync / -allowlist-on / -allowlist-off ─────────────────
do_allowlist_sync() {
    [[ -t 1 ]] || ALLOWLIST_QUIET=true
    if [[ -z "$(crowdsec_cid)" ]]; then
        alog WARN "Сервис '${CROWDSEC_SERVICE}' не найден в стеке или не запущен"
        exit "${E_PRECOND}"
    fi
    allowlist_sync && exit "${E_OK}" || exit "${E_FAIL}"
}

install_allowlist_cron() {
    local script_path
    script_path=$(readlink -f "$0")
    cat > "${ALLOWLIST_CRON_FILE}" <<EOF
# Синхронизация allowlist CrowdSec: IP сервера и сайтов Newt (pangolin-update)
*/${ALLOWLIST_SYNC_INTERVAL} * * * * root ${script_path} --allowlist-sync >/dev/null 2>&1
EOF
    chmod 644 "${ALLOWLIST_CRON_FILE}"
    log OK "cron-задача создана: ${ALLOWLIST_CRON_FILE} (каждые ${ALLOWLIST_SYNC_INTERVAL} мин)"
}

allowlist_enable() {
    if [[ -z "$(crowdsec_cid)" ]]; then
        log ERROR "Сервис '${CROWDSEC_SERVICE}' не найден в стеке или не запущен — сначала установите CrowdSec (--crowdsec-install)"
        exit "${E_PRECOND}"
    fi
    install_allowlist_cron
    log INFO "Первичная синхронизация allowlist..."
    if allowlist_sync; then
        log OK "Автоматический allowlist включён: новые сайты Newt и смена их IP подхватываются за ${ALLOWLIST_SYNC_INTERVAL} мин"
    else
        log WARN "cron-задача создана, но при первичной синхронизации были ошибки — см. лог выше"
    fi
    log_separator
    exit "${E_OK}"
}

allowlist_disable() {
    if [[ -f "${ALLOWLIST_CRON_FILE}" ]]; then
        rm -f "${ALLOWLIST_CRON_FILE}"
        log OK "cron-задача удалена: ${ALLOWLIST_CRON_FILE}"
    else
        log INFO "cron-задачи синхронизации allowlist не было"
    fi
    log INFO "Сам allowlist '${ALLOWLIST_NAME}' сохранён. Удалить его целиком:"
    log INFO "  docker exec ${CROWDSEC_SERVICE} cscli allowlists delete ${ALLOWLIST_NAME}"
    log INFO "Синхронизация при обычном запуске отключается параметром ALLOWLIST_SYNC=false"
    log_separator
    exit "${E_OK}"
}

# ─── Чтение текущих версий из файлов конфигурации ────────────────────────────
read_current_versions() {
    OLD_PANGOLIN_V=$(get_image_tag fosrl/pangolin)
    OLD_GERBIL_V=$(get_image_tag fosrl/gerbil)
    OLD_TRAEFIK_V=$(get_image_tag traefik)
    OLD_BADGER_V=$(get_badger_version || true)
    OLD_CROWDSEC_V=$(get_image_tag crowdsecurity/crowdsec)   # пусто, если CrowdSec в стеке нет

    local var
    for var in OLD_PANGOLIN_V OLD_GERBIL_V OLD_TRAEFIK_V OLD_BADGER_V; do
        if [[ -z "${!var}" ]]; then
            log ERROR "Не удалось прочитать текущую версию: ${var} (проверьте строки image: в ${COMPOSE_FILE} и блок badger: в ${TRAEFIK_CONFIG})"
            exit "${E_PRECOND}"
        fi
    done
    if ! parse_pangolin_tag "${OLD_PANGOLIN_V}"; then
        log ERROR "Тег Pangolin '${OLD_PANGOLIN_V}' не поддерживается: закрепите версию вида X.Y.Z, ee-X.Y.Z, postgresql-X.Y.Z или ee-postgresql-X.Y.Z"
        exit "${E_PRECOND}"
    fi
    for var in OLD_GERBIL_V OLD_TRAEFIK_V OLD_BADGER_V; do
        if [[ ! "${!var}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            log ERROR "Версия ${var#OLD_} '${!var}' плавающая или нестандартная — закрепите версию вида X.Y.Z"
            exit "${E_PRECOND}"
        fi
    done
}

# ─── Форматированный вывод версий ────────────────────────────────────────────
print_version_line() {
    local name="$1" old="$2" new="$3"
    if [[ "${old}" == "${new}" ]]; then
        printf "  %-12s ${C_YELLOW}%-22s${C_RESET} (без изменений)\n" "${name}" "${old}"
        printf "  %-12s %-22s (без изменений)\n" "${name}" "${old}" >> "${LOG_FILE}"
    else
        printf "  %-12s ${C_RED}%-22s${C_RESET} -> ${C_GREEN}%s${C_RESET}\n" "${name}" "${old}" "${new}"
        printf "  %-12s %-22s -> %s\n" "${name}" "${old}" "${new}" >> "${LOG_FILE}"
    fi
}

print_versions() {
    print_version_line "Pangolin" "${OLD_PANGOLIN_V}" "${PANGOLIN_V}"
    print_version_line "Gerbil"   "${OLD_GERBIL_V}"   "${GERBIL_V}"
    print_version_line "Traefik"  "${OLD_TRAEFIK_V}"  "${TRAEFIK_V}"
    print_version_line "Badger"   "${OLD_BADGER_V}"   "${BADGER_V}"
    if [[ -n "${OLD_CROWDSEC_V}" ]]; then
        print_version_line "CrowdSec" "${OLD_CROWDSEC_V}" "${CROWDSEC_V}"
    fi
}

nothing_to_update() {
    [[ "${OLD_PANGOLIN_V}" == "${PANGOLIN_V}" &&
       "${OLD_GERBIL_V}"   == "${GERBIL_V}"   &&
       "${OLD_TRAEFIK_V}"  == "${TRAEFIK_V}"  &&
       "${OLD_BADGER_V}"   == "${BADGER_V}"   &&
       "${OLD_CROWDSEC_V}" == "${CROWDSEC_V}" ]]
}

# Строка-итог для уведомлений: «Pangolin 1.25.0→1.26.0, Traefik v3.6.1→v3.6.2»
changes_summary() {
    local out=""
    [[ "${OLD_PANGOLIN_V}" != "${PANGOLIN_V}" ]] && out+="Pangolin ${OLD_PANGOLIN_V}→${PANGOLIN_V}, "
    [[ "${OLD_GERBIL_V}"   != "${GERBIL_V}"   ]] && out+="Gerbil ${OLD_GERBIL_V}→${GERBIL_V}, "
    [[ "${OLD_TRAEFIK_V}"  != "${TRAEFIK_V}"  ]] && out+="Traefik ${OLD_TRAEFIK_V}→${TRAEFIK_V}, "
    [[ "${OLD_BADGER_V}"   != "${BADGER_V}"   ]] && out+="Badger ${OLD_BADGER_V}→${BADGER_V}, "
    [[ "${OLD_CROWDSEC_V}" != "${CROWDSEC_V}" ]] && out+="CrowdSec ${OLD_CROWDSEC_V}→${CROWDSEC_V}, "
    echo "${out%, }"
}

# Применить план к файлам $1 (compose) и $2 (traefik_config). Используется и
# для настоящего обновления, и для показа diff в режиме -dry-run.
apply_plan_to_files() {
    local compose="$1" traefik="$2"
    [[ "${OLD_PANGOLIN_V}" != "${PANGOLIN_V}" ]] && set_image_tag fosrl/pangolin "${PANGOLIN_V}" "${compose}"
    [[ "${OLD_GERBIL_V}"   != "${GERBIL_V}"   ]] && set_image_tag fosrl/gerbil   "${GERBIL_V}"   "${compose}"
    [[ "${OLD_TRAEFIK_V}"  != "${TRAEFIK_V}"  ]] && set_image_tag traefik        "${TRAEFIK_V}"  "${compose}"
    if [[ -n "${OLD_CROWDSEC_V}" && "${OLD_CROWDSEC_V}" != "${CROWDSEC_V}" ]]; then
        set_image_tag crowdsecurity/crowdsec "${CROWDSEC_V}" "${compose}"
    fi
    if [[ "${OLD_BADGER_V}" != "${BADGER_V}" ]]; then
        set_badger_version "${BADGER_V}" "${traefik}" || return 1
    fi
    return 0
}

# Образы, которые нужно скачать для плана (только изменившиеся компоненты)
planned_images() {
    [[ "${OLD_PANGOLIN_V}" != "${PANGOLIN_V}" ]] && echo "docker.io/fosrl/pangolin:${PANGOLIN_V}"
    [[ "${OLD_GERBIL_V}"   != "${GERBIL_V}"   ]] && echo "docker.io/fosrl/gerbil:${GERBIL_V}"
    [[ "${OLD_TRAEFIK_V}"  != "${TRAEFIK_V}"  ]] && echo "docker.io/traefik:${TRAEFIK_V}"
    [[ -n "${OLD_CROWDSEC_V}" && "${OLD_CROWDSEC_V}" != "${CROWDSEC_V}" ]] && echo "docker.io/crowdsecurity/crowdsec:${CROWDSEC_V}"
    return 0
}

# Образы, которые план заменяет (кандидаты на удаление после успеха)
replaced_images() {
    [[ "${OLD_PANGOLIN_V}" != "${PANGOLIN_V}" ]] && echo "fosrl/pangolin:${OLD_PANGOLIN_V}"
    [[ "${OLD_GERBIL_V}"   != "${GERBIL_V}"   ]] && echo "fosrl/gerbil:${OLD_GERBIL_V}"
    [[ "${OLD_TRAEFIK_V}"  != "${TRAEFIK_V}"  ]] && echo "traefik:${OLD_TRAEFIK_V}"
    [[ -n "${OLD_CROWDSEC_V}" && "${OLD_CROWDSEC_V}" != "${CROWDSEC_V}" ]] && echo "crowdsecurity/crowdsec:${OLD_CROWDSEC_V}"
    return 0
}

# ─── HTTP-проверка через Traefik ─────────────────────────────────────────────
dashboard_url() {
    sed -nE 's/^[[:space:]]*dashboard_url:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' \
        "${PANGOLIN_DIR}/config/config.yml" 2>/dev/null | head -n1 || true
}

http_ok() { [[ "$1" =~ ^[23][0-9][0-9]$ || "$1" == 401 || "$1" == 403 ]]; }

# Код ответа на запрос к URL через Traefik на этом хосте (--resolve на
# HEALTH_HTTP_RESOLVE_IP: проверяется именно этот сервер, а не DNS/CDN)
http_status() {
    local url="$1" rest hostport host port code=""
    rest="${url#*://}"; hostport="${rest%%/*}"; host="${hostport%%:*}"
    if [[ "${hostport}" == *:* ]]; then port="${hostport##*:}"
    elif [[ "${url}" == http://* ]]; then port=80
    else port=443; fi
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
        --resolve "${host}:${port}:${HEALTH_HTTP_RESOLVE_IP}" "${url}" 2>/dev/null) || true
    echo "${code:-000}"
}

# Замер до изменений: если адрес не отвечает уже сейчас (порт не на этом IP,
# другой маршрут), HTTP-проверка после обновления не включается — иначе
# получился бы ложный откат.
http_baseline() {
    HTTP_BASELINE_OK=false
    [[ "${HEALTH_HTTP_CHECK}" == true ]] || return 0
    HEALTH_URL_EFFECTIVE="${HEALTH_URL:-$(dashboard_url)}"
    if [[ -z "${HEALTH_URL_EFFECTIVE}" ]]; then
        log INFO "HTTP-проверка: адрес не задан (HEALTH_URL) и не найден dashboard_url в config.yml — пропускается"
        return 0
    fi
    local code
    code=$(http_status "${HEALTH_URL_EFFECTIVE}")
    if http_ok "${code}"; then
        HTTP_BASELINE_OK=true
        log INFO "HTTP-проверка: ${HEALTH_URL_EFFECTIVE} → ${code} (будет проверена и после изменений)"
    else
        log WARN "HTTP-проверка: ${HEALTH_URL_EFFECTIVE} через ${HEALTH_HTTP_RESOLVE_IP} отвечает '${code}' уже сейчас — после изменений не проверяется"
    fi
}

# ─── Health check ────────────────────────────────────────────────────────────
# Все контейнеры стека одной командой docker inspect:
# имя|сервис|статус|здоровье|перезапуски|запущен|код выхода|политика рестарта
stack_rows() {
    local ids
    ids=$(dc ps -aq 2>/dev/null || true)
    [[ -z "${ids}" ]] && return 0
    # shellcheck disable=SC2086
    docker inspect --format '{{.Name}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{.State.StartedAt}}|{{.State.ExitCode}}|{{.HostConfig.RestartPolicy.Name}}' \
        ${ids} 2>/dev/null | sed 's|^/||'
}

is_ignored_service() { [[ -n "$1" && " ${HEALTH_IGNORE_SERVICES} " == *" $1 "* ]]; }

print_container_line() {
    local mark="$1" color="$2" name="$3" state="$4" health="$5" restarts="$6"
    printf "  %b%s%b %-28s состояние=%-12s здоровье=%-12s перезапусков=%s\n" \
        "${color}" "${mark}" "${C_RESET}" "${name}" "${state}" "${health}" "${restarts}"
    printf "  %s %-28s состояние=%-12s здоровье=%-12s перезапусков=%s\n" \
        "${mark}" "${name}" "${state}" "${health}" "${restarts}" >> "${LOG_FILE}"
}

# Одна проверка. Результат: CHECK_FAILED (число проблем без учёта
# HEALTH_IGNORE_SERVICES), имена проблемных контейнеров — FAILED_CONTAINERS.
#   • не running (кроме одноразовых сервисов, завершившихся с кодом 0)
#   • RESTART_THRESHOLD+ перезапусков, если контейнер перезапускался после старта стека
#   • healthcheck unhealthy или ещё starting
#   • без healthcheck — работает меньше HEALTH_MIN_UPTIME секунд
#   • сервис из compose без контейнера
check_stack_once() {
    local rows services now name svc state health restarts started code policy problem kind started_e up s
    local seen=" "
    CHECK_FAILED=0
    FAILED_CONTAINERS=()
    rows=$(stack_rows)
    services=$(dc config --services 2>/dev/null || true)
    now=$(date +%s)
    while IFS='|' read -r name svc state health restarts started code policy; do
        [[ -z "${name}" ]] && continue
        seen+="${svc} "
        problem=""; kind=WARN
        started_e=$(to_epoch "${started}")
        up=$(( now - started_e ))
        [[ "${restarts}" =~ ^[0-9]+$ ]] || restarts=0
        if [[ "${state}" != running ]]; then
            if [[ "${state}" == exited && "${code}" == 0 && ( "${policy}" == no || -z "${policy}" ) ]]; then
                problem=""
            else
                problem="не запущен (${state}, код ${code})"
            fi
        elif (( restarts >= RESTART_THRESHOLD && started_e >= STACK_STARTED_EPOCH - 5 )); then
            problem="циклические перезапуски (${restarts} раз)"
        elif [[ "${health}" == unhealthy ]]; then
            problem="healthcheck: unhealthy"
        elif [[ "${health}" == starting ]]; then
            problem="ещё запускается (healthcheck: starting)"; kind=INFO
        elif [[ "${health}" == none ]] && (( up < HEALTH_MIN_UPTIME )); then
            problem="работает ${up}с, ждём ${HEALTH_MIN_UPTIME}с"; kind=INFO
        fi

        if [[ -z "${problem}" ]]; then
            print_container_line "✓" "${C_GREEN}" "${name}" "${state}" "${health}" "${restarts}"
            continue
        fi
        print_container_line "✗" "${C_RED}" "${name}" "${state}" "${health}" "${restarts}"
        if is_ignored_service "${svc}"; then
            log WARN "Контейнер '${name}': ${problem} — сервис в HEALTH_IGNORE_SERVICES, на откат не влияет"
        else
            log "${kind}" "Контейнер '${name}': ${problem}"
            FAILED_CONTAINERS+=("${name}")
            (( CHECK_FAILED++ )) || true
        fi
    done <<< "${rows}"

    while IFS= read -r s; do
        [[ -z "${s}" || "${seen}" == *" ${s} "* ]] && continue
        if is_ignored_service "${s}"; then
            log WARN "Сервис '${s}': контейнер не создан — сервис в HEALTH_IGNORE_SERVICES, на откат не влияет"
            continue
        fi
        log WARN "Сервис '${s}': контейнер не создан"
        (( CHECK_FAILED++ )) || true
    done <<< "${services}"
}

dump_failed_logs() {
    local -a names=("${FAILED_CONTAINERS[@]}")
    local n state
    if (( ${#names[@]} == 0 )); then
        while IFS='|' read -r n _ state _; do
            [[ -n "${n}" && "${state}" != running ]] && names+=("${n}")
        done <<< "$(stack_rows)"
    fi
    (( ${#names[@]} > 0 )) || return 0
    log ERROR "Дамп последних логов проблемных контейнеров:"
    for n in "${names[@]}"; do
        {
            echo "━━━ Логи контейнера: ${n} ━━━"
            docker logs --tail=50 "${n}" 2>&1
            echo "━━━ Конец логов: ${n} ━━━"
            echo ""
        } >> "${LOG_FILE}"
        log ERROR "Логи '${n}' записаны в ${LOG_FILE}"
    done
}

# Логи боевого Traefik с момента запуска: ошибки загрузки плагинов.
# При такой ошибке контейнер остаётся running — docker inspect её не видит.
traefik_plugins_ok() {
    local cid logs bad l
    cid=$(svc_cid traefik)
    [[ -z "${cid}" ]] && return 0
    logs=$(docker logs --since "${STACK_STARTED_AT:-10m}" "${cid}" 2>&1 || true)
    bad=$(grep -iE "${TRAEFIK_PLUGIN_ERR_RE}" <<< "${logs}" | tail -n 3 || true)
    if [[ -n "${bad}" ]]; then
        log WARN "Traefik: плагины не загрузились — ресурсы Pangolin недоступны, хотя контейнер работает:"
        while IFS= read -r l; do log WARN "  traefik> ${l:0:300}"; done <<< "${bad}"
        return 1
    fi
    return 0
}

# Возвращает: 0 — стек здоров; 1 — нездоров контейнер или HTTP;
#             3 — контейнеры работают, но Traefik не загрузил плагины.
# Опрос начинается сразу и завершается, как только всё в порядке.
health_check() {
    local attempt code
    log INFO "Health check: до ${HEALTH_RETRIES} попыток с интервалом ${HEALTH_INTERVAL}с"
    sleep "${HEALTH_INITIAL_WAIT}"
    for (( attempt=1; attempt<=HEALTH_RETRIES; attempt++ )); do
        log INFO "Проверка состояния стека (попытка ${attempt}/${HEALTH_RETRIES})..."
        check_stack_once
        if (( CHECK_FAILED == 0 )); then
            # Ошибка плагина не лечится ожиданием — повторы не нужны
            if ! traefik_plugins_ok; then
                log ERROR "Health check: контейнеры работают, но Traefik не загрузил плагины (Badger/CrowdSec)"
                return 3
            fi
            if [[ "${HTTP_BASELINE_OK}" == true ]]; then
                code=$(http_status "${HEALTH_URL_EFFECTIVE}")
                if http_ok "${code}"; then
                    log OK "HTTP-проверка: ${HEALTH_URL_EFFECTIVE} → ${code}"
                else
                    log WARN "HTTP-проверка: ${HEALTH_URL_EFFECTIVE} → ${code} (до изменений отвечал нормально)"
                    CHECK_FAILED=1
                fi
            fi
        fi
        if (( CHECK_FAILED == 0 )); then
            log OK "Health check пройден: контейнеры работают, плагины Traefik загружены"
            return 0
        fi
        if (( attempt < HEALTH_RETRIES )); then
            sleep "${HEALTH_INTERVAL}"
        fi
    done
    log ERROR "Health check провален после ${HEALTH_RETRIES} попыток"
    dump_failed_logs
    return 1
}

# ─── Частичный откат: вернуть только версию Badger ───────────────────────────
# Остальные компоненты остаются на новых версиях; перезапускается только Traefik.
badger_rollback() {
    local from="$1" rc
    log WARN "┌──────────────────────────────────────────────────────────┐"
    log WARN "│  ЧАСТИЧНЫЙ ОТКАТ: только Badger ${from} -> ${OLD_BADGER_V}"
    log WARN "└──────────────────────────────────────────────────────────┘"
    set_badger_version "${OLD_BADGER_V}" || return 1
    log OK "[Badger] В traefik_config.yml возвращена версия ${OLD_BADGER_V}"
    mark_stack_start
    if ! dc restart traefik >> "${LOG_FILE}" 2>&1; then
        log ERROR "[Badger] Не удалось перезапустить Traefik"
        return 1
    fi
    health_check
    rc=$?
    if (( rc == 0 )); then
        BADGER_V="${OLD_BADGER_V}"
        BADGER_HELD_BACK=true
        log OK "[Badger] Частичный откат успешен: Badger ${OLD_BADGER_V}, остальные компоненты обновлены"
    fi
    return "${rc}"
}

# ─── Полный откат к предыдущим версиям ───────────────────────────────────────
# Конфиги — из *.bak.<DATE_SUFFIX>. Если менялась версия Pangolin, его БД и
# config.yml возвращаются из архива, снятого перед обновлением: новая версия
# уже прогнала миграции, и старая на новой схеме могла бы не запуститься.
do_rollback() {
    ROLLBACK_DONE=true
    RECOVERY=""
    log WARN "┌─────────────────────────────────────────────┐"
    log WARN "│      ЗАПУСК ОТКАТА К ПРЕДЫДУЩЕЙ ВЕРСИИ      │"
    log WARN "└─────────────────────────────────────────────┘"

    log INFO "[Откат] Остановка контейнеров с новыми версиями..."
    dc down >> "${LOG_FILE}" 2>&1 || true

    log INFO "[Откат] Восстановление конфигурационных файлов (суффикс: ${DATE_SUFFIX})..."
    local f ok=true
    for f in "${COMPOSE_FILE}" "${TRAEFIK_CONFIG}"; do
        if [[ -f "${f}.bak.${DATE_SUFFIX}" ]]; then
            write_over "${f}.bak.${DATE_SUFFIX}" "${f}"
            log OK "[Откат] $(basename "${f}") восстановлен"
        else
            log ERROR "[Откат] Резервная копия не найдена: ${f}.bak.${DATE_SUFFIX}"
            ok=false
        fi
    done
    if [[ "${ok}" == false ]]; then
        log ERROR "[Откат] Не удалось восстановить конфигурации — требуется ручное вмешательство!"
        log ERROR "[Откат] Ищите резервные копии по маске: *.bak.${DATE_SUFFIX}; полный архив: ${LAST_ARCHIVE:-нет}"
        return 1
    fi
    if [[ "${ROLLBACK_DB}" == true ]]; then
        restore_db_from_archive || log ERROR "[Откат] БД Pangolin не восстановлена — старая версия может не запуститься на новой схеме. Архив: ${LAST_ARCHIVE:-нет}"
    fi

    log INFO "[Откат] Запуск стека на предыдущих версиях (образы в локальном кэше)..."
    mark_stack_start
    dc up -d >> "${LOG_FILE}" 2>&1 || log ERROR "[Откат] docker compose up завершился с ошибкой"

    local rc
    health_check
    rc=$?
    if (( rc == 0 )); then
        log OK "┌──────────────────────────────────────────────────────────┐"
        log OK "│  Откат выполнен успешно. Стек работает на старых версиях │"
        log OK "└──────────────────────────────────────────────────────────┘"
        return 0
    fi
    if (( rc == 3 )); then
        log ERROR "[Откат] Контейнеры работают, но Traefik не загрузил плагины и на старых версиях."
        log ERROR "[Откат] Вероятно, проблема на стороне каталога plugins.traefik.io — повторите позже."
    else
        log ERROR "[Откат] Стек нездоров после отката — требуется ручное вмешательство."
    fi
    return 1
}

restore_db_from_archive() {
    if stack_uses_postgres; then
        log WARN "[Откат] Pangolin работает на PostgreSQL — БД скрипт не откатывает. При необходимости восстановите её из своего бэкапа PostgreSQL."
        return 0
    fi
    if [[ -z "${LAST_ARCHIVE}" || ! -f "${LAST_ARCHIVE}" ]]; then
        log ERROR "[Откат] Нет архива, снятого перед обновлением — БД не восстановлена"
        return 1
    fi
    local keep="${BACKUP_DIR}/failed_${DATE_SUFFIX}" dbdir
    local -a members=(config/db)
    dbdir=$(dirname "${PANGOLIN_DB}")
    tar tzf "${LAST_ARCHIVE}" 2>/dev/null | grep -qx 'config/config.yml' && members+=(config/config.yml)
    # Состояние после неудачного запуска — для разбора причин
    (umask 077; mkdir -p "${keep}")
    cp -a "${dbdir}" "${keep}/" 2>/dev/null || true
    cp -a "${PANGOLIN_DIR}/config/config.yml" "${keep}/" 2>/dev/null || true
    rm -f "${PANGOLIN_DB}-wal" "${PANGOLIN_DB}-shm"
    if ! tar xzf "${LAST_ARCHIVE}" -C "${PANGOLIN_DIR}" "${members[@]}" >> "${LOG_FILE}" 2>&1; then
        log ERROR "[Откат] Не удалось распаковать ${members[*]} из ${LAST_ARCHIVE}"
        return 1
    fi
    log OK "[Откат] Из ${LAST_ARCHIVE} возвращены: ${members[*]} (состояние после сбоя сохранено в ${keep})"
}

# ─── Резервные копии ─────────────────────────────────────────────────────────
# Сортировка путей по дате в имени (старые первыми). Понимает новый формат
# YYYYMMDD_HHMMSS и прежний DDMMYYYY_HHMMSS — старые архивы тоже чистятся.
name_date_sort() {
    awk '{
        k = "00000000000000"
        if (match($0, /[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]/)) {
            d = substr($0, RSTART, 8); t = substr($0, RSTART + 9, 6)
            y = substr(d, 5, 4) + 0; m = substr(d, 3, 2) + 0
            if (y >= 2000 && y <= 2099 && m >= 1 && m <= 12) d = substr(d, 5, 4) substr(d, 3, 2) substr(d, 1, 2)
            k = d t
        }
        print k "\t" $0
    }' | sort -k1,1 | cut -f2-
}

# Оставить $1 самых свежих из перечисленных на stdin путей
keep_newest() {
    name_date_sort | head -n -"$1" | while IFS= read -r f; do
        [[ -n "${f}" ]] && rm -f -- "${f}"
    done
}

prune_bak_files() {
    local f
    for f in "${COMPOSE_FILE}" "${TRAEFIK_CONFIG}" "${TRAEFIK_DYNAMIC_CONFIG}"; do
        find "$(dirname "${f}")" -maxdepth 1 -name "$(basename "${f}").bak.*" -print 2>/dev/null | keep_newest "${BACKUP_KEEP}"
    done
}

# Копии конфигов перед изменением: <файл>.bak.<DATE_SUFFIX>
make_bak_copies() {
    local f
    for f in "$@"; do
        [[ -f "${f}" ]] && cp -p "${f}" "${f}.bak.${DATE_SUFFIX}"
    done
    prune_bak_files
    log OK "Копии конфигов: *.bak.${DATE_SUFFIX}"
}

ensure_backup_dir() {
    mkdir -p "${BACKUP_DIR}"
    chmod 700 "${BACKUP_DIR}"
}

# Хватит ли места под архив (проверяется до любых изменений)
check_backup_space() {
    local need avail
    ensure_backup_dir
    need=$(du -sk --exclude="${LOGS_EXCLUDE##*/}" "${PANGOLIN_DIR}/config" 2>/dev/null | cut -f1)
    need=$(( ${need:-0} + BACKUP_MIN_FREE_MB * 1024 ))
    avail=$(df -Pk "${BACKUP_DIR}" | awk 'NR == 2 { print $4 }')
    if (( ${avail:-0} < need )); then
        log ERROR "Мало места для резервной копии в ${BACKUP_DIR}: свободно $(( ${avail:-0} / 1024 )) МБ, нужно не меньше $(( need / 1024 )) МБ"
        return 1
    fi
}

sqlite_valid() { [[ -s "$1" && "$(head -c 15 "$1" 2>/dev/null)" == "SQLite format 3" ]]; }

# Согласованная копия работающей SQLite-базы (online backup API): sqlite3
# или python3 на хосте, иначе better-sqlite3 внутри контейнера pangolin.
sqlite_snapshot() {
    local src="$1" dest="$2" cid tmp_rel
    if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 -cmd '.timeout 15000' "${src}" ".backup '${dest}'" 2>> "${LOG_FILE}" && sqlite_valid "${dest}" && return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -I - "${src}" "${dest}" 2>> "${LOG_FILE}" <<'PY' && sqlite_valid "${dest}" && return 0
import sqlite3, sys
src = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=15)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close(); src.close()
PY
    fi
    cid=$(svc_cid pangolin)
    if [[ -n "${cid}" ]]; then
        tmp_rel="config/db/.pu-snapshot-$$.sqlite"
        if docker exec -w /app -e OUT="${tmp_rel}" "${cid}" node -e '
                const D = require("better-sqlite3");
                const db = new D("config/db/db.sqlite", { readonly: true, fileMustExist: true });
                db.backup(process.env.OUT).then(() => process.exit(0)).catch(e => { console.error(e); process.exit(1); });
            ' >> "${LOG_FILE}" 2>&1 && [[ -f "${PANGOLIN_DIR}/${tmp_rel}" ]]; then
            mv "${PANGOLIN_DIR}/${tmp_rel}" "${dest}"
            sqlite_valid "${dest}" && return 0
        fi
        rm -f "${PANGOLIN_DIR}/${tmp_rel}"
    fi
    return 1
}

# Горячая копия возможна: режим hot, SQLite (не PostgreSQL), файл БД на месте
hot_backup_possible() {
    [[ "${BACKUP_MODE}" == hot ]] || return 1
    stack_uses_postgres && return 1
    [[ -f "${PANGOLIN_DB}" ]]
}

# Полный архив: docker-compose.yml + config/ (БД, сертификаты, конфиги) +
# настройки Cloudflare. Режим hot — стек работает, БД берётся online-копией;
# cold — стек уже остановлен вызывающим. Архив доступен только root,
# проверяется после записи. Путь — в LAST_ARCHIVE.
# Возвращает 0; 1 — ошибка; 2 — горячая копия невозможна (нужна холодная).
create_backup_archive() {
    local mode="$1" prefix="${2:-pangolin}" archive tmpdir="" rc=0
    local -a members=(docker-compose.yml config) excl=(--exclude='*.bak.*' --exclude="${LOGS_EXCLUDE}" --exclude='.crowdsec-stage') extra=()
    ensure_backup_dir
    archive="${BACKUP_DIR}/${prefix}_$(date +%Y%m%d_%H%M%S).tar.gz"
    [[ -f "${CF_ENV_FILE}" && "${CF_ENV_FILE}" == "${PANGOLIN_DIR}"/* ]] && members+=("$(rel_path "${CF_ENV_FILE}")")

    if [[ "${mode}" == hot ]]; then
        tmpdir=$(mktemp -d)
        mkdir -p "${tmpdir}/db-snapshot"
        log INFO "Online-копия БД Pangolin (стек продолжает работать)..."
        if ! sqlite_snapshot "${PANGOLIN_DB}" "${tmpdir}/db-snapshot/db.sqlite"; then
            rm -rf "${tmpdir}"
            log WARN "Не удалось снять online-копию БД (нет sqlite3/python3 на хосте и контейнер pangolin недоступен)"
            return 2
        fi
        local db_rel
        db_rel=$(rel_path "${PANGOLIN_DB}")
        excl+=(--exclude="${db_rel}" --exclude="${db_rel}-*")
        extra=(--transform "s|^db-snapshot/db.sqlite\$|${db_rel}|" -C "${tmpdir}" db-snapshot/db.sqlite)
    fi

    log INFO "Архивирование ${PANGOLIN_DIR} (docker-compose.yml + config/)..."
    (umask 077; tar czf "${archive}" "${excl[@]}" -C "${PANGOLIN_DIR}" "${members[@]}" "${extra[@]}") >> "${LOG_FILE}" 2>&1 || rc=1
    [[ -n "${tmpdir}" ]] && rm -rf "${tmpdir}"
    if (( rc == 0 )) && ! gzip -t "${archive}" 2>> "${LOG_FILE}"; then rc=1; fi
    if (( rc != 0 )); then
        rm -f "${archive}"
        log ERROR "Не удалось создать резервную копию ${archive} — подробности в ${LOG_FILE}"
        return 1
    fi
    chmod 600 "${archive}"
    LAST_ARCHIVE="${archive}"
    log OK "Резервная копия создана: ${archive} ($(du -h "${archive}" | cut -f1), режим ${mode})"
    if [[ "${prefix}" == pangolin ]]; then
        find "${BACKUP_DIR}" -maxdepth 1 -name 'pangolin_*.tar.gz' -print | keep_newest "${BACKUP_KEEP}"
    fi
    return 0
}

# Перед изменениями стека: горячая копия, если возможна; иначе остановка + холодная.
# После вызова STACK_DOWN=true означает, что стек остановлен.
STACK_DOWN=false
backup_before_change() {
    local rc=0
    if hot_backup_possible; then
        create_backup_archive hot || rc=$?
        (( rc == 0 )) && return 0
        (( rc == 1 )) && return 1
        log WARN "Перехожу на холодную копию (с остановкой стека)"
    fi
    log INFO "Остановка Docker-стека (для консистентной копии БД)..."
    dc down >> "${LOG_FILE}" 2>&1
    STACK_DOWN=true
    log OK "Стек остановлен"
    create_backup_archive cold
}

recover_start_stack() {
    log INFO "Запуск Docker-стека..."
    mark_stack_start
    dc up -d >> "${LOG_FILE}" 2>&1 || log ERROR "docker compose up завершился с ошибкой"
    health_check
}

# ─── Режим -backup ───────────────────────────────────────────────────────────
do_backup() {
    local rc=0
    log INFO "Создание полной резервной копии стека (конфигурация, БД, сертификаты)"
    check_backup_space || exit "${E_PRECOND}"
    if hot_backup_possible; then
        create_backup_archive hot || rc=$?
        if (( rc == 0 )); then log_separator; exit "${E_OK}"; fi
        (( rc == 1 )) && exit "${E_FAIL}"
        log WARN "Перехожу на холодную копию (с остановкой стека)"
    fi
    log INFO "Остановка Docker-стека (для консистентной копии БД)..."
    RECOVERY=start_stack
    dc down >> "${LOG_FILE}" 2>&1
    log OK "Стек остановлен"
    rc=0
    create_backup_archive cold || rc=1
    RECOVERY=""
    if ! recover_start_stack; then
        log ERROR "Стек не прошёл проверку после резервного копирования! Проверьте: cd ${PANGOLIN_DIR} && docker compose ps"
        notify ERROR "backup-failed" "После холодного резервного копирования стек не прошёл health check"
        exit "${E_CRIT}"
    fi
    (( rc == 0 )) || exit "${E_FAIL}"
    log_separator
    exit "${E_OK}"
}

# ─── Режим -restore ──────────────────────────────────────────────────────────
do_restore() {
    local archive="${1:-}"
    if [[ -z "${archive}" ]]; then
        archive=$(find "${BACKUP_DIR}" -maxdepth 1 -name 'pangolin_*.tar.gz' -print 2>/dev/null | name_date_sort | tail -n1)
        if [[ -z "${archive}" ]]; then
            log ERROR "Резервные копии не найдены в ${BACKUP_DIR}"
            exit "${E_PRECOND}"
        fi
        log INFO "Архив не указан — использую последний: ${archive}"
    fi
    if [[ ! -f "${archive}" ]]; then
        log ERROR "Файл не найден: ${archive}"
        exit "${E_PRECOND}"
    fi
    if ! gzip -t "${archive}" 2>/dev/null || ! tar tzf "${archive}" >/dev/null 2>&1; then
        log ERROR "Архив повреждён или не является tar.gz: ${archive}"
        exit "${E_PRECOND}"
    fi

    log WARN "Восстановление из резервной копии: ${archive}"
    log WARN "Текущие конфигурация, БД и сертификаты будут перезаписаны содержимым архива"
    confirm "Восстановить стек из ${archive}?" || { log INFO "Восстановление отменено"; exit "${E_PRECOND}"; }

    # Страховочная копия текущего состояния (если есть что копировать)
    if [[ -f "${COMPOSE_FILE}" && -d "${PANGOLIN_DIR}/config" ]] && check_backup_space; then
        local rc=0
        if hot_backup_possible; then create_backup_archive hot pre-restore || rc=$?; else rc=2; fi
        if (( rc == 0 )); then
            log INFO "Текущее состояние сохранено: ${LAST_ARCHIVE} (не удаляется автоматически)"
        else
            log WARN "Страховочная копия текущего состояния не создана — продолжаю"
        fi
    fi

    log INFO "Остановка Docker-стека..."
    [[ -f "${COMPOSE_FILE}" ]] && { dc down >> "${LOG_FILE}" 2>&1 || true; }
    log OK "Стек остановлен"

    mkdir -p "${PANGOLIN_DIR}"
    rm -f "${PANGOLIN_DB}-wal" "${PANGOLIN_DB}-shm"   # WAL новой базы рядом со старой испортил бы её
    tar xzf "${archive}" -C "${PANGOLIN_DIR}"
    log OK "Файлы восстановлены из архива"

    log INFO "Скачивание образов (если отсутствуют в локальном кэше)..."
    dc pull >> "${LOG_FILE}" 2>&1 \
        || log WARN "docker compose pull завершился с ошибкой — пробуем запустить из кэша"

    local hc
    set +e
    recover_start_stack
    hc=$?
    set -e
    if (( hc != 0 )); then
        log ERROR "Стек восстановлен из архива, но не прошёл health check — смотрите логи выше"
        notify ERROR "restore-failed" "Стек восстановлен из ${archive}, но не прошёл health check"
        exit "${E_CRIT}"
    fi
    log OK "Восстановление из резервной копии выполнено успешно"
    log_separator
    exit "${E_OK}"
}

# ─── Удаление старых образов ─────────────────────────────────────────────────
# Вместо docker image prune -a (удалял ВСЕ неиспользуемые образы хоста)
# удаляются только образы, которые заменил скрипт:
#   previous  — предыдущая версия хранится до следующего успешного обновления
#               (можно вручную откатиться на день-два без скачивания);
#   immediate — удаляются сразу; none — не удаляются.
remove_image() {
    docker image rm "$1" >> "${LOG_FILE}" 2>&1 && log INFO "Удалён образ $1" || true
}

cleanup_images() {
    local list="${STATE_DIR}/previous-images" img
    local -a replaced=()
    mapfile -t replaced < <(replaced_images)
    # Образы из неудачной пробы, которые не стали рабочими
    for img in "${PROBE_PULLED[@]}"; do
        [[ "${img}" != "traefik:${TRAEFIK_V}" && "${img}" != "traefik:${OLD_TRAEFIK_V}" ]] && remove_image "${img}"
    done
    case "${PRUNE_MODE}" in
        none) return 0 ;;
        immediate)
            for img in "${replaced[@]}"; do remove_image "${img}"; done ;;
        *)
            if [[ -f "${list}" ]]; then
                while IFS= read -r img; do [[ -n "${img}" ]] && remove_image "${img}"; done < "${list}"
            fi
            printf '%s\n' "${replaced[@]}" > "${list}" 2>/dev/null || true
            (( ${#replaced[@]} > 0 )) && log INFO "Предыдущие образы сохранены до следующего обновления: ${replaced[*]}" ;;
    esac
    return 0
}

# ─── Интеграция с Cloudflare: DNS-записи для поддоменов Pangolin ─────────────
# Список поддоменов — из конфигурации, которую Pangolin отдаёт Traefik
# (/api/v1/traefik-config, Host-правила всех ресурсов). Скрипт создаёт
# недостающие A-записи, обновляет IP в СВОИХ записях (помечены комментарием
# CF_MARK) и, если CF_DELETE_STALE=true, удаляет свои записи удалённых
# ресурсов. Чужие и ручные записи не меняются никогда.

cf_api() {
    curl -sS --max-time 20 --retry 2 \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" "$@" 2>> "${LOG_FILE}"
}

# Все страницы списка Cloudflare: печатает элементы .result[] построчно (JSON)
cf_list() {
    local url="$1" page=1 pages=1 resp sep="?"
    [[ "${url}" == *\?* ]] && sep="&"
    while (( page <= pages )); do
        resp=$(cf_api "${url}${sep}page=${page}") || return 1
        [[ "$(jq -r '.success' <<< "${resp}" 2>/dev/null)" == true ]] || {
            log ERROR "[DNS] Cloudflare API: $(jq -r '[.errors[]?.message] | join("; ")' <<< "${resp}" 2>/dev/null)"
            return 1
        }
        jq -c '.result[]' <<< "${resp}"
        pages=$(jq -r '.result_info.total_pages // 1' <<< "${resp}")
        (( page++ ))
    done
}

# Загрузить настройки интеграции из CF_ENV_FILE (файл не исполняется)
load_cf_env() {
    if [[ ! -f "${CF_ENV_FILE}" ]]; then
        log ERROR "Интеграция с Cloudflare не включена (нет файла ${CF_ENV_FILE})."
        log ERROR "Включите: CLOUDFLARE_API_TOKEN=<токен> $(basename "$0") --cloudflare"
        return 1
    fi
    check_secret_file "${CF_ENV_FILE}" || return 1
    CF_TOKEN=$(env_get "${CF_ENV_FILE}" CF_TOKEN)
    CF_TARGET_IP=$(env_get "${CF_ENV_FILE}" CF_TARGET_IP)
    CF_PROXIED=$(env_get "${CF_ENV_FILE}" CF_PROXIED)
    local del
    del=$(env_get "${CF_ENV_FILE}" CF_DELETE_STALE)
    [[ -n "${del}" ]] && CF_DELETE_STALE="${del}"
    [[ "${CF_PROXIED}" == true ]] || CF_PROXIED=false
    if [[ -z "${CF_TOKEN}" || -z "${CF_TARGET_IP}" ]]; then
        log ERROR "В ${CF_ENV_FILE} не заданы CF_TOKEN и/или CF_TARGET_IP"
        return 1
    fi
}

# Адрес для A-записей: значение CF_TARGET_IP или, при CF_TARGET_IP=auto,
# текущий внешний IPv4 сервера (согласованный двумя сервисами)
cf_target_ip() {
    if [[ "${CF_TARGET_IP}" == auto ]]; then
        public_ip_consensus 4
    else
        echo "${CF_TARGET_IP}"
    fi
}

# Список FQDN всех ресурсов Pangolin. Запрос выполняется внутри контейнера
# pangolin (там есть curl), поэтому порт API наружу не нужен.
get_pangolin_hostnames() {
    local cid cfg="" ip
    cid=$(svc_cid pangolin)
    if [[ -z "${cid}" ]]; then
        log ERROR "[DNS] Контейнер pangolin не запущен — не могу получить список поддоменов"
        return 1
    fi
    cfg=$(docker exec "${cid}" curl -sf --max-time 10 http://localhost:3001/api/v1/traefik-config 2>/dev/null) || cfg=""
    if [[ -z "${cfg}" ]]; then
        ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "${cid}" | awk '{ print $1 }')
        cfg=$(curl -sf --max-time 10 "http://${ip}:3001/api/v1/traefik-config") || {
            log ERROR "[DNS] Не удалось получить /api/v1/traefik-config от Pangolin"
            return 1
        }
    fi
    # shellcheck disable=SC2016  # обратные кавычки — часть правила Host(`...`), а не подстановка
    grep -oE 'Host\(`[^`]+`\)' <<< "${cfg}" | sed -E 's/^Host\(`//; s/`\)$//' | tr '[:upper:]' '[:lower:]' | sort -u || true
}

# ─── Ядро синхронизации DNS ──────────────────────────────────────────────────
# Если список поддоменов, целевой IP и режим не менялись — Cloudflare не
# запрашивается вовсе (полная сверка раз в CF_FULL_RESYNC_MIN минут).
# Иначе: зоны — одним списком, записи — одним списком на зону, сравнение
# локально. Возвращает 0 или 1 (были ошибки).
dns_sync_run() {
    local hostnames target verbose=false sig sigf="${STATE_DIR}/dns.sig"
    [[ -t 1 ]] && verbose=true
    hostnames=$(get_pangolin_hostnames) || return 1
    if ! target=$(cf_target_ip) || [[ -z "${target}" ]]; then
        log ERROR "[DNS] Не удалось определить IP для A-записей (CF_TARGET_IP=${CF_TARGET_IP})"
        return 1
    fi
    sig=$(printf '%s\n%s %s %s\n' "${hostnames}" "${target}" "${CF_PROXIED}" "${CF_DELETE_STALE}" | md5sum | cut -d' ' -f1)
    if [[ "${verbose}" == false && -s "${sigf}" && "$(<"${sigf}")" == "${sig}" ]] \
            && (( $(file_age_min "${sigf}") < CF_FULL_RESYNC_MIN )); then
        return 0
    fi

    local zones
    zones=$(cf_list "${CF_API}/zones?status=active&per_page=50" | jq -r '[.id, .name] | @tsv') || return 1

    # Зона для каждого FQDN — самый длинный совпадающий суффикс
    local fqdn zid zname best_id best_name map=""
    while IFS= read -r fqdn; do
        [[ -z "${fqdn}" ]] && continue
        best_id=""; best_name=""
        while IFS=$'\t' read -r zid zname; do
            [[ -z "${zid}" ]] && continue
            if [[ "${fqdn}" == "${zname}" || "${fqdn}" == *".${zname}" ]] && (( ${#zname} > ${#best_name} )); then
                best_id="${zid}"; best_name="${zname}"
            fi
        done <<< "${zones}"
        map+="${fqdn}"$'\t'"${best_id}"$'\t'"${best_name}"$'\n'
    done <<< "${hostnames}"

    local created=0 updated=0 skipped=0 external=0 failed=0 deleted=0
    local zone_ids records rec_id rec_type rec_name rec_content rec_comment body ok
    zone_ids=$(awk -F'\t' '$2 != "" { print $2 }' <<< "${map}" | sort -u)
    # Для удаления устаревших смотрим все зоны, где у скрипта есть записи
    [[ "${CF_DELETE_STALE}" == true ]] && zone_ids=$(cut -f1 <<< "${zones}")

    local all_records=""
    for zid in ${zone_ids}; do
        records=$(cf_list "${CF_API}/zones/${zid}/dns_records?per_page=1000" \
            | jq -r --arg z "${zid}" '[$z, .id, .type, .name, .content, (.comment // "")] | @tsv') || { (( failed++ )) || true; continue; }
        [[ -n "${records}" ]] && all_records+="${records}"$'\n'
    done

    while IFS=$'\t' read -r fqdn zid zname; do
        [[ -z "${fqdn}" ]] && continue
        if [[ -z "${zid}" ]]; then
            [[ "${verbose}" == true ]] && log WARN "[DNS] Зона для '${fqdn}' не найдена в Cloudflare — пропускаю"
            (( external++ )) || true
            continue
        fi
        rec_id=""; rec_type=""; rec_content=""; rec_comment=""
        IFS=$'\t' read -r _ rec_id rec_type rec_name rec_content rec_comment < <(
            awk -F'\t' -v z="${zid}" -v n="${fqdn}" '$1 == z && tolower($4) == n { print; exit }' <<< "${all_records}") || true
        if [[ -z "${rec_id}" ]]; then
            body=$(jq -nc --arg n "${fqdn}" --arg c "${target}" --arg m "${CF_MARK}" --argjson p "${CF_PROXIED}" \
                '{type: "A", name: $n, content: $c, ttl: 1, proxied: $p, comment: $m}')
            ok=$(cf_api -X POST "${CF_API}/zones/${zid}/dns_records" --data "${body}" | jq -r '.success' 2>/dev/null || true)
            if [[ "${ok}" == true ]]; then
                log OK "[DNS] Создана A-запись: ${fqdn} -> ${target} (зона ${zname}, proxied=${CF_PROXIED})"
                (( created++ )) || true
            else
                log ERROR "[DNS] Не удалось создать запись '${fqdn}' — проверьте права токена (Zone:Read, DNS:Edit) для зоны ${zname}"
                (( failed++ )) || true
            fi
        elif [[ "${rec_comment}" == "${CF_MARK}" && "${rec_type}" == A && "${rec_content}" != "${target}" ]]; then
            body=$(jq -nc --arg c "${target}" '{content: $c}')
            ok=$(cf_api -X PATCH "${CF_API}/zones/${zid}/dns_records/${rec_id}" --data "${body}" | jq -r '.success' 2>/dev/null || true)
            if [[ "${ok}" == true ]]; then
                log OK "[DNS] Обновлена A-запись: ${fqdn} ${rec_content} -> ${target}"
                (( updated++ )) || true
            else
                log ERROR "[DNS] Не удалось обновить запись '${fqdn}'"
                (( failed++ )) || true
            fi
        else
            (( skipped++ )) || true
        fi
    done <<< "${map}"

    # Свои записи, ресурсов для которых больше нет. Удаляются, только если
    # запись «осиротела» в двух синхронизациях подряд и список ресурсов не пуст
    # (Pangolin при старте может кратко отдавать пустую конфигурацию).
    local stale_f="${STATE_DIR}/dns.stale" prev_stale="" now_stale=""
    [[ -f "${stale_f}" ]] && prev_stale=$(<"${stale_f}")
    while IFS=$'\t' read -r zid rec_id rec_type rec_name rec_content rec_comment; do
        [[ -z "${rec_id}" || "${rec_comment}" != "${CF_MARK}" ]] && continue
        grep -qxF -- "${rec_name,,}" <<< "${hostnames}" && continue
        if [[ "${CF_DELETE_STALE}" != true ]]; then
            [[ "${verbose}" == true ]] && log INFO "[DNS] ${rec_name}: ресурса больше нет (запись оставлена; удаление — CF_DELETE_STALE=true)"
            continue
        fi
        [[ -z "${hostnames}" ]] && continue
        now_stale+="${rec_id}"$'\n'
        if grep -qxF -- "${rec_id}" <<< "${prev_stale}"; then
            ok=$(cf_api -X DELETE "${CF_API}/zones/${zid}/dns_records/${rec_id}" | jq -r '.success' 2>/dev/null || true)
            if [[ "${ok}" == true ]]; then
                log OK "[DNS] Удалена запись ресурса, которого больше нет: ${rec_name} (${rec_content})"
                (( deleted++ )) || true
            else
                log ERROR "[DNS] Не удалось удалить запись '${rec_name}'"
                (( failed++ )) || true
            fi
        else
            log INFO "[DNS] ${rec_name}: ресурса больше нет — запись будет удалена при следующей синхронизации"
        fi
    done <<< "${all_records}"
    printf '%s' "${now_stale}" > "${stale_f}" 2>/dev/null || true

    if (( created > 0 || updated > 0 || deleted > 0 || failed > 0 )) || [[ "${verbose}" == true ]]; then
        log INFO "[DNS] Синхронизация: создано ${created}, обновлено ${updated}, удалено ${deleted}, без изменений ${skipped}, вне Cloudflare ${external}, ошибок ${failed}"
    fi
    (( failed > 0 )) && return 1
    # Сигнатуру сохраняем, только если «осиротевших» записей на очереди нет
    [[ -z "${now_stale}" ]] && printf '%s' "${sig}" > "${sigf}" 2>/dev/null
    return 0
}

# ─── Режим -dns-sync (вызывается из cron) ────────────────────────────────────
do_dns_sync() {
    load_cf_env || exit "${E_PRECOND}"
    dns_sync_run && exit "${E_OK}" || exit "${E_FAIL}"
}

# ─── Включение интеграции с Cloudflare ───────────────────────────────────────
cf_enable() {
    local token="${1:-${CLOUDFLARE_API_TOKEN:-${CLOUDFLARE_DNS_API_TOKEN:-}}}"
    if [[ -n "${1:-}" ]]; then
        log WARN "Токен передан аргументом: он виден в списке процессов и истории shell. Надёжнее: CLOUDFLARE_API_TOKEN=<токен> $(basename "$0") --cloudflare"
    fi
    if [[ -z "${token}" && -f "${CF_ENV_FILE}" ]]; then
        token=$(env_get "${CF_ENV_FILE}" CF_TOKEN)
    fi
    if [[ -z "${token}" ]]; then
        log ERROR "Не указан API-токен Cloudflare. Передайте его через переменную окружения:"
        log ERROR "  CLOUDFLARE_API_TOKEN=<токен> $(basename "$0") --cloudflare"
        log ERROR "Токен создаётся в dash.cloudflare.com -> My Profile -> API Tokens"
        log ERROR "с правами Zone:Read и DNS:Edit для зоны вашего домена."
        exit "${E_PRECOND}"
    fi

    log INFO "Включение интеграции с Cloudflare (автосоздание DNS-записей для поддоменов)"
    CF_TOKEN="${token}"
    if [[ "$(cf_api "${CF_API}/user/tokens/verify" | jq -r '.success' 2>/dev/null || true)" != "true" ]]; then
        log ERROR "Токен Cloudflare не прошёл проверку (${CF_API}/user/tokens/verify)"
        exit "${E_PRECOND}"
    fi
    log OK "Токен Cloudflare действителен"

    local existing_ip="" proxied="${CF_PROXIED}"
    if [[ -f "${CF_ENV_FILE}" ]]; then
        existing_ip=$(env_get "${CF_ENV_FILE}" CF_TARGET_IP)
        proxied=$(env_get "${CF_ENV_FILE}" CF_PROXIED)
    fi
    [[ "${proxied}" == true ]] || proxied=false
    if [[ -n "${existing_ip}" ]]; then
        CF_TARGET_IP="${existing_ip}"
    elif ! CF_TARGET_IP=$(public_ip_consensus 4); then
        log ERROR "Не удалось надёжно определить публичный IPv4 сервера (сервисы не дали согласованного ответа)."
        log ERROR "Создайте ${CF_ENV_FILE} вручную или повторите позже."
        exit "${E_PRECOND}"
    fi
    log INFO "IP для A-записей: ${CF_TARGET_IP} (CF_TARGET_IP в ${CF_ENV_FILE}; значение auto — следить за сменой IP)"

    (
        umask 077
        cat > "${CF_ENV_FILE}" <<EOF
# Интеграция pangolin-update с Cloudflare DNS (создано $(date '+%Y-%m-%d %H:%M:%S'))
CF_TOKEN="${token}"
CF_TARGET_IP="${CF_TARGET_IP}"   # IP для A-записей; auto = текущий внешний IPv4 сервера
CF_PROXIED=${proxied}             # true = проксировать через Cloudflare (оранжевое облако)
CF_DELETE_STALE=${CF_DELETE_STALE}        # true = удалять свои записи удалённых ресурсов
EOF
    )
    chmod 600 "${CF_ENV_FILE}"
    log OK "Настройки сохранены: ${CF_ENV_FILE} (права 600)"
    CF_PROXIED="${proxied}"

    local script_path
    script_path=$(readlink -f "$0")
    cat > "${CF_CRON_FILE}" <<EOF
# Автосинхронизация DNS-записей Cloudflare с ресурсами Pangolin (pangolin-update)
*/${CF_SYNC_INTERVAL} * * * * root ${script_path} --dns-sync >/dev/null 2>&1
EOF
    chmod 644 "${CF_CRON_FILE}"
    log OK "cron-задача создана: ${CF_CRON_FILE} (каждые ${CF_SYNC_INTERVAL} мин)"

    log INFO "Первичная синхронизация DNS-записей..."
    if dns_sync_run; then
        log OK "Интеграция с Cloudflare включена. Новые поддомены Pangolin будут"
        log OK "получать A-записи автоматически (проверка каждые ${CF_SYNC_INTERVAL} мин)."
    else
        log WARN "Интеграция включена, но при первичной синхронизации были ошибки — см. лог выше"
    fi
    log_separator
    exit "${E_OK}"
}

# ─── Отключение интеграции с Cloudflare ──────────────────────────────────────
cf_disable() {
    local removed=false
    if [[ -f "${CF_CRON_FILE}" ]]; then
        rm -f "${CF_CRON_FILE}"
        log OK "cron-задача удалена: ${CF_CRON_FILE}"
        removed=true
    fi
    if [[ -f "${CF_ENV_FILE}" ]]; then
        rm -f "${CF_ENV_FILE}"
        log OK "Файл настроек удалён: ${CF_ENV_FILE}"
        removed=true
    fi
    rm -f "${STATE_DIR}/dns.sig" "${STATE_DIR}/dns.stale"
    if [[ "${removed}" == true ]]; then
        log OK "Интеграция с Cloudflare отключена — новые поддомены больше не синхронизируются"
        log INFO "Уже созданные DNS-записи в Cloudflare сохранены. При необходимости удалите их"
        log INFO "вручную — они помечены комментарием '${CF_MARK}'."
    else
        log INFO "Интеграция с Cloudflare не была включена. Ничего не меняю."
    fi
    log_separator
    exit "${E_OK}"
}

# ════════════════════════════════════════════════════════════════════════════════
# Установка / удаление CrowdSec в работающем Pangolin
# ════════════════════════════════════════════════════════════════════════════════
# YAML правится утилитой yq в одноразовом контейнере (на хост ничего не
# ставится, комментарии и порядок ключей сохраняются). Все правки делаются
# на КОПИЯХ конфигов в каталоге .crowdsec-stage, пока стек работает, и
# проверяются (docker compose config). Только после этого копии подменяют
# рабочие файлы — простой сокращается до перезапуска Traefik.

CS_STAGE_REL=".crowdsec-stage"
CS_TRAEFIK_LOG_VOLUME="./config/traefik/logs:/var/log/traefik"
CS_ACCESS_LOG="/var/log/traefik/access.log"
CS_KEY_REL="config/traefik/crowdsec-bouncer.key"   # ключ bouncer (файл, а не значение в YAML)
YQ_ENV=()                                          # доп. переменные для strenv(): (-e NAME=value ...)

yqd() {
    docker run --rm -u 0:0 -v "${PANGOLIN_DIR}:/workdir" -w /workdir \
        ${YQ_ENV[@]+"${YQ_ENV[@]}"} "${YQ_IMAGE}" "$@"
}

# Пути копий в каталоге подготовки (относительно PANGOLIN_DIR — для yq)
cs_stage_compose() { echo "${CS_STAGE_REL}/docker-compose.yml"; }
cs_stage_traefik() { echo "${CS_STAGE_REL}/traefik_config.yml"; }
cs_stage_dynamic() { echo "${CS_STAGE_REL}/dynamic_config.yml"; }

cs_stage_init() {
    local dir="${PANGOLIN_DIR}/${CS_STAGE_REL}"
    rm -rf "${dir}"
    (umask 077; mkdir -p "${dir}")
    cp -p "${COMPOSE_FILE}" "${PANGOLIN_DIR}/$(cs_stage_compose)"
    cp -p "${TRAEFIK_CONFIG}" "${PANGOLIN_DIR}/$(cs_stage_traefik)"
    cp -p "${TRAEFIK_DYNAMIC_CONFIG}" "${PANGOLIN_DIR}/$(cs_stage_dynamic)"
}

cs_stage_cleanup() { rm -rf "${PANGOLIN_DIR:?}/${CS_STAGE_REL}"; }

cs_stage_validate() {
    if ! docker compose --project-directory "${PANGOLIN_DIR}" -f "${PANGOLIN_DIR}/$(cs_stage_compose)" config -q >> "${LOG_FILE}" 2>&1; then
        log ERROR "docker-compose.yml после изменений не проходит проверку (docker compose config) — подробности в ${LOG_FILE}"
        return 1
    fi
}

# Подменить рабочие конфиги подготовленными копиями (inode сохраняется)
cs_stage_swap_in() {
    write_over "${PANGOLIN_DIR}/$(cs_stage_compose)" "${COMPOSE_FILE}"
    write_over "${PANGOLIN_DIR}/$(cs_stage_traefik)" "${TRAEFIK_CONFIG}"
    write_over "${PANGOLIN_DIR}/$(cs_stage_dynamic)" "${TRAEFIK_DYNAMIC_CONFIG}"
}

# Имя контейнера сервиса: container_name из compose или <проект>-<сервис>-1
compose_container_name() {
    local svc="$1" name project
    YQ_ENV=(-e "SVC=${svc}")
    name=$(yqd '.services[strenv(SVC)].container_name // ""' "$(rel_path "${COMPOSE_FILE}")" 2>/dev/null || true)
    YQ_ENV=()
    if [[ -z "${name}" || "${name}" == "null" ]]; then
        project=$(dc config --format json 2>/dev/null | jq -r '.name // empty' || true)
        name="${project:-$(basename "${PANGOLIN_DIR}")}-${svc}-1"
    fi
    echo "${name}"
}

# Путь в контейнере traefik, куда примонтирован каталог config/traefik
# (для файла ключа bouncer). Пусто — каталог не примонтирован.
traefik_conf_mount() {
    local v host target
    while IFS= read -r v; do
        host="${v%%:*}"; target="${v#*:}"; target="${target%%:*}"
        host="${host%/}"
        if [[ "${host}" == "./config/traefik" || "${host}" == "config/traefik" || "${host}" == "${PANGOLIN_DIR}/config/traefik" ]]; then
            echo "${target%/}"; return 0
        fi
    done < <(yqd '.services.traefik.volumes[]? | select(type == "!!str")' "$(rel_path "${COMPOSE_FILE}")" 2>/dev/null || true)
}

# Диапазоны Cloudflare (для режима «оранжевого облака»)
get_cloudflare_ranges() {
    { curl -sf --max-time 10 https://www.cloudflare.com/ips-v4 || true; echo
      curl -sf --max-time 10 https://www.cloudflare.com/ips-v6 || true; echo
    } | grep -E '^[0-9a-fA-F:.]+/[0-9]+$' || true
}

# ─── Фрагменты конфигурации ──────────────────────────────────────────────────
# $1 — каталог фрагментов, $2 — путь к файлу ключа в контейнере traefik
# (пусто — ключ пишется в YAML), $3 — сам ключ, $4..$6 — имена контейнеров.
cs_write_fragments() {
    local tmp="$1" key_path="$2" key="$3" traefik_cn="$4" pangolin_cn="$5" gerbil_cn="$6"
    local cf_proxied=false ranges="" r ip

    cat > "${tmp}/crowdsec.yml" <<EOF
image: docker.io/crowdsecurity/crowdsec:${CROWDSEC_IMAGE_TAG}
container_name: ${CROWDSEC_SERVICE}
restart: unless-stopped
environment:
  GID: "1000"
  # Разбор логов Traefik + правила WAF (AppSec). OWASP CRS не включён (много
  # ложных срабатываний): cscli collections install crowdsecurity/appsec-crs
  COLLECTIONS: crowdsecurity/traefik crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-generic-rules
  PARSERS: crowdsecurity/whitelists
healthcheck:
  test: ["CMD", "cscli", "lapi", "status"]
  interval: 10s
  timeout: 5s
  retries: 5
  start_period: 90s
labels:
  - traefik.enable=false
volumes:
  - ./config/crowdsec:/etc/crowdsec
  - ./config/crowdsec/db:/var/lib/crowdsec/data
  - ./config/traefik/logs:/var/log/traefik:ro
# Порты не публикуются: LAPI, AppSec и метрики доступны только в docker-сети
EOF

    cat > "${tmp}/manager.yml" <<EOF
image: ${CROWDSEC_MANAGER_IMAGE}
container_name: crowdsec-manager
restart: unless-stopped
# Нет собственной авторизации + docker.sock (= root на хосте): порт НЕ публикуется,
# открывать только как ресурс Pangolin с включённой аутентификацией
expose:
  - "8080"
environment:
  - PORT=8080
  - ENVIRONMENT=production
  - TRAEFIK_CONTAINER_NAME=${traefik_cn}
  - PANGOLIN_CONTAINER_NAME=${pangolin_cn}
  - GERBIL_CONTAINER_NAME=${gerbil_cn}
  - CROWDSEC_CONTAINER_NAME=${CROWDSEC_SERVICE}
  - TRAEFIK_STATIC_CONFIG=/etc/traefik/traefik_config.yml
  - TRAEFIK_DYNAMIC_CONFIG=/etc/traefik/dynamic_config.yml
  - TRAEFIK_ACCESS_LOG=${CS_ACCESS_LOG}
  - CROWDSEC_METRICS_URL=http://${CROWDSEC_SERVICE}:6060/metrics
  - ALERT_LIST_LIMIT=5000
volumes:
  - /var/run/docker.sock:/var/run/docker.sock
  - ./config:/app/config
  # только чтение: обновлениями стека управляет pangolin-update.sh
  - ./docker-compose.yml:/app/docker-compose.yml:ro
  - ./config/traefik/logs:/var/log/traefik:ro
  - ./crowdsec-manager/data:/app/data
  - ./crowdsec-manager/backups:/app/backups
depends_on:
  ${CROWDSEC_SERVICE}:
    condition: service_healthy
EOF

    cat > "${tmp}/accesslog.yml" <<EOF
filePath: ${CS_ACCESS_LOG}
format: json
bufferingSize: 100
fields:
  defaultMode: keep
  headers:
    defaultMode: drop
    names:
      User-Agent: keep
      Content-Type: keep
      Authorization: redact
      Cookie: redact
EOF

    # Cloudflare-прокси: Traefik видит адреса Cloudflare, реальный IP — в заголовке
    if [[ -f "${CF_ENV_FILE}" && "$(env_get "${CF_ENV_FILE}" CF_PROXIED)" == true ]]; then
        cf_proxied=true
        ranges=$(get_cloudflare_ranges)
    fi

    {
        cat <<EOF
plugin:
  crowdsec:
    enabled: true
    logLevel: INFO
    # Баны: список кэшируется в Traefik и обновляется раз в 15 с
    crowdsecMode: stream
    updateIntervalSeconds: 15
    updateMaxFailure: -1                  # CrowdSec недоступен → работать по последнему кэшу
    crowdsecLapiScheme: http
    crowdsecLapiHost: ${CROWDSEC_SERVICE}:8080
EOF
        if [[ -n "${key_path}" ]]; then
            echo "    crowdsecLapiKeyFile: ${key_path}   # ключ в файле, а не в конфиге"
        else
            echo "    crowdsecLapiKey: ${key}"
        fi
        cat <<EOF
    # AppSec (WAF): проверка каждого запроса
    crowdsecAppsecEnabled: true
    crowdsecAppsecHost: ${CROWDSEC_SERVICE}:7422
    crowdsecAppsecFailureBlock: true
    crowdsecAppsecUnreachableBlock: false # CrowdSec лёг → сайты работают без WAF, а не блокируются целиком
    crowdsecAppsecBodyLimit: 10485760
EOF
        # Клиенты в обход bouncer и AppSec — только явно заданные адреса
        if [[ -n "${CROWDSEC_CLIENT_TRUSTED_IPS}" ]]; then
            echo "    clientTrustedIPs:   # CROWDSEC_CLIENT_TRUSTED_IPS: эти клиенты не проверяются"
            for ip in ${CROWDSEC_CLIENT_TRUSTED_IPS}; do echo "      - ${ip}"; done
        else
            echo "    clientTrustedIPs: []   # без исключений (CROWDSEC_CLIENT_TRUSTED_IPS)"
        fi
        if [[ "${cf_proxied}" == true && -n "${ranges}" ]]; then
            echo "    # Cloudflare-прокси (CF_PROXIED=true): реальный IP клиента — в CF-Connecting-IP"
            echo "    forwardedHeadersCustomName: CF-Connecting-IP"
            echo "    forwardedHeadersTrustedIPs:"
            while read -r r; do echo "      - ${r}"; done <<< "${ranges}"
        else
            echo "    # Traefik первый на входе: заголовкам X-Forwarded-For не доверяем (иначе бан обходится подменой IP)"
            echo "    forwardedHeadersTrustedIPs: []"
        fi
    } > "${tmp}/middleware.yml"

    if [[ "${cf_proxied}" == true && -z "${ranges}" ]]; then
        log WARN "CF_PROXIED=true, но список адресов Cloudflare получить не удалось — пропишите их в forwardedHeadersTrustedIPs вручную"
    elif [[ "${cf_proxied}" == true ]]; then
        log INFO "CF_PROXIED=true: реальный IP клиента берётся из CF-Connecting-IP, доверенные адреса — диапазоны Cloudflare"
    fi
}

cs_write_acquis() {
    local dir="${PANGOLIN_DIR}/config/crowdsec/acquis.d"
    mkdir -p "${dir}"
    if [[ ! -f "${dir}/traefik.yaml" ]]; then
        cat > "${dir}/traefik.yaml" <<EOF
# Источник событий: access-лог Traefik (JSON)
poll_without_inotify: false
filenames:
  - ${CS_ACCESS_LOG}
labels:
  type: traefik
EOF
    fi
    if [[ ! -f "${dir}/appsec.yaml" ]]; then
        cat > "${dir}/appsec.yaml" <<'EOF'
# Компонент AppSec (WAF): к нему обращается bouncer в Traefik (crowdsec:7422)
listen_addr: 0.0.0.0:7422
appsec_config: crowdsecurity/appsec-default
name: pangolin-appsec
source: appsec
labels:
  type: appsec
EOF
    fi
}

# Ротация access-лога без потерь: файл переименовывается, Traefik по сигналу
# USR1 открывает новый (copytruncate терял строки между копированием и обрезкой)
cs_write_logrotate() {
    [[ -d "$(dirname "${TRAEFIK_LOGROTATE_FILE}")" ]] || {
        log WARN "logrotate не найден — настройте ротацию ${PANGOLIN_DIR}/config/traefik/logs/access.log вручную"
        return 0
    }
    cat > "${TRAEFIK_LOGROTATE_FILE}" <<EOF
# Ротация access-лога Traefik, который читает CrowdSec (pangolin-update.sh)
${PANGOLIN_DIR}/config/traefik/logs/access.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        docker compose --project-directory ${PANGOLIN_DIR} -f ${COMPOSE_FILE} kill -s USR1 traefik >/dev/null 2>&1 || true
    endscript
}
EOF
    log OK "Ротация access-лога: ${TRAEFIK_LOGROTATE_FILE} (ежедневно, 7 архивов, переоткрытие по USR1)"
}

# Ждать, пока LAPI CrowdSec начнёт отвечать (первый старт качает правила из Hub)
cs_wait_ready() {
    local cid waited=0
    while (( waited < 180 )); do
        cid=$(crowdsec_cid)
        if [[ -n "${cid}" ]] && docker exec "${cid}" cscli lapi status >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
        (( waited += 5 ))
    done
    return 1
}

# Вернуть три конфига из .bak текущей операции
cs_restore_files() {
    local f ok=0
    for f in "${COMPOSE_FILE}" "${TRAEFIK_CONFIG}" "${TRAEFIK_DYNAMIC_CONFIG}"; do
        if [[ -f "${f}.bak.${DATE_SUFFIX}" ]]; then
            write_over "${f}.bak.${DATE_SUFFIX}" "${f}"
        else
            log ERROR "Нет резервной копии ${f}.bak.${DATE_SUFFIX}"
            ok=1
        fi
    done
    return "${ok}"
}

# ─── Подготовка установки на копиях (стек работает). Возвращает 0/1 ──────────
CS_KEY=""
CS_KEY_PATH=""
crowdsec_install_stage() {
    local frag="${PANGOLIN_DIR}/${CS_STAGE_REL}" t sc st sd
    sc=$(cs_stage_compose); st=$(cs_stage_traefik); sd=$(cs_stage_dynamic)
    cs_stage_init

    CS_KEY=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-48)
    CS_KEY_PATH=""
    local mount
    mount=$(traefik_conf_mount)
    if [[ -n "${mount}" ]]; then
        CS_KEY_PATH="${mount}/$(basename "${CS_KEY_REL}")"
    else
        log WARN "[Установка] config/traefik не примонтирован в traefik — ключ bouncer будет записан прямо в dynamic_config.yml"
    fi
    cs_write_fragments "${frag}" "${CS_KEY_PATH}" "${CS_KEY}" "${CS_TRAEFIK_CN}" "${CS_PANGOLIN_CN}" "${CS_GERBIL_CN}"

    # ── docker-compose.yml ──
    log INFO "[Подготовка] docker-compose.yml: сервисы ${CROWDSEC_SERVICE}$([[ "${CROWDSEC_INSTALL_MANAGER}" == true ]] && echo ", crowdsec-manager"), дополнения к traefik..."
    YQ_ENV=(-e "S=${CROWDSEC_SERVICE}" -e "V=${CS_TRAEFIK_LOG_VOLUME}" -e "NS=${CS_NET_SOURCE}")
    yqd -i ".services[strenv(S)] = load(\"${CS_STAGE_REL}/crowdsec.yml\")" "${sc}" >> "${LOG_FILE}" 2>&1 || return 1
    if [[ "${CROWDSEC_INSTALL_MANAGER}" == true ]]; then
        yqd -i ".services[\"crowdsec-manager\"] = load(\"${CS_STAGE_REL}/manager.yml\")" "${sc}" >> "${LOG_FILE}" 2>&1 || return 1
    fi
    # Те же сети, что у gerbil (если сети заданы явно), — иначе Traefik не найдёт crowdsec
    if [[ -n "${CS_NET_SOURCE}" && "$(yqd '.services[strenv(NS)].networks == null' "${sc}")" == "false" ]]; then
        yqd -i '.services[strenv(S)].networks = .services[strenv(NS)].networks' "${sc}" >> "${LOG_FILE}" 2>&1 || return 1
        if [[ "${CROWDSEC_INSTALL_MANAGER}" == true ]]; then
            yqd -i '.services["crowdsec-manager"].networks = .services[strenv(NS)].networks' "${sc}" >> "${LOG_FILE}" 2>&1 || return 1
        fi
    fi
    if [[ "$(yqd '[.services.traefik.volumes[]? | select(. == strenv(V))] | length' "${sc}")" == "0" ]]; then
        yqd -i '.services.traefik.volumes += [strenv(V)]' "${sc}" >> "${LOG_FILE}" 2>&1 || return 1
    fi
    t=$(yqd '.services.traefik.depends_on | type' "${sc}")
    if [[ "${t}" == "!!seq" ]]; then
        yqd -i '.services.traefik.depends_on += [strenv(S)]' "${sc}" >> "${LOG_FILE}" 2>&1 || return 1
    else
        yqd -i '.services.traefik.depends_on[strenv(S)].condition = "service_healthy"' "${sc}" >> "${LOG_FILE}" 2>&1 || return 1
    fi
    cs_stage_validate || return 1

    # ── traefik_config.yml ──
    log INFO "[Подготовка] traefik_config.yml: плагин bouncer ${CROWDSEC_BOUNCER_VERSION}, access-лог, middleware на entrypoint ${CROWDSEC_ENTRYPOINT}..."
    YQ_ENV=(-e "M=${CROWDSEC_BOUNCER_MODULE}" -e "BV=${CROWDSEC_BOUNCER_VERSION}" -e "EP=${CROWDSEC_ENTRYPOINT}" -e "AL=${CS_ACCESS_LOG}")
    yqd -i '.experimental.plugins.crowdsec.moduleName = strenv(M) | .experimental.plugins.crowdsec.version = strenv(BV)' \
        "${st}" >> "${LOG_FILE}" 2>&1 || return 1
    t=$(yqd '.accessLog.filePath // ""' "${st}")
    if [[ "$(yqd '.accessLog == null' "${st}")" == "true" ]]; then
        yqd -i ".accessLog = load(\"${CS_STAGE_REL}/accesslog.yml\")" "${st}" >> "${LOG_FILE}" 2>&1 || return 1
    elif [[ "${t}" != "${CS_ACCESS_LOG}" ]]; then
        log WARN "[Подготовка] accessLog уже настроен (filePath='${t:-stdout}') — перенаправляю в ${CS_ACCESS_LOG} (JSON) для CrowdSec"
        yqd -i '.accessLog.filePath = strenv(AL) | .accessLog.format = "json"' "${st}" >> "${LOG_FILE}" 2>&1 || return 1
    fi
    if [[ "$(yqd '[.entryPoints[strenv(EP)].http.middlewares[]? | select(. == "crowdsec@file")] | length' "${st}")" == "0" ]]; then
        yqd -i '.entryPoints[strenv(EP)].http.middlewares += ["crowdsec@file"]' "${st}" >> "${LOG_FILE}" 2>&1 || return 1
    fi

    # ── dynamic_config.yml ──
    log INFO "[Подготовка] dynamic_config.yml: middleware crowdsec..."
    YQ_ENV=()
    yqd -i ".http.middlewares.crowdsec = load(\"${CS_STAGE_REL}/middleware.yml\")" "${sd}" >> "${LOG_FILE}" 2>&1 || return 1
    rm -f "${frag}"/crowdsec.yml "${frag}"/manager.yml "${frag}"/accesslog.yml "${frag}"/middleware.yml
    log OK "[Подготовка] Изменения конфигов подготовлены и проверены (стек пока работает без изменений)"
    return 0
}

# ─── Применение установки. Возвращает 0/1 ────────────────────────────────────
crowdsec_install_apply() {
    local cid
    log INFO "[Установка] Каталоги и источники событий CrowdSec..."
    mkdir -p "${PANGOLIN_DIR}/config/crowdsec/db" "${PANGOLIN_DIR}/config/traefik/logs"
    [[ "${CROWDSEC_INSTALL_MANAGER}" == true ]] && \
        mkdir -p "${PANGOLIN_DIR}/crowdsec-manager/data" "${PANGOLIN_DIR}/crowdsec-manager/backups"
    cs_write_acquis
    if [[ -n "${CS_KEY_PATH}" ]]; then
        (umask 077; printf '%s' "${CS_KEY}" > "${PANGOLIN_DIR}/${CS_KEY_REL}")
    fi

    cs_stage_swap_in
    cs_stage_cleanup
    log OK "[Установка] Подготовленные конфиги применены"

    log INFO "[Установка] Запуск CrowdSec (первый старт загружает правила из Hub, до 3 мин)..."
    dc up -d "${CROWDSEC_SERVICE}" >> "${LOG_FILE}" 2>&1 || return 1
    if ! cs_wait_ready; then
        log ERROR "[Установка] CrowdSec не ответил за 3 минуты"
        cid=$(crowdsec_cid); [[ -n "${cid}" ]] && docker logs --tail=30 "${cid}" >> "${LOG_FILE}" 2>&1
        return 1
    fi
    cid=$(crowdsec_cid)
    log OK "[Установка] CrowdSec запущен"
    docker exec "${cid}" cscli bouncers delete "${CROWDSEC_BOUNCER_NAME}" >/dev/null 2>&1 || true
    # вывод не пишем в лог — в нём ключ
    if ! docker exec "${cid}" cscli bouncers add "${CROWDSEC_BOUNCER_NAME}" -k "${CS_KEY}" >/dev/null 2>&1; then
        log ERROR "[Установка] Не удалось зарегистрировать bouncer '${CROWDSEC_BOUNCER_NAME}'"
        return 1
    fi
    log OK "[Установка] Bouncer '${CROWDSEC_BOUNCER_NAME}' зарегистрирован"

    log INFO "[Установка] Запуск стека с новыми настройками Traefik..."
    mark_stack_start
    dc up -d >> "${LOG_FILE}" 2>&1 \
        || log ERROR "[Установка] docker compose up завершился с ошибкой — проверка состояния покажет детали"
    ensure_fresh traefik
    health_check || return 1
    return 0
}

crowdsec_install_rollback() {
    RECOVERY=""
    ROLLBACK_DONE=true
    log WARN "┌──────────────────────────────────────────────────────────┐"
    log WARN "│   ОТКАТ УСТАНОВКИ CROWDSEC: возврат к прежним конфигам   │"
    log WARN "└──────────────────────────────────────────────────────────┘"
    dump_failed_logs
    cs_stage_cleanup
    if ! cs_restore_files; then
        log ERROR "[Откат] Не удалось восстановить конфиги — восстановите из *.bak.${DATE_SUFFIX} или --restore"
        return 1
    fi
    log OK "[Откат] docker-compose.yml, traefik_config.yml, dynamic_config.yml восстановлены"
    rm -f "${PANGOLIN_DIR}/${CS_KEY_REL}"
    mark_stack_start
    dc up -d --remove-orphans >> "${LOG_FILE}" 2>&1 || true
    ensure_fresh traefik
    if health_check; then
        log OK "[Откат] Стек работает как до установки. Данные CrowdSec оставлены в config/crowdsec"
        return 0
    fi
    log ERROR "[Откат] Стек нездоров и после отката — используйте --restore (бэкап сделан перед установкой)"
    return 1
}

# ─── Проверки после установки (не влияют на результат) ───────────────────────
cs_post_checks() {
    local cid last dash code
    cid=$(crowdsec_cid)
    sleep 20
    last=$(docker exec "${cid}" cscli bouncers list -o json 2>/dev/null \
        | jq -r --arg n "${CROWDSEC_BOUNCER_NAME}" '.[]? | select(.name == $n) | .last_pull // empty' 2>/dev/null || true)
    if [[ -n "${last}" && "${last}" != 0001-* ]]; then
        log OK "[Проверка] Traefik получает решения CrowdSec (последний запрос: ${last})"
    else
        log WARN "[Проверка] Bouncer ещё не обращался к CrowdSec — проверьте позже: docker exec ${CROWDSEC_SERVICE} cscli bouncers list"
    fi
    dash=$(dashboard_url)
    if [[ -n "${dash}" ]]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${dash%/}/.env" 2>/dev/null || true)
        if [[ "${code}" == "403" ]]; then
            log OK "[Проверка] AppSec блокирует атаки: тестовый запрос ${dash%/}/.env → 403"
        else
            log WARN "[Проверка] Тестовый запрос ${dash%/}/.env вернул '${code:-нет ответа}' вместо 403."
            log WARN "[Проверка] Проверьте с внешнего адреса: curl -sI ${dash%/}/.env (и docker exec ${CROWDSEC_SERVICE} cscli metrics)"
        fi
    fi
}

# ─── Режим -crowdsec-install ─────────────────────────────────────────────────
crowdsec_install() {
    local f rc_compose rc_traefik fname fdir traefik_tag rc=0
    log INFO "Установка CrowdSec + AppSec$([[ "${CROWDSEC_INSTALL_MANAGER}" == true ]] && echo " + crowdsec-manager") в Pangolin (${PANGOLIN_DIR})"

    # ── 1. Проверки: стек работает, ничего не меняется ──
    for f in "${COMPOSE_FILE}" "${TRAEFIK_CONFIG}" "${TRAEFIK_DYNAMIC_CONFIG}"; do
        [[ -f "${f}" ]] || { log ERROR "Файл не найден: ${f}"; exit "${E_PRECOND}"; }
        [[ "${f}" == "${PANGOLIN_DIR}"/* ]] || { log ERROR "Файл должен находиться внутри ${PANGOLIN_DIR}: ${f}"; exit "${E_PRECOND}"; }
    done
    if stack_uses_postgres; then
        log WARN "Стек на PostgreSQL: перед установкой будет остановлен (горячая копия БД PostgreSQL не поддерживается)"
    fi
    rc_compose=$(rel_path "${COMPOSE_FILE}")
    rc_traefik=$(rel_path "${TRAEFIK_CONFIG}")

    log INFO "Подготовка утилиты yq (${YQ_IMAGE%%@*})..."
    docker pull -q "${YQ_IMAGE}" >> "${LOG_FILE}" 2>&1 || { log ERROR "Не удалось скачать образ ${YQ_IMAGE}"; exit "${E_PRECOND}"; }
    yqd '.services | length' "${rc_compose}" >> "${LOG_FILE}" 2>&1 \
        || { log ERROR "yq не может прочитать ${COMPOSE_FILE} — подробности в ${LOG_FILE}"; exit "${E_PRECOND}"; }
    dc config -q >> "${LOG_FILE}" 2>&1 \
        || { log ERROR "Текущий docker-compose.yml не проходит проверку (docker compose config) — исправьте его до установки"; exit "${E_PRECOND}"; }

    YQ_ENV=(-e "S=${CROWDSEC_SERVICE}")
    if [[ "$(yqd '.services | has(strenv(S))' "${rc_compose}")" == "true" ]]; then
        log INFO "Сервис '${CROWDSEC_SERVICE}' уже есть в docker-compose.yml — CrowdSec установлен."
        log INFO "Переустановка: $(basename "$0") --crowdsec-uninstall, затем --crowdsec-install"
        exit "${E_OK}"
    fi
    [[ "$(yqd '.services | has("traefik")' "${rc_compose}")" == "true" ]] \
        || { log ERROR "В docker-compose.yml нет сервиса traefik"; exit "${E_PRECOND}"; }
    CS_NET_SOURCE=""
    if [[ "$(yqd '.services | has("gerbil")' "${rc_compose}")" == "true" ]]; then
        CS_NET_SOURCE="gerbil"
    elif [[ "$(yqd '.services | has("pangolin")' "${rc_compose}")" == "true" ]]; then
        CS_NET_SOURCE="pangolin"
    fi
    YQ_ENV=(-e "EP=${CROWDSEC_ENTRYPOINT}")
    [[ "$(yqd '.entryPoints | has(strenv(EP))' "${rc_traefik}")" == "true" ]] \
        || { log ERROR "В traefik_config.yml нет entrypoint '${CROWDSEC_ENTRYPOINT}' (параметр CROWDSEC_ENTRYPOINT)"; exit "${E_PRECOND}"; }
    fname=$(yqd '.providers.file.filename // ""' "${rc_traefik}")
    fdir=$(yqd '.providers.file.directory // ""' "${rc_traefik}")
    if [[ -z "${fdir}" && "$(basename "${fname}")" != "$(basename "${TRAEFIK_DYNAMIC_CONFIG}")" ]]; then
        log ERROR "Traefik не читает $(basename "${TRAEFIK_DYNAMIC_CONFIG}") (providers.file.filename='${fname}') — проверьте TRAEFIK_DYNAMIC_CONFIG"
        exit "${E_PRECOND}"
    fi
    if [[ -n "$(yqd '.log.filePath // ""' "${rc_traefik}")" ]]; then
        log WARN "В traefik_config.yml задан log.filePath: ошибки загрузки плагинов не видны в docker logs, и health check их не заметит"
    fi
    YQ_ENV=()
    for f in "${CROWDSEC_SERVICE}" crowdsec-manager; do
        [[ "${f}" == crowdsec-manager && "${CROWDSEC_INSTALL_MANAGER}" != true ]] && continue
        if docker ps -a --format '{{.Names}}' | grep -qx "${f}"; then
            log ERROR "Контейнер с именем '${f}' уже существует вне этого стека — удалите или переименуйте его"; exit "${E_PRECOND}"
        fi
    done
    CS_TRAEFIK_CN=$(compose_container_name traefik)
    CS_PANGOLIN_CN=$(compose_container_name pangolin)
    CS_GERBIL_CN=$(compose_container_name gerbil)
    log OK "Проверки пройдены (traefik: ${CS_TRAEFIK_CN}, сети: как у ${CS_NET_SOURCE:-default})"

    # ── 2. Проба: загрузит ли текущий Traefik плагин bouncer ──
    traefik_tag=$(get_image_tag traefik)
    if [[ -n "${traefik_tag}" ]]; then
        rc=0
        PROBE_EXTRA_PLUGINS="crowdsec ${CROWDSEC_BOUNCER_MODULE} ${CROWDSEC_BOUNCER_VERSION}" \
            probe_badger "${traefik_tag}" "$(get_badger_version)" || rc=$?
        if (( rc == 1 )); then
            log ERROR "Traefik ${traefik_tag} не загружает плагин bouncer ${CROWDSEC_BOUNCER_VERSION} — установка отменена, стек не тронут"
            exit "${E_PRECOND}"
        elif (( rc == 2 )); then
            log ERROR "Проверить загрузку плагина bouncer не удалось — установка отменена, стек не тронут"
            exit "${E_PRECOND}"
        fi
    fi

    # ── 3. Образы заранее ──
    log INFO "Скачивание образов CrowdSec$([[ "${CROWDSEC_INSTALL_MANAGER}" == true ]] && echo " и crowdsec-manager")..."
    docker pull -q "docker.io/crowdsecurity/crowdsec:${CROWDSEC_IMAGE_TAG}" >> "${LOG_FILE}" 2>&1 \
        || { log ERROR "Не удалось скачать crowdsecurity/crowdsec:${CROWDSEC_IMAGE_TAG}"; exit "${E_PRECOND}"; }
    if [[ "${CROWDSEC_INSTALL_MANAGER}" == true ]]; then
        docker pull -q "${CROWDSEC_MANAGER_IMAGE}" >> "${LOG_FILE}" 2>&1 \
            || { log ERROR "Не удалось скачать ${CROWDSEC_MANAGER_IMAGE}"; exit "${E_PRECOND}"; }
    fi
    log OK "Образы готовы"

    # ── 4. Подготовка конфигов на копиях (стек работает) ──
    if ! crowdsec_install_stage; then
        YQ_ENV=()
        cs_stage_cleanup
        log ERROR "Подготовка конфигов не удалась — установка отменена, стек не тронут (подробности в ${LOG_FILE})"
        exit "${E_PRECOND}"
    fi
    check_backup_space || { cs_stage_cleanup; exit "${E_PRECOND}"; }
    http_baseline

    if hot_backup_possible; then
        confirm "Будут применены изменения; Traefik перезапустится (простой — секунды). Продолжить?" \
            || { cs_stage_cleanup; log INFO "Установка отменена"; exit "${E_PRECOND}"; }
    else
        confirm "Стек Pangolin будет остановлен на 1–3 минуты (полный бэкап и установка). Продолжить?" \
            || { cs_stage_cleanup; log INFO "Установка отменена"; exit "${E_PRECOND}"; }
    fi

    # ── 5. Резервные копии ──
    DATE_SUFFIX=$(date +%Y%m%d_%H%M%S)
    make_bak_copies "${COMPOSE_FILE}" "${TRAEFIK_CONFIG}" "${TRAEFIK_DYNAMIC_CONFIG}"
    RECOVERY=start_stack
    if ! backup_before_change; then
        cs_stage_cleanup
        if [[ "${STACK_DOWN}" == true ]]; then RECOVERY=""; recover_start_stack || true; fi
        RECOVERY=""
        exit "${E_FAIL}"
    fi

    # ── 6. Установка с откатом при сбое ──
    RECOVERY=cs_install
    set +e
    crowdsec_install_apply
    rc=$?
    set -e
    if (( rc != 0 )); then
        log ERROR "Установка CrowdSec не удалась — откатываю изменения"
        set +e
        crowdsec_install_rollback
        rc=$?
        set -e
        if (( rc == 0 )); then
            notify ERROR "crowdsec-install-failed" "Установка CrowdSec не удалась, прежние конфиги восстановлены"
            exit "${E_FAIL}"
        fi
        notify ERROR "critical" "Установка CrowdSec не удалась, и стек нездоров после отката — используйте --restore"
        exit "${E_CRIT}"
    fi
    RECOVERY=""

    # ── 7. Завершение ──
    cs_write_logrotate
    cs_post_checks
    log INFO "Allowlist своей инфраструктуры (IP сервера и сайтов Newt)..."
    allowlist_sync || log WARN "[Allowlist] Синхронизация завершилась с ошибками — см. лог"
    install_allowlist_cron
    crowdsec_hub_update || true

    log OK "┌──────────────────────────────────────────────────────────┐"
    log OK "│        CrowdSec + AppSec установлены и работают          │"
    log OK "└──────────────────────────────────────────────────────────┘"
    if [[ "${CROWDSEC_INSTALL_MANAGER}" == true ]]; then
        log INFO "Веб-интерфейс crowdsec-manager — открыть через Pangolin (своей авторизации у него НЕТ):"
        log INFO "  1. Сайты → сайт типа Local (для сервисов на этом же сервере)"
        log INFO "  2. Ресурсы → HTTP-ресурс, напр. crowdsec.<ваш домен>, цель http://crowdsec-manager:8080"
        log INFO "  3. В ресурсе включите аутентификацию и оставьте доступ только администраторам"
    fi
    log INFO "Проверка вручную: docker exec ${CROWDSEC_SERVICE} cscli metrics | cscli decisions list | cscli alerts list"
    log INFO "Удаление: $(basename "$0") --crowdsec-uninstall"
    notify INFO "crowdsec-installed" "CrowdSec + AppSec установлены"
    log_separator
    exit "${E_OK}"
}

# ─── Режим -crowdsec-uninstall ───────────────────────────────────────────────
crowdsec_uninstall_stage() {
    local t sc st sd
    sc=$(cs_stage_compose); st=$(cs_stage_traefik); sd=$(cs_stage_dynamic)
    cs_stage_init
    YQ_ENV=(-e "S=${CROWDSEC_SERVICE}")
    yqd -i 'del(.services[strenv(S)]) | del(.services["crowdsec-manager"])' "${sc}" >> "${LOG_FILE}" 2>&1 || return 1
    # volume с логами у traefik не трогаем: в свежих установках Pangolin он есть изначально
    t=$(yqd '.services.traefik.depends_on | type' "${sc}")
    if [[ "${t}" == "!!seq" ]]; then
        yqd -i 'del(.services.traefik.depends_on[] | select(. == strenv(S)))' "${sc}" >> "${LOG_FILE}" 2>&1 || return 1
    elif [[ "${t}" == "!!map" ]]; then
        yqd -i 'del(.services.traefik.depends_on[strenv(S)])' "${sc}" >> "${LOG_FILE}" 2>&1 || return 1
    fi
    cs_stage_validate || return 1
    YQ_ENV=(-e "AL=${CS_ACCESS_LOG}")
    yqd -i 'del(.experimental.plugins.crowdsec)
            | del(.entryPoints[].http.middlewares[] | select(. == "crowdsec@file"))
            | del(.entryPoints[].http.middlewares | select(length == 0))
            | del(.accessLog | select(.filePath == strenv(AL)))' "${st}" >> "${LOG_FILE}" 2>&1 || return 1
    YQ_ENV=()
    yqd -i 'del(.http.middlewares.crowdsec)' "${sd}" >> "${LOG_FILE}" 2>&1 || return 1
    return 0
}

crowdsec_uninstall_apply() {
    cs_stage_swap_in
    cs_stage_cleanup
    mark_stack_start
    dc up -d --remove-orphans >> "${LOG_FILE}" 2>&1 \
        || log ERROR "docker compose up завершился с ошибкой — проверка состояния покажет детали"
    ensure_fresh traefik
    health_check || return 1
    return 0
}

# Вернуть стек к состоянию «с CrowdSec» после неудачного удаления
crowdsec_uninstall_recover() {
    RECOVERY=""
    ROLLBACK_DONE=true
    log ERROR "Удаление не удалось — возвращаю прежние конфиги"
    cs_stage_cleanup
    cs_restore_files || true
    mark_stack_start
    dc up -d >> "${LOG_FILE}" 2>&1 || true
    ensure_fresh traefik
    if health_check; then
        log OK "Стек работает с CrowdSec, как до попытки удаления"
        return 0
    fi
    log ERROR "Стек нездоров — используйте --restore"
    return 1
}

crowdsec_uninstall() {
    local f rc
    for f in "${COMPOSE_FILE}" "${TRAEFIK_CONFIG}" "${TRAEFIK_DYNAMIC_CONFIG}"; do
        [[ -f "${f}" ]] || { log ERROR "Файл не найден: ${f}"; exit "${E_PRECOND}"; }
    done
    docker pull -q "${YQ_IMAGE}" >> "${LOG_FILE}" 2>&1 || { log ERROR "Не удалось скачать ${YQ_IMAGE}"; exit "${E_PRECOND}"; }
    yqd '.services | length' "$(rel_path "${COMPOSE_FILE}")" >> "${LOG_FILE}" 2>&1 \
        || { log ERROR "yq не может прочитать ${COMPOSE_FILE} — подробности в ${LOG_FILE}"; exit "${E_PRECOND}"; }
    YQ_ENV=(-e "S=${CROWDSEC_SERVICE}")
    if [[ "$(yqd '.services | has(strenv(S))' "$(rel_path "${COMPOSE_FILE}")")" != "true" ]]; then
        YQ_ENV=()
        log INFO "CrowdSec не установлен (нет сервиса '${CROWDSEC_SERVICE}' в docker-compose.yml)"
        exit "${E_OK}"
    fi
    YQ_ENV=()
    if ! crowdsec_uninstall_stage; then
        YQ_ENV=()
        cs_stage_cleanup
        log ERROR "Подготовка конфигов не удалась — стек не тронут (подробности в ${LOG_FILE})"
        exit "${E_PRECOND}"
    fi
    log WARN "CrowdSec, AppSec и crowdsec-manager будут удалены из стека; Traefik вернётся к работе без них."
    log INFO "Данные (config/crowdsec, crowdsec-manager/) остаются на диске."
    confirm "Traefik будет перезапущен. Продолжить?" || { cs_stage_cleanup; log INFO "Отменено"; exit "${E_PRECOND}"; }
    http_baseline

    DATE_SUFFIX=$(date +%Y%m%d_%H%M%S)
    make_bak_copies "${COMPOSE_FILE}" "${TRAEFIK_CONFIG}" "${TRAEFIK_DYNAMIC_CONFIG}"

    RECOVERY=cs_uninstall
    set +e
    crowdsec_uninstall_apply
    rc=$?
    set -e
    if (( rc != 0 )); then
        set +e
        crowdsec_uninstall_recover
        rc=$?
        set -e
        if (( rc == 0 )); then
            notify ERROR "crowdsec-uninstall-failed" "Удаление CrowdSec не удалось, стек возвращён в прежнее состояние"
            exit "${E_FAIL}"
        fi
        notify ERROR "critical" "Удаление CrowdSec не удалось, и стек нездоров — используйте --restore"
        exit "${E_CRIT}"
    fi
    RECOVERY=""

    rm -f "${ALLOWLIST_CRON_FILE}" "${TRAEFIK_LOGROTATE_FILE}" "${PANGOLIN_DIR}/${CS_KEY_REL}"
    log OK "CrowdSec удалён из стека, cron-задача allowlist и ротация access-лога убраны"
    log INFO "Удалить данные окончательно: rm -r ${PANGOLIN_DIR}/config/crowdsec ${PANGOLIN_DIR}/crowdsec-manager"
    log_separator
    exit "${E_OK}"
}

# ─── Пауза обновлений ────────────────────────────────────────────────────────
hold_active() { [[ "${UPDATE_HOLD}" == true || -f "${HOLD_FILE}" ]]; }

do_hold() {
    state_init
    printf '%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${ACTION_ARG:-без причины}" > "${HOLD_FILE}"
    log OK "Обновления приостановлены (${HOLD_FILE}). Правила CrowdSec, allowlist и DNS продолжают обновляться."
    log INFO "Возобновить: $(basename "$0") --unhold"
    exit "${E_OK}"
}

do_unhold() {
    if [[ -f "${HOLD_FILE}" ]]; then
        rm -f "${HOLD_FILE}"
        log OK "Пауза обновлений снята"
    else
        log INFO "Пауза обновлений не была включена"
    fi
    [[ "${UPDATE_HOLD}" == true ]] && log WARN "В конфигурации задано UPDATE_HOLD=true — обновления остаются приостановленными"
    exit "${E_OK}"
}

# ─── Справка ─────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
pangolin-update.sh ${PU_VERSION} — обновление стека Pangolin с проверкой и откатом

Использование: $(basename "$0") [ОПЦИЯ]

Без опций       Полный цикл: проверка версий и, при наличии обновлений,
                обновление стека с health check и автоматическим откатом.

Проверка без изменений:
  --info               Только таблица «текущая -> целевая версия».
  --dry-run            Таблица + diff, который будет применён к docker-compose.yml
                       и traefik_config.yml. Ничего не скачивается и не меняется.

Управление обновлением:
  --enterprise, --ee   Использовать/переключиться на Enterprise Edition.
  --community, --ce    Использовать/вернуться на Community Edition.
  --no-delay           Не ждать MIN_RELEASE_AGE_HOURS после выхода релиза.
  --hold [причина]     Приостановить обновления (CrowdSec/allowlist/DNS работают).
  --unhold             Снять паузу.

Резервные копии:
  --backup             Полная копия: docker-compose.yml + config/ (БД, сертификаты,
                       конфиги) + настройки Cloudflare. По умолчанию без остановки
                       стека (BACKUP_MODE=hot).
  --restore [файл]     Восстановление из архива (без аргумента — самый свежий).
                       Перед восстановлением сохраняется копия текущего состояния.

Cloudflare DNS:
  --cloudflare         Включить: CLOUDFLARE_API_TOKEN=<токен> $(basename "$0") --cloudflare
                       (токен можно передать и аргументом, но он попадёт в историю shell).
  --cloudflare-off     Отключить (созданные записи не удаляются).
  --dns-sync           Разовая синхронизация (её вызывает cron).

CrowdSec:
  --crowdsec-install   Установить CrowdSec + AppSec (WAF) в работающий Pangolin.
  --with-manager       (с --crowdsec-install) добавить веб-интерфейс crowdsec-manager.
  --crowdsec-uninstall Удалить CrowdSec из стека (данные остаются на диске).
  --crowdsec-hub       Только обновить правила CrowdSec из Hub.
  --allowlist-sync     Синхронизировать allowlist (IP сервера и сайтов Newt).
  --allowlist-on       Поставить cron-задачу синхронизации allowlist.
  --allowlist-off      Убрать cron-задачу (сам allowlist сохраняется).

Прочее:
  -y, --yes            Не спрашивать подтверждение.
  --version            Версия скрипта.
  -h, --help           Эта справка.

Однодефисные формы (-info, -backup, ...) по-прежнему принимаются.
Настройки: ${CONFIG_FILE} (путь меняется переменной PANGOLIN_UPDATE_CONF).

Коды выхода: 0 — успех; 1 — операция не удалась, прежнее состояние восстановлено;
2 — восстановить не удалось, нужно ручное вмешательство; 3 — CrowdSec не отвечает;
4 — ничего не изменено (аргументы, окружение, сеть, проверки до изменений).
EOF
}

# ─── Разбор аргументов ───────────────────────────────────────────────────────
set_action() {
    if [[ -n "${ACTION}" && "${ACTION}" != "$1" ]]; then
        echo "Нельзя совмещать --${ACTION//_/-} и --${1//_/-}" >&2
        exit "${E_PRECOND}"
    fi
    ACTION="$1"
}

parse_args() {
    local opt
    while [[ $# -gt 0 ]]; do
        opt="$1"
        [[ "${opt}" == --* ]] || opt="-${opt}"       # -info → --info
        case "${opt}" in
            --info)                       INFO_ONLY=true ;;
            --dry-run)                    DRY_RUN=true ;;
            --no-delay)                   NO_DELAY=true ;;
            --enterprise|--ee)            EDITION_FLAG="ee" ;;
            --community|--ce)             EDITION_FLAG="ce" ;;
            --backup)                     set_action backup ;;
            --restore)
                set_action restore
                if [[ $# -gt 1 && "${2}" != -* ]]; then ACTION_ARG="$2"; shift; fi ;;
            --cloudflare|--cf)
                set_action cf_on
                if [[ $# -gt 1 && "${2}" != -* ]]; then CF_TOKEN="$2"; shift; fi ;;
            --cloudflare-off|--cf-off)    set_action cf_off ;;
            --dns-sync)                   set_action dns_sync ;;
            --crowdsec-hub)               set_action crowdsec_hub ;;
            --allowlist-sync)             set_action allowlist_sync ;;
            --allowlist-on)               set_action allowlist_on ;;
            --allowlist-off)              set_action allowlist_off ;;
            --crowdsec-install)           set_action crowdsec_install ;;
            --crowdsec-uninstall)         set_action crowdsec_uninstall ;;
            --with-manager)               MANAGER_FLAG=true ;;
            --no-manager)                 MANAGER_FLAG=false ;;
            --hold)
                set_action hold
                if [[ $# -gt 1 && "${2}" != -* ]]; then ACTION_ARG="$2"; shift; fi ;;
            --unhold)                     set_action unhold ;;
            --yes|--y)                    ASSUME_YES=true ;;
            --version)                    echo "pangolin-update.sh ${PU_VERSION}"; exit "${E_OK}" ;;
            --help|--h)                   usage; exit "${E_OK}" ;;
            *) echo "Неизвестный аргумент: $1" >&2; usage >&2; exit "${E_PRECOND}" ;;
        esac
        shift
    done

    # Несовместимые сочетания: «проверка без изменений» с действием — ошибка,
    # а не молчаливое выполнение действия
    if [[ "${INFO_ONLY}" == true && "${DRY_RUN}" == true ]]; then
        echo "Укажите что-то одно: --info или --dry-run" >&2; exit "${E_PRECOND}"
    fi
    if [[ ( "${INFO_ONLY}" == true || "${DRY_RUN}" == true ) && -n "${ACTION}" ]]; then
        echo "--info/--dry-run нельзя совмещать с --${ACTION//_/-}" >&2; exit "${E_PRECOND}"
    fi
    if [[ -n "${EDITION_FLAG}" && -n "${ACTION}" ]]; then
        echo "Флаг редакции (--ee/--ce) действует только при обновлении, не с --${ACTION//_/-}" >&2; exit "${E_PRECOND}"
    fi
    if [[ -n "${MANAGER_FLAG}" ]]; then
        if [[ "${ACTION}" != crowdsec_install ]]; then
            echo "--with-manager/--no-manager используются только с --crowdsec-install" >&2; exit "${E_PRECOND}"
        fi
        CROWDSEC_INSTALL_MANAGER="${MANAGER_FLAG}"
    fi
    if [[ "${NO_DELAY}" == true && -n "${ACTION}" ]]; then
        echo "--no-delay действует только при обновлении" >&2; exit "${E_PRECOND}"
    fi
}

# ─── Определение целевых версий ──────────────────────────────────────────────
resolve_targets() {
    local line cand pub cur_num target_num

    # Редакция: по тегу образа (ee-* = Enterprise); явный флаг важнее
    local current_edition="ce"
    [[ -n "${PANGOLIN_TAG_EE}" ]] && current_edition="ee"
    case "${EDITION_FLAG}" in
        ee) ENTERPRISE=true ;;
        ce) ENTERPRISE=false ;;
        *)  [[ "${current_edition}" == ee ]] && ENTERPRISE=true || ENTERPRISE=false ;;
    esac
    log INFO "Редакция Pangolin: $([[ ${ENTERPRISE} == true ]] && echo Enterprise || echo Community)$([[ -n ${PANGOLIN_TAG_DB} ]] && echo ', сборка PostgreSQL')"
    if [[ "${ENTERPRISE}" == true && "${current_edition}" == ce ]] || [[ "${ENTERPRISE}" == false && "${current_edition}" == ee ]]; then
        EDITION_SWITCH=true
        log WARN "Смена редакции Pangolin: $([[ ${current_edition} == ee ]] && echo Enterprise || echo Community) -> $([[ ${ENTERPRISE} == true ]] && echo Enterprise || echo Community)"
    fi

    log INFO "Запрос актуальных версий..."
    # Pangolin: сравниваются номера версий, тег строится с учётом редакции и сборки
    line=$(gh_latest_release fosrl/pangolin) || exit "${E_PRECOND}"
    cand="${line%%$'\t'*}"; pub="${line#*$'\t'}"
    cur_num="${PANGOLIN_TAG_VER}"
    target_num=$(choose_target Pangolin "${cur_num}" "${cand}" "${pub}")
    PANGOLIN_V=$(pangolin_image_tag "${target_num}")
    if [[ "${PANGOLIN_V}" != "${OLD_PANGOLIN_V}" ]] && ! image_tag_exists "docker.io/fosrl/pangolin:${PANGOLIN_V}"; then
        if [[ "${target_num}" != "${cur_num}" ]]; then
            log INFO "Pangolin: образ fosrl/pangolin:${PANGOLIN_V} ещё не опубликован — оставляю текущую версию"
            PANGOLIN_V=$(pangolin_image_tag "${cur_num}")
        fi
        if [[ "${PANGOLIN_V}" != "${OLD_PANGOLIN_V}" ]] && ! image_tag_exists "docker.io/fosrl/pangolin:${PANGOLIN_V}"; then
            log ERROR "Образ fosrl/pangolin:${PANGOLIN_V} не найден в Docker Hub — смена редакции невозможна"
            exit "${E_PRECOND}"
        fi
    fi

    line=$(gh_latest_release fosrl/gerbil) || exit "${E_PRECOND}"
    GERBIL_V=$(choose_target Gerbil "${OLD_GERBIL_V}" "${line%%$'\t'*}" "${line#*$'\t'}")
    if [[ "${GERBIL_V}" != "${OLD_GERBIL_V}" ]] && ! image_tag_exists "docker.io/fosrl/gerbil:${GERBIL_V}"; then
        log INFO "Gerbil: образ ${GERBIL_V} ещё не опубликован — оставляю ${OLD_GERBIL_V}"
        GERBIL_V="${OLD_GERBIL_V}"
    fi

    line=$(get_traefik_latest "$(version_major "${OLD_TRAEFIK_V}")") || exit "${E_PRECOND}"
    TRAEFIK_V=$(choose_target Traefik "${OLD_TRAEFIK_V}" "${line%%$'\t'*}" "${line#*$'\t'}")
    if [[ "${TRAEFIK_V}" != "${OLD_TRAEFIK_V}" ]] && ! image_tag_exists "docker.io/traefik:${TRAEFIK_V}"; then
        log INFO "Traefik: образ ${TRAEFIK_V} ещё не опубликован — оставляю ${OLD_TRAEFIK_V}"
        TRAEFIK_V="${OLD_TRAEFIK_V}"
    fi

    if [[ -n "${BADGER_PIN}" ]]; then
        BADGER_V="${BADGER_PIN}"
        log INFO "Badger закреплён на ${BADGER_PIN} (BADGER_PIN)"
    else
        line=$(gh_latest_release fosrl/badger) || exit "${E_PRECOND}"
        BADGER_V=$(choose_target Badger "${OLD_BADGER_V}" "${line%%$'\t'*}" "${line#*$'\t'}")
    fi

    CROWDSEC_V="${OLD_CROWDSEC_V}"
    if [[ -n "${OLD_CROWDSEC_V}" && "${CROWDSEC_AUTO_UPDATE}" == true ]]; then
        CROWDSEC_V=$(resolve_crowdsec_target "${OLD_CROWDSEC_V}")
    fi
}

# Проба Traefik + Badger: проблемный компонент остаётся на прежней версии
run_probe() {
    [[ "${BADGER_PROBE}" == true ]] || return 0
    [[ "${OLD_BADGER_V}" != "${BADGER_V}" || "${OLD_TRAEFIK_V}" != "${TRAEFIK_V}" ]] || return 0
    local rc=0 rc2=0
    probe_badger "${TRAEFIK_V}" "${BADGER_V}" || rc=$?
    (( rc == 0 )) && return 0
    if (( rc == 2 )); then
        log WARN "Совместимость Traefik ${TRAEFIK_V} + Badger ${BADGER_V} проверить не удалось — оба остаются на текущих версиях"
        [[ "${OLD_BADGER_V}" != "${BADGER_V}" ]] && BADGER_HELD_BACK=true
        [[ "${OLD_TRAEFIK_V}" != "${TRAEFIK_V}" ]] && TRAEFIK_HELD_BACK=true
        BADGER_V="${OLD_BADGER_V}"; TRAEFIK_V="${OLD_TRAEFIK_V}"
    elif [[ "${OLD_BADGER_V}" != "${BADGER_V}" ]]; then
        log WARN "Badger ${BADGER_V} не загружается — Badger остаётся на ${OLD_BADGER_V}"
        notify_once "badger-held-${BADGER_V}" WARN "badger-held-back" "Badger ${BADGER_V} не загружается в Traefik ${TRAEFIK_V} — оставлен ${OLD_BADGER_V}"
        BADGER_V="${OLD_BADGER_V}"
        BADGER_HELD_BACK=true
        if [[ "${OLD_TRAEFIK_V}" != "${TRAEFIK_V}" ]]; then
            probe_badger "${TRAEFIK_V}" "${BADGER_V}" || rc2=$?
            if (( rc2 != 0 )); then
                log WARN "Traefik ${TRAEFIK_V} не прошёл проверку и с Badger ${BADGER_V} — Traefik остаётся на ${OLD_TRAEFIK_V}"
                TRAEFIK_V="${OLD_TRAEFIK_V}"; TRAEFIK_HELD_BACK=true
            fi
        fi
    else
        log WARN "Traefik ${TRAEFIK_V} не загружает Badger ${BADGER_V} — Traefik остаётся на ${OLD_TRAEFIK_V}"
        notify_once "traefik-held-${TRAEFIK_V}" WARN "traefik-held-back" "Traefik ${TRAEFIK_V} не загружает плагины — оставлен ${OLD_TRAEFIK_V}"
        TRAEFIK_V="${OLD_TRAEFIK_V}"; TRAEFIK_HELD_BACK=true
    fi
    log INFO "Скорректированный план обновления:"
    print_versions
}

# Режим --dry-run: показать изменения файлов, ничего не меняя
show_dry_run_diff() {
    local tc tt
    tc=$(mktemp); tt=$(mktemp)
    cp "${COMPOSE_FILE}" "${tc}"; cp "${TRAEFIK_CONFIG}" "${tt}"
    apply_plan_to_files "${tc}" "${tt}" >/dev/null 2>&1 || true
    log INFO "Изменения, которые будут внесены:"
    diff -u --label "a/$(rel_path "${COMPOSE_FILE}")" --label "b/$(rel_path "${COMPOSE_FILE}")" "${COMPOSE_FILE}" "${tc}" || true
    diff -u --label "a/$(rel_path "${TRAEFIK_CONFIG}")" --label "b/$(rel_path "${TRAEFIK_CONFIG}")" "${TRAEFIK_CONFIG}" "${tt}" || true
    rm -f "${tc}" "${tt}"
    if [[ "${BADGER_PROBE}" == true ]] && [[ "${OLD_BADGER_V}" != "${BADGER_V}" || "${OLD_TRAEFIK_V}" != "${TRAEFIK_V}" ]]; then
        log INFO "При обновлении совместимость Traefik ${TRAEFIK_V} + Badger ${BADGER_V} будет проверена тестовым контейнером."
    fi
    log INFO "Образы будут скачаны до остановки стека: $(planned_images | tr '\n' ' ')"
    log INFO "Резервная копия: $(hot_backup_possible && echo 'горячая (без остановки)' || echo 'холодная (стек останавливается)')"
}

# ─── Основной цикл обновления ────────────────────────────────────────────────
run_update() {
    log INFO "Чтение текущих версий из конфигурации..."
    read_current_versions
    resolve_targets

    log INFO "Сравнение версий:"
    print_versions

    if nothing_to_update; then
        log INFO "Все компоненты актуальны, обновление не требуется."
        if [[ "${INFO_ONLY}" == false && "${DRY_RUN}" == false ]]; then
            post_run_crowdsec || exit "${E_CROWDSEC}"
        fi
        exit "${E_OK}"
    fi
    if [[ "${INFO_ONLY}" == true ]]; then
        log INFO "Доступно обновление. Режим --info: действия не выполняются."
        exit "${E_OK}"
    fi
    if [[ "${DRY_RUN}" == true ]]; then
        show_dry_run_diff
        exit "${E_OK}"
    fi
    if hold_active; then
        log WARN "Обновления приостановлены ($( [[ -f ${HOLD_FILE} ]] && cut -f2 "${HOLD_FILE}" || echo UPDATE_HOLD=true )). Снять: $(basename "$0") --unhold"
        post_run_crowdsec || exit "${E_CROWDSEC}"
        exit "${E_OK}"
    fi

    # ── Всё, что может сорваться, — до каких-либо изменений ──
    run_probe
    if nothing_to_update; then
        log INFO "После пробы обновлять нечего — стек не трогаю. Повторная попытка при следующем запуске."
        post_run_crowdsec || exit "${E_CROWDSEC}"
        exit "${E_OK}"
    fi

    local img
    log INFO "Скачивание новых образов (стек продолжает работать)..."
    while IFS= read -r img; do
        [[ -z "${img}" ]] && continue
        if ! docker pull -q "${img}" >> "${LOG_FILE}" 2>&1; then
            log ERROR "Не удалось скачать ${img} — обновление отменено, стек не тронут"
            exit "${E_PRECOND}"
        fi
    done < <(planned_images)
    log OK "Образы скачаны"

    check_backup_space || exit "${E_PRECOND}"
    http_baseline

    # ── Изменения ──
    DATE_SUFFIX=$(date +%Y%m%d_%H%M%S)
    log INFO "Создание резервных копий конфигураций..."
    make_bak_copies "${COMPOSE_FILE}" "${TRAEFIK_CONFIG}"

    RECOVERY=start_stack
    if ! backup_before_change; then
        RECOVERY=""
        if [[ "${STACK_DOWN}" == true ]]; then recover_start_stack || exit "${E_CRIT}"; fi
        exit "${E_FAIL}"
    fi
    [[ "${OLD_PANGOLIN_V}" != "${PANGOLIN_V}" ]] && ROLLBACK_DB=true
    RECOVERY=rollback

    log INFO "Обновление версий в конфигурационных файлах..."
    apply_plan_to_files "${COMPOSE_FILE}" "${TRAEFIK_CONFIG}"
    log OK "Файлы конфигурации обновлены"

    log INFO "Запуск стека на новых версиях..."
    mark_stack_start
    if dc up -d >> "${LOG_FILE}" 2>&1; then
        log OK "Стек запущен, начинаем проверку работоспособности..."
    else
        # Например, сервис с depends_on: service_healthy не дождался зависимости.
        # Health check увидит незапущенные контейнеры и запустит откат.
        log ERROR "docker compose up завершился с ошибкой — проверка состояния решит, нужен ли откат"
    fi
    # Сменилась только версия Badger — compose не пересоздаст Traefik сам
    [[ "${OLD_BADGER_V}" != "${BADGER_V}" ]] && ensure_fresh traefik

    local hc file_badger
    set +e
    health_check
    hc=$?

    # Миграция Pangolin при первом запуске может сама переписать версию Badger
    # в traefik_config.yml. Traefik применит её только при следующем
    # перезапуске — проверяем это сейчас, под контролем скрипта.
    file_badger=$(get_badger_version)
    if (( hc == 0 )) && [[ -n "${file_badger}" && "${file_badger}" != "${BADGER_V}" ]]; then
        log WARN "Версия Badger в traefik_config.yml изменена после запуска (вероятно, миграцией Pangolin): ${BADGER_V} -> ${file_badger}"
        log WARN "Перезапускаю Traefik, чтобы проверить новую версию сейчас, а не при случайном рестарте"
        mark_stack_start
        dc restart traefik >> "${LOG_FILE}" 2>&1
        health_check
        hc=$?
        (( hc == 0 )) && BADGER_V="${file_badger}"
    fi

    # Сломался только плагин — откатываем только Badger
    if (( hc == 3 )); then
        file_badger=$(get_badger_version)
        if [[ -n "${file_badger}" && "${file_badger}" != "${OLD_BADGER_V}" ]]; then
            badger_rollback "${file_badger}"
            hc=$?
        fi
    fi
    set -e

    if (( hc != 0 )); then
        log ERROR "Новые версии не прошли проверку работоспособности — запускаем откат"
        RECOVERY=""
        set +e
        do_rollback
        local rb=$?
        set -e
        if (( rb != 0 )); then
            log ERROR "КРИТИЧНО: откат завершился с ошибкой. Стек может быть нестабилен."
            log ERROR "Резервные копии конфигураций: *.bak.${DATE_SUFFIX}; полный архив: ${LAST_ARCHIVE:-нет}"
            notify ERROR "critical" "Обновление ($(changes_summary)) не прошло проверку, и откат тоже не удался — нужно ручное вмешательство. Архив: ${LAST_ARCHIVE:-нет}"
            exit "${E_CRIT}"
        fi
        notify ERROR "rollback" "Обновление ($(changes_summary)) не прошло проверку — стек возвращён на прежние версии"
        exit "${E_FAIL}"
    fi
    RECOVERY=""

    cleanup_images
    log OK "Обновление успешно завершено: $(changes_summary)"
    notify INFO "update-ok" "Обновлено: $(changes_summary)"

    if [[ "${TRAEFIK_HELD_BACK}" == true ]]; then
        log WARN "Traefik оставлен на ${TRAEFIK_V}: новая версия не прошла проверку плагинов. Повторная попытка — при следующем запуске."
    fi
    if [[ "${BADGER_HELD_BACK}" == true ]]; then
        log WARN "Badger оставлен на ${BADGER_V}: новая версия не прошла проверку."
        log WARN "Скрипт попробует снова при следующем запуске. Закрепить версию: BADGER_PIN=\"${BADGER_V}\""
    fi
    if [[ "${EDITION_SWITCH}" == true && "${ENTERPRISE}" == true ]]; then
        log INFO "Переключено на Enterprise Edition. Активируйте лицензионный ключ"
        log INFO "в панели Server Admin: /admin/license (без ключа EE-функции останутся выключенными)."
    fi

    local hub=0
    post_run_crowdsec || hub=$?
    log_separator
    (( hub != 0 )) && exit "${E_CROWDSEC}"
    exit "${E_OK}"
}

# ════════════════════════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════════════════════════
main() {
    parse_args "$@"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    if [[ "${INFO_ONLY}" == true ]]; then RUN_MODE=info
    elif [[ "${DRY_RUN}" == true ]]; then RUN_MODE=dry_run
    elif [[ -n "${ACTION}" ]]; then RUN_MODE="${ACTION}"
    else RUN_MODE=update; fi

    init_log_file
    state_init
    case "${RUN_MODE}" in
        info|dry_run)
            log_separator
            log INFO "Проверка версий Pangolin-стека (режим --${RUN_MODE//_/-}, изменения не вносятся)" ;;
        dns_sync|allowlist_sync)
            rotate_log ;;   # частый тихий запуск из cron: без разделителя
        update)
            rotate_log; log_separator
            log INFO "Запуск проверки обновлений Pangolin-стека (pangolin-update ${PU_VERSION})" ;;
        *)
            rotate_log; log_separator ;;
    esac

    check_deps

    # Lock — для всего, что меняет стек или его окружение. --info и --dry-run
    # только читают. Cron-синхронизации при занятом lock тихо пропускаются.
    case "${RUN_MODE}" in
        info|dry_run) ;;
        dns_sync|allowlist_sync) acquire_lock quiet ;;
        *) acquire_lock wait ;;
    esac

    # При restore compose-файл может отсутствовать (разрушенная установка)
    if [[ ! -f "${COMPOSE_FILE}" && "${ACTION}" != restore && "${ACTION}" != hold && "${ACTION}" != unhold ]]; then
        log ERROR "Файл не найден: ${COMPOSE_FILE}"
        exit "${E_PRECOND}"
    fi
    # Тег Pangolin нужен для определения PostgreSQL-сборки и в сервисных режимах
    parse_pangolin_tag "$(get_image_tag fosrl/pangolin)" || true

    if [[ -n "${ACTION}" ]]; then
        case "${ACTION}" in
            backup)             do_backup ;;
            restore)            do_restore "${ACTION_ARG}" ;;
            cf_on)              cf_enable "${CF_TOKEN}" ;;
            cf_off)             cf_disable ;;
            dns_sync)           do_dns_sync ;;
            crowdsec_hub)
                if [[ -z "$(crowdsec_cid)" ]]; then
                    log ERROR "Сервис '${CROWDSEC_SERVICE}' не найден в стеке или не запущен"
                    exit "${E_PRECOND}"
                fi
                CROWDSEC_HUB_UPDATE=true
                if crowdsec_hub_update; then log_separator; exit "${E_OK}"; fi
                exit "${E_CROWDSEC}" ;;
            allowlist_sync)     do_allowlist_sync ;;
            allowlist_on)       allowlist_enable ;;
            allowlist_off)      allowlist_disable ;;
            crowdsec_install)   crowdsec_install ;;
            crowdsec_uninstall) crowdsec_uninstall ;;
            hold)               do_hold ;;
            unhold)             do_unhold ;;
        esac
        exit "${E_OK}"
    fi

    run_update
}

# Скрипт можно подключить через source (для тестов) — тогда main не запускается
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
