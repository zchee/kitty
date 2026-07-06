Performance
===================

The main goals for |kitty| performance are user perceived latency while typing
and "smoothness" while scrolling as well as CPU usage. |kitty| tries hard to
find an optimum balance for these. To that end it keeps a cache of each
rendered glyph in video RAM so that font rendering is not a bottleneck.
Interaction with child programs takes place in a separate thread from
rendering, to improve smoothness. Parsing of the byte stream is done using
`vector CPU instructions
<https://en.wikipedia.org/wiki/Single_instruction,_multiple_data>`__ for
maximum performance. Updates to the screen typically require sending just a few
bytes to the GPU.

There are two config options you can tune to adjust the performance,
:opt:`repaint_delay` and :opt:`input_delay`. These control the artificial delays
introduced into the render loop to reduce CPU usage. See
:ref:`conf-kitty-performance` for details. See also the :opt:`sync_to_monitor`
option to further decrease latency at the cost of some `screen tearing
<https://en.wikipedia.org/wiki/Screen_tearing>`__ while scrolling.

Benchmarks
-------------

Measuring terminal emulator performance is fairly subtle, there are three main
axes on which performance is measured: Energy usage for typical tasks,
Keyboard to screen latency, and throughput (processing large amounts of data).

Keyboard to screen latency
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

This is measured either with dedicated hardware, or software such as `Typometer
<https://pavelfatin.com/typometer/>`__. Third party measurements comparing
kitty with other terminal emulators on various systems show kitty has best in
class keyboard to screen latency.

Note that to minimize latency at the expense of more energy usage, use the
following settings in kitty.conf::

    input_delay 0
    repaint_delay 2
    sync_to_monitor no
    wayland_enable_ime no

`Hardware based measurement on macOS
<https://thume.ca/2020/05/20/making-a-latency-tester/>`__ show that kitty and
Apple's Terminal.app share the crown for best latency. These
measurements were done with :opt:`input_delay` at its default value of ``3 ms``
which means kitty's actual numbers would be even lower.

`Typometer based measurements on Linux
<https://github.com/kovidgoyal/kitty/issues/2701#issuecomment-911089374>`__
show that kitty has far and away the best latency of the terminals tested.

.. _throughput:

Throughput
^^^^^^^^^^^^^^^^

kitty has a builtin kitten to measure throughput, it works by dumping large
amounts of data of different types into the tty device and measuring how fast
the terminal parses and responds to it. The measurements below were taken with
the same font, font size and window size for all terminals, and default
settings, on the same computer. They clearly show kitty has the fastest
throughput. To run the tests yourself, run ``kitten __benchmark__`` in the
terminal emulator you want to test, where the kitten binary is part of the
kitty install.

The numbers are megabytes per second of data that the terminal
processes. Measurements were taken under Linux/X11 with an ``AMD Ryzen 7 PRO
5850U``. Entries are in order of decreasing performance. kitty is twice
as fast as the next best.

================   ======  ======= ===== ====== =======
Terminal           ASCII   Unicode CSI   Images Average
================   ======  ======= ===== ====== =======
kitty 0.33         121.8   105.0   59.8  251.6  134.55
gnometerm 3.50.1   33.4    55.0    16.1  142.8  61.83
alacritty 0.13.1   43.1    46.5    32.5  94.1   54.05
wezterm 20230712   16.4    26.0    11.1  140.5  48.5
xterm 389          47.7    18.3    0.6   56.3   30.72
konsole 23.08.04   25.2    37.7    23.6  23.4   27.48
alacritty+tmux     30.3    7.8     14.7  46.1   24.73
================   ======  ======= ===== ====== =======

In this table, each column represents different types of data. The CSI column
is for data consisting of a mix of typical formatting escape codes and some
ASCII only text.

.. note::

   By default, the benchmark kitten suppresses actual rendering, to better
   focus on parser speed, you can pass it the ``--render`` flag to not suppress
   rendering. However, modern terminals typically render asynchronously,
   therefore the numbers are not really useful for comparison, as it is just a
   game about how much input to *batch* before rendering the next frame.
   However, even with rendering enabled kitty is still faster than all the
   rest. For brevity those numbers are not included.

.. note::

   foot, iterm2 and Terminal.app are left out as they do not run under X11.
   Alacritty+tmux is included just to show the effect of putting a terminal
   multiplexer into the mix (halving throughput) and because alacritty isn't
   remotely comparable to any of the other terminals feature wise without tmux.

.. note::

   konsole, gnome-terminal and xterm do not support the `Synchronized update
   <https://gitlab.com/gnachman/iterm2/-/wikis/synchronized-updates-spec>`__
   escape code used to suppress rendering, if and when they gain support for it
   their numbers are likely to improve by ``20 - 50%``, depending on how well they
   implement it.


Energy usage
^^^^^^^^^^^^^^^^^

Sadly, I do not have the infrastructure to measure actual energy usage so CPU
usage will have to stand in for it. Here are some CPU usage numbers for the
task of scrolling a file continuously in :program:`less`. The CPU usage is for
the terminal process and X together and is measured using :program:`htop`. The
measurements are taken at the same font and window size for all terminals on a
``Intel(R) Core(TM) i7-4820K CPU @ 3.70GHz`` CPU with a ``Advanced Micro
Devices, Inc. [AMD/ATI] Cape Verde XT [Radeon HD 7770/8760 / R7 250X]`` GPU.

