# Upstream — where the patches live

The corrections this audit proposes to LinuxCNC's documentation are on a pull
request, and **the pull request is the authority**:

### [LinuxCNC PR #4349](https://github.com/LinuxCNC/linuxcnc/pull/4349)

Opened 2026-08-06 · reviewed by @grandixximo 2026-08-08 · answered 2026-08-09 ·
five commits against four files.

| File | What it corrects | Errata |
|---|---|---|
| `docs/src/code/code-notes.adoc` | buffer types (FILEMEM/GLOBMEM do not exist, RTLMEM is rejected), the `OVERRIDE_LIMITS` "currently broken" note for a bug fixed years ago, the 2020 command-count note, PAUSE semantics and the spindle-sync exception, the false *"Requirements: None"* on ENABLE and STEP, the EMCIO chapter's self-contradiction, the stale `initraj.cc` bug pointer | 15, 16, 17, 19, 21, 22, 23, 25 |
| `docs/src/gcode/g-code.adoc` | G33/G33.1 error lists — a phantom error replaced by the two real, undocumented ones; G64 under cutter comp; G96's second phantom error and the no-`D` behaviour | 26, 27 |
| `docs/src/config/ini-config.adoc` | the S-curve jerk threshold is **1.0**, not "non-zero" | — |
| `docs/src/hal/basic-hal.adoc` | the `initf` example names a funct the EtherCAT driver does not export: `lcec.activate`, not `lcec.0.activate` | §2.9.5 |

To apply them, take them from the PR rather than from a copy:

```bash
gh pr diff 4349 --repo LinuxCNC/linuxcnc > 4349.diff
git apply --check 4349.diff
```

---

## Why this directory no longer carries `.patch` files

It did until 2026-08-10, and they had stopped matching the PR. They held the
first **three** of its five commits — the two that answer the review were
missing — and the README beside them still announced that the corrections were
"neither yet pushed", that the PR "still carries `859c1710f8`", and that a
sentence the review had already removed was "still open".

Every one of those statements was true when it was written and false three days
later. **A copy that has to be kept in step with a live pull request is a copy
that will silently fall behind**, and a reader has no way of telling which of
the two is current. So there is one place to look now, and it is the one that
cannot go stale.

The audit's own record of what was submitted, and why, is in
[`../LINUXCNC-FINDINGS.md`](../LINUXCNC-FINDINGS.md) — the errata with their
`file:line` evidence, and the changelog entry for each pass.
