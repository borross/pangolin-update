#!/bin/bash
# ver. 0.2 (09.04.2026)
# Pangolin stack auto-updater with logging and error handling

set -euo pipefail

# ─── Конфигурация ────────────────────────────────────────────────────────────
PANGOLIN_DIR="/root/pangolin"
COMPOSE_FILE="${PANGOLIN_DIR}/docker-compose.yml"
TRAEFIK_CONFIG="${PANGOLIN_DIR}/config/traefik/traefik_config.yml"
LOG_FILE="/var/log/pangolin-update.log"
LOCK_FILE="/tmp/pangolin-update.lock"
LOG_MAX_LINES=1000   # ротация лога при превышении

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

    # В файл — без цветов
    echo "${line}" >> "${LOG_FILE}"

    # В терминал — с цветами
    case "${level}" in
        INFO)  echo -e "${C_CYAN}${line}${C_RESET}" ;;
        OK)    echo -e "${C_GREEN}${line}${C_RESET}" ;;
        WARN)  echo -e "${C_YELLOW}${line}${C_RESET}" ;;
        ERROR) echo -e "${C_RED}${line}${C_RESET}" >&2 ;;
        *)     echo "${line}" ;;
    esac
}

log_separator() {
    local sep="$(printf '─%.0s' {1..60})"
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
    rm -f "${LOCK_FILE}"
    if (( exit_code != 0 )); then
        log ERROR "Скрипт завершился с ошибкой (код: ${exit_code})"
    fi
}
trap cleanup EXIT

# ─── Проверка зависимостей ────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in curl jq docker sed awk; do
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

# ─── Получение последней стабильной версии Traefik из Docker Hub ─────────────
get_traefik_latest() {
    local version
    version=$(curl -sf --max-time 10 \
        "https://registry.hub.docker.com/v2/repositories/library/traefik/tags?page_size=100" \
        | jq -r '.results[].name' \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -V \
        | tail -n1)
    if [[ -z "${version}" ]]; then
        log ERROR "Не удалось получить версию Traefik"
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
        | awk -F'"' '/version:/ { print $2 }')

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

# ════════════════════════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════════════════════════
rotate_log
log_separator
log INFO "Запуск проверки обновлений Pangolin-стека"

check_deps
acquire_lock

if [[ ! -f "${COMPOSE_FILE}" ]]; then
    log ERROR "Файл не найден: ${COMPOSE_FILE}"
    exit 1
fi

# Получаем текущие версии
log INFO "Чтение текущих версий из конфигурации..."
read_current_versions

# Получаем актуальные версии
log INFO "Запрос актуальных версий..."
PANGOLIN_V=$(get_github_latest "fosrl/pangolin")
GERBIL_V=$(get_github_latest "fosrl/gerbil")
TRAEFIK_V=$(get_traefik_latest)
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

# Обновляем версии в файлах
log INFO "Обновление версий в конфигурационных файлах..."
sed -i -E "s|(docker.io/fosrl/pangolin:)[^[:space:]]+|\1${PANGOLIN_V}|" "${COMPOSE_FILE}"
sed -i -E "s|(docker.io/fosrl/gerbil:)[^[:space:]]+|\1${GERBIL_V}|"    "${COMPOSE_FILE}"
sed -i -E "s|(docker.io/traefik:)[^[:space:]]+|\1${TRAEFIK_V}|"        "${COMPOSE_FILE}"
sed -i -E "s|(\s*version:)\s*\"[^\"]+\"|\1 \"${BADGER_V}\"|"           "${TRAEFIK_CONFIG}"
log OK "Файлы конфигурации обновлены"

# Скачиваем новые образы
log INFO "Скачивание новых Docker-образов..."
docker compose pull >> "${LOG_FILE}" 2>&1
log OK "Образы скачаны"

# Запускаем стек
log INFO "Запуск Docker-стека..."
docker compose up -d >> "${LOG_FILE}" 2>&1
log OK "Стек запущен"

# Удаляем устаревшие образы
log INFO "Удаление устаревших Docker-образов..."
docker image prune -a -f >> "${LOG_FILE}" 2>&1
log OK "Устаревшие образы удалены"

log OK "Обновление успешно завершено"
log_separator
