#!/bin/bash
# ver. 0.9 (27.10.2026)
# Pangolin stack auto-updater with logging, health checks and rollback
# 0.3.1: версия Traefik берётся с GitHub Releases (как остальные компоненты),
#        с защитой от перехода на чужую мажорную ветку
# 0.3.2: флаг -info — только сравнение версий (dry-run), без действий
# 0.3.3: флаги -enterprise/-community — переключение редакции Pangolin (CE/EE);
#        текущая редакция определяется автоматически по тегу образа
# 0.3.4: чтение и запись версии badger теперь работают и без кавычек в YAML
# 0.4:   -backup/-restore — полное резервное копирование (конфиги+БД+сертификаты)
#        и восстановление из архива; автоматический полный бэкап перед обновлением
# 0.5:   интеграция с Cloudflare: -cloudflare включает автоматическое создание
#        DNS-записей в Cloudflare для новых поддоменов (ресурсов) Pangolin —
#        синхронизация -dns-sync по cron; -cloudflare-off отключает интеграцию
# 0.6:   защита от «тихого» отказа плагина Badger (Traefik жив, но плагин
#        отключён — все ресурсы недоступны):
#        - проба новой пары Traefik+Badger в одноразовом контейнере ДО обновления;
#          не прошедший пробу компонент не обновляется, остальные — обновляются;
#        - health check читает логи Traefik на ошибки загрузки плагинов;
#        - частичный откат только версии Badger (без отката всего стека);
#        - контроль версии Badger, которую меняет миграция Pangolin при старте;
#        - BADGER_PIN — закрепление версии Badger;
#        - чтение/запись версии только внутри блока badger: (раньше sed менял
#          любую строку version: в traefik_config.yml)
# 0.7:   поддержка CrowdSec (+ AppSec) и crowdsec-manager в стеке:
#        - версия образа CrowdSec учитывается и обновляется как остальные
#          компоненты (если сервис crowdsec есть в compose; только в своей
#          мажорной ветке и только если тег уже опубликован в реестре);
#        - обновление правил CrowdSec Hub (сценарии, виртуальные патчи AppSec)
#          при каждом запуске + режим -crowdsec-hub;
#        - проба Traefik загружает ВСЕ плагины из traefik_config.yml (Badger и
#          bouncer CrowdSec), а не только Badger;
#        - HEALTH_IGNORE_SERVICES: второстепенные сервисы (crowdsec-manager)
#          не вызывают откат всего стека;
#        - логи Traefik (access.log растёт) не попадают в полный бэкап
# 0.8:   автоматический allowlist CrowdSec для своей инфраструктуры:
#        - публичные IP сервера (внешний IPv4/IPv6 + глобальные адреса интерфейсов);
#        - публичные IP сайтов Newt — из БД Pangolin (sites.endpoint: адрес, с
#          которого Newt пробивает туннель к Gerbil), только активные сайты;
#        - устаревшие автоматические записи удаляются (сменился IP у провайдера);
#          записи, добавленные вручную, не трогаются;
#        - -allowlist-sync (разово) / -allowlist-on (cron) / -allowlist-off
# 0.9:   -crowdsec-install — установка CrowdSec + AppSec + crowdsec-manager в уже
#        работающий Pangolin одной командой: проверки и проба плагина до простоя,
#        полный бэкап, правка YAML через yq в контейнере (комментарии сохраняются),
#        регистрация bouncer, health check с автоматическим откатом, logrotate,
#        allowlist + cron; -crowdsec-uninstall — обратная операция; -y

set -euo pipefail

# ─── Конфигурация ────────────────────────────────────────────────────────────
PANGOLIN_DIR="/root/pangolin"
COMPOSE_FILE="${PANGOLIN_DIR}/docker-compose.yml"
TRAEFIK_CONFIG="${PANGOLIN_DIR}/config/traefik/traefik_config.yml"
LOG_FILE="/var/log/pangolin-update.log"
LOCK_FILE="/tmp/pangolin-update.lock"
LOG_MAX_LINES=1000      # ротация лога при превышении

HEALTH_INITIAL_WAIT=20  # пауза после запуска перед первой проверкой (сек)
HEALTH_INTERVAL=10      # интервал между повторными проверками (сек)
HEALTH_RETRIES=6        # количество попыток проверки
RESTART_THRESHOLD=3     # порог количества перезапусков контейнера (аномалия)

BACKUP_DIR="/root/pangolin-backups"  # каталог полных резервных копий (tar.gz)
BACKUP_KEEP=7                        # сколько последних архивов хранить

CF_ENV_FILE="${PANGOLIN_DIR}/.cf-dns.env"    # настройки интеграции с Cloudflare (токен, IP)
CF_CRON_FILE="/etc/cron.d/pangolin-cf-dns"   # cron-задача автосинхронизации DNS
CF_SYNC_INTERVAL=5                           # период синхронизации DNS-записей (минуты)
CF_API="https://api.cloudflare.com/client/v4"

BADGER_MODULE="github.com/fosrl/badger"
BADGER_PIN=""           # закрепить версию Badger (напр. "v1.7.0"); пусто = следовать за релизами
BADGER_PROBE=true       # проверять новую пару Traefik+Badger в тестовом контейнере до обновления
BADGER_PROBE_WAIT=30    # сколько секунд тестовый Traefik ждёт ошибку загрузки плагина

# Сообщения Traefik, означающие, что плагины не загрузились
TRAEFIK_PLUGIN_ERR_RE='Plugins are disabled|unable to set up plugins|unable to download plugin|invalid hash|failed to (get|download|load|check) plugin|middleware "[^"]*(badger|crowdsec)[^"]*" does not exist'

# CrowdSec (необязательный компонент: всё ниже работает, только если сервис
# crowdsec есть в docker-compose.yml)
CROWDSEC_SERVICE="crowdsec"         # имя сервиса CrowdSec в compose
CROWDSEC_AUTO_UPDATE=true           # обновлять образ CrowdSec вместе со стеком
CROWDSEC_HUB_UPDATE=true            # обновлять правила Hub при каждом запуске
LOGS_EXCLUDE="config/traefik/logs"  # не включать в полный бэкап (растущие логи)

# Allowlist CrowdSec для своей инфраструктуры (сервер + сайты Newt)
ALLOWLIST_SYNC=true                          # синхронизировать при обычном запуске
ALLOWLIST_NAME="pangolin-infra"              # имя allowlist в CrowdSec
ALLOWLIST_EXTRA=""                           # доп. адреса/подсети через пробел (дом, офис, VPN)
ALLOWLIST_NEWT_MAX_AGE_DAYS=7                # сайт Newt без связи дольше — его IP убирается
ALLOWLIST_CRON_FILE="/etc/cron.d/pangolin-allowlist"
ALLOWLIST_SYNC_INTERVAL=10                   # период cron-синхронизации (минуты)
PANGOLIN_DB="${PANGOLIN_DIR}/config/db/db.sqlite"

# Установка CrowdSec в работающий Pangolin (-crowdsec-install)
CROWDSEC_IMAGE_TAG="v1.8.1"                              # тег образа crowdsecurity/crowdsec
CROWDSEC_BOUNCER_MODULE="github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin"
CROWDSEC_BOUNCER_VERSION="v1.8.1"                        # версия плагина-bouncer для Traefik
CROWDSEC_INSTALL_MANAGER=true                            # ставить веб-интерфейс crowdsec-manager
CROWDSEC_MANAGER_IMAGE="docker.io/hhftechnology/crowdsec-manager:2.4.1"
CROWDSEC_ENTRYPOINT="websecure"                          # entrypoint Traefik, к которому цепляется защита
CROWDSEC_BOUNCER_NAME="traefik-bouncer"
TRAEFIK_DYNAMIC_CONFIG="${PANGOLIN_DIR}/config/traefik/dynamic_config.yml"
TRAEFIK_LOGROTATE_FILE="/etc/logrotate.d/pangolin-traefik"
YQ_IMAGE="docker.io/mikefarah/yq:4.53.6"                  # правка YAML в контейнере (комментарии сохраняются)
ASSUME_YES=false                                         # -y: не спрашивать подтверждение

# Сервисы, сбой которых не должен откатывать весь стек (через пробел).
# Их состояние выводится в лог, но на результат health check не влияет.
HEALTH_IGNORE_SERVICES="crowdsec-manager"

# Глобальные переменные (заполняются в процессе работы)
DATE_SUFFIX=""
ROLLBACK_DONE=false
INFO_ONLY=false         # режим -info: только сравнение версий, без действий
LOCK_HELD=false         # этот процесс владеет lock-файлом (для корректной очистки)
EDITION_FLAG=""         # "" = авто (по образу), "ee" = форсировать Enterprise, "ce" = Community
ENTERPRISE=false        # итоговая целевая редакция (вычисляется в MAIN)
EDITION_SWITCH=false    # true, если редакция меняется относительно текущей
ACTION=""               # сервисное действие: backup | restore | cf_on | cf_off
RESTORE_FILE=""         # путь к архиву для -restore (пусто = последний)
CF_TOKEN=""             # API-токен Cloudflare, переданный аргументом -cloudflare
STACK_STARTED_AT=""     # момент (UTC, RFC3339) запуска стека/Traefik — для чтения свежих логов
BADGER_HELD_BACK=false  # true, если новую версию Badger пришлось оставить на прежней
OLD_CROWDSEC_V=""       # текущий тег образа CrowdSec ("" = CrowdSec в стеке нет)
CROWDSEC_V=""           # целевой тег образа CrowdSec
CS_NET_SOURCE=""        # сервис, чьи сети копируются для crowdsec (установка)
CS_TRAEFIK_CN=""        # имена контейнеров для crowdsec-manager (установка)
CS_PANGOLIN_CN=""
CS_GERBIL_CN=""

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
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local line="[${timestamp}] [${level}] ${message}"

    echo "${line}" >> "${LOG_FILE}"

    case "${level}" in
        INFO)  echo -e "${C_CYAN}${line}${C_RESET}" ;;
        OK)    echo -e "${C_GREEN}${line}${C_RESET}" ;;
        WARN)  echo -e "${C_YELLOW}${line}${C_RESET}" ;;
        ERROR) echo -e "${C_RED}${line}${C_RESET}" >&2 ;;
        *)     echo "${line}" ;;
    esac
}

log_separator() {
    local sep
    sep=$(printf '─%.0s' {1..60})
    echo "${sep}" >> "${LOG_FILE}"
    echo -e "${C_BOLD}${sep}${C_RESET}"
}

rotate_log() {
    if [[ -f "${LOG_FILE}" ]]; then
        local lines
        lines=$(wc -l < "${LOG_FILE}")
        if (( lines > LOG_MAX_LINES )); then
            local backup="${LOG_FILE}.$(date +%Y%m%d)"
            mv "${LOG_FILE}" "${backup}"
            log INFO "Лог ротирован: ${backup}"
        fi
    fi
}

# ─── Очистка при выходе ───────────────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    [[ "${LOCK_HELD}" == true ]] && rm -f "${LOCK_FILE}"
    if (( exit_code != 0 )) && [[ "${ROLLBACK_DONE}" == false ]]; then
        log ERROR "Скрипт завершился с ошибкой (код: ${exit_code})"
    fi
}
trap cleanup EXIT

