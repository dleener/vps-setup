#!/usr/bin/env bash
#
# ============================================================================
#  vps-setup.sh — Первоначальная базовая настройка VPS (Ubuntu/Debian)
# ============================================================================
#
#  Скрипт выполняет пошагово, с подтверждением на каждом этапе:
#    1. Обновление системы (apt update && apt upgrade)
#    2. Отключение IPv6 на уровне ядра
#    3. Защита SSH (смена порта + отключение входа по паролю)
#    4. Настройка фаервола UFW (запрет всего входящего, кроме нужного)
#    5. Установка и настройка Fail2Ban (защита SSH от перебора паролей)
#
#  Репозиторий: разместите этот файл в GitHub и запускайте на чистом VPS
#  под root (или через sudo):
#
#     sudo bash vps-setup.sh
#
#  Скрипт написан так, чтобы НЕ заблокировать вам доступ к серверу:
#  на каждом рискованном шаге он просит проверить результат в НОВОМ
#  терминале, прежде чем закрыть текущую сессию SSH.
#
# ============================================================================

# --- Базовые проверки окружения -------------------------------------------

if [ -z "${BASH_VERSION:-}" ]; then
    echo "Пожалуйста, запустите этот скрипт через bash: sudo bash vps-setup.sh"
    exit 1
fi

set -uo pipefail

# --- Оформление -------------------------------------------------------------

readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_RED='\033[0;31m'
readonly C_BLUE='\033[0;34m'
readonly C_CYAN='\033[0;36m'

LOG_FILE="/var/log/vps-setup-$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/vps-setup-$(date +%Y%m%d-%H%M%S).log"

log() {
    printf '%s\n' "$1" | sed -E 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE"
}

line() { printf '%s\n' "────────────────────────────────────────────────────────────────────"; }

header() {
    echo
    printf '%b' "${C_BOLD}${C_BLUE}"
    line
    printf "  %s\n" "$1"
    line
    printf '%b' "${C_RESET}"
    log "=== $1 ==="
}

step_title() {
    echo
    printf "${C_BOLD}${C_CYAN}▶ %s${C_RESET}\n" "$1"
    log "-> $1"
}

info()    { printf "${C_BLUE}ℹ %s${C_RESET}\n" "$1"; log "INFO: $1"; }
success() { printf "${C_GREEN}✔ %s${C_RESET}\n" "$1"; log "OK: $1"; }
warn()    { printf "${C_YELLOW}⚠ %s${C_RESET}\n" "$1"; log "WARN: $1"; }
error()   { printf "${C_RED}✘ %s${C_RESET}\n" "$1"; log "ERROR: $1"; }

# Пауза с ожиданием Enter
pause() {
    echo
    read -r -p "$(printf '%bНажмите Enter, чтобы продолжить...%b' "$C_BOLD" "$C_RESET")" _
}

# confirm "Вопрос" "y|n" -> код возврата 0 = да, 1 = нет
confirm() {
    local prompt="$1"
    local default="${2:-y}"
    local hint yn
    if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    while true; do
        read -r -p "$(printf "${C_BOLD}%s %s: ${C_RESET}" "$prompt" "$hint")" yn
        yn="${yn:-$default}"
        case "$yn" in
            [Yy]|[Yy][Ee][Ss]|[Дд]|[Дд][Аа]) return 0 ;;
            [Nn]|[Nn][Oo]|[Нн]|[Нн][Ее][Тт]) return 1 ;;
            *) echo "Пожалуйста, введите y (да) или n (нет)." ;;
        esac
    done
}

# ask_value "Вопрос" "значение_по_умолчанию" -> печатает результат в stdout
ask_value() {
    local prompt="$1"
    local default="$2"
    local val
    read -r -p "$(printf "${C_BOLD}%s [%s]: ${C_RESET}" "$prompt" "$default")" val
    echo "${val:-$default}"
}

