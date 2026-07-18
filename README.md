# kiro-troubleshoot-tui

Tools and diagnostic scripts for investigating why the Kiro CLI TUI does not
start, particularly on systems with CPUs that lack AVX support.

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the diagnosis steps, fix, and
usage instructions.

## Quick start

Check whether Kiro CLI's bundled Bun runtime works:

```bash
~/.local/share/kiro-cli/bun --version
```

If it fails with an illegal-instruction error on a non-AVX CPU, run:

```bash
./kiro-fix-bun
```

For diagnosis, recovery details, and data-collection tools, see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).
