#!/usr/bin/env bash
set -euo pipefail

SCRIPT_SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BASE_DIR=${BENCHMARK_HOME:-"$HOME/benchmarkTests"}
GO_DIR="$BASE_DIR/go"
RESULTS_DIR="$BASE_DIR/results"
LOG_DIR="$BASE_DIR/logs"
SCRIPT_DIR="$BASE_DIR/scripts"
TODAY=$(date +%F)
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

CONFIG_FILE="$SCRIPT_SOURCE_DIR/.benchmark_config"
if [ ! -f "$CONFIG_FILE" ]; then
    CONFIG_FILE="$SCRIPT_DIR/.benchmark_config"
fi

CPU_SIBLING_PAIR=""

# Send a mail using available system MTAs
send_email() {
    local subject="$1"
    local body="$2"
    local recipient_list="$3"
    
    # Normalize space-separated emails to comma-separated
    recipient_list=$(echo "$recipient_list" | tr ' ' ',')
    
    if [ -z "$recipient_list" ]; then
        echo "No recipients provided for email: '$subject'"
        return 1
    fi
    
    echo "Sending email: '$subject' to $recipient_list"
    
    if command -v mailx >/dev/null 2>&1; then
        if echo -e "$body" | mailx -s "$subject" "$recipient_list" >/dev/null 2>&1; then
            return 0
        fi
    elif command -v mail >/dev/null 2>&1; then
        if echo -e "$body" | mail -s "$subject" "$recipient_list" >/dev/null 2>&1; then
            return 0
        fi
    elif command -v sendmail >/dev/null 2>&1; then
        if (
            echo "Subject: $subject"
            echo "To: $recipient_list"
            echo ""
            echo -e "$body"
        ) | sendmail -t >/dev/null 2>&1; then
            return 0
        fi
    fi
    
    echo "WARNING: Could not send email (no MTA configured or mail command failed)." >&2
    return 1
}

usage() {
    echo "Usage: $0 [--tag TAG | --commit HASH]"
    echo ""
    echo "With --tag or --commit, build and benchmark the specified Go revision."
    echo "Without either option, clone/update and benchmark the current master branch."
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
        apt-get) run_as_root apt-get update -y; run_as_root apt-get install -y "${resolved[@]}" ;;
        dnf) run_as_root dnf install -y "${resolved[@]}" ;;
        yum) run_as_root yum install -y "${resolved[@]}" ;;
        pacman) run_as_root pacman -Sy --noconfirm "${resolved[@]}" ;;
        zypper) run_as_root zypper --non-interactive install "${resolved[@]}" ;;
        brew) brew install "${resolved[@]}" ;;
    esac
}

# Run a command as root when the current user is not root.
run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        command -v sudo >/dev/null 2>&1 || { echo "sudo is required to install system packages." >&2; exit 1; }
        sudo "$@"
    fi
}