abort() {
    error "$1"
    error "Скрипт остановлен. Ничего дальше выполняться не будет."
    exit 1
}

# --- Проверка прав root -------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    error "Этот скрипт нужно запускать с правами root."
    echo "Запустите так: sudo bash $0"
    exit 1
fi

# --- Определение ОС -------------------------------------------------------

OS_ID="unknown"
OS_VERSION="unknown"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
fi

# --- Определение внешнего IP-адреса сервера --------------------------------
# Нужен, чтобы подставлять его в примеры команд (ssh, ssh-copy-id) вместо
# плейсхолдера — так их можно скопировать и сразу выполнить без правок.

detect_server_ip() {
    local ip=""
    # Сначала пробуем узнать реальный внешний IP через интернет-сервис —
    # это надёжнее всего для VPS за NAT/с несколькими интерфейсами.
    if command -v curl >/dev/null 2>&1; then
        ip=$(curl -s -4 --max-time 3 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')
        if [ -z "$ip" ]; then
            ip=$(curl -s -4 --max-time 3 https://ifconfig.me 2>/dev/null | tr -d '[:space:]')
        fi
    fi
    # Если интернета нет или curl недоступен — берём локальный адрес
    # исходящего интерфейса.
    if [ -z "$ip" ]; then
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}')
    fi
    if [ -z "$ip" ]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "$ip"
}

SERVER_IP="$(detect_server_ip)"

# --- Приветствие ------------------------------------------------------------

clear 2>/dev/null || true
header "Базовая настройка VPS"

cat <<EOF
Этот скрипт шаг за шагом выполнит первоначальную настройку сервера:

  1) Обновление системы (apt update && apt upgrade)
  2) Отключение IPv6
  3) Защита SSH (смена порта, вход только по ключу)
  4) Настройка фаервола UFW
  5) Установка Fail2Ban (защита от перебора паролей)

Перед каждым важным действием скрипт объясняет, что будет сделано,
и спрашивает подтверждение. Везде, где это уместно, можно просто
нажать Enter, чтобы согласиться со значением по умолчанию.

Обнаруженная система: ${OS_ID} ${OS_VERSION}
Журнал выполнения сохраняется в: ${LOG_FILE}
EOF

if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
    warn "Скрипт рассчитан на Ubuntu/Debian. Обнаружена другая система (${OS_ID})."
    confirm "Всё равно продолжить на свой страх и риск?" "n" || exit 0
fi

echo
if [ -n "$SERVER_IP" ]; then
    info "Определён внешний IP-адрес сервера: ${SERVER_IP}"
else
    warn "Не удалось автоматически определить IP-адрес сервера."
fi
SERVER_IP=$(ask_value "IP-адрес сервера (для примеров команд подключения)" "${SERVER_IP:-<IP-адрес-сервера>}")

echo
confirm "Начать настройку сервера?" "y" || { echo "Отменено пользователем."; exit 0; }

# ============================================================================
#  ШАГ 1. Обновление системы
# ============================================================================

step1_update_system() {
    header "Шаг 1 из 5. Обновление системы"
    echo "Сейчас будут выполнены команды:"
    echo "  apt-get update"
    echo "  apt-get upgrade -y"
    echo
    echo "Это установит последние обновления безопасности и пакетов."
    echo "Обычно это безопасно и не требует вашего участия."
    confirm "Выполнить обновление системы сейчас?" "y" || { info "Шаг 1 пропущен."; return; }

    step_title "Обновление списка пакетов (apt-get update)"
    if ! DEBIAN_FRONTEND=noninteractive apt-get update -y; then
        warn "apt-get update завершился с ошибкой. Проверьте подключение к интернету и репозитории."
        confirm "Продолжить, несмотря на ошибку?" "n" || abort "Остановлено на шаге обновления."
    else
        success "Список пакетов обновлён."
    fi

    step_title "Обновление установленных пакетов (apt-get upgrade)"
    if ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; then
        warn "apt-get upgrade завершился с ошибкой."
        confirm "Продолжить настройку дальше?" "y" || abort "Остановлено пользователем после ошибки upgrade."
    else
        success "Система обновлена."
    fi

    if [ -f /var/run/reboot-required ]; then
        warn "Обновление отметило, что серверу нужна перезагрузка (сделаем это в конце, по желанию)."
    fi
}

