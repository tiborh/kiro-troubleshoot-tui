# kiro-cli TUI Troubleshooting Guide

**Problem:** `kiro-cli` silently exits or only works with `--classic` on some machines,
even though the setup appears identical (same Manjaro version, same lxterminal).

**Root cause:** The bundled `bun` runtime (used to render the TUI via `tui.js`) requires
**AVX instructions**. CPUs without AVX (e.g., Intel Celeron J4125, pre-Haswell,
Gemini Lake) crash with `SIGILL` (Illegal Instruction) when bun is executed. kiro-cli
silently falls back to `--classic` mode or exits when this happens.

Reference issues:
- <https://github.com/aws/amazon-q-developer-cli/issues/3860>
- Same class of bug as <https://github.com/anthropics/claude-code/issues/20116>

---

## Quick diagnosis

```bash
# Does the bundled bun work on your CPU?
~/.local/share/kiro-cli/bun --version
```

If this prints a version number, bun works — your issue is something else (see
[Other causes](#other-causes-kiro-cli-term-not-launching) below).

If it crashes with **"Illegal instruction"** or **"CPU lacks AVX support"**, you've
hit the AVX issue. Apply the fix below.

---

## The Fix: replace bun with the baseline build

Bun publishes a **baseline** build that doesn't require AVX. The `kiro-fix-bun`
script in this repo automates the replacement.

### One-time fix

```bash
# From this repo:
./kiro-fix-bun

# Or if installed to ~/.local/bin:
kiro-fix-bun
```

The script will:
1. Check if your CPU lacks AVX (exit early if AVX is present — safe on any machine)
2. Check if the current bun binary already works (exit early if so)
3. Auto-detect the bun version from the binary
4. Download the matching baseline build from GitHub
5. Verify it runs, then swap it in

### Installing the script system-wide

```bash
cp kiro-fix-bun ~/.local/bin/
chmod +x ~/.local/bin/kiro-fix-bun
```

Then after any kiro-cli update, just run:

```bash
kiro-fix-bun
```

### Options

```bash
kiro-fix-bun            # auto-detect and fix if needed
kiro-fix-bun --force    # re-download even if bun already works
kiro-fix-bun 1.3.14    # manually specify version (if auto-detect fails)
```

### What it does

| Before | After |
|---|---|
| `~/.local/share/kiro-cli/bun` (AVX build, crashes) | `~/.local/share/kiro-cli/bun` (baseline build, works) |
| — | `~/.local/share/kiro-cli/bun.original` (backup of AVX build) |

The baseline build is functionally identical — just compiled without AVX/AVX2
SIMD optimizations. Performance difference is negligible for the TUI use case.

### After a kiro-cli update

kiro-cli updates will overwrite the bun binary, reverting to the AVX build. Just
run `kiro-fix-bun` again. The script is idempotent — if bun already works, it
does nothing.

---

## Root cause details

### How the TUI launches

When you run `kiro-cli` (without `--classic`), it starts the chat via:

```
kiro-cli → kiro-cli-chat chat → bun tui.js chat → kiro-cli-chat acp
```

The TUI is a JavaScript application (`tui.js`) executed by the bundled `bun`
runtime. If `bun` crashes (SIGILL on non-AVX CPUs), the TUI never starts and
kiro-cli falls back to classic mode silently.

### Affected CPUs

Any x86_64 CPU **without AVX** support:
- Intel Celeron J-series (Gemini Lake: J4125, J4105, etc.)
- Intel Atom (pre-Goldmont Plus)
- Intel Core pre-Sandy Bridge (before ~2011)
- Some low-power / embedded x86_64 processors
- Virtual machines where AVX is not exposed by the hypervisor

### How to check

```bash
# Check for AVX support:
grep -o ' avx ' /proc/cpuinfo | head -1
# Empty output = no AVX = affected by this bug

# Check CPU model:
grep "model name" /proc/cpuinfo | head -1
```

### Machines tested

All running Manjaro 26.1.0, lxterminal 0.4.1-2, vte3 0.84.0-1, kiro-cli 2.13.0.

| Machine | CPU | AVX? | TUI without fix? | TUI with fix? |
|---|---|---|---|---|
| tibor-herobox0 | Intel Celeron J4125 | ✘ no | ✘ crashes | ✔ works |
| tibor-nipogi | AMD Ryzen 5 7430U | ✔ yes | ✔ works | n/a |
| tibor-larkboxx | Intel N150 | ✔ yes | ✔ works | n/a |

---

## Other causes: kiro-cli-term not launching

If `bun --version` works but `kiro-cli` still doesn't show the TUI, the issue
may be with `kiro-cli-term` (the PTY wrapper). This is a separate component from
the bun-based TUI.

### How kiro-cli-term launch works

During shell startup, `kiro-cli init bash pre` evaluates whether to launch
`kiro-cli-term`. The decision is based on:

| Check | What it looks at |
|---|---|
| Terminal allowlist | Is the parent terminal on the known-good list? |
| `VTE_VERSION` env var | Signals VTE PTY support |
| `TERM_PROGRAM` env var | Terminal self-identification |
| `COLORTERM` env var | `truecolor` or `24bit` — capable terminal |
| `SHOULD_QTERM_LAUNCH` | Override: if set to `1`, always launch |

When kiro-cli-term is running, it injects:

| Variable | Meaning |
|---|---|
| `Q_SET_PARENT_CHECK=1` | kiro-cli-term is the active wrapper |
| `SHELL_PID` | PID of the wrapped interactive shell |
| `TTY` | PTY device path |

### Diagnosis steps for kiro-cli-term issues

**Step 1 — Check if kiro-cli-term is running:**
```bash
echo "Q_SET_PARENT_CHECK=${Q_SET_PARENT_CHECK:-<not set>}"
```

**Step 2 — Check shell integrations:**
```bash
kiro-cli doctor
```
If it reports missing integrations:
```bash
kiro-cli integrations install dotfiles
```

**Step 3 — Check VTE_VERSION:**
```bash
echo "VTE_VERSION=${VTE_VERSION:-<not set>}"
# Test if setting it helps:
VTE_VERSION=9400 kiro-cli
```

**Step 4 — Force kiro-cli-term launch:**
```bash
echo 'export SHOULD_QTERM_LAUNCH=1' >> ~/.bashrc
source ~/.bashrc
kiro-cli
```

Note: lxterminal is not officially in kiro-cli-term's allowlist as of 2.13.0.
`SHOULD_QTERM_LAUNCH=1` is the most reliable workaround for that issue.

### The `should-figterm-launch` subshell caveat

Running `kiro-cli _ should-figterm-launch` from a script or subshell will **always
return exit 1** — the command sees the script's bash as the direct parent, not the
terminal. This is normal. To get the real result, run interactively:

```bash
kiro-cli _ should-figterm-launch; echo "Exit: $?"
```

---

## Data collection (for further debugging)

### Files in this repo

| File | Purpose |
|---|---|
| `kiro-fix-bun` | Fix script — replaces bun with baseline build |
| `collect.sh` | Gathers diagnostic data from a machine |
| `compare.sh` | Diffs two diagnostic files side by side |
| `TROUBLESHOOTING.md` | This document |

### Diagnostic files (not committed)

Diagnostic output goes to `~/Dropbox/kiro/troubleshoot-tui/diag-*.txt` (excluded
via `.gitignore`). These contain machine-specific environment data.

### Collecting data

```bash
# From a plain terminal:
./collect.sh

# From inside a running kiro-cli session:
./collect.sh
```

The script prints `Context: INSIDE/OUTSIDE kiro-cli-term` at the top.

### Comparing data

```bash
./compare.sh                           # list available diag files
./compare.sh diag-A.txt diag-B.txt     # compare two files
```

---

## Known limitations / open issues

- The bundled bun binary in kiro-cli 2.13.0 is the AVX build (`bun-linux-x64`),
  not the baseline build (`bun-linux-x64-baseline`). This affects all non-AVX CPUs.
  The fix must be re-applied after each kiro-cli update.

- lxterminal is not in kiro-cli-term's terminal allowlist as of 2.13.0.
  `SHOULD_QTERM_LAUNCH=1` is needed to force kiro-cli-term to launch.

- `should-figterm-launch` always exits 1 from a script subshell — this is by
  design and not a diagnostic signal.

- Upstream issue: <https://github.com/aws/amazon-q-developer-cli/issues/3860>
