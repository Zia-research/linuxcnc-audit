# EtherCAT with LinuxCNC — integration notes

Everything read in the source, nothing from forum lore. Companion to
`LINUXCNC-FINDINGS.md`, which holds the audit trail; this file holds what someone
actually building an EtherCAT machine needs.

| | |
|---|---|
| Read against | `LinuxCNC/linuxcnc` @ `caa13ca6ae` (master, 2.10.0~pre1) |
| | `linuxcnc-ethercat/linuxcnc-ethercat` @ `87a72a8` |
| Audit trail | `LINUXCNC-FINDINGS.md` §2.9 and §5.4–5.7 |
| Status | **nothing here has been tested on hardware.** It is what the code says. |

---

## 1. The short version

**LinuxCNC ships no EtherCAT driver.** No source file speaks the protocol. The
driver, `lcec`, is a separate project under separate maintainers, and it sits on
the IgH EtherLab master. The Debian package description nonetheless advertises
EtherCAT support.

**The servo cycle is not special.** EtherCAT slots into the same read-compute-write
bracket as a Mesa card. If you know how a hostmot2 machine is wired, you know how
an EtherCAT one is.

**Three things are special**, and all three are about *time*:

1. HAL reserves the first pass of every thread for an init cycle, and the stated
   reason is EtherCAT — keeping the master's frame clear of SYNC0.
2. There are two master-activation paths, and the clean one is not used by any
   shipped example.
3. The phase re-anchoring is a `uspace` primitive; on RTAI it is a stub. In practice
   this decides nothing for you, because **lcec does not build for RTAI** — see §5.

**One trap that will cost you an evening:** the LinuxCNC HAL manual names a funct that
does not exist (§4.3). The RTAI question (§5) is not a trap — it is a door already shut.

---

## 2. Where the pieces live

### In LinuxCNC

| Piece | Location | What it is |
|---|---|---|
| `initf` | `hal.h:1063-1080`, `hal_lib.c:2865` | the real-time analogue of `addf` — run a funct **once**, in RT context, before any cyclic funct |
| halcmd verb | `halcmd_commands.cc:291` | `do_initf_cmd` |
| the init cycle | `hal_lib.c:3594-3632` | the first pass of every thread |
| `rtapi_task_self_resync()` | `uspace_rtapi_main.cc:1676` | re-anchors the thread's period |

`initf` exists essentially for one consumer, and that consumer is in another
repository. See §2.9.6 of the findings file — it is a rare case of an out-of-tree
component shaping in-tree real-time design.

### Outside

| | |
|---|---|
| `linuxcnc-ethercat` | the HAL driver, GPL-2.0, releases roughly monthly |
| `ethercat` | the organisation's **own fork** of the IgH EtherLab master |
| `apt` | their Debian repo — packages carry epoch `1:1.6.9-…`, so they supersede the openSUSE build on a normal `apt upgrade` |
| `esi-data` | ESI data processed to YAML |

Counts and sizes are in the findings file, §2.9.3. They are recorded once, there,
on purpose.

---

## 3. The servo cycle with EtherCAT

### The addf order, from a shipped example

`linuxcnc-ethercat/examples/swm-fm45a/swm-fm45a.hal` — a real machine, not a
testbench:

```
loadrt trivkins
loadrt [EMCMOT]EMCMOT servo_period_nsec=[EMCMOT]SERVO_PERIOD num_joints=[TRAJ]AXES
loadrt lcec
loadrt pid names=x-pid,y-pid,z-pid

addf lcec.read-all           servo-thread     # feedback in
addf motion-command-handler  servo-thread
addf motion-controller       servo-thread
addf x-pid.do-pid-calcs      servo-thread
addf y-pid.do-pid-calcs      servo-thread
addf z-pid.do-pid-calcs      servo-thread
addf lcec.write-all          servo-thread     # commands out
```

Compare `configs/by_interface/mesa/hm2-servo/hm2-servo.hal` in LinuxCNC itself:

```
addf hm2_[HOSTMOT2](BOARD).0.read   servo-thread
addf motion-command-handler         servo-thread
addf motion-controller              servo-thread
addf pid.0.do-pid-calcs             servo-thread
addf hm2_[HOSTMOT2](BOARD).0.write  servo-thread
```

**Identical.** The driver read opens the pass, the driver write closes it, and
everything between is the same on any machine.

Worth internalising if you come from a conventional PLC: **this order is not a
property of LinuxCNC.** It is the sequence of `addf` lines in your `.hal` file.
Reorder them and you reorder the machine's cycle — including into something that
reads stale feedback.

### The functs lcec exports

