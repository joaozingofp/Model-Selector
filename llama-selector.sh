#!/usr/bin/env bash
# llama-select.sh — ncurses-based model selector for launching llama.cpp server
# Single-command deployment: chmod +x llama-select.sh && ./llama-select.sh
# Optional curl install: curl -sSL https://example.com/llama-select.sh | bash

set -euo pipefail

# ─── Defaults (env vars override these) ───────────────────────────────
MODEL_DIR="${MODEL_DIR:-$HOME/models}"
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-llama-server}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"
CTX="${CTX:-4096}"
THREADS="${THREADS:-$(nproc 2>/dev/null || echo 1)}"
NGL="${NGL:-999}"

# Extended params (empty = not used)
BATCH_SIZE=""       # --batch-size
MICRO_BATCH=""      # --mlock micro-batch size
KV_CACHE_TYPE=""    # --kv-cache-type: f16, q8_0, q4_0
EXPERTS_NGL=""      # --expert-n-gpu-layers

PROFILES_DIR="${PROFILES_DIR:-$HOME/.llama-select/profiles/}"

PROFILE=""          # selected profile name (basename without .sh)
PROFILE_PATH=""     # full path to the selected profile file

# Track which CLI args were explicitly set (for override after profile load)
declare -A _CLI_OVERRIDES=()

# ─── Usage ───────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -m, --model PATH           Skip TUI; use this model file directly.
  -d, --model-dir DIR        Model directory (default: $HOME/models).
  -s, --server-bin BIN       llama-server binary name/path (default: llama-server).
  -P, --profile NAME         Load profile params by name (e.g. "fast").
  -D, --profiles-dir DIR     Profile directory (default: ~/.llama-select/profiles/).
  -H, --host HOST            Bind host (default: 0.0.0.0).
  -p, --port PORT            Port (default: 8080).
  -c, --ctx N                Context size in tokens (default: 4096).
  -t, --threads N            CPU threads (default: nproc).
  -n, --ngl N                GPU layers to offload (default: 999).
  -B, --batch-size N         Batch size (default: unset = llama.cpp default).
  -M, --micro-batch N        Micro-batch size (default: unset).
  -K, --kv-cache-type TYPE   KV cache quantization: f16, q8_0, q4_0 (default: unset).
  -E, --experts-ngl N        MoE expert GPU layers (default: unset).
  -h, --help                 Show this help.

Profiles are .sh files that export HOST, PORT, CTX, THREADS, NGL and any of:
  BATCH_SIZE, MICRO_BATCH, KV_CACHE_TYPE, EXPERTS_NGL.

Environment variables can override all options above.

Example profile file ($PROFILES_DIR/my-profile.sh):
    #!/usr/bin/env bash
    # Fast inference - 8 threads, low context
    HOST="0.0.0.0"
    PORT="3000"
    CTX="8192"
    THREADS="8"
    NGL="35"
    BATCH_SIZE="512"
    MICRO_BATCH="64"
    KV_CACHE_TYPE="q8_0"
    EXPERTS_NGL="0"
EOF
}

# ─── Argument parsing ────────────────────────────────────────────────
MODEL_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--model)          MODEL_PATH="$2"; shift 2 ;;
        -d|--model-dir)      MODEL_DIR="$2"; shift 2 ;;
        -s|--server-bin)     LLAMA_SERVER_BIN="$2"; shift 2 ;;
        -P|--profile)        PROFILE="$2"; shift 2 ;;
        -D|--profiles-dir)   PROFILES_DIR="$2"; shift 2 ;;
        -H|--host)           _CLI_OVERRIDES[HOST]="$2"; shift 2 ;;
        -p|--port)           _CLI_OVERRIDES[PORT]="$2"; shift 2 ;;
        -c|--ctx)            _CLI_OVERRIDES[CTX]="$2"; shift 2 ;;
        -t|--threads)        _CLI_OVERRIDES[THREADS]="$2"; shift 2 ;;
        -n|--ngl)            _CLI_OVERRIDES[NGL]="$2"; shift 2 ;;
        -B|--batch-size)     _CLI_OVERRIDES[BATCH_SIZE]="$2"; shift 2 ;;
        -M|--micro-batch)    _CLI_OVERRIDES[MICRO_BATCH]="$2"; shift 2 ;;
        -K|--kv-cache-type)  _CLI_OVERRIDES[KV_CACHE_TYPE]="$2"; shift 2 ;;
        -E|--experts-ngl)    _CLI_OVERRIDES[EXPERTS_NGL]="$2"; shift 2 ;;
        -h|--help)           usage; exit 0 ;;
        *)                   echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

