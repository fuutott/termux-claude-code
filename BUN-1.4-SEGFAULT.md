# Claude Code / Bun 1.4.0 startup segfault on Termux (aarch64 + glibc-runner)

Investigation log, 2026-06-22. Device: Samsung Fold6, Termux + glibc-runner,
Linux kernel 6.6.98-android15, glibc 2.42, aarch64.

## TL;DR

- Claude Code's native build **>= 2.1.181 segfaults at startup** on this setup.
- **Last good: `2.1.179`. First bad: `2.1.181`.** (No `2.1.180`/`2.1.184` were ever
  published; `.182 .183 .185 .186` all crash too.)
- Cause: **2.1.181 bumped the bundled Bun runtime to 1.4.0**, which null-derefs
  during its **HTTP-thread event-loop init**. 2.1.179 ships an older Bun (1.3.x)
  that works.
- Not fixable from our side (it's a NULL deref inside compiled Bun runtime code).
- Mitigation in this repo: `install.sh` pins to 2.1.179 and disables auto-update;
  `try-upgrade.sh` canary-tests newer builds and auto-promotes the first that works.

## How we found it

`--version` and `--help` exit cleanly on **every** version, including the broken
ones — the crash only fires on the full interactive/TUI runtime path. So the
bisect had to launch each candidate **interactively under a pty** (isolated HOME,
no live binary touched) and watch ~12s for a SIGSEGV / Bun crash banner.

| Version | `--version` | Interactive init (pty) |
|---------|-------------|------------------------|
| 2.1.179 | ok          | OK — survives (last good) |
| 2.1.181 | ok          | **CRASH (first bad)** |
| 2.1.182 | ok          | crash |
| 2.1.183 | ok          | crash |
| 2.1.185 | ok          | crash |
| 2.1.186 | ok          | crash |

## strace evidence (2.1.181)

The real fault is a **null-pointer read in userspace**, not a blocked syscall.
No `io_uring`, `rseq`, `clone3`, `membarrier`, `landlock`, `userfaultfd`, `memfd`,
and **no `SIGSYS`** anywhere in the trace — the glibc-runner shim served every
syscall fine. The trailing `SIGTRAP`/"killed by SIGTRAP" lines are just Bun's own
crash reporter tearing down threads.

Faulting thread, last syscalls before the crash (it was building an epoll loop):

```
epoll_create1(EPOLL_CLOEXEC)            = 13
timerfd_create(CLOCK_MONOTONIC, ...)    = 14
eventfd2(0, ...)                        = 15
epoll_ctl(13, EPOLL_CTL_ADD, 15, ...)   = 0
...
mmap(NULL, 4096, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0) = 0x791b2e5000
madvise(0x791b2e5000, 4096, 0xffffffff /* MADV_??? */) = -1 EINVAL   # benign probe
madvise(0x791b2e5000, 4096, MADV_WIPEONFORK)           = 0
getrandom(...)                                                       # seeding
timerfd_settime(14, 0, {it_interval=4s, it_value=4s}, ...) = 0
epoll_ctl(13, EPOLL_CTL_ADD, 14, ...)                  = 0
--- SIGSEGV {si_signo=SIGSEGV, si_code=SEGV_MAPERR, si_addr=NULL} ---
```

Note: the SIGSEGV lands **after** `epoll_ctl(ADD)` and **before** the first
`epoll_pwait2` syscall is issued — i.e. in userspace setup, on the first `tick`.
Concurrently a sibling thread had just opened an `AF_NETLINK/NETLINK_ROUTE` socket
(glibc resolver init) and another was PATH-scanning for `npm`/`bun`. Classic
multi-threaded startup; the HTTP thread faults reading a null loop/state pointer.

## Decoded crash stack (bun.report)

```
Bun 1.4.0 · linux aarch64 [StandaloneExecutable] · SIGSEGV @ 0x00000000

  sys_epoll_pwait2                                     linux.rs:38       <- faulting frame
  bun_epoll_pwait2                                     epoll_kqueue.c:142
  us_loop_run_bun_tick                                 epoll_kqueue.c:391
  tick                                                 Loop.rs:249
  bun_http::http_thread::HttpThread::process_events    HTTPThread.rs:1372
  on_start                                             HTTPThread.rs:1336
  {closure#0}                                          HTTPThread.rs:1240
  std::sys::thread::unix::Thread::thread_start         unix.rs:118
```

Crash report URL (encodes the stack; opens on bun.report):
`https://bun.report/1.4.0/L_1324c5f0kgggkEugogC2pl8Buxz0uCm12//C+00//C2pl9kCmxy8kCu6x8kC+q275B+ytiB2568BA2AA`

**Signature:** Bun 1.4.0 standalone, linux aarch64 — SIGSEGV (null) at startup in
`us_loop_run_bun_tick` / `bun_epoll_pwait2`, on the `HttpThread` (`on_start`).
Bun 1.4.0 moved the Linux event loop to the newer `epoll_pwait2` syscall; this
path is new in 1.4.0 and is where it dies.

## Is it already reported?

No exact match found (2026-06-22). The broad "Claude Code segfaults under Bun" is
heavily reported, but every prominent issue differs from ours on the two details
that matter:

- **Thread:** all public reports crash on the **main thread** (JS engine — WASM
  interpreter or JSC GC). Ours is on the **HTTP thread** (uSockets event loop).
- **Timing:** most are **long-session** crashes (32 min / 53 min / ~3 h). Ours is
  **deterministic at startup**, every launch.

Checked: bun#24963 (x64, main, WASM), bun#24357 (macOS, main, JSC GC),
bun#26843 (macOS, main, 53min), claude-code#27699 (x64 glibc2.41, main, ~3h).
None mention `us_loop_run_bun_tick`/`bun_epoll_pwait2`/`HttpThread`.

Not filing upstream: Bun does not support Android/Termux as a platform and closes
those issues as unsupported. See "Future" below for the one thing that would make
a report actionable.

## Future: confirming whether it's a real aarch64+glibc bug vs a Termux artifact

We run the **glibc** Bun build under glibc-runner on a stock Linux aarch64 kernel
— not bionic. So this *might* be a genuine aarch64 + glibc-2.42 Bun bug, not a
Termux quirk. To know, reproduce 2.1.181+ (or just a standalone Bun 1.4.0 build)
on a **non-Termux aarch64 + glibc box**:

- Snapdragon X laptop (currently Windows) booted into / running Linux aarch64, or
- Raspberry Pi on a recent glibc (aim for glibc 2.41/2.42 if possible).

If it crashes there too → real Bun bug, worth a clean upstream report using the
signature above. If it only happens under glibc-runner → likely shim-specific,
and the pin + canary strategy is the permanent answer.

No time to test as of writing; revisit if it stays unfixed.

## Current mitigation (live)

- Live `claude` runs pinned **2.1.179** via glibc-runner; wrapper auto-update OFF
  (`CLAUDE_SKIP_UPDATE` defaults to 1). See `install.sh`.
- `./try-upgrade.sh [version]` — stages a candidate, runs the pty interactive
  smoke test, and only promotes it on a clean pass. Backs up the pin first.
- To re-test latest anytime: `./try-upgrade.sh` (safe; keeps the pin if it fails).
