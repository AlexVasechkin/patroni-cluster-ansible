# Patroni Cluster — учебный стенд HA PostgreSQL

Учебный проект по развёртыванию отказоустойчивого кластера PostgreSQL на базе
**Patroni + etcd**, с пулингом соединений через **PgBouncer** и резервным
копированием / PITR через **pgBackRest**.

Вся инфраструктура поднимается в Docker-контейнерах (Ubuntu 24.04 + systemd),
а конфигурация раскатывается через Ansible. Стенд рассчитан на локальный запуск
и изучение — не для production.

---

## Архитектура

```
                     ┌─────────────────────────────────────────┐
                     │        etcd cluster (DCS, кворум)         │
                     │  etcd1        etcd2        etcd3          │
                     │  .11          .12          .13           │
                     └───────────────┬───────────────────────── ┘
                                     │ хранит: лидера, конфиг кластера
                     ┌───────────────┴───────────────┐
                     ▼                                ▼
         ┌───────────────────────┐        ┌───────────────────────┐
         │  pg1  172.20.0.21      │◀──────▶│  pg2  172.20.0.22      │
         │  PostgreSQL + Patroni  │ stream │  PostgreSQL + Patroni  │
         │  (primary)             │  repl  │  (replica)             │
         └───────────┬───────────┘        └───────────────────────┘
                     ▲                                │
   клиенты ─────────┐│                               │ archive-push (WAL)
                    ││                                ▼
         ┌──────────┴┴──────────┐        ┌───────────────────────┐
         │  pgbouncer1  .30      │        │  backup1  172.20.0.40  │
         │  connection pooler    │        │  pgBackRest repo       │
         │  :6432 → primary      │        │  бэкапы + архив WAL    │
         └───────────────────────┘        └───────────────────────┘
```

### Узлы

| Хост         | IP            | Роль                                  | SSH-порт | Прочие порты (host)      |
|--------------|---------------|---------------------------------------|----------|--------------------------|
| `etcd1`      | 172.20.0.11   | etcd (DCS)                            | 2221     | 2379, 2380               |
| `etcd2`      | 172.20.0.12   | etcd (DCS)                            | 2222     | 2381→2379, 2382→2380     |
| `etcd3`      | 172.20.0.13   | etcd (DCS)                            | 2223     | 2383→2379, 2384→2380     |
| `pg1`        | 172.20.0.21   | PostgreSQL 16 + Patroni (primary)     | 2224     | 5432, 8008               |
| `pg2`        | 172.20.0.22   | PostgreSQL 16 + Patroni (replica)     | 2225     | 5433→5432, 8009→8008     |
| `pgbouncer1` | 172.20.0.30   | PgBouncer (connection pooler)         | 2226     | 6432                     |
| `backup1`    | 172.20.0.40   | pgBackRest (репозиторий бэкапов)      | 2227     | —                        |

- **etcd** — распределённый DCS (Distributed Configuration Store). 3 ноды дают
  кворум: кластер жив, пока работают 2 из 3.
- **Patroni** управляет жизненным циклом PostgreSQL, выбирает primary и выполняет
  автоматический failover через etcd.
- **PgBouncer** держит пул соединений и направляет трафик на текущий primary.
- **pgBackRest** на выделенном узле хранит бэкапы и архив WAL (для PITR).

---

## Требования

- Docker + Docker Compose
- Ansible (core 2.20+) на хост-машине
- `ssh-keygen`, `ssh-keyscan`, свободные порты `2221–2227`, `5432/5433`, `6432`, `8008/8009`

---

## Быстрый старт

### 1. Поднять инфраструктуру

```bash
./setup.sh
```

Скрипт: генерирует SSH-ключ для Ansible, собирает Docker-образ, запускает
контейнеры и добавляет их host-ключи в `~/.ssh/known_hosts`.

Проверка доступности:

```bash
cd ansible
ansible -i inventory.ini all -m ping
```

### 2. Раскатать кластер (плейбуки запускаются по порядку)

```bash
cd ansible

ansible-playbook -i inventory.ini 01_etcd_playbook.yml       # etcd-кластер
ansible-playbook -i inventory.ini 02_patroni_playbook.yml    # PostgreSQL + Patroni
ansible-playbook -i inventory.ini 03_pgbouncer_playbook.yml  # PgBouncer
ansible-playbook -i inventory.ini 04_pgbackrest_playbook.yml # бэкапы + архив WAL
```

### 3. Проверить кластер

```bash
# Состояние кластера Patroni
docker exec -it pg1 patronictl -c /etc/patroni/patroni.yml list

# Подключение через PgBouncer (с хоста)
psql -h localhost -p 6432 -U postgres -d postgres
```

---

## Плейбуки