# ============================================================================
#  ШАГ 2. Отключение IPv6
# ============================================================================

step2_disable_ipv6() {
    header "Шаг 2 из 5. Отключение IPv6"
    cat <<EOF
Если ваш сервер использует только IPv4, IPv6 лучше отключить:
  - это упрощает настройку фаервола (не нужно дублировать правила для IPv6);
  - убирает риск случайных «утечек» трафика в обход правил IPv4.

Будет создан файл /etc/sysctl.d/99-disable-ipv6.conf и параметры ядра
применятся немедленно, без перезагрузки.

Если вы точно используете IPv6 (например, для сайтов или почты) — откажитесь.
EOF
    confirm "Отключить IPv6?" "n" || { info "IPv6 оставлен включённым."; return; }

    step_title "Отключение IPv6 через sysctl"
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<EOF
# Отключение IPv6 (создано vps-setup.sh)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    if sysctl --system >/dev/null 2>>"$LOG_FILE"; then
        success "IPv6 отключён на уровне ядра (действует сразу, сохранится после перезагрузки)."
    else
        warn "Не удалось применить sysctl --system, но настройка сохранена в файл и заработает после перезагрузки."
    fi
}

# ============================================================================
#  ШАГ 3. Защита SSH
# ============================================================================

SSH_NEW_PORT=""
SSH_USES_SOCKET=0
SSH_CURRENT_PORT="22"
# Порт и вход-по-паролю сознательно лежат в РАЗНЫХ файлах: если бы они были
# в одном файле, повторный запуск скрипта (шаг A перезаписывает файл целиком)
# случайно стирал бы уже сделанный выбор по паролю, и наоборот.
SSHD_PORT_DROPIN="/etc/ssh/sshd_config.d/99-vps-setup-port.conf"
SSHD_AUTH_DROPIN="/etc/ssh/sshd_config.d/99-vps-setup-auth.conf"

get_current_ssh_port() {
    local p
    p=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
    if [ -n "$p" ]; then
        echo "$p"
    else
        echo "22"
    fi
}

ssh_socket_active() {
    # Возвращает 0, если SSH работает через systemd socket-активацию
    # (это по умолчанию в Ubuntu 24.04)
    if systemctl list-unit-files 2>/dev/null | grep -q '^ssh.socket'; then
        if systemctl is-enabled ssh.socket >/dev/null 2>&1 || systemctl is-active ssh.socket >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

ipv6_is_disabled() {
    # Возвращает 0, если IPv6 отключён в ядре (в т.ч. если сам этот скрипт
    # отключил его на шаге 2) — тогда сокет ssh.socket нельзя привязывать
    # к двойному стеку "::", иначе соединения будут устанавливаться,
    # но тут же обрываться.
    local v
    if [ ! -e /proc/sys/net/ipv6 ]; then
        return 0
    fi
    v=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    [ "$v" = "1" ]
}

write_ssh_socket_override() {
    # Пишет override для ssh.socket, слушая порт явно на IPv4 (и на IPv6,
    # только если IPv6 в ядре не отключён — иначе двойной стек "::"
    # ломает реальные подключения, хотя bind() при этом не выдаёт ошибку).
    local port="$1"
    mkdir -p /etc/systemd/system/ssh.socket.d
    {
        echo "[Socket]"
        echo "ListenStream="
        echo "ListenStream=0.0.0.0:${port}"
        if ! ipv6_is_disabled; then
            echo "ListenStream=[::]:${port}"
        fi
    } > /etc/systemd/system/ssh.socket.d/override.conf
}

ensure_sshd_config_include() {
    # Убеждаемся, что /etc/ssh/sshd_config подключает файлы из sshd_config.d/
    mkdir -p /etc/ssh/sshd_config.d
    if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
        info "В sshd_config добавлена строка подключения sshd_config.d/*.conf"
    fi
}

step3_harden_ssh() {
    header "Шаг 3 из 5. Защита SSH"

    SSH_CURRENT_PORT="$(get_current_ssh_port)"
    if ssh_socket_active; then
        SSH_USES_SOCKET=1
        info "Обнаружена socket-активация SSH (ssh.socket) — это стандарт для Ubuntu 24.04."
    else
        SSH_USES_SOCKET=0
        info "SSH работает как обычная служба (ssh.service)."
    fi
    info "Текущий порт SSH: ${SSH_CURRENT_PORT}"

    echo
    cat <<EOF
Сейчас настроим два уровня защиты SSH:

  A) Смена порта SSH со стандартного 22 на нестандартный
     (это не «настоящая» защита, но резко снижает число автоматических
     атак ботов, которые сканируют только порт 22).

  B) Отключение входа по паролю — останется вход ТОЛЬКО по SSH-ключу.
     Это гораздо важнее для безопасности, чем смена порта.

