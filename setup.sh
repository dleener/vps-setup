#!/usr/bin/env bash
# ==============================================================================
# VPS Security Setup Wizard
# Ubuntu 22.04 / 24.04 LTS
# https://github.com/dleener/vps-setup
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="2.0.0"
BACKUP_DIR="/root/vps-security-backup-$(date +%Y%m%d-%H%M%S)"
SSH_DROPIN="/etc/ssh/sshd_config.d/99-vps-security.conf"
F2B_CONFIG="/etc/fail2ban/jail.d/99-vps-security.local"

# ---------- Colors ----------
if [[ -t 1 ]]; then
    RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BLUE='\033[0;34m'; WHITE='\033[1;37m'
else
    RESET=''; BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; BLUE=''; WHITE=''
fi

LOG_FILE="/var/log/vps-security-setup.log"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'printf "\n%b✗ Ошибка на строке %s. Лог: %s%b\n" "$RED" "$LINENO" "$LOG_FILE" "$RESET"' ERR

info()    { printf "%b›%b %s\n" "$CYAN" "$RESET" "$1"; }
success() { printf "%b✓%b %s\n" "$GREEN" "$RESET" "$1"; }
warn()    { printf "%b!%b %s\n" "$YELLOW" "$RESET" "$1"; }
die()     { printf "%b✗ %s%b\n" "$RED" "$1" "$RESET"; exit 1; }

hr() { printf "%b────────────────────────────────────────────────────────────%b\n" "$DIM" "$RESET"; }

title() {
    local n="$1" text="$2"
    clear 2>/dev/null || true
    printf "%b╭────────────────────────────────────────────────────────────╮%b\n" "$CYAN" "$RESET"
    printf "%b│%b  %b%-58s%b│%b\n" "$CYAN" "$RESET" "$BOLD" "$text" "$RESET" "$CYAN" "$RESET"
    printf "%b╰────────────────────────────────────────────────────────────╯%b\n\n" "$CYAN" "$RESET"
    printf "%b[%s/7]%b %b%s%b\n\n" "$BLUE" "$n" "$RESET" "$BOLD" "$text" "$RESET"
}

pause() {
    printf "\n%bНажмите Enter, чтобы продолжить...%b " "$DIM" "$RESET"
    read -r _
}

ask_yes_no() {
    local prompt="$1" default="${2:-y}" answer
    if [[ "$default" == "y" ]]; then
        read -r -p "$prompt [Y/n]: " answer
        answer="${answer:-y}"
    else
        read -r -p "$prompt [y/N]: " answer
        answer="${answer:-n}"
    fi
    [[ "$answer" =~ ^[YyДд]$ ]]
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 65535 ))
}

valid_tcp_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 65535 ))
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    [[ "$EUID" -eq 0 ]] || die "Запустите скрипт от root."
}

check_os() {
    [[ -r /etc/os-release ]] || die "Не удалось определить ОС."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || die "Этот мастер рассчитан на Ubuntu."
    case "${VERSION_ID:-}" in
        22.04|24.04) ;;
        *) warn "Обнаружена Ubuntu ${VERSION_ID:-unknown}. Скрипт рассчитан на 22.04/24.04."; ask_yes_no "Продолжить?" n || exit 0 ;;
    esac
}

server_ip() {
    hostname -I 2>/dev/null | awk '{print $1}'
}