# ─── Auto-install dialog if missing ────────────────────────────────────
ensure_dialog() {
    if command -v dialog &>/dev/null; then
        return 0
    fi

    echo "dialog is not installed. Attempting to install..." >&2

    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y dialog
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y dialog || sudo yum install -y dialog
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm dialog
    elif command -v brew &>/dev/null; then
        brew install dialog
    else
        echo "Error: No supported package manager found. Please install 'dialog' manually." >&2
        exit 1
    fi

    if ! command -v dialog &>/dev/null; then
        echo "Error: Failed to install dialog." >&2
        exit 1
    fi
}

# ─── Detect llama-server binary ────────────────────────────────────────
detect_server_bin() {
    local bin="$1"

    if command -v "$bin" &>/dev/null; then
        echo "$bin"
        return 0
    fi

    if [[ -f "./$bin" && -x "./$bin" ]]; then
        echo "./$bin"
        return 0
    fi
    if [[ "$bin" == "llama-server" && -f "./server" && -x "./server" ]]; then
        echo "./server"
        return 0
    fi

    local resolved
    resolved="$(command -v "$bin" 2>/dev/null || true)"
    if [[ -n "$resolved" && -x "$resolved" ]]; then
        echo "$resolved"
        return 0
    fi

    echo "Error: Cannot find '$LLAMA_SERVER_BIN' in PATH or current directory." >&2
    echo "Place the binary in PATH, pass --server-bin <path>, or put it in the current directory as 'llama-server' or 'server'." >&2
    exit 1
}

# ─── Discover models ──────────────────────────────────────────────────
discover_models() {
    local dir="$1"

    if [[ ! -d "$dir" ]]; then
        echo "Error: Model directory '$dir' does not exist." >&2
        exit 1
    fi

    find "$dir" -maxdepth 3 \( -name '*.gguf' -o -name '*.bin' \) -print0 | sort -z
}

# ─── Discover profiles ────────────────────────────────────────────────
discover_profiles() {
    local dir="$1"

    if [[ ! -d "$dir" ]]; then
        return 0   # no profiles dir yet is fine
    fi

    find "$dir" -maxdepth 1 -name '*.sh' -type f -print0 | sort -z
}

# ─── Load a profile ───────────────────────────────────────────────────
load_profile() {
    local profile_file="$1"

    if [[ ! -f "$profile_file" ]]; then
        echo "Error: Profile file '$profile_file' not found." >&2
        exit 1
    fi

    # Source the profile — it exports HOST, PORT, CTX, THREADS, NGL and optionally:
    # BATCH_SIZE, MICRO_BATCH, KV_CACHE_TYPE, EXPERTS_NGL
    local _saved_host="$HOST" _saved_port="$PORT" _saved_ctx="$CTX"
    local _saved_threads="$THREADS" _saved_ngl="$NGL"
    local _saved_batch="$BATCH_SIZE" _saved_micro="$MICRO_BATCH"
    local _saved_kvtype="$KV_CACHE_TYPE" _saved_experts="$EXPERTS_NGL"

    # shellcheck disable=SC1090
    source "$profile_file" 2>/dev/null || {
        echo "Error: Failed to source profile '$profile_file'." >&2
        exit 1
    }
}

