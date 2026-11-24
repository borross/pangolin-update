# pangolin-update.sh

**Версия:** 1.0 · **Дата:** 23.11.2026 · [История изменений](CHANGELOG.md)

Автообновление стека [Pangolin](https://github.com/fosrl/pangolin) (Pangolin, Gerbil, Traefik, плагин Badger, CrowdSec) с проверкой работоспособности и автоматическим откатом. Плюс резервное копирование, синхронизация DNS-записей Cloudflare и установка CrowdSec + AppSec одной командой.

> **English summary.** A Bash updater for self-hosted Pangolin stacks. It checks GitHub releases for Pangolin, Gerbil, Traefik, the Badger plugin and CrowdSec. It test-loads Traefik plugins in a throwaway container and pulls new images while the stack keeps running. Then it takes a consistent backup (online SQLite copy, no downtime) and updates the compose and Traefik files. Every container is verified, plus a real HTTP request through Traefik. On failure it rolls back automatically, including the Pangolin database. It also handles backup/restore, Cloudflare DNS sync, CrowdSec install and allowlists. Notifications go to ntfy, Telegram or a custom command. Settings live in `/etc/pangolin-update.conf`. Exit codes: 0 ok, 1 failed and restored, 2 needs manual action, 3 CrowdSec down, 4 nothing changed. Log messages are in Russian.

---

## Содержание

- [Быстрый старт](#быстрый-старт)
- [Как проходит обновление](#как-проходит-обновление)
- [Компоненты стека](#компоненты-стека)
- [Требования](#требования)
- [Установка](#установка)
- [Конфигурация](#конфигурация)
- [Использование](#использование)
- [Политика обновлений](#политика-обновлений)
- [Редакции: Community / Enterprise](#редакции-community--enterprise)
- [PostgreSQL-сборка Pangolin](#postgresql-сборка-pangolin)
- [Резервное копирование и восстановление](#резервное-копирование-и-восстановление)
- [Health check](#health-check)
- [Автоматический откат](#автоматический-откат)
- [Уведомления и мониторинг](#уведомления-и-мониторинг)
- [Интеграция с Cloudflare](#интеграция-с-cloudflare)
- [Защита плагина Badger](#защита-плагина-badger)
- [CrowdSec + AppSec](#crowdsec--appsec)
- [Логирование](#логирование)
- [Автоматизация: cron или systemd](#автоматизация-cron-или-systemd)
- [Коды выхода](#коды-выхода)
- [Структура файлов](#структура-файлов)
- [Разработка и тесты](#разработка-и-тесты)
- [Не входит в скрипт: установка и обновление Newt](#не-входит-в-скрипт-установка-и-обновление-newt)

---

## Быстрый старт

```bash
# 1. Скрипт
curl -fsSL -o /usr/local/bin/pangolin-update.sh \
  https://raw.githubusercontent.com/borross/pangolin-update/main/pangolin-update.sh
chmod 755 /usr/local/bin/pangolin-update.sh

# 2. Настройки (если стек не в /root/pangolin или нужны уведомления)
curl -fsSL -o /etc/pangolin-update.conf \
  https://raw.githubusercontent.com/borross/pangolin-update/main/pangolin-update.conf.example
chown root:root /etc/pangolin-update.conf && chmod 600 /etc/pangolin-update.conf
nano /etc/pangolin-update.conf

# 3. Что будет обновлено — без изменений
pangolin-update.sh --info
pangolin-update.sh --dry-run      # плюс diff файлов

# 4. Ночное обновление
echo '17 3 * * * root /usr/local/bin/pangolin-update.sh >/dev/null 2>&1' > /etc/cron.d/pangolin-update
```

> Для production лучше брать скрипт из тега релиза, а не из ветки `main`, и сверять контрольную сумму — см. [Установка](#установка).

---

## Как проходит обновление

Всё, что может сорваться (сеть, отсутствующий образ, несовместимый плагин), проверяется **до** изменений, пока стек работает. Простой — только пересоздание изменённых контейнеров.

| # | Шаг | Стек |
|---|-----|------|
| 1 | Чтение текущих версий; запрос релизов с GitHub; выбор целевых версий по [политике](#политика-обновлений) | работает |
| 2 | Проверка, что теги опубликованы в Docker Hub | работает |
| 3 | [Проба](#защита-плагина-badger): тестовый Traefik загружает все плагины с новыми версиями | работает |
| 4 | Скачивание новых образов. Не скачалось — выход с кодом 4, ничего не изменено | работает |
| 5 | Проверка свободного места; замер HTTP-ответа Traefik (база для проверки) | работает |
| 6 | Копии конфигов `*.bak.<дата>`; **полный архив** с online-копией БД | работает |
| 7 | Новые версии в `docker-compose.yml` и `traefik_config.yml` | работает |
| 8 | `docker compose up -d` — пересоздаются только изменённые контейнеры | краткий перезапуск |
| 9 | [Health check](#health-check): контейнеры, логи плагинов Traefik, HTTP-запрос | работает |
| 10 | Успех — удаление образов предыдущего обновления, правила CrowdSec Hub, allowlist, уведомление | работает |
| 10′ | Сбой — [откат](#автоматический-откат) конфигов и БД, уведомление | перезапуск |

Если работа прерывается между шагами 6 и 10 (ошибка, Ctrl-C, `kill`), обработчик выхода **сам возвращает стек в прежнее состояние**. Остановленным он не остаётся.

Для PostgreSQL-сборки и при `BACKUP_MODE=cold` на шаге 6 стек останавливается: это даёт консистентную копию. На шаге 8 он запускается целиком.

---

## Компоненты стека

| Компонент | Источник версий | Примечание |
|-----------|----------------|------------|
| **Pangolin** | GitHub Releases `fosrl/pangolin` | Редакция (`ee-`) и сборка (`postgresql-`) сохраняются |
| **Gerbil** | GitHub Releases `fosrl/gerbil` | |
| **Traefik** | GitHub Releases `traefik/traefik` | Только в пределах текущей мажорной ветки |
| **Badger** | GitHub Releases `fosrl/badger` | Плагин Traefik; можно закрепить `BADGER_PIN` |
| **CrowdSec** *(необязательный)* | GitHub Releases `crowdsecurity/crowdsec` | Учитывается, если сервис есть в compose и тег закреплён (`v1.8.1`, не `latest`) |

Плагин-bouncer CrowdSec и образ `crowdsec-manager` не обновляются автоматически. Bouncer при этом участвует в пробе Traefik.

**Версия Traefik.** Сначала запрашивается `/releases/latest`. Если он указывает на другую мажорную ветку (например, в день выхода патча v2.11.x), скрипт берёт последнюю стабильную версию **текущей** ветки из списка релизов.

Строки `image:` распознаются с префиксом `docker.io/` и без, в кавычках и без. Закомментированные строки и похожие репозитории (`traefik/whoami`) не затрагиваются. Если образ был закреплён по digest (`@sha256:…`), при обновлении digest заменяется новым тегом, и в лог пишется `WARN`.

---

## Требования

- **ОС:** Linux, **Bash 4.4+**
- **Права:** root. Скрипт пишет в `/etc/cron.d`, `/etc/logrotate.d`, `/var/log`, `/run`, `/var/lib`.
- **Docker Engine** с плагином **Compose v2** (команда `docker compose`)

| Утилита | Назначение |
|---------|-----------|
| `curl`, `jq` | GitHub API, Cloudflare API, разбор JSON |
| `docker` + `docker compose` | Управление стеком |
| `sed`, `awk` | Правка версий в YAML |
| `tar`, `gzip` | Резервные копии и их проверка |
| `flock` (util-linux) | Защита от параллельного запуска |
| `md5sum`, `stat`, `timeout` (coreutils) | Кэши, проверка прав, таймауты |
| `sqlite3` или `python3` *(желательно)* | Online-копия БД и чтение сайтов Newt. Без них используется Node.js внутри контейнера `pangolin` |

Debian/Ubuntu:

```bash
apt install curl jq tar gzip util-linux sqlite3
# Docker и Compose v2 — по инструкции docs.docker.com/engine/install
# (пакет docker.io из репозитория дистрибутива не везде включает docker compose v2)
```

---

## Установка

Скрипт — один файл. Рекомендуемый способ — из тега релиза, с проверкой контрольной суммы (её печатает CI, см. [Разработка и тесты](#разработка-и-тесты)):

```bash
VER=v1.0
curl -fsSL -o /tmp/pangolin-update.sh \
  "https://raw.githubusercontent.com/borross/pangolin-update/${VER}/pangolin-update.sh"
sha256sum /tmp/pangolin-update.sh      # сверить с опубликованной суммой
install -m 755 /tmp/pangolin-update.sh /usr/local/bin/pangolin-update.sh
```

Лог, каталог состояния и lock-файл создаются автоматически с нужными правами.

---

## Конфигурация

Все настройки — в **`/etc/pangolin-update.conf`**. Редактировать сам скрипт не нужно, поэтому обновление скрипта настройки не затирает. Образец со всеми параметрами и значениями по умолчанию — [`pangolin-update.conf.example`](pangolin-update.conf.example).

- Файл исполняется как Bash от root. Поэтому он принимается, только если **владелец — root** и **запись для группы и остальных запрещена**, иначе скрипт завершится с кодом 4. Рекомендуемые права — `600`, в файле могут быть токены.
- Приоритет: файл конфигурации > переменные окружения > встроенные значения.
- Другой путь к файлу: `PANGOLIN_UPDATE_CONF=/путь pangolin-update.sh`.

Основные параметры:

| Параметр | По умолчанию | Описание |
|----------|-------------|----------|
| `PANGOLIN_DIR` | `/root/pangolin` | Каталог стека; от него считаются остальные пути |
| `MIN_RELEASE_AGE_HOURS` | `24` | Не ставить релизы моложе N часов |
| `ALLOW_MAJOR_UPGRADE` | `false` | Разрешить переход на новую мажорную версию |
| `BACKUP_MODE` | `hot` | `hot` — копия без остановки стека; `cold` — с остановкой |
| `BACKUP_KEEP` | `7` | Сколько архивов и `*.bak.*` каждого конфига хранить |
| `PRUNE_MODE` | `previous` | Когда удалять старые образы: `previous`, `immediate`, `none` |
| `HEALTH_RETRIES` × `HEALTH_INTERVAL` | `15` × `10` с | Максимальное время проверки |
| `HEALTH_HTTP_CHECK` | `true` | HTTP-запрос через Traefik в проверке |
| `NOTIFY_ON` | `problems` | Когда уведомлять: `problems`, `all`, `none` |
| `GITHUB_TOKEN` | — | Необязательно: лимит GitHub API выше 60 запросов/час |

Полный список с комментариями — в образце.

---

## Использование

```bash
pangolin-update.sh [ОПЦИЯ]
```

| Опция | Действие |
|-------|----------|
| *(без опций)* | Полный цикл обновления |
| `--info` | Только таблица «текущая → целевая версия», ничего не меняется |
| `--dry-run` | Таблица + `diff` файлов + какие образы будут скачаны и какой будет бэкап |
| `--enterprise`, `--ee` / `--community`, `--ce` | Переключить редакцию Pangolin при обновлении |
| `--no-delay` | Не ждать `MIN_RELEASE_AGE_HOURS` (разовое срочное обновление) |
| `--hold [причина]` / `--unhold` | Приостановить / возобновить обновления |
| `--backup` | Полная резервная копия |
| `--restore [файл]` | Восстановление из архива (без аргумента — самый свежий) |
| `--cloudflare` / `--cloudflare-off` / `--dns-sync` | Интеграция с Cloudflare DNS |
| `--crowdsec-install [--with-manager]` / `--crowdsec-uninstall` | Установка / удаление CrowdSec + AppSec |
| `--crowdsec-hub` | Обновить правила CrowdSec Hub |
| `--allowlist-sync` / `--allowlist-on` / `--allowlist-off` | Allowlist CrowdSec для своей инфраструктуры |
| `-y`, `--yes` | Не спрашивать подтверждение |
| `--version`, `-h`/`--help` | Версия, справка |

Однодефисные формы (`-info`, `-backup`, …) по-прежнему работают.

**Несовместимые сочетания — ошибка, а не молчаливое выполнение.** `--info --backup`, два действия сразу или `--ee` вместе с `--backup` завершаются с кодом 4 и ничего не делают.

### Пример — `--dry-run`

```
[2026-11-23 03:00:01] [INFO] Сравнение версий:
  Pangolin     1.25.0                 -> 1.26.0
  Gerbil       1.3.0                  (без изменений)
  Traefik      v3.6.1                 -> v3.6.2
  Badger       v1.7.0                 (без изменений)
[2026-11-23 03:00:01] [INFO] Изменения, которые будут внесены:
--- a/docker-compose.yml
+++ b/docker-compose.yml
@@ -1,6 +1,6 @@
 services:
   pangolin:
-    image: docker.io/fosrl/pangolin:1.25.0
+    image: docker.io/fosrl/pangolin:1.26.0
...
[2026-11-23 03:00:01] [INFO] Образы будут скачаны до остановки стека: docker.io/fosrl/pangolin:1.26.0 docker.io/traefik:v3.6.2
[2026-11-23 03:00:01] [INFO] Резервная копия: горячая (без остановки)
```

### Пример — успешное обновление

```
[2026-11-23 03:00:04] [INFO] Скачивание новых образов (стек продолжает работать)...
[2026-11-23 03:00:31] [OK] Образы скачаны
[2026-11-23 03:00:31] [INFO] HTTP-проверка: https://pangolin.example.com → 200 (будет проверена и после изменений)
[2026-11-23 03:00:31] [OK] Копии конфигов: *.bak.20261123_030031
[2026-11-23 03:00:31] [INFO] Online-копия БД Pangolin (стек продолжает работать)...
[2026-11-23 03:00:32] [OK] Резервная копия создана: /root/pangolin-backups/pangolin_20261123_030031.tar.gz (3.1M, режим hot)
[2026-11-23 03:00:32] [INFO] Запуск стека на новых версиях...
[2026-11-23 03:00:38] [INFO] Проверка состояния стека (попытка 1/15)...
  ✗ pangolin                     состояние=running      здоровье=starting     перезапусков=0
[2026-11-23 03:00:48] [INFO] Проверка состояния стека (попытка 2/15)...
  ✓ pangolin                     состояние=running      здоровье=healthy      перезапусков=0
  ✓ gerbil                       состояние=running      здоровье=none         перезапусков=0
  ✓ traefik                      состояние=running      здоровье=none         перезапусков=0
[2026-11-23 03:00:48] [OK] HTTP-проверка: https://pangolin.example.com → 200
[2026-11-23 03:00:48] [OK] Health check пройден: контейнеры работают, плагины Traefik загружены
[2026-11-23 03:00:49] [OK] Обновление успешно завершено: Pangolin 1.25.0→1.26.0, Traefik v3.6.1→v3.6.2
```

---

## Политика обновлений

| Правило | Поведение | Настройка |
|---------|-----------|-----------|
| **Выдержка релиза** | Релиз ставится не раньше, чем через N часов после публикации: у разработчиков есть время отозвать неудачную версию. Пока срок не вышел, компонент остаётся на текущей версии, остальные обновляются | `MIN_RELEASE_AGE_HOURS=24`, разово — `--no-delay` |
| **Без понижения** | Версии сравниваются по номерам: установленный `1.27.0-rc.1` не «обновится» до `1.26.0` | — |
| **Мажорные версии** | Pangolin, Gerbil, Badger и CrowdSec не переходят на новую мажорную версию автоматически (`WARN` + одно уведомление). Traefik — всегда в своей ветке | `ALLOW_MAJOR_UPGRADE=true` |
| **Тег ещё не в Docker Hub** | Релиз на GitHub есть, а образа ещё нет — компонент ждёт следующего запуска (`INFO`, без ошибки) | — |
| **Пауза** | Обновления не выполняются; правила CrowdSec, allowlist и DNS продолжают работать | `--hold`, `--unhold`, `UPDATE_HOLD=true` |

---

## Редакции: Community / Enterprise

| Редакция | Тег образа `pangolin` | Лицензия |
|----------|----------------------|----------|
| **Community (CE)** | `fosrl/pangolin:X.Y.Z` | не требуется |
| **Enterprise (EE)** | `fosrl/pangolin:ee-X.Y.Z` | ключ активируется вручную в `/admin/license` |

- **Без флага** редакция определяется по текущему тегу (`ee-*` → Enterprise) и сохраняется. Флаг в cron-строке не нужен.
- **`--enterprise`** / **`--community`** переключают редакцию при ближайшем обновлении. Если версия не меняется, меняется только тег. Если нужного EE-тега нет в Docker Hub, скрипт сообщает об этом до каких-либо изменений (код 4).
- После перехода на EE скрипт напоминает активировать ключ в панели Server Admin. Подробности о лицензиях — в [документации Pangolin](https://docs.pangolin.net/self-host/enterprise-edition).

---

## PostgreSQL-сборка Pangolin

Теги `postgresql-X.Y.Z` и `ee-postgresql-X.Y.Z` поддерживаются: префикс сборки сохраняется при обновлении и при смене редакции. Суффиксы архитектуры (`-amd64`, `-arm64`) тоже сохраняются. Плавающие теги (`latest`, `postgresql-latest`, `1.26`) не поддерживаются — закрепите версию.

Ограничения при PostgreSQL:

- резервная копия делается **с остановкой стека**;
- архив содержит только то, что лежит в `PANGOLIN_DIR`. Если данные PostgreSQL хранятся в именованном томе Docker, делайте их бэкап отдельно (`pg_dump`);
- при откате БД **не восстанавливается** скриптом (`WARN` в логе);
- allowlist CrowdSec не читает сайты Newt — укажите их адреса в `ALLOWLIST_EXTRA`.

---

## Резервное копирование и восстановление

**Состав архива** (`BACKUP_DIR/pangolin_YYYYMMDD_HHMMSS.tar.gz`):

- `docker-compose.yml`;
- `config/` целиком: **БД Pangolin**, **сертификаты Let's Encrypt**, конфигурация Traefik и CrowdSec, `config.yml`;
- `.cf-dns.env` (настройки Cloudflare), если интеграция включена.

Не входят логи Traefik (`config/traefik/logs`) и `*.bak.*`.

Архив доступен только root (права `600`, каталог `700`) и проверяется (`gzip -t`) сразу после записи. До изменений проверяется свободное место: размер данных + `BACKUP_MIN_FREE_MB`. Хранятся последние `BACKUP_KEEP` архивов, очистка идёт по дате в имени, так что архивы со старым форматом имён тоже учитываются.

> В архиве приватные ключи сертификатов, секрет сервера и БД. Он лежит на том же диске, что и данные, поэтому храните копию вне сервера.

### Горячая и холодная копия

| | `BACKUP_MODE=hot` (по умолчанию) | `BACKUP_MODE=cold` |
|---|---|---|
| Стек | **работает** | останавливается на время архивирования |
| БД SQLite | online backup API (`sqlite3 .backup`, `python3` или better-sqlite3 в контейнере) — согласованная копия работающей базы | копируется файл остановленной базы |
| Когда используется | SQLite и есть чем снять копию | PostgreSQL; нет ни одного способа снять online-копию; явно задано |

### Команды

```bash
pangolin-update.sh --backup                       # копия (без простоя в режиме hot)
pangolin-update.sh --restore                      # из самого свежего архива
pangolin-update.sh --restore /root/pangolin-backups/pangolin_20261120_031702.tar.gz
pangolin-update.sh --restore -y                   # без вопроса (для скриптов)
```

Восстановление:

1. проверяет архив (`gzip -t`, `tar tzf`) и спрашивает подтверждение (без терминала нужен `-y`);
2. сохраняет **текущее** состояние в `pre-restore_<дата>.tar.gz` (автоматически не удаляется);
3. останавливает стек, удаляет WAL-файлы текущей БД и распаковывает архив;
4. скачивает образы версий из архива, если их нет локально, запускает стек и проходит health check.

> Восстановление возвращает БД к моменту бэкапа: ресурсы, пользователи и настройки, созданные позже, пропадут. Работает и на «разрушенной» установке без `docker-compose.yml`.

---

## Health check

Опрос начинается сразу после запуска (`HEALTH_INITIAL_WAIT`, 5 с). Он завершается, как только всё в порядке, или после `HEALTH_RETRIES` попыток с интервалом `HEALTH_INTERVAL`: по умолчанию до ~2,5 минуты. Все контейнеры стека читаются одним вызовом `docker inspect`.

| Проверка | Условие |
|----------|---------|
| Состояние | `running`. Одноразовый сервис, завершившийся с кодом 0 и без политики перезапуска, тоже считается нормой |
| Healthcheck | `healthy`. Состояние **`starting` — ещё не готов**, попытка повторяется |
| Без healthcheck | Контейнер работает не меньше `HEALTH_MIN_UPTIME` (15 с) — ловит падение через несколько секунд после старта |
| Перезапуски | Меньше `RESTART_THRESHOLD`. Учитываются только у контейнеров, перезапущенных в этом цикле — старые счётчики не мешают |
| Сервисы compose | У каждого активного сервиса есть контейнер |
| Плагины Traefik | В логах Traefik с момента запуска нет ошибок загрузки плагинов (см. [Защита плагина Badger](#защита-плагина-badger)) |
| **HTTP через Traefik** | Запрос к `dashboard_url` из `config/config.yml` (или `HEALTH_URL`), отправленный на `HEALTH_HTTP_RESOLVE_IP` (127.0.0.1), отвечает 2xx/3xx/401/403 |

HTTP-проверка включается, **только если адрес отвечал до изменений**. Иначе (порт привязан к другому IP, особая маршрутизация) в лог пишется `WARN`, и проверка пропускается: ложного отката не будет.

Сервисы из `HEALTH_IGNORE_SERVICES` (по умолчанию `crowdsec-manager`) попадают в лог как `WARN`, но откат не вызывают. При провале последние 50 строк логов проблемных контейнеров записываются в `LOG_FILE`.

---

## Автоматический откат

Запускается, если health check не пройден. Старые образы остаются в локальном кэше (удаляются только после успешного *следующего* обновления), поэтому откат не требует скачивания.

1. `docker compose down`.
2. `docker-compose.yml` и `traefik_config.yml` — из `*.bak.<дата>` (содержимое переписывается, inode сохраняется).
3. **Если менялась версия Pangolin** — БД и `config.yml` возвращаются из архива, снятого перед обновлением. Новая версия уже прогнала миграции, и старая на новой схеме могла бы не запуститься. Состояние после сбоя сохраняется в `BACKUP_DIR/failed_<дата>/` для разбора.
4. `docker compose up -d` и полный health check.

Если сломался только плагин (Badger), сначала выполняется **частичный откат** — только версия Badger и перезапуск Traefik.

**Прерывание.** Если скрипт прерван (ошибка, Ctrl-C, `kill`, `systemctl stop`) после начала изменений, обработчик выхода выполняет тот же откат. Для сервисных режимов он запускает остановленный стек или возвращает конфиги установки/удаления CrowdSec. Код выхода — 1, если восстановление удалось, иначе 2.

### Ручное восстановление (код 2)

```bash
cd /root/pangolin
ls -lt docker-compose.yml.bak.* /root/pangolin-backups/
# Вариант 1: полный архив, снятый перед обновлением
pangolin-update.sh --restore /root/pangolin-backups/pangolin_<дата>.tar.gz -y
# Вариант 2: только конфиги
cp docker-compose.yml.bak.<дата> docker-compose.yml
cp config/traefik/traefik_config.yml.bak.<дата> config/traefik/traefik_config.yml
docker compose up -d && docker compose ps
```

---

## Уведомления и мониторинг

| Параметр | Канал |
|----------|-------|
| `NOTIFY_URL` | [ntfy](https://ntfy.sh) или совместимый сервис: POST текста с заголовками `Title`, `Priority`, `Tags` |
| `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` | Telegram-бот |
| `NOTIFY_CMD` | Любая команда; получает переменные `PU_LEVEL`, `PU_EVENT`, `PU_MESSAGE`, `PU_HOST`, `PU_TITLE` |
| `HEARTBEAT_URL` | После каждого обычного запуска — запрос `<URL>/<код выхода>` (формат [healthchecks.io](https://healthchecks.io)): видно и сбой, и то, что задание вообще не запустилось |

`NOTIFY_ON=problems` (по умолчанию) — только предупреждения и ошибки; `all` — ещё и успешные обновления; `none` — ничего.

| Событие | Уровень |
|---------|---------|
| `update-ok` — обновлено (список изменений) | INFO |
| `badger-held-back`, `traefik-held-back` — компонент оставлен на прежней версии (один раз на версию) | WARN |
| `update-skipped` — ничего не изменено, код 4 (GitHub недоступен, образ не скачался…) | WARN |
| `rollback` — обновление откатено | ERROR |
| `critical` — откат не удался, нужно ручное вмешательство | ERROR |
| `crowdsec-down` — CrowdSec не отвечает после обновления правил | ERROR |
| `interrupted` — работа прервана, стек восстановлен | ERROR |
| `dns_sync-failed`, `allowlist_sync-failed` — ошибки cron-синхронизации (не чаще раза в сутки) | WARN |

Пример (`/etc/pangolin-update.conf`):

```bash
NOTIFY_URL="https://ntfy.sh/my-pangolin-7f3c"
HEARTBEAT_URL="https://hc-ping.com/1b2c3d4e-..."
```

Сбой отправки уведомления пишется в лог и на работу скрипта не влияет.

---

## Интеграция с Cloudflare

Когда в Pangolin появляется новый поддомен (ресурс), для него автоматически создаётся A-запись в Cloudflare DNS.

```
Pangolin (новый ресурс app.example.com)
        │  каждые CF_SYNC_INTERVAL минут (cron)
        ▼
pangolin-update.sh --dns-sync
        ├─► Список поддоменов ◄── /api/v1/traefik-config (запрос внутри контейнера pangolin)
        ├─► Ничего не изменилось с прошлого раза? ──► выход без запросов к Cloudflare
        └─► Cloudflare API: зоны — одним списком, записи — одним списком на зону
              ├─ записи нет                         ──► создать A → IP сервера
              ├─ своя запись, IP изменился          ──► обновить IP
              ├─ чужая/ручная запись (любого типа)  ──► не трогать
              └─ своя запись, ресурса больше нет    ──► удалить (если CF_DELETE_STALE=true)
```

«Своими» считаются только записи с комментарием `pangolin-update autosync`. Ручные записи скрипт не меняет и не удаляет. Полная сверка с Cloudflare делается не реже раза в `CF_FULL_RESYNC_MIN` минут, даже если ничего не менялось.

### Включение

Создайте токен в [dash.cloudflare.com → My Profile → API Tokens](https://dash.cloudflare.com/profile/api-tokens) с правами **Zone:Read** и **DNS:Edit**, затем:

```bash
CLOUDFLARE_API_TOKEN=<токен> pangolin-update.sh --cloudflare
```

Токен можно передать и аргументом (`--cloudflare <токен>`), но тогда он виден в списке процессов и истории shell — скрипт предупредит об этом.

Команда проверяет токен и определяет внешний IPv4 сервера: адрес принимается, только если его подтвердили два независимых сервиса. Затем она сохраняет `.cf-dns.env` (права 600), создаёт `/etc/cron.d/pangolin-cf-dns` и сразу выполняет первую синхронизацию.

### Параметры (`.cf-dns.env`)

| Параметр | Описание |
|----------|----------|
| `CF_TARGET_IP` | IP для A-записей. `auto` — каждый раз текущий внешний IPv4 (с кэшем `SERVER_IP_CACHE_MIN`). При смене адреса свои записи обновляются |
| `CF_PROXIED` | `true` — «оранжевое облако». Учтите [особенности Pangolin за Cloudflare-прокси](https://docs.pangolin.net/self-host/advanced/cloudflare-proxy) |
| `CF_DELETE_STALE` | `true` — удалять свои записи удалённых ресурсов. Запись удаляется, только если «осиротела» в двух синхронизациях подряд и список ресурсов не пуст (Pangolin при старте может кратко отдавать пустую конфигурацию) |

Файл читается построчно, а не исполняется. Если права шире 600 или владелец не root, синхронизация не запустится.

```bash
pangolin-update.sh --dns-sync         # вручную, с подробным итогом
pangolin-update.sh --cloudflare-off   # отключить (записи в Cloudflare остаются)
```

> Если используете wildcard-запись `*.example.com`, интеграция, скорее всего, не нужна.

---

## Защита плагина Badger

### Проблема

Badger — плагин Traefik, через который проходят все ресурсы Pangolin. Traefik скачивает его из `plugins.traefik.io` и проверяет целостность. Если проверка не прошла, Traefik пишет `Plugins are disabled because an error has occurred` и **работает без плагина**: контейнер `running`, а все ресурсы недоступны. Так было с Badger v1.8.0 (октябрь 2026), который к тому же прописывала миграция Pangolin 1.25.x.

### Четыре уровня защиты

| Уровень | Когда | Что делает |
|---------|-------|------------|
| **1. Проба** | до изменений | Одноразовый контейнер Traefik целевой версии загружает **все плагины** из `traefik_config.yml` (Badger — в целевой версии). Готовность — по ответу `/ping`, обычно за несколько секунд. Не загрузил — проблемный компонент остаётся на прежней версии, остальные обновляются. Не удалось проверить (нет сети, образ не скачался) — Traefik и Badger остаются на текущих версиях. Результат кэшируется на `PROBE_CACHE_HOURS` |
| **2. Логи в health check** | после запуска | Ошибки загрузки плагинов в логах Traefik — отдельный результат, без бессмысленных повторов |
| **3. Контроль миграции** | после запуска | Если миграция Pangolin переписала версию Badger, Traefik сразу перезапускается и проверяется под контролем скрипта |
| **4. Частичный откат** | при ошибке плагина | Возвращается только версия Badger, перезапускается только Traefik. Полный откат — если и это не помогло |

Закрепить версию: `BADGER_PIN="v1.7.0"` в файле конфигурации. Отключить пробу: `BADGER_PROBE=false` (уровни 2–4 останутся).

---

## CrowdSec + AppSec

| Часть | Что делает |
|-------|-----------|
| **CrowdSec** | Читает access-лог Traefik, замечает перебор паролей, сканирование путей, всплески 404 и банит нарушителя на всех ресурсах. Плюс блоклист сообщества |
| **AppSec** (WAF) | Проверяет каждый запрос: виртуальные патчи против известных CVE и общие правила |
| **Bouncer** (плагин Traefik) | Перед каждым запросом проверяет IP по банам и передаёт запрос в AppSec. Подключён ко всему entrypoint `websecure` |
| **crowdsec-manager** *(по желанию)* | Веб-интерфейс: алерты, баны, allowlist, Hub |

```
Клиент ──► Traefik (websecure :443)
              ├─► bouncer: IP в бане? ──── да ──► 403
              ├─► AppSec (crowdsec:7422): запрос опасен? ── да ──► 403
              └─► Badger (авторизация Pangolin) ──► Gerbil ──► Newt ──► сервис

access.log Traefik ──► CrowdSec (сценарии) ──► решения (баны) ──► bouncer
```

### Установка одной командой

```bash
pangolin-update.sh --crowdsec-install                  # CrowdSec + AppSec
pangolin-update.sh --crowdsec-install --with-manager   # + веб-интерфейс crowdsec-manager
```

| Этап | Стек | Что делается |
|------|------|--------------|
| 1. Проверки | работает | Файлы на месте, `docker compose config` проходит, есть `traefik` и entrypoint `websecure`, Traefik читает `dynamic_config.yml`, нет посторонних контейнеров с теми же именами |
| 2. Проба плагина | работает | Текущий Traefik загружает Badger и bouncer. Не загрузил — установка отменяется |
| 3. Образы | работает | CrowdSec (и crowdsec-manager) скачиваются заранее |
| 4. Подготовка | работает | Все правки YAML делаются **на копиях** в `.crowdsec-stage/` и проверяются `docker compose config` |
| 5. Подтверждение и бэкап | работает | Копии трёх конфигов (`*.bak.<дата>`), полный архив (горячий) |
| 6. Применение | перезапуск Traefik | Копии подменяют рабочие конфиги; запуск CrowdSec (до 3 мин на первый старт); регистрация bouncer; `up -d`; health check |
| 7. Завершение | работает | Ротация access-лога, проверка bouncer ↔ CrowdSec, тест `/.env` → 403, allowlist + cron, правила Hub |

Простой — перезапуск Traefik. Для PostgreSQL-сборки стек останавливается на этапе 5. Если этапы 6–7 не удались, конфиги возвращаются из копий, стек поднимается как был (код 1). Если и это не помогло — код 2, и тогда используйте `--restore`.

**Что меняется по сравнению с шаблоном установщика Pangolin (`installer --crowdsec`):**

| Параметр | Шаблон Pangolin | Здесь | Почему |
|----------|----------------|-------|--------|
| `forwardedHeadersTrustedIPs` | `0.0.0.0/0` | `[]` | Доверие `X-Forwarded-For` от всех позволяет обойти бан подменой IP |
| `clientTrustedIPs` | частные сети | `[]` | Клиенты из этих сетей не проверяются вовсе. Нужные адреса — в `CROWDSEC_CLIENT_TRUSTED_IPS` |
| Ключ bouncer | в YAML | в файле `config/traefik/crowdsec-bouncer.key` (600), `crowdsecLapiKeyFile` | Ключ не попадает в конфиг и в инструменты, которые его читают. Если `config/traefik` не примонтирован в traefik — ключ в YAML с `WARN` |
| `crowdsecMode` | `live` | `stream` | Баны кэшируются в Traefik |
| `crowdsecAppsecUnreachableBlock` | `true` | `false` | Упавший CrowdSec не блокирует все сайты вместе с панелью |
| Порты | опубликованы | нет | Docker NAT обходит UFW |
| Тег CrowdSec | `latest` | `v1.8.1` | С `latest` откат невозможен |
| crowdsec-manager | — | только с `--with-manager` | Нет своей авторизации и есть доступ к `docker.sock` (= root на хосте) |
| Ротация access-лога | — | logrotate без `copytruncate`, Traefik переоткрывает лог по `USR1` | Без потери строк |

**crowdsec-manager** открывайте только через Pangolin:

1. создайте сайт типа **Local**;
2. создайте HTTP-ресурс `crowdsec.<домен>` с целью `http://crowdsec-manager:8080`;
3. включите аутентификацию и оставьте доступ только администраторам.

**Cloudflare-прокси.** При `CF_PROXIED=true` в `.cf-dns.env` bouncer берёт реальный IP из `CF-Connecting-IP`, а доверенными становятся диапазоны Cloudflare.

**Удаление:**

```bash
pangolin-update.sh --crowdsec-uninstall
```

Правки готовятся на копиях. Затем контейнеры CrowdSec удаляются, а Traefik перезапускается; при сбое прежние конфиги возвращаются. Данные `config/crowdsec` и `crowdsec-manager/` остаются на диске.

**Ручная установка.** Если автоматическая не подходит, можно перенести те же фрагменты вручную. Это сервисы compose, `accessLog`, плагин и middleware Traefik, `acquis.d`. Их точное содержимое — в функциях `cs_write_fragments`, `cs_write_acquis` и `cs_write_logrotate` скрипта. Не задавайте `log.filePath` для основного лога Traefik: иначе скрипт не увидит ошибки загрузки плагинов.

### Allowlist своей инфраструктуры

Бан IP сайта Newt обрывает туннель со всеми его ресурсами, а бан IP сервера ломает обращения сервисов к своим доменам. Поэтому эти адреса держатся в allowlist `pangolin-infra`, который действует и на баны, и на AppSec.

| Источник | Как определяется | Описание записи |
|----------|------------------|-----------------|
| Сервер | Глобальные адреса интерфейсов; внешний IPv4/IPv6 — только если **два сервиса из трёх** вернули одно и то же (кэш `SERVER_IP_CACHE_MIN`); `CF_TARGET_IP` | `auto: server` |
| Сайты Newt | Таблица `sites` в БД Pangolin, поле `endpoint`. Только сайты на связи за `ALLOWLIST_NEWT_MAX_AGE_DAYS` дней, кроме перечисленных в `ALLOWLIST_NEWT_EXCLUDE` | `auto: newt <сайт>` |
| Вручную | `ALLOWLIST_EXTRA` | `auto: config ALLOWLIST_EXTRA` |

- **Ручные записи не трогаются**; устаревшие `auto:` удаляются (сменился IP у провайдера).
- **Нет данных — нет удалений**: если БД или IP сервера не прочитаны, соответствующие записи не меняются.
- **Тихий cron**: если адреса не изменились, `cscli` не вызывается (полная сверка раз в час).
- **Общий адрес.** Если сайт Newt стоит за CGNAT или общим офисным IP, в allowlist попадают все, кто за этим адресом. Такой сайт добавьте в `ALLOWLIST_NEWT_EXCLUDE="Имя сайта,Другой сайт"`. Выключить учёт сайтов совсем: `ALLOWLIST_NEWT=false`.
- Нужен CrowdSec 1.6.8+. PostgreSQL — адреса сайтов через `ALLOWLIST_EXTRA`.

```bash
pangolin-update.sh --allowlist-on      # cron каждые ALLOWLIST_SYNC_INTERVAL минут (ставится и при --crowdsec-install)
pangolin-update.sh --allowlist-sync    # разово
docker exec crowdsec cscli allowlists inspect pangolin-infra
```

### Обслуживание CrowdSec скриптом

| Что | Как |
|-----|-----|
| Образ CrowdSec | Обновляется со стеком в своей мажорной ветке, с выдержкой релиза; откатывается вместе со стеком |
| Правила Hub | При каждом запуске: `cscli hub update` + `upgrade`, SIGHUP при изменениях. Если CrowdSec после этого не отвечает — перезапуск, код 3 и уведомление |
| Bouncer, crowdsec-manager | Не обновляются автоматически; bouncer входит в пробу Traefik |

Особенности: правила AppSec действуют на все ресурсы, включая панель Pangolin (ложное 403 — смотрите `cscli alerts list`). TCP/UDP-ресурсы bouncer не защищает. `crowdsecAppsecUnreachableBlock: true` закрывает окно «без WAF» ценой недоступности при падении CrowdSec.

---

## Логирование

Лог — `/var/log/pangolin-update.log` (права 640: в него попадают логи контейнеров). Формат: `[YYYY-MM-DD HH:MM:SS] [LEVEL] Сообщение`, уровни `INFO`, `OK`, `WARN`, `ERROR`. Цвета — только в терминале.

**Ротация:** при превышении `LOG_MAX_LINES` (5000) лог переименовывается в `pangolin-update.log.YYYYMMDD_HHMMSS` и сжимается. Хранится `LOG_KEEP` (5) файлов.

```bash
grep '\[ERROR\]' /var/log/pangolin-update.log
grep 'Обновление успешно завершено' /var/log/pangolin-update.log
grep -E 'ОТКАТ|Откат' /var/log/pangolin-update.log
grep 'Создана A-запись\|Обновлена A-запись' /var/log/pangolin-update.log
```

---

## Автоматизация: cron или systemd

### cron

```bash
cat > /etc/cron.d/pangolin-update <<'EOF'
# Обновление стека Pangolin — ежедневно в 03:17
17 3 * * * root /usr/local/bin/pangolin-update.sh >/dev/null 2>&1
# Полная копия — по субботам в 02:43
43 2 * * 6 root /usr/local/bin/pangolin-update.sh --backup >/dev/null 2>&1
EOF
```

### systemd timer

Даёт вывод в `journalctl`, случайную задержку и запуск пропущенного после перезагрузки:

```ini
# /etc/systemd/system/pangolin-update.service
[Unit]
Description=Pangolin stack update
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pangolin-update.sh
TimeoutStartSec=30min
```

```ini
# /etc/systemd/system/pangolin-update.timer
[Unit]
Description=Daily Pangolin stack update

[Timer]
OnCalendar=*-*-* 03:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl daemon-reload && systemctl enable --now pangolin-update.timer
systemctl list-timers pangolin-update.timer
```

Параллельные запуски исключены `flock`. Обновление ждёт до `LOCK_WAIT` секунд, пока закончится другой запуск; cron-синхронизации DNS и allowlist при занятом lock просто пропускают цикл.

---

## Коды выхода

| Код | Значение | Что делать |
|-----|----------|------------|
| `0` | Успех: обновлено, обновлять нечего, пауза (`--hold`), режимы `--info`/`--dry-run`, сервисная операция выполнена | — |
| `1` | Операция не удалась, **прежнее состояние восстановлено** (откат после health check, прерывание с восстановлением, ошибка бэкапа, ошибки синхронизации) | Разобраться по логу; стек работает |
| `2` | **Восстановить не удалось** | Ручное вмешательство: `--restore` или `*.bak.<дата>` |
| `3` | Стек в порядке, но CrowdSec не отвечает после обновления правил | `docker logs crowdsec` |
| `4` | **Ничего не изменено**: ошибка аргументов, прав или конфигурации, нет зависимостей, занят lock, GitHub недоступен, образ не скачался, мало места, отмена пользователем | Причина — в последней строке `ERROR` |

---

## Структура файлов

```
/etc/pangolin-update.conf                      # Настройки (600, root)
/usr/local/bin/pangolin-update.sh              # Скрипт

/root/pangolin/
├── docker-compose.yml                         # Конфиг стека
├── docker-compose.yml.bak.YYYYMMDD_HHMMSS     # Копии (BACKUP_KEEP шт.)
├── .cf-dns.env                                # Настройки Cloudflare (600)
├── crowdsec-manager/                          # Если установлен с --with-manager
└── config/
    ├── db/db.sqlite                           # БД Pangolin
    ├── crowdsec/                              # CrowdSec: конфиг, acquis.d/, db/
    └── traefik/
        ├── traefik_config.yml (+ .bak.*)
        ├── dynamic_config.yml (+ .bak.*)
        ├── crowdsec-bouncer.key               # Ключ bouncer (600)
        └── logs/access.log                    # Для CrowdSec, не входит в бэкап

/root/pangolin-backups/                        # 700
├── pangolin_YYYYMMDD_HHMMSS.tar.gz            # Полные копии (BACKUP_KEEP шт., 600)
├── pre-restore_YYYYMMDD_HHMMSS.tar.gz         # Состояние перед --restore (не удаляются)
└── failed_YYYYMMDD_HHMMSS/                    # БД после неудачного обновления

/var/lib/pangolin-update/                      # Кэши и состояние (700)
├── github/                                    # Ответы GitHub API + ETag
├── probe-cache                                # Результаты проб плагинов
├── previous-images                            # Образы к удалению после следующего обновления
├── public-ipv4, public-ipv6                    # Внешние адреса сервера
├── dns.sig, dns.stale, allowlist.sig          # Состояние синхронизаций
├── notified                                   # Отправленные одноразовые уведомления
└── hold                                       # Пауза обновлений (--hold)

/run/pangolin-update.lock                      # flock
/etc/cron.d/pangolin-cf-dns, pangolin-allowlist
/etc/logrotate.d/pangolin-traefik
/var/log/pangolin-update.log (+ .YYYYMMDD_HHMMSS.gz)
```

---

## Разработка и тесты

```
pangolin-update.sh              # скрипт (main() запускается только при прямом вызове)
pangolin-update.conf.example    # образец настроек
CHANGELOG.md
tests/unit.bats                 # чистые функции: версии, теги, YAML, IP, аргументы
tests/integration.bats          # полный цикл на имитации docker (tests/mock/docker)
.github/workflows/ci.yml        # ShellCheck + тесты + контрольная сумма
```

```bash
npm install -g bats             # или пакет bats из дистрибутива
shellcheck -S style pangolin-update.sh
bats tests/
```

Скрипт можно подключить через `source` (например, в тестах). Тогда определяются только функции, `main` не запускается.

Интеграционные тесты не требуют Docker и сети. Они проверяют успешное обновление, сохранение PostgreSQL-тега, откат с возвратом БД, отказ при неудачном скачивании, восстановление после SIGTERM, частичный откат Badger, выдержку релиза, отсутствие понижения pre-release, `--dry-run`, `--hold`, `--backup`/`--restore` и блокировку параллельного запуска.

---

## Не входит в скрипт: установка и обновление Newt

Служба systemd (`/etc/systemd/system/newt.service`):

```ini
[Unit]
Description=Newt Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/newt --id <NEWT_ID> --secret <NEWT_SECRET> --endpoint https://pangolin.example.com
Restart=always
RestartSec=5
User=root
WorkingDirectory=/usr/local/bin
LimitNOFILE=65536
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload && systemctl enable --now newt.service
```

> Чтобы секрет не был виден в `systemctl status` и `ps`, вынесите его в файл окружения с правами 600 (`EnvironmentFile=`) — см. документацию Newt по переменным окружения.

Обновление:

```bash
systemctl stop newt.service
NEWT_V=$(curl -fsS https://api.github.com/repos/fosrl/newt/releases/latest | jq -r .tag_name) \
  && [ -n "$NEWT_V" ] && [ "$NEWT_V" != null ] \
  && curl -fsSL -o /usr/local/bin/newt.new "https://github.com/fosrl/newt/releases/download/${NEWT_V}/newt_linux_amd64" \
  && chmod 755 /usr/local/bin/newt.new && mv /usr/local/bin/newt.new /usr/local/bin/newt
systemctl start newt.service
```
