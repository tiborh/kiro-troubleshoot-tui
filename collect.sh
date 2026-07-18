#!/usr/bin/env bash
# collect.sh — Collect kiro-cli TUI diagnostic data on a machine.
# Usage: ./collect.sh [output-file]
#
# Output defaults to:
#   ~/Dropbox/kiro/troubleshoot-tui/diag-<hostname>-<timestamp>.txt
#
# Diagnostic files are written to a private Dropbox folder so they can be
# shared safely without being committed to the public git repo.
# The scripts and documentation live in git; the data files live in Dropbox.
#
# IMPORTANT: Run this TWICE on each machine where kiro-cli works:
#   1. From a plain terminal (outside kiro-cli)
#   2. From inside a running kiro-cli session
# The diff between those two captures shows exactly what kiro-cli-term injects.
#
# On the broken machine, run once from a plain terminal.

set -euo pipefail

PRIVATE_DIR="${HOME}/Dropbox/kiro/troubleshoot-tui"
mkdir -p "$PRIVATE_DIR"

OUTPUT="${1:-${PRIVATE_DIR}/diag-$(hostname)-$(date +%Y%m%d_%H%M%S).txt}"

section() {
    echo ""
    echo "########################################"
    echo "# $*"
    echo "########################################"
}

run() {
    # Run a command, print its output; never abort on error.
    echo "$ $*"
    "$@" 2>&1 || echo "(exit code $?)"
    echo ""
}