| Плейбук                       | Назначение                                                                 |
|-------------------------------|----------------------------------------------------------------------------|
| `01_etcd_playbook.yml`        | Установка и настройка etcd-кластера (3 ноды, systemd, healthcheck).         |
| `02_patroni_playbook.yml`     | PostgreSQL 16 + Patroni: primary (pg1), затем реплика (pg2).                |
| `03_pgbouncer_playbook.yml`   | PgBouncer + перевод pg_hba `md5 → scram-sha-256`.                           |
| `04_pgbackrest_playbook.yml`  | pgBackRest: SSH repo↔db, `archive_mode`, stanza, первый full backup, cron. |
| `05_pitr_demo_playbook.yml`   | **Разрушающая** демонстрация PITR — пересобирает кластер из бэкапа.         |

Демо PITR запускается с явным подтверждением:

```bash
ansible-playbook -i inventory.ini 05_pitr_demo_playbook.yml -e pitr_confirm=true
```

---

## Конфигурация

Все настраиваемые значения вынесены в переменные — хардкода в плейбуках нет.

| Файл                              | Что задаёт                                                        |
|-----------------------------------|------------------------------------------------------------------|
| `ansible/inventory.ini`           | Хосты, группы, SSH-параметры подключения.                        |
| `ansible/group_vars/all/vars.yml` | Версии, имя кластера, сеть, ноды etcd/pg, порты, учётки, pgBackRest. |
| `ansible/group_vars/all/vault.yml`| Секреты (пароли), зашифровано ansible-vault.                      |
| `ansible/group_vars/etcd.yml`     | Пути, порты, токен, тайминги Raft и логирование etcd.            |
| `ansible/group_vars/postgres.yml` | Пути, порты, параметры PostgreSQL и Patroni, pg_hba, watchdog.   |
| `ansible/host_vars/*.yml`         | IP каждого конкретного узла.                                     |
| `ansible/roles/*/defaults/`       | Дефолты ролей PgBouncer и pgBackRest.                            |

Ключевые параметры (`group_vars/all/vars.yml`):

```yaml
etcd_version: "3.5.13"
postgresql_version: "16"
patroni_cluster_name: "pg-cluster"
cluster_subnet: "172.20.0.0/24"
etcd_client_port: 2379          # единый источник; endpoints строятся из etcd_nodes
patroni_api_port: 8008
pgbackrest_enabled: false       # true — поднимать кластер сразу с архивацией WAL
```

### Секреты (ansible-vault)

Пароли вынесены из репозитория в зашифрованный файл:

- `ansible/group_vars/all/vars.yml` — несекретные переменные; пароли ссылаются
  на `vault_*`.
- `ansible/group_vars/all/vault.yml` — секреты (`vault_patroni_*_password`),
  зашифрованы `ansible-vault`.
- `ansible/.vault_pass` — файл с паролем от vault. **Не коммитится** (в
  `.gitignore`); путь к нему прописан в `ansible/ansible.cfg`.

```bash
cd ansible
ansible-vault view group_vars/all/vault.yml   # посмотреть секреты
ansible-vault edit group_vars/all/vault.yml   # изменить
ansible-vault rekey group_vars/all/vault.yml  # сменить пароль vault
```

При клонировании репозитория на новую машину положите пароль vault в
`ansible/.vault_pass` (или запускайте плейбуки с `--ask-vault-pass`).

> ⚠️ Значения паролей в стенде учебные. Смените их (`ansible-vault edit`) и
> сгенерируйте новый `.vault_pass` перед любым реальным использованием.

### Замена всех паролей для production

Учебные пароли (`postgres_pass`, `replicator_pass`) и авто-сгенерированный
`.vault_pass` **обязательно** заменить. Порядок зависит от того, разворачиваете
вы кластер с нуля или меняете пароли на уже работающем.

#### Шаг 1. Сгенерировать стойкие пароли

```bash
openssl rand -base64 24   # для суперпользователя
openssl rand -base64 24   # для пользователя репликации
```

#### Шаг 2. Сменить пароль самого vault (`.vault_pass`)

```bash
cd ansible
openssl rand -base64 32 > .vault_pass   # новый пароль vault (файл gitignored, mode 600)
chmod 600 .vault_pass
ansible-vault rekey group_vars/all/vault.yml   # перешифровать существующий файл
```

> `.vault_pass` не хранится в git. На каждой машине, откуда запускаются
> плейбуки, положите его вручную или используйте `--ask-vault-pass`.

#### Шаг 3. Записать новые пароли в vault

```bash
ansible-vault edit group_vars/all/vault.yml
```

Замените значения (кавычки обязательны, спецсимволы допустимы):

```yaml
vault_patroni_superuser_password:   "<новый-пароль-superuser>"
vault_patroni_replication_password: "<новый-пароль-replication>"
```

Проверка, что всё расшифровывается и подставляется:

```bash
ansible localhost -m debug -a "var=patroni_superuser_password"
```