⚠ ВАЖНО: НЕ закрывайте текущее окно терминала до тех пор, пока не
   проверите, что новый вход работает, в отдельном (новом) окне!
EOF
    pause

    # --- A) Смена порта --------------------------------------------------
    step_title "A) Смена порта SSH"
    if confirm "Сменить порт SSH со значения ${SSH_CURRENT_PORT}?" "y"; then
        local suggested
        suggested=$(shuf -i 20000-65000 -n 1 2>/dev/null || echo "2222")
        local new_port
        while true; do
            new_port=$(ask_value "Введите новый порт SSH (рекомендуемый диапазон 1024-65535)" "$suggested")
            if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                error "Некорректный порт. Введите число от 1 до 65535."
                continue
            fi
            if [ "$new_port" = "$SSH_CURRENT_PORT" ]; then
                warn "Это и есть текущий порт SSH, менять его на самого себя нет смысла."
                if confirm "Всё равно оставить ${new_port}?" "n"; then break; else continue; fi
            fi
            if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${new_port}\$"; then
                warn "Похоже, порт ${new_port} уже кем-то занят на этом сервере."
                if confirm "Всё равно использовать этот порт?" "n"; then break; else continue; fi
            fi
            break
        done
        SSH_NEW_PORT="$new_port"

        ensure_sshd_config_include
        cp -a /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null

        cat > "$SSHD_PORT_DROPIN" <<EOF