# Find the first pair of logical CPUs listed as siblings by sysfs.
find_sibling_pair() {
    local topology list first second start
    for topology in /sys/devices/system/cpu/cpu[0-9]*/topology/thread_siblings_list; do
        [ -r "$topology" ] || continue
        list=$(tr -d '[:space:]' < "$topology")
        if [[ "$list" == *,* ]]; then
            first=${list%%,*}
            second=${list#*,}
        elif [[ "$list" == *-* ]]; then
            start=${list%%-*}
            first=$start
            second=$((start + 1))
        else
            continue
        fi
        [ "$first" != "$second" ] || continue
        CPU_SIBLING_PAIR="$first,$second"
        return 0
    done
    return 1
}

# Check if we can safely edit crontab
check_crontab_permission() {
    local tmp_cron
    tmp_cron=$(mktemp 2>/dev/null || echo "/tmp/cron_test_$$")
    if crontab -l > "$tmp_cron" 2>/dev/null; then
        if crontab "$tmp_cron" 2>/dev/null; then
            rm -f "$tmp_cron"
            return 0
        else
            rm -f "$tmp_cron"
            return 1
        fi
    else
        # No crontab exists yet, try writing a test line and then removing it
        if echo "# test" | crontab - 2>/dev/null; then
            crontab -r 2>/dev/null || true
            return 0
        else
            return 1
        fi
    fi
}

# Check all pre-requisites
check_prerequisites() {
    local status=0
    local log_content=""
    log_content+="--- Go Benchmark Pre-requisite Check ---\n"
    log_content+="Timestamp: $(date '+%Y-%m-%d %H:%M:%S')\n"
    log_content+="Log File: $LOG_FILE\n\n"
    
    # 1. CPU Sibling check (skip if single IFL/core)
    local num_cpus
    num_cpus=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    if [ "$num_cpus" -eq 1 ]; then
        log_content+="1. CPU Pinning Check: SKIPPED (Single core/IFL/logical CPU detected)\n"
    else
        if find_sibling_pair; then
            log_content+="1. CPU Pinning Check: SUCCESS (CPU Sibling pair: $CPU_SIBLING_PAIR)\n"
        else
            log_content+="1. CPU Pinning Check: FAILED (No adjacent logical CPU sibling pair found for CPU pinning)\n"
            status=1
        fi
    fi
    
    # 2. Sudo user for taskset installation
    local has_taskset=false
    if command -v taskset >/dev/null 2>&1; then
        has_taskset=true
    fi
    
    local has_sudo=false
    if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
        has_sudo=true
    fi
    
    if [ "$has_taskset" = true ]; then
        log_content+="2. Taskset Sudo Check: SUCCESS (taskset already installed)\n"
    else
        if [ "$has_sudo" = true ]; then
            log_content+="2. Taskset Sudo Check: SUCCESS (taskset not installed, but passwordless sudo is available)\n"
        else
            log_content+="2. Taskset Sudo Check: FAILED (taskset is NOT installed, and passwordless sudo is NOT available)\n"
            status=1
        fi
    fi
    
    # 3. Required packages check
    local missing_pkgs=()
    for cmd in git make gcc python3 pip3 taskset; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_pkgs+=("$cmd")
        fi
    done
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c "import venv" >/dev/null 2>&1; then
            missing_pkgs+=("python3-venv")
        fi
    else
        missing_pkgs+=("python3-venv")
    fi
    
    if [ ${#missing_pkgs[@]} -eq 0 ]; then
        log_content+="3. Required Packages Check: SUCCESS (All required packages are already installed)\n"
    else
        log_content+="3. Required Packages Check: PENDING (Missing: ${missing_pkgs[*]}). Attempting installation...\n"
        if [ "$has_sudo" = false ] && [ "$(id -u)" -ne 0 ]; then
            log_content+="3. Required Packages Check: FAILED (Missing: ${missing_pkgs[*]}; cannot install without root/sudo)\n"
            status=1
        else
            if detect_package_manager; then
                if install_packages "${missing_pkgs[@]}" >> "$LOG_FILE" 2>&1; then
                    log_content+="3. Required Packages Check: SUCCESS (Successfully installed: ${missing_pkgs[*]})\n"
                else
                    log_content+="3. Required Packages Check: FAILED (Failed to install: ${missing_pkgs[*]})\n"
                    status=1
                fi
            else
                log_content+="3. Required Packages Check: FAILED (No supported package manager found to install: ${missing_pkgs[*]})\n"
                status=1
            fi
        fi
    fi
    
    # 4. Crontab check (skip if root user)
    if [ "$(id -u)" -eq 0 ]; then
        log_content+="4. Crontab Edit Check: SKIPPED (Running as root user)\n"
    else
        if check_crontab_permission; then
            log_content+="4. Crontab Edit Check: SUCCESS (Able to edit crontab)\n"
        else
            log_content+="4. Crontab Edit Check: FAILED (Permission denied/unable to edit crontab)\n"
            status=1
        fi
    fi
    
    log_content+="\n---------------------------------------\n"
    if [ "$status" -eq 0 ]; then
        log_content+="Overall Pre-requisites: SUCCESS\n"
    else
        log_content+="Overall Pre-requisites: FAILED\n"
    fi
    
    # Print results to stdout/logfile
    printf "%b" "$log_content"
    
    # Send email with pre-requisite results
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        if [ -n "${DEV_EMAILS:-}" ]; then
            local subject="Go Benchmark Pre-requisites: "
            if [ "$status" -eq 0 ]; then
                subject+="SUCCESS"
            else
                subject+="FAILED"
            fi
            send_email "$subject" "$(printf "%b" "$log_content")" "$DEV_EMAILS"
        fi
    else
        echo "WARNING: Configuration file $CONFIG_FILE not found. Cannot send pre-requisite email to devs."
    fi
    
    return "$status"
}

# Parse the explicitly requested revision, if any.
parse_args() {
    REVISION_MODE=master
    REVISION=
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --tag|--commit)
                [ "$#" -ge 2 ] || { echo "$1 requires a value." >&2; usage >&2; exit 2; }
                [ -z "$REVISION" ] || { echo "Specify only one of --tag or --commit." >&2; exit 2; }
                REVISION_MODE=$1
                REVISION=$2
                shift 2
                ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        esac
    done
}

parse_args "$@"

# Initialize Log File with Timestamp early
mkdir -p "$BASE_DIR" "$RESULTS_DIR" "$LOG_DIR" "$SCRIPT_DIR"
LOG_FILE="$LOG_DIR/daily_pipeline_${TIMESTAMP}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Run prerequisites check
if ! check_prerequisites; then
    echo "ERROR: Pre-requisites check failed. Exiting." >&2
    exit 1
fi

# Set up files in $SCRIPT_DIR
cp "$SCRIPT_SOURCE_DIR/daily_go_benchmark_pipeline.sh" "$SCRIPT_DIR/"
cp "$SCRIPT_SOURCE_DIR/generate_dashboard.py" "$SCRIPT_DIR/"
cp "$SCRIPT_SOURCE_DIR/generate_excel.py" "$SCRIPT_DIR/"
cp "$SCRIPT_SOURCE_DIR/requirements.txt" "$SCRIPT_DIR/"
if [ -f "$SCRIPT_SOURCE_DIR/.benchmark_config" ]; then
    cp "$SCRIPT_SOURCE_DIR/.benchmark_config" "$SCRIPT_DIR/"
fi
chmod 0755 "$SCRIPT_DIR/daily_go_benchmark_pipeline.sh"

VENV_DIR="$BASE_DIR/.venv"
python3 -m venv "$VENV_DIR"
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
python -m pip install --no-cache-dir -r "$SCRIPT_SOURCE_DIR/requirements.txt"

TODAY_DIR="$RESULTS_DIR/$TODAY"
mkdir -p "$TODAY_DIR"
START_TIME=$(date +%s)

if [ ! -d "$GO_DIR/.git" ]; then
    clone_attempt=1
    while ! git clone https://go.googlesource.com/go "$GO_DIR" --recursive; do
        echo "Go repository clone attempt $clone_attempt failed."
        [ "$clone_attempt" -lt 2 ] || { echo "Unable to clone the Go repository after 2 attempts." >&2; exit 1; }
        clone_attempt=$((clone_attempt + 1))
        sleep 5
    done
fi

cd "$GO_DIR"
if [ "$REVISION_MODE" = master ]; then
    git fetch origin master
    git checkout master
    git reset --hard origin/master
else
    git fetch --tags origin
    git checkout --detach "$REVISION"
fi
CURRENT_COMMIT=$(git rev-parse HEAD)

cd "$GO_DIR/src"
if ! ./make.bash; then
    echo "Go toolchain build failed." >&2
    exit 1
fi

RAW_BENCH="$TODAY_DIR/benchmark_raw.txt"

if [ -n "$CPU_SIBLING_PAIR" ]; then
    echo "Running pinned to logical CPU sibling pair: $CPU_SIBLING_PAIR"
    if ! taskset -c "$CPU_SIBLING_PAIR" "$GO_DIR/bin/go" test ./... -run=^$ -bench=. -benchmem -test.count=6 > "$RAW_BENCH"; then
        echo "Benchmark execution failed." >&2
        exit 1
    fi
else
    echo "Running unpinned (single CPU)..."
    if ! "$GO_DIR/bin/go" test ./... -run=^$ -bench=. -benchmem -test.count=6 > "$RAW_BENCH"; then
        echo "Benchmark execution failed." >&2
        exit 1
    fi
fi

# Metadata is written before comparison so it is preserved on a first run.
BENCHSTAT_FILE="$TODAY_DIR/benchstat.txt"
EXCEL_REPORT="$TODAY_DIR/report.xlsx"
HTML_REPORT="$TODAY_DIR/report.html"
STATE_FILE="$TODAY_DIR/dashboard_state.json"
METADATA_FILE="$TODAY_DIR/metadata.txt"
cat > "$METADATA_FILE" <<EOF
Date: $TODAY
Commit: $CURRENT_COMMIT
Mode: $REVISION_MODE
Raw Benchmark File: $RAW_BENCH
Benchstat File: $BENCHSTAT_FILE
Excel Report: $EXCEL_REPORT
HTML Report: $HTML_REPORT
Dashboard State: $STATE_FILE
EOF

CURRENT_RAW="$RAW_BENCH"
PREV_RAW=$(find "$RESULTS_DIR" -type f -name benchmark_raw.txt ! -path "$CURRENT_RAW" | sort | tail -1)
HAS_PREVIOUS_RESULTS=false
if [ -n "$PREV_RAW" ]; then
    HAS_PREVIOUS_RESULTS=true
fi

if [ "$HAS_PREVIOUS_RESULTS" = true ]; then
    PREV_DIR=$(dirname "$PREV_RAW")
    PREV_STATE="$PREV_DIR/dashboard_state.json"
    BASELINE_DATE=$(basename "$PREV_DIR")
    PREVIOUS_COMMIT=Unknown
    PREV_METADATA="$PREV_DIR/metadata.txt"
    if [ -f "$PREV_METADATA" ]; then
        PREVIOUS_COMMIT=$(grep '^Commit:' "$PREV_METADATA" | head -1 | cut -d' ' -f2)
    fi
    if ! command -v benchstat >/dev/null 2>&1; then
        go install golang.org/x/perf/cmd/benchstat@latest
    fi
    export PATH="$(go env GOPATH)/bin:$PATH"
    benchstat -format=text "$PREV_RAW" "$RAW_BENCH" > "$BENCHSTAT_FILE"
    python "$SCRIPT_DIR/generate_excel.py" "$BENCHSTAT_FILE" "$EXCEL_REPORT"
    if [ -f "$PREV_STATE" ]; then
        PREVIOUS_STATE_ARG="$PREV_STATE"
    else
        PREVIOUS_STATE_ARG=
    fi
    python "$SCRIPT_DIR/generate_dashboard.py" "$BENCHSTAT_FILE" "$HTML_REPORT" "$TODAY" "$BASELINE_DATE" "$CURRENT_COMMIT" "$PREVIOUS_COMMIT" "$STATE_FILE" "$PREVIOUS_STATE_ARG"
else
    echo "No previous benchmark result found; comparison reports were skipped."
fi

END_TIME=$(date +%s)
echo "Benchmark pipeline completed in $((END_TIME - START_TIME)) seconds."
echo "Metadata: $METADATA_FILE"