{
    echo "kiro-cli TUI diagnostic report"
    echo "Generated: $(date --iso-8601=seconds)"
    echo "Hostname:  $(hostname)"

    # ── Collection context banner ─────────────────────────────────────────────
    # Print this at the very top so the context is immediately obvious.
    if [ "${Q_SET_PARENT_CHECK:-}" = "1" ]; then
        echo "Context:   INSIDE kiro-cli-term (TUI wrapper is active)"
    else
        echo "Context:   OUTSIDE kiro-cli-term (plain terminal)"
        echo "           ⚠ For full data: also run collect.sh from inside a kiro-cli session"
    fi

    # ── kiro-cli ──────────────────────────────────────────────────────────────
    section "kiro-cli version"
    run kiro-cli --version

    section "kiro-cli should-figterm-launch"
    # ⚠ SUBSHELL LIMITATION:
    # This command is run in a subshell (bash ./collect.sh), so it will almost
    # always return exit 1 — it sees the script's bash as the parent, not the
    # interactive shell or terminal. This is expected and does NOT mean figterm
    # won't launch. The useful part is the process-check line it prints, showing
    # which processes it actually found in the tree.
    echo "$ kiro-cli _ should-figterm-launch"
    echo "(NOTE: always exits 1 from a script subshell — see TROUBLESHOOTING.md)"
    FIGTERM_EXIT=0
    ( SHOULD_QTERM_LAUNCH=0 kiro-cli _ should-figterm-launch </dev/null ) 2>&1 || FIGTERM_EXIT=$?
    echo "Exit code: $FIGTERM_EXIT"
    echo ""

    section "kiro-cli doctor"
    run kiro-cli doctor

    section "kiro-cli integrations"
    run kiro-cli integrations list 2>/dev/null || echo "(integrations list not available in this version)"

    section "kiro-cli init output (what it exports into the shell)"
    echo "$ kiro-cli init bash pre --rcfile bashrc"
    kiro-cli init bash pre --rcfile bashrc 2>&1 | head -20 || echo "(exit code $?)"
    echo "..."
    echo ""
    echo "$ kiro-cli init bash post --rcfile bashrc"
    kiro-cli init bash post --rcfile bashrc 2>&1 | head -20 || echo "(exit code $?)"
    echo "..."
    echo ""

    # ── Shell dotfile integrations ────────────────────────────────────────────
    section "Shell dotfile integrations"
    echo "Checking for kiro-cli hooks in shell startup files:"
    echo ""
    for f in ~/.bashrc ~/.bash_profile ~/.profile ~/.zshrc ~/.zprofile; do
        if [ -f "$f" ]; then
            echo "--- $f ---"
            grep -n 'kiro\|fig\|q_pre\|q_post\|SHOULD_QTERM\|kiro-cli' "$f" 2>/dev/null \
                || echo "  (no kiro-cli hooks found)"
            echo ""
        else
            echo "--- $f --- (does not exist)"
            echo ""
        fi
    done

    echo "Integration script files:"
    INTEG_DIR="${HOME}/.local/share/kiro-cli/shell"
    if [ -d "$INTEG_DIR" ]; then
        ls -la "$INTEG_DIR"
        echo ""
        for f in "$INTEG_DIR"/*.bash "$INTEG_DIR"/*.sh; do
            [ -f "$f" ] || continue
            echo "=== $f ==="
            cat "$f"
            echo ""
        done
    else
        echo "  (directory not found: $INTEG_DIR)"
    fi
    echo ""

    # ── Terminal environment ──────────────────────────────────────────────────
    section "Terminal-related environment variables"
    env | grep -E \
        'TERM|VTE|COLORTERM|XTERM|TILIX|KONSOLE|GNOME_TERMINAL|KITTY|ALACRITTY|WEZTERM|TMUX|STY|Q_|KIRO_|FIG_|SHOULD_QTERM' \
        | sort || echo "(none found)"
    echo ""

    section "Full environment (sanitised)"
    # Redact anything that looks like a secret/token.
    env | sed 's/\(TOKEN\|SECRET\|PASSWORD\|KEY\|CREDENTIAL\|AUTH\)=.*/\1=<REDACTED>/i' \
        | sort
    echo ""

    # ── Terminal emulator detection ───────────────────────────────────────────
    section "Terminal emulator binary & version"
    for var in TERM_PROGRAM VTE_VERSION COLORTERM; do
        val="${!var:-}"
        echo "$var=${val:-<not set>}"
    done
    echo ""

    # Walk up the process tree to find the terminal emulator.
    echo "Process tree (ps -o pid,ppid,comm,args):"
    pid=$$
    while [ "$pid" -gt 1 ]; do
        ps -p "$pid" -o pid=,ppid=,comm=,args= 2>/dev/null || break
        pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ') || break
    done
    echo ""

    # Also show the direct parent of the interactive shell (PPID of SHELL_PID if set,
    # otherwise PPID of the script's parent bash).
    INTERACTIVE_SHELL_PID="${SHELL_PID:-}"
    if [ -n "$INTERACTIVE_SHELL_PID" ]; then
        echo "Interactive shell PID (from SHELL_PID env): $INTERACTIVE_SHELL_PID"
        IPARENT=$(ps -p "$INTERACTIVE_SHELL_PID" -o ppid= 2>/dev/null | tr -d ' ' || echo "?")
        echo "Parent of interactive shell (PID $IPARENT):"
        ps -p "$IPARENT" -o pid=,ppid=,comm=,args= 2>/dev/null || echo "  (could not read)"
    fi
    echo ""

    # /proc cmdline of direct shell parent — more reliable than ps args truncation.
    SCRIPT_PARENT=$(ps -p $$ -o ppid= 2>/dev/null | tr -d ' ')
    if [ -r "/proc/${SCRIPT_PARENT}/cmdline" ]; then
        echo "Script parent /proc/$SCRIPT_PARENT/cmdline:"
        tr '\0' ' ' < "/proc/${SCRIPT_PARENT}/cmdline"
        echo ""
    fi
    echo ""

    # ── lxterminal / VTE details ──────────────────────────────────────────────
    section "lxterminal / VTE details"
    run lxterminal --version
    run pacman -Q lxterminal 2>/dev/null || run dpkg -l lxterminal 2>/dev/null || echo "(package manager not identified)"
    run pacman -Q vte3 2>/dev/null || run dpkg -l libvte-2.91-0 2>/dev/null || echo "(vte package not found)"
    run pacman -Q vte-common 2>/dev/null || true

    # ── Inside-TUI session detection ──────────────────────────────────────────
    section "Inside-TUI session (kiro-cli-term wrapper)"
    if [ "${Q_SET_PARENT_CHECK:-}" = "1" ]; then
        echo "✔ Running INSIDE kiro-cli-term (TUI wrapper is active)"
    else
        echo "✘ Running OUTSIDE kiro-cli-term (plain terminal — not wrapped)"
        echo "  → To capture the inside-TUI env, open kiro-cli, then run collect.sh again."
    fi
    echo ""
    echo "Relevant vars injected by kiro-cli-term:"
    for var in Q_SET_PARENT_CHECK TERM_PROGRAM KIRO_TERM FIG_TERM \
               Q_TERM QTERM Q_PARENT Q_SHELL_PID TTY SHELL_PID SHOULD_QTERM_LAUNCH; do
        val="${!var:-}"
        echo "  $var=${val:-<not set>}"
    done
    echo ""
    echo "All Q_/KIRO_/FIG_/SHOULD_ vars present:"
    env | grep -E '^(Q_|KIRO_|FIG_|SHOULD_)' | sort || echo "  (none)"
    echo ""

    # ── Shell ─────────────────────────────────────────────────────────────────
    section "Shell"
    echo "Login shell (SHELL env var): $SHELL"
    echo "Currently running shell:     $(ps -p $$ -o comm= 2>/dev/null || echo unknown)"
    echo "SHLVL:                       ${SHLVL:-<not set>}"
    echo ""
    run bash --version
    if [ "$SHELL" != "/bin/bash" ] && [ "$SHELL" != "/usr/bin/bash" ]; then
        run "$SHELL" --version
    fi

    # ── OS / kernel ───────────────────────────────────────────────────────────
    section "OS / kernel"
    run uname -a
    run cat /etc/os-release
    run cat /etc/lsb-release 2>/dev/null || true

    # ── Display / session ─────────────────────────────────────────────────────
    section "Display and session"
    for var in DISPLAY WAYLAND_DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP \
               DBUS_SESSION_BUS_ADDRESS; do
        val="${!var:-}"
        echo "$var=${val:-<not set>}"
    done
    echo ""

    # ── PTY / tty ─────────────────────────────────────────────────────────────
    section "TTY / PTY info"
    run tty
    run ls -la "$(tty)" 2>/dev/null || true
    run stty -a

    # ── kiro-cli-term (figterm) binary ────────────────────────────────────────
    section "kiro-cli-term (figterm) binary"
    run which kiro-cli-term 2>/dev/null || echo "(kiro-cli-term not found in PATH)"
    for p in \
        ~/.local/bin/kiro-cli-term \
        ~/.local/share/kiro/bin/kiro-cli-term \
        /usr/local/bin/kiro-cli-term \
        ~/.local/bin/q-term; do
        [ -f "$p" ] && echo "Found: $p ($(ls -lh "$p" | awk '{print $5, $6, $7, $8}'))"
    done
    echo ""

    # ── kiro-cli config / data dirs ───────────────────────────────────────────
    section "kiro-cli config and data directories"
    for d in \
        ~/.kiro \
        ~/.config/kiro \
        ~/.local/share/kiro \
        ~/.fig \
        ~/.config/fig \
        ~/.local/share/fig; do
        if [ -d "$d" ]; then
            echo "Directory: $d"
            ls -la "$d" 2>/dev/null
            echo ""
        fi
    done

    section "kiro-cli settings files"
    for d in \
        ~/.kiro/settings \
        ~/.config/kiro/settings; do
        if [ -d "$d" ]; then
            echo "Directory: $d"
            ls -la "$d"
            echo ""
            shopt -s nullglob
            for f in "$d"/*.json "$d"/*.toml "$d"/*.yaml "$d"/*.yml; do
                echo "File: $f"
                cat "$f"
                echo ""
            done
            shopt -u nullglob
        fi
    done
    for f in \
        ~/.kiro/settings.json \
        ~/.config/kiro/settings.json \
        ~/.kiro/state.json; do
        if [ -f "$f" ]; then
            echo "File: $f"
            cat "$f"
            echo ""
        fi
    done

    # ── System info ───────────────────────────────────────────────────────────
    section "CPU and memory"
    run lscpu | grep -E 'Model name|Architecture|CPU\(s\)|Thread|Socket'
    run free -h

    section "Locale"
    run locale

} | tee "$OUTPUT"

echo ""
echo "✔  Diagnostic saved to: $OUTPUT"
echo "   Dropbox will sync this file automatically."
if [ "${Q_SET_PARENT_CHECK:-}" != "1" ]; then
    echo ""
    echo "   ⚠  This was collected OUTSIDE kiro-cli."
    echo "   For complete data: open kiro-cli, then run collect.sh again from inside."
fi