# Создано vps-setup.sh — не редактируйте вручную, используйте новый запуск скрипта
Port ${SSH_NEW_PORT}
EOF

        if [ "$SSH_USES_SOCKET" -eq 1 ]; then
            write_ssh_socket_override "$SSH_NEW_PORT"
            info "Настроена socket-активация (ssh.socket) на новый порт."
        fi

        if ! sshd -t 2>>"$LOG_FILE"; then
            error "Конфигурация SSH содержит ошибку! Изменения порта отменены."
            rm -f "$SSHD_PORT_DROPIN"
            rm -f /etc/systemd/system/ssh.socket.d/override.conf
            SSH_NEW_PORT=""
        else
            step_title "Открываем новый порт в UFW заранее (чтобы не потерять доступ)"
            if command -v ufw >/dev/null 2>&1; then
                ufw allow "${SSH_NEW_PORT}"/tcp comment 'SSH (vps-setup.sh)' >>"$LOG_FILE" 2>&1
            fi

            step_title "Применяем новый порт SSH"
            systemctl daemon-reload
            if [ "$SSH_USES_SOCKET" -eq 1 ]; then
                systemctl restart ssh.socket
            else
                systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null
            fi
            sleep 1

            if ss -tln 2>/dev/null | grep -q ":${SSH_NEW_PORT} "; then
                success "SSH теперь слушает порт ${SSH_NEW_PORT}."
            else
                warn "Не удалось подтвердить через 'ss', что порт ${SSH_NEW_PORT} слушается. Проверьте вручную."
            fi

            echo
            warn "ОСТАНОВИТЕСЬ. Откройте НОВОЕ окно терминала и проверьте вход:"
            printf "${C_BOLD}    ssh -p %s %s@%s${C_RESET}\n" "$SSH_NEW_PORT" "${SUDO_USER:-root}" "$SERVER_IP"
            echo
            echo "Не закрывайте текущую сессию, пока не убедитесь, что новая работает!"
            pause

            if confirm "Новый вход по порту ${SSH_NEW_PORT} успешно сработал?" "y"; then
                success "Отлично. Порт ${SSH_NEW_PORT} подтверждён как рабочий."
                if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "22/tcp"; then
                    if confirm "Закрыть старый порт 22 в фаерволе?" "y"; then
                        ufw delete allow 22/tcp >>"$LOG_FILE" 2>&1
                        success "Порт 22 закрыт."
                    fi
                fi
            else
                error "Откатываю изменения порта SSH, чтобы не потерять доступ к серверу."
                rm -f "$SSHD_PORT_DROPIN"
                rm -f /etc/systemd/system/ssh.socket.d/override.conf
                systemctl daemon-reload
                if [ "$SSH_USES_SOCKET" -eq 1 ]; then
                    systemctl restart ssh.socket
                else
                    systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null
                fi
                SSH_NEW_PORT="$SSH_CURRENT_PORT"
                warn "Порт SSH возвращён на ${SSH_CURRENT_PORT}."
            fi
        fi
    else
        info "Порт SSH оставлен без изменений: ${SSH_CURRENT_PORT}."
        SSH_NEW_PORT="$SSH_CURRENT_PORT"
    fi

    # --- B) Отключение входа по паролю -----------------------------------
    echo
    step_title "B) Отключение входа по паролю (только SSH-ключи)"

    local target_user="${SUDO_USER:-root}"
    target_user=$(ask_value "Для какого пользователя проверить наличие SSH-ключа" "$target_user")
    local home_dir
    home_dir=$(getent passwd "$target_user" 2>/dev/null | cut -d: -f6)
    local keys_file="${home_dir:-/root}/.ssh/authorized_keys"

    if [ -s "$keys_file" ]; then
        success "У пользователя '${target_user}' найден файл с ключами: ${keys_file}"
    else
        warn "У пользователя '${target_user}' НЕ найден authorized_keys с ключом (${keys_file})."
        warn "Если отключить пароль сейчас, вы можете потерять доступ к серверу!"
        echo
        echo "Сначала на СВОЁМ компьютере выполните (в новом окне терминала):"
        printf "${C_BOLD}    ssh-copy-id -p %s %s@%s${C_RESET}\n" "${SSH_NEW_PORT:-22}" "$target_user" "$SERVER_IP"
        echo "и только потом отключайте вход по паролю."
    fi

    if confirm "Отключить вход по паролю для SSH (оставить только ключи)?" "$([ -s "$keys_file" ] && echo y || echo n)"; then
        if [ ! -s "$keys_file" ]; then
            warn "Ключ не найден, но вы всё равно хотите продолжить."
            confirm "Вы ТОЧНО уверены? Это может заблокировать вам доступ!" "n" || { info "Отключение пароля пропущено."; return; }
        fi
        ensure_sshd_config_include
        cat > "$SSHD_AUTH_DROPIN" <<EOF
