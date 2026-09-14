#!/usr/bin/env bash
set -euo pipefail

SCRIPT_SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BASE_DIR=${BENCHMARK_HOME:-"$HOME/benchmarkTests"}
GO_DIR="$BASE_DIR/go"
RESULTS_DIR="$BASE_DIR/results"
LOG_DIR="$BASE_DIR/logs"
SCRIPT_DIR="$BASE_DIR/scripts"
TODAY=$(date +%F)

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
detect_package_manager
install_packages git make gcc python pip venv jpeg zlib taskset

mkdir -p "$BASE_DIR" "$RESULTS_DIR" "$LOG_DIR" "$SCRIPT_DIR"
cp "$SCRIPT_SOURCE_DIR/daily_go_benchmark_pipeline.sh" "$SCRIPT_DIR/"
cp "$SCRIPT_SOURCE_DIR/generate_dashboard.py" "$SCRIPT_DIR/"
cp "$SCRIPT_SOURCE_DIR/generate_excel.py" "$SCRIPT_DIR/"
cp "$SCRIPT_SOURCE_DIR/requirements.txt" "$SCRIPT_DIR/"
chmod 0755 "$SCRIPT_DIR/daily_go_benchmark_pipeline.sh"

VENV_DIR="$BASE_DIR/.venv"
python3 -m venv "$VENV_DIR"
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
python -m pip install --no-cache-dir -r "$SCRIPT_SOURCE_DIR/requirements.txt"

TODAY_DIR="$RESULTS_DIR/$TODAY"
mkdir -p "$TODAY_DIR"
LOG_FILE="$LOG_DIR/daily_pipeline_$TODAY.log"
exec > >(tee -a "$LOG_FILE") 2>&1
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

if ! find_sibling_pair; then
    echo "No adjacent logical CPU sibling pair was found; benchmark affinity is required." >&2
    exit 1
fi
command -v taskset >/dev/null 2>&1 || { echo "taskset is required for benchmark CPU affinity." >&2; exit 1; }
RAW_BENCH="$TODAY_DIR/benchmark_raw.txt"

if ! taskset -c "$CPU_SIBLING_PAIR" "$GO_DIR/bin/go" test ./... -run=^$ -bench=. -benchmem -test.count=6 > "$RAW_BENCH"; then
    echo "Benchmark execution failed." >&2
    exit 1
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
