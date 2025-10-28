# Kitty Metal Crash-Triage Playbook (written 2025-10-28)

Authoritative notebook for analysing kitty Metal crashes on macOS. Use it to avoid rediscovering the workflow every time a core dump appears.

---

## 1. Core Dump Intake Checklist
1. List new cores inside `./.cores` and the repo root (`ls -l ./.cores`).
2. Capture size/mtime (`ls -l core.*`), and keep originals read-only.
3. Always identify the file type with a known-good magic database:
   ```bash
   MAGIC=/usr/share/file/magic.mgc /usr/bin/file path/to/core
   ```
4. Note the PID timestamp encoded in the filename; you’ll need it to match crash reports or logs.

---

## 2. Standard LLDB Commands
Use the shipping app bundle unless you intentionally built another binary.
```bash
/usr/bin/lldb -c path/to/core /Applications/kitty.app/Contents/MacOS/kitty \
  --batch \
  -o "thread list" \
  -o "bt all" \
  > core_bt.txt
```

If you need extra details:
```bash
/usr/bin/lldb -c core exec --batch -o "process status" -o "image list" > core_status.txt
```

Interpretation rules:
- **Stop reason absent** → snapshot while idle (not a crash).
- **Stop reason `EXC_BAD_ACCESS` or `SIGSEGV`** → real fault; inspect the crashing thread first.
- Thread #1 inside `mach_msg` + AppKit run-loop is usually harmless unless the stop reason points elsewhere.

---

## 3. Supporting Artifacts to Collect
1. `kitty-metal.log` from the same run (if present). Provides renderer-side warnings and occlusion events.
2. macOS unified log window for the last five minutes:
   ```bash
   log show --last 5m --predicate 'process == "kitty"' > unified_kitty.log
   ```
3. Crash reports:
   ```bash
   ls -t ~/Library/Logs/DiagnosticReports/kitty*.crash | head
   ```
   If none appear, macOS may have auto-terminated before a crash. Reproduce with `ulimit -c unlimited`.

4. Record active kitty PIDs via `pgrep -fl "kitty"`; useful when correlating multiple instances.

---

## 4. Determining Next Actions
Use the following decision tree after LLDB:

| Observation | Next Step |
|-------------|-----------|
| No stop reason + AppKit run-loop | Core is idle sample — capture a new one at the actual crash. |
| Crash in `metal_renderer` / Metal frameworks | Open matching source file, check recent changes, and design targeted tests. |
| Crash in Python eval path | Inspect the Python caller (often a failing helper). |
| Thread stuck in `poll` with non-zero stop reason | Investigate native IO loops (`talk_loop`, `io_loop`). |

Always document findings (core path, stop reason, top frames, suggested fix) in your working notes and update this playbook only if the process changes.

---

## 5. Quick Commands Reference
- Build launcher: `python3.13 setup.py build-launcher`
- Run Metal GUI test: `KITTY_ENABLE_METAL_GUI_TESTS=1 ./test.py --module test_metal_helpers test_initial_blank_frame_uses_active_window_background`
- Launch debug kitty that keeps window alive:
  ```bash
  KITTY_ENABLE_METAL_GUI_TESTS=1 ./kitty.app/Contents/MacOS/kitty --debug-rendering 2>kitty-metal.log
  ```

---

## 6. Guidelines
- Never delete or modify cores before archiving essential data.
- Keep LLDB outputs (`core_bt.txt`, `core_status.txt`) under version control only if needed; otherwise stash locally.
- When you find the root cause, update the relevant source comments/tests instead of only documenting here.
- Refresh this file immediately if the triage workflow changes (new build path, different LLDB commands, etc.).

---

## 7. Future Enhancements
- Automate LLDB triage with a small script (`scripts/analyse_core.py`) that:
  - Validates magic database availability.
  - Runs `thread list`, `bt all`, `process status`.
  - Highlights stop reasons.
- Add a shell alias `kitty-core` pointing to the command bundle above.
- Investigate structured logging (`log show --style compact`) when Metal prints GPU errors.

