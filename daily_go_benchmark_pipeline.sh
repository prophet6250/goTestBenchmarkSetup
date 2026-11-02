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

CPU_PIN_CORE="0"
RUN_HISTORY_FILE="$BASE_DIR/logs/run_history.txt"

# Send a mail using available system MTAs with optional attachment
send_email() {
    local subject="$1"
    local body="$2"
    local recipient_list="$3"
    local attachment_path="${4:-}"
    
    # Normalize space-separated emails to comma-separated
    recipient_list=$(echo "$recipient_list" | tr ' ' ',')
    
    if [ -z "$recipient_list" ]; then
        echo "No recipients provided for email: '$subject'"
        return 1
    fi
    
    echo "Sending email: '$subject' to $recipient_list"
    
    local mailx_opts=()
    if [ -n "$attachment_path" ] && [ -f "$attachment_path" ]; then
        mailx_opts=(-a "$attachment_path")
        echo "Attaching file: $attachment_path"
    fi
    
    if command -v mailx >/dev/null 2>&1; then
        if echo -e "$body" | mailx "${mailx_opts[@]}" -s "$subject" "$recipient_list" >/dev/null 2>&1; then
            return 0
        fi
    elif command -v mail >/dev/null 2>&1; then
        if echo -e "$body" | mail "${mailx_opts[@]}" -s "$subject" "$recipient_list" >/dev/null 2>&1; then
            return 0
        fi
    elif command -v sendmail >/dev/null 2>&1; then
        if (
            echo "Subject: $subject"
            echo "To: $recipient_list"
            echo ""
            echo -e "$body"
            if [ -n "$attachment_path" ] && [ -f "$attachment_path" ]; then
                echo "Note: sendmail does not natively support attachments. File saved at: $attachment_path"
            fi
        ) | sendmail -t >/dev/null 2>&1; then
            return 0
        fi
    fi
    
    echo "WARNING: Could not send email (no MTA configured or mail command failed)." >&2
    return 1
}