# Создано vps-setup.sh — не редактируйте вручную, используйте новый запуск скрипта
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF
        if sshd -t 2>>"$LOG_FILE"; then
            if [ "$SSH_USES_SOCKET" -eq 1 ]; then
                systemctl restart ssh.socket
            else
                systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null
            fi
            success "Вход по паролю отключён. Теперь работает только вход по SSH-ключу."
            echo
            warn "Проверьте в НОВОМ окне терминала, что вход по ключу всё ещё работает,"
            warn "прежде чем закрывать текущую сессию!"
            pause
            if ! confirm "Вход по ключу точно сработал в новом окне?" "y"; then
                error "Откатываю отключение пароля, чтобы не потерять доступ к серверу."
                rm -f "$SSHD_AUTH_DROPIN"
                if [ "$SSH_USES_SOCKET" -eq 1 ]; then
                    systemctl restart ssh.socket
                else
                    systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null
                fi
                warn "Вход по паролю снова включён."
            fi
        else
            error "Ошибка в конфигурации SSH. Отключение пароля отменено."
            rm -f "$SSHD_AUTH_DROPIN"
        fi
    else
        info "Вход по паролю оставлен включённым."
    fi
}

# ============================================================================
#  ШАГ 4. Настройка фаервола (UFW)
# ============================================================================

step4_setup_firewall() {
    header "Шаг 4 из 5. Настройка фаервола UFW"
    cat <<EOF
Сейчас настроим UFW (Uncomplicated Firewall):

  - весь входящий трафик будет запрещён по умолчанию;
  - весь исходящий трафик будет разрешён;
  - будет автоматически открыт ваш порт SSH (${SSH_NEW_PORT:-22});
  - вы сможете дополнительно открыть любые нужные порты (например, 80 и 443).
EOF
    confirm "Настроить фаервол UFW?" "y" || { info "Шаг 4 пропущен."; return; }

    if ! command -v ufw >/dev/null 2>&1; then
        step_title "Установка UFW"
        if DEBIAN_FRONTEND=noninteractive apt-get install -y ufw >>"$LOG_FILE" 2>&1; then
            success "UFW установлен."
        else
            abort "Не удалось установить UFW."
        fi
    fi

    step_title "Правила по умолчанию"
    ufw default deny incoming >>"$LOG_FILE" 2>&1
    ufw default allow outgoing >>"$LOG_FILE" 2>&1
    success "По умолчанию: весь входящий трафик запрещён, весь исходящий — разрешён."

    step_title "Открываем порт SSH"
    local ssh_port="${SSH_NEW_PORT:-22}"
    ufw allow "${ssh_port}"/tcp comment 'SSH (vps-setup.sh)' >>"$LOG_FILE" 2>&1
    success "Порт ${ssh_port}/tcp (SSH) разрешён."

    step_title "Дополнительные порты"
    if confirm "Открыть стандартные веб-порты 80 (HTTP) и 443 (HTTPS)?" "n"; then
        ufw allow 80/tcp comment 'HTTP (vps-setup.sh)' >>"$LOG_FILE" 2>&1
        ufw allow 443/tcp comment 'HTTPS (vps-setup.sh)' >>"$LOG_FILE" 2>&1
        success "Порты 80 и 443 открыты."
    fi

    while confirm "Открыть ещё один дополнительный порт?" "n"; do
        local extra_port extra_proto
        extra_port=$(ask_value "Номер порта" "")
        if ! [[ "$extra_port" =~ ^[0-9]+$ ]] || [ "$extra_port" -lt 1 ] || [ "$extra_port" -gt 65535 ]; then
            error "Некорректный номер порта, пропускаю."
            continue
        fi
        extra_proto=$(ask_value "Протокол (tcp/udp)" "tcp")
        ufw allow "${extra_port}/${extra_proto}" comment 'custom (vps-setup.sh)' >>"$LOG_FILE" 2>&1
        success "Порт ${extra_port}/${extra_proto} открыт."
    done

    echo
    warn "Порт SSH (${ssh_port}) уже открыт, поэтому включение фаервола безопасно."
    if confirm "Включить UFW сейчас?" "y"; then
        ufw --force enable >>"$LOG_FILE" 2>&1
        success "UFW включён и активен."
        echo
        ufw status verbose
    else
        info "UFW настроен, но не включён. Включить позже: sudo ufw enable"
    fi
}

