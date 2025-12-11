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
echo -e "${YELLOW}[1/9] Обновление системы и установка пакетов...${NC}"
apt update && apt upgrade -y
apt install -y sudo ufw fail2ban rsyslog curl wget git nano

# --- 2. Отключение IPv6 ---
echo -e "${YELLOW}[2/9] Настройка IPv6...${NC}"
read -p "Отключить IPv6 (рекомендуется для корректной работы Xray/VPN)? (y/n): " disable_ipv6_choice
if [[ "$disable_ipv6_choice" =~ ^[Yy]$ ]]; then
    # Добавляем настройки в sysctl.conf, если их там нет
    if ! grep -q "net.ipv6.conf.all.disable_ipv6 = 1" /etc/sysctl.conf; then
        echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
        echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
        echo "net.ipv6.conf.lo.disable_ipv6 = 1" >> /etc/sysctl.conf
        sysctl -p
        echo -e "${GREEN}IPv6 отключен системно.${NC}"
    else
        echo -e "${GREEN}IPv6 уже отключен.${NC}"
    fi
fi

# --- 3. Проверка логов (rsyslog) ---
echo -e "${YELLOW}[3/9] Проверка конфигурации логов...${NC}"
if [ ! -f /var/log/auth.log ]; then
    echo -e "Файл auth.log не найден. Настраиваем rsyslog..."
    systemctl enable rsyslog
    systemctl start rsyslog
    sleep 2
else
    echo -e "${GREEN}Log файл auth.log на месте.${NC}"
fi

# --- 4. Создание пользователя ---
echo -e "${YELLOW}[4/9] Настройка нового пользователя...${NC}"
read -p "Хотите создать нового sudo-пользователя? (y/n): " create_user_choice
FINAL_USER="root" # По умолчанию пользователь root

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
        FINAL_USER="$NEW_USER"
    else
        # --gecos "" пропускает вопросы про имя, телефон и т.д.
        adduser --gecos "" "$NEW_USER"
        usermod -aG sudo "$NEW_USER"
        FINAL_USER="$NEW_USER"
        echo -e "${GREEN}Пользователь $NEW_USER создан и добавлен в группу sudo.${NC}"
    fi
else
    echo "Пропускаем создание пользователя."
fi

# --- 5. Настройка SSH ---
echo -e "${YELLOW}[5/9] Настройка безопасности SSH...${NC}"
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
    sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin no/' $SSH_CONFIG
    echo -e "${GREEN}Вход root отключен.${NC}"
fi

# --- 6. Настройка Firewall (UFW) ---
echo -e "${YELLOW}[6/9] Настройка UFW (Firewall)...${NC}"

ufw default deny incoming
ufw default allow outgoing

# Основные порты
ufw allow $SSH_PORT/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 2096/tcp
echo -e "Разрешены: SSH ($SSH_PORT), HTTP (80), HTTPS (443), Sub (2096)"

# External Proxy Port
read -p "Хотите открыть порт для External Proxy? (y/n): " ext_proxy_choice
if [[ "$ext_proxy_choice" =~ ^[Yy]$ ]]; then
     while true; do
        read -p "Введите порт для External Proxy: " EXT_PORT
        if [[ "$EXT_PORT" =~ ^[0-9]+$ ]] && [ "$EXT_PORT" -ge 1024 ] && [ "$EXT_PORT" -le 65535 ]; then
            ufw allow $EXT_PORT/tcp
            echo -e "${GREEN}Порт External Proxy ($EXT_PORT) разрешен.${NC}"
            break
        else
            echo -e "${RED}Неверный порт.${NC}"
        fi
    done
fi

# 3x-ui Panel Port
read -p "Введите порт, на котором будет висеть панель 3x-ui (по умолчанию 2053): " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-2053}
if [[ "$PANEL_PORT" =~ ^[0-9]+$ ]]; then
    ufw allow $PANEL_PORT/tcp
    echo -e "Разрешен порт панели: $PANEL_PORT"
fi

echo "y" | ufw enable
echo -e "${GREEN}UFW активирован.${NC}"

# --- 7. Настройка Fail2Ban ---
echo -e "${YELLOW}[7/9] Настройка Fail2Ban...${NC}"
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
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

# --- 8. Установка 3x-ui ---
echo -e "${YELLOW}[8/9] Установка панели 3x-ui...${NC}"
read -p "Хотите установить панель 3x-ui (MHSanaei fork)? (y/n): " install_3xui
if [[ "$install_3xui" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}ВАЖНО: При установке укажите порт панели $PANEL_PORT !${NC}"
    sleep 2
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
fi

# --- 9. Финал ---
echo -e "${YELLOW}[9/9] Применение изменений...${NC}"
systemctl restart ssh

# Получение внешнего IP
SERVER_IP=$(curl -s -4 ifconfig.me)

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}   Настройка завершена!                             ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo ""
echo -e "Для подключения используйте команду:"
echo -e "${YELLOW}ssh -p $SSH_PORT $FINAL_USER@$SERVER_IP${NC}"
echo ""
echo -e "${RED}ВАЖНО:${NC} Не закрывайте текущую сессию SSH, пока не проверите вход в новом окне!"
echo ""
echo -e "${YELLOW}НАСТРОЙКА External PROXY (плюс русское меню 3x-ui):${NC} bash <(curl -Ls https://raw.githubusercontent.com/Gothik99/3XUI-RUSMENU-Reverse-Proxy/main/update-menu-gothik.sh)"
