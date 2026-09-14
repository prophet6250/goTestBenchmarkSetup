#!/usr/bin/env bash
set -euo pipefail

# Set to true to add the monthly cron entry automatically.
ENABLE_CRON=false
BENCHMARK_USER=${BENCHMARK_USER:-gobenchmark}
INSTALL_ROOT=${INSTALL_ROOT:-/opt/gobenchmark}
REPOSITORY_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BENCHMARK_HOME="/home/$BENCHMARK_USER/benchmarkTests"
SCRIPT_INSTALL_DIR="$INSTALL_ROOT/scripts"
CRON_LINE="0 2 26-31 * * [ \"\$(date -d '+3 days' +\\%m)\" != \"\$(date +\\%m)\" ] && $SCRIPT_INSTALL_DIR/daily_go_benchmark_pipeline.sh"

# Verify the current user can perform privileged operations.
check_root_access() {
    if [ "$(id -u)" -ne 0 ]; then
        if ! sudo -n true 2>/dev/null; then
            echo "This script requires root privileges. Run as root or ensure the current user has passwordless sudo." >&2
            exit 1
        fi
    fi
}

# Select the package manager available on the host.
detect_package_manager() {
    local manager
    for manager in apt-get dnf yum pacman zypper brew; do
        if command -v "$manager" >/dev/null 2>&1; then
            PACKAGE_MANAGER=$manager
            return 0
        fi
    done
    echo "No supported package manager found (apt, dnf, yum, pacman, zypper, brew)." >&2
    exit 1
}

# Resolve distro-specific package names.
package_name() {
    local package=$1
    case "$PACKAGE_MANAGER:$package" in
        apt-get:python) echo python3 ;;
        apt-get:pip) echo python3-pip ;;
        apt-get:venv) echo python3-venv ;;
        apt-get:jpeg) echo libjpeg-dev ;;
        apt-get:zlib) echo zlib1g-dev ;;
        apt-get:taskset) echo util-linux ;;
        dnf:python|yum:python) echo python3 ;;
        dnf:pip|yum:pip) echo python3-pip ;;
        dnf:venv|yum:venv) echo python3-virtualenv ;;
        dnf:jpeg|yum:jpeg) echo libjpeg-turbo-devel ;;
        dnf:zlib|yum:zlib) echo zlib-devel ;;
        dnf:taskset|yum:taskset) echo util-linux ;;
        pacman:python) echo python ;;
        pacman:pip) echo python-pip ;;
        pacman:venv) echo python-virtualenv ;;
        pacman:jpeg) echo libjpeg-turbo ;;
        pacman:zlib) echo zlib ;;
        pacman:taskset) echo util-linux ;;
        zypper:python) echo python3 ;;
        zypper:pip) echo python3-pip ;;
        zypper:venv) echo python3-virtualenv ;;
        zypper:jpeg) echo libjpeg-turbo-devel ;;
        zypper:zlib) echo zlib-devel ;;
        zypper:taskset) echo util-linux ;;
        brew:python) echo python ;;
        brew:pip) echo python ;;
        brew:venv) echo python ;;
        brew:jpeg) echo jpeg ;;
        brew:zlib) echo zlib ;;
        brew:taskset) echo util-linux ;;
        *) echo "$package" ;;
    esac
}

# Install named logical packages through the detected package manager.
install_packages() {
    local package
    local resolved=()
    for package in "$@"; do
        resolved+=("$(package_name "$package")")
    done
    case "$PACKAGE_MANAGER" in
        apt-get) apt-get update -y; apt-get install -y "${resolved[@]}" ;;
        dnf) dnf install -y "${resolved[@]}" ;;
        yum) yum install -y "${resolved[@]}" ;;
        pacman) pacman -Sy --noconfirm "${resolved[@]}" ;;
        zypper) zypper --non-interactive install "${resolved[@]}" ;;
        brew) brew install "${resolved[@]}" ;;
    esac
}

# Create the dedicated system account and home directory.
create_benchmark_user() {
    if ! id "$BENCHMARK_USER" >/dev/null 2>&1; then
        useradd --system --create-home --home-dir "/home/$BENCHMARK_USER" --shell /bin/bash "$BENCHMARK_USER"
    fi
    install -d -m 0750 -o "$BENCHMARK_USER" -g "$BENCHMARK_USER" "/home/$BENCHMARK_USER"
}

# Report or install the monthly cron entry for master/latest mode.
configure_cron() {
    local existing
    existing=$(crontab -u "$BENCHMARK_USER" -l 2>/dev/null || true)
    if printf '%s\n' "$existing" | grep -Fqx "$CRON_LINE"; then
        echo "Cron entry already exists for $BENCHMARK_USER:"
        echo "$CRON_LINE"
        return 0
    fi
    echo "Cron entry is not present for $BENCHMARK_USER."
    echo "Cron line that would be added:"
    echo "$CRON_LINE"
    if [ "$ENABLE_CRON" = true ]; then
        { printf '%s\n' "$existing"; printf '%s\n' "$CRON_LINE"; } | crontab -u "$BENCHMARK_USER" -
        echo "Cron entry added."
    else
        echo "ENABLE_CRON=false; crontab was not modified."
    fi
}

check_root_access
detect_package_manager
install_packages git make gcc python pip venv jpeg zlib taskset
create_benchmark_user

install -d -m 0755 "$INSTALL_ROOT" "$SCRIPT_INSTALL_DIR"
install -o "$BENCHMARK_USER" -g "$BENCHMARK_USER" -m 0755 "$REPOSITORY_DIR/daily_go_benchmark_pipeline.sh" "$SCRIPT_INSTALL_DIR/"
install -o "$BENCHMARK_USER" -g "$BENCHMARK_USER" -m 0644 "$REPOSITORY_DIR/generate_dashboard.py" "$SCRIPT_INSTALL_DIR/"
install -o "$BENCHMARK_USER" -g "$BENCHMARK_USER" -m 0644 "$REPOSITORY_DIR/generate_excel.py" "$SCRIPT_INSTALL_DIR/"
install -o "$BENCHMARK_USER" -g "$BENCHMARK_USER" -m 0644 "$REPOSITORY_DIR/requirements.txt" "$SCRIPT_INSTALL_DIR/"

install -d -m 0750 -o "$BENCHMARK_USER" -g "$BENCHMARK_USER" "$BENCHMARK_HOME"
chown -R "$BENCHMARK_USER:$BENCHMARK_USER" "$INSTALL_ROOT" "$BENCHMARK_HOME"
su - "$BENCHMARK_USER" -c "python3 -m venv '$BENCHMARK_HOME/.venv'"
su - "$BENCHMARK_USER" -c "'$BENCHMARK_HOME/.venv/bin/python' -m pip install --no-cache-dir -r '$SCRIPT_INSTALL_DIR/requirements.txt'"

configure_cron
echo "Benchmark environment installed for $BENCHMARK_USER."
