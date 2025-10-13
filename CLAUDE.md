# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

kitty is a fast, feature-rich, GPU-based terminal emulator written in a multi-language architecture:
- **Python**: High-level application logic and orchestration
- **C**: Performance-critical code (terminal emulation, OpenGL rendering)
- **Go**: CLI tools and "kittens" (plugins)
- **GLSL**: GPU shaders for rendering

## Build System

The build system is Python-based using `setup.py` as the main orchestrator. It handles:
- Compilation of C extensions
- Go binary builds
- GLFW (custom fork for windowing)
- Code generation for constants and bindings

### Common Build Commands

```bash
# Standard build
python3 setup.py

# Development build (via Makefile)
make devel          # Full development build with code signing (macOS)
make all            # Standard build
make clean          # Clean build artifacts

# Debug builds
python3 setup.py build --debug                    # Debug build
python3 setup.py build --debug --sanitize         # With ASAN/UBSAN
python3 setup.py build --debug --extra-logging=event-loop  # Extra logging

# Profile build
python3 setup.py build --profile

# macOS app bundle
python3 setup.py kitty.app

# Linux package
python3 setup.py linux-package
```

**Important**: The `setup.py` file is ~2000 lines and handles complex platform-specific logic. When modifying the build system, always check for platform-specific conditionals (`is_macos`, `is_windows`, `is_bsd`).

## Testing

Tests are integrated across Python and Go codebases.

### Running Tests

```bash
# Run all tests (Python + Go)
./test.py

# Run specific test by name
./test.py linebuf              # Runs test_linebuf in Python
./test.py Something            # Runs TestSomething in Go

# Run tests from specific module/package
./test.py --module ssh         # Python module
./test.py --module tools/cli   # Go package

# Type checking
./test.py type-check           # or mypy
```

### Test Structure

- **Python tests**: `kitty_tests/` directory, uses unittest framework
- **Go tests**: `*_test.go` files throughout codebase, uses standard Go testing
- Tests run in isolated environment (temporary HOME, XDG dirs)

### Code Quality Tools

```bash
# Python type checking (mypy with strict settings in pyproject.toml)
python3 -m mypy --pretty

# Python linting (ruff)
ruff check .
ruff format .

# Go linting
# (staticcheck configuration in staticcheck.conf)
```

## Architecture Overview

### Multi-Process Architecture

kitty uses a multi-process model:
- **Main Process**: Python-based, manages the UI and coordinates everything (see `kitty/boss.py`)
- **Child Processes**: Individual shell sessions running in pseudo-terminals
- **Child Monitor**: C-based thread monitoring child processes (see `kitty/child-monitor.c`)

### Core Components

**Python Layer** (`kitty/` directory):
- `boss.py`: Central orchestrator ("the boss") managing all OS windows, tabs, and terminal windows
- `window.py`: Individual terminal window implementation
- `tabs.py`: Tab management within OS windows
- `fast_data_types.{c,pyi}`: C extension interface exposing fast operations to Python
- `screen.c`: Terminal screen buffer and emulation state machine
- `graphics.c`: Graphics protocol implementation

**Go Layer** (`tools/` directory):
- `tools/cmd/main.go`: Entry point for the `kitten` command
- `tools/cli/`: CLI framework
- `tools/tui/`: Terminal UI library
- `tools/utils/`: Shared utilities
- Each subdirectory implements a specific kitten or utility

**Rendering Pipeline**:
- `*.glsl` files: GLSL shaders for GPU rendering
- `gl.c`, `gl-wrapper.c`: OpenGL interface
- `glfw/`: Custom GLFW build for windowing

### Kittens (Plugin System)

Kittens are sub-commands that extend kitty's functionality. Located in `kittens/` directory:
- Can be implemented in Python or Go
- Python kittens: `kittens/{name}/main.py`
- Go kittens: Integrated into `tools/cmd/`
- Examples: `ssh`, `diff`, `icat`, `themes`, `hints`

To add a new kitten:
1. Create directory in `kittens/` (for Python) or `tools/cmd/` (for Go)
2. Implement the kitten following existing patterns
3. For Go kittens, integrate into `tools/cmd/main.go`

## Python-Specific Patterns

### Fast Data Types

Performance-critical code is in C with Python bindings:
- C files in `kitty/*.c` are compiled as Python extensions
- Python stubs in `kitty/*.pyi` for type hints
- Access via `from kitty.fast_data_types import ...`

### Type Hints

Extremely strict mypy configuration (see `pyproject.toml`):
- `strict = true`
- `disallow_untyped_defs = true`
- `disallow_untyped_calls = true`
- All code must be fully typed

### Code Generation

Several files are auto-generated:
- `kitty/cli_stub.py`: Generated from CLI definitions
- `constants_generated.go`: Generated from Python constants
- Do not edit these directly; modify their generators instead

