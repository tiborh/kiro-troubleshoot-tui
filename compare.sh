#!/usr/bin/env bash
# compare.sh — Diff two diagnostic files produced by collect.sh.
# Usage: ./compare.sh <file-a.txt> <file-b.txt>
#
# If no arguments are given, lists available diag files in the default
# private Dropbox directory so you can pick the right pair.
#
# Typical comparisons:
#   (A) broken-plain  vs working-plain   → find env differences between machines
#   (B) working-plain vs working-intui   → see what kiro-cli-term injects
#   (C) broken-plain  vs working-intui   → what the broken machine needs to replicate
#
# Diagnostic files live in ~/Dropbox/kiro/troubleshoot-tui/ (private, not in git).
# Scripts and docs live in the git repo (public).

set -euo pipefail

PRIVATE_DIR="${HOME}/Dropbox/kiro/troubleshoot-tui"

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <file-a.txt> <file-b.txt>"
    echo ""
    echo "Typical comparisons:"
    echo "  broken-plain  vs working-plain   → env differences between machines"
    echo "  working-plain vs working-intui   → what kiro-cli-term injects"
    echo "  broken-plain  vs working-intui   → what broken machine needs to replicate"
    echo ""
    echo "Diagnostic files are stored in: ${PRIVATE_DIR}"
    if [ -d "$PRIVATE_DIR" ]; then
        echo ""
        echo "Available files:"
        ls -lht "${PRIVATE_DIR}"/diag-*.txt 2>/dev/null \
            | awk '{print "  " $NF " (" $5 ", " $6 " " $7 ")"}' \
            || echo "  (none found yet — run collect.sh first)"
    else
        echo "  (directory not found — run collect.sh first to create it)"
    fi
    exit 1
fi

FILE_A="$1"
FILE_B="$2"

for f in "$FILE_A" "$FILE_B"; do
    if [ ! -f "$f" ]; then
        echo "Error: file not found: $f"
        exit 1
    fi
done

# Colour helpers (fall back gracefully if not a tty)
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

hr() { echo -e "${CYAN}────────────────────────────────────────────────────────────${RESET}"; }

header() {
    echo ""
    hr
    echo -e "${BOLD}${YELLOW}  $*${RESET}"
    hr
}

# ── Extract a named section from a diag file ──────────────────────────────────
extract_section() {
    local file="$1"
    local name="$2"
    awk "/^# ${name}/{found=1; next} found && /^#{4,}/{exit} found{print}" "$file"
}

# ── Helper: get a single value from the full-env section ──────────────────────
get_env_val() {
    local file="$1"
    local varname="$2"
    # Look for exact VAR= match in the full env section (sorted env dump).
    grep -m1 "^${varname}=" "$file" | cut -d= -f2- || echo "<not set>"
}

# ── Pre-flight: warn if both files are inside-TUI (misleading comparison) ─────
a_ctx=$(grep "^Context:" "$FILE_A" | head -1 || echo "")
b_ctx=$(grep "^Context:" "$FILE_B" | head -1 || echo "")

header "COLLECTION CONTEXT"
echo -e "  File A: ${BOLD}$(basename "$FILE_A")${RESET}"
echo "    ${a_ctx:-Context: (unknown — old format)}"
echo ""
echo -e "  File B: ${BOLD}$(basename "$FILE_B")${RESET}"
echo "    ${b_ctx:-Context: (unknown — old format)}"
echo ""

if echo "$a_ctx $b_ctx" | grep -q "INSIDE.*INSIDE"; then
    echo -e "  ${YELLOW}⚠  Both files were collected INSIDE kiro-cli-term.${RESET}"
    echo "     This comparison shows differences between two working sessions."
    echo "     For root-cause analysis, compare a plain-terminal capture (OUTSIDE)"
    echo "     against either of these."
elif echo "$a_ctx $b_ctx" | grep -q "OUTSIDE.*OUTSIDE"; then
    echo -e "  ${YELLOW}⚠  Both files were collected OUTSIDE kiro-cli-term.${RESET}"
    echo "     This comparison shows env differences between plain terminals."
    echo "     Also collect from inside kiro-cli on the working machine to see"
    echo "     what kiro-cli-term injects."
else
    echo -e "  ${GREEN}✔  One inside-TUI, one outside — ideal comparison.${RESET}"
fi

# ── Quick-look: key values side by side ───────────────────────────────────────
header "KEY VALUES SIDE BY SIDE"
printf "%-44s  %-28s  %-28s\n" "Variable / Check" "FILE A ($(basename "$FILE_A" .txt | cut -c1-25))" "FILE B ($(basename "$FILE_B" .txt | cut -c1-25))"
printf "%-44s  %-28s  %-28s\n" "$(printf '%0.s-' {1..44})" "$(printf '%0.s-' {1..28})" "$(printf '%0.s-' {1..28})"

