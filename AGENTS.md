# Kitty Contributor Guide

## Architecture Overview

Kitty is a multi-language project combining Python (high-level logic), C (performance-critical code), Go (utilities), and GLSL (GPU rendering). Requires Python 3.10+. See [build documentation](https://sw.kovidgoyal.net/kitty/build/#dependencies) for dependency installation.

## Project Structure & Module Organization

```
kitty/              # Core terminal emulator (Python, C, GLSL)
  ├── conf/         # Configuration handling
  ├── fonts/        # Font rendering
  ├── launcher/     # Application launcher
  ├── layout/       # Window layout management
  ├── options/      # Options parsing
  └── rc/           # Remote control
kittens/            # Extension utilities (diff, ssh, themes, etc.)
kitty_tests/        # Tests mirroring source structure
docs/               # Sphinx documentation (RST format)
tools/              # Development utilities
3rdparty/           # Vendored dependencies (glfw, glad)
gen/                # Generated code
```

## Build, Test, and Development Commands

**Build:**
- `python3 setup.py` - Build kitty
- `make devel` - Development build with verbose output
- `make debug` - Debug build with symbols
- `make clean` - Clean build artifacts

**Testing:**
- `./test.py` - Run all tests
- `python3 setup.py test` - Alternative test runner

**Documentation:**
- `make docs` - Build HTML and man pages
- `make html` - Build HTML documentation only
- `make develop-docs` - Auto-rebuild docs on changes

**Specialized builds:** `make asan` (sanitizers), `make profile` (profiling)

## Coding Style & Naming Conventions

**Indentation:**
- Python/C: 4 spaces
- Go/Makefiles: tabs
- Line endings: LF
- Trim trailing whitespace

**Python specifics:**
- Line length: 160 characters
- Quotes: single quotes (`'string'`)
- Type checking: strict mypy (all `disallow_untyped_*` flags enabled)
- Linting: ruff (rules: E, F, I, RUF100)

**Configuration files:**
- `.editorconfig` - Editor settings
- `pyproject.toml` - Python tool configuration

## Testing Guidelines

- Tests located in `kitty_tests/` mirroring source structure
- Test file naming: match the module (e.g., `fonts.py` tests `kitty/fonts`)
- Run with `./test.py`
- Contribute tests for easily testable code
- Framework: Python's built-in testing via `kitty_tests/main.py`

## Commit & Pull Request Guidelines

**Commit messages:**
- Use imperative mood ("Add feature", "Fix bug")
- Keep concise and descriptive
- Optional component prefixes (e.g., `macOS:`, `entitlements:`)

**Pull requests:**
1. Fork the repository
2. Make your changes with tests (if applicable)
3. For large/controversial changes, open an issue first for discussion
4. Submit PR with clear description
5. Link related issues

**Contribution workflow:**
See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.
