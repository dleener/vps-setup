#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Проверка запуска от root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Пожалуйста, запустите скрипт от имени root.${NC}"
  exit 1
fi

clear
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}   VPS Initial Setup & Security (Ubuntu 24.04)      ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo ""

# --- 1. Обновление системы ---
echo -e "${YELLOW}[1/8] Обновление системы и установка пакетов...${NC}"
apt update && apt upgrade -y
# Установка утилит
apt install -y sudo ufw fail2ban rsyslog curl wget git nano

# --- 2. Проверка логов (rsyslog) ---
echo -e "${YELLOW}[2/8] Проверка конфигурации логов...${NC}"
# В Ubuntu 24.04 auth.log может отсутствовать по умолчанию (используется journald),
# но fail2ban часто ищет именно файл.
if [ ! -f /var/log/auth.log ]; then
    echo -e "Файл auth.log не найден. Настраиваем rsyslog..."
    systemctl enable rsyslog
    systemctl start rsyslog
    # Ждем пару секунд, чтобы файл создался
    sleep 2
    if [ -f /var/log/auth.log ]; then
        echo -e "${GREEN}Log файл создан успешно.${NC}"
    else
        echo -e "${RED}Не удалось создать auth.log, но продолжим.${NC}"
    fi
else
    echo -e "${GREEN}Log файл auth.log на месте.${NC}"
fi

# --- 3. Создание пользователя ---
echo -e "${YELLOW}[3/8] Настройка нового пользователя...${NC}"
read -p "Хотите создать нового sudo-пользователя? (y/n): " create_user_choice

if [[ "$create_user_choice" =~ ^[Yy]$ ]]; then
    while true; do
        read -p "Введите имя пользователя (латиница, без пробелов): " NEW_USER
        if [[ "$NEW_USER" =~ ^[a-z0-9]+$ ]]; then
            break
        else
            echo -e "${RED}Неверный формат имени. Используйте только строчные буквы и цифры.${NC}"
        fi
    done

    if id "$NEW_USER" &>/dev/null; then
        echo -e "${YELLOW}Пользователь $NEW_USER уже существует.${NC}"
    else
        adduser "$NEW_USER"
        usermod -aG sudo "$NEW_USER"
        echo -e "${GREEN}Пользователь $NEW_USER создан и добавлен в группу sudo.${NC}"
    fi
else
    echo "Пропускаем создание пользователя."
fi

# --- 4. Настройка SSH ---
echo -e "${YELLOW}[4/8] Настройка безопасности SSH...${NC}"
SSH_CONFIG="/etc/ssh/sshd_config"
cp $SSH_CONFIG "$SSH_CONFIG.bak"

# Смена порта
read -p "Хотите изменить стандартный порт SSH (22)? (y/n): " change_port_choice
SSH_PORT=22

if [[ "$change_port_choice" =~ ^[Yy]$ ]]; then
    while true; do
        read -p "Введите новый порт (1024-65535): " NEW_PORT
        if [[ "$NEW_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_PORT" -ge 1024 ] && [ "$NEW_PORT" -le 65535 ]; then
            SSH_PORT=$NEW_PORT
            sed -i "s/#Port 22/Port $SSH_PORT/" $SSH_CONFIG
            sed -i "s/Port 22/Port $SSH_PORT/" $SSH_CONFIG
            echo -e "${GREEN}Порт SSH изменен на $SSH_PORT.${NC}"
            break
        else
            echo -e "${RED}Неверный порт. Введите число от 1024 до 65535.${NC}"
        fi
    done
fi

# Отключение root логина
read -p "Отключить вход по root через SSH? (Рекомендуется, если создан новый пользователь) (y/n): " disable_root_choice
if [[ "$disable_root_choice" =~ ^[Yy]$ ]]; then
    sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' $SSH_CONFIG
    sed -i 's/PermitRootLogin yes/PermitRootLogin no/' $SSH_CONFIG
    # На случай если там было prohibit-password
    sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin no/' $SSH_CONFIG
    echo -e "${GREEN}Вход root отключен.${NC}"
fi

# --- 5. Настройка Firewall (UFW) ---
echo -e "${YELLOW}[5/8] Настройка UFW (Firewall)...${NC}"

# Сброс правил
ufw default deny incoming
ufw default allow outgoing

# Разрешаем SSH (на новом или старом порту)
ufw allow $SSH_PORT/tcp
echo -e "Разрешен порт SSH: $SSH_PORT"

# Разрешаем HTTP/HTTPS
ufw allow 80/tcp
ufw allow 443/tcp
echo -e "Разрешены порты HTTP (80) и HTTPS (443)"

# Разрешаем порт для подписки 3x-ui
ufw allow 2096/tcp
echo -e "Разрешен порт подписки (2096)"

# Спрашиваем про порт панели 3x-ui
read -p "Введите порт, на котором будет висеть панель 3x-ui (по умолчанию 2053): " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-2053}
if [[ "$PANEL_PORT" =~ ^[0-9]+$ ]]; then
    ufw allow $PANEL_PORT/tcp
    echo -e "Разрешен порт панели: $PANEL_PORT"
else
    echo -e "${RED}Порт введен неверно, правило не добавлено.${NC}"
fi

# Включение UFW
echo "y" | ufw enable
echo -e "${GREEN}UFW активирован.${NC}"

# --- 6. Настройка Fail2Ban ---
echo -e "${YELLOW}[6/8] Настройка Fail2Ban для защиты SSH...${NC}"
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

# Создаем конфигурацию для sshd
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
backend = auto
EOF

systemctl restart fail2ban
echo -e "${GREEN}Fail2Ban настроен и перезапущен.${NC}"

# --- 7. Установка 3x-ui ---
echo -e "${YELLOW}[7/8] Установка панели 3x-ui...${NC}"
read -p "Хотите установить панель 3x-ui (MHSanaei fork)? (y/n): " install_3xui

if [[ "$install_3xui" =~ ^[Yy]$ ]]; then
    echo -e "Запускаем установщик 3x-ui..."
    echo -e "${YELLOW}ВАЖНО: При установке укажите порт панели $PANEL_PORT, который мы открыли в UFW!${NC}"
    sleep 3
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
else
    echo "Установка 3x-ui пропущена."
fi

# --- 8. Финал ---
echo -e "${YELLOW}[8/8] Применение изменений...${NC}"
systemctl restart ssh

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}   Настройка завершена!                             ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "1. SSH порт: ${YELLOW}$SSH_PORT${NC}"
if [[ "$create_user_choice" =~ ^[Yy]$ ]]; then
    echo -e "2. Пользователь: ${YELLOW}$NEW_USER${NC}"
fi
echo -e "3. Firewall: ${YELLOW}Активен${NC}"
echo -e "4. Fail2Ban: ${YELLOW}Активен${NC}"
echo ""
echo -e "${RED}ВАЖНО:${NC} Не закрывайте текущую сессию SSH!"
echo -e "Откройте новое окно терминала и попробуйте подключиться:"
echo -e "ssh -p $SSH_PORT <user>@<ip-address>"
echo -e "Если подключение успешно, можно закрывать эту сессию."
