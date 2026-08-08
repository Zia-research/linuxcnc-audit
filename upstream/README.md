# Upstream patches — prepared from the audit

Patches generated from the `docs-audit-fixes-v2` branch (`5ac93bb4b2` ·
`a8fb59b743` · `f587664ac8`, based on `dd8d0be15b`). Every change corrects a
statement that the audit in
[`../LINUXCNC-FINDINGS.md`](../LINUXCNC-FINDINGS.md) verified against the source;
the commit messages carry the `file:line` evidence.

> **⚠ These are one revision ahead of the open PR.**
> [PR #4349](https://github.com/LinuxCNC/linuxcnc/pull/4349), opened 2026-08-06,
> still carries `5ac93bb4b2` · `d152953a4d` · `859c1710f8`. On 2026-08-08
> @grandixximo reviewed it and found **two factual errors in the PAUSE
> paragraph**, both now corrected here and neither yet pushed:
> **(1)** *"Velocity-synchronized segments (G96 style)"* — it is **G95**, feed per
> revolution. `G_95` enqueues `SET_FEED_MODE(spindle, 1)`
> (`interp_convert.cc:2841-2846`), the only writer of `canon.feed_mode`
> (`emccanon.cc:521`), and the only path passing `velocity_mode = 1` to
> `START_SPEED_FEED_SYNCH` (`emccanon.cc:530`), which yields `TC_SYNC_VELOCITY`
> (`tp.c:4159-4162`). G33/G33.1/G76 all pass `0`
> (`interp_convert.cc:5505,5520,5644-5662`); G96 goes through `SET_SPINDLE_MODE`
> (`:5075-5087`) and never reaches this code.
> **(2)** *"with a non-zero MAX_JERK"* — the threshold is **1.0**, enforced in
> three places (`initraj.cc:159`, `inihal.cc:302`, `:320`), all commented *"Force
> planner type 0 if max_jerk < 1"*.
> **The commit message already carried the right threshold** — *"forced back to 0
> when jerk is below 1.0"* — so the patch contradicted its own evidence for two
> days. The correction was written once, in the message and in a
> [comment on #3718](https://github.com/LinuxCNC/linuxcnc/pull/3718#issuecomment-5206092235),
> and never propagated to the document text.
> **Still open from the same review**, deliberately not changed here: the ENABLE
> *Requirements* sentence says *"the hardware enable chain must be satisfied"*,
> which overstates — `motion.enable` is created with default `1`
> (`motion.c:528`), under a source comment saying so, so an unconnected pin reads
> TRUE and the rejection at `command.c:1372` never fires on a normal machine.

## Contents

| Patch | Fixes | Errata |
|---|---|---|
| `0001-docs-initf-example-funct-is-lcec.activate-not-lcec.0.patch` | `docs/src/hal/basic-hal.adoc` — the `initf` example names a funct (`lcec.0.activate`) that the lcec driver does not export; the real name is `lcec.activate` (global, not per-master). Fixed in both the prose and the example block. | §2.9.5 |
| `0002-docs-code-notes-correct-stale-and-self-contradictory.patch` | `docs/src/code/code-notes.adoc` — seven corrections: buffer types (FILEMEM/GLOBMEM don't exist, RTLMEM is rejected), OVERRIDE_LIMITS "currently broken" note (bug long fixed), the 2020 command-count note (73/70 → 76/73), PAUSE semantics (mid-segment deceleration + the spindle-sync exception), ENABLE and STEP false "Requirements: None", the EMCIO chapter self-contradiction, the stale initraj.cc bug pointer. | 15, 16, 17, 19, 21, 22, 23, 25 |
| `0003-docs-g-code-align-G33-G33.1-G64-and-G96-error-lists-.patch` | `docs/src/gcode/g-code.adoc` — G33/G33.1: replaces a phantom error ("exceeds machine velocity limits", implemented nowhere) with the two real, undocumented ones (K required, F forbidden) and states that "spindle not turning" means the commanded M3/M4 state; G33.1 I-word <1 clamp; G64: path-mode change is an error under cutter comp; G96: removes a second phantom error and documents the no-D behaviour (no RPM limit). | 26, 27 |

## How to use

```bash
# from a linuxcnc checkout on a fresh branch
git am path/to/0001-*.patch path/to/0002-*.patch
```

Or apply without committing: `git apply --check` first, then `git apply`.

The branches also exist locally: `docs-audit-fixes-v2` is what these patches were
generated from, and `docs-audit-fixes` is kept unchanged as the revision the open
PR still carries.

## Suggested PR framing

One PR titled e.g. *"docs: correct stale statements found by auditing the Code
Notes against the source"*. Points worth making in the description:

- The Code Notes open by admitting they are outdated; these are point fixes for
  the statements that are now provably wrong, each verified against the current
  source (citations in the commit messages).
- Two of the fixes remove **bug reports for bugs that were fixed years ago**
  (OVERRIDE_LIMITS, initraj.cc) — the failure mode where the document records
  defects but never their repair.
- The PAUSE change adds an operator-relevant fact documented nowhere else:
  pause is bypassed while a segment is position-synchronized to the spindle
  (threading, rigid tapping).
- The lcec funct-name fix (patch 0001) is independent and could be split out if
  preferred; it is the one most likely to bite users directly.

## Caveats before submitting

- The commits are based on `dd8d0be15b` (master, 2026-08-06). They also apply
  cleanly on the audited `caa13ca6ae` — the three target files are identical at
  both bases, and `git patch-id` is identical before and after the rebase.
  Verified both ways: `git apply --check`, then a real apply with the produced
  text read back.
- The PAUSE and command-count wording describes **master** behaviour. If the
  docs team wants 2.9-applicable wording, the command-count note (76/73) is the
  only figure that differs — check `cmd_code_t` on the 2.9 branch first.
- LinuxCNC docs are AsciiDoc; both files build with the normal docs toolchain,
  but a `make docs` smoke test before submitting is prudent.