usage() {
    echo "Usage: $0 [--tag TAG | --commit HASH] [--cron] [--test]"
    echo ""
    echo "With --tag or --commit, build and benchmark the specified Go revision."
    echo "With --cron, enforce the last Mon/Tue/Wed scheduling checks."
    echo "With --test, run a fast test benchmark on a single package (fmt) with 1 iteration to verify mailing and pipeline."
    echo "Without options, clone/update and benchmark the current master branch on-demand."
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
    
    # 1. CPU Pinning Check (skip if single core/IFL)
    local num_cpus
    num_cpus=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    if [ "$num_cpus" -eq 1 ]; then
        log_content+="1. CPU Pinning Check: SKIPPED (Single core/IFL/logical CPU detected)\n"
        CPU_PIN_CORE=""
    else
        log_content+="1. CPU Pinning Check: SUCCESS (Pinning workloads to core: $CPU_PIN_CORE)\n"
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
    for cmd in git make gcc taskset; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_pkgs+=("$cmd")
        fi
    done
    
    if [ ${#missing_pkgs[@]} -eq 0 ]; then
        log_content+="3. Required Packages Check: SUCCESS (All required packages are already installed)\n"
    else
        log_content+="3. Required Packages Check: PENDING (Missing: ${missing_pkgs[*]}). Attempting installation...\n"
        if [ "$has_sudo" = false ] && [ "$(id -u)" -ne 0 ]; then
            log_content+="3. Required Packages Check: FAILED (Missing: ${missing_pkgs[*]}; cannot install without root/sudo)\n"
            status=1
        else
            # Resolve taskset to util-linux in Ubuntu, others match command name
            local install_list=()
            for item in "${missing_pkgs[@]}"; do
                if [ "$item" = "taskset" ]; then
                    install_list+=("util-linux")
                else
                    install_list+=("$item")
                fi
            done
            
            local apt_success=true
            if [ "$(id -u)" -eq 0 ]; then
                apt-get update -y && apt-get install -y "${install_list[@]}" >> "$LOG_FILE" 2>&1 || apt_success=false
            else
                # shellcheck disable=SC2024
                sudo apt-get update -y && sudo apt-get install -y "${install_list[@]}" >> "$LOG_FILE" 2>&1 || apt_success=false
            fi
            
            if [ "$apt_success" = true ]; then
                log_content+="3. Required Packages Check: SUCCESS (Successfully installed: ${missing_pkgs[*]})\n"
            else
                log_content+="3. Required Packages Check: FAILED (Failed to install: ${missing_pkgs[*]})\n"
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
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        if [ -n "${DEV_EMAILS:-}" ]; then
            local subject=""
            if [ "${TEST_MODE:-false}" = true ]; then
                subject+="[TEST MODE] "
            fi
            subject+="Go Benchmark Pre-requisites: "
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

# Logger helper for persistent history of each run
log_run_history() {
    local date_str commit_hash status msg
    date_str=$(date '+%Y-%m-%d %H:%M:%S')
    commit_hash="${1:-unknown}"
    status="$2" # SUCCESS or FAILED
    msg="$3"
    echo "$date_str [$commit_hash] [$status] $msg" >> "$RUN_HISTORY_FILE"
}

# Add benchmark script to current user's crontab automatically if not root and not present
ensure_cron_entry() {
    if [ "$(id -u)" -eq 0 ]; then
        echo "Running as root user. Skipping crontab automatic addition."
        return 0
    fi
    
    local script_path="$SCRIPT_DIR/daily_go_benchmark_pipeline.sh"
    if [ ! -f "$script_path" ]; then
        script_path="$SCRIPT_SOURCE_DIR/daily_go_benchmark_pipeline.sh"
    fi
    
    local cron_cmd="0 2 22-31 * * $script_path --cron"
    local existing
    existing=$(crontab -l 2>/dev/null || true)
    
    if printf '%s\n' "$existing" | grep -Fqx "$cron_cmd"; then
        return 0
    fi
    
    echo "Adding benchmark script to crontab..."
    { printf '%s\n' "$existing"; printf '%s\n' "$cron_cmd"; } | crontab -
    echo "Crontab entry added successfully."
}

# Determine the last Mon, Tue, Wed of the current month
get_last_mon_tue_wed() {
    local y m last_day
    y=$(date +%Y)
    m=$(date +%m)
    
    if date -d "today" >/dev/null 2>&1; then
        last_day=$(date -d "$(date +%Y-%m-01) +1 month -1 day" +%d)
    else
        last_day=$(date -v1d -v+1m -v-1d +%d)
    fi
    
    LAST_MON=""
    LAST_TUE=""
    LAST_WED=""
    
    for ((d=last_day; d>=last_day-6; d--)); do
        local dow
        if date -d "today" >/dev/null 2>&1; then
            dow=$(date -d "$y-$m-$d" +%u 2>/dev/null || true)
        else
            dow=$(date -j -f "%Y-%m-%d" "$y-$m-$d" +%u 2>/dev/null || true)
        fi
        
        if [ "$dow" = "1" ] && [ -z "$LAST_MON" ]; then
            LAST_MON=$d
        elif [ "$dow" = "2" ] && [ -z "$LAST_TUE" ]; then
            LAST_TUE=$d
        elif [ "$dow" = "3" ] && [ -z "$LAST_WED" ]; then
            LAST_WED=$d
        fi
    done
}

# Cron scheduled run checks (earliest of last Mon, Tue, Wed precedence)
should_run_cron_today() {
    get_last_mon_tue_wed
    
    local today_day today_dow current_month
    today_day=$(date +%e | tr -d '[:space:]')
    today_dow=$(date +%u) # 1=Mon, 2=Tue, 3=Wed
    current_month=$(date +%Y-%m)
    
    local is_target_day=false
    if [ "$today_dow" = "1" ] && [ "$today_day" = "$LAST_MON" ]; then
        is_target_day=true
    elif [ "$today_dow" = "2" ] && [ "$today_day" = "$LAST_TUE" ]; then
        is_target_day=true
    elif [ "$today_dow" = "3" ] && [ "$today_day" = "$LAST_WED" ]; then
        is_target_day=true
    fi
    
    if [ "$is_target_day" = false ]; then
        echo "Today is not the last Monday, Tuesday, or Wednesday of the month. Skipping scheduled run."
        return 1
    fi
    
    # Check if a successful run already happened this month
    local has_run_this_month=false
    if [ -f "$RUN_HISTORY_FILE" ]; then
        if grep -q "^$current_month-.*SUCCESS" "$RUN_HISTORY_FILE"; then
            has_run_this_month=true
        fi
    fi
    
    if [ "$has_run_this_month" = true ]; then
        echo "Benchmark has already run successfully this month. Skipping run."
        return 1
    fi
    
    # Precedence logic: Mon -> Tue -> Wed
    if [ "$today_dow" = "1" ]; then
        echo "Today is last Monday of the month. Proceeding with run."
        return 0
    fi
    if [ "$today_dow" = "2" ]; then
        echo "Today is last Tuesday of the month, and no successful run recorded yet. Proceeding with run."
        return 0
    fi
    if [ "$today_dow" = "3" ]; then
        echo "Today is last Wednesday of the month, and no successful run recorded yet. Proceeding with run."
        return 0
    fi
    
    return 1
}

# Copy the benchmark results archive to remote hosts
copy_results_to_hosts() {
    local tar_path="$1"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "WARNING: Configuration file $CONFIG_FILE is missing. Skipping results SCP copy."
        return 0
    fi
    
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    
    if [ -z "${SCP_HOSTS:-}" ] || [ -z "${SCP_HOSTS//[[:space:]]/}" ]; then
        echo "WARNING: SCP hosts configuration (SCP_HOSTS) is missing. Skipping copy."
        if [ -n "${DEV_EMAILS:-}" ]; then
            local subject=""
            if [ "${TEST_MODE:-false}" = true ]; then
                subject+="[TEST MODE] "
            fi
            subject+="Go Benchmark: SCP Hosts Missing"
            send_email "$subject" "The benchmark completed successfully, but SCP_HOSTS is missing from $CONFIG_FILE. Skipping copy." "$DEV_EMAILS"
        fi
        return 0
    fi
    
    local scp_failed=false
    local failed_hosts=()
    local hosts_list
    hosts_list=$(echo "$SCP_HOSTS" | tr ',' ' ')
    
    for host in $hosts_list; do
        echo "SCP'ing results tarball $tar_path to $host..."
        local scp_err
        if scp_err=$(scp -B -o ConnectTimeout=15 "$tar_path" "$host" 2>&1 >/dev/null); then
            echo "Successfully copied to $host"
        else
            echo "FAILED to copy to $host"
            echo "scp error: $scp_err"
            scp_failed=true
            failed_hosts+=("$host")
        fi
    done
    
    if [ "$scp_failed" = true ]; then
        local failed_hosts_str="${failed_hosts[*]}"
        echo "ERROR: Failed to copy results to hosts: $failed_hosts_str"
        if [ -n "${DEV_EMAILS:-}" ]; then
            local subject=""
            if [ "${TEST_MODE:-false}" = true ]; then
                subject+="[TEST MODE] "
            fi
            subject+="Go Benchmark: SCP Copy Failure"
            send_email "$subject" "The benchmark completed, but copying the results tarball ($tar_path) failed for: $failed_hosts_str." "$DEV_EMAILS"
        fi
        return 1
    fi
    
    return 0
}

# Parse the explicitly requested revision, if any.
parse_args() {
    REVISION_MODE=master
    REVISION=
    CRON_MODE=false
    TEST_MODE=false
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --tag|--commit)
                [ "$#" -ge 2 ] || { echo "$1 requires a value." >&2; usage >&2; exit 2; }
                [ -z "$REVISION" ] || { echo "Specify only one of --tag or --commit." >&2; exit 2; }
                REVISION_MODE=$1
                REVISION=$2
                shift 2
                ;;
            --cron)
                CRON_MODE=true
                shift
                ;;
            --test)
                TEST_MODE=true
                shift
                ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        esac
    done
}

