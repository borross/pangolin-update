#!/bin/bash
# ver. 0.5 (19.07.2026)
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
        log ERROR "Не удалось получить версию для репозитория: ${repo}"
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
        log WARN "Traefik: latest вернул '${version}', ищу последнюю версию ветки v${major}"
        version=$(curl -sf --max-time 10 \
            "https://api.github.com/repos/traefik/traefik/releases?per_page=100" \
            | jq -r '.[] | select(.prerelease==false and .draft==false) | .tag_name' \
            | grep -E "^v${major}\.[0-9]+\.[0-9]+$" \
            | sort -V \
            | tail -n1)
    fi

    if [[ -z "${version}" || "${version}" == "null" ]]; then
        log ERROR "Не удалось получить версию Traefik v${major}"
        exit 1
    fi
    echo "${version}"
}

# ─── Чтение текущих версий из файлов конфигурации ───────────────────────────
read_current_versions() {
    OLD_PANGOLIN_V=$(grep "image: docker.io/fosrl/pangolin" "${COMPOSE_FILE}" | cut -d: -f3)
    OLD_GERBIL_V=$(grep "image: docker.io/fosrl/gerbil"    "${COMPOSE_FILE}" | cut -d: -f3)
    OLD_TRAEFIK_V=$(grep "image: docker.io/traefik"        "${COMPOSE_FILE}" | cut -d: -f3)
    OLD_BADGER_V=$(grep -A5 '^[[:space:]]*badger:' "${TRAEFIK_CONFIG}" \
        | awk '/version:/ { v=$2; gsub(/"/, "", v); print v; exit }')

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
# Возвращает: 0 — стек здоров, 1 — стек нездоров
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
            log OK "Health check пройден: все контейнеры работают корректно"
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
    tar czf "${archive}" --exclude='*.bak.*' -C "${PANGOLIN_DIR}" docker-compose.yml config
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
    docker compose up -d >> "${LOG_FILE}" 2>&1
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
    docker compose up -d >> "${LOG_FILE}" 2>&1

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

# ─── Справка по использованию ────────────────────────────────────────────────
usage() {
    cat <<EOF
Использование: $(basename "$0") [ОПЦИЯ]

Без опций       Полный цикл: проверка версий и, при наличии обновлений,
                обновление стека с health-check и автоматическим откатом.

Опции:
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
        -h|--help)                usage; exit 0 ;;
        *)                        echo "Неизвестный аргумент: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ "${INFO_ONLY}" == true ]]; then
    log_separator
    log INFO "Проверка версий Pangolin-стека (режим -info, изменения не вносятся)"
elif [[ "${ACTION}" == "dns_sync" ]]; then
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
if [[ "${INFO_ONLY}" == false && "${ACTION}" != "dns_sync" ]]; then
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
BADGER_V=$(get_github_latest "fosrl/badger")

# Выводим таблицу версий
log INFO "Сравнение версий:"
print_version_line "Pangolin" "${OLD_PANGOLIN_V}" "${PANGOLIN_V}"
print_version_line "Gerbil"   "${OLD_GERBIL_V}"   "${GERBIL_V}"
print_version_line "Traefik"  "${OLD_TRAEFIK_V}"  "${TRAEFIK_V}"
print_version_line "Badger"   "${OLD_BADGER_V}"   "${BADGER_V}"

# Проверка необходимости обновления
if [[ "${OLD_PANGOLIN_V}" == "${PANGOLIN_V}" &&
      "${OLD_GERBIL_V}"   == "${GERBIL_V}"   &&
      "${OLD_TRAEFIK_V}"  == "${TRAEFIK_V}"  &&
      "${OLD_BADGER_V}"   == "${BADGER_V}" ]]; then
    log INFO "Все компоненты актуальны, обновление не требуется."
    exit 0
fi

# Есть обновления. В режиме -info на этом и останавливаемся — без действий.
if [[ "${INFO_ONLY}" == true ]]; then
    log INFO "Доступно обновление. Режим -info: действия не выполняются."
    exit 0
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
sed -i -E "s|^([[:space:]]*version:[[:space:]]*)(\"?)[^\"[:space:]]+(\"?)|\1\2${BADGER_V}\3|" "${TRAEFIK_CONFIG}"
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
docker compose up -d >> "${LOG_FILE}" 2>&1
log OK "Стек запущен, начинаем проверку работоспособности..."

# ── Health check — проверяем новые контейнеры ────────────────────────────────
# Отключаем errexit: отказ health check обрабатывается явно через откат
set +e
health_check
HEALTH_RESULT=$?
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

# Напоминание об активации лицензии при переходе на Enterprise Edition
if [[ "${EDITION_SWITCH}" == true && "${ENTERPRISE}" == true ]]; then
    log INFO "Переключено на Enterprise Edition. Активируйте лицензионный ключ"
    log INFO "в панели Server Admin: /admin/license (без ключа EE-функции останутся выключенными)."
fi

log_separator