# ─── Проверка зависимостей ────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in curl jq docker sed awk tar; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done
    if (( ${#missing[@]} > 0 )); then
        log ERROR "Отсутствуют зависимости: ${missing[*]}"
        exit 1
    fi
}

# ─── Защита от параллельного запуска ─────────────────────────────────────────
acquire_lock() {
    if [[ -f "${LOCK_FILE}" ]]; then
        local pid
        pid=$(cat "${LOCK_FILE}")
        if kill -0 "${pid}" 2>/dev/null; then
            log ERROR "Скрипт уже запущен (PID: ${pid})"
            exit 1
        else
            log WARN "Найден устаревший lock-файл, удаляю..."
            rm -f "${LOCK_FILE}"
        fi
    fi
    echo $$ > "${LOCK_FILE}"
    LOCK_HELD=true
}

# ─── Получение версии из GitHub Releases ─────────────────────────────────────
get_github_latest() {
    local repo="$1"
    local version
    version=$(curl -sf --max-time 10 \
        "https://api.github.com/repos/${repo}/releases/latest" \
        | jq -r '.tag_name // empty')
    if [[ -z "${version}" ]]; then
        log ERROR "Не удалось получить версию для репозитория: ${repo}" >&2
        exit 1
    fi
    echo "${version}"
}

# ─── Построение тега образа Pangolin под нужную редакцию ─────────────────────
# Community Edition: тег = GitHub-релиз как есть (vX.Y.Z)
# Enterprise Edition: тег = ee-X.Y.Z (тот же релиз, образ fosrl/pangolin:ee-*)
# См. https://docs.pangolin.net/self-host/enterprise-edition
pangolin_image_tag() {
    local gh_tag="$1"   # напр. v1.14.1
    if [[ "${ENTERPRISE}" == true ]]; then
        echo "ee-${gh_tag#v}"
    else
        echo "${gh_tag}"
    fi
}

# ─── Получение последней версии Traefik из GitHub Releases ───────────────────
# Аргумент: текущая мажорная версия (например "3") — её нельзя пересекать,
# чтобы не уйти на v2-патч или на разрушительный новый major.
get_traefik_latest() {
    local major="$1"
    local version

    # Быстрый путь: последний релиз
    version=$(curl -sf --max-time 10 \
        "https://api.github.com/repos/traefik/traefik/releases/latest" \
        | jq -r '.tag_name')

    # Если latest из другой мажорной ветки (напр. вышел патч v2.11.x) или
    # ответ пустой/битый — берём последнюю стабильную версию строго в нашей ветке
    if [[ -z "${version}" || "${version}" == "null" || "${version}" != v${major}.* ]]; then
        log WARN "Traefik: latest вернул '${version}', ищу последнюю версию ветки v${major}" >&2
        version=$(curl -sf --max-time 10 \
            "https://api.github.com/repos/traefik/traefik/releases?per_page=100" \
            | jq -r '.[] | select(.prerelease==false and .draft==false) | .tag_name' \
            | grep -E "^v${major}\.[0-9]+\.[0-9]+$" \
            | sort -V \
            | tail -n1)
    fi

    if [[ -z "${version}" || "${version}" == "null" ]]; then
        log ERROR "Не удалось получить версию Traefik v${major}" >&2
        exit 1
    fi
    echo "${version}"
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
        /^[ ]*badger:[ ]*$/ { inb = 1; bind = indent($0) }
    ' "${TRAEFIK_CONFIG}"
}

set_badger_version() {
    local ver="$1" tmp
    tmp=$(mktemp) || return 1
    if ! awk -v ver="${ver}" '
        function indent(s) { match(s, /^[ ]*/); return RLENGTH }
        inb && NF && indent($0) <= bind { inb = 0 }
        inb && $1 == "version:" {
            q = ($0 ~ /version:[ ]*"/) ? "\"" : ""
            match($0, /^[ ]*version:[ ]*/)
            print substr($0, 1, RLENGTH) q ver q
            done = 1; inb = 0; next
        }
        /^[ ]*badger:[ ]*$/ { inb = 1; bind = indent($0) }
        { print }
        END { exit done ? 0 : 1 }
    ' "${TRAEFIK_CONFIG}" > "${tmp}"; then
        rm -f "${tmp}"
        log ERROR "Не найден ключ version в блоке badger: файла ${TRAEFIK_CONFIG}"
        return 1
    fi
    # cat вместо mv — сохраняем inode и права (файл примонтирован в контейнер)
    cat "${tmp}" > "${TRAEFIK_CONFIG}"
    rm -f "${tmp}"
}

# ─── Список плагинов Traefik из traefik_config.yml ───────────────────────────
# Выводит строки «имя moduleName версия» для каждого плагина в
# experimental.plugins (badger, crowdsec и любые другие).
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
        /^[ ]*plugins:[ ]*$/ { inp = 1; pind = indent($0); cind = 0 }
        END { if (inp) flush() }
    ' "${TRAEFIK_CONFIG}"
}

# ─── Проба: загрузит ли Traefik плагины с указанной версией Badger ───────────
# Поднимает одноразовый контейнер Traefik (без портов, без конфигов стека) со
# ВСЕМИ плагинами из traefik_config.yml; Badger — в проверяемой версии.
# Traefik сам скачивает плагины из каталога plugins.traefik.io и проходит ту же
# проверку целостности, что и боевой. Работающий стек не трогается.
# Возвращает: 0 — плагины загрузились, 1 — ошибка (или пробу выполнить не удалось).
probe_badger() {
    local traefik_tag="$1" badger_ver="$2"
    local name="pangolin-badger-probe-$$" logs="" state bad
    local -a plugin_args=() plugin_names=()
    local p_name p_mod p_ver have_badger=false

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

    log INFO "[Проба] Traefik ${traefik_tag} + плагины: ${plugin_names[*]} (тестовый контейнер, до ${BADGER_PROBE_WAIT}с)..."

    if ! docker pull -q "docker.io/traefik:${traefik_tag}" >> "${LOG_FILE}" 2>&1; then
        log WARN "[Проба] Не удалось скачать образ traefik:${traefik_tag}"
        return 1
    fi

    docker rm -f "${name}" >/dev/null 2>&1 || true
    if ! docker run -d --name "${name}" "docker.io/traefik:${traefik_tag}" \
            --log.level=INFO "${plugin_args[@]}" \
            >/dev/null 2>>"${LOG_FILE}"; then
        log WARN "[Проба] Не удалось запустить тестовый контейнер Traefik"
        return 1
    fi

    local waited=0
    while (( waited < BADGER_PROBE_WAIT )); do
        sleep 5
        (( waited += 5 ))
        logs=$(docker logs "${name}" 2>&1 || true)
        grep -qiE "${TRAEFIK_PLUGIN_ERR_RE}" <<< "${logs}" && break
        state=$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || echo "gone")
        [[ "${state}" != "running" ]] && break
    done
    state=$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null || echo "gone")
    docker rm -f "${name}" >/dev/null 2>&1 || true

    bad=$(grep -iE "${TRAEFIK_PLUGIN_ERR_RE}" <<< "${logs}" | tail -n 3 || true)
    if [[ -n "${bad}" ]]; then
        log WARN "[Проба] Traefik ${traefik_tag} НЕ загрузил плагины (${plugin_names[*]}):"
        while IFS= read -r l; do log WARN "  traefik> ${l:0:300}"; done <<< "${bad}"
        return 1
    fi
    if [[ "${state}" != "running" ]]; then
        log WARN "[Проба] Тестовый Traefik завершился раньше времени (${state}):"
        while IFS= read -r l; do log WARN "  traefik> ${l:0:300}"; done <<< "$(tail -n 3 <<< "${logs}")"
        return 1
    fi
    log OK "[Проба] Плагины ${plugin_names[*]} загружаются в Traefik ${traefik_tag}"
    return 0
}

# ─── CrowdSec: версии образа ─────────────────────────────────────────────────
# Шаблон строки image: в compose (с docker.io/ или без)
CROWDSEC_IMAGE_RE='image:[[:space:]]*(docker\.io/)?crowdsecurity/crowdsec:'

get_crowdsec_image_tag() {
    grep -E "${CROWDSEC_IMAGE_RE}" "${COMPOSE_FILE}" | head -n1 \
        | sed -E "s|.*crowdsecurity/crowdsec:([^[:space:]\"']+).*|\1|" || true
}

# Существует ли тег в Docker Hub (без скачивания образа)
image_tag_exists() {
    docker manifest inspect "$1" >/dev/null 2>&1
}