parse_args "$@"

# If running via cron, check if today is the correct day
if [ "$CRON_MODE" = true ]; then
    if ! should_run_cron_today; then
        exit 0
    fi
fi

# Auto-ensure cron entry for future schedules (not in test mode)
if [ "$TEST_MODE" != true ]; then
    ensure_cron_entry
fi

# Initialize Log File with Timestamp early
mkdir -p "$BASE_DIR" "$RESULTS_DIR" "$LOG_DIR" "$SCRIPT_DIR"
LOG_FILE="$LOG_DIR/daily_pipeline_${TIMESTAMP}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Metadata block appended to emails (empty if the run failed before metadata was written)
metadata_for_email() {
    if [ -n "${METADATA_FILE:-}" ] && [ -f "$METADATA_FILE" ]; then
        printf '\n\nMetadata:\n%s' "$(cat "$METADATA_FILE")"
    fi
}

# Error handler for unexpected execution failures
handle_error() {
    local exit_code=$?
    echo "ERROR: Pipeline failed on line $1 with exit code $exit_code" >&2
    log_run_history "${CURRENT_COMMIT:-${REVISION:-master}}" "FAILED" "Execution failed on line $1 with exit code $exit_code"
    
    # Send email on failure
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        if [ -n "${DEV_EMAILS:-}" ]; then
            local subject=""
            if [ "${TEST_MODE:-false}" = true ]; then
                subject+="[TEST MODE] "
            fi
            subject+="Go Benchmark: Benchmark Execution FAILED"
            send_email "$subject" "The benchmark execution has FAILED.\n\nCheck the log file at $LOG_FILE for details.$(metadata_for_email)" "${DEV_EMAILS:-}"
        fi
    fi
}
trap 'handle_error $LINENO' ERR