# ─── Apply CLI overrides on top of profile values ──────────────────────
apply_cli_overrides() {
    if [[ ${#_CLI_OVERRIDES[@]} -eq 0 ]]; then
        return
    fi

    for key in "${!_CLI_OVERRIDES[@]}"; do
        case "$key" in
            HOST)          HOST="${_CLI_OVERRIDES[$key]}" ;;
            PORT)          PORT="${_CLI_OVERRIDES[$key]}" ;;
            CTX)           CTX="${_CLI_OVERRIDES[$key]}" ;;
            THREADS)       THREADS="${_CLI_OVERRIDES[$key]}" ;;
            NGL)           NGL="${_CLI_OVERRIDES[$key]}" ;;
            BATCH_SIZE)    BATCH_SIZE="${_CLI_OVERRIDES[$key]}" ;;
            MICRO_BATCH)   MICRO_BATCH="${_CLI_OVERRIDES[$key]}" ;;
            KV_CACHE_TYPE) KV_CACHE_TYPE="${_CLI_OVERRIDES[$key]}" ;;
            EXPERTS_NGL)   EXPERTS_NGL="${_CLI_OVERRIDES[$key]}" ;;
        esac
    done
}

# ─── Save a profile interactively ─────────────────────────────────────
save_profile_interactive() {
    local model_path="$1"

    # Step 1: Ask for profile name
    local pname rc tmp desc target

    tmp="$(mktemp)" || {
        echo "Internal error: failed to create temp file" >&2
        return 1
    }

    dialog --inputbox "Profile name (no spaces, no extension):" 8 40 "" 2> "$tmp" >/dev/tty
    rc=$?
    if [[ $rc -ne 0 ]]; then
        rm -f "$tmp"
        echo "Save cancelled." >&2
        return 1
    fi
    pname="$(<"$tmp")"
    rm -f "$tmp"

    # Validate name
    if [[ -z "$pname" ]]; then
        dialog --msgbox "Profile name cannot be empty." 6 40
        return 1
    fi
    if [[ "$pname" == *"."* || "$pname" == *" "* || "$pname" == *$'\n'* ]]; then
        dialog --msgbox "Invalid profile name. Use letters, numbers, and underscores only." 8 50
        return 1
    fi

    # Check if file already exists
    target="$PROFILES_DIR/${pname}.sh"
    if [[ -f "$target" ]]; then
        dialog --msgbox "A profile named '$pname' already exists at $target. Delete it first or choose another name." 8 60
        return 1
    fi

    # Step 2: Ask for description (first comment line)
    tmp="$(mktemp)" || {
        echo "Internal error: failed to create temp file" >&2
        return 1
    }
    dialog --inputbox "Profile description (shown in menu, optional):" 8 50 "" 2> "$tmp" >/dev/tty
    rc=$?
    if [[ $rc -ne 0 ]]; then
        rm -f "$tmp"
        echo "Save cancelled." >&2
        return 1
    fi
    desc="$(<"$tmp")"
    rm -f "$tmp"

    # Step 3: Write the profile file
    mkdir -p "$PROFILES_DIR"

    cat > "$target" <<PROFEOF
#!/usr/bin/env bash
# ${desc:-$(basename "$model_path")} - Profile generated $(date '+%Y-%m-%d %H:%M')
HOST="$HOST"
PORT="$PORT"
CTX="$CTX"
THREADS="$THREADS"
NGL="$NGL"
PROFEOF

    # Only add extended params if they have values
    if [[ -n "$BATCH_SIZE" && "$BATCH_SIZE" != "0" ]]; then
        echo "BATCH_SIZE=\"$BATCH_SIZE\"" >> "$target"
    fi
    if [[ -n "$MICRO_BATCH" && "$MICRO_BATCH" != "0" ]]; then
        echo "MICRO_BATCH=\"$MICRO_BATCH\"" >> "$target"
    fi
    if [[ -n "$KV_CACHE_TYPE" && "$KV_CACHE_TYPE" != "" ]]; then
        echo "KV_CACHE_TYPE=\"$KV_CACHE_TYPE\"" >> "$target"
    fi
    if [[ -n "$EXPERTS_NGL" && "$EXPERTS_NGL" != "0" ]]; then
        echo "EXPERTS_NGL=\"$EXPERTS_NGL\"" >> "$target"
    fi

    chmod +x "$target"
    PROFILE="$pname"
    PROFILE_PATH="$target"
    echo "Saved profile: $pname → $target" >&2
}