# Целевой тег CrowdSec: последний GitHub-релиз в той же мажорной ветке, если
# соответствующий тег уже опубликован в Docker Hub. Иначе — текущий тег.
# Плавающие теги (latest, slim, debian...) не трогаем — их предлагается закрепить.
resolve_crowdsec_target() {
    local cur="$1" latest suffix=""
    if [[ ! "${cur}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-(slim|debian))?$ ]]; then
        log WARN "CrowdSec: тег '${cur}' плавающий — автообновление пропущено." >&2
        log WARN "CrowdSec: закрепите версию в compose (напр. crowdsecurity/crowdsec:v1.8.1), тогда скрипт будет её обновлять и сможет откатить." >&2
        echo "${cur}"; return
    fi
    [[ "${cur}" =~ -(slim|debian)$ ]] && suffix="-${BASH_REMATCH[1]}"

    latest=$(curl -sf --max-time 10 \
        "https://api.github.com/repos/crowdsecurity/crowdsec/releases/latest" \
        | jq -r '.tag_name // empty' || true)
    if [[ -z "${latest}" ]]; then
        log WARN "CrowdSec: не удалось получить последний релиз — оставляю ${cur}" >&2
        echo "${cur}"; return
    fi
    local cur_major="${cur#v}"; cur_major="${cur_major%%.*}"
    local new_major="${latest#v}"; new_major="${new_major%%.*}"
    if [[ "${cur_major}" != "${new_major}" ]]; then
        log WARN "CrowdSec: вышла новая мажорная версия ${latest} — автоматически не обновляю (текущая ${cur})" >&2
        echo "${cur}"; return
    fi
    local target="${latest}${suffix}"
    if [[ "${target}" != "${cur}" ]] && ! image_tag_exists "docker.io/crowdsecurity/crowdsec:${target}"; then
        log INFO "CrowdSec: релиз ${latest} ещё не опубликован в Docker Hub — оставляю ${cur}" >&2
        echo "${cur}"; return
    fi
    echo "${target}"
}

# ─── CrowdSec: обновление правил Hub ─────────────────────────────────────────
# Сценарии, парсеры и правила AppSec (виртуальные патчи) обновляются из Hub
# независимо от версии образа. При изменениях CrowdSec перечитывает
# конфигурацию (SIGHUP), без перезапуска контейнера.
# Возвращает 1, если после обновления CrowdSec перестал отвечать: при
# включённом crowdsecAppsecUnreachableBlock это блокирует ВЕСЬ трафик.
crowdsec_hub_update() {
    [[ "${CROWDSEC_HUB_UPDATE}" == true ]] || return 0
    local cid state before after
    cid=$(docker compose -f "${COMPOSE_FILE}" ps -q "${CROWDSEC_SERVICE}" 2>/dev/null || true)
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
    docker compose -f "${COMPOSE_FILE}" restart "${CROWDSEC_SERVICE}" >> "${LOG_FILE}" 2>&1 || true
    sleep "${HEALTH_INITIAL_WAIT}"
    if docker exec "${cid}" cscli lapi status >/dev/null 2>&1; then
        log OK "CrowdSec: работает после перезапуска"
        return 0
    fi
    log ERROR "CrowdSec не отвечает после обновления правил! Если в bouncer включён"
    log ERROR "crowdsecAppsecUnreachableBlock, весь трафик сейчас блокируется."
    log ERROR "Диагностика: docker logs ${CROWDSEC_SERVICE}; cscli hub list"
    return 1
}

# ─── Allowlist CrowdSec: своя инфраструктура ─────────────────────────────────
# Адреса, которые нельзя банить: сам сервер и сайты Newt. Бан IP сайта Newt
# обрывает туннель вместе со всеми ресурсами этого сайта.
#
# Каждая автоматическая запись помечается описанием «auto: ...». При
# синхронизации записи «auto:», которых больше нет в источниках, удаляются
# (например, у сайта сменился IP у провайдера — старый адрес мог достаться
# кому-то другому). Записи с другими описаниями (добавленные вручную через
# cscli или crowdsec-manager) скрипт не трогает.

# Лог синхронизации: при тихом запуске из cron INFO/WARN не пишутся (иначе
# одна и та же строка каждые несколько минут); изменения и ошибки — всегда.
ALLOWLIST_QUIET=false
alog() {
    [[ "${ALLOWLIST_QUIET}" == true && "$1" != "ERROR" && "$1" != "OK" ]] && return 0
    log "$@"
}

crowdsec_cid() {
    docker compose -f "${COMPOSE_FILE}" ps -q "${CROWDSEC_SERVICE}" 2>/dev/null || true
}

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

# Запрос к БД Pangolin (SQLite) только на чтение; строки через TAB.
# Пробует sqlite3, затем python3 на хосте, затем Node.js внутри контейнера
# pangolin (better-sqlite3 там есть всегда) — на хост ничего ставить не нужно.
pangolin_db_query() {
    local sql="$1" cid
    if [[ -f "${PANGOLIN_DB}" ]]; then
        if command -v sqlite3 >/dev/null 2>&1; then
            sqlite3 -readonly -separator $'\t' "${PANGOLIN_DB}" "${sql}" 2>>"${LOG_FILE}" && return 0
        fi
        if command -v python3 >/dev/null 2>&1; then
            python3 -I - "${PANGOLIN_DB}" "${sql}" 2>>"${LOG_FILE}" <<'PY' && return 0
import sqlite3, sys
con = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True, timeout=10)
for row in con.execute(sys.argv[2]):
    print("\t".join("" if v is None else str(v) for v in row))
PY
        fi
    elif grep -qE 'image:[[:space:]]*\S*postgres' "${COMPOSE_FILE}" 2>/dev/null; then
        alog WARN "[Allowlist] Pangolin использует PostgreSQL — чтение сайтов Newt не поддерживается, добавьте их IP в ALLOWLIST_EXTRA" >&2
        return 1
    fi
    cid=$(docker compose -f "${COMPOSE_FILE}" ps -q pangolin 2>/dev/null || true)
    [[ -z "${cid}" ]] && return 1
    # Маркер в конце вывода отличает «запрос выполнен, строк нет» от сбоя
    # (иначе пустой ответ привёл бы к удалению всех записей Newt из allowlist)
    local out marker="__PANGOLIN_DB_OK__"
    out=$(docker exec -w /app -e Q="${sql}" -e M="${marker}" "${cid}" node -e '
        const D = require("better-sqlite3");
        const db = new D("config/db/db.sqlite", { readonly: true, fileMustExist: true });
        for (const r of db.prepare(process.env.Q).raw().all())
            console.log(r.map(v => (v === null || v === undefined) ? "" : v).join("\t"));
        console.log(process.env.M);
    ' 2>>"${LOG_FILE}") || return 1
    [[ "$(tail -n1 <<< "${out}")" == "${marker}" ]] || return 1
    sed '$d' <<< "${out}"
}

# Публичные IP сайтов Newt: строки «ip<TAB>auto: newt <имя сайта>».
# sites.endpoint — адрес, с которого Newt пробивает туннель к Gerbil
# (обновляется Pangolin при каждом hole punch). Сайты без связи дольше
# ALLOWLIST_NEWT_MAX_AGE_DAYS пропускаются. Возвращает 1, если БД не прочитана.
get_newt_ips() {
    local rows now cutoff name _type ep hp lp seen host ip
    rows=$(pangolin_db_query "SELECT name, type, endpoint, COALESCE(lastHolePunch,0), COALESCE(lastPing,0) FROM sites WHERE endpoint IS NOT NULL AND endpoint <> ''") || return 1
    now=$(date +%s)
    cutoff=$(( now - ALLOWLIST_NEWT_MAX_AGE_DAYS * 86400 ))
    while IFS=$'\t' read -r name _type ep hp lp; do
        [[ -z "${ep}" ]] && continue
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
get_server_ips() {
    {
        curl -4 -sf --max-time 10 https://api.ipify.org || curl -4 -sf --max-time 10 https://ifconfig.me || true
        echo
        curl -6 -sf --max-time 10 https://api6.ipify.org || true
        echo
        if [[ -f "${CF_ENV_FILE}" ]]; then
            sed -n 's/^CF_TARGET_IP="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "${CF_ENV_FILE}"
        fi
        # Глобальные адреса интерфейсов хоста (без docker/bridge/veth/wireguard)
        ip -o addr show scope global 2>/dev/null \
            | awk '$2 !~ /^(docker|br-|veth|wg|lo)/ { split($4, a, "/"); print a[1] }' || true
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
    if newt=$(get_newt_ips); then
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
    if ! current=$(docker exec "${cid}" cscli allowlists inspect "${ALLOWLIST_NAME}" -o json 2>>"${LOG_FILE}" \
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

    # Из cron — тихо: итог только при изменениях или ошибках
    if (( added > 0 || removed > 0 || failed > 0 )) || [[ "${verbose}" == true ]]; then
        log INFO "[Allowlist] '${ALLOWLIST_NAME}': добавлено ${added}, удалено ${removed}, без изменений ${kept}, ошибок ${failed}"
    fi
    (( failed > 0 )) && return 1
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
    # Идёт обновление/бэкап (главный lock занят) — тихо откладываем
    if [[ -f "${LOCK_FILE}" ]] && kill -0 "$(cat "${LOCK_FILE}" 2>/dev/null)" 2>/dev/null; then
        exit 0
    fi
    [[ -t 1 ]] || ALLOWLIST_QUIET=true
    if [[ -z "$(crowdsec_cid)" ]]; then
        alog WARN "Сервис '${CROWDSEC_SERVICE}' не найден в стеке или не запущен"
        exit 1
    fi
    allowlist_sync && exit 0 || exit 1
}

install_allowlist_cron() {
    local script_path
    script_path=$(readlink -f "$0")
    cat > "${ALLOWLIST_CRON_FILE}" <<EOF
# Синхронизация allowlist CrowdSec: IP сервера и сайтов Newt (pangolin-update)
*/${ALLOWLIST_SYNC_INTERVAL} * * * * root ${script_path} -allowlist-sync >/dev/null 2>&1
EOF
    chmod 644 "${ALLOWLIST_CRON_FILE}"
    log OK "cron-задача создана: ${ALLOWLIST_CRON_FILE} (каждые ${ALLOWLIST_SYNC_INTERVAL} мин)"
}

allowlist_enable() {
    if [[ -z "$(crowdsec_cid)" ]]; then
        log ERROR "Сервис '${CROWDSEC_SERVICE}' не найден в стеке или не запущен — сначала установите CrowdSec (-crowdsec-install)"
        exit 1
    fi
    install_allowlist_cron
    log INFO "Первичная синхронизация allowlist..."
    if allowlist_sync; then
        log OK "Автоматический allowlist включён: новые сайты Newt и смена их IP подхватываются за ${ALLOWLIST_SYNC_INTERVAL} мин"
    else
        log WARN "cron-задача создана, но при первичной синхронизации были ошибки — см. лог выше"
    fi
    log_separator
    exit 0
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
    exit 0
}

# ─── Проверка логов боевого Traefik на ошибки загрузки плагинов ──────────────
# Контейнер при такой ошибке остаётся running, поэтому docker inspect её не видит.
# Возвращает: 0 — ошибок нет, 1 — плагины не загрузились.
traefik_plugins_ok() {
    local cid logs bad
    cid=$(docker compose ps -q traefik 2>/dev/null || true)
    [[ -z "${cid}" ]] && return 0   # состояние контейнера проверяет check_container
    logs=$(docker logs --since "${STACK_STARTED_AT:-10m}" "${cid}" 2>&1 || true)
    bad=$(grep -iE "${TRAEFIK_PLUGIN_ERR_RE}" <<< "${logs}" | tail -n 3 || true)
    if [[ -n "${bad}" ]]; then
        log WARN "Traefik: плагины не загрузились — ресурсы Pangolin недоступны, хотя контейнер работает:"
        while IFS= read -r l; do log WARN "  traefik> ${l:0:300}"; done <<< "${bad}"
        return 1
    fi
    return 0
}

# ─── Частичный откат: вернуть только версию Badger ───────────────────────────
# Остальные компоненты остаются на новых версиях; перезапускается только Traefik.
# Вызывается при отключённом errexit. Возвращает результат health_check.
badger_rollback() {
    local from="$1"
    log WARN "┌──────────────────────────────────────────────────────────┐"
    log WARN "│  ЧАСТИЧНЫЙ ОТКАТ: только Badger ${from} -> ${OLD_BADGER_V}"
    log WARN "└──────────────────────────────────────────────────────────┘"

    set_badger_version "${OLD_BADGER_V}" || return 1
    log OK "[Badger] В traefik_config.yml возвращена версия ${OLD_BADGER_V}"

    STACK_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if ! docker compose restart traefik >> "${LOG_FILE}" 2>&1; then
        log ERROR "[Badger] Не удалось перезапустить Traefik"
        return 1
    fi

    local rc
    health_check
    rc=$?
    if (( rc == 0 )); then
        BADGER_V="${OLD_BADGER_V}"
        BADGER_HELD_BACK=true
        log OK "[Badger] Частичный откат успешен: Badger ${OLD_BADGER_V}, остальные компоненты обновлены"
    fi
    return "${rc}"
}

# ─── Чтение текущих версий из файлов конфигурации ───────────────────────────
read_current_versions() {
    OLD_PANGOLIN_V=$(grep "image: docker.io/fosrl/pangolin" "${COMPOSE_FILE}" | cut -d: -f3)
    OLD_GERBIL_V=$(grep "image: docker.io/fosrl/gerbil"    "${COMPOSE_FILE}" | cut -d: -f3)
    OLD_TRAEFIK_V=$(grep "image: docker.io/traefik"        "${COMPOSE_FILE}" | cut -d: -f3)
    OLD_BADGER_V=$(get_badger_version)
    OLD_CROWDSEC_V=$(get_crowdsec_image_tag)   # пусто, если CrowdSec в стеке нет

    for var in OLD_PANGOLIN_V OLD_GERBIL_V OLD_TRAEFIK_V OLD_BADGER_V; do
        if [[ -z "${!var}" ]]; then
            log ERROR "Не удалось прочитать текущую версию: ${var}"
            exit 1
        fi
    done
}

# ─── Форматированный вывод версий ────────────────────────────────────────────
print_version_line() {
    local name="$1" old="$2" new="$3"
    if [[ "${old}" == "${new}" ]]; then
        printf "  %-12s ${C_YELLOW}%-14s${C_RESET} (без изменений)\n" "${name}" "${old}"
        printf "  %-12s %-14s (без изменений)\n" "${name}" "${old}" >> "${LOG_FILE}"
    else
        printf "  %-12s ${C_RED}%-14s${C_RESET} -> ${C_GREEN}%-14s${C_RESET}\n" "${name}" "${old}" "${new}"
        printf "  %-12s %-14s -> %-14s\n" "${name}" "${old}" "${new}" >> "${LOG_FILE}"
    fi
}

# Таблица «текущая -> целевая» для всех отслеживаемых компонентов
print_versions() {
    print_version_line "Pangolin" "${OLD_PANGOLIN_V}" "${PANGOLIN_V}"
    print_version_line "Gerbil"   "${OLD_GERBIL_V}"   "${GERBIL_V}"
    print_version_line "Traefik"  "${OLD_TRAEFIK_V}"  "${TRAEFIK_V}"
    print_version_line "Badger"   "${OLD_BADGER_V}"   "${BADGER_V}"
    if [[ -n "${OLD_CROWDSEC_V}" ]]; then
        print_version_line "CrowdSec" "${OLD_CROWDSEC_V}" "${CROWDSEC_V}"
    fi
}

# 0 — все компоненты уже на целевых версиях
nothing_to_update() {
    [[ "${OLD_PANGOLIN_V}" == "${PANGOLIN_V}" &&
       "${OLD_GERBIL_V}"   == "${GERBIL_V}"   &&
       "${OLD_TRAEFIK_V}"  == "${TRAEFIK_V}"  &&
       "${OLD_BADGER_V}"   == "${BADGER_V}"   &&
       "${OLD_CROWDSEC_V}" == "${CROWDSEC_V}" ]]
}

# ─── Проверка здоровья одного контейнера ─────────────────────────────────────
# Возвращает: 0 — здоров, 1 — нездоров
check_container() {
    local id="$1"
    local name state health restart_count

    name=$(docker inspect --format '{{.Name}}' "${id}" 2>/dev/null | sed 's|^/||')
    state=$(docker inspect --format '{{.State.Status}}' "${id}" 2>/dev/null)
    restart_count=$(docker inspect --format '{{.RestartCount}}' "${id}" 2>/dev/null)
    health=$(docker inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "${id}" 2>/dev/null)

    local problem=""

    if [[ "${state}" != "running" ]]; then
        problem="не запущен (${state})"
    elif (( restart_count >= RESTART_THRESHOLD )); then
        problem="циклические перезапуски (${restart_count} раз)"
    elif [[ "${health}" == "unhealthy" ]]; then
        problem="healthcheck: unhealthy"
    fi

    if [[ -n "${problem}" ]]; then
        printf "  ${C_RED}✗${C_RESET} %-28s состояние=%-12s здоровье=%-12s перезапусков=%s\n" \
            "${name}" "${state}" "${health}" "${restart_count}"
        printf "  ✗ %-28s состояние=%-12s здоровье=%-12s перезапусков=%s\n" \
            "${name}" "${state}" "${health}" "${restart_count}" >> "${LOG_FILE}"
        local svc
        svc=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "${id}" 2>/dev/null || true)
        if [[ -n "${svc}" && " ${HEALTH_IGNORE_SERVICES} " == *" ${svc} "* ]]; then
            log WARN "Контейнер '${name}': ${problem} — сервис в HEALTH_IGNORE_SERVICES, на откат не влияет"
            return 0
        fi
        log WARN "Контейнер '${name}': ${problem}"
        return 1
    fi

    printf "  ${C_GREEN}✓${C_RESET} %-28s состояние=%-12s здоровье=%-12s перезапусков=%s\n" \
        "${name}" "${state}" "${health}" "${restart_count}"
    printf "  ✓ %-28s состояние=%-12s здоровье=%-12s перезапусков=%s\n" \
        "${name}" "${state}" "${health}" "${restart_count}" >> "${LOG_FILE}"
    return 0
}

# ─── Сбор диагностических логов упавших контейнеров ─────────────────────────
dump_failed_logs() {
    local ids
    ids=$(docker compose ps -q 2>/dev/null || true)
    [[ -z "${ids}" ]] && return

    log ERROR "Дамп последних логов проблемных контейнеров:"
    while IFS= read -r id; do
        local name state
        name=$(docker inspect --format '{{.Name}}' "${id}" 2>/dev/null | sed 's|^/||')
        state=$(docker inspect --format '{{.State.Status}}' "${id}" 2>/dev/null)

        if [[ "${state}" != "running" ]]; then
            {
                echo "━━━ Логи контейнера: ${name} [${state}] ━━━"
                docker logs --tail=50 "${id}" 2>&1
                echo "━━━ Конец логов: ${name} ━━━"
                echo ""
            } >> "${LOG_FILE}"
            log ERROR "Логи '${name}' записаны в ${LOG_FILE}"
        fi
    done <<< "${ids}"
}

# ─── Health check всего стека с повторными попытками ─────────────────────────
# Возвращает: 0 — стек здоров, 1 — нездоров контейнер,
#             3 — контейнеры работают, но Traefik не загрузил плагины (Badger)
health_check() {
    log INFO "Ожидание инициализации контейнеров (${HEALTH_INITIAL_WAIT}с)..."
    sleep "${HEALTH_INITIAL_WAIT}"

    for (( attempt=1; attempt<=HEALTH_RETRIES; attempt++ )); do
        log INFO "Проверка состояния стека (попытка ${attempt}/${HEALTH_RETRIES})..."

        local ids
        ids=$(docker compose ps -q 2>/dev/null || true)

        if [[ -z "${ids}" ]]; then
            log WARN "Контейнеры не обнаружены"
            sleep "${HEALTH_INTERVAL}"
            continue
        fi

        local failed=0
        while IFS= read -r id; do
            check_container "${id}" || (( failed++ )) || true
        done <<< "${ids}"

        if (( failed == 0 )); then
            # Ошибка плагина не лечится ожиданием — повторы не нужны
            if ! traefik_plugins_ok; then
                log ERROR "Health check: контейнеры работают, но Traefik не загрузил плагины (Badger/CrowdSec)"
                return 3
            fi
            log OK "Health check пройден: все контейнеры работают корректно, плагины Traefik загружены"
            return 0
        fi

        log WARN "Проблемных контейнеров: ${failed}"

        if (( attempt < HEALTH_RETRIES )); then
            log INFO "Следующая проверка через ${HEALTH_INTERVAL}с..."
            sleep "${HEALTH_INTERVAL}"
        fi
    done

    log ERROR "Health check провален после ${HEALTH_RETRIES} попыток"
    dump_failed_logs
    return 1
}

# ─── Откат к предыдущим версиям ──────────────────────────────────────────────
do_rollback() {
    ROLLBACK_DONE=true
    log WARN "┌─────────────────────────────────────────────┐"
    log WARN "│      ЗАПУСК ОТКАТА К ПРЕДЫДУЩЕЙ ВЕРСИИ      │"
    log WARN "└─────────────────────────────────────────────┘"

    # Останавливаем новые контейнеры
    log INFO "[Откат] Остановка контейнеров с новыми версиями..."
    docker compose down >> "${LOG_FILE}" 2>&1 || true
    log OK "[Откат] Контейнеры остановлены"

    # Восстанавливаем конфигурационные файлы
    log INFO "[Откат] Восстановление конфигурационных файлов (суффикс: ${DATE_SUFFIX})..."
    local restore_ok=true

    if [[ -f "${COMPOSE_FILE}.bak.${DATE_SUFFIX}" ]]; then
        cp "${COMPOSE_FILE}.bak.${DATE_SUFFIX}" "${COMPOSE_FILE}"
        log OK "[Откат] docker-compose.yml восстановлен"
    else
        log ERROR "[Откат] Резервная копия не найдена: ${COMPOSE_FILE}.bak.${DATE_SUFFIX}"
        restore_ok=false
    fi

    if [[ -f "${TRAEFIK_CONFIG}.bak.${DATE_SUFFIX}" ]]; then
        cp "${TRAEFIK_CONFIG}.bak.${DATE_SUFFIX}" "${TRAEFIK_CONFIG}"
        log OK "[Откат] traefik_config.yml восстановлен"
    else
        log ERROR "[Откат] Резервная копия не найдена: ${TRAEFIK_CONFIG}.bak.${DATE_SUFFIX}"
        restore_ok=false
    fi

    if [[ "${restore_ok}" == false ]]; then
        log ERROR "[Откат] Не удалось восстановить конфигурации — требуется ручное вмешательство!"
        log ERROR "[Откат] Ищите резервные копии по маске: *.bak.${DATE_SUFFIX}"
        return 1
    fi

    # Запускаем стек на старых образах (они ещё в кэше, prune не вызывался)
    log INFO "[Откат] Запуск стека на предыдущих версиях (образы в локальном кэше)..."
    STACK_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    docker compose up -d >> "${LOG_FILE}" 2>&1
    log OK "[Откат] Команда запуска выполнена"

    # Проверяем состояние после отката
    log INFO "[Откат] Проверка работоспособности восстановленного стека..."
    sleep "${HEALTH_INITIAL_WAIT}"

    local ids
    ids=$(docker compose ps -q 2>/dev/null || true)
    local rollback_failed=0

    if [[ -z "${ids}" ]]; then
        log ERROR "[Откат] Контейнеры не запустились после отката!"
        return 1
    fi

    while IFS= read -r id; do
        check_container "${id}" || (( rollback_failed++ )) || true
    done <<< "${ids}"

    if (( rollback_failed == 0 )); then
        if ! traefik_plugins_ok; then
            log ERROR "[Откат] Контейнеры работают, но Traefik не загрузил плагины и на старых версиях."
            log ERROR "[Откат] Вероятно, проблема на стороне каталога plugins.traefik.io — повторите позже."
            return 1
        fi
        log OK "┌──────────────────────────────────────────────────────────┐"
        log OK "│  Откат выполнен успешно. Стек работает на старых версиях │"
        log OK "└──────────────────────────────────────────────────────────┘"
    else
        log ERROR "[Откат] ${rollback_failed} контейнер(ов) не запустились после отката!"
        log ERROR "[Откат] Требуется ручное вмешательство."
        dump_failed_logs
        return 1
    fi
}

# ─── Полная резервная копия: конфиги + БД + сертификаты ──────────────────────
# Вызывается при остановленном стеке — так копия SQLite-базы консистентна.
# ponytail: холодный бэкап (короткий downtime); горячий через sqlite3 .backup —
# если простой станет неприемлем.
create_backup_archive() {
    mkdir -p "${BACKUP_DIR}"
    local archive="${BACKUP_DIR}/pangolin_$(date +%d%m%Y_%H%M%S).tar.gz"

    log INFO "Архивирование ${PANGOLIN_DIR} (docker-compose.yml + config/)..."
    tar czf "${archive}" --exclude='*.bak.*' --exclude="${LOGS_EXCLUDE}" \
        -C "${PANGOLIN_DIR}" docker-compose.yml config
    log OK "Резервная копия создана: ${archive} ($(du -h "${archive}" | cut -f1))"

    # Храним только последние BACKUP_KEEP архивов
    local old
    old=$(ls -1t "${BACKUP_DIR}"/pangolin_*.tar.gz 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) || true)
    if [[ -n "${old}" ]]; then
        echo "${old}" | xargs rm -f
        log INFO "Старые архивы удалены (храним последние ${BACKUP_KEEP})"
    fi
}

# ─── Режим -backup: остановить стек, снять копию, запустить обратно ──────────
do_backup() {
    log INFO "Создание полной резервной копии стека (конфигурация, БД, сертификаты)"
    log INFO "Остановка Docker-стека (для консистентной копии БД)..."
    docker compose down >> "${LOG_FILE}" 2>&1
    log OK "Стек остановлен"

    create_backup_archive

    log INFO "Запуск Docker-стека..."
    if ! docker compose up -d >> "${LOG_FILE}" 2>&1; then
        log ERROR "docker compose up завершился с ошибкой — стек может быть запущен не полностью!"
        log ERROR "Проверьте: cd ${PANGOLIN_DIR} && docker compose ps"
        exit 1
    fi
    log OK "Стек запущен"
    log_separator
    exit 0
}

# ─── Режим -restore: восстановление из архива ────────────────────────────────
do_restore() {
    local archive="${1:-}"

    if [[ -z "${archive}" ]]; then
        archive=$(ls -1t "${BACKUP_DIR}"/pangolin_*.tar.gz 2>/dev/null | head -n1 || true)
        if [[ -z "${archive}" ]]; then
            log ERROR "Резервные копии не найдены в ${BACKUP_DIR}"
            exit 1
        fi
        log INFO "Архив не указан — использую последний: ${archive}"
    fi

    if [[ ! -f "${archive}" ]]; then
        log ERROR "Файл не найден: ${archive}"
        exit 1
    fi
    if ! tar tzf "${archive}" >/dev/null 2>&1; then
        log ERROR "Архив повреждён или не является tar.gz: ${archive}"
        exit 1
    fi

    log WARN "Восстановление из резервной копии: ${archive}"
    log WARN "Текущие конфигурация, БД и сертификаты будут перезаписаны содержимым архива"

    log INFO "Остановка Docker-стека..."
    docker compose down >> "${LOG_FILE}" 2>&1 || true
    log OK "Стек остановлен"

    mkdir -p "${PANGOLIN_DIR}"
    tar xzf "${archive}" -C "${PANGOLIN_DIR}"
    log OK "Файлы восстановлены из архива"

    # Образы версий из архива могли быть удалены prune — докачиваем недостающие
    log INFO "Скачивание образов (если отсутствуют в локальном кэше)..."
    docker compose pull >> "${LOG_FILE}" 2>&1 \
        || log WARN "docker compose pull завершился с ошибкой — пробуем запустить из кэша"

    log INFO "Запуск Docker-стека..."
    docker compose up -d >> "${LOG_FILE}" 2>&1 \
        || log ERROR "docker compose up завершился с ошибкой — подробности покажет health check"

    set +e
    health_check
    local hc=$?
    set -e
    if (( hc != 0 )); then
        log ERROR "Стек восстановлен из архива, но не прошёл health check — смотрите логи выше"
        exit 1
    fi

    log OK "Восстановление из резервной копии выполнено успешно"
    log_separator
    exit 0
}

# ─── Интеграция с Cloudflare: автосоздание DNS-записей для поддоменов ────────
# При появлении нового ресурса (поддомена) в Pangolin для него автоматически
# создаётся A-запись в Cloudflare. Список поддоменов берётся из конфигурации,
# которую Pangolin отдаёт Traefik (endpoint /api/v1/traefik-config) — там
# перечислены Host-правила всех ресурсов.
# -cloudflare сохраняет настройки в CF_ENV_FILE и ставит cron-задачу -dns-sync;
# -cloudflare-off убирает и то и другое. Docker-стек при этом не перезапускается.

cf_api() {
    curl -sf --max-time 15 \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" "$@"
}

# Поиск зоны Cloudflare для FQDN: отбрасываем метки слева, пока не найдём зону.
# Результат — в глобальных ZONE_ID / ZONE_NAME (вызов без subshell, чтобы
# кэш CF_ZONE_CACHE сохранялся между итерациями). Возвращает 0/1.
declare -A CF_ZONE_CACHE
ZONE_ID=""
ZONE_NAME=""
cf_find_zone() {
    local candidate="$1" zid
    ZONE_ID=""; ZONE_NAME=""
    while [[ "${candidate}" == *.* ]]; do
        if [[ -n "${CF_ZONE_CACHE[${candidate}]:-}" ]]; then
            ZONE_ID="${CF_ZONE_CACHE[${candidate}]}"
            ZONE_NAME="${candidate}"
            return 0
        fi
        zid=$(cf_api "${CF_API}/zones?name=${candidate}&status=active" \
            | jq -r '.result[0].id // empty')
        if [[ -n "${zid}" ]]; then
            CF_ZONE_CACHE[${candidate}]="${zid}"
            ZONE_ID="${zid}"
            ZONE_NAME="${candidate}"
            return 0
        fi
        candidate="${candidate#*.}"
    done
    return 1
}

# Список FQDN всех ресурсов Pangolin — из HTTP-конфигурации для Traefik
get_pangolin_hostnames() {
    local cid ip cfg
    cid=$(docker compose ps -q pangolin 2>/dev/null || true)
    if [[ -z "${cid}" ]]; then
        log ERROR "[DNS] Контейнер pangolin не запущен — не могу получить список поддоменов"
        return 1
    fi
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${cid}")
    cfg=$(curl -sf --max-time 10 "http://${ip}:3001/api/v1/traefik-config") || {
        log ERROR "[DNS] Не удалось получить http://${ip}:3001/api/v1/traefik-config"
        return 1
    }
    echo "${cfg}" | grep -oE 'Host\(`[^`]+`\)' | sed -E 's/^Host\(`//; s/`\)$//' | sort -u || true
}

# ─── Ядро синхронизации DNS ──────────────────────────────────────────────────
# Использует CF_TOKEN, CF_TARGET_IP, CF_PROXIED. Возвращает 0 или 1 (были ошибки).
# Добавляет только недостающие записи; существующие (любого типа) не трогает.
dns_sync_run() {
    local hostnames
    hostnames=$(get_pangolin_hostnames) || return 1
    [[ -z "${hostnames}" ]] && return 0   # ресурсов нет — делать нечего

    local created=0 skipped=0 external=0 failed=0
    local fqdn rec ok verbose=false
    [[ -t 1 ]] && verbose=true   # ручной запуск — подробный вывод; cron — тихий

    while IFS= read -r fqdn; do
        [[ -z "${fqdn}" ]] && continue

        if ! cf_find_zone "${fqdn}"; then
            # Домен обслуживается не в Cloudflare — это не ошибка, просто пропускаем.
            # Пишем в лог только при ручном запуске, чтобы не засорять его из cron.
            [[ "${verbose}" == true ]] && log WARN "[DNS] Зона для '${fqdn}' не найдена в Cloudflare — пропускаю"
            (( external++ )) || true
            continue
        fi

        rec=$(cf_api "${CF_API}/zones/${ZONE_ID}/dns_records?name=${fqdn}" \
            | jq -r '.result[0].id // empty')
        if [[ -n "${rec}" ]]; then
            (( skipped++ )) || true
            continue
        fi

        ok=$(cf_api -X POST "${CF_API}/zones/${ZONE_ID}/dns_records" --data "{
                \"type\": \"A\",
                \"name\": \"${fqdn}\",
                \"content\": \"${CF_TARGET_IP}\",
                \"ttl\": 1,
                \"proxied\": ${CF_PROXIED:-false},
                \"comment\": \"pangolin-update autosync\"
            }" | jq -r '.success' || true)
        if [[ "${ok}" == "true" ]]; then
            log OK "[DNS] Создана A-запись: ${fqdn} -> ${CF_TARGET_IP} (зона ${ZONE_NAME}, proxied=${CF_PROXIED:-false})"
            (( created++ )) || true
        else
            log ERROR "[DNS] Не удалось создать запись '${fqdn}' — проверьте права токена (Zone:Read, DNS:Edit) для зоны ${ZONE_NAME}"
            (( failed++ )) || true
        fi
    done <<< "${hostnames}"

    # Из cron запуск тихий: итог пишем только когда что-то создали или были ошибки.
    # При ручном запуске итог выводится всегда.
    if (( created > 0 || failed > 0 )) || [[ "${verbose}" == true ]]; then
        log INFO "[DNS] Синхронизация: создано ${created}, уже существует ${skipped}, вне Cloudflare ${external}, ошибок ${failed}"
    fi
    (( failed > 0 )) && return 1
    return 0
}

# ─── Режим -dns-sync: разовая синхронизация (вызывается из cron) ─────────────
do_dns_sync() {
    if [[ ! -f "${CF_ENV_FILE}" ]]; then
        log ERROR "Интеграция с Cloudflare не включена (нет файла ${CF_ENV_FILE})."
        log ERROR "Включите: $(basename "$0") -cloudflare <TOKEN>"
        exit 1
    fi
    # shellcheck source=/dev/null
    source "${CF_ENV_FILE}"
    if [[ -z "${CF_TOKEN:-}" || -z "${CF_TARGET_IP:-}" ]]; then
        log ERROR "В ${CF_ENV_FILE} не заданы CF_TOKEN и/или CF_TARGET_IP"
        exit 1
    fi

    # Идёт обновление/бэкап (главный lock занят) — тихо откладываем до следующего цикла
    if [[ -f "${LOCK_FILE}" ]] && kill -0 "$(cat "${LOCK_FILE}" 2>/dev/null)" 2>/dev/null; then
        exit 0
    fi

    dns_sync_run && exit 0 || exit 1
}

# ─── Включение интеграции с Cloudflare ───────────────────────────────────────
cf_enable() {
    local token="${1:-${CLOUDFLARE_API_TOKEN:-${CLOUDFLARE_DNS_API_TOKEN:-}}}"

    # Токен не передан, но интеграция уже была включена — берём сохранённый
    if [[ -z "${token}" && -f "${CF_ENV_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${CF_ENV_FILE}"
        token="${CF_TOKEN:-}"
    fi
    if [[ -z "${token}" ]]; then
        log ERROR "Не указан API-токен Cloudflare."
        log ERROR "Передайте его аргументом:  $(basename "$0") -cloudflare <TOKEN>"
        log ERROR "или через переменную окружения CLOUDFLARE_API_TOKEN."
        log ERROR "Токен создаётся в dash.cloudflare.com -> My Profile -> API Tokens"
        log ERROR "с правами Zone:Read и DNS:Edit для зоны вашего домена."
        exit 1
    fi

    log INFO "Включение интеграции с Cloudflare (автосоздание DNS-записей для поддоменов)"

    # Проверка токена
    CF_TOKEN="${token}"
    if [[ "$(cf_api "${CF_API}/user/tokens/verify" | jq -r '.success' || true)" != "true" ]]; then
        log ERROR "Токен Cloudflare не прошёл проверку (${CF_API}/user/tokens/verify)"
        exit 1
    fi
    log OK "Токен Cloudflare действителен"

    # Публичный IP сервера — на него будут указывать создаваемые A-записи
    CF_TARGET_IP=$(curl -4 -sf --max-time 10 https://api.ipify.org \
        || curl -4 -sf --max-time 10 https://ifconfig.me || true)
    if [[ -z "${CF_TARGET_IP}" ]]; then
        log ERROR "Не удалось определить публичный IP сервера."
        log ERROR "Проверьте доступ в интернет и повторите, либо создайте ${CF_ENV_FILE} вручную."
        exit 1
    fi
    log INFO "Публичный IP сервера: ${CF_TARGET_IP} (при необходимости измените в ${CF_ENV_FILE})"

    # Файл настроек (только для root)
    umask 077
    cat > "${CF_ENV_FILE}" <<EOF
# Интеграция pangolin-update с Cloudflare DNS (создано $(date '+%Y-%m-%d %H:%M:%S'))
CF_TOKEN="${token}"
CF_TARGET_IP="${CF_TARGET_IP}"
CF_PROXIED=${CF_PROXIED:-false}   # true = проксировать записи через Cloudflare (оранжевое облако)
EOF
    log OK "Настройки сохранены: ${CF_ENV_FILE} (права 600)"

    # cron-задача периодической синхронизации
    local script_path
    script_path=$(readlink -f "$0")
    cat > "${CF_CRON_FILE}" <<EOF
# Автосинхронизация DNS-записей Cloudflare с ресурсами Pangolin (pangolin-update)
*/${CF_SYNC_INTERVAL} * * * * root ${script_path} -dns-sync >/dev/null 2>&1
EOF
    chmod 644 "${CF_CRON_FILE}"
    log OK "cron-задача создана: ${CF_CRON_FILE} (каждые ${CF_SYNC_INTERVAL} мин)"

    # Первичная синхронизация — сразу создаём записи для существующих ресурсов
    log INFO "Первичная синхронизация DNS-записей..."
    CF_PROXIED="${CF_PROXIED:-false}"
    if dns_sync_run; then
        log OK "Интеграция с Cloudflare включена. Новые поддомены Pangolin будут"
        log OK "получать A-записи автоматически (проверка каждые ${CF_SYNC_INTERVAL} мин)."
    else
        log WARN "Интеграция включена, но при первичной синхронизации были ошибки — см. лог выше"
    fi
    log_separator
    exit 0
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

    if [[ "${removed}" == true ]]; then
        log OK "Интеграция с Cloudflare отключена — новые поддомены больше не синхронизируются"
        log INFO "Уже созданные DNS-записи в Cloudflare сохранены. При необходимости удалите их"
        log INFO "вручную — они помечены комментарием 'pangolin-update autosync'."
    else
        log INFO "Интеграция с Cloudflare не была включена. Ничего не меняю."
    fi
    log_separator
    exit 0
}

# ════════════════════════════════════════════════════════════════════════════════
# Установка / удаление CrowdSec в работающем Pangolin
# ════════════════════════════════════════════════════════════════════════════════
# YAML правится утилитой yq в одноразовом контейнере: на хост ничего не ставится,
# комментарии и порядок ключей в конфигах сохраняются. Пути для yq — относительно
# PANGOLIN_DIR (он монтируется в контейнер как /workdir).

CS_TMP_REL=".crowdsec-install"                 # временные фрагменты (внутри PANGOLIN_DIR)
CS_TRAEFIK_LOG_VOLUME="./config/traefik/logs:/var/log/traefik"
CS_ACCESS_LOG="/var/log/traefik/access.log"
YQ_ENV=()                                      # доп. переменные для strenv(): (-e NAME=value ...)

yqd() {
    docker run --rm -u 0:0 -v "${PANGOLIN_DIR}:/workdir" -w /workdir \
        ${YQ_ENV[@]+"${YQ_ENV[@]}"} "${YQ_IMAGE}" "$@"
}

rel_path() { echo "${1#"${PANGOLIN_DIR}"/}"; }

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

# Имя контейнера сервиса: container_name из compose или <проект>-<сервис>-1
compose_container_name() {
    local svc="$1" name project
    YQ_ENV=(-e "SVC=${svc}")
    name=$(yqd '.services[strenv(SVC)].container_name // ""' "$(rel_path "${COMPOSE_FILE}")" 2>/dev/null || true)
    YQ_ENV=()
    if [[ -z "${name}" || "${name}" == "null" ]]; then
        project=$(docker compose config --format json 2>/dev/null | jq -r '.name // empty' || true)
        name="${project:-$(basename "${PANGOLIN_DIR}")}-${svc}-1"
    fi
    echo "${name}"
}

# Тег образа traefik из compose
get_traefik_image_tag() {
    grep -E 'image:[[:space:]]*(docker\.io/)?traefik:' "${COMPOSE_FILE}" | head -n1 \
        | sed -E "s|.*traefik:([^[:space:]\"']+).*|\1|" || true
}

# Диапазоны Cloudflare (для режима «оранжевого облака»)
get_cloudflare_ranges() {
    { curl -sf --max-time 10 https://www.cloudflare.com/ips-v4 || true; echo
      curl -sf --max-time 10 https://www.cloudflare.com/ips-v6 || true; echo
    } | grep -E '^[0-9a-fA-F:.]+/[0-9]+$' || true
}

# ─── Фрагменты конфигурации ──────────────────────────────────────────────────
cs_write_fragments() {
    local tmp="$1" key="$2" traefik_cn="$3" pangolin_cn="$4" gerbil_cn="$5"
    local cf_proxied=false ranges="" r

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
    if [[ -f "${CF_ENV_FILE}" ]] && grep -qE '^CF_PROXIED=true' "${CF_ENV_FILE}"; then
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
    crowdsecLapiKey: ${key}
    # AppSec (WAF): проверка каждого запроса
    crowdsecAppsecEnabled: true
    crowdsecAppsecHost: ${CROWDSEC_SERVICE}:7422
    crowdsecAppsecFailureBlock: true
    crowdsecAppsecUnreachableBlock: false # CrowdSec лёг → сайты работают без WAF, а не блокируются целиком
    crowdsecAppsecBodyLimit: 10485760
    clientTrustedIPs:
      - 10.0.0.0/8
      - 172.16.0.0/12
      - 192.168.0.0/16
EOF
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
    copytruncate
}
EOF
    log OK "Ротация access-лога: ${TRAEFIK_LOGROTATE_FILE} (ежедневно, 7 архивов)"
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

# Восстановить три файла из .bak текущей операции
cs_restore_files() {
    local f ok=0
    for f in "${COMPOSE_FILE}" "${TRAEFIK_CONFIG}" "${TRAEFIK_DYNAMIC_CONFIG}"; do
        if [[ -f "${f}.bak.${DATE_SUFFIX}" ]]; then
            cp "${f}.bak.${DATE_SUFFIX}" "${f}"
        else
            log ERROR "Нет резервной копии ${f}.bak.${DATE_SUFFIX}"
            ok=1
        fi
    done
    return "${ok}"
}

cs_cleanup_tmp() {
    local tmp="${PANGOLIN_DIR}/${CS_TMP_REL}"
    [[ -d "${tmp}" ]] || return 0
    rm -f "${tmp}"/*.yml
    rmdir "${tmp}" 2>/dev/null || true
}

# ─── Применение установки (стек уже остановлен). Возвращает 0/1 ──────────────
crowdsec_install_apply() {
    local tmp="${PANGOLIN_DIR}/${CS_TMP_REL}" key cid t
    local rc_compose rc_traefik rc_dynamic
    rc_compose=$(rel_path "${COMPOSE_FILE}")
    rc_traefik=$(rel_path "${TRAEFIK_CONFIG}")
    rc_dynamic=$(rel_path "${TRAEFIK_DYNAMIC_CONFIG}")

    log INFO "[Установка] Каталоги и источники событий CrowdSec..."
    mkdir -p "${PANGOLIN_DIR}/config/crowdsec/db" "${PANGOLIN_DIR}/config/traefik/logs" "${tmp}"
    [[ "${CROWDSEC_INSTALL_MANAGER}" == true ]] && \
        mkdir -p "${PANGOLIN_DIR}/crowdsec-manager/data" "${PANGOLIN_DIR}/crowdsec-manager/backups"
    cs_write_acquis

    key=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-48)
    cs_write_fragments "${tmp}" "${key}" "${CS_TRAEFIK_CN}" "${CS_PANGOLIN_CN}" "${CS_GERBIL_CN}"

    # ── docker-compose.yml ──
    log INFO "[Установка] docker-compose.yml: сервисы ${CROWDSEC_SERVICE}$([[ "${CROWDSEC_INSTALL_MANAGER}" == true ]] && echo ", crowdsec-manager"), дополнения к traefik..."
    YQ_ENV=(-e "S=${CROWDSEC_SERVICE}" -e "V=${CS_TRAEFIK_LOG_VOLUME}" -e "NS=${CS_NET_SOURCE}")
    yqd -i ".services[strenv(S)] = load(\"${CS_TMP_REL}/crowdsec.yml\")" "${rc_compose}" >> "${LOG_FILE}" 2>&1 || return 1
    if [[ "${CROWDSEC_INSTALL_MANAGER}" == true ]]; then
        yqd -i ".services[\"crowdsec-manager\"] = load(\"${CS_TMP_REL}/manager.yml\")" "${rc_compose}" >> "${LOG_FILE}" 2>&1 || return 1
    fi
    # Те же сети, что у gerbil (если сети заданы явно), — иначе Traefik не найдёт crowdsec
    if [[ -n "${CS_NET_SOURCE}" && "$(yqd '.services[strenv(NS)].networks == null' "${rc_compose}")" == "false" ]]; then
        yqd -i '.services[strenv(S)].networks = .services[strenv(NS)].networks' "${rc_compose}" >> "${LOG_FILE}" 2>&1 || return 1
        if [[ "${CROWDSEC_INSTALL_MANAGER}" == true ]]; then
            yqd -i '.services["crowdsec-manager"].networks = .services[strenv(NS)].networks' "${rc_compose}" >> "${LOG_FILE}" 2>&1 || return 1
        fi
    fi
    if [[ "$(yqd '[.services.traefik.volumes[]? | select(. == strenv(V))] | length' "${rc_compose}")" == "0" ]]; then
        yqd -i '.services.traefik.volumes += [strenv(V)]' "${rc_compose}" >> "${LOG_FILE}" 2>&1 || return 1
    fi
    t=$(yqd '.services.traefik.depends_on | type' "${rc_compose}")
    if [[ "${t}" == "!!seq" ]]; then
        yqd -i '.services.traefik.depends_on += [strenv(S)]' "${rc_compose}" >> "${LOG_FILE}" 2>&1 || return 1
    else
        yqd -i '.services.traefik.depends_on[strenv(S)].condition = "service_healthy"' "${rc_compose}" >> "${LOG_FILE}" 2>&1 || return 1
    fi
    if ! docker compose config -q >> "${LOG_FILE}" 2>&1; then
        log ERROR "[Установка] docker-compose.yml после изменений не проходит проверку (docker compose config)"
        return 1
    fi

    # ── traefik_config.yml ──
    log INFO "[Установка] traefik_config.yml: плагин bouncer ${CROWDSEC_BOUNCER_VERSION}, access-лог, middleware на entrypoint ${CROWDSEC_ENTRYPOINT}..."
    YQ_ENV=(-e "M=${CROWDSEC_BOUNCER_MODULE}" -e "BV=${CROWDSEC_BOUNCER_VERSION}" -e "EP=${CROWDSEC_ENTRYPOINT}" -e "AL=${CS_ACCESS_LOG}")
    yqd -i '.experimental.plugins.crowdsec.moduleName = strenv(M) | .experimental.plugins.crowdsec.version = strenv(BV)' \
        "${rc_traefik}" >> "${LOG_FILE}" 2>&1 || return 1
    t=$(yqd '.accessLog.filePath // ""' "${rc_traefik}")
    if [[ "$(yqd '.accessLog == null' "${rc_traefik}")" == "true" ]]; then
        yqd -i ".accessLog = load(\"${CS_TMP_REL}/accesslog.yml\")" "${rc_traefik}" >> "${LOG_FILE}" 2>&1 || return 1
    elif [[ "${t}" != "${CS_ACCESS_LOG}" ]]; then
        log WARN "[Установка] accessLog уже настроен (filePath='${t:-stdout}') — перенаправляю в ${CS_ACCESS_LOG} (JSON) для CrowdSec"
        yqd -i '.accessLog.filePath = strenv(AL) | .accessLog.format = "json"' "${rc_traefik}" >> "${LOG_FILE}" 2>&1 || return 1
    fi
    if [[ "$(yqd '[.entryPoints[strenv(EP)].http.middlewares[]? | select(. == "crowdsec@file")] | length' "${rc_traefik}")" == "0" ]]; then
        yqd -i '.entryPoints[strenv(EP)].http.middlewares += ["crowdsec@file"]' "${rc_traefik}" >> "${LOG_FILE}" 2>&1 || return 1
    fi

    # ── dynamic_config.yml ──
    log INFO "[Установка] dynamic_config.yml: middleware crowdsec (ключ bouncer сгенерирован)..."
    YQ_ENV=()
    yqd -i ".http.middlewares.crowdsec = load(\"${CS_TMP_REL}/middleware.yml\")" "${rc_dynamic}" >> "${LOG_FILE}" 2>&1 || return 1
    cs_cleanup_tmp

    # ── Запуск CrowdSec и регистрация bouncer ──
    log INFO "[Установка] Запуск CrowdSec (первый старт загружает правила из Hub, до 3 мин)..."
    docker compose up -d "${CROWDSEC_SERVICE}" >> "${LOG_FILE}" 2>&1 || return 1
    if ! cs_wait_ready; then
        log ERROR "[Установка] CrowdSec не ответил за 3 минуты"
        cid=$(crowdsec_cid); [[ -n "${cid}" ]] && docker logs --tail=30 "${cid}" >> "${LOG_FILE}" 2>&1
        return 1
    fi
    cid=$(crowdsec_cid)
    log OK "[Установка] CrowdSec запущен"
    docker exec "${cid}" cscli bouncers delete "${CROWDSEC_BOUNCER_NAME}" >/dev/null 2>&1 || true
    # вывод не пишем в лог — в нём ключ
    if ! docker exec "${cid}" cscli bouncers add "${CROWDSEC_BOUNCER_NAME}" -k "${key}" >/dev/null 2>&1; then
        log ERROR "[Установка] Не удалось зарегистрировать bouncer '${CROWDSEC_BOUNCER_NAME}'"
        return 1
    fi
    log OK "[Установка] Bouncer '${CROWDSEC_BOUNCER_NAME}' зарегистрирован"

    # ── Запуск всего стека и проверка ──
    log INFO "[Установка] Запуск всего стека..."
    STACK_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    docker compose up -d >> "${LOG_FILE}" 2>&1 \
        || log ERROR "[Установка] docker compose up завершился с ошибкой — проверка состояния покажет детали"
    health_check || return 1
    return 0
}

crowdsec_install_rollback() {
    log WARN "┌──────────────────────────────────────────────────────────┐"
    log WARN "│   ОТКАТ УСТАНОВКИ CROWDSEC: возврат к прежним конфигам   │"
    log WARN "└──────────────────────────────────────────────────────────┘"
    dump_failed_logs
    docker compose down --remove-orphans >> "${LOG_FILE}" 2>&1 || true
    cs_cleanup_tmp
    if ! cs_restore_files; then
        log ERROR "[Откат] Не удалось восстановить конфиги — восстановите из *.bak.${DATE_SUFFIX} или -restore"
        return 1
    fi
    log OK "[Откат] docker-compose.yml, traefik_config.yml, dynamic_config.yml восстановлены"
    STACK_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    docker compose up -d --remove-orphans >> "${LOG_FILE}" 2>&1 || true
    if health_check; then
        log OK "[Откат] Стек работает как до установки. Данные CrowdSec оставлены в config/crowdsec"
        return 0
    fi
    log ERROR "[Откат] Стек нездоров и после отката — используйте -restore (бэкап сделан перед установкой)"
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

    dash=$(sed -nE 's/^[[:space:]]*dashboard_url:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' \
        "${PANGOLIN_DIR}/config/config.yml" 2>/dev/null | head -n1 || true)
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
    local f rc_compose rc_traefik fname fdir traefik_tag
    log INFO "Установка CrowdSec + AppSec$([[ "${CROWDSEC_INSTALL_MANAGER}" == true ]] && echo " + crowdsec-manager") в Pangolin (${PANGOLIN_DIR})"

    # ── 1. Проверки: стек пока работает, ничего не меняется ──
    for f in "${COMPOSE_FILE}" "${TRAEFIK_CONFIG}" "${TRAEFIK_DYNAMIC_CONFIG}"; do
        if [[ ! -f "${f}" ]]; then
            log ERROR "Файл не найден: ${f}"; exit 1
        fi
        if [[ "${f}" != "${PANGOLIN_DIR}"/* ]]; then
            log ERROR "Файл должен находиться внутри ${PANGOLIN_DIR}: ${f}"; exit 1
        fi
    done
    rc_compose=$(rel_path "${COMPOSE_FILE}")
    rc_traefik=$(rel_path "${TRAEFIK_CONFIG}")

    log INFO "Подготовка утилиты yq (${YQ_IMAGE})..."
    if ! docker pull -q "${YQ_IMAGE}" >> "${LOG_FILE}" 2>&1; then
        log ERROR "Не удалось скачать образ ${YQ_IMAGE}"; exit 1
    fi
    if ! yqd '.services | length' "${rc_compose}" >> "${LOG_FILE}" 2>&1; then
        log ERROR "yq не может прочитать ${COMPOSE_FILE} — подробности в ${LOG_FILE}"; exit 1
    fi
    if ! docker compose config -q >> "${LOG_FILE}" 2>&1; then
        log ERROR "Текущий docker-compose.yml не проходит проверку (docker compose config) — исправьте его до установки"; exit 1
    fi

    YQ_ENV=(-e "S=${CROWDSEC_SERVICE}")
    if [[ "$(yqd '.services | has(strenv(S))' "${rc_compose}")" == "true" ]]; then
        log INFO "Сервис '${CROWDSEC_SERVICE}' уже есть в docker-compose.yml — CrowdSec установлен."
        log INFO "Переустановка: $(basename "$0") -crowdsec-uninstall, затем -crowdsec-install"
        exit 0
    fi
    if [[ "$(yqd '.services | has("traefik")' "${rc_compose}")" != "true" ]]; then
        log ERROR "В docker-compose.yml нет сервиса traefik"; exit 1
    fi
    CS_NET_SOURCE=""
    if [[ "$(yqd '.services | has("gerbil")' "${rc_compose}")" == "true" ]]; then
        CS_NET_SOURCE="gerbil"
    elif [[ "$(yqd '.services | has("pangolin")' "${rc_compose}")" == "true" ]]; then
        CS_NET_SOURCE="pangolin"
    fi
    YQ_ENV=(-e "EP=${CROWDSEC_ENTRYPOINT}")
    if [[ "$(yqd '.entryPoints | has(strenv(EP))' "${rc_traefik}")" != "true" ]]; then
        log ERROR "В traefik_config.yml нет entrypoint '${CROWDSEC_ENTRYPOINT}' (параметр CROWDSEC_ENTRYPOINT)"; exit 1
    fi
    fname=$(yqd '.providers.file.filename // ""' "${rc_traefik}")
    fdir=$(yqd '.providers.file.directory // ""' "${rc_traefik}")
    if [[ -z "${fdir}" && "$(basename "${fname}")" != "$(basename "${TRAEFIK_DYNAMIC_CONFIG}")" ]]; then
        log ERROR "Traefik не читает $(basename "${TRAEFIK_DYNAMIC_CONFIG}") (providers.file.filename='${fname}') — проверьте TRAEFIK_DYNAMIC_CONFIG"
        exit 1
    fi
    if [[ -n "$(yqd '.log.filePath // ""' "${rc_traefik}")" ]]; then
        log WARN "В traefik_config.yml задан log.filePath: ошибки загрузки плагинов не видны в docker logs, и health check их не заметит"
    fi
    YQ_ENV=()
    for f in "${CROWDSEC_SERVICE}" crowdsec-manager; do
        [[ "${f}" == crowdsec-manager && "${CROWDSEC_INSTALL_MANAGER}" != true ]] && continue
        if docker ps -a --format '{{.Names}}' | grep -qx "${f}"; then
            log ERROR "Контейнер с именем '${f}' уже существует вне этого стека — удалите или переименуйте его"; exit 1
        fi
    done
    CS_TRAEFIK_CN=$(compose_container_name traefik)
    CS_PANGOLIN_CN=$(compose_container_name pangolin)
    CS_GERBIL_CN=$(compose_container_name gerbil)
    log OK "Проверки пройдены (traefik: ${CS_TRAEFIK_CN}, сети: как у ${CS_NET_SOURCE:-default})"

    # ── 2. Проба: загрузит ли текущий Traefik плагин bouncer ──
    traefik_tag=$(get_traefik_image_tag)
    if [[ -n "${traefik_tag}" ]]; then
        if ! PROBE_EXTRA_PLUGINS="crowdsec ${CROWDSEC_BOUNCER_MODULE} ${CROWDSEC_BOUNCER_VERSION}" \
                probe_badger "${traefik_tag}" "$(get_badger_version)"; then
            log ERROR "Traefik ${traefik_tag} не загружает плагин bouncer ${CROWDSEC_BOUNCER_VERSION} — установка отменена, стек не тронут"
            exit 1
        fi
    fi

    # ── 3. Образы заранее (стек ещё работает) ──
    log INFO "Скачивание образов CrowdSec$([[ "${CROWDSEC_INSTALL_MANAGER}" == true ]] && echo " и crowdsec-manager")..."
    docker pull -q "docker.io/crowdsecurity/crowdsec:${CROWDSEC_IMAGE_TAG}" >> "${LOG_FILE}" 2>&1 \
        || { log ERROR "Не удалось скачать crowdsecurity/crowdsec:${CROWDSEC_IMAGE_TAG}"; exit 1; }
    if [[ "${CROWDSEC_INSTALL_MANAGER}" == true ]]; then
        docker pull -q "${CROWDSEC_MANAGER_IMAGE}" >> "${LOG_FILE}" 2>&1 \
            || { log ERROR "Не удалось скачать ${CROWDSEC_MANAGER_IMAGE}"; exit 1; }
    fi
    log OK "Образы готовы"

    confirm "Стек Pangolin будет остановлен на 1–3 минуты (полный бэкап и установка). Продолжить?" \
        || { log INFO "Установка отменена"; exit 1; }

    # ── 4. Резервные копии ──
    DATE_SUFFIX=$(date +%d%m%Y_%H%M%S)
    for f in "${COMPOSE_FILE}" "${TRAEFIK_CONFIG}" "${TRAEFIK_DYNAMIC_CONFIG}"; do
        cp "${f}" "${f}.bak.${DATE_SUFFIX}"
    done
    log OK "Копии конфигов: *.bak.${DATE_SUFFIX}"
    log INFO "Остановка стека..."
    docker compose down >> "${LOG_FILE}" 2>&1
    create_backup_archive

    # ── 5. Установка с откатом при сбое ──
    local rc
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
        (( rc == 0 )) && exit 1
        exit 2
    fi

    # ── 6. Завершение ──
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
    log INFO "Удаление: $(basename "$0") -crowdsec-uninstall"
    log_separator
    exit 0
}

# ─── Режим -crowdsec-uninstall ───────────────────────────────────────────────
crowdsec_uninstall_apply() {
    local rc_compose rc_traefik rc_dynamic t
    rc_compose=$(rel_path "${COMPOSE_FILE}")
    rc_traefik=$(rel_path "${TRAEFIK_CONFIG}")
    rc_dynamic=$(rel_path "${TRAEFIK_DYNAMIC_CONFIG}")

    docker compose down --remove-orphans >> "${LOG_FILE}" 2>&1 || true

    YQ_ENV=(-e "S=${CROWDSEC_SERVICE}")
    yqd -i 'del(.services[strenv(S)]) | del(.services["crowdsec-manager"])' "${rc_compose}" >> "${LOG_FILE}" 2>&1 || return 1
    # volume с логами у traefik не трогаем: в свежих установках Pangolin он есть изначально
    t=$(yqd '.services.traefik.depends_on | type' "${rc_compose}")
    if [[ "${t}" == "!!seq" ]]; then
        yqd -i 'del(.services.traefik.depends_on[] | select(. == strenv(S)))' "${rc_compose}" >> "${LOG_FILE}" 2>&1 || return 1
    elif [[ "${t}" == "!!map" ]]; then
        yqd -i 'del(.services.traefik.depends_on[strenv(S)])' "${rc_compose}" >> "${LOG_FILE}" 2>&1 || return 1
    fi
    docker compose config -q >> "${LOG_FILE}" 2>&1 || return 1

    YQ_ENV=(-e "AL=${CS_ACCESS_LOG}")
    yqd -i 'del(.experimental.plugins.crowdsec)
            | del(.entryPoints[].http.middlewares[] | select(. == "crowdsec@file"))
            | del(.entryPoints[].http.middlewares | select(length == 0))
            | del(.accessLog | select(.filePath == strenv(AL)))' "${rc_traefik}" >> "${LOG_FILE}" 2>&1 || return 1
    YQ_ENV=()
    yqd -i 'del(.http.middlewares.crowdsec)' "${rc_dynamic}" >> "${LOG_FILE}" 2>&1 || return 1

    STACK_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    docker compose up -d --remove-orphans >> "${LOG_FILE}" 2>&1 \
        || log ERROR "docker compose up завершился с ошибкой — проверка состояния покажет детали"
    health_check || return 1
    return 0
}

crowdsec_uninstall() {
    local f rc
    for f in "${COMPOSE_FILE}" "${TRAEFIK_CONFIG}" "${TRAEFIK_DYNAMIC_CONFIG}"; do
        [[ -f "${f}" ]] || { log ERROR "Файл не найден: ${f}"; exit 1; }
    done
    docker pull -q "${YQ_IMAGE}" >> "${LOG_FILE}" 2>&1 || { log ERROR "Не удалось скачать ${YQ_IMAGE}"; exit 1; }
    yqd '.services | length' "$(rel_path "${COMPOSE_FILE}")" >> "${LOG_FILE}" 2>&1 \
        || { log ERROR "yq не может прочитать ${COMPOSE_FILE} — подробности в ${LOG_FILE}"; exit 1; }
    YQ_ENV=(-e "S=${CROWDSEC_SERVICE}")
    if [[ "$(yqd '.services | has(strenv(S))' "$(rel_path "${COMPOSE_FILE}")")" != "true" ]]; then
        YQ_ENV=()
        log INFO "CrowdSec не установлен (нет сервиса '${CROWDSEC_SERVICE}' в docker-compose.yml)"
        exit 0
    fi
    YQ_ENV=()
    log WARN "CrowdSec, AppSec и crowdsec-manager будут удалены из стека; Traefik вернётся к работе без них."
    log INFO "Данные (config/crowdsec, crowdsec-manager/) остаются на диске."
    confirm "Стек будет перезапущен. Продолжить?" || { log INFO "Отменено"; exit 1; }

    DATE_SUFFIX=$(date +%d%m%Y_%H%M%S)
    for f in "${COMPOSE_FILE}" "${TRAEFIK_CONFIG}" "${TRAEFIK_DYNAMIC_CONFIG}"; do
        cp "${f}" "${f}.bak.${DATE_SUFFIX}"
    done
    log OK "Копии конфигов: *.bak.${DATE_SUFFIX}"

    set +e
    crowdsec_uninstall_apply
    rc=$?
    set -e
    if (( rc != 0 )); then
        log ERROR "Удаление не удалось — возвращаю прежние конфиги"
        docker compose down --remove-orphans >> "${LOG_FILE}" 2>&1 || true
        cs_restore_files || true
        STACK_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        docker compose up -d >> "${LOG_FILE}" 2>&1 || true
        set +e; health_check; rc=$?; set -e
        (( rc == 0 )) && { log OK "Стек работает с CrowdSec, как до попытки удаления"; exit 1; }
        log ERROR "Стек нездоров — используйте -restore"
        exit 2
    fi

    rm -f "${ALLOWLIST_CRON_FILE}" "${TRAEFIK_LOGROTATE_FILE}"
    log OK "CrowdSec удалён из стека, cron-задача allowlist и ротация access-лога убраны"
    log INFO "Удалить данные окончательно: rm -r ${PANGOLIN_DIR}/config/crowdsec ${PANGOLIN_DIR}/crowdsec-manager"
    log_separator
    exit 0
}

# ─── Справка по использованию ────────────────────────────────────────────────
usage() {
    cat <<EOF
Использование: $(basename "$0") [ОПЦИЯ]

Без опций       Полный цикл: проверка версий и, при наличии обновлений,
                обновление стека с health-check и автоматическим откатом.

Опции:
  -crowdsec-install, --crowdsec-install
                       Установить CrowdSec + AppSec (WAF) + веб-интерфейс
                       crowdsec-manager в работающий Pangolin. Всё автоматически:
                       проверки, бэкап, правка конфигов, запуск, проверка, откат
                       при сбое, allowlist сервера и сайтов Newt. Простой 1–3 мин.
  -no-manager          (с -crowdsec-install) без веб-интерфейса crowdsec-manager
  -crowdsec-uninstall, --crowdsec-uninstall
                       Удалить CrowdSec из стека (данные остаются на диске).
  -y, --yes            Не спрашивать подтверждение (для запуска без терминала).
  -info, --info        Только проверка и вывод таблицы «Сравнение версий».
                       Никаких действий не выполняется (dry-run): без резервных
                       копий, остановки стека, изменения конфигов, скачивания
                       и удаления образов.
  -enterprise, --ee    Использовать/переключиться на Enterprise Edition
                       (образ fosrl/pangolin:ee-*). Требует активации лицензии
                       вручную в панели Server Admin (/admin/license).
  -community, --ce     Использовать/вернуться на Community Edition
                       (образ fosrl/pangolin:*).
  -backup, --backup    Полная резервная копия стека (docker-compose.yml + config/:
                       БД, сертификаты, конфиги Traefik) в tar.gz-архив.
                       Стек кратко останавливается для консистентной копии БД.
  -restore [файл], --restore [файл]
                       Восстановление из архива. Без аргумента берётся самый
                       свежий архив из каталога резервных копий.
  -cloudflare [токен], --cf [токен]
                       Включить интеграцию с Cloudflare: автоматическое создание
                       A-записей в Cloudflare DNS для новых поддоменов (ресурсов)
                       Pangolin. Ставит cron-задачу синхронизации (-dns-sync).
                       Токен — аргументом или через переменную окружения
                       CLOUDFLARE_API_TOKEN (права Zone:Read + DNS:Edit).
  -cloudflare-off, --cf-off
                       Отключить интеграцию: убрать cron-задачу и файл настроек.
                       Уже созданные DNS-записи не удаляются.
  -dns-sync, --dns-sync
                       Разовая синхронизация DNS-записей (вызывается из cron,
                       можно запускать вручную). Добавляет только недостающие
                       записи, существующие не трогает.
  -crowdsec-hub, --crowdsec-hub
                       Только обновить правила CrowdSec из Hub (сценарии,
                       виртуальные патчи AppSec) без обновления стека. Обычный
                       запуск делает это автоматически.
  -allowlist-sync, --allowlist-sync
                       Синхронизировать allowlist CrowdSec: публичные IP сервера
                       и сайтов Newt (из БД Pangolin) + ALLOWLIST_EXTRA.
                       Устаревшие автоматические записи удаляются.
  -allowlist-on, --allowlist-on
                       Поставить cron-задачу синхронизации allowlist (каждые
                       ALLOWLIST_SYNC_INTERVAL мин) и сразу синхронизировать.
  -allowlist-off, --allowlist-off
                       Убрать cron-задачу (сам allowlist сохраняется).
  -h, --help           Показать эту справку.

Без флага редакции текущая редакция Pangolin определяется автоматически по
тегу образа в docker-compose.yml и сохраняется (безопасно для cron).
EOF
}

# ════════════════════════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════════════════════════

# ─── Разбор аргументов ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -info|--info)             INFO_ONLY=true; shift ;;
        -enterprise|--enterprise|--ee) EDITION_FLAG="ee"; shift ;;
        -community|--community|--ce)   EDITION_FLAG="ce"; shift ;;
        -backup|--backup)         ACTION="backup"; shift ;;
        -restore|--restore)
            ACTION="restore"
            if [[ $# -gt 1 && "${2}" != -* ]]; then RESTORE_FILE="$2"; shift; fi
            shift ;;
        -cloudflare|--cloudflare|--cf)
            ACTION="cf_on"
            if [[ $# -gt 1 && "${2}" != -* ]]; then CF_TOKEN="$2"; shift; fi
            shift ;;
        -cloudflare-off|--cloudflare-off|--cf-off) ACTION="cf_off"; shift ;;
        -dns-sync|--dns-sync)     ACTION="dns_sync"; shift ;;
        -crowdsec-hub|--crowdsec-hub) ACTION="crowdsec_hub"; shift ;;
        -allowlist-sync|--allowlist-sync) ACTION="allowlist_sync"; shift ;;
        -allowlist-on|--allowlist-on)     ACTION="allowlist_on"; shift ;;
        -allowlist-off|--allowlist-off)   ACTION="allowlist_off"; shift ;;
        -crowdsec-install|--crowdsec-install)     ACTION="crowdsec_install"; shift ;;
        -crowdsec-uninstall|--crowdsec-uninstall) ACTION="crowdsec_uninstall"; shift ;;
        -no-manager|--no-manager) CROWDSEC_INSTALL_MANAGER=false; shift ;;
        -y|--yes)                 ASSUME_YES=true; shift ;;
        -h|--help)                usage; exit 0 ;;
        *)                        echo "Неизвестный аргумент: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ "${INFO_ONLY}" == true ]]; then
    log_separator
    log INFO "Проверка версий Pangolin-стека (режим -info, изменения не вносятся)"
elif [[ "${ACTION}" == "dns_sync" || "${ACTION}" == "allowlist_sync" ]]; then
    # Частый тихий запуск из cron: без разделителя, ротация лога сохраняется
    rotate_log
elif [[ -n "${ACTION}" ]]; then
    rotate_log
    log_separator
else
    rotate_log
    log_separator
    log INFO "Запуск проверки обновлений Pangolin-стека"
fi

check_deps

# Lock нужен только для запусков, меняющих стек. Режимы -info и -dns-sync лишь
# читают данные: они не мешают идущему обновлению и не блокируются им
# (-dns-sync сам тихо откладывается, если главный lock занят).
if [[ "${INFO_ONLY}" == false && "${ACTION}" != "dns_sync" && "${ACTION}" != "allowlist_sync" ]]; then
    acquire_lock
fi

# При restore compose-файл может отсутствовать (разрушенная установка) —
# он будет восстановлен из архива.
if [[ ! -f "${COMPOSE_FILE}" && "${ACTION}" != "restore" ]]; then
    log ERROR "Файл не найден: ${COMPOSE_FILE}"
    exit 1
fi

# ─── Сервисные действия: backup / restore / cloudflare ───────────────────────
# Каждая функция завершает работу самостоятельно (exit).
if [[ -n "${ACTION}" ]]; then
    mkdir -p "${PANGOLIN_DIR}"
    cd "${PANGOLIN_DIR}"
    case "${ACTION}" in
        backup)   do_backup ;;
        restore)  do_restore "${RESTORE_FILE}" ;;
        cf_on)    cf_enable "${CF_TOKEN}" ;;
        cf_off)   cf_disable ;;
        dns_sync) do_dns_sync ;;
        crowdsec_hub)
            if [[ -z "$(docker compose ps -q "${CROWDSEC_SERVICE}" 2>/dev/null || true)" ]]; then
                log ERROR "Сервис '${CROWDSEC_SERVICE}' не найден в стеке или не запущен"
                exit 1
            fi
            CROWDSEC_HUB_UPDATE=true
            crowdsec_hub_update && { log_separator; exit 0; } || exit 3 ;;
        allowlist_sync) do_allowlist_sync ;;
        allowlist_on)   allowlist_enable ;;
        allowlist_off)  allowlist_disable ;;
        crowdsec_install)   crowdsec_install ;;
        crowdsec_uninstall) crowdsec_uninstall ;;
    esac
fi

# Получаем текущие версии
log INFO "Чтение текущих версий из конфигурации..."
read_current_versions

# ─── Определение редакции Pangolin (Community / Enterprise) ──────────────────
# Текущая редакция — по тегу образа: ee-* => Enterprise, иначе Community.
CURRENT_EDITION="ce"
[[ "${OLD_PANGOLIN_V}" == ee-* ]] && CURRENT_EDITION="ee"

# Целевая редакция: явный флаг важнее, иначе сохраняем текущую (безопасно для cron).
case "${EDITION_FLAG}" in
    ee) ENTERPRISE=true  ;;
    ce) ENTERPRISE=false ;;
    *)  [[ "${CURRENT_EDITION}" == "ee" ]] && ENTERPRISE=true || ENTERPRISE=false ;;
esac

if [[ "${ENTERPRISE}" == true ]]; then
    log INFO "Редакция Pangolin: Enterprise (образ fosrl/pangolin:ee-*)"
else
    log INFO "Редакция Pangolin: Community (образ fosrl/pangolin:*)"
fi

# Фиксируем факт смены редакции (для предупреждений и напоминания о лицензии).
if { [[ "${ENTERPRISE}" == true  ]] && [[ "${CURRENT_EDITION}" == "ce" ]]; } || \
   { [[ "${ENTERPRISE}" == false ]] && [[ "${CURRENT_EDITION}" == "ee" ]]; }; then
    EDITION_SWITCH=true
    EDITION_TO=$([[ "${ENTERPRISE}" == true ]] && echo "Enterprise" || echo "Community")
    log WARN "Смена редакции Pangolin: $([[ ${CURRENT_EDITION} == ee ]] && echo Enterprise || echo Community) -> ${EDITION_TO}"
    log WARN "Перед сменой редакции рекомендуется сделать резервную копию БД (редакции используют общую схему, но это страховка)."
fi

# Определяем мажорную ветку Traefik из текущей версии (защита от перехода на v2/v4)
TRAEFIK_MAJOR=$(echo "${OLD_TRAEFIK_V}" | sed -E 's/^v?([0-9]+).*/\1/')

# Получаем актуальные версии
log INFO "Запрос актуальных версий..."
PANGOLIN_GH_V=$(get_github_latest "fosrl/pangolin")     # GitHub-релиз (vX.Y.Z)
PANGOLIN_V=$(pangolin_image_tag "${PANGOLIN_GH_V}")     # тег образа нужной редакции
GERBIL_V=$(get_github_latest "fosrl/gerbil")
TRAEFIK_V=$(get_traefik_latest "${TRAEFIK_MAJOR}")
BADGER_LATEST=$(get_github_latest "fosrl/badger")
BADGER_V="${BADGER_LATEST}"
if [[ -n "${BADGER_PIN}" ]]; then
    BADGER_V="${BADGER_PIN}"
    log INFO "Badger закреплён на ${BADGER_PIN} (BADGER_PIN); последний релиз: ${BADGER_LATEST}"
fi
CROWDSEC_V="${OLD_CROWDSEC_V}"
if [[ -n "${OLD_CROWDSEC_V}" && "${CROWDSEC_AUTO_UPDATE}" == true ]]; then
    CROWDSEC_V=$(resolve_crowdsec_target "${OLD_CROWDSEC_V}")
fi

# Выводим таблицу версий
log INFO "Сравнение версий:"
print_versions

# Проверка необходимости обновления
if nothing_to_update; then
    log INFO "Все компоненты актуальны, обновление не требуется."
    if [[ "${INFO_ONLY}" == false ]]; then
        post_run_crowdsec || exit 3
    fi
    exit 0
fi

# Есть обновления. В режиме -info на этом и останавливаемся — без действий.
if [[ "${INFO_ONLY}" == true ]]; then
    log INFO "Доступно обновление. Режим -info: действия не выполняются."
    if [[ "${BADGER_PROBE}" == true ]] && \
       [[ "${OLD_BADGER_V}" != "${BADGER_V}" || "${OLD_TRAEFIK_V}" != "${TRAEFIK_V}" ]]; then
        log INFO "При обновлении совместимость Traefik ${TRAEFIK_V} + Badger ${BADGER_V} будет проверена тестовым контейнером."
    fi
    exit 0
fi

# ─── Проба совместимости Traefik + Badger до остановки стека ─────────────────
# Если новая пара не работает, проблемный компонент остаётся на прежней версии,
# а остальные обновляются как обычно.
if [[ "${BADGER_PROBE}" == true ]] && \
   [[ "${OLD_BADGER_V}" != "${BADGER_V}" || "${OLD_TRAEFIK_V}" != "${TRAEFIK_V}" ]]; then
    if ! probe_badger "${TRAEFIK_V}" "${BADGER_V}"; then
        if [[ "${OLD_BADGER_V}" != "${BADGER_V}" ]]; then
            log WARN "Badger ${BADGER_V} не загружается — Badger остаётся на ${OLD_BADGER_V}"
            BADGER_V="${OLD_BADGER_V}"
            BADGER_HELD_BACK=true
            # Новый Traefik нужно проверить и со старым Badger
            if [[ "${OLD_TRAEFIK_V}" != "${TRAEFIK_V}" ]] && ! probe_badger "${TRAEFIK_V}" "${BADGER_V}"; then
                log WARN "Traefik ${TRAEFIK_V} не загружает и Badger ${BADGER_V} — Traefik остаётся на ${OLD_TRAEFIK_V}"
                TRAEFIK_V="${OLD_TRAEFIK_V}"
            fi
        else
            log WARN "Traefik ${TRAEFIK_V} не загружает Badger ${BADGER_V} — Traefik остаётся на ${OLD_TRAEFIK_V}"
            TRAEFIK_V="${OLD_TRAEFIK_V}"
        fi

        log INFO "Скорректированный план обновления:"
        print_versions

        if nothing_to_update; then
            log INFO "После пробы обновлять нечего — стек не трогаю. Повторная попытка при следующем запуске."
            post_run_crowdsec || exit 3
            exit 0
        fi
    fi
fi

# Создаём резервные копии
log INFO "Создание резервных копий конфигураций..."
DATE_SUFFIX=$(date +%d%m%Y_%H%M%S)
cp "${COMPOSE_FILE}"   "${COMPOSE_FILE}.bak.${DATE_SUFFIX}"
cp "${TRAEFIK_CONFIG}" "${TRAEFIK_CONFIG}.bak.${DATE_SUFFIX}"
log OK "Резервные копии созданы (суффикс: ${DATE_SUFFIX})"

# Останавливаем стек
log INFO "Остановка Docker-стека..."
cd "${PANGOLIN_DIR}"
docker compose down >> "${LOG_FILE}" 2>&1
log OK "Стек остановлен"

# Полная резервная копия перед обновлением (стек остановлен — БД консистентна)
create_backup_archive

# Обновляем версии в файлах
log INFO "Обновление версий в конфигурационных файлах..."
sed -i -E "s|(docker.io/fosrl/pangolin:)[^[:space:]]+|\1${PANGOLIN_V}|" "${COMPOSE_FILE}"
sed -i -E "s|(docker.io/fosrl/gerbil:)[^[:space:]]+|\1${GERBIL_V}|"    "${COMPOSE_FILE}"
sed -i -E "s|(docker.io/traefik:)[^[:space:]]+|\1${TRAEFIK_V}|"        "${COMPOSE_FILE}"
if [[ "${OLD_BADGER_V}" != "${BADGER_V}" ]]; then
    set_badger_version "${BADGER_V}"
fi
if [[ -n "${OLD_CROWDSEC_V}" && "${OLD_CROWDSEC_V}" != "${CROWDSEC_V}" ]]; then
    sed -i -E "s#(${CROWDSEC_IMAGE_RE})[^[:space:]\"']+#\1${CROWDSEC_V}#" "${COMPOSE_FILE}"
fi
log OK "Файлы конфигурации обновлены"

# Скачиваем новые образы
log INFO "Скачивание новых Docker-образов..."
set +e
docker compose pull >> "${LOG_FILE}" 2>&1
PULL_RESULT=$?
set -e
if (( PULL_RESULT != 0 )); then
    log ERROR "Не удалось скачать образы (проверьте, что тег '${PANGOLIN_V}' существует) — запускаем откат"
    set +e
    do_rollback
    ROLLBACK_RESULT=$?
    set -e
    if (( ROLLBACK_RESULT != 0 )); then
        log ERROR "КРИТИЧНО: откат после неудачного pull завершился с ошибкой."
        log ERROR "Резервные копии конфигураций: *.bak.${DATE_SUFFIX}"
        exit 2
    fi
    exit 1
fi
log OK "Образы скачаны"

# Запускаем стек с новыми версиями
log INFO "Запуск Docker-стека..."
STACK_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if docker compose up -d >> "${LOG_FILE}" 2>&1; then
    log OK "Стек запущен, начинаем проверку работоспособности..."
else
    # Например, сервис с depends_on: service_healthy не дождался зависимости.
    # Не выходим: health check увидит незапущенные контейнеры и запустит откат.
    log ERROR "docker compose up завершился с ошибкой — проверка состояния решит, нужен ли откат"
fi

# ── Health check — проверяем новые контейнеры ────────────────────────────────
# Отключаем errexit: отказ health check обрабатывается явно через откат
set +e
health_check
HEALTH_RESULT=$?

# Миграция Pangolin при первом запуске новой версии может сама переписать
# версию Badger в traefik_config.yml (так 1.25.x ставит v1.8.0). Traefik
# применит её только при следующем перезапуске — например, ночью после
# перезагрузки сервера. Проверяем это сейчас, под контролем скрипта.
FILE_BADGER_V=$(get_badger_version)
if (( HEALTH_RESULT == 0 )) && [[ -n "${FILE_BADGER_V}" && "${FILE_BADGER_V}" != "${BADGER_V}" ]]; then
    log WARN "Версия Badger в traefik_config.yml изменена после запуска (вероятно, миграцией Pangolin): ${BADGER_V} -> ${FILE_BADGER_V}"
    log WARN "Перезапускаю Traefik, чтобы проверить новую версию сейчас, а не при случайном рестарте"
    STACK_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    docker compose restart traefik >> "${LOG_FILE}" 2>&1
    health_check
    HEALTH_RESULT=$?
    (( HEALTH_RESULT == 0 )) && BADGER_V="${FILE_BADGER_V}"
fi

# Сломался только плагин, и версия Badger отличается от рабочей — откатываем
# только Badger, не трогая остальные обновлённые компоненты.
if (( HEALTH_RESULT == 3 )); then
    FILE_BADGER_V=$(get_badger_version)
    if [[ -n "${FILE_BADGER_V}" && "${FILE_BADGER_V}" != "${OLD_BADGER_V}" ]]; then
        badger_rollback "${FILE_BADGER_V}"
        HEALTH_RESULT=$?
    fi
fi
set -e

if (( HEALTH_RESULT != 0 )); then
    log ERROR "Новые версии не прошли проверку работоспособности — запускаем откат"

    set +e
    do_rollback
    ROLLBACK_RESULT=$?
    set -e

    if (( ROLLBACK_RESULT != 0 )); then
        log ERROR "КРИТИЧНО: Откат завершился с ошибкой. Стек может быть нестабилен."
        log ERROR "Резервные копии конфигураций: *.bak.${DATE_SUFFIX}"
        exit 2
    fi

    exit 1
fi

# ── Только после успешного health check удаляем устаревшие образы ────────────
log INFO "Удаление устаревших Docker-образов..."
docker image prune -a -f >> "${LOG_FILE}" 2>&1
log OK "Устаревшие образы удалены"

log OK "Обновление успешно завершено"

if [[ "${BADGER_HELD_BACK}" == true ]]; then
    log WARN "Badger оставлен на ${BADGER_V}: новая версия не загружается в Traefik."
    log WARN "Скрипт попробует снова при следующем запуске. Закрепить версию вручную: BADGER_PIN=\"${BADGER_V}\""
fi

# Напоминание об активации лицензии при переходе на Enterprise Edition
if [[ "${EDITION_SWITCH}" == true && "${ENTERPRISE}" == true ]]; then
    log INFO "Переключено на Enterprise Edition. Активируйте лицензионный ключ"
    log INFO "в панели Server Admin: /admin/license (без ключа EE-функции останутся выключенными)."
fi

# Правила CrowdSec и allowlist — после обновления стека (контейнер уже работает)
HUB_RESULT=0
post_run_crowdsec || HUB_RESULT=$?

log_separator
(( HUB_RESULT != 0 )) && exit 3
exit 0
