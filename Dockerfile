# ============================================================
# Base image для всех узлов кластера (etcd + patroni)
# Ubuntu 24.04 с systemd и SSH для Ansible
# ============================================================
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
# Говорим systemd, что мы в контейнере
ENV container=docker

# -----------------------------------------------------------
# Устанавливаем базовые пакеты
# -----------------------------------------------------------
RUN apt-get update && apt-get install -y \
    # Systemd — нужен для управления сервисами через Ansible (systemctl)
    systemd \
    systemd-sysv \
    dbus \
    # SSH — точка входа для Ansible
    openssh-server \
    # Python3 — обязателен для работы Ansible на managed-нодах
    python3 \
    python3-pip \
    # Утилиты
    sudo \
    curl \
    wget \
    gnupg \
    lsb-release \
    apt-transport-https \
    ca-certificates \
    iproute2 \
    net-tools \
    vim \
    less \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------
# Зачищаем systemd-юниты, которые не работают в контейнере.
# Без этого /sbin/init зависнет при старте.
# -----------------------------------------------------------
RUN systemctl mask \
    dev-hugepages.mount \
    sys-fs-fuse-connections.mount \
    sys-kernel-config.mount \
    sys-kernel-debug.mount \
    sys-kernel-tracing.mount \
    display-manager.service \
    getty@.service \
    getty.target \
    graphical.target \
    kmod-static-nodes.service \
    plymouth-quit-wait.service \
    plymouth.service \
    systemd-ask-password-console.path \
    systemd-ask-password-console.service \
    systemd-ask-password-wall.path \
    systemd-ask-password-wall.service \
    systemd-logind.service \
    systemd-udev-trigger.service \
    systemd-udevd.service \
    systemd-update-utmp.service \
    udev.service

# -----------------------------------------------------------
# Настраиваем SSH
# -----------------------------------------------------------
RUN mkdir -p /var/run/sshd && \
    # Генерируем host-ключи
    ssh-keygen -A && \
    # Разрешаем аутентификацию по ключу
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/#AuthorizedKeysFile/AuthorizedKeysFile/' /etc/ssh/sshd_config && \
    # Ускоряем подключение (отключаем DNS lookup)
    echo "UseDNS no" >> /etc/ssh/sshd_config

# -----------------------------------------------------------
# Создаём пользователя ansible (от его имени будет работать Ansible)
# -----------------------------------------------------------
RUN useradd -m -s /bin/bash ansible && \
    # Беспарольный sudo — нужен для установки пакетов и управления systemd
    # через Ansible на всех нодах (провижнинг требует широкого root, поэтому
    # ограничение набора команд ломает become). Это осознанный выбор для
    # контейнерного стенда; в production sudo ужесточается вместе с уходом
    # от Docker-субстрата — см. раздел 3 в prod-plan.todo.
    echo 'ansible ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ansible && \
    chmod 440 /etc/sudoers.d/ansible && \
    mkdir -p /home/ansible/.ssh && \
    chmod 700 /home/ansible/.ssh

# Копируем публичный ключ (генерируется скриптом setup.sh перед сборкой)
COPY ssh/id_rsa.pub /home/ansible/.ssh/authorized_keys
RUN chmod 600 /home/ansible/.ssh/authorized_keys && \
    chown -R ansible:ansible /home/ansible/.ssh

# Включаем SSH при старте systemd
RUN systemctl enable ssh

# Ubuntu 24.04 по умолчанию использует graphical.target,
# часть его зависимостей недоступна в контейнере → systemd уходит в rescue.
# Явно переключаем на multi-user.target.
RUN systemctl set-default multi-user.target

EXPOSE 22

# cgroup монтируется с хоста (нужен systemd)
VOLUME ["/sys/fs/cgroup"]

# Точка входа — systemd init
CMD ["/sbin/init"]