#### Шаг 4a. Развёртывание с нуля

Если кластер ещё не создан — просто раскатайте плейбуки (`01 → 04`). Patroni
задаст новые пароли при bootstrap, PgBouncer возьмёт их из vault. Больше делать
ничего не нужно.

#### Шаг 4b. Смена паролей на уже работающем кластере

initdb выполняется один раз, поэтому смена пароля в vault **не** меняет пароли
в уже созданной БД автоматически (секция `bootstrap.users` применяется только
при создании кластера). Нужно применить их к живому кластеру вручную:

```bash
cd ansible

# 1. Меняем пароли ролей в PostgreSQL (выполнять на текущем primary).
#    Роль реплики — та же, что в vault (по умолчанию replicator).
docker exec -it pg1 psql -U postgres -c \
  "ALTER ROLE postgres   WITH PASSWORD '<новый-пароль-superuser>';"
docker exec -it pg1 psql -U postgres -c \
  "ALTER ROLE replicator WITH PASSWORD '<новый-пароль-replication>';"

# 2. Перегенерируем patroni.yml из vault (пароли для pg_rewind/basebackup).
ansible-playbook 02_patroni_playbook.yml

# 3. Перегенерируем userlist.txt PgBouncer из vault и делаем reload.
ansible-playbook 03_pgbouncer_playbook.yml --tags configure
```

После смены пароля репликации проверьте, что реплика не отвалилась:

```bash
docker exec -it pg1 patronictl -c /etc/patroni/patroni.yml list
```

#### Шаг 5. Прочие секреты (для реального production)

Помимо паролей БД смените и остальные учётные данные из лабораторного стенда:

- **SSH-ключ Ansible** — `ssh/id_rsa` генерируется `setup.sh`; для prod
  используйте свой управляемый ключ, не общий на весь кластер.
- **Шифрование репозитория pgBackRest** — включите `pgbackrest_cipher_type:
  aes-256-cbc` + `repo1-cipher-pass` (тоже в vault). См. раздел 2 в
  `prod-plan.todo`.
- **TLS-сертификаты** etcd / PostgreSQL / Patroni REST — раздел 2 в
  `prod-plan.todo`.

---

## Типовые операции

**Состояние и ручной switchover:**

```bash
docker exec -it pg1 patronictl -c /etc/patroni/patroni.yml list
docker exec -it pg1 patronictl -c /etc/patroni/patroni.yml switchover
```

**Проверка failover** — остановите текущий primary и посмотрите, как Patroni
промоутит реплику:

```bash
docker stop pg1
docker exec -it pg2 patronictl -c /etc/patroni/patroni.yml list
```

После failover обновите backend PgBouncer:

```bash
docker exec -it pgbouncer1 /usr/local/bin/pgbouncer-update-primary.sh
```

**Бэкапы (pgBackRest, на узле backup1):**

```bash
docker exec -it backup1 sudo -u pgbackrest pgbackrest --stanza=pg-cluster info
docker exec -it backup1 /usr/local/bin/pgbackrest-backup.sh full   # full | diff | incr
```

---

## Управление стендом

```bash
docker compose ps                 # статус контейнеров
docker compose down               # остановить (данные сохраняются в томах)
docker compose down -v            # остановить и УДАЛИТЬ данные + бэкапы
docker compose logs -f pg1        # логи узла
```

Данные PostgreSQL и репозиторий бэкапов живут в именованных Docker-томах
(`patroni_pg1_data`, `patroni_pg2_data`, `patroni_backup_repo`) и переживают
`docker compose down`.

---

## Структура репозитория

```
.
├── Dockerfile              # базовый образ узла (Ubuntu 24.04 + systemd + SSH)
├── docker-compose.yml      # топология: 3× etcd, 2× pg, pgbouncer, backup
├── setup.sh                # генерация ключей + сборка + запуск контейнеров
├── ssh/                    # SSH-ключи для Ansible (приватный не коммитится)
├── ansible/
│   ├── inventory.ini
│   ├── 0X_*.yml            # плейбуки этапов развёртывания
│   ├── group_vars/         # переменные по группам (all / etcd / postgres)
│   ├── host_vars/          # IP конкретных узлов
│   ├── templates/          # шаблоны etcd / Patroni (systemd, конфиги)
│   └── roles/
│       ├── pgbouncer/
│       └── pgbackrest/
└── docs/                   # дополнительные заметки (пулеры, pgBackRest)
```

---

## Примечания

- Стенд учебный: watchdog отключён, TLS не используется, пароли в открытом виде.
- Контейнеры запускаются с `privileged: true` и смонтированным `cgroup` — это
  необходимо, чтобы внутри работал systemd.
- Порядок запуска плейбуков важен: `01 → 02 → 03 → 04`. Плейбук `05` — отдельная
  разрушающая демонстрация PITR.
```