print_row() {
    local label="$1"
    local a_val="$2"
    local b_val="$3"
    local marker=""
    [ "$a_val" != "$b_val" ] && marker=" ◄ DIFF"
    printf "%-44s  %-28s  %-28s%s\n" "$label" "${a_val:0:28}" "${b_val:0:28}" "$marker"
}

# Collection context
a_inside=$(grep "^Context:.*INSIDE" "$FILE_A" > /dev/null 2>&1 && echo "inside-TUI" || echo "plain terminal")
b_inside=$(grep "^Context:.*INSIDE" "$FILE_B" > /dev/null 2>&1 && echo "inside-TUI" || echo "plain terminal")
print_row "collection context" "$a_inside" "$b_inside"

# should-figterm-launch exit code
a_figterm=$(grep "^Exit code:" "$FILE_A" | head -1 | grep -oP '\d+' || echo "?")
b_figterm=$(grep "^Exit code:" "$FILE_B" | head -1 | grep -oP '\d+' || echo "?")
print_row "should-figterm-launch exit code" "$a_figterm" "$b_figterm"

# kiro-cli version
a_ver=$(grep -m1 "^kiro-cli " "$FILE_A" | grep -oP '\d+\.\d+\.\d+' || echo "?")
b_ver=$(grep -m1 "^kiro-cli " "$FILE_B" | grep -oP '\d+\.\d+\.\d+' || echo "?")
print_row "kiro-cli version" "$a_ver" "$b_ver"

# Q_SET_PARENT_CHECK — injected by kiro-cli-term
a_qcheck=$(get_env_val "$FILE_A" "Q_SET_PARENT_CHECK")
b_qcheck=$(get_env_val "$FILE_B" "Q_SET_PARENT_CHECK")
print_row "Q_SET_PARENT_CHECK (inside TUI?)" "$a_qcheck" "$b_qcheck"

# SHOULD_QTERM_LAUNCH — workaround override
a_sqtl=$(get_env_val "$FILE_A" "SHOULD_QTERM_LAUNCH")
b_sqtl=$(get_env_val "$FILE_B" "SHOULD_QTERM_LAUNCH")
print_row "SHOULD_QTERM_LAUNCH (override?)" "$a_sqtl" "$b_sqtl"

# SHELL_PID / TTY — injected by kiro-cli-term
a_spid=$(get_env_val "$FILE_A" "SHELL_PID")
b_spid=$(get_env_val "$FILE_B" "SHELL_PID")
print_row "SHELL_PID (injected by kiro-term?)" "$a_spid" "$b_spid"

a_tty=$(get_env_val "$FILE_A" "TTY")
b_tty=$(get_env_val "$FILE_B" "TTY")
print_row "TTY (injected by kiro-term?)" "$a_tty" "$b_tty"

# VTE_VERSION
a_vte=$(get_env_val "$FILE_A" "VTE_VERSION")
b_vte=$(get_env_val "$FILE_B" "VTE_VERSION")
print_row "VTE_VERSION" "$a_vte" "$b_vte"

# TERM_PROGRAM
a_tp=$(get_env_val "$FILE_A" "TERM_PROGRAM")
b_tp=$(get_env_val "$FILE_B" "TERM_PROGRAM")
print_row "TERM_PROGRAM" "$a_tp" "$b_tp"

# COLORTERM
a_ct=$(get_env_val "$FILE_A" "COLORTERM")
b_ct=$(get_env_val "$FILE_B" "COLORTERM")
print_row "COLORTERM" "$a_ct" "$b_ct"

# TERM
a_term=$(get_env_val "$FILE_A" "TERM")
b_term=$(get_env_val "$FILE_B" "TERM")
print_row "TERM" "$a_term" "$b_term"

# SHELL (login shell)
a_shell=$(get_env_val "$FILE_A" "SHELL")
b_shell=$(get_env_val "$FILE_B" "SHELL")
print_row "SHELL (login shell)" "$a_shell" "$b_shell"

# SHLVL
a_shlvl=$(get_env_val "$FILE_A" "SHLVL")
b_shlvl=$(get_env_val "$FILE_B" "SHLVL")
print_row "SHLVL (nesting depth)" "$a_shlvl" "$b_shlvl"

# XDG_SESSION_TYPE
a_xdg=$(get_env_val "$FILE_A" "XDG_SESSION_TYPE")
b_xdg=$(get_env_val "$FILE_B" "XDG_SESSION_TYPE")
print_row "XDG_SESSION_TYPE" "$a_xdg" "$b_xdg"