| Funct | Source | Note |
|---|---|---|
| `lcec.read-all` | `lcec_main.c:416` | all masters — what real configs use |
| `lcec.write-all` | `lcec_main.c:422` | all masters |
| `lcec.<master>.read` | `lcec_main.c:392` | per master |
| `lcec.<master>.write` | `lcec_main.c:398` | per master |
| `lcec.activate` | `lcec_main.c:408` | **global, not per-master** — and only exported on the initf path |

### Cycle zero

`hal_lib.c:3594`. On the first pass of a thread, `thread_task()` takes a branch it
never takes again. Its own comment states the purpose:

> re-anchor the period so the long init does not poison maxtime, does not trip the
> "unexpected realtime delay" catch-up loop, and lands the next wakeup at a clean
> period boundary (**used to keep EtherCAT send clear of SYNC0**)

#### What you write

```
initf <functname> <threadname>
```

`hal_init_funct_to_thread(funct_name, thread_name, position)` — `hal.h:1080`. The
`position` argument has the same semantics as `addf`: `+1` runs first in the init
list, `-1` last, `0` is illegal (`-EINVAL`). Guards: `-EFAULT` before HAL is
initialised, `-EPERM` while HAL is locked, `-EINVAL` on a missing name.

Nothing executes at this point. `initf` only *registers*.

#### What happens at run time

`hal_lib.c:3604`, inside `thread_task()`. The branch is taken when
`hal_data->threads_running > 0 && !thread->init_done`, which is true exactly once
per thread. Five things happen, in this order:

1. **the init list is walked and each entry called** — `hal_lib.c:3620`,
   `funct_entry->funct(funct_entry->arg, thread->period)`. The funct receives the
   thread period as its argument, exactly like a cyclic funct;
2. **nothing is timed.** The cyclic branch immediately below (`:3638`) calls
   `rtapi_get_time()`; the init branch does not. A long activation therefore cannot
   poison `maxtime`, nor trip the "unexpected realtime delay" catch-up loop;
3. **`rtapi_task_self_resync()`** (`:3623`) re-anchors the period, so the next
   wakeup lands one full period later, on a clean boundary;
4. `thread->init_done = 1` latches;
5. **the list is drained** (`:3626-3632`) — entries are removed and returned to the
   free pool, not merely marked as run.

**The cyclic funct list is not executed during this cycle.** The code says so in as
many words: *"The cyclic funct_list is intentionally NOT executed in this cycle --
the next cycle is the first clean cyclic pass."* Your first real servo pass is
cycle 1.

Registering afterwards fails loudly rather than silently: once `init_done` is set,
`hal_init_funct_to_thread` warns and returns `-EALREADY` (`hal_lib.c:2918-2927`),
which halcmd surfaces (`halcmd_commands.cc:307`). The reason it is an error and not
a no-op is in the comment: *"so config order doesn't depend on whether
`start_threads` has been issued"*.

#### The part that surprises people

The entry condition says nothing about the list being non-empty. **Every LinuxCNC
thread gives up its first pass this way, EtherCAT or not, whether or not you ever
wrote an `initf` line.** The mechanism is universal; only the reason it exists is
EtherCAT.

#### Not in 2.9

`initf` is 2.10-only. Verified against `origin/2.9` (`18c5bb5b1c`): no
`hal_init_funct_to_thread`, no halcmd verb, and not even the documentation error of
§4.3. On the official 2.9.x ISO the clean activation path cannot be exercised at
all — lcec takes the legacy path of §4.1 and says so. See findings §2.9.1.

Why the phase matters: DC slaves latch their I/O on the SYNC0 pulse. If the
master's frame drifts in phase against it, you read and write at the wrong moment
in the slave's cycle — with no error anywhere, just worse motion.

### Startup values — when they are actually written

The natural next question, and the answer is **long before `initf`, and twice
rather than once**. Three XML-declared mechanisms, all handled in the same
"initialize slaves" loop of `rtapi_app_main` — so at `loadrt lcec`, before the
master is activated (`lcec_main.c:241`; activation at `lcec_main.c:383`).

**`<sdoConfig>` is written twice, deliberately.** `lcec_write_sdo()` calls two IgH
functions in succession (`lcec_ethercat.c:384`, and `ecrt_master_sdo_download`
immediately above it):

| Call | When | Why it is there |
|---|---|---|
| `ecrt_master_sdo_download()` | **immediately, blocking** | to *know*: a non-existent SDO reports an error there and then |
| `ecrt_slave_config_sdo()` | asynchronous, stored by the master | so the value is **re-applied if the slave is power-cycled** |

The function's own doc comment gives the reasoning: without the first *"we can't
know if an error occurred"*, without the second *"the config will be lost if the
slave reboots"*. It is also why none of this can happen in realtime — the first
call blocks.

