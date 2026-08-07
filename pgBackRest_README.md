# pgBackRest — резервное копирование и PITR для PostgreSQL

Подробное руководство «с нуля» для этого проекта (Patroni-кластер `pg-cluster`:
ноды `pg1`/`pg2`/`pg3` + выделенный репозиторный хост `backup1`).

Версия pgBackRest на стенде — **2.59.0**, PostgreSQL — **16**.

---

## Оглавление

1. [Что это и зачем](#1-что-это-и-зачем)
2. [Ключевые концепции простыми словами](#2-ключевые-концепции-простыми-словами)
3. [Как работает резервное копирование (backup)](#3-как-работает-резервное-копирование-backup)
4. [Непрерывное архивирование WAL (это и есть основа PITR)](#4-непрерывное-архивирование-wal)
5. [Что такое stanza](#5-что-такое-stanza)
6. [Архитектура в этом проекте](#6-архитектура-в-этом-проекте)
7. [Какие настройки PostgreSQL необходимы](#7-какие-настройки-postgresql-необходимы)
8. [Особенности работы с Patroni](#8-особенности-работы-с-patroni)
9. [Подробный разбор параметров конфигурации](#9-подробный-разбор-параметров-конфигурации)
10. [Основные команды](#10-основные-команды)
11. [Восстановление и PITR](#11-восстановление-и-pitr)
12. [Выделенная роль PostgreSQL и аутентификация (без суперпользователя)](#12-выделенная-роль-postgresql-и-аутентификация-без-суперпользователя)
13. [Альтернатива: репозиторий в S3 / object storage](#13-альтернатива-репозиторий-в-s3--object-storage)
14. [Ручная настройка SSH между хостами (без Ansible)](#14-ручная-настройка-ssh-между-хостами-без-ansible)
15. [Диагностика и типичные ошибки](#15-диагностика-и-типичные-ошибки)

---

## 1. Что это и зачем

**pgBackRest** — это специализированный инструмент для резервного копирования и
восстановления PostgreSQL. Он решает две задачи, которые вместе дают полноценную
защиту данных:

- **Backup** — снимает копию всего кластера БД (физическую, побайтовую копию файлов данных).
- **Continuous WAL archiving** — непрерывно складывает в репозиторий журналы
  предзаписи (WAL), то есть поток всех изменений, произошедших *после* бэкапа.

Комбинация «полная копия + поток изменений» даёт **PITR** (Point-In-Time Recovery) —
возможность восстановить базу на **любой момент времени**, а не только на момент бэкапа.
Например: «верни базу к состоянию на 14:32:05, за секунду до того, как кто-то выполнил
`DELETE` без `WHERE`».

### Чем pgBackRest лучше «голого» `pg_dump` / `pg_basebackup`

| | `pg_dump` | `pg_basebackup` | **pgBackRest** |
|---|---|---|---|
| Тип копии | логическая (SQL) | физическая | физическая |
| PITR (восстановление на точку) | ❌ | ⚠️ вручную | ✅ из коробки |
| Инкрементальные / разностные бэкапы | ❌ | ❌ | ✅ |
| Параллелизм и сжатие | ограниченно | ❌ | ✅ |
| Проверка целостности (checksums) | ❌ | ⚠️ | ✅ автоматически |
| Ретеншн (авто-удаление старого) | ❌ | ❌ | ✅ |
| Выделенный репозиторный хост | ❌ | ❌ | ✅ |

Проще говоря: `pg_dump` хорош для «выгрузить одну таблицу», а pgBackRest — это
**промышленная система бэкапов кластера** с PITR.

---

## 2. Ключевые концепции простыми словами

Прежде чем углубляться, разберём словарь. Все эти термины дальше используются постоянно.

- **Repository (репозиторий)** — хранилище, куда pgBackRest кладёт бэкапы и архив WAL.
  В нашем проекте это каталог `/var/lib/pgbackrest` на хосте `backup1`. Может быть
  локальным каталогом, отдельным хостом по SSH (наш случай) или object storage (S3/GCS/Azure).

- **Stanza (стэнза)** — «профиль» одного PostgreSQL-кластера внутри pgBackRest.
  Одно имя = один кластер БД. У нас stanza называется `pg-cluster`. Подробно — [раздел 5](#5-что-такое-stanza).

- **WAL (Write-Ahead Log)** — журнал предзаписи PostgreSQL. Прежде чем изменить
  страницу данных, PostgreSQL записывает изменение в WAL. WAL делится на **сегменты**
  (файлы обычно по 16 МБ, с именами вида `000000050000000000000042`). Именно поток WAL
  позволяет «доиграть» изменения после бэкапа и делает PITR возможным.

- **archive_command / archive-push** — механизм, которым PostgreSQL отдаёт заполненный
  сегмент WAL в репозиторий pgBackRest.

- **restore_command / archive-get** — обратный механизм: восстанавливаемая база
  запрашивает нужные сегменты WAL из репозитория.

- **Типы бэкапов**:
  - **full** (полный) — полная копия всех файлов кластера. Самодостаточен.
  - **diff** (разностный, differential) — только файлы, изменившиеся с последнего **full**.
  - **incr** (инкрементальный) — только файлы, изменившиеся с последнего **любого** бэкапа
    (full/diff/incr).

- **PITR (Point-In-Time Recovery)** — восстановление на произвольный момент времени
  за счёт бэкапа + доигрывания архивного WAL до заданной точки (`--type=time`).

- **Retention (ретеншн)** — политика хранения: сколько бэкапов держать. Устаревшие
  бэкапы и уже ненужный WAL удаляются автоматически (`expire`).

### Как типы бэкапов связаны между собой

```
full ──────────── diff ──── incr ──── incr ──── diff ──── incr ...
(полная копия)   (Δ от      (Δ от     (Δ от     (Δ от     (Δ от
                  full)      diff)     incr)     full)     diff)
```

- Восстановление `incr` требует наличия цепочки до его `full`.
- Удаление `full` каскадно удаляет все зависящие от него `diff`/`incr` — pgBackRest
  следит за этим сам через ретеншн.

---

## 3. Как работает резервное копирование (backup)

pgBackRest делает **физический** бэкап — копирует файлы каталога данных PostgreSQL
(`PGDATA`), а не выгружает SQL. Ключевой момент: копирование идёт с **работающего**
кластера, без остановки БД. Это возможно благодаря режиму online-backup PostgreSQL.

### Что происходит по шагам при `pgbackrest backup`

1. **Старт бэкапа.** pgBackRest подключается к PostgreSQL (через Unix-сокет, у нас
   `/var/run/postgresql`) и вызывает `pg_backup_start()`. PostgreSQL запоминает
   стартовую позицию в WAL и делает **checkpoint**.
   - Параметр `start-fast=y` (включён в проекте) просит сделать checkpoint **немедленно**,
     не дожидаясь планового — бэкап стартует сразу, а не через минуты.

2. **Копирование файлов.** pgBackRest построчно обходит `PGDATA` и копирует файлы в
   репозиторий. Для **full** — все файлы. Для **diff/incr** — только изменившиеся
   (определяется по времени модификации и размеру; при `delta`-режиме — по контрольным
   суммам). Файлы на лету **сжимаются** (у нас `zst`) и, при желании, **шифруются**.
   Копирование идёт в несколько потоков (`process-max`).

3. **Контрольные суммы.** Для каждого файла считается checksum и записывается в манифест
   бэкапа — это позволяет позже проверить целостность (`verify`) и обнаружить порчу.

4. **Стоп бэкапа.** Вызывается `pg_backup_stop()`. PostgreSQL возвращает финальную
   позицию WAL. Всё, что изменилось за время копирования, будет восстановлено из WAL —
   поэтому бэкап консистентен, хотя снимался с «живой» базы.

5. **Дождаться WAL.** pgBackRest дожидается, пока все сегменты WAL от старта до стопа
   бэкапа окажутся в архиве репозитория (их туда кладёт `archive_command`). Без этих
   сегментов бэкап нельзя было бы восстановить. Отсюда **важный вывод: backup невозможен,
   если не настроено архивирование WAL** (см. [раздел 4](#4-непрерывное-архивирование-wal)).

6. **Манифест.** Записывается `backup.manifest` — список всех файлов, их размеров,
   checksum, границ WAL, параметров кластера. Это «оглавление» бэкапа.

7. **Expire (ретеншн).** Если бэкапов стало больше `repo1-retention-full`, самые старые
   full (вместе с их diff/incr и уже ненужным архивом WAL) удаляются.

### Пример из нашего стенда

```
full backup: 20260729-084146F
    timestamp start/stop: 2026-07-29 08:41:46+00 / 2026-07-29 08:41:49+00
    wal start/stop: 000000050000000000000042 / 000000050000000000000042
    database size: 197.8MB, database backup size: 197.8MB
    repo1: backup set size: 20.3MB, backup size: 20.3MB
```

- `20260729-084146F` — метка бэкапа (дата-время + `F` = full; `D` = diff, `I` = incr).
- `database size: 197.8MB` → `repo1 backup size: 20.3MB` — эффект сжатия `zst` (~10×).
- `wal start/stop` — какие сегменты WAL нужны, чтобы этот бэкап был консистентным.

---

## 4. Непрерывное архивирование WAL

Это **сердце PITR** и обязательное условие работы backup. Разберём подробно.

### Идея

PostgreSQL пишет все изменения в WAL-сегменты. Когда сегмент заполняется (или проходит
`archive_timeout`), PostgreSQL «закрывает» его и вызывает **`archive_command`** — команду,
которая должна куда-то надёжно скопировать этот сегмент. Если команда вернула успех (код 0),
PostgreSQL считает сегмент заархивированным и может его переиспользовать.

В нашем проекте `archive_command` такая:

```
pgbackrest --stanza=pg-cluster archive-push %p
```

- `%p` — PostgreSQL подставляет путь к готовому сегменту WAL.
- `archive-push` берёт этот сегмент, сжимает, (шифрует) и кладёт в репозиторий
  (у нас — по SSH на `backup1`).

Обратная операция при восстановлении — **`archive-get`** (см. `restore_command`):

```
pgbackrest --stanza=pg-cluster archive-get %f "%p"
```

восстанавливаемый сервер запрашивает недостающий сегмент `%f` из репозитория.

### Почему это даёт PITR

Имея **base backup** (снимок на момент T0) и **непрерывный архив WAL** после T0,
можно восстановить base backup и «доиграть» WAL до любого момента `T0 ≤ t ≤ сейчас`.
Точность — вплоть до транзакции.

```
        backup (T0)                     хотим восстановить сюда (t)
            │                                        │
   ─────────●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╳━━━━━━━━━━━▶  время
            └── непрерывный архив WAL ────────────────┘
                (00...42, 00...43, 00...44, ...)
```

### archive_timeout и RPO

Если база простаивает, WAL-сегмент может долго не заполняться, и последние изменения
останутся не заархивированными. `archive_timeout` (у нас `60s`) заставляет PostgreSQL
переключать WAL хотя бы раз в минуту, ограничивая **RPO** (Recovery Point Objective —
сколько данных максимум потеряем) примерно этой минутой.

### Проверка, что архивация работает

```sql
SELECT archived_count, last_archived_wal, failed_count, last_failed_wal
FROM pg_stat_archiver;
```

Здоровое состояние: `failed_count = 0`, `last_archived_wal` растёт. Пример со стенда:

```
archived_count | 6
last_archived_wal | 000000050000000000000042.00000028.backup
failed_count | 0
last_failed_wal |
```

---

## 5. Что такое stanza

**Stanza** — это описание **одного PostgreSQL-кластера** в терминах pgBackRest.
Одна stanza = один логический кластер БД со своей историей бэкапов и своим архивом WAL
внутри репозитория.

Имя нашей stanza — **`pg-cluster`** (совпадает с именем Patroni-кластера, для наглядности;
задаётся переменной `pgbackrest_stanza`).

Что «знает» stanza:
- где находится `PGDATA` каждой ноды (`pgN-path`);
- как достучаться до PostgreSQL (`pgN-host`, `pgN-port`, `pgN-socket-path`);
- под каким пользователем ходить (`pgN-host-user`);
- параметры хранения (наследуются из `[global]`).

### `stanza-create` — инициализация

Перед первым бэкапом stanza нужно **создать**:

```
pgbackrest --stanza=pg-cluster stanza-create
```

Что делает `stanza-create`:
1. Подключается к PostgreSQL и считывает `system identifier`, версию, размер WAL-сегмента.
2. Создаёт в репозитории структуру каталогов и файлы `backup.info` / `archive.info`
   (с контрольными суммами и метаданными кластера).
3. Проверяет соответствие: репозиторий действительно принадлежит **этому** кластеру.

Команда **идемпотентна**: повторный запуск на готовой stanza завершится успешно и
напишет `stanza 'pg-cluster' already exists on repo1 and is valid`, ничего не меняя.

> В нашем Ansible-роли это учтено: `changed_when` у задачи `stanza-create` считает
> изменение только если в выводе есть `completed successfully` **и нет** `already exists`.

### `stanza-delete` / `stanza-upgrade`

- `stanza-upgrade` — обновить метаданные stanza после мажорного апгрейда PostgreSQL
  (например, 16 → 17). Обязательно вызывать после `pg_upgrade`.
- `stanza-delete` — удалить stanza и все её бэкапы из репозитория (осторожно!).

---

## 6. Архитектура в этом проекте

Проект использует модель **выделенного репозиторного хоста** (dedicated repository host) —
это рекомендованная промышленная схема: бэкапы физически лежат **не на** серверах БД,
поэтому падение/компрометация ноды БД не уносит с собой бэкапы.

```
        ┌──────────────────────── SSH ────────────────────────┐
        │                                                      │
   ┌────▼─────┐   ┌──────────┐   ┌──────────┐          ┌───────┴────────┐
   │   pg1    │   │   pg2    │   │   pg3    │          │    backup1     │
   │ Leader   │   │ Replica  │   │ Replica  │          │  (repo host)   │
   │ postgres │   │ postgres │   │ postgres │          │  user:         │
   │          │   │          │   │          │          │  pgbackrest    │
   └────┬─────┘   └────┬─────┘   └────┬─────┘          │  repo:         │
        │ archive-push │              │                │ /var/lib/      │
        │  (WAL) ──────┴──────────────┴───────────────▶│   pgbackrest   │
        │                                              └────────────────┘
        │  ◀───── backup / restore (pull от repo-хоста по SSH) ─────────┘
```

### Направления связи (обе стороны по SSH, взаимная авторизация ключей)

1. **`postgres@pgN → pgbackrest@backup1`** — доставка WAL (`archive-push`). Инициатор —
   нода БД: её `archive_command` толкает сегмент на репо-хост.
2. **`pgbackrest@backup1 → postgres@pgN`** — снятие бэкапа и restore. Инициатор —
   репо-хост: команда `backup` запускается на `backup1`, он «тянет» файлы с нужной ноды БД.

Именно поэтому в роли настраивается **взаимный** обмен SSH-ключами (`roles/pgbackrest/tasks/ssh.yml`).

### Два разных конфига на разных ролях хостов

Один и тот же шаблон (`pgbackrest.conf.j2`) генерирует **разный** конфиг в зависимости
от роли хоста:

**На репо-хосте `backup1`** — секция stanza перечисляет ВСЕ ноды кластера:
```ini
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2
repo1-cipher-type=none
...
[pg-cluster]
pg1-host=pg1
pg1-host-user=postgres
pg1-path=/var/lib/postgresql/16/data
pg1-port=5432
pg1-socket-path=/var/run/postgresql
pg2-host=pg2   # ... и так для всех нод
pg3-host=pg3
```

**На ноде БД `pg1`** — знает только про репо-хост и про СЕБЯ:
```ini
[global]
repo1-path=/var/lib/pgbackrest
repo1-host=backup1          # где репозиторий
repo1-host-user=pgbackrest  # под кем туда ходить
...
[pg-cluster]
pg1-path=/var/lib/postgresql/16/data   # только локальный data_dir
pg1-port=5432
pg1-socket-path=/var/run/postgresql
```

### Почему бэкап делается через реплику — это полезное свойство

Репо-хост знает про все ноды. pgBackRest сам определяет, кто сейчас primary, а кто
standby, и по умолчанию для **full/diff/incr** **снимает данные с реплики** (backup from
standby), разгружая primary. К primary он обращается только за управлением WAL. В нашем
логе `check` это видно: `check repo1 (standby)`.

---

## 7. Какие настройки PostgreSQL необходимы

Чтобы pgBackRest мог делать бэкапы и обеспечивать PITR, в PostgreSQL должны быть включены
следующие параметры. **В кластере Patroni их нельзя менять напрямую в `postgresql.conf`** —
только через Patroni (см. [раздел 8](#8-особенности-работы-с-patroni)).

| Параметр | Значение в проекте | Зачем | Требует рестарта? |
|---|---|---|---|
| `archive_mode` | `on` | Включает вызов `archive_command`. Без него нет архива WAL → нет PITR и нельзя завершить backup. | **Да** |
| `archive_command` | `pgbackrest --stanza=pg-cluster archive-push %p` | Команда доставки сегмента WAL в репозиторий. | Нет (reload) |
| `archive_timeout` | `60s` | Форсирует переключение WAL при простое (ограничивает RPO). | Нет (reload) |
| `wal_level` | `replica` (или выше) | Минимальный уровень для физического бэкапа и репликации. `minimal` не годится. | **Да** |
| `max_wal_senders` | `> 0` | Нужен для потоковой репликации и `backup from standby`. | **Да** |

Ключевые тонкости:

- **`archive_mode` читается только при СТАРТЕ PostgreSQL.** Изменить его на лету
  (reload) нельзя — нужен **рестарт**. Это порождает главную сложность интеграции с
  Patroni (см. ниже).
- **`archive_mode=on` vs `always`.** При `on` реплики **не** архивируют WAL (архивирует
  только primary). При `always` архивируют и реплики. Для схемы с pgBackRest и Patroni
  правильно **`on`**: за архив отвечает текущий primary, а при failover новый primary
  просто продолжает архивацию (`archive_command` одинаков на всех нодах).
- `archive_command` должен возвращать **0 только при реальном успехе**. pgBackRest это
  гарантирует. Никогда не пишите `... || true`.

---

## 8. Особенности работы с Patroni

Patroni управляет конфигурацией PostgreSQL централизованно через **DCS** (у нас etcd).
Поэтому «руками в конфиг» лезть нельзя — Patroni перезапишет. Есть несколько важных
особенностей и один коварный подводный камень.

### 8.1. Где какие настройки живут

Настройки pgBackRest в Patroni делятся на **две категории** — это принципиально:

1. **Параметры PostgreSQL** (`archive_mode`, `archive_command`, `archive_timeout`) —
   это `postgresql.parameters`. Они **общие для всего кластера** и хранятся в **DCS**.
   Меняются через `patronictl edit-config` (пишет в etcd, применяется на всех нодах).

2. **Локальная конфигурация ноды Patroni** (`create_replica_methods`, `pgbackrest`,
   `recovery_conf`) — это методы клонирования реплик и восстановления. Они **локальны**
   для ноды (ссылаются на локальные команды) и живут в **`patroni.yml`** каждой ноды,
   применяются через `reload`.

В проекте это разнесено по разным play в `04_pgbackrest_playbook.yml`:
- PLAY 2 — правит локальный `patroni.yml` (create_replica_methods) + `reload`;
- PLAY 3 — правит `postgresql.parameters` через `edit-config` (DCS) + рестарт.

### 8.2. Интеграция реплик и восстановления (фрагмент `patroni.yml`)

```yaml
postgresql:
  # Новые/пересобираемые реплики сначала пытаются подняться из бэкапа
  # pgBackRest (разгружая primary), basebackup — запасной метод.
  create_replica_methods:
    - pgbackrest
    - basebackup
  pgbackrest:
    command: 'pgbackrest --stanza=pg-cluster --delta restore'
    keep_data: True
    no_params: True
  # Если streaming-репликация отстанет — реплика догонит недостающие
  # сегменты WAL из архива pgBackRest.
  recovery_conf:
    restore_command: 'pgbackrest --stanza=pg-cluster archive-get %f "%p"'
```

Что это даёт:
- **Быстрое создание реплики** из бэкапа вместо полного `pg_basebackup` с primary.
- **Отказоустойчивость репликации**: отставшая реплика возьмёт WAL из архива, а не
  «застрянет», если primary уже удалил нужный сегмент.

### 8.3. PITR-bootstrap (восстановление всего кластера на точку во времени)

Для восстановления кластера на момент времени Patroni может при bootstrap выполнить
не `initdb`, а восстановление pgBackRest (см. `patroni.yml.j2`, блок `bootstrap`):

```yaml
bootstrap:
  method: pgbackrest_pitr
  pgbackrest_pitr:
    command: >-
      pgbackrest --stanza=pg-cluster --delta
      --type=time --target="2026-07-29 14:32:00"
      --target-action=promote restore
    keep_existing_recovery_conf: True
    no_params: True
```

> ⚠️ После успешного PITR-bootstrap этот блок нужно убрать (перегенерировать конфиг с
> `pitr_bootstrap=false`), иначе при следующем ре-бутстрапе Patroni снова уйдёт в PITR.
> В проекте это делает playbook 05.

### 8.4. ⚠️ ГЛАВНЫЙ подводный камень: гонка `edit-config` → `restart`

Это реальный баг, который был найден и исправлен в проекте. Разберём детально, потому
что он неочевиден и «тихий».

**Симптом:** после включения архивации `pgbackrest check` падает с
`ERROR: [087]: archive_mode must be enabled`, хотя в DCS `archive_mode: 'on'`, и на
репликах архивация включена. Оказывается, `archive_mode=off` остался **только на лидере**.

**Причина:**
1. `patronictl edit-config` лишь записывает `archive_mode=on` в **DCS** (etcd).
2. Каждая нода применяет изменение к своему локальному `postgresql.conf` и выставляет
   флаг `Pending restart` **не мгновенно, а на следующем HA-цикле** (`loop_wait`, ~10 с).
3. Если сразу после `edit-config` сделать `patronictl restart`, лидер успевает
   перезапуститься **со старым конфигом** (`archive_mode=off`) — его HA-цикл ещё не
   переписал `postgresql.conf`. Реплики рестартуют чуть позже и подхватывают `on`.
4. Итог: архивация выключена **только на primary** → `check` и backup невозможны.

**Почему `--pending` сразу тоже не спасает:** флаг `Pending restart` в этот момент ещё
не выставлен, поэтому `restart --pending` не найдёт что рестартовать.

**Правильное решение (реализовано в PLAY 3):**
```
edit-config (пишем archive_* в DCS)
    │
    ▼
ЖДЁМ (retry), пока флаг "Pending restart" появится у ВСЕХ нод
   (patronictl list --format json → у ноды есть поле "Pending restart")
    │
    ▼
restart <cluster> --pending --force   (точечно и безопасно)
    │
    ▼
проверяем SHOW archive_mode = on на КАЖДОЙ ноде (включая лидера)
```

**Практический вывод для любых restart-требующих GUC в Patroni** (пригодится и при
апгрейде 16→17→18): никогда не рестартуйте сразу после `edit-config` — сначала дождитесь,
пока Patroni распространит изменение и выставит `Pending restart` на всех нодах.

### 8.5. Ещё одна тонкость: квотирование enum-значений

`patronictl edit-config -p archive_mode=on` распарсит `on` как YAML-boolean `true` и
запишет `archive_mode = 'True'` — **невалидное** значение enum `{off,on,always}`,
PostgreSQL не стартует. Правильно передавать строкой: `-p 'archive_mode="on"'`.

---

## 9. Подробный разбор параметров конфигурации

Конфиг pgBackRest (`/etc/pgbackrest/pgbackrest.conf`) состоит из секций:
`[global]` — общие настройки; `[global:command]` — переопределения под конкретную команду;
`[<stanza>]` — описание кластера. Ниже — параметры, используемые в проекте, и главные
из тех, что стоит знать.

### 9.1. Репозиторий (`repo1-*`)

pgBackRest поддерживает несколько репозиториев (`repo1-*`, `repo2-*`, …). У нас один.

| Параметр | Значение | Описание |
|---|---|---|
| `repo1-path` | `/var/lib/pgbackrest` | Каталог репозитория на репо-хосте. Здесь лежат `backup/` и `archive/`. |
| `repo1-host` | `backup1` (только на db-нодах) | Адрес выделенного репо-хоста. Его наличие переключает pgBackRest в режим SSH-репозитория. |
| `repo1-host-user` | `pgbackrest` (только на db-нодах) | Системный пользователь на репо-хосте, под которым ходим по SSH. |
| `repo1-retention-full` | `2` | Сколько **полных** бэкапов хранить. Старые full + их diff/incr + ненужный WAL удаляются при expire. |
| `repo1-retention-diff` | (не задано) | Сколько diff хранить внутри full. По умолчанию — все до следующего full. |
| `repo1-cipher-type` | `none` | Шифрование репозитория. `none` — учебно; для prod → `aes-256-cbc`. |
| `repo1-cipher-pass` | (нет) | Пароль шифрования (нужен при `aes-256-cbc`). Хранить в секрете (vault). |

Для **object storage** вместо `repo1-path` используется `repo1-type=s3` (или `gcs`/`azure`)
плюс параметры доступа к бакету. Полный разбор и примеры — в
[разделе 13](#13-альтернатива-репозиторий-в-s3--object-storage).

### 9.2. Хранение / производительность (`[global]`)

| Параметр | Значение | Описание |
|---|---|---|
| `compress-type` | `zst` | Алгоритм сжатия репозитория. `zst` (zstd) — быстрый и с хорошим коэффициентом. Альтернативы: `gz`, `lz4`, `bz2`, `none`. |
| `compress-level` | (по умолч. для zst) | Уровень сжатия. Выше = меньше размер, но больше CPU. |
| `process-max` | `2` | Число параллельных процессов копирования/сжатия. Разумно ≈ числу ядер; на нашем стенде — 2. |
| `start-fast` | `y` | Форсировать checkpoint при старте бэкапа немедленно, не ждать планового. Бэкап стартует быстрее ценой всплеска I/O. |
| `delta` | (передаём флагом `--delta`) | Определять изменённые файлы по **контрольным суммам**, а не только по mtime/размеру. Надёжнее для инкрементальных бэкапов и restore. |
| `archive-async` | (не задано) | Асинхронная доставка WAL с буферизацией — сильно ускоряет archive-push под нагрузкой (для prod полезно). |

### 9.3. Логирование

| Параметр | Значение | Описание |
|---|---|---|
| `log-path` | `/var/log/pgbackrest` | Каталог лог-файлов. |
| `log-level-console` | `info` | Детальность вывода в консоль/stdout. |
| `log-level-file` | `detail` | Детальность лог-файла. `detail` полезно для разбора инцидентов. Ещё есть `debug`, `trace`. |

> Замечание: pgBackRest пишет INFO-строки в **stdout** (не stderr). Это важно учитывать
> в Ansible при вычислении `changed_when`/`failed_when`.

### 9.4. Параметры stanza (`[pg-cluster]`) — как pgBackRest находит PostgreSQL

Индекс `pgN` — это **порядковый номер ноды внутри stanza**, а не имя. На репо-хосте
перечислены все ноды (`pg1..pg3`), на самой ноде — только она сама (`pg1`).

| Параметр | Пример | Описание |
|---|---|---|
| `pgN-host` | `pg1` | Хост ноды БД (задаётся только на репо-хосте; для локальной ноды не нужен). |
| `pgN-host-user` | `postgres` | Пользователь на ноде БД для SSH (владелец `PGDATA`). |
| `pgN-path` | `/var/lib/postgresql/16/data` | Путь к `PGDATA`. Должен точно совпадать с `data_dir` PostgreSQL. |
| `pgN-port` | `5432` | Порт PostgreSQL. |
| `pgN-socket-path` | `/var/run/postgresql` | Каталог Unix-сокета. Через него pgBackRest вызывает `pg_backup_start/stop`. На Debian/Ubuntu PG слушает здесь. |
| `pgN-user` | `pgbackrest` | **Роль БД** для libpq-подключения (не суперпользователь `postgres`). См. [раздел 12](#12-выделенная-роль-postgresql-и-аутентификация-без-суперпользователя). |
| `pgN-database` | `postgres` | База, к которой подключается pgBackRest. |

### 9.5. Параметры, задаваемые флагами команд (в проекте)

Не всё лежит в файле — часть передаётся при вызове:

| Флаг | Где используется | Описание |
|---|---|---|
| `--stanza=pg-cluster` | везде | Обязательный: с какой stanza работаем. |
| `--type=full\|diff\|incr` | `backup` | Тип бэкапа. |
| `--type=time` | `restore` | Тип восстановления (PITR по времени). Ещё: `default`, `immediate`, `lsn`, `xid`, `name`. |
| `--target="2026-... "` | `restore` | Целевая точка для PITR. |
| `--target-action=promote` | `restore` | Что делать по достижении точки: `promote` (открыть на запись), `pause`, `shutdown`. |
| `--delta` | `restore` / `backup` | Восстанавливать/сравнивать по checksum, не перезаписывая совпадающие файлы (быстрее). |
| `--output=json` | `info` | Машиночитаемый вывод (используется в плейбуке для проверки наличия бэкапов). |

---

## 10. Основные команды

Все команды требуют `--stanza`. На репо-хосте они запускаются от пользователя `pgbackrest`.

```bash
# Инициализация профиля кластера (один раз)
pgbackrest --stanza=pg-cluster stanza-create

# Проверить, что archive_command работает и репозиторий доступен
# (гоняет тестовый сегмент WAL через архив)
pgbackrest --stanza=pg-cluster check

# Бэкапы
pgbackrest --stanza=pg-cluster --type=full backup   # полный
pgbackrest --stanza=pg-cluster --type=diff backup   # разностный
pgbackrest --stanza=pg-cluster --type=incr backup   # инкрементальный (по умолчанию)

# Информация о бэкапах и архиве WAL
pgbackrest --stanza=pg-cluster info
pgbackrest --stanza=pg-cluster --output=json info

# Проверка целостности репозитория (сверка контрольных сумм)
pgbackrest --stanza=pg-cluster verify

# Восстановление (см. следующий раздел)
pgbackrest --stanza=pg-cluster restore

# Принудительно удалить устаревшие бэкапы по политике ретеншна
pgbackrest --stanza=pg-cluster expire
```

В проекте регулярные бэкапы поставлены в cron на `backup1` через обёртку
`/usr/local/bin/pgbackrest-backup.sh`:
- `full` — еженедельно (вс, 02:00);
- `incr` — ежедневно (пн–сб, 02:00).

---

## 11. Восстановление и PITR

> ⚠️ В кластере Patroni нельзя просто выполнить `pgbackrest restore` поверх работающей
> ноды — Patroni управляет жизненным циклом PostgreSQL. Восстановление делается либо
> через **PITR-bootstrap** ([раздел 8.3](#83-pitr-bootstrap-восстановление-всего-кластера-на-точку-во-времени)),
> либо на остановленной/новой ноде с последующим ре-встраиванием в кластер. В проекте
> сценарий восстановления автоматизирован в `05_pitr_demo_playbook.yml`.

### Общая механика restore (для понимания)

```bash
# Восстановить последний бэкап «как есть» (recovery до конца доступного WAL)
pgbackrest --stanza=pg-cluster restore

# PITR: восстановить на конкретный момент времени
pgbackrest --stanza=pg-cluster --delta \
    --type=time --target="2026-07-29 14:32:00" \
    --target-action=promote restore
```

Что происходит:
1. pgBackRest раскладывает файлы выбранного бэкапа в `PGDATA` (при `--delta` — только
   отличающиеся файлы, быстрее).
2. Пишет `recovery.signal` и `restore_command` (`archive-get`), чтобы PostgreSQL при
   старте «доиграл» WAL из архива.
3. PostgreSQL стартует в recovery, применяет WAL до `--target` (например, до времени).
4. По достижении цели выполняется `--target-action` (у нас `promote` — база открывается
   на запись как новый primary).

### Выбор точки восстановления (`--type`)

| `--type` | Восстановить до… |
|---|---|
| `default` | конца всего доступного архивного WAL (максимально свежее). |
| `time` | заданного момента времени (`--target="YYYY-MM-DD HH:MM:SS"`). |
| `xid` | заданного transaction ID. |
| `lsn` | заданной позиции в WAL. |
| `name` | именованной restore point (`pg_create_restore_point`). |
| `immediate` | ближайшей согласованной точки (конец восстановления бэкапа, минимум WAL). |

---

## 12. Выделенная роль PostgreSQL и аутентификация (без суперпользователя)

По умолчанию pgBackRest подключается к PostgreSQL как OS-пользователь `postgres`
через сокет с `trust`/`peer` — то есть фактически суперпользователем без пароля.
Для production это недопустимо (политика pg_hba запрещает `local ... postgres trust`).
Ниже — как увести pgBackRest на **выделенную non-superuser роль** с паролем. Всё
проверено на стенде (PG 16 / pgBackRest 2.59) и реализовано в роли Ansible.

### 12.1. Ключевое ограничение: pgBackRest ходит в БД ТОЛЬКО через Unix-socket

У pgBackRest **нет** опции TCP-подключения к PostgreSQL. Опции соединения — только
`pg-socket-path`, `pg-port`, `pg-user`, `pg-database`. Опция `pg-host` — это **SSH/TLS
канал управления** (запуск pgBackRest на удалённой ноде), а не libpq-TCP. Локальный
процесс pgBackRest всегда подключается к своему PostgreSQL по сокету.

**Вывод:** «полностью без сокета» для pgBackRest недостижимо. Достижимо и правильно —
**отдельная роль + `scram-sha-256` по сокету** (без `postgres`, без `trust`).

Важно не путать двух «пользователей»:

| | Кто это | Требование | Можно ли не-`postgres`? |
|---|---|---|---|
| **OS-пользователь** | под ним идёт процесс pgBackRest на ноде БД (`pgN-host-user`) | должен **читать файлы `PGDATA`** (владелец `postgres`, режим `0700`) | практически **нет** — остаётся `postgres`; к pg_hba отношения не имеет |
| **Роль БД** | под ней делается libpq-подключение (`pg-user`) | нужна для `pg_backup_start/stop`, чтения настроек | **да** — это и есть выделенная роль |

### 12.2. Минимальные права роли (проверено на PG 16)

Роль **не суперпользователь**, `REPLICATION` не нужен:

```sql
CREATE ROLE pgbackrest WITH LOGIN PASSWORD '<из vault>';
GRANT EXECUTE ON FUNCTION pg_backup_start(text, boolean)  TO pgbackrest;
GRANT EXECUTE ON FUNCTION pg_backup_stop(boolean)         TO pgbackrest;
GRANT EXECUTE ON FUNCTION pg_switch_wal()                 TO pgbackrest;
GRANT EXECUTE ON FUNCTION pg_create_restore_point(text)   TO pgbackrest;
GRANT pg_read_all_settings TO pgbackrest;   -- ОБЯЗАТЕЛЬНО (стандартная роль)
```

- `pg_read_all_settings` — **предопределённая (стандартная) роль, обязательна**: без неё
  pgBackRest падает с `unable to select some rows from pg_settings` (нужно читать
  `data_directory` и другие ограниченные GUC). `pg_monitor` — её надмножество, годится,
  если той же ролью гоняете мониторинг.
- Четыре `EXECUTE`-гранта на backup-функции **предопределённой ролью не заменить** — нет
  стандартной роли, дающей на них права. Выдаются только явно.
- Проверено: с этим набором `stanza-create` / `check` / `backup` проходят полностью;
  убрать `pg_read_all_settings` — всё ломается.

> Сигнатуры функций даны для PG 15+ (в т.ч. 16). До PG 15 они назывались
> `pg_start_backup` / `pg_stop_backup` — учитывайте при апгрейде/даунгрейде.

### 12.3. pg_hba: правило scram ВЫШЕ `trust`

```
# pg_hba.conf — правило роли pgbackrest ДОЛЖНО идти выше любых "local ... trust":
local   postgres   pgbackrest   scram-sha-256
```

- **Порядок критичен.** pg_hba — first-match. Если `local all all trust` окажется выше,
  он перехватит роль первой, и пароль проверяться не будет (scram не сработает). Правило
  для `pgbackrest` ставится в самое начало файла.
- **Почему `scram`, а не `peer`.** `peer` мапит OS-пользователя на одноимённую роль БД.
  OS-user у нас `postgres` (нужен для чтения `PGDATA`), а роль — `pgbackrest`; `peer` их
  связать не даст. `scram` развязывает: OS-user `postgres` подключается ролью `pgbackrest`
  по паролю.
- В проекте на живой кластер правило добавляется в `pg_hba.conf` через `lineinfile`
  (`insertbefore: BOF`) + `SELECT pg_reload_conf()` — pg_hba перечитывается **без
  рестарта**. В `bootstrap.pg_hba` шаблона Patroni правило тоже прописано (для свежих
  бутстрапов). В production завершающую строку `local all all trust` убирают — тогда
  роль ходит исключительно через scram.

### 12.4. Пароль через `~/.pgpass` (нюанс с host)

У pgBackRest **намеренно нет** опции `pg-password` — пароль берётся из `~/.pgpass`
OS-пользователя, под которым процесс работает на ноде БД (`postgres` →
`/var/lib/postgresql/.pgpass`, режим `0600`).

⚠️ **Тонкость matching.** Для подключения по Unix-сокету libpq ищет запись в `.pgpass`
по ключу host = **`localhost`**, а НЕ по пути каталога сокета. Строка вида
`/var/run/postgresql:...` **не матчится** → `fe_sendauth: no password supplied`.
Правильно:

```
# ~/.pgpass  (host:port:database:user:password)
localhost:*:postgres:pgbackrest:<пароль>
```

На **repo-хосте** `.pgpass` не нужен: он сам к БД не подключается (ходит по SSH; libpq-
подключение делает процесс уже на ноде БД).

### 12.5. Что поменять в конфиге pgBackRest

```ini
[pg-cluster]
# ... pgN-host / pgN-path / pgN-port / pgN-socket-path как раньше ...
pg1-user=pgbackrest        # ← libpq-подключение под выделенной ролью, НЕ postgres
pg1-database=postgres
```

### 12.6. Как это собрано в проекте

| Слой | Где |
|---|---|
| Создание роли + гранты (на primary, идемпотентно) | `roles/pgbackrest/tasks/pg_role.yml`, PLAY 3c |
| `~/.pgpass` на нодах БД | `roles/pgbackrest/tasks/configure.yml` |
| `pg-user` / `pg-database` в конфиге | `roles/pgbackrest/templates/pgbackrest.conf.j2` |
| Правило pg_hba (живой кластер + bootstrap) | PLAY 3c + `templates/patroni.yml.j2` |
| Пароль роли | `vault_pgbackrest_db_password` в `group_vars/all/vault.yml` |

### 12.7. Как проверить, что работает именно scram (а не trust)

```bash
# 1. Роль без суперправ, с нужными грантами
psql -U postgres -tAc "SELECT rolname,rolsuper,rolcanlogin FROM pg_roles WHERE rolname='pgbackrest';"
# → pgbackrest|f|t

# 2. Убрать .pgpass и запустить check — ДОЛЖЕН упасть с "no password supplied"
mv /var/lib/postgresql/.pgpass /var/lib/postgresql/.pgpass.bak
pgbackrest --stanza=pg-cluster check       # → fe_sendauth: no password supplied
mv /var/lib/postgresql/.pgpass.bak /var/lib/postgresql/.pgpass
# 3. Вернуть .pgpass — check снова проходит (значит идёт scram, а не trust)
pgbackrest --stanza=pg-cluster check       # → completed successfully
```

---

## 13. Альтернатива: репозиторий в S3 / object storage

До сих пор репозиторий был **posix-каталогом на выделенном SSH-хосте** (`backup1`,
`repo1-path=/var/lib/pgbackrest`). pgBackRest умеет хранить репозиторий и в **object
storage** — AWS S3, Google Cloud Storage, Azure Blob, а также S3-совместимых хранилищах
(MinIO, Ceph RGW, Yandex/VK Cloud Object Storage и т.п.). Ниже — вариант с **S3**.

**Когда это уместно:** целевая архитектура — облако; нужен off-site репозиторий без
собственного «железного» repo-хоста; хочется дешёвого масштабируемого хранилища и
георезервирования на стороне провайдера.

Важно: **сами команды и концепции не меняются** — stanza, full/diff/incr, PITR,
`archive-push`/`archive-get`, `stanza-create`, `check`, `restore` идентичны. Меняется
**только описание репозитория** (`repo1-*`). Всё из [раздела 12](#12-выделенная-роль-postgresql-и-аутентификация-без-суперпользователя)
(выделенная роль БД, `.pgpass`, pg_hba) остаётся в силе — оно про подключение к
PostgreSQL, а не про репозиторий.

### 13.1. Что меняется по сравнению с SSH-репо-хостом

| | SSH repo-хост (текущий) | S3 (object storage) |
|---|---|---|
| Где лежат бэкапы | `/var/lib/pgbackrest` на `backup1` | бакет в S3 |
| `repo1-type` | `posix` (по умолчанию) | `s3` |
| Передача в репозиторий | по SSH на repo-хост | по HTTPS в S3 |
| `repo1-host` / SSH-ключи repo↔db | нужны | **не нужны** для доступа к репозиторию |
| Шифрование | опционально | **настоятельно** client-side (`aes-256-cbc`) |
| Кто «держит» репозиторий | отдельный хост | провайдер |

Возможны две топологии:

- **A. Без выделенного repo-хоста (типично для S3).** Каждая нода БД в своём
  `pgbackrest.conf` имеет `repo1-type=s3` и напрямую пушит WAL/бэкапы в бакет.
  `pgN-host`/SSH между repo и db больше не нужны. Команду `backup` запускают по
  расписанию на одной из нод (или на любом хосте с доступом к бакету и к БД).
- **B. Выделенный backup-хост + S3.** Оставляем `backup1` как «оркестратор», который
  инициирует `backup` и по SSH ходит к db-нодам за данными (`pgN-host` как сейчас), но
  сам репозиторий стримит уже не на локальный диск, а в S3. Полезно, если не хотите
  давать креденшелы S3 всем db-нодам.

### 13.2. Параметры S3 (`repo1-s3-*`)

| Параметр | Пример | Описание |
|---|---|---|
| `repo1-type` | `s3` | Тип репозитория — object storage S3. |
| `repo1-path` | `/pg-cluster` | **Префикс внутри бакета** (не путь на диске). Под ним появятся `backup/` и `archive/`. |
| `repo1-s3-bucket` | `pgbackrest-prod` | Имя бакета. |
| `repo1-s3-endpoint` | `s3.amazonaws.com` / `storage.yandexcloud.net` / `minio.local:9000` | Хост S3 API. Для S3-совместимых — их эндпоинт. |
| `repo1-s3-region` | `us-east-1` / `ru-central1` | Регион. У части S3-совместимых любой валидный (например `us-east-1`). |
| `repo1-s3-uri-style` | `host` (AWS) / `path` (MinIO, Ceph, многие совместимые) | Как формируется URL: `bucket.endpoint` (host) или `endpoint/bucket` (path). |
| `repo1-s3-key` | `AKIA...` | Access key ID. **Секрет → vault.** |
| `repo1-s3-key-secret` | `wJalr...` | Secret access key. **Секрет → vault.** |
| `repo1-s3-key-type` | `shared` (по умолч.) / `auto` | `shared` — ключ+секрет; `auto` — IAM instance profile / web-identity (без статичных ключей). |
| `repo1-s3-token` | (нет) | Session token для временных STS-креденшелов (если применимо). |
| `repo1-storage-verify-tls` | `y` (по умолч.) | Проверять TLS-сертификат эндпоинта. Отключать только для тестовых MinIO по HTTP. |
| `repo1-storage-ca-file` | `/etc/ssl/…/ca.crt` | Свой CA (частный MinIO/Ceph с собственным сертификатом). |
| `repo1-cipher-type` | `aes-256-cbc` | **Client-side шифрование репозитория** — для object storage настоятельно рекомендуется. |
| `repo1-cipher-pass` | `<секрет>` | Пароль шифрования. **Секрет → vault.** |

### 13.3. Пример `pgbackrest.conf` с S3 (топология A)

```ini
[global]
# --- Репозиторий в S3 ---
repo1-type=s3
repo1-path=/pg-cluster
repo1-s3-bucket=pgbackrest-prod
repo1-s3-endpoint=s3.amazonaws.com
repo1-s3-region=us-east-1
repo1-s3-uri-style=host
repo1-s3-key=AKIAIOSFODNN7EXAMPLE
repo1-s3-key-secret=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

# Шифрование обязательно — данные уходят к внешнему провайдеру
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=<длинный-случайный-секрет-из-vault>

# Хранение / производительность (как и раньше)
repo1-retention-full=2
compress-type=zst
process-max=4
start-fast=y

log-path=/var/log/pgbackrest
log-level-console=info
log-level-file=detail

# --- Stanza: описание локального PostgreSQL ---
# В топологии A pgBackRest работает на самой ноде → знает только про себя.
[pg-cluster]
pg1-path=/var/lib/postgresql/16/data
pg1-port=5432
pg1-socket-path=/var/run/postgresql
pg1-user=pgbackrest
pg1-database=postgres
```

> В топологии B (`backup1` + S3) секция `[global]` та же, но stanza на `backup1`
> по-прежнему перечисляет `pgN-host`/`pgN-host-user`/`pgN-path` для всех нод — как
> в [разделе 6](#6-архитектура-в-этом-проекте). Отличие от текущего проекта — только
> блок `repo1-*` (S3 вместо posix-пути).

### 13.4. Аутентификация в S3: ключи vs IAM-роль

- **Статичные ключи** (`repo1-s3-key-type=shared`, по умолчанию): `repo1-s3-key` +
  `repo1-s3-key-secret`. Просто, но ключи надо хранить и ротировать (обязательно в vault,
  файл конфига — `0640`/`0600`).
- **IAM-роль** (`repo1-s3-key-type=auto`): на EC2/EKS/GKE креденшелы берутся автоматически
  из instance profile или web-identity — статичных ключей в конфиге нет вообще. Это
  предпочтительный вариант в облаке (нечего утекать).

### 13.5. S3-совместимые хранилища (MinIO / Ceph / Yandex / VK Cloud)

Работают через тот же драйвер `s3`, отличия:
- `repo1-s3-endpoint` — эндпоинт провайдера (напр. `storage.yandexcloud.net`).
- `repo1-s3-uri-style=path` — большинству совместимых хранилищ нужен path-style
  (`endpoint/bucket`), тогда как AWS — `host`.
- `repo1-s3-region` — часто подойдёт любой валидный (`us-east-1`), у ЯО/VK — свой.
- Приватный TLS: `repo1-storage-ca-file=<ваш CA>`; HTTP-тест (без TLS) —
  `repo1-storage-verify-tls=n` (только для песочницы).

### 13.6. Что поменять в Ansible проекта (набросок)

Полноценно не реализовано (текущий проект — SSH repo-хост), но интеграция сводится к:

| Что | Как |
|---|---|
| Секреты S3 | `vault_pgbackrest_s3_key`, `vault_pgbackrest_s3_key_secret`, `vault_pgbackrest_cipher_pass` в `group_vars/all/vault.yml` |
| Переменные | `pgbackrest_repo_type: s3`, `pgbackrest_s3_bucket/endpoint/region/uri_style`, `pgbackrest_cipher_type: aes-256-cbc` |
| Шаблон | в `pgbackrest.conf.j2` — ветка `{% if pgbackrest_repo_type == 's3' %}` с блоком `repo1-s3-*` вместо `repo1-host`/`repo1-path`-каталога |
| Роль/плейбук | убрать создание системного пользователя и каталога репозитория на `backup1` (топология A); SSH-обмен ключами repo↔db больше не нужен |
| Инициализация | `stanza-create` теперь создаёт структуру **в бакете** — предварительно бакет должен существовать и быть доступен по ключам/роли |

### 13.7. Команды и восстановление — без изменений

```bash
# Всё как в разделах 10–11, отличается только репозиторий (S3):
pgbackrest --stanza=pg-cluster stanza-create
pgbackrest --stanza=pg-cluster check
pgbackrest --stanza=pg-cluster --type=full backup
pgbackrest --stanza=pg-cluster info
pgbackrest --stanza=pg-cluster --delta --type=time \
    --target="2026-07-29 14:32:00" --target-action=promote restore
```

pgBackRest сам ходит в S3 согласно `repo1-*`; синтаксис команд, PITR и интеграция с
Patroni ([раздел 8](#8-особенности-работы-с-patroni)) остаются прежними.

---

## 14. Ручная настройка SSH между хостами (без Ansible)

В модели выделенного repo-хоста pgBackRest общается по SSH в **обе стороны**, поэтому
нужна **взаимная** авторизация ключей (напоминание из [раздела 6](#6-архитектура-в-этом-проекте)):

```
postgres@pgN     ──SSH──▶  pgbackrest@backup1     # archive-push (WAL с ноды в репо)
pgbackrest@backup1 ──SSH──▶ postgres@pgN          # backup / restore / stanza-create
```

Ниже — как настроить это руками (то же, что делает роль `ssh.yml`, но пошагово в shell).
Все команды — от `root` (или через `sudo`). Имена/хосты — из этого проекта:
repo-хост `backup1`, ноды `pg1`/`pg2`/`pg3`, OS-пользователи `pgbackrest` (на repo) и
`postgres` (на нодах).

### 14.1. Пользователь на repo-хосте

На нодах БД `postgres` уже существует. На **backup1** создаём системного пользователя
`pgbackrest` — обязательно с login-шеллом (иначе SSH-команды не выполнятся):

```bash
# на backup1
useradd --create-home --home-dir /home/pgbackrest --shell /bin/bash pgbackrest
```

### 14.2. Генерация ключевых пар

По ключу на каждой стороне. Тип `ed25519` (короткий и безопасный).

```bash
# на backup1 — под пользователем pgbackrest
sudo -u pgbackrest ssh-keygen -t ed25519 -N '' \
     -f /home/pgbackrest/.ssh/id_ed25519 -C pgbackrest@backup1

# на КАЖДОЙ ноде pg1/pg2/pg3 — под пользователем postgres
sudo -u postgres ssh-keygen -t ed25519 -N '' \
     -f /var/lib/postgresql/.ssh/id_ed25519 -C "postgres@$(hostname)"
```

`ssh-keygen` сам создаёт `~/.ssh` с правами `700`. Если каталог создавали вручную —
проверьте права в шаге 14.4.

### 14.3. Обмен публичными ключами (взаимно!)

**(а) Ключ `pgbackrest@backup1` → на все ноды БД** (чтобы repo-хост заходил к `postgres@pgN`):

```bash
# посмотреть публичный ключ на backup1
sudo -u pgbackrest cat /home/pgbackrest/.ssh/id_ed25519.pub
```
Добавить эту строку в `authorized_keys` пользователя `postgres` на КАЖДОЙ ноде:
```bash
# на pg1, pg2, pg3
echo 'ssh-ed25519 AAAA...pgbackrest@backup1' \
  | sudo -u postgres tee -a /var/lib/postgresql/.ssh/authorized_keys
```

**(б) Ключ `postgres@pgN` (с каждой ноды) → на backup1** (чтобы ноды пушили WAL к `pgbackrest@backup1`):

```bash
# на каждой ноде — показать её публичный ключ
sudo -u postgres cat /var/lib/postgresql/.ssh/id_ed25519.pub
```
Добавить ВСЕ три строки в `authorized_keys` пользователя `pgbackrest` на backup1:
```bash
# на backup1 — по строке от pg1, pg2, pg3
echo 'ssh-ed25519 AAAA...postgres@pg1' \
  | sudo -u pgbackrest tee -a /home/pgbackrest/.ssh/authorized_keys
# ...повторить для postgres@pg2 и postgres@pg3
```

> Альтернатива вручную: `ssh-copy-id`. Но у системных пользователей часто нет пароля
> для входа, поэтому надёжнее показанный способ «показать pub → дописать в authorized_keys».

### 14.4. Права и владельцы (SSH строг к правам)

SSH молча игнорирует ключи при слишком открытых правах. Привести в порядок на **каждом**
хосте для соответствующего пользователя:

```bash
# backup1 (пользователь pgbackrest)
chown -R pgbackrest:pgbackrest /home/pgbackrest/.ssh
chmod 700 /home/pgbackrest/.ssh
chmod 600 /home/pgbackrest/.ssh/id_ed25519 /home/pgbackrest/.ssh/authorized_keys
chmod 644 /home/pgbackrest/.ssh/id_ed25519.pub

# pgN (пользователь postgres) — аналогично
chown -R postgres:postgres /var/lib/postgresql/.ssh
chmod 700 /var/lib/postgresql/.ssh
chmod 600 /var/lib/postgresql/.ssh/id_ed25519 /var/lib/postgresql/.ssh/authorized_keys
```

### 14.5. Проверка host-ключей (known_hosts)

При первом соединении SSH спросит про подлинность хоста — в неинтерактивном режиме
(cron, pgBackRest) это приведёт к зависанию/ошибке. Два варианта:

**Проще (учебно):** `~/.ssh/config` с `accept-new` — принять ключ при первом контакте:
```bash
# на backup1 (для pgbackrest) и на каждой ноде (для postgres)
cat > /home/pgbackrest/.ssh/config <<'EOF'
Host pg1 pg2 pg3 backup1
    StrictHostKeyChecking accept-new
    LogLevel ERROR
EOF
chown pgbackrest:pgbackrest /home/pgbackrest/.ssh/config
chmod 600 /home/pgbackrest/.ssh/config
```

**Безопаснее (production):** заранее наполнить `known_hosts` пиннингом ключей:
```bash
sudo -u pgbackrest bash -c 'ssh-keyscan -t ed25519 pg1 pg2 pg3 >> ~/.ssh/known_hosts'
sudo -u postgres  bash -c 'ssh-keyscan -t ed25519 backup1  >> ~/.ssh/known_hosts'
```

### 14.6. Проверка связности в обе стороны

```bash
# repo → db (нужно для backup/restore)
sudo -u pgbackrest ssh postgres@pg1 hostname   # → pg1
sudo -u pgbackrest ssh postgres@pg2 hostname
sudo -u pgbackrest ssh postgres@pg3 hostname

# db → repo (нужно для archive-push)
sudo -u postgres ssh pgbackrest@backup1 hostname   # → backup1  (запустить на каждой ноде)
```

Обе стороны должны логиниться **без пароля**. После этого — сквозная проверка pgBackRest
(она гоняет тестовый WAL и обращается к нодам по SSH):

```bash
sudo -u pgbackrest pgbackrest --stanza=pg-cluster check   # → completed successfully
```

### 14.7. Частые проблемы

| Симптом | Причина | Решение |
|---|---|---|
| `Permission denied (publickey)` | pub-ключ не в `authorized_keys` нужного пользователя, либо не та сторона | Проверить, что ключ **инициатора** лежит у **цели** (14.3) |
| SSH просит пароль | слишком открытые права на `~/.ssh`/ключах — ключ игнорируется | Выставить права из 14.4 |
| `Host key verification failed` | host-ключ не в `known_hosts` | `accept-new` или `ssh-keyscan` (14.5) |
| `... /bin/false` / соединение рвётся | у `pgbackrest` нет login-шелла | `usermod -s /bin/bash pgbackrest` (14.1) |
| pgBackRest: `remote-0 ssh protocol ... unable to ...` | не работает нужное направление SSH | Проверить обе стороны из 14.6 |

> Направления и «кто к кому» подробно — в [разделе 6](#6-архитектура-в-этом-проекте);
> про то, что для **самого подключения к БД** используется не SSH, а сокет+роль — в
> [разделе 12](#12-выделенная-роль-postgresql-и-аутентификация-без-суперпользователя).

---

## 15. Диагностика и типичные ошибки

| Симптом / ошибка | Причина | Решение |
|---|---|---|
| `ERROR: [087]: archive_mode must be enabled` | Архивация не включена на **primary** (часто — из-за гонки edit-config→restart, [8.4](#84--главный-подводный-камень-гонка-edit-config--restart)). | Убедиться `SHOW archive_mode` = `on` на лидере; при необходимости `reload`+рестарт лидера. |
| `fe_sendauth: no password supplied` | Роль `pgbackrest` идёт через scram, но `.pgpass` не найден/не матчится (host ≠ `localhost`). | Проверить `~/.pgpass` OS-пользователя на ноде БД: host=`localhost`, режим `0600` ([12.4](#124-пароль-через-pgpass-нюанс-с-host)). |
| `unable to select some rows from pg_settings` | Роли `pgbackrest` не выдан `pg_read_all_settings`. | `GRANT pg_read_all_settings TO pgbackrest;` ([12.2](#122-минимальные-права-роли-проверено-на-pg-16)). |
| `permission denied for function pg_backup_start` | Роли не выдан EXECUTE на backup-функции. | Выдать 4 гранта из [12.2](#122-минимальные-права-роли-проверено-на-pg-16). |
| `check` виснет / WAL не доезжает | `archive_command` не работает: нет SSH-доступа, неверный `repo1-host`, права. | Проверить `pg_stat_archiver.failed_count`, лог pgBackRest, ручной `archive-push`, SSH-связность. |
| `stanza-create` пишет `already exists` | Stanza уже создана — это норма. | Ничего не делать; операция идемпотентна. |
| `unable to find user pgbackrest` | На репо-хосте нет системного пользователя `pgbackrest`. | Прогнать роль (PLAY 1 создаёт пользователя в `ssh.yml`). |
| Backup «висит» на ожидании WAL | Сегменты WAL не архивируются (см. выше) — backup не может дождаться границ. | Починить архивацию; проверить `archive_timeout`. |
| `ERROR: ... could not open ... permission denied` | Несовпадение владельца `PGDATA` и `pgN-host-user`, или прав на `repo1-path`. | `pgN-host-user` должен владеть `PGDATA`; репозиторий — пользователем `pgbackrest`. |
| PostgreSQL не стартует после смены `archive_mode` | В DCS записалось `archive_mode = 'True'` (YAML-boolean). | Квотировать значение: `-p 'archive_mode="on"'` ([8.5](#85-ещё-одна-тонкость-квотирование-enum-значений)). |

### Полезные проверки

```bash
# Состояние архивации на primary
psql -U postgres -xc "SELECT * FROM pg_stat_archiver;"

# Что видит pgBackRest (статус stanza, список бэкапов, диапазон WAL)
pgbackrest --stanza=pg-cluster info

# Ручная проверка связности и archive_command
pgbackrest --stanza=pg-cluster check

# Логи
tail -n 100 /var/log/pgbackrest/pg-cluster-*.log
```

---

## Итог

- **stanza** = один PostgreSQL-кластер в pgBackRest (`pg-cluster`).
- **backup** = физическая онлайн-копия `PGDATA`; **full/diff/incr** экономят место.
- **WAL archiving** (`archive_command` → `archive-push`) = непрерывный поток изменений,
  без него нет ни PITR, ни возможности завершить backup.
- **PITR** = бэкап + доигрывание WAL до нужного момента (`--type=time`).
- В **Patroni** параметры архивации меняются через `edit-config` (DCS), а методы
  реплик/восстановления — через `patroni.yml` (`reload`); **`archive_mode` требует
  рестарта**, а рестарт нельзя делать сразу после `edit-config` — сначала дождаться
  `Pending restart` на всех нодах.
- Проект использует модель **выделенного репо-хоста** по SSH — бэкапы хранятся отдельно
  от серверов БД.
- pgBackRest ходит в БД **только через Unix-socket** (TCP нет). Для безопасности —
  **выделенная non-superuser роль** `pgbackrest` + `scram` по сокету + `.pgpass`
  (без `postgres`/`trust`), права минимальны: 4 backup-функции + `pg_read_all_settings`
  ([раздел 12](#12-выделенная-роль-postgresql-и-аутентификация-без-суперпользователя)).

**Файлы проекта:** роль `ansible/roles/pgbackrest/`, плейбук
`ansible/04_pgbackrest_playbook.yml`, PITR-демо `ansible/05_pitr_demo_playbook.yml`,
шаблон Patroni `ansible/templates/patroni.yml.j2`.