# Run prerequisites check
if ! check_prerequisites; then
    echo "ERROR: Pre-requisites check failed. Exiting." >&2
    log_run_history "${REVISION:-master}" "FAILED" "Prerequisite checks failed."
    exit 1
fi

# Set up files in $SCRIPT_DIR
cp "$SCRIPT_SOURCE_DIR/daily_go_benchmark_pipeline.sh" "$SCRIPT_DIR/"
if [ -f "$SCRIPT_SOURCE_DIR/.benchmark_config" ]; then
    cp "$SCRIPT_SOURCE_DIR/.benchmark_config" "$SCRIPT_DIR/"
fi
chmod 0755 "$SCRIPT_DIR/daily_go_benchmark_pipeline.sh"

run_suffix="${REVISION:-master}"
run_suffix=$(echo "$run_suffix" | tr '/' '_')
TODAY_DIR="$RESULTS_DIR/${TODAY}_${run_suffix}"
mkdir -p "$TODAY_DIR"
START_TIME=$(date +%s)

if [ ! -d "$GO_DIR/.git" ]; then
    clone_attempt=1
    while ! git clone https://go.googlesource.com/go "$GO_DIR" --recursive; do
        echo "Go repository clone attempt $clone_attempt failed."
        [ "$clone_attempt" -lt 2 ] || { echo "Unable to clone the Go repository after 2 attempts." >&2; false; }
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

# Metadata is written before the build/benchmark so failure emails can include it.
RAW_BENCH="$TODAY_DIR/benchmark_raw.txt"
BENCHSTAT_FILE="$TODAY_DIR/benchstat.txt"
METADATA_FILE="$TODAY_DIR/metadata.txt"
rm -f "$TODAY_DIR/.complete"
cat > "$METADATA_FILE" <<EOF
Date: $TODAY
Timestamp: $TIMESTAMP
Commit: $CURRENT_COMMIT
Mode: $REVISION_MODE
Test Mode: ${TEST_MODE:-false}
Raw Benchmark File: $RAW_BENCH
Benchstat File: $BENCHSTAT_FILE
EOF

# NOTE: 'false' (rather than 'exit 1') is used below so the ERR trap sends the failure email.
cd "$GO_DIR/src"
if ! ./make.bash; then
    echo "Go toolchain build failed." >&2
    false
fi

bench_target="./..."
bench_count=6
if [ "${TEST_MODE:-false}" = true ]; then
    bench_target="fmt"
    bench_count=1
    echo "[TEST MODE] Running on single package '$bench_target' with 1 iteration."