show_intro() {
    clear 2>/dev/null || true
    printf "%b╭────────────────────────────────────────────────────────────╮%b\n" "$CYAN" "$RESET"
    printf "%b│%b                                                            %b│%b\n" "$CYAN" "$RESET" "$CYAN" "$RESET"
    printf "%b│%b              %bVPS SECURITY SETUP%b                         %b│%b\n" "$CYAN" "$RESET" "$BOLD$WHITE" "$RESET" "$CYAN" "$RESET"
    printf "%b│%b              Ubuntu 22.04 / 24.04                          %b│%b\n" "$CYAN" "$RESET" "$CYAN" "$RESET"
    printf "%b│%b              %bby dleen%b                                    %b│%b\n" "$CYAN" "$RESET" "$DIM" "$RESET" "$CYAN" "$RESET"
    printf "%b│%b                                                            %b│%b\n" "$CYAN" "$RESET" "$CYAN" "$RESET"
    printf "%b╰────────────────────────────────────────────────────────────╯%b\n\n" "$CYAN" "$RESET"

    printf "%bЭтот мастер выполнит базовую защиту VPS:%b\n\n" "$BOLD" "$RESET"
    printf "  %b✓%b Обновление системы\n" "$GREEN" "$RESET"
    printf "  %b✓%b Безопасная настройка SSH\n" "$GREEN" "$RESET"
    printf "  %b✓%b UFW Firewall\n" "$GREEN" "$RESET"
    printf "  %b✓%b Fail2Ban\n" "$GREEN" "$RESET"
    printf "  %b✓%b Опциональное отключение IPv6\n" "$GREEN" "$RESET"
    printf "  %b✓%b Проверка конфигурации перед перезапуском\n\n" "$GREEN" "$RESET"

    printf "%bСервер%b\n" "$BOLD" "$RESET"
    hr
    printf "  OS       %s %s\n" "${PRETTY_NAME:-Ubuntu}" "${VERSION_ID:-}"
    printf "  Hostname %s\n" "$(hostname)"
    printf "  IP       %s\n" "$(server_ip || echo unknown)"
    printf "\n%bВнимание:%b не закрывайте текущую SSH-сессию до успешной проверки нового подключения.\n" "$YELLOW" "$RESET"
    printf "\n"
    ask_yes_no "Начать настройку?" y || exit 0
    ask_yes_no "Начать настройку?" y || exit 0
}

step_update() {
    title "1" "ОБНОВЛЕНИЕ СИСТЕМЫ"
    info "Обновляю индекс пакетов..."
    apt-get update
    info "Устанавливаю доступные обновления..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    success "Система обновлена."
    pause
}

step_ipv6() {
    title "2" "IPv6"
    local current
    current="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)"
    if [[ "$current" == "1" ]]; then
        success "IPv6 уже отключён."
        pause
        return
    fi

    printf "  IPv6 сейчас: %b%s%b\n\n" "$YELLOW" "включён" "$RESET"
    printf "Отключение IPv6 имеет смысл, если ваш VPS и приложения\n"
    printf "не используют IPv6. Это не является обязательным требованием безопасности.\n\n"
    if ask_yes_no "Отключить IPv6?" y; then
        mkdir -p "$BACKUP_DIR"
        cat > /etc/sysctl.d/99-vps-disable-ipv6.conf <<'EOF'
# Managed by VPS Security Setup
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        sysctl --system >/dev/null
        success "IPv6 отключён."
    else
        rm -f /etc/sysctl.d/99-vps-disable-ipv6.conf
        success "IPv6 оставлен включённым."
    fi
    pause
}

step_ssh() {
    title "3" "SSH"
    local current_port="$1"
    local new_port answer disable_pass key_count
    local current_keys=0

    # Detect authorized keys for current user and root.
    if [[ -s /root/.ssh/authorized_keys ]]; then
        current_keys="$(grep -cve '^[[:space:]]*$' /root/.ssh/authorized_keys || true)"
    fi

    printf "  Текущий SSH-порт: %b%s%b\n" "$YELLOW" "$current_port" "$RESET"
    printf "  Ключей root в authorized_keys: %b%s%b\n\n" "$YELLOW" "$current_keys" "$RESET"

    while true; do
        read -r -p "Новый SSH-порт [${current_port}]: " new_port
        new_port="${new_port:-$current_port}"
        if valid_port "$new_port" && (( new_port >= 1024 )); then break; fi
        warn "Введите порт от 1024 до 65535."
    done
    SSH_PORT="$new_port"

    printf "\n%bSSH hardening:%b\n" "$BOLD" "$RESET"
    printf "  • PermitRootLogin        → prohibit-password\n"
    printf "  • KbdInteractiveAuthentication → no\n"
    printf "  • MaxAuthTries           → 3\n"
    printf "  • X11Forwarding          → no\n"
    printf "  • DebianBanner           → no (если поддерживается)\n\n"

    if (( current_keys == 0 )); then
        warn "В /root/.ssh/authorized_keys не найден публичный ключ."
        warn "Отключать парольную авторизацию сейчас НЕбезопасно."
        disable_pass="n"
    else
        if ask_yes_no "Отключить вход по паролю?" y; then
            disable_pass="y"
        else
            disable_pass="n"
        fi
    fi

    mkdir -p "$BACKUP_DIR"
    cp -a /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.original"

    cat > "$SSH_DROPIN" <<EOF
# Managed by VPS Security Setup v${VERSION}
Port ${SSH_PORT}
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
MaxAuthTries 3
X11Forwarding no
DebianBanner no
EOF

    if [[ "$disable_pass" == "y" ]]; then
        cat >> "$SSH_DROPIN" <<'EOF'
PasswordAuthentication no
EOF
    else
        cat >> "$SSH_DROPIN" <<'EOF'
PasswordAuthentication yes
EOF
    fi

    # Validate before touching the running daemon.
    if ! sshd -t; then
        rm -f "$SSH_DROPIN"
        die "Новая конфигурация SSH не прошла проверку. Изменения SSH отменены."
    fi

    success "Конфигурация SSH прошла проверку."
    pause
}

