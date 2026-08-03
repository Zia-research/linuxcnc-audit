# Upstream patches â€” prepared from the audit

Patches generated from the `audit-fixes` branch of the local clone (based on
`master` at `caa13ca6ae`). Every change corrects a statement that the audit in
[`../LINUXCNC-FINDINGS.md`](../LINUXCNC-FINDINGS.md) verified against the source;
the commit messages carry the `file:line` evidence.

**Submission is yours to do** â€” under your own GitHub identity, as agreed.
Nothing here has been sent anywhere.

## Contents

| Patch | Fixes | Errata |
|---|---|---|
| `0001-docs-initf-example-funct-is-lcec.activate-not-lcec.0.patch` | `docs/src/hal/basic-hal.adoc` â€” the `initf` example names a funct (`lcec.0.activate`) that the lcec driver does not export; the real name is `lcec.activate` (global, not per-master). Fixed in both the prose and the example block. | Â§2.9.5 |
| `0002-docs-code-notes-correct-stale-and-self-contradictory.patch` | `docs/src/code/code-notes.adoc` â€” seven corrections: buffer types (FILEMEM/GLOBMEM don't exist, RTLMEM is rejected), OVERRIDE_LIMITS "currently broken" note (bug long fixed), the 2020 command-count note (73/70 â†’ 76/73), PAUSE semantics (mid-segment deceleration + the spindle-sync exception), ENABLE and STEP false "Requirements: None", the EMCIO chapter self-contradiction, the stale initraj.cc bug pointer. | 15, 16, 17, 19, 21, 22, 23, 25 |
| `0003-docs-g-code-align-G33-G33.1-G64-and-G96-error-lists-.patch` | `docs/src/gcode/g-code.adoc` â€” G33/G33.1: replaces a phantom error ("exceeds machine velocity limits", implemented nowhere) with the two real, undocumented ones (K required, F forbidden) and states that "spindle not turning" means the commanded M3/M4 state; G33.1 I-word <1 clamp; G64: path-mode change is an error under cutter comp; G96: removes a second phantom error and documents the no-D behaviour (no RPM limit). | 26, 27 |

## How to use

```bash
# from a linuxcnc checkout on a fresh branch
git am path/to/0001-*.patch path/to/0002-*.patch
```

Or apply without committing: `git apply --check` first, then `git apply`.

The branch also exists locally: `git -C linuxcnc log master..audit-fixes`.

## Suggested PR framing

One PR titled e.g. *"docs: correct stale statements found by auditing the Code
Notes against the source"*. Points worth making in the description:

- The Code Notes open by admitting they are outdated; these are point fixes for
  the statements that are now provably wrong, each verified against the current
  source (citations in the commit messages).
- Two of the fixes remove **bug reports for bugs that were fixed years ago**
  (OVERRIDE_LIMITS, initraj.cc) â€” the failure mode where the document records
  defects but never their repair.
- The PAUSE change adds an operator-relevant fact documented nowhere else:
  pause is bypassed while a segment is position-synchronized to the spindle
  (threading, rigid tapping).
- The lcec funct-name fix (patch 0001) is independent and could be split out if
  preferred; it is the one most likely to bite users directly.

## Caveats before submitting

- Patches are against `master` (`caa13ca6ae`, 2026-07-30). Rebase if master has
  moved: `git fetch && git rebase origin/master` on the branch.
- The PAUSE and command-count wording describes **master** behaviour. If the
  docs team wants 2.9-applicable wording, the command-count note (76/73) is the
  only figure that differs â€” check `cmd_code_t` on the 2.9 branch first.
- LinuxCNC docs are AsciiDoc; both files build with the normal docs toolchain,
  but a `make docs` smoke test before submitting is prudent.