## Go-Specific Patterns

### Build Tags

Go tests use build tags:
```bash
go test -tags testing ./...
```

### Package Structure

- `tools/cmd/`: Commands and entry points
- `tools/cli/`: CLI argument parsing framework
- `tools/tui/`: Terminal UI library (used by many kittens)
- `tools/utils/`: Shared utilities
- `tools/tty/`: TTY manipulation
- `tools/vt/`: Virtual terminal implementation

### Common Patterns

- CLI commands use the `tools/cli` framework (see `tools/cmd/main.go`)
- TUI applications use `tools/tui` (see kittens like `ssh`, `diff`)
- Prefer `tools/utils` for common operations

## C Code Patterns

### Memory Management

- Use arena allocators where appropriate (see `kitty/arena.h`)
- Follow Python's memory management for extension code
- Use `PyMem_Calloc`, `PyMem_Free` for Python-exposed allocations

### OpenGL/Rendering

- All OpenGL code goes through `gl.c` and `gl-wrapper.c`
- Shaders are in separate `.glsl` files
- Follow existing shader compilation patterns in `setup.py`

### Screen Buffer

The terminal screen buffer (`screen.c`) is highly optimized:
- Cursor management
- Line buffer operations
- VT escape sequence parsing
- Graphics protocol handling

## Documentation

### Building Docs

```bash
# Build HTML docs
make html

# Build man pages
make man

# Build all documentation
make docs

# Serve docs locally
make develop-docs
```

Documentation is Sphinx-based (RST format) in `docs/` directory.

### Auto-Generated Documentation

The following docs are auto-generated (via `docs/conf.py`):
- CLI documentation from argparse definitions
- Config file documentation from `kitty/options/definition.py`
- Remote control protocol docs from `kitty/rc/base.py`

When adding new CLI options or config options, the docs will be generated automatically.

## Common Development Workflows

### Adding a New Keyboard Shortcut

1. Add action function to `kitty/actions.py`
2. Add default mapping in `kitty/options/definition.py`
3. Documentation auto-generates from docstrings

### Adding a New Config Option

1. Define option in `kitty/options/definition.py`
2. Add type definition in `kitty/options/types.py` if needed
3. Handle option in relevant code (usually `boss.py` or `window.py`)
4. Documentation auto-generates

### Adding a New Remote Control Command

1. Create command class in `kitty/rc/` directory
2. Implement the command following existing patterns
3. Add to `kitty/rc/base.py`
4. Protocol documentation auto-generates

### Debugging

```bash
# Run with debug logging
kitty --debug-gl --debug-keyboard

# Attach with lldb (macOS)
lldb -- ./kitty/launcher/kitty

# Run under ASAN
make asan
./kitty.app/Contents/MacOS/kitty

# Run with profiling
make profile
```

## Code Generation

Code generation happens during build:

```bash
# Generate Go constants from Python
python3 setup.py               # Runs during normal build

# Force regeneration
rm constants_generated.go gen/* build/*
python3 setup.py
```

Generated files:
- `constants_generated.go`: Go constants from Python `kitty/constants.py`
- `gen/` directory: Various generated code
- `kitty/cli_stub.py`: CLI type stubs

## Cross-Compilation

```bash
# Prepare for cross-compile
make prepare-for-cross-compile

# Cross-compile (after prepare)
make cross-compile
```

## Platform-Specific Notes

### macOS

- Code signing is required for .so files (see Makefile `devel` target)
- Uses Cocoa APIs (see `glfw/cocoa_*.m` files)
- Universal binaries supported (`macos_universal_arches` in setup.py)

### Linux

- Multiple display server backends (X11, Wayland)
- D-Bus integration (see `glfw/dbus_glfw.c`)
- systemd notification support

### Dependencies

Install build dependencies as documented at: https://sw.kovidgoyal.net/kitty/build/#dependencies

Required:
- Python 3.10+ (see `pyproject.toml` for exact version)
- Go 1.24+ (see `go.mod` for exact version)
- C compiler (clang preferred, gcc supported)
- pkg-config
- OpenGL libraries
- fontconfig, freetype
- harfbuzz

## Important Files to Review

When working on kitty, these files provide the big picture:

- `kitty/boss.py`: Main application orchestrator
- `kitty/window.py`: Terminal window implementation
- `kitty/screen.c`: Terminal emulation state machine
- `kitty/fast_data_types.c`: Python-C interface
- `setup.py`: Build system logic
- `tools/cmd/main.go`: Go CLI entry point
- `glfw/`: Windowing and platform integration

## Performance Considerations

- The rendering pipeline is GPU-accelerated via OpenGL
- Terminal screen operations are highly optimized C code
- Avoid Python allocations in hot paths
- Use C extensions for performance-critical code
- The boss pattern minimizes Python overhead by batching operations