==============   =========================
Terminal         CPU usage (X + terminal)
==============   =========================
|kitty|          6 - 8%
xterm            5 - 7% (but scrolling was extremely janky)
termite          10 - 13%
urxvt            12 - 14%
gnome-terminal   15 - 17%
konsole          29 - 31%
==============   =========================

As you can see, |kitty| uses much less CPU than all terminals, except xterm, but
its scrolling "smoothness" is much better than that of xterm (at least to my,
admittedly biased, eyes).

Apple Silicon / Metal backend
--------------------------------

The macOS Metal backend (``KITTY_USE_METAL=1`` builds) was optimized and
measured in 2026 on an Apple M3 Max (macOS 27, 60 Hz laptop display,
default config and font, 100×30 cell window unless stated). Methodology:
same-machine interleaved A/B arms, medians over repeated runs, load
average recorded per run and elevated-load captures flagged rather than
dropped; the full fairness protocol (identical grids/fonts, visible
unoccluded windows, byte-identical workloads, warmup/teardown discipline)
is kept in the repository alongside the raw JSON artifacts.

Highlights, each measured against a same-binary kill-switch arm so the
change under test is the only variable:

- **Input latency** (PTY-write→present, the harness-measurable proxy for
  echo latency): median ≈ **15 ms** with the asynchronous IOSurface
  presentation path, down from ≈ 26 ms with the synchronous present and
  ≈ 64–79 ms with the original display-link pacing — and the ~200 ms
  link-resume tail is gone entirely.
- **Throughput** (``kitten __benchmark__ --render``): ASCII ≈ 147 MB/s
  and ASCII+scrollback ≈ 111 MB/s at 100×30 after the batched ASCII
  run-fill (1.30×/1.20× over the same binary with the fill disabled);
  Unicode ≈ 130 MB/s after the batched width-2 run fill (+6.8% over the
  fill-disabled arm; it was ≈ 121 MB/s before).
- **Flood behavior**: sustained full-screen updates encode at the display
  refresh rate (cadence p50 = p99 = 16.67 ms at 60 Hz) instead of
  free-running, with zero transient buffer or texture allocations per
  steady-state frame, including during GIF animation.
- **Memory**: the glyph atlas stores monochrome glyphs as single-channel
  masks — 4× smaller than the previous RGBA atlas for the monochrome set
  (−72% total atlas bytes on a text+emoji workload) with byte-identical
  rendered output.
- **1-line edit cost**: ≈ 2.2 KB uploaded per typed-character frame
  (dirty-row uploads), versus a full-grid upload previously.

Same-machine comparison (Apple M3 Max; kitty 0.47.4-dev, Alacritty
0.17.0, Ghostty 1.3.1; 100×30 cells, default configs, interleaved arms,
2026-07-06; **all runs under elevated system load (loadavg ≈ 8–14),
flagged per protocol** — treat as indicative until quiet-machine
replication):

===============  =========================  ==========================
Terminal         devlog-006 (54 MB JP)      full-grid churn drain
===============  =========================  ==========================
Alacritty        **0.435 s** (0.427–0.444)  **≈ 62 MB/s**
Ghostty          0.484 s (0.446–0.767)      ≈ 47 MB/s
kitty (Metal)    0.496 s (0.479–0.500)      ≈ 52 MB/s
kitty (OpenGL)   0.500 s (0.499–0.512)      ≈ 51 MB/s
===============  =========================  ==========================

The devlog-006 gap decomposes cleanly (three-way interleave, medians):
of kitty's **17.2%** deficit to Alacritty, **6.0%** is kitty's
:opt:`input_delay` input-batching policy (a deliberate energy/latency
trade — with ``input_delay 0`` kitty measures 0.470 s on the same
workload) and the remaining **10.6%** is structural: kitty parses and
renders on one thread where Alacritty parses on a dedicated thread.
Parser-stage CPU is *not* the limiter — halving the draw-loop self-time
moved this wall by under 1% — which is also why the Metal and OpenGL
backends measure equal here: the pty→parse pipeline, not rendering,
bounds this axis. (An earlier revision of this table showed Metal ~13%
ahead of OpenGL on devlog-006; that delta does not reproduce under
same-window interleaving and is attributed to load-window confounding.
The backend's wins are on the latency, CPU-per-frame, and memory axes
above, which are same-binary kill-switch-anchored.)

`vtebench <https://github.com/alacritty/vtebench>`__ (subset, median
ms per ~1 MiB sample, lower is better, same conditions):

===============  ============  =========  ========
Terminal         dense_cells   scrolling  unicode
===============  ============  =========  ========
Alacritty        7             26         6
Ghostty          8             20         8
kitty (Metal)    15            69         9
===============  ============  =========  ========

kitty trails on vtebench's SGR-dense and scrolling patterns; the
scrolling gap aligns with the profiled scroll-machinery share
(history-buffer line copy) and is queued for analysis. Energy
(powermetrics) columns will be added when captured.

Instrumenting kitty
-----------------------

You can generate detailed per-function performance data using
`gperftools <https://github.com/gperftools/gperftools>`__. Build |kitty| with
``make profile``. Run kitty and perform the task you want to analyse, for
example, scrolling a large file with :program:`less`. After you quit, function
call statistics will be displayed in *KCachegrind*. Hence, profiling is best done
on Linux which has these tools easily available.
