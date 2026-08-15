Create a Bash script named `llama-select.sh` that acts as an ncurses-based model selector for launching a llama.cpp server. The script must be production-ready, efficient, and deployable with a single command.

## Core requirements

1. **Technology stack**
   - Use only Bash (version 4+), `dialog` (the standard ncurses TUI toolkit), and common Unix utilities (`find`, `sort`, `mapfile`, etc.).
   - No Python, Node.js, or other external runtimes.
   - If `dialog` is not installed, the script must auto-install it using the appropriate package manager for the detected OS:
     - Debian/Ubuntu: `apt-get`
     - Fedora/RHEL: `dnf` or `yum`
     - Arch: `pacman`
     - macOS: `brew`
   - If no package manager is available, print a clear error and exit with code 1.

2. **llama-server binary detection**
   - Default binary name is `llama-server`, but allow override via `--server-bin` or env `LLAMA_SERVER_BIN`.
   - If the binary is not found in `PATH`, check for `./llama-server` and `./server` in the current directory.
   - If still not found, print error and exit.

3. **Model directory and discovery**
   - Default model directory is `$HOME/models`, overridable via `--model-dir` or env `MODEL_DIR`.
   - Scan recursively with `find` up to a maximum depth of 3 for files ending in `.gguf` or `.bin`.
   - Sort the list alphabetically.
   - Use `mapfile` to store paths in an array to handle spaces safely.

4. **Command-line options**
   - Support these flags (all optional, with sensible defaults):
     - `-m, --model PATH`       : skip model selection TUI and use this file directly.
     - `-d, --model-dir DIR`    : directory to scan (default `$HOME/models`).
     - `-s, --server-bin BIN`   : llama-server binary (default `llama-server`).
     - `-H, --host HOST`        : bind host (default `0.0.0.0`).
     - `-p, --port PORT`        : port (default `8080`).
     - `-c, --ctx N`            : context size (default `4096`).
     - `-t, --threads N`        : CPU threads (default `nproc`).
     - `-n, --ngl N`            : GPU layers (default `999`).
     - `-h, --help`             : show usage.
   - Environment variables can also set defaults: `MODEL_DIR`, `LLAMA_SERVER_BIN`, `HOST`, `PORT`, `CTX`, `THREADS`, `NGL`.

5. **Interactive TUI flow (only when running in a real terminal and no `--model` given)**
   - If models are found, present a `dialog --menu` listing models by their basename. Let user pick one.
   - After selection, show a `dialog --form` to edit host, port, context size, threads, and GPU layers, prefilled with current/default values.
   - Show a `dialog --yesno` confirmation summarizing all settings.
   - If any dialog is cancelled, exit gracefully with a message (exit code 0 for user cancellation, 1 for errors).
   - If no models are found, show a `dialog --msgbox` and exit.

6. **Non‑interactive / agentic mode**
   - If stdin is not a TTY (`[ ! -t 0 ]`) and `--model` is not provided, print a clear error and usage, exit 1.
   - If `--model` is provided, skip all dialogs and directly build the command.
   - With `--model` and other flags, the script should run without any TUI, suitable for automation.

7. **Execution**
   - Build the command as an array (to preserve spaces):
     ```bash
     cmd=("$LLAMA_SERVER_BIN" --model "$model_path" --host "$HOST" --port "$PORT" --ctx-size "$CTX" --threads "$THREADS" --n-gpu-layers "$NGL")

    Print the full command to stderr/stdout for logging.

    Use exec to replace the shell process with the server.

    Robustness & efficiency

        Quote all variables, especially paths.

        Use arrays for lists and command arguments.

        Minimize external process calls; use Bash builtins where possible.

        Handle errors clearly with exit codes and messages.

        Ensure the script can run on a fresh Linux/macOS system with only curl or wget to fetch it.

    Single-command deployment

        The script should be self-contained; after downloading, chmod +x llama-select.sh && ./llama-select.sh should work.

        Optionally, include in a comment a one-liner like:
        bash

        curl -sSL https://example.com/llama-select.sh | bash

        But the main deliverable is the script itself.

Acceptance criteria

    Running ./llama-select.sh interactively with models present shows a TUI menu, then a form, then confirmation, and finally launches llama-server.

    Running ./llama-select.sh --model /path/to/model.gguf --port 9000 in a non-interactive shell launches the server directly with no TUI.

    Missing dialog triggers automatic installation.

    Missing llama-server or model directory gives clear error.

    No external dependencies beyond dialog and llama-server.

    Handles filenames with spaces.

Output: A file with the bash script on the project folder.