# ============================================================================
#  ШАГ 5. Fail2Ban
# ============================================================================

step5_setup_fail2ban() {
    header "Шаг 5 из 5. Установка Fail2Ban"
    cat <<EOF
Fail2Ban следит за логами SSH и временно блокирует IP-адреса, с которых
подбирают пароль. Значения по умолчанию:

  - блокировка (бан):     1 час
  - число попыток:        3
  - окно отслеживания:    10 минут
EOF
    confirm "Установить и настроить Fail2Ban?" "y" || { info "Шаг 5 пропущен."; return; }

    if ! command -v fail2ban-server >/dev/null 2>&1; then
        step_title "Установка Fail2Ban"
        if DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban >>"$LOG_FILE" 2>&1; then
            success "Fail2Ban установлен."
        else
            abort "Не удалось установить Fail2Ban."
        fi
    fi

    local bantime="1h"
    local maxretry="3"
    local findtime="10m"

    if ! confirm "Использовать значения по умолчанию (бан 1 час, 3 попытки)?" "y"; then
        bantime=$(ask_value "Время блокировки (например: 1h, 30m, 1d)" "$bantime")
        maxretry=$(ask_value "Число неудачных попыток до блокировки" "$maxretry")
        findtime=$(ask_value "Окно отслеживания попыток (например: 10m)" "$findtime")
    fi

    local ssh_port="${SSH_NEW_PORT:-22}"

    step_title "Создание /etc/fail2ban/jail.local"
    cat > /etc/fail2ban/jail.local <<EOF
# Создано vps-setup.sh
[DEFAULT]
bantime  = ${bantime}
findtime = ${findtime}
maxretry = ${maxretry}

[sshd]
enabled  = true
port     = ${ssh_port}
filter   = sshd
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
EOF

    systemctl enable fail2ban >>"$LOG_FILE" 2>&1
    systemctl restart fail2ban

    sleep 1
    if systemctl is-active --quiet fail2ban; then
        success "Fail2Ban запущен и следит за портом ${ssh_port}."
        echo
        fail2ban-client status sshd 2>/dev/null || true
    else
        warn "Fail2Ban не запустился. Проверьте: systemctl status fail2ban"
    fi
}

# ============================================================================
#  Итоги
# ============================================================================

print_summary() {
    header "Готово! Итоги настройки"
    echo "  Порт SSH:            ${SSH_NEW_PORT:-$SSH_CURRENT_PORT}"
    if command -v ufw >/dev/null 2>&1; then
        echo "  UFW:                 $(ufw status | head -n1)"
    fi
    if command -v fail2ban-client >/dev/null 2>&1; then
        echo "  Fail2Ban:            $(systemctl is-active fail2ban 2>/dev/null || echo 'не запущен')"
    fi
    echo "  Журнал выполнения:   ${LOG_FILE}"
    echo
    warn "Обязательно сохраните новый порт SSH — без него вы не сможете подключиться!"

    if [ -f /var/run/reboot-required ]; then
        echo
        if confirm "Системе требуется перезагрузка. Перезагрузить сейчас?" "n"; then
            info "Перезагрузка..."
            reboot
        else
            info "Не забудьте перезагрузить сервер позже: sudo reboot"
        fi
    fi
}

# ============================================================================
#  Главный сценарий
# ============================================================================

main() {
    step1_update_system
    pause
    step2_disable_ipv6
    pause
    step3_harden_ssh
    pause
    step4_setup_firewall
    pause
    step5_setup_fail2ban
    print_summary
}

main "$@"