step_ufw() {
    title "4" "FIREWALL — UFW"
    local extra port clean
    local -a ports=()

    printf "SSH будет открыт на порту: %b%s/tcp%b\n\n" "$GREEN" "$SSH_PORT" "$RESET"
    printf "Часто используемые дополнительные порты:\n"
    printf "  80    HTTP\n"
    printf "  443   HTTPS\n"
    printf "  2096  HTTPS/приложения (если нужен)\n"
    printf "  17040 пользовательский порт (если нужен)\n\n"

    read -r -p "Дополнительные TCP-порты через пробел [80 443]: " extra
    extra="${extra:-80 443}"

    for port in $extra; do
        if valid_tcp_port "$port"; then
            ports+=("$port")
        else
            warn "Пропускаю некорректный порт: $port"
        fi
    done

    printf "\n%bБудут разрешены входящие TCP:%b\n" "$BOLD" "$RESET"
    printf "  • %s/tcp — SSH\n" "$SSH_PORT"
    for port in "${ports[@]}"; do printf "  • %s/tcp\n" "$port"; done
    printf "\nПолитика: incoming DENY / outgoing ALLOW\n\n"

    ask_yes_no "Применить правила UFW?" y || { warn "UFW пропущен."; return; }

    apt-get install -y ufw

    # Important: always permit SSH before enabling UFW.
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw limit "${SSH_PORT}/tcp"

    for port in "${ports[@]}"; do
        ufw allow "${port}/tcp"
    done

    printf "\n%bПредпросмотр UFW:%b\n" "$BOLD" "$RESET"
    ufw status numbered || true
    printf "\n"

    ufw --force enable
    success "UFW активирован. SSH защищён rate-limit правилом."
    pause
}

step_fail2ban() {
    title "5" "FAIL2BAN"
    apt-get install -y fail2ban

    mkdir -p /etc/fail2ban/jail.d
    cat > "$F2B_CONFIG" <<EOF
# Managed by VPS Security Setup
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 3
backend  = systemd
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ${SSH_PORT}
backend  = systemd
EOF

    systemctl enable --now fail2ban
    systemctl restart fail2ban

    if fail2ban-client status sshd >/dev/null 2>&1; then
        success "Fail2Ban активен и защищает SSH."
    else
        warn "Fail2Ban запущен, но jail sshd пока не удалось проверить."
    fi
    pause
}

