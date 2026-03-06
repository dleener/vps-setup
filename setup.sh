#!/bin/bash

# ==============================================================================
# Скрипт базовой настройки безопасности VPS на Ubuntu 24.04
# GitHub: [Ваш_Ник/Ваш_Репозиторий]
# ==============================================================================

set -e # Остановка скрипта при ошибках

# --- Цвета для вывода ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # Без цвета

info() { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
prompt() { echo -n -e "${YELLOW}[PROMPT]${NC} $1"; }

# --- Проверка прав root ---
if [ "$EUID" -ne 0 ]; then
  error "Пожалуйста, запустите этот скрипт от имени root (sudo -i или sudo ./script.sh)."
  exit 1
fi

echo -e "${GREEN}=======================================================${NC}"
echo -e "${GREEN}  Интерактивная настройка безопасности Ubuntu 24.04 LTS  ${NC}"
echo -e "${GREEN}=======================================================${NC}"

# ==============================================================================
# 1. ОБНОВЛЕНИЕ СИСТЕМЫ
# ==============================================================================
info "Запуск обновления системы..."
apt-get update -y
apt-get upgrade -y
success "Система успешно обновлена."

# ==============================================================================
# 2. ОТКЛЮЧЕНИЕ IPv6
# ==============================================================================
info "Отключение IPv6..."
cat <<EOF > /etc/sysctl.d/99-disable-ipv6.conf
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sysctl --system > /dev/null 2>&1
success "IPv6 отключен."

# ==============================================================================
# 3. НАСТРОЙКА SSH (Смена порта и отключение паролей)
# ==============================================================================
info "Настройка SSH..."

# Запрос нового порта
while true; do
    prompt "Введите новый порт для SSH (от 1024 до 65535)[по умолчанию 22]: "
    read -r SSH_PORT
    SSH_PORT=${SSH_PORT:-22}
    if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] &&[ "$SSH_PORT" -ge 1024 ] &&[ "$SSH_PORT" -le 65535 ]; then
        break
    elif [ "$SSH_PORT" -eq 22 ]; then
        break
    else
        error "Пожалуйста, введите корректный номер порта."
    fi
done

# В Ubuntu 24.04 SSH часто управляется через systemd-socket. Отключаем его и включаем классический сервис.
if systemctl is-active --quiet ssh.socket; then
    warning "Обнаружен ssh.socket (стандарт Ubuntu 22.10+). Переключаем на ssh.service..."
    systemctl disable --now ssh.socket > /dev/null 2>&1 || true
    systemctl enable --now ssh.service > /dev/null 2>&1 || true
fi

# Резервная копия конфига
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Удаляем старые записи Port и добавляем новый
sed -i '/^Port /d' /etc/ssh/sshd_config
sed -i '/^#Port /d' /etc/ssh/sshd_config
echo "Port $SSH_PORT" >> /etc/ssh/sshd_config

# Запрос на отключение паролей
warning "ВНИМАНИЕ: Перед отключением входа по паролю убедитесь, что вы уже добавили свой публичный SSH-ключ в ~/.ssh/authorized_keys на этом сервере!"
prompt "Отключить авторизацию по паролю (оставить только по ключу)? (y/n) [y]: "
read -r DISABLE_PASS
DISABLE_PASS=${DISABLE_PASS:-y}

if [[ "$DISABLE_PASS" =~ ^[Yy]$ ]]; then
    # Отключаем пароли в главном конфиге
    sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    
    # Отключаем в drop-in файлах Ubuntu (если есть, например 50-cloud-init.conf)
    if ls /etc/ssh/sshd_config.d/*.conf 1> /dev/null 2>&1; then
        sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config.d/*.conf
    fi
    success "Авторизация по паролю отключена."
else
    info "Авторизация по паролю оставлена включенной."
fi

# ==============================================================================
# 4. НАСТРОЙКА FIREWALL (UFW)
# ==============================================================================
info "Установка и настройка UFW..."
apt-get install ufw -y > /dev/null 2>&1

# Базовые правила
ufw --force reset > /dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing

# Разрешаем новый порт SSH
ufw allow "$SSH_PORT"/tcp
success "Порт $SSH_PORT/tcp (SSH) добавлен в исключения UFW."

# Запрос на открытие дополнительных портов
prompt "Введите дополнительные порты, которые нужно открыть, через пробел (например: 80 443). Если не нужно - нажмите Enter: "
read -r EXTRA_PORTS

if [ -n "$EXTRA_PORTS" ]; then
    for port in $EXTRA_PORTS; do
        ufw allow "$port"
        success "Порт $port открыт."
    done
fi

info "Активация UFW..."
ufw --force enable
success "UFW успешно настроен и активирован."

# ==============================================================================
# 5. НАСТРОЙКА FAIL2BAN
# ==============================================================================
info "Установка Fail2Ban..."
apt-get install fail2ban -y > /dev/null 2>&1

info "Настройка конфигурации Fail2Ban для SSH..."
cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 3
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = $SSH_PORT
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF

systemctl enable fail2ban > /dev/null 2>&1
systemctl restart fail2ban
success "Fail2Ban установлен и защищает порт $SSH_PORT."

# ==============================================================================
# ЗАВЕРШЕНИЕ
# ==============================================================================
info "Перезапуск SSH сервера..."
systemctl restart ssh

echo -e "\n${GREEN}=======================================================${NC}"
echo -e "${GREEN}                 НАСТРОЙКА ЗАВЕРШЕНА!                  ${NC}"
echo -e "${GREEN}=======================================================${NC}"
echo -e "${CYAN}Текущий порт SSH:${NC} $SSH_PORT"
echo -e "${CYAN}Статус UFW:${NC} Активен"
echo -e "${CYAN}Статус Fail2Ban:${NC} Активен\n"
echo -e "${RED}ВАЖНО: НЕ ЗАКРЫВАЙТЕ ЭТУ ТЕРМИНАЛЬНУЮ СЕССИЮ!${NC}"
echo -e "Откройте ${YELLOW}НОВОЕ ОКНО${NC} терминала и убедитесь, что вы можете подключиться к серверу:"
echo -e "Команда: ${YELLOW}ssh -p $SSH_PORT user@your_server_ip${NC}"
echo -e "Только после успешного входа можете закрывать эту сессию."
