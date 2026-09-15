#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# VPS SECURITY SETUP WIZARD
# Clean implementation from scratch
# Ubuntu 22.04 / 24.04 LTS
# https://github.com/dleener/vps-setup
# ══════════════════════════════════════════════════════════════════════════════

set -Eeuo pipefail
IFS=$'\n\t'

# ══════════════════════════════════════════════════════════════════════════════
# GLOBALS
# ══════════════════════════════════════════════════════════════════════════════

readonly SCRIPT_VERSION="3.0.0"
readonly SCRIPT_START_TS="$(date +%s)"
readonly BOX_WIDTH=64
readonly TOTAL_STEPS=7

readonly BACKUP_DIR="/root/vps-setup-backup-$(date +%Y%m%d-%H%M%S)"
readonly SSH_DROPIN="/etc/ssh/sshd_config.d/99-vps-security.conf"
readonly F2B_JAIL="/etc/fail2ban/jail.d/99-vps-security.local"
readonly LOG_FILE="/var/log/vps-setup.log"

# Will be set during step_ssh()
SSH_PORT=""

# ══════════════════════════════════════════════════════════════════════════════
# TERMINAL SETUP
# ══════════════════════════════════════════════════════════════════════════════

# Detect if output is a terminal; if not, disable colors
if [[ -t 1 ]]; then
    readonly C_RESET='\033[0m'
    readonly C_BOLD='\033[1m'
    readonly C_DIM='\033[2m'
    readonly C_RED='\033[0;31m'
    readonly C_GREEN='\033[0;32m'
    readonly C_YELLOW='\033[1;33m'
    readonly C_CYAN='\033[0;36m'
    readonly C_BLUE='\033[0;34m'
    readonly C_WHITE='\033[1;37m'
else
    readonly C_RESET=''
    readonly C_BOLD=''
    readonly C_DIM=''
    readonly C_RED=''
    readonly C_GREEN=''
    readonly C_YELLOW=''
    readonly C_CYAN=''
    readonly C_BLUE=''
    readonly C_WHITE=''
fi

# fd 3 = original stdout, so spinner can write there without polluting the log
exec 3>&1
exec > >(tee -a "$LOG_FILE") 2>&1

# ══════════════════════════════════════════════════════════════════════════════
# ERROR HANDLING
# ══════════════════════════════════════════════════════════════════════════════

trap 'printf "\n%b✗ Ошибка на строке %d%b\nЛог: %s\n" "$C_RED" "$LINENO" "$C_RESET" "$LOG_FILE"' ERR

# ══════════════════════════════════════════════════════════════════════════════
# OUTPUT FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════════

info()    { printf "  %b›%b %s\n" "$C_CYAN" "$C_RESET" "$1"; }
success() { printf "  %b✓%b %s\n" "$C_GREEN" "$C_RESET" "$1"; }
warn()    { printf "  %b!%b %s\n" "$C_YELLOW" "$C_RESET" "$1"; }
error()   { printf "  %b✗ %s%b\n" "$C_RED" "$1" "$C_RESET"; exit 1; }

# ══════════════════════════════════════════════════════════════════════════════
# TERMINAL RENDERING HELPERS
# ══════════════════════════════════════════════════════════════════════════════

# Generate N copies of a character: repeat_char '<char>' <count>
repeat_char() {
    printf '%*s' "$2" '' | tr ' ' "$1"
}

# Print a horizontal rule
hr() {
    printf "%b%s%b\n" "$C_DIM" "$(repeat_char '─' "$BOX_WIDTH")" "$C_RESET"
}