# XDG_CURRENT_DESKTOP
a_desk=$(get_env_val "$FILE_A" "XDG_CURRENT_DESKTOP")
b_desk=$(get_env_val "$FILE_B" "XDG_CURRENT_DESKTOP")
print_row "XDG_CURRENT_DESKTOP" "$a_desk" "$b_desk"

# lxterminal version
a_lxt=$(grep -A1 "^\$ lxterminal --version" "$FILE_A" | tail -1 || echo "?")
b_lxt=$(grep -A1 "^\$ lxterminal --version" "$FILE_B" | tail -1 || echo "?")
print_row "lxterminal version" "$a_lxt" "$b_lxt"

# vte3 package version
a_vte3=$(grep "^vte3 " "$FILE_A" | awk '{print $2}' || echo "?")
b_vte3=$(grep "^vte3 " "$FILE_B" | awk '{print $2}' || echo "?")
[ -z "$a_vte3" ] && a_vte3="?"
[ -z "$b_vte3" ] && b_vte3="?"
print_row "vte3 package version" "$a_vte3" "$b_vte3"

echo ""

# ── Focused section diffs ─────────────────────────────────────────────────────
focused_diff() {
    local section_name="$1"
    local a_tmp b_tmp
    a_tmp=$(mktemp); b_tmp=$(mktemp)
    extract_section "$FILE_A" "$section_name" > "$a_tmp"
    extract_section "$FILE_B" "$section_name" > "$b_tmp"
    if diff -q "$a_tmp" "$b_tmp" > /dev/null 2>&1; then
        echo -e "  ${GREEN}✔ identical${RESET}"
    else
        diff --color=always -u \
            --label "FILE A: $section_name" \
            --label "FILE B: $section_name" \
            "$a_tmp" "$b_tmp" || true
    fi
    rm -f "$a_tmp" "$b_tmp"
}

for section in \
    "Inside-TUI session (kiro-cli-term wrapper)" \
    "Terminal-related environment variables" \
    "Shell dotfile integrations" \
    "kiro-cli init output (what it exports into the shell)" \
    "kiro-cli integrations" \
    "lxterminal / VTE details" \
    "Shell" \
    "kiro-cli version" \
    "Display and session" \
    "kiro-cli settings files"
do
    header "SECTION DIFF: $section"
    focused_diff "$section"
done

# ── Full diff offer ────────────────────────────────────────────────────────────
echo ""
hr
echo -e "${BOLD}Full diff (all sections):${RESET}"
echo "  diff --color=always -u \"$FILE_A\" \"$FILE_B\" | less -R"
echo ""
echo -e "${BOLD}Diag files location:${RESET}  ${PRIVATE_DIR}"
hr
echo ""
echo -e "${BOLD}Interpretation guide:${RESET}"
cat <<'GUIDE'

  Collection context
  ──────────────────
  INSIDE  = collected from within a running kiro-cli session (kiro-cli-term active)
  OUTSIDE = collected from a plain terminal (kiro-cli-term NOT running)

  Best comparisons:
    broken-outside vs working-outside  → env differences between machines
    working-outside vs working-inside  → what kiro-cli-term injects into the env
    broken-outside vs working-inside   → what the broken machine is missing

  should-figterm-launch
  ─────────────────────
  ⚠ Always exits 1 when run from a script subshell — this is EXPECTED and normal.
  The useful part of that section is the process-check line, e.g.:
    ❌ bash | bash (PID) <- ✅ bash (PID)
  This shows kiro-cli-term sees the script bash as the parent, not the terminal.

  Key injected vars (set by kiro-cli-term when it wraps the shell)
  ─────────────────────────────────────────────────────────────────
  Q_SET_PARENT_CHECK=1   → confirms kiro-cli-term is the wrapper
  SHELL_PID              → PID of the interactive shell it wrapped
  TTY                    → PTY device path

  SHOULD_QTERM_LAUNCH=1  → workaround override (not injected by kiro-cli-term;
                           set by kiro-cli init bash pre to force figterm launch)

  If SHOULD_QTERM_LAUNCH=1 is set on the "working" machine, it is using the
  workaround — not a naturally working baseline.

  Shell dotfile integrations
  ──────────────────────────
  kiro-cli hooks in ~/.bashrc / ~/.profile / ~/.bash_profile:
    bashrc.pre.bash  → sources early (sets SHOULD_QTERM_LAUNCH=1, other vars)
    bashrc.post.bash → sources late (registers shell hooks for inline completion etc.)
  Missing hooks → kiro-cli-term may not be triggered at shell startup.
  Run: kiro-cli integrations install dotfiles
  to reinstall if missing.

GUIDE
