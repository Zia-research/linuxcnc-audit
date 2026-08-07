# linuxcnc-audit

**Visual documentation of how LinuxCNC actually works inside** — made while
learning the system before a first machine build, and shared in case it helps
someone else arriving here.

Four self-contained HTML sheets, plus the verification work that backs them:
everything shown was read in the source, and every claim carries a `file:line`
citation that a script re-checks.

| | |
|---|---|
| Read against | `LinuxCNC/linuxcnc` @ `caa13ca6ae` (master, 2.10.0~pre1, 2026-07-30) |
| | `linuxcnc-ethercat/linuxcnc-ethercat` @ `87a72a8` (2026-08-03) |
| Licence | GPL-2.0 |

---

## The sheets

All four are single HTML files with no dependencies — download and open in
any browser. *(GitHub shows HTML as source rather than rendering it; use
**Download raw file**, or clone the repository.)*

### [`sheets/linuxcnc-command-flow.html`](sheets/linuxcnc-command-flow.html)

An animated sheet following one command the whole way through:

```
.ngc → Interp → canon → interp_list → task → usrmotintf
     → emcmot shared segment → motion-command-handler → tpAddLine
     → TC_QUEUE → tpRunCycle → inverse kinematics → output_to_hal
     → HAL → pid → stepgen → hostmot2 → motor
```

…and the feedback path climbing back up. Hover any block to see its role and
the source file that implements it. Three detail panels come with it:

- **The servo cycle as a ring** — all 18 steps in the real call order, from
  `head++` opening the seqlock to `tail = head` closing it.
- **The seven position representations** — `carte_pos_cmd` down to
  `carte_pos_fb`, with the transformation between each, as a closed loop.
- **Buffer capacities, to scale** — the trajectory queue and the HAL block
  outweigh the NML channels by roughly a thousand to one. The dialogue between
  operator and machine fits in a few kilobytes; looking *ahead* of the motion
  is what costs memory.

### [`sheets/linuxcnc-code-notes-errata.html`](sheets/linuxcnc-code-notes-errata.html)

The architecture diagram from the Code Notes redrawn as published, next to a
corrected version reflecting the current source, with the joint-controller
diagram audited alongside.

### [`sheets/linuxcnc-context-diagram.html`](sheets/linuxcnc-context-diagram.html)

The C4 context diagram merged by LinuxCNC PR #3781, in three states: as
published, with its two connection errors corrected in red — the terminal
tools' only link points at the core when two of the three are HAL clients, and
the embedded panels lack the HAL link that is their entire purpose — and
rebuilt from the source. The page records its own verification passes and the
corrections they forced on it, including one error of exactly the class it
criticises.

### [`sheets/linuxcnc-system-overview.html`](sheets/linuxcnc-system-overview.html)

The whole system on one page, from the operator's screen to the machine. It began as a
merge of the two sheets above — Sheet B for component detail, the context sheet's
rebuilt view for the seams — and has been corrected seven times since.

Two decisions shape it. **There are no domain containers**: a frame asserts membership
and can be contradicted by its own geometry, as the first version was when the frame
labelled *"ordinary Linux processes"* ended above `linuxcncsvr` and `milltask`. A dashed
line cannot make that mistake, so the boundary is a line and nothing else, labelled on
each side. **And the two shared-memory segments are drawn across it** — `emcmot` at key
100 and HAL at `0x48414C32` — because each is created on one side and attached from the
other, which is what shared memory is.

Both network doors are drawn, because a door that is not shown is a door nobody thinks
about, and they are not alike: `linuxcncrsh` is a telnet server on TCP 5007 speaking
plain text, reachable from anything with a socket, while a remote NML client needs
`libnml` and in practice another Linux. Red marks what is wrong rather than what is,
including one note printed *unverified* because it is.

---

## The verification behind them

Written with the help of an AI assistant (Claude), under a deliberate
discipline: nothing claimed without being read in the source, every statement
carrying a citation, and the citations themselves machine-checked.

```
git clone https://github.com/LinuxCNC/linuxcnc.git
git clone https://github.com/linuxcnc-ethercat/linuxcnc-ethercat.git
git -C linuxcnc checkout caa13ca6ae
git -C linuxcnc-ethercat checkout 87a72a8
powershell -File linuxcnc-audit/tools/verify-citations.ps1
```

Expected: `190 pass, 0 fail`. On a later HEAD a FAIL usually means the line
moved — re-anchor the citation rather than assume the finding broke.

The script also checks itself against the documents: if any file here tells you
to expect a number the manifest no longer holds, it says so and exits non-zero.
That check exists because the mistake was made twice — the count grew, and was
updated where it was remembered and left stale where it was not, including in
this README.

The same discipline was turned on this work itself. Every verification pass is
recorded in the findings file's changelog, with the original wording preserved
where a correction reversed it — including the passes that found errors in the
audit rather than in LinuxCNC. There have been several: the first two corrected
twelve of their own findings before any of this was published, and later ones
caught a count that had gone stale in two places and an overstated claim about
motion. The changelog is the authority on how many and what they found; it is
deliberately not summarised as a number here, for exactly the reason recorded
in the 2026-08-04 entry.

---

## What the verification turned up

The Code Notes open by warning that *"much of this information is now outdated
and has never been reviewed for accuracy."* Taking that at its word surfaced a
number of places where the documentation and the source have drifted apart.
Most are harmless; a few would bite someone.

- [`LINUXCNC-FINDINGS.md`](LINUXCNC-FINDINGS.md) — the knowledge base:
  architecture facts (NML, HAL, the `emcmot` segment, queues, the servo cycle,
  EtherCAT), the errata with their evidence, the points that check out
  unchanged, what remains unverified, and the changelog.
- [`motion-commands-reference.md`](motion-commands-reference.md) — all 76
  motion commands read from `command.c`, with handler locations and rejection
  conditions. The Code Notes document 27 of them.
- [`upstream/`](upstream/) — the three documentation patches submitted as
  [LinuxCNC PR #4349](https://github.com/LinuxCNC/linuxcnc/pull/4349), exactly
  as sent.

Two examples of the kind of thing found: the HAL manual's `initf` example names
a funct the EtherCAT driver doesn't export, and pause is silently bypassed
during spindle-synchronized motion (G33 threading, rigid tapping) — sensible
behaviour, documented nowhere.

---

## Caveats

- Everything targets **master, which is unreleased** (newest tag `v2.9.10`).
  Most of it holds for 2.9 too; the exceptions are flagged in the findings file
  — notably that on 2.9.x, `iocontrol` is still a separate process.
- The G-code reference was **sampled**, not audited whole: G33/G33.1, G76, G64,
  G96 out of a 2 786-line document.
- Citations were true at the recorded HEADs. The verifier exists precisely
  because they rot.
- I'm new to this codebase. Corrections welcome — that's rather the point of
  publishing it.

## Licence

GPL-2.0 (see [`LICENSE`](LICENSE)) — the patches derive from LinuxCNC's
GPL-2.0 documentation, and the findings quote its source.