# Center text inside a ║ ... ║ line, with optional color
# center_box_line '<text>' [<color>]
center_box_line() {
    local text="$1" color="${2:-}" line
    local pad_total left right

    # Compute padding based on plain text length (ignore color codes)
    pad_total=$(( BOX_WIDTH - ${#text} ))
    (( pad_total < 0 )) && pad_total=0
    left=$(( pad_total / 2 ))
    right=$(( pad_total - left ))

    line="$(repeat_char ' ' "$left")"
    if [[ -n "$color" ]]; then
        line+="${color}${text}${C_RESET}"
    else
        line+="$text"
    fi
    line+="$(repeat_char ' ' "$right")"

    printf "%b║%b%s%b║%b\n" "$C_CYAN" "$C_RESET" "$line" "$C_CYAN" "$C_RESET"
}

# Format seconds to "X мин Y с" or "Y с"
format_duration() {
    local total="$1" m s
    m=$(( total / 60 ))
    s=$(( total % 60 ))
    if (( m > 0 )); then
        printf "%d мин %d с" "$m" "$s"
    else
        printf "%d с" "$s"
    fi
}

# Display a progress bar: progress_bar <step_num> <total_steps>
progress_bar() {
    local step="$1" total="$2"
    local width=30 filled empty pct bar

    filled=$(( step * width / total ))
    empty=$(( width - filled ))
    bar="$(repeat_char '█' "$filled")$(repeat_char '░' "$empty")"
    pct=$(( step * 100 / total ))

    printf "  %b%s%b %b%3d%%%b  (шаг %d из %d)\n" \
        "$C_CYAN" "$bar" "$C_RESET" \
        "$C_DIM" "$pct" "$C_RESET" \
        "$step" "$total"
}

# Display the title screen for a step
# title <step_num> '<title_text>'
title() {
    local step="$1" text="$2"
    local top bottom

    clear 2>/dev/null || true

    top="╭$(repeat_char '─' "$BOX_WIDTH")╮"
    bottom="╰$(repeat_char '─' "$BOX_WIDTH")╯"

    printf "%b%s%b\n" "$C_CYAN" "$top" "$C_RESET"
    printf "%b│%b %b%-*s%b %b│%b\n" \
        "$C_CYAN" "$C_RESET" \
        "$C_BOLD$C_WHITE" "$((BOX_WIDTH-2))" "$text" "$C_RESET" \
        "$C_CYAN" "$C_RESET"
    printf "%b%s%b\n\n" "$C_CYAN" "$bottom" "$C_RESET"

    progress_bar "$step" "$TOTAL_STEPS"
    printf "\n"
}

# Pause and wait for user to press Enter
pause_for_enter() {
    printf "\n%b  ↵  Нажмите Enter, чтобы продолжить...%b " "$C_DIM" "$C_RESET"
    read -r _
}

# ══════════════════════════════════════════════════════════════════════════════
# SPINNER FOR LONG-RUNNING TASKS
# ══════════════════════════════════════════════════════════════════════════════

# Run a command with an animated spinner
# run_with_spinner '<message>' <command> [args...]
run_with_spinner() {
    local msg="$1"
    shift

    local start rc idx frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
    start="$(date +%s)"

    # Run command in background, redirecting output to log
    ( "$@" ) >>"$LOG_FILE" 2>&1 &
    local pid=$!

    # Animate spinner while process runs
    while kill -0 "$pid" 2>/dev/null; do
        idx=$(( i % ${#frames} ))
        printf "\r  %b%s%b %s" "$C_CYAN" "${frames:idx:1}" "$C_RESET" "$msg" >&3
        i=$(( i + 1 ))
        sleep 0.1
    done

    # Wait for process to finish, capture exit code
    wait "$pid"
    rc=$?

    local dur=$(( $(date +%s) - start ))

    # Show final status
    if (( rc == 0 )); then
        printf "\r%-78s\r  %b✓%b %s %b(%s с)%b\n" "" \
            "$C_GREEN" "$C_RESET" "$msg" "$C_DIM" "$dur" "$C_RESET"
    else
        printf "\r%-78s\r  %b✗%b %s %b(код %d)%b\n" "" \
            "$C_RED" "$C_RESET" "$msg" "$C_DIM" "$rc" "$C_RESET"
    fi

    return "$rc"
}

# ══════════════════════════════════════════════════════════════════════════════
# VALIDATION FUNCTIONS
# ══════════════════════════════════════════════════════════════════════════════

# Validate that a port number is in the valid range
valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# Ask user a yes/no question with a default answer
# ask_yes_no '<prompt>' [default_y/n]
# Returns 0 if yes, 1 if no
ask_yes_no() {
    local prompt="$1" default="${2:-y}" answer

    if [[ "$default" == "y" ]]; then
        read -r -p "  ${prompt} [Y/n]: " answer
        answer="${answer:-y}"
    else
        read -r -p "  ${prompt} [y/N]: " answer
        answer="${answer:-n}"
    fi

    [[ "$answer" =~ ^[YyДд]$ ]]
}

# Check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ══════════════════════════════════════════════════════════════════════════════
# PREREQUISITES
# ══════════════════════════════════════════════════════════════════════════════

# Ensure we're running as root
require_root() {
    [[ "$EUID" -eq 0 ]] || error "Запустите скрипт от root."
}

# Ensure we're running on a compatible Ubuntu version
check_os() {
    [[ -r /etc/os-release ]] || error "Не удалось определить ОС."

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        error "Этот мастер рассчитан на Ubuntu."
    fi

    case "${VERSION_ID:-}" in
        22.04|24.04) ;;
        *)
            warn "Обнаружена Ubuntu ${VERSION_ID:-unknown}."
            ask_yes_no "Продолжить на неподдерживаемой версии?" n || exit 0
            ;;
    esac
}

# Get the server's primary IP address
server_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown"
}

# Get current SSH port from running daemon
get_current_ssh_port() {
    sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}' || echo "22"
}

# ══════════════════════════════════════════════════════════════════════════════
# INTRO SCREEN
# ══════════════════════════════════════════════════════════════════════════════

show_intro() {
    clear 2>/dev/null || true

    local top bottom
    top="╔$(repeat_char '═' "$BOX_WIDTH")╗"
    bottom="╚$(repeat_char '═' "$BOX_WIDTH")╝"

    printf "%b%s%b\n" "$C_CYAN" "$top" "$C_RESET"
    printf "%b║%b%*s%b║%b\n" "$C_CYAN" "$C_RESET" "$BOX_WIDTH" "" "$C_CYAN" "$C_RESET"
    center_box_line "VPS SECURITY SETUP" "${C_BOLD}${C_WHITE}"
    center_box_line "Ubuntu 22.04 / 24.04" "$C_DIM"
    printf "%b║%b%*s%b║%b\n" "$C_CYAN" "$C_RESET" "$BOX_WIDTH" "" "$C_CYAN" "$C_RESET"
    printf "%b%s%b\n\n" "$C_CYAN" "$bottom" "$C_RESET"

    printf "  %bВерсия %s%b · мастер базовой защиты VPS за 7 шагов\n\n" \
        "$C_DIM" "$SCRIPT_VERSION" "$C_RESET"

    printf "%bЭтот мастер выполнит:%b\n\n" "$C_BOLD" "$C_RESET"
    printf "  %b✓%b Обновление системы\n" "$C_GREEN" "$C_RESET"
    printf "  %b✓%b Безопасную настройку SSH\n" "$C_GREEN" "$C_RESET"
    printf "  %b✓%b Firewall (UFW)\n" "$C_GREEN" "$C_RESET"
    printf "  %b✓%b Защиту от перебора (Fail2Ban)\n" "$C_GREEN" "$C_RESET"
    printf "  %b✓%b Опциональное отключение IPv6\n" "$C_GREEN" "$C_RESET"
    printf "  %b✓%b Проверку конфигурации\n" "$C_GREEN" "$C_RESET"
    printf "  %b✓%b Перезапуск SSH с новыми настройками\n\n" "$C_GREEN" "$C_RESET"

    printf "%bСервер%b\n" "$C_BOLD" "$C_RESET"
    hr
    printf "  OS        %s %s\n" "${PRETTY_NAME:-Ubuntu}" "${VERSION_ID:-}"
    printf "  Hostname  %s\n" "$(hostname)"
    printf "  IP        %s\n" "$(server_ip)"
    printf "\n%b!%b Не закрывайте текущую SSH-сессию до проверки нового подключения.\n" \
        "$C_YELLOW" "$C_RESET"

    printf "\n"
    ask_yes_no "Начать настройку?" y || exit 0
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: UPDATE SYSTEM
# ══════════════════════════════════════════════════════════════════════════════

step_1_update() {
    title "1" "ОБНОВЛЕНИЕ СИСТЕМЫ"

    run_with_spinner "Обновляю индекс пакетов..." \
        apt-get update

    run_with_spinner "Устанавливаю доступные обновления..." \
        env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

    success "Система обновлена."
    pause_for_enter
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: IPv6 CONFIGURATION
# ══════════════════════════════════════════════════════════════════════════════

step_2_ipv6() {
    title "2" "IPv6"

    local current
    current="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)"

    if [[ "$current" == "1" ]]; then
        success "IPv6 уже отключён."
        pause_for_enter
        return
    fi

    printf "  IPv6 сейчас: %b%s%b\n\n" "$C_YELLOW" "включён" "$C_RESET"
    printf "  Отключение IPv6 имеет смысл, если ваш VPS и приложения\n"
    printf "  не используют IPv6. Это опциональное требование.\n\n"

    if ! ask_yes_no "Отключить IPv6?" y; then
        success "IPv6 оставлен включённым."
        pause_for_enter
        return
    fi

    mkdir -p "$BACKUP_DIR"

    cat > /etc/sysctl.d/99-vps-disable-ipv6.conf <<'EOF'
# Managed by VPS Security Setup
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

    sysctl --system >/dev/null
    success "IPv6 отключён."
    pause_for_enter
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: SSH HARDENING
# ══════════════════════════════════════════════════════════════════════════════

step_3_ssh() {
    title "3" "SSH HARDENING"

    local current_port
    current_port="$(get_current_ssh_port)"

    local current_keys=0
    if [[ -s /root/.ssh/authorized_keys ]]; then
        current_keys="$(grep -cve '^[[:space:]]*$' /root/.ssh/authorized_keys || true)"
    fi

    printf "  Текущий SSH-порт: %b%s%b\n" "$C_YELLOW" "$current_port" "$C_RESET"
    printf "  SSH-ключей root: %b%s%b\n\n" "$C_YELLOW" "$current_keys" "$C_RESET"

    # Prompt for new SSH port
    while true; do
        read -r -p "  Новый SSH-порт [${current_port}]: " SSH_PORT
        SSH_PORT="${SSH_PORT:-$current_port}"
        if valid_port "$SSH_PORT" && (( SSH_PORT >= 1024 )); then
            break
        fi
        warn "Введите порт от 1024 до 65535."
    done

    printf "\n%bBudут применены параметры:%b\n" "$C_BOLD" "$C_RESET"
    printf "  %b✓%b Port                            → %s\n" "$C_GREEN" "$C_RESET" "$SSH_PORT"
    printf "  %b✓%b PermitRootLogin                → prohibit-password\n" "$C_GREEN" "$C_RESET"
    printf "  %b✓%b KbdInteractiveAuthentication    → no\n" "$C_GREEN" "$C_RESET"
    printf "  %b✓%b MaxAuthTries                    → 3\n" "$C_GREEN" "$C_RESET"
    printf "  %b✓%b X11Forwarding                   → no\n\n" "$C_GREEN" "$C_RESET"

    local disable_pass="n"
    if (( current_keys == 0 )); then
        warn "SSH-ключ не найден в /root/.ssh/authorized_keys"
        warn "Отключать пароль сейчас НЕ рекомендуется."
    else
        if ask_yes_no "Отключить вход по паролю?" y; then
            disable_pass="y"
        fi
    fi

    # Backup original sshd_config
    mkdir -p "$BACKUP_DIR"
    cp -a /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.original"

    # Write new configuration
    cat > "$SSH_DROPIN" <<EOF
# Managed by VPS Security Setup v${SCRIPT_VERSION}
Port ${SSH_PORT}
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
MaxAuthTries 3
X11Forwarding no
DebianBanner no
PasswordAuthentication $([ "$disable_pass" = "y" ] && echo "no" || echo "yes")
EOF

    # Validate new configuration
    if ! sshd -t; then
        rm -f "$SSH_DROPIN"
        error "Новая конфигурация SSH не прошла проверку. Изменения отменены."
    fi

    success "Конфигурация SSH прошла проверку."
    pause_for_enter
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: FIREWALL (UFW)
# ══════════════════════════════════════════════════════════════════════════════

step_4_ufw() {
    title "4" "FIREWALL — UFW"

    printf "  SSH будет открыт на: %b%s/tcp%b\n\n" \
        "$C_GREEN" "$SSH_PORT" "$C_RESET"

    printf "  Часто используемые дополнительные порты:\n"
    printf "    80     HTTP\n"
    printf "    443    HTTPS\n"
    printf "    2096   Custom HTTPS\n"
    printf "    3306   MySQL\n\n"

    local extra
    read -r -p "  Дополнительные TCP-порты через пробел [80 443]: " extra
    extra="${extra:-80 443}"

    local -a ports=()
    for port in $extra; do
        if valid_port "$port"; then
            ports+=("$port")
        else
            warn "Пропускаю некорректный порт: $port"
        fi
    done

    printf "\n%bБудут разрешены входящие TCP:%b\n" "$C_BOLD" "$C_RESET"
    printf "  %b✓%b %s/tcp — SSH\n" "$C_GREEN" "$C_RESET" "$SSH_PORT"
    for port in "${ports[@]}"; do
        printf "  %b✓%b %s/tcp\n" "$C_GREEN" "$C_RESET" "$port"
    done
    printf "\n  Политика: входящее DENY | исходящее ALLOW\n\n"

    if ! ask_yes_no "Применить правила UFW?" y; then
        warn "UFW пропущен."
        pause_for_enter
        return
    fi

    run_with_spinner "Устанавливаю UFW..." \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y ufw

    # Reset and configure UFW
    ufw --force reset >/dev/null
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw limit "${SSH_PORT}/tcp" >/dev/null

    for port in "${ports[@]}"; do
        ufw allow "${port}/tcp" >/dev/null
    done

    printf "\n%bПредпросмотр правил:%b\n" "$C_BOLD" "$C_RESET"
    ufw status numbered || true
    printf "\n"

    ufw --force enable >/dev/null
    success "UFW активирован и включен."
    pause_for_enter
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: FAIL2BAN
# ══════════════════════════════════════════════════════════════════════════════

step_5_fail2ban() {
    title "5" "FAIL2BAN"

    run_with_spinner "Устанавливаю Fail2Ban..." \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban

    mkdir -p /etc/fail2ban/jail.d

    cat > "$F2B_JAIL" <<EOF
# Managed by VPS Security Setup v${SCRIPT_VERSION}
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

    systemctl enable --now fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban

    if fail2ban-client status sshd >/dev/null 2>&1; then
        success "Fail2Ban активен и защищает SSH."
    else
        warn "Fail2Ban запущен, но jail пока не удалось проверить."
    fi

    pause_for_enter
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6: VERIFICATION
# ══════════════════════════════════════════════════════════════════════════════

step_6_verify() {
    title "6" "ПРОВЕРКА БЕЗОПАСНОСТИ"

    local failed=0

    # Check sshd_config validity
    printf "  %-40s" "sshd_config корректен"
    if sshd -t 2>/dev/null; then
        printf "%b✓ OK%b\n" "$C_GREEN" "$C_RESET"
    else
        printf "%b✗ FAIL%b\n" "$C_RED" "$C_RESET"
        failed=1
    fi

    # Check SSH port
    printf "  %-40s" "SSH слушает ${SSH_PORT}/tcp"
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${SSH_PORT}$"; then
        printf "%b✓ OK%b\n" "$C_GREEN" "$C_RESET"
    else
        printf "%b✗ FAIL%b\n" "$C_RED" "$C_RESET"
        failed=1
    fi

    # Check UFW status
    printf "  %-40s" "UFW активен"
    if ufw status 2>/dev/null | grep -q '^Status: active'; then
        printf "%b✓ ACTIVE%b\n" "$C_GREEN" "$C_RESET"
    else
        printf "%b✗ FAIL%b\n" "$C_RED" "$C_RESET"
        failed=1
    fi

    # Check Fail2Ban status
    printf "  %-40s" "Fail2Ban активен"
    if systemctl is-active --quiet fail2ban; then
        printf "%b✓ ACTIVE%b\n" "$C_GREEN" "$C_RESET"
    else
        printf "%b✗ FAIL%b\n" "$C_RED" "$C_RESET"
        failed=1
    fi

    printf "\n"

    if (( failed )); then
        error "Одна или несколько проверок не пройдены. SSH НЕ перезапускается."
    fi

    success "Все проверки пройдены успешно."
    pause_for_enter
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7: SSH RESTART AND COMPLETION
# ══════════════════════════════════════════════════════════════════════════════

step_7_restart() {
    title "7" "ЗАВЕРШЕНИЕ"

    printf "%b! ВАЖНО%b\n\n" "$C_YELLOW$C_BOLD" "$C_RESET"
    printf "  Не закрывайте текущую SSH-сессию.\n"
    printf "  Откройте НОВОЕ окно терминала для проверки:\n\n"
    printf "    %bssh -p %s root@%s%b\n\n" \
        "$C_WHITE" "$SSH_PORT" "$(server_ip)" "$C_RESET"

    if ! ask_yes_no "Перезапустить SSH сейчас?" y; then
        warn "SSH не перезапущен. Позже выполните: systemctl restart ssh"
        pause_for_enter
        return
    fi

    systemctl restart ssh
    sleep 1

    if ! systemctl is-active --quiet ssh; then
        error "SSH не запустился. Текущую сессию НЕ закрывайте!"
    fi

    success "SSH успешно перезапущен."

    # Show completion summary
    local top bottom elapsed ip_addr
    top="╔$(repeat_char '═' "$BOX_WIDTH")╗"
    bottom="╚$(repeat_char '═' "$BOX_WIDTH")╝"
    elapsed="$(format_duration $(( $(date +%s) - SCRIPT_START_TS )))"
    ip_addr="$(server_ip)"

    clear 2>/dev/null || true
    printf "%b%s%b\n" "$C_GREEN" "$top" "$C_RESET"
    printf "%b│%b %b%-*s%b %b│%b\n" \
        "$C_GREEN" "$C_RESET" "$C_BOLD" "$((BOX_WIDTH-2))" "✓ НАСТРОЙКА ЗАВЕРШЕНА" \
        "$C_RESET" "$C_GREEN" "$C_RESET"
    printf "%b%s%b\n\n" "$C_GREEN" "$bottom" "$C_RESET"

    printf "%bSSH%b\n" "$C_BOLD" "$C_RESET"
    hr
    printf "  Порт                %s\n" "$SSH_PORT"
    if grep -q '^PasswordAuthentication no' "$SSH_DROPIN"; then
        printf "  Пароль              %bОТКЛЮЧЕН%b\n" "$C_GREEN" "$C_RESET"
    else
        printf "  Пароль              %bВКЛЮЧЕН%b\n" "$C_YELLOW" "$C_RESET"
    fi

    printf "\n%bFIREWALL%b\n" "$C_BOLD" "$C_RESET"
    hr
    printf "  UFW                 %bАКТИВЕН%b\n" "$C_GREEN" "$C_RESET"
    printf "  Входящее            DENY\n"
    printf "  Исходящее           ALLOW\n"

    printf "\n%bFAIL2BAN%b\n" "$C_BOLD" "$C_RESET"
    hr
    printf "  Статус              %bАКТИВЕН%b\n" "$C_GREEN" "$C_RESET"
    printf "  SSH jail            %bВКЛЮЧЕН%b\n" "$C_GREEN" "$C_RESET"
    printf "  Время блока         1 час\n"
    printf "  Max попыток         3\n"

    printf "\n%bRESERVE BACKUP%b\n" "$C_BOLD" "$C_RESET"
    hr
    printf "  %s\n" "$BACKUP_DIR"

    printf "\n%bПроверка подключения:%b\n" "$C_CYAN" "$C_RESET"
    printf "  ssh -p %s root@%s\n\n" "$SSH_PORT" "$ip_addr"

    printf "%bВремя выполнения:%b %s\n" "$C_DIM" "$C_RESET" "$elapsed"
    printf "%bЛог операций:%b %s\n\n" "$C_DIM" "$C_RESET" "$LOG_FILE"
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ══════════════════════════════════════════════════════════════════════════════

main() {
    require_root
    check_os
    show_intro

    step_1_update
    step_2_ipv6
    step_3_ssh
    step_4_ufw
    step_5_fail2ban
    step_6_verify
    step_7_restart
}

# ══════════════════════════════════════════════════════════════════════════════

main "$@"
