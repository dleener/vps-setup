#!/bin/bash

#################################################
# VPS Hardening Script
# Базовая настройка безопасности VPS
# Поддержка: Ubuntu 22.04 / 24.04
#################################################

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

clear

echo -e "${BLUE}"
echo "=============================================="
echo "        VPS SECURITY HARDENING SCRIPT"
echo "=============================================="
echo -e "${NC}"

echo "Этот скрипт выполнит:"
echo "• обновление системы"
echo "• отключение IPv6"
echo "• защиту SSH"
echo "• настройку firewall"
echo "• установку Fail2Ban"
echo ""

read -p "Продолжить? (y/n): " confirm

if [[ "$confirm" != "y" ]]; then
    echo "Отмена."
    exit
fi

# Проверка root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Запустите скрипт от root.${NC}"
   exit
fi

#################################
# Обновление системы
#################################

echo -e "${YELLOW}Обновление системы...${NC}"

apt update
apt upgrade -y
apt install -y ufw fail2ban curl wget

echo -e "${GREEN}Система обновлена.${NC}"

#################################
# Отключение IPv6
#################################

echo ""
read -p "Отключить IPv6? (y/n): " disable_ipv6

if [[ "$disable_ipv6" == "y" ]]; then

echo -e "${YELLOW}Отключение IPv6...${NC}"

cat <<EOF >> /etc/sysctl.conf

# Disable IPv6
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF

sysctl -p

echo -e "${GREEN}IPv6 отключен.${NC}"

fi

#################################
# SSH настройка
#################################

echo ""
echo -e "${BLUE}Настройка SSH${NC}"

read -p "Введите новый SSH порт (по умолчанию 22): " SSH_PORT

if [[ -z "$SSH_PORT" ]]; then
SSH_PORT=22
fi

echo -e "${YELLOW}Создание резервной копии SSH конфига...${NC}"

cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

sed -i "s/#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config

sed -i "s/#PermitRootLogin prohibit-password/PermitRootLogin no/" /etc/ssh/sshd_config

read -p "Отключить вход по паролю (только SSH ключ)? (y/n): " keyonly

if [[ "$keyonly" == "y" ]]; then
sed -i "s/#PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config
fi

systemctl restart ssh

echo -e "${GREEN}SSH настроен.${NC}"

#################################
# Firewall
#################################

echo ""
echo -e "${BLUE}Настройка Firewall (UFW)${NC}"

ufw default deny incoming
ufw default allow outgoing

echo "Разрешаем SSH порт..."

ufw allow $SSH_PORT/tcp

while true
do

read -p "Введите порт для открытия (Enter чтобы завершить): " PORT

if [[ -z "$PORT" ]]; then
break
fi

ufw allow $PORT/tcp
echo -e "${GREEN}Порт $PORT открыт.${NC}"

done

read -p "Включить firewall сейчас? (y/n): " enablefw

if [[ "$enablefw" == "y" ]]; then

ufw enable

fi

echo ""
ufw status verbose

#################################
# Fail2Ban
#################################

echo ""
echo -e "${BLUE}Установка Fail2Ban${NC}"

cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

cat <<EOF >> /etc/fail2ban/jail.local

[sshd]
enabled = true
port = $SSH_PORT
maxretry = 5
findtime = 10m
bantime = 1h
EOF

systemctl enable fail2ban
systemctl restart fail2ban

echo -e "${GREEN}Fail2Ban запущен.${NC}"

#################################
# Дополнительная защита сети
#################################

echo ""
echo -e "${BLUE}Применение базовых сетевых защит${NC}"

cat <<EOF >> /etc/sysctl.conf

# Security hardening
net.ipv4.tcp_syncookies=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1
EOF

sysctl -p

echo -e "${GREEN}Сетевые параметры применены.${NC}"

#################################
# Завершение
#################################

echo ""
echo -e "${GREEN}"
echo "=============================================="
echo "        НАСТРОЙКА ЗАВЕРШЕНА"
echo "=============================================="
echo -e "${NC}"

echo "Рекомендуемые действия:"
echo "1. Откройте новое SSH подключение."
echo "2. Проверьте доступ по новому порту."
echo "3. После проверки закройте старую сессию."

echo ""
echo "Fail2Ban статус:"
fail2ban-client status