step_final_check() {
    title "6" "ПРОВЕРКА БЕЗОПАСНОСТИ"

    local failed=0

    printf "  Проверка sshd_config... "
    if sshd -t; then printf "%bOK%b\n" "$GREEN" "$RESET"; else printf "%bFAIL%b\n" "$RED" "$RESET"; failed=1; fi

    printf "  SSH слушает ${SSH_PORT}/tcp... "
    if ss -lnt | awk '{print $4}' | grep -Eq "(^|:)${SSH_PORT}$"; then
        printf "%bOK%b\n" "$GREEN" "$RESET"
    else
        printf "%bFAIL%b\n" "$RED" "$RESET"; failed=1
    fi

    printf "  UFW... "
    if ufw status | grep -q '^Status: active'; then printf "%bACTIVE%b\n" "$GREEN" "$RESET"; else printf "%bFAIL%b\n" "$RED" "$RESET"; failed=1; fi

    printf "  Fail2Ban... "
    if systemctl is-active --quiet fail2ban; then printf "%bACTIVE%b\n" "$GREEN" "$RESET"; else printf "%bFAIL%b\n" "$RED" "$RESET"; failed=1; fi

    printf "\n"
    if (( failed )); then
        warn "Одна или несколько проверок не пройдены."
        warn "SSH пока НЕ перезапускается автоматически."
        return 1
    fi

    success "Все локальные проверки пройдены."
    pause
}

step_restart() {
    title "7" "ЗАВЕРШЕНИЕ"

    printf "%bВАЖНО%b\n\n" "$YELLOW$BOLD" "$RESET"
    printf "Не закрывайте текущую SSH-сессию.\n"
    printf "Откройте НОВОЕ окно терминала и проверьте подключение:\n\n"
    printf "  %bssh -p %s root@%s%b\n\n" "$WHITE" "$SSH_PORT" "$(server_ip)" "$RESET"

    if ! ask_yes_no "Перезапустить SSH сейчас?" y; then
        warn "SSH не перезапущен. Вы можете выполнить: systemctl restart ssh"
        return
    fi

    systemctl restart ssh
    sleep 1

    if systemctl is-active --quiet ssh; then
        success "SSH успешно перезапущен."
    else
        die "SSH не запустился после изменения конфигурации. Текущую сессию НЕ закрывайте."
    fi

    clear 2>/dev/null || true
    printf "%b╭──────────────────────────────────────────────────────────╮%b\n" "$GREEN" "$RESET"
    printf "%b│%b              %b✓ SETUP COMPLETE%b                         %b│%b\n" "$GREEN" "$RESET" "$BOLD" "$RESET" "$GREEN" "$RESET"
    printf "%b╰──────────────────────────────────────────────────────────╯%b\n\n" "$GREEN" "$RESET"

    printf "%bSSH%b\n" "$BOLD" "$RESET"
    hr
    printf "  Port             %s\n" "$SSH_PORT"
    if grep -q '^PasswordAuthentication no' "$SSH_DROPIN"; then
        printf "  Password login   %bDISABLED%b\n" "$GREEN" "$RESET"
    else
        printf "  Password login   %bENABLED%b\n" "$YELLOW" "$RESET"
    fi
    printf "\n%bFIREWALL%b\n" "$BOLD" "$RESET"
    hr
    printf "  UFW              %bACTIVE%b\n" "$GREEN" "$RESET"
    printf "  Incoming         DENY\n"
    printf "  Outgoing         ALLOW\n"
    printf "\n%bFAIL2BAN%b\n" "$BOLD" "$RESET"
    hr
    printf "  Service          %bACTIVE%b\n" "$GREEN" "$RESET"
    printf "  SSH jail         %bENABLED%b\n" "$GREEN" "$RESET"
    printf "  Ban time         1h\n"
    printf "  Max retries      3\n"
    printf "\n%bBACKUP%b\n" "$BOLD" "$RESET"
    hr
    printf "  %s\n" "$BACKUP_DIR"
    printf "\n%bSSH connection:%b\n  ssh -p %s root@%s\n\n" "$CYAN" "$RESET" "$SSH_PORT" "$(server_ip)"
    printf "%bЛог:%b %s\n\n" "$DIM" "$RESET" "$LOG_FILE"
}

main() {
    require_root
    check_os
    show_intro

    local current_port
    current_port="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}' || true)"
    current_port="${current_port:-22}"

    step_update
    step_ipv6
    step_ssh "$@" "$current_port"
    step_ufw
    step_fail2ban

    if ! step_final_check; then
        warn "Для безопасности автоматический перезапуск SSH отменён."
        printf "\nПроверьте конфигурацию и при необходимости восстановите backup:\n  %s\n\n" "$BACKUP_DIR"
        exit 1
    fi

    step_restart
}

main "$@"