fi

if [ -n "$CPU_PIN_CORE" ]; then
    echo "Running pinned to logical CPU core: $CPU_PIN_CORE"
    if ! taskset -c "$CPU_PIN_CORE" "$GO_DIR/bin/go" test "$bench_target" -run=^$ -bench=. -benchmem -test.count="$bench_count" > "$RAW_BENCH"; then
        echo "Benchmark execution failed." >&2
        false
    fi
else
    echo "Running unpinned (single CPU)..."
    if ! "$GO_DIR/bin/go" test "$bench_target" -run=^$ -bench=. -benchmem -test.count="$bench_count" > "$RAW_BENCH"; then
        echo "Benchmark execution failed." >&2
        false
    fi
fi

# Marks this run's raw results as complete so later runs can use them as a baseline.
touch "$TODAY_DIR/.complete"

# Previous baseline: the most recently finished run (by metadata.txt mtime) that
# completed successfully and has the same test-mode setting as this run.
CURRENT_RAW="$RAW_BENCH"
PREV_RAW=""
for meta in $(ls -1t "$RESULTS_DIR"/*/metadata.txt 2>/dev/null || true); do
    prev_dir=$(dirname "$meta")
    [ -f "$prev_dir/.complete" ] && [ -f "$prev_dir/benchmark_raw.txt" ] || continue
    [ "$prev_dir/benchmark_raw.txt" != "$CURRENT_RAW" ] || continue
    if grep -qx 'Test Mode: true' "$meta"; then prev_test=true; else prev_test=false; fi
    [ "$prev_test" = "${TEST_MODE:-false}" ] || continue
    PREV_RAW="$prev_dir/benchmark_raw.txt"
    break
done
echo "Previous benchmark baseline: ${PREV_RAW:-none}"
HAS_PREVIOUS_RESULTS=false
if [ -n "$PREV_RAW" ]; then
    HAS_PREVIOUS_RESULTS=true
fi

if [ "$HAS_PREVIOUS_RESULTS" = true ]; then
    if ! command -v benchstat >/dev/null 2>&1; then
        echo "Installing benchstat..."
        go install golang.org/x/perf/cmd/benchstat@latest || true
    fi
    GOPATH_BIN="$(go env GOPATH 2>/dev/null || echo "$HOME/go")/bin"
    export PATH="$GOPATH_BIN:$PATH"
    if command -v benchstat >/dev/null 2>&1; then
        benchstat -format=text "$PREV_RAW" "$RAW_BENCH" > "$BENCHSTAT_FILE"
    else
        echo "WARNING: benchstat is not available; raw comparison skipped."
    fi
else
    echo "No previous benchmark result found; comparison reports were skipped."
fi

# Create TAR package
tar_name="benchmark_results_${TODAY}_${run_suffix}.tar.gz"
tar_file="${BASE_DIR}/results/${tar_name}"
echo "Creating results TAR package $tar_file..."
tar -czf "$tar_file" -C "$RESULTS_DIR" "${TODAY}_${run_suffix}" -C "$LOG_DIR" "$(basename "$LOG_FILE")"

# SCP to remote hosts
copy_results_to_hosts "$tar_file"

END_TIME=$(date +%s)
echo "Benchmark pipeline completed in $((END_TIME - START_TIME)) seconds."
echo "Metadata: $METADATA_FILE"
log_run_history "${CURRENT_COMMIT:-master}" "SUCCESS" "Benchmark completed successfully in $((END_TIME - START_TIME)) seconds."

# Send success email to devs with results attachment
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    if [ -n "${DEV_EMAILS:-}" ]; then
        subject=""
        if [ "${TEST_MODE:-false}" = true ]; then
            subject+="[TEST MODE] "
        fi
        subject+="Go Benchmark Execution SUCCESS"
        body="The benchmark execution completed successfully in $((END_TIME - START_TIME)) seconds.$(metadata_for_email)"
        send_email "$subject" "$body" "$DEV_EMAILS" "$tar_file"
    fi
fi
