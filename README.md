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

The whole system on one page, from the operator's screen to the machine, read against
`caa13ca6ae`. **The evidence for what it asserts is in `LINUXCNC-FINDINGS.md`, not on the
page** — the sheet used to carry a long footnoted record of its own corrections, and that
record was moved out: a figure is for understanding, and proof belongs where proof is kept.

Two decisions shape it. **Domains are marked by lines, never by frames**: a frame asserts
membership and can be contradicted by its own geometry, as the first version was when the
frame labelled *"ordinary Linux processes"* ended above `linuxcncsvr` and `milltask`. A
line cannot make that mistake. The frames that do exist assert *process* and *thread*
membership — a fact about the running system rather than a domain — and each lies wholly
on one side of every line. **And the two shared-memory segments lie in the boundary band**
— `emcmot` at key 100 and HAL at `0x48414C32` — because each is created on one side and
attached from the other, which is what shared memory is. A configuration can create more,
and the figure names them.

**The source is [`sheets/linuxcnc-system-overview.drawio`](sheets/linuxcnc-system-overview.drawio)**,
and the HTML page is generated from it: box geometry comes from the model, connector
routing from draw.io's own SVG export, and only the `<svg>` block of the page is replaced,
so the prose around it never makes the round trip. Editing the SVG in the page by hand is a
change the next conversion deletes.

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

Expected: `304 pass, 0 fail`. On a later HEAD a FAIL usually means the line
moved — re-anchor the citation rather than assume the finding broke.

**The manifest is a curated set, not an index**, and the gap is stated rather
than hidden. Measured 2026-08-09, with the manifest at 304: `LINUXCNC-FINDINGS.md`
holds **220 distinct `file:line` citations, of which 187 have an entry at that
exact line — 85%**.

*The method, so it can be redone rather than believed:* extract every
`name.ext:NNN` from the findings with a regex, compare against the manifest on
`basename:line`. It does not resolve the shorthand the document uses when several
lines of one file are cited in a row — `emcsvr.cc:140`, `:146`, `:151` counts as
one citation, not three — so it **undercounts**. And note that **the instrument
changed here**: an earlier pass counted 193 where this one counts 198 on the same
commit. Two rulers, not growth.

The 33 without an exact-line entry are three different things, and the difference
is the point:

- **14 point at LinuxCNC's own `.adoc` documentation** — which is what this audit
  criticises and what its patches rewrite. Pinning them would guarantee a failure
  the day a patch lands, while saying nothing about the code. A check that breaks
  when you win is a bad check.
- **10 have an entry within fifteen lines of the same file.** The block is
  watched; the exact line is not.
- **9 are genuinely unwatched**, and are named here rather than left as a number:
  `control.c:333`, `control.main-pkg.in:70`, `control.top.in:119`,
  `driver.cc:571`, `hal.h:1472`, `interpmodule.cc:39`, `Makefile:745`, `motion.c:1091`,
  `pyparamclass.cc:28`.

A green run means *the manifest's* citations were re-read against the source at
the pinned commits. The script's own header used to claim it covered every
citation, and was corrected; it now points here instead of carrying its own copy
of these figures, because a number kept in two files is a number that will drift
— which is exactly what happened to it.

### The two figure checkers

The figures are checked as well as the prose, by two tools that answer different
questions and are honest about where each stops.

| Tool | Reads | Answers |
|---|---|---|
| [`tools/diagram-check.js`](tools/diagram-check.js) | the rendered SVG, in a browser | does a connector cross a box or a label, does every arrow land on something named, is any text hidden |
| [`tools/drawio-check.ps1`](tools/drawio-check.ps1) | the `.drawio` model, no dependencies | dangling edges, orphan boxes, a declared parent its geometry contradicts, the legend's own colour rules, what a connector is allowed to land on |

Routing is not in the model — draw.io computes it at display time — so line
collisions belong to the first. Fill colours, parent relations and
`source`/`target` do not survive into an SVG, so the claims the figure makes
about itself belong to the second. **Every rule in both refuses to run unless it
first fails on a deliberately broken copy**, because three of the earliest checks
written here passed everything by measuring the wrong thing.

The model checker found the sheet asserting something false about itself: the
legend printed four colour rules and the sentence *"All four hold as drawn"*, and
the fourth did not hold. The rule was wrong and the drawing was right.

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
- [`upstream/`](upstream/) — a pointer to
  [LinuxCNC PR #4349](https://github.com/LinuxCNC/linuxcnc/pull/4349), which
  carries the documentation patches this audit proposes: five commits against
  four files, reviewed and answered. The patches are not copied here, because a
  copy of a live pull request falls behind it.

Two examples of the kind of thing found: the HAL manual's `initf` example names
a funct the EtherCAT driver doesn't export, and pause is silently bypassed
during spindle-synchronized motion (G33 threading, rigid tapping) — sensible
behaviour, documented nowhere.

---

## The EtherCAT notes

[`ETHERCAT-NOTES.md`](ETHERCAT-NOTES.md) — how LinuxCNC accommodates an EtherCAT
master it does not contain. There is no EtherCAT driver in the LinuxCNC tree;
`linuxcnc-ethercat` is a separate project depending on IgH EtherLab, and the two
meet through a small number of real accommodations in LinuxCNC itself. The notes
cover that seam, the `initf` mechanism, and the RTAI question — a door that is
closed rather than a trap.

Held back until now because it was written for one reader and not checked as
hard as the sheets. It is published as it stands, with its own caveat in place:
some of its citations have no manifest entry, and it says so where it matters.

## Caveats

- Everything targets **master, which is unreleased** (newest tag `v2.10.0-pre0`,
  checked 2026-08-10; `v2.9.10` is the newest 2.9).
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
