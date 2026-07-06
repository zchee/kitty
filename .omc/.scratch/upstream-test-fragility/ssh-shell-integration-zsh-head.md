# test_ssh_shell_integration breaks under zsh-master's native OSC 133

Status: ready-for-human

`kitty_tests/ssh.py::test_ssh_shell_integration` (the
shell-integration-disabled cases) asserts `b'\x1b]133;'` never appears
in the pty byte stream. zsh master (observed with
`zsh 5.9.999.3-test [zsh-5.9.0.3-test-402-g843a291]`, homebrew
`zsh-head`) now emits OSC 133 semantic-prompt marks natively
(`133;A;cl=m;<nonce>`, `133;P;k=i`, `133;B/C/D`) whenever the terminal
answers its startup capability probes — with kitty integration fully
disabled and a clean sandbox HOME. On machines whose PATH-first `zsh`
is a dev build, the test fails (timing-modulated, since the marks arm
only after the query round-trips).

Full forensics with probe commands:
`.omc/verify/phase12/results/ssh-test-env-failure.md`.

Human decision: report upstream to kovidgoyal/kitty (test could pin
`/bin/zsh`, filter dev builds, or scope the assertion to kitty's own
mark formats) — and/or drop `zsh-head` from PATH-first on this machine.
Once zsh 5.10 ships with native marks, this bites everyone.
