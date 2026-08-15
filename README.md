# Model Selector

A TUI-powered model selector and launcher for llama.cpp. Pick from GGUF/BIN models, configure server parameters via menus, save reusable profiles, and fire up `llama-server` — all from the terminal.

## Features

- **Interactive TUI** — ncurses-style menus powered by `dialog`. Select models, edit parameters, confirm before launch.
- **Non-interactive / agentic mode** — skip the UI entirely with CLI flags (`--model`, `--profile`, etc.). Pipe it into scripts or automation.
- **Profile system** — save named configurations to `~/.llama-select/profiles/`. Each profile stores host, port, context size, threads, GPU layers, and optional extended params (batch size, micro-batch, KV cache type, expert NGL).
- **Auto-install** — detects and installs `dialog` if missing.
- **Binary detection** — finds `llama-server` or `server` in PATH or current directory automatically.

## Quick Start

```bash
chmod +x llama-selector.sh
./llama-selector.sh
```

Drop GGUF or BIN files into `$HOME/models/` (or any dir with `-d`) and launch.

## Usage

### Interactive mode (default)

Run from a TTY for the full menu-driven workflow: model selection → profile pick → parameter edit → confirm → launch.

### Non-interactive / agentic mode

```bash
# Direct model path, no UI
./llama-selector.sh -m ~/models/llama3-8b.Q4_K_M.gguf

# Load a profile + override port
./llama-selector.sh -P fast -p 3000

# All flags:
./llama-selector.sh \
    --model PATH           # Skip TUI, use this model directly
    --model-dir DIR        # Model directory (default: $HOME/models)
    --server-bin BIN       # llama-server binary name/path
    --profile NAME         # Load profile params by name
    --profiles-dir DIR     # Profile directory (default: ~/.llama-select/profiles/)
    --host HOST            # Bind host (default: 0.0.0.0)
    --port PORT            # Port (default: 8080)
    --ctx N                # Context size in tokens (default: 4096)
    --threads N            # CPU threads (default: nproc)
    --ngl N                # GPU layers to offload (default: 999)
    --batch-size N         # Batch size
    --micro-batch N        # Micro-batch size (--mlock)
    --kv-cache-type TYPE   # KV cache quantization: f16, q8_0, q4_0
    --experts-ngl N        # MoE expert GPU layers
```

### Profiles

Profiles are `.sh` files that export variables. Example (`~/.llama-select/profiles/fast.sh`):

```bash
#!/usr/bin/env bash
HOST="0.0.0.0"
PORT="3000"
CTX="8192"
THREADS="8"
NGL="35"
BATCH_SIZE="512"
MICRO_BATCH="64"
KV_CACHE_TYPE="q8_0"
EXPERTS_NGL="0"
```

Save a profile from the TUI after editing parameters, or create one manually.

### Environment overrides

Every CLI flag can be set via environment variable:

```bash
MODEL_DIR=~/my-models PORT=9000 ./llama-selector.sh
```

## Dependencies

- `dialog` — auto-installed if missing (apt/dnf/pacman/brew)
- `llama-server` or `server` binary in PATH, current dir, or specified with `--server-bin`

## License

MIT