**One asymmetry worth knowing.** A complete-access SDO — `subindex ==
LCEC_CONF_SDO_COMPLETE_SUBIDX` — takes only the second route, via
`ecrt_slave_config_complete_sdo()` (`lcec_main.c:256`). **There is no synchronous
verification on that path**, so a bad complete-access SDO will not be reported at
load time the way an ordinary one is.

**`<initCmds>`** points at an external ESI file. Each `<InitCmd>` carries a
`<Transition>` — `PS` for PreOp→SafeOp in the shipped examples under
`examples/initcmds/` — so it is **the master that replays them at the named state
transition**, not LinuxCNC. **`<idnConfig>`** (Sercos-over-EtherCAT) is the same
shape: `ecrt_slave_config_idn()` (`lcec_main.c:273`) also carries a target state.

The whole order, end to end:

```
loadrt lcec   slave config; synchronous SDOs written HERE;
              SDO / IDN / InitCmds registered with the master
              (without initf: inline master activation, also here)
initf …       registers only — nothing executes
start         cycle 0: lcec.activate runs, then resync
              cycle 1: first cyclic pass
later         the master replays SDOs and InitCmds on every
              (re)configuration of a slave — after a power-cycle, say
```

So the two subjects never meet. Startup values are acyclic, mailbox-based, and
belong to the PreOp/SafeOp era; `initf` concerns only the **phase of the cyclic
frame**. Getting one right tells you nothing about the other.

---

## 4. Master activation — two paths

### 4.1 How the driver decides

`lcec` probes LinuxCNC through a **weak symbol**, so one binary serves both old and
new LinuxCNC (`lcec_main.c:37-45, 200`):

```c
#pragma weak hal_init_funct_to_thread
extern int hal_init_funct_to_thread(const char *funct_name, const char *thread_name, int position);
static int initf_supported = 0;
...
initf_supported = (&hal_init_funct_to_thread != NULL);
```

and warns when it is absent:

```
linuxcnc lacks initf support; using legacy inline activation.
DC phasing will trim via PLL. Upgrade linuxcnc for clean activation.
```

| LinuxCNC | Path | DC phase |
|---|---|---|
| ships `initf` | `lcec.activate` runs from RT context, in cycle zero | clean from the first cycle |
| lacks `initf` | activation inline in `rtapi_app_main`, at `loadrt` | **trimmed afterwards by a PLL** |

The branch is explicit in the source (`lcec_main.c:384-389`):

```c
// Activate master (only when initf is unavailable; otherwise lcec.activate
// funct does it from RT context after the user's `initf lcec.activate <thread>`).
if (!initf_supported) {
  if (lcec_activate_master(master) != 0) { goto fail2; }
}
```

### 4.2 Nobody uses the clean path

**No shipped lcec example contains an `initf` line.** Searched the whole
`examples/` tree: nothing. The driver's own `documentation/` does not mention
`initf` either.

So a user following the shipped examples gets the legacy path and the PLL trim,
on a LinuxCNC that is perfectly capable of the clean one. The only place the
facility is documented for users is the LinuxCNC HAL manual — which gets the name
wrong. See below.

*This is the most actionable thing in this file.* Whether the difference is
measurable needs hardware; the code is unambiguous that there is one.

### 4.3 The documentation error

`docs/src/hal/basic-hal.adoc:100` gives the example **`lcec.0.activate`**. The
driver exports **`lcec.activate`** — global, not per-master (`lcec_main.c:408`).
Only the cyclic functs are per-master, so `lcec.0.read` is right while
`lcec.0.activate` is not.

Copy the manual's example into a `.hal` file and you get a funct that does not
exist. Fixed by patch `0001` in `upstream/` — two lines,
not submitted.

The correct line, on a LinuxCNC that ships `initf`:

```
initf lcec.activate servo-thread
```

placed in the `.hal` file **before** `start`.

---

## 5. RTAI: a closed door, not a trap

`rtapi_task_self_resync()` is what performs the re-anchoring. It does nothing on
**either** RTAI backend:

| Backend | File | Behaviour |
|---|---|---|
| RTAI kernel | `rtapi/rtai_rtapi.c:903-916` | warns once, returns |
| RTAI uspace | `rtapi/uspace_rtai.cc:190` | warns once, returns |
| uspace POSIX | `rtapi/uspace_rtapi_main.cc:1676` | **implemented** |

The RTAI stub's own comment gives the reasoning: *"The primary consumer (EtherCAT
init via initf) runs on the uspace backend."*

**But you cannot reach this from a machine build**, and an earlier version of this note
framed it as though you could. lcec does not build for RTAI:

| Evidence | Where |
|---|---|
| kbuild/RTAI rules commented out, *"Currently disabled, and needs updated to work"* | `src/Makefile:62-76` |
| the only live `realtime` target links a userspace `lcec.so` | `src/Makefile:82,104` |
| `src/Kbuild` survives but is **stale** — three common objects against the Makefile's six | `src/Kbuild:3` vs `src/Makefile:18` |
| deprecated in the driver in release 0.9.3, March 2018 | `debian/changelog` |