# ─── TUI: model selection menu ────────────────────────────────────────
select_model_menu() {
    local -a items=()

    while IFS= read -r -d '' fpath; do
        local base
        base="$(basename "$fpath")"
        items+=("$base" "$fpath")
    done < <(discover_models "$MODEL_DIR")

    if [[ ${#items[@]} -eq 0 ]]; then
        dialog --msgbox "No .gguf or .bin models found in '$MODEL_DIR'.\nAdd models to this directory." 10 50
        exit 0
    fi

    local choice
    choice=$(dialog --menu "Select a model:" 16 50 8 "${items[@]}" 2>&1 >/dev/tty) || {
        echo "Model selection cancelled." >&2
        exit 0
    }

    while IFS= read -r -d '' fpath; do
        local base
        base="$(basename "$fpath")"
        if [[ "$base" == "$choice" ]]; then
            echo "$fpath"
            return 0
        fi
    done < <(discover_models "$MODEL_DIR")

    echo "Error: Selected model '$choice' not found." >&2
    exit 1
}

# ─── TUI: profile selection menu ──────────────────────────────────────
select_profile_menu() {
    local -a items=()

    while IFS= read -r -d '' pfile; do
        local pname desc=""
        pname="$(basename "$pfile" .sh)"
        if [[ -f "$pfile" ]]; then
            desc="$(head -1 "$pfile" 2>/dev/null | sed 's/^#[[:space:]]*//')" || true
        fi
        items+=("$pname" "${desc:-No description}")
    done < <(discover_profiles "$PROFILES_DIR")

    # Always offer "Custom" to edit params manually without a profile
    items+=("Custom" "Edit parameters manually (no profile)")

    local choice
    choice=$(dialog --menu "Select a profile:" 14 50 6 "${items[@]}" 2>&1 >/dev/tty) || {
        echo "Profile selection cancelled." >&2
        exit 0
    }

    if [[ "$choice" == "Custom" ]]; then
        PROFILE=""
        PROFILE_PATH=""
        return 0
    fi

    # Find and load the selected profile
    while IFS= read -r -d '' pfile; do
        local pname
        pname="$(basename "$pfile" .sh)"
        if [[ "$pname" == "$choice" ]]; then
            PROFILE="$pname"
            PROFILE_PATH="$pfile"
            load_profile "$PROFILE_PATH"
            echo "Loaded profile: $PROFILE" >&2
            return 0
        fi
    done < <(discover_profiles "$PROFILES_DIR")

    echo "Error: Selected profile '$choice' not found." >&2
    exit 1
}

# ─── TUI: parameter form (extended) ───────────────────────────────────
edit_params_form() {
    local host="$1" port="$2" ctx="$3" threads="$4" ngl="$5"
    local batch="$6" micro="$7" kvtype="$8" experts="$9"

    # Run dialog writing output to a temp file, capture rc immediately.
    local tmp output rc=0 vals=()
    tmp="$(mktemp)" || {
        echo "Internal error: failed to create temp file" >&2
        exit 1
    }

    dialog --form "Configure server parameters:" 22 60 9 \
        "Host:"         1 1 "$host"       1 8 20 0 \
        "Port:"         2 1 "$port"       2 8 10 0 \
        "Context:"      3 1 "$ctx"        3 10 8 0 \
        "Threads:"      4 1 "$threads"    4 10 6 0 \
        "GPU Layers:"   5 1 "$ngl"        5 14 6 0 \
        "Batch Size:"   6 1 "${batch:-}"  6 13 8 0 \
        "Micro-batch:"  7 1 "${micro:-}"  7 14 8 0 \
        "KV Cache Type:"8 1 "${kvtype:-}" 8 15 10 0 \
        "Experts NGL:"  9 1 "${experts:-}" 9 16 6 0 \
        2> "$tmp" >/dev/tty
    rc=$?

    if [[ $rc -ne 0 ]]; then
        rm -f "$tmp"
        echo "Parameter edit cancelled." >&2
        exit 0
    fi

    output="$(<"$tmp")"
    rm -f "$tmp"

    # dialog --form outputs each field value on its own line (newline-separated).
    # Empty fields become empty lines. Parse into array.
    while IFS= read -r line; do
        [[ -n "$line" || ${#vals[@]} -lt 9 ]] && vals+=("$line")
    done <<< "$output"

    if [[ ${#vals[@]} -ge 9 ]]; then
        HOST="${vals[0]:-$HOST}"
        PORT="${vals[1]:-$PORT}"
        CTX="${vals[2]:-$CTX}"
        THREADS="${vals[3]:-$THREADS}"
        NGL="${vals[4]:-$NGL}"
        BATCH_SIZE="${vals[5]:-}"
        MICRO_BATCH="${vals[6]:-}"
        KV_CACHE_TYPE="${vals[7]:-}"
        EXPERTS_NGL="${vals[8]:-}"
    fi
}

# ─── TUI: confirmation summary ────────────────────────────────────────
confirm_launch() {
    local model_name="$1"
    local profile_label="None"
    if [[ -n "$PROFILE" ]]; then
        profile_label="$PROFILE (from $PROFILES_DIR)"
    fi

    local extended=""
    [[ -n "$BATCH_SIZE" ]] && extended+="Batch: $BATCH_SIZE\n"
    [[ -n "$MICRO_BATCH" ]] && extended+="Micro-batch: $MICRO_BATCH\n"
    [[ -n "$KV_CACHE_TYPE" ]] && extended+="KV Cache Type: $KV_CACHE_TYPE\n"
    [[ -n "$EXPERTS_NGL" ]] && extended+="Experts NGL: $EXPERTS_NGL\n"

    local summary="Model: $model_name
Profile: $profile_label
Host: $HOST
Port: $PORT
Context: $CTX
Threads: $THREADS
GPU Layers: $NGL
${extended:-}"

    local rc=0
    dialog --yesno "$summary" 14 40 2>&1 >/dev/tty; rc=$? || true
    if [[ $rc -ne 0 ]]; then
        echo "Launch cancelled." >&2
        exit 0
    fi
}

# ─── Build command array (only include flags that have values) ─────────
build_command() {
    local model_path="$1"

    local -a cmd=("$LLAMA_SERVER_BIN" \
        --model "$model_path" \
        --host "$HOST" \
        --port "$PORT" \
        --ctx-size "$CTX" \
        --threads "$THREADS" \
        --n-gpu-layers "$NGL")

    # Only add extended flags if they have non-empty, non-zero values
    if [[ -n "$BATCH_SIZE" && "$BATCH_SIZE" != "0" ]]; then
        cmd+=(-b "$BATCH_SIZE")
    fi
    if [[ -n "$MICRO_BATCH" && "$MICRO_BATCH" != "0" ]]; then
        cmd+=(--mlock "$MICRO_BATCH")  # llama.cpp uses --mlock for micro-batch
    fi
    if [[ -n "$KV_CACHE_TYPE" ]]; then
        cmd+=(--kv-cache-type "$KV_CACHE_TYPE")
    fi
    if [[ -n "$EXPERTS_NGL" && "$EXPERTS_NGL" != "0" ]]; then
        cmd+=(--expert-n-gpu-layers "$EXPERTS_NGL")
    fi

    printf '%s\0' "${cmd[@]}"
}

# ─── Validate numeric params ──────────────────────────────────────────
validate_numeric() {
    local varname="$1" value="$2" label="$3" is_positive="${4:-true}"

    if [[ -z "$value" ]]; then
        return 0   # empty = not used, that's fine
    fi

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "Error: $label must be a non-negative integer (got '$value')." >&2
        exit 1
    fi
    if [[ "$is_positive" == "true" && "$value" -eq 0 ]]; then
        # For positive-only params, 0 means unset → treat as empty
        case "$varname" in
            THREADS)   THREADS="" ;;
            CTX)       CTX="" ;;
            NGL)       NGL="" ;;
            BATCH_SIZE) BATCH_SIZE="" ;;
            MICRO_BATCH) MICRO_BATCH="" ;;
            EXPERTS_NGL) EXPERTS_NGL="" ;;
        esac
    fi
}

# ─── Main ───────────────────────────────────────────────────────────
main() {
    # Validate core params
    validate_numeric "THREADS" "$THREADS" "THREADS" "true"
    validate_numeric "CTX" "$CTX" "CTX" "true"
    validate_numeric "NGL" "$NGL" "NGL" "false"

    # Validate extended params
    validate_numeric "BATCH_SIZE" "$BATCH_SIZE" "BATCH_SIZE" "false"
    validate_numeric "MICRO_BATCH" "$MICRO_BATCH" "MICRO_BATCH" "false"
    if [[ -n "$KV_CACHE_TYPE" ]]; then
        case "$KV_CACHE_TYPE" in
            f16|q8_0|q4_0) ;;  # valid
            *) echo "Error: KV_CACHE_TYPE must be f16, q8_0, or q4_0 (got '$KV_CACHE_TYPE')." >&2; exit 1 ;;
        esac
    fi
    validate_numeric "EXPERTS_NGL" "$EXPERTS_NGL" "EXPERTS_NGL" "false"

    # Resolve server binary
    LLAMA_SERVER_BIN="$(detect_server_bin "$LLAMA_SERVER_BIN")"

    if [[ -n "$MODEL_PATH" ]]; then
        # Non-interactive / agentic mode with explicit model
        if [[ ! -f "$MODEL_PATH" ]]; then
            echo "Error: Model file '$MODEL_PATH' not found." >&2
            exit 1
        fi

        # If a profile was specified, load it and apply CLI overrides
        if [[ -n "$PROFILE" ]]; then
            PROFILE_PATH="$PROFILES_DIR/$PROFILE.sh"
            if [[ ! -f "$PROFILE_PATH" ]]; then
                echo "Error: Profile '$PROFILE' not found at $PROFILE_PATH" >&2
                exit 1
            fi
            load_profile "$PROFILE_PATH"
        fi

        apply_cli_overrides

        # Build and exec
        local -a cmd=()
        while IFS= read -r -d '' arg; do
            cmd+=("$arg")
        done < <(build_command "$MODEL_PATH")

        echo "Launching: ${cmd[*]}" >&2
        exec "${cmd[@]}"
    else
        # Check TTY for interactive mode
        if [[ ! -t 0 ]]; then
            echo "Error: No model specified and stdin is not a TTY." >&2
            echo "Run with --model <path> for non-interactive mode, or from an interactive terminal." >&2
            usage >&2
            exit 1
        fi

        # Interactive TUI flow — ensure dialog is available
        ensure_dialog

        # Step 1: Select model via menu
        MODEL_PATH="$(select_model_menu)"

        # Step 2: Select profile (or Custom)
        select_profile_menu

        # Apply CLI overrides on top of any loaded profile values
        apply_cli_overrides

        # Step 3: Edit parameters via extended form
        edit_params_form "$HOST" "$PORT" "$CTX" "$THREADS" "$NGL" \
                         "$BATCH_SIZE" "$MICRO_BATCH" "$KV_CACHE_TYPE" "$EXPERTS_NGL"

        # Step 4: Offer to save as new profile (only for Custom selections)
        if [[ -z "$PROFILE" ]]; then
            if dialog --yesno "Save current settings as a new profile?" 8 40 2>/dev/tty >/dev/tty; then
                save_profile_interactive "$MODEL_PATH" || true
            else
                echo "Profile save skipped." >&2
            fi
        fi

        # Step 5: Confirm before launch
        confirm_launch "$(basename "$MODEL_PATH")"

        # Build and exec
        local -a cmd=()
        while IFS= read -r -d '' arg; do
            cmd+=("$arg")
        done < <(build_command "$MODEL_PATH")

        echo "Launching: ${cmd[*]}" >&2
        exec "${cmd[@]}"
    fi
}

main "$@"