So the correct statement is **unreachable, not degraded.** It stays recorded because it
is a real gap in the LinuxCNC core, and the stub's own comment says how to close it if
RTAI EtherCAT support is ever wanted.

`uspace` on PREEMPT_RT is the default build, and for EtherCAT it is the only build.

*Corrected 2026-08-06*, after grandixximo filed issue #1 against §2.9 of the findings.
Note what the earlier version got wrong: not a fact, a **frame**. Every cited line was
right; none of them was reachable. Verify the gate, not only the destination.

---

## 6. What to wire and watch

lcec exposes master-level pins, and the DC monitor is **on by default**
(`lcec_main.c:381`).

| Pin | Type | What it tells you |
|---|---|---|
| `lcec.<m>.link-up` | bit | the physical link |
| `lcec.<m>.slaves-responding` | u32 | how many slaves answer |
| `lcec.<m>.all-op` | bit | every slave reached OP |
| `lcec.<m>.dc-sync-diff` | u32 | **the distributed-clock error, in ns** |
| `lcec.<m>.dc-sync-converged` | bit | true once the error holds under the threshold |
| `lcec.<m>.dc-sync-max` | u32, rw | the threshold — default `app_time_period / 25` |
| `lcec.<m>.dc-sync-monitor` | bit, rw | enable, default on |

The default threshold works out at **40 µs for a 1 ms servo period**
(`lcec_main.c:378`).

Put `dc-sync-diff` and `dc-sync-converged` on a halscope at first power-up, before
looking anywhere else. If the axes are rough and these are unhappy, nothing
downstream will explain it.

DC is configured per slave at `lcec_main.c:307`:

```c
ecrt_slave_config_dc(config, assignActivate, sync0Cycle, sync0Shift, sync1Cycle, sync1Shift)
```

and one process-data domain is created **per Sync Unit** (`lcec_main.c:230-239`).

---

## 7. What is not established

- **Whether the phase behaviour is measurable on a real machine.** It needs hardware
  and a scope, and that part genuinely cannot be closed by reading code.
  *Narrowed 2026-08-06:* this applies to the `uspace` path only. The RTAI form of the
  same question — what the resync stub does to SYNC0 phase there — was never a
  question: lcec does not build for RTAI (§5), so there is nothing to measure.
- **The individual device drivers.** 60 files under `src/devices/`; the
  registration mechanism, parser and generator are understood (findings §5.7), the
  per-device PDO mappings are not, and auditing them without the matching hardware
  would be sterile.
- **Whether the legacy PLL trim is good enough in practice.** The driver's warning
  implies it is a fallback, not an equal.

---

## 8. How to re-check any of this

Both repositories, at the recorded HEADs:

```
git clone https://github.com/LinuxCNC/linuxcnc.git
git clone https://github.com/linuxcnc-ethercat/linuxcnc-ethercat.git
git -C linuxcnc checkout caa13ca6ae
git -C linuxcnc-ethercat checkout 87a72a8
```

**Some** of the `file:line` citations here are covered by the machine-checked
manifest in `tools/` — not all of them, and this line used to
claim otherwise. The manifest is a curated set backing `LINUXCNC-FINDINGS.md`; it was
never an index of every citation in either document. Measured 2026-08-07: 15 of the
citations in this file have no manifest entry, and 39 of those in the findings do
not either. A green verifier run therefore means *the manifest's* citations hold — it
says nothing about the ones it does not contain. Re-read those by hand at the pinned
HEADs above. Run it:

```
powershell -File tools\verify-citations.ps1 `
    -LinuxcncPath linuxcnc -LcecPath linuxcnc-ethercat
```

A FAIL after a `git pull` usually means upstream moved the line, not that the
finding broke — re-anchor the citation and record the new HEAD.

---

## Changelog

| Date | Change |
|---|---|
| 2026-08-07 | §3 *Cycle zero* rewritten from the source rather than summarised: what `initf` registers, the five things `thread_task()` does on the init cycle, the `-EALREADY` rejection and its stated reason, and the fact — verified against `origin/2.9` — that **`initf` does not exist in 2.9 at all**, so the official ISO cannot exercise the clean path. |
| 2026-08-05 | Created. Gathers the EtherCAT material from `LINUXCNC-FINDINGS.md` §2.9 and §5.4–5.7 and adds what this session established: the real `addf` order from a shipped machine config and its identity with the Mesa bracket; that **no shipped example uses `initf`** and lcec's own documentation never mentions it; the DC monitoring pins and the default 40 µs threshold; that the init cycle is unconditional, so every machine gives up cycle zero; and that **both** RTAI backends are no-ops, not only the kernel one. |
