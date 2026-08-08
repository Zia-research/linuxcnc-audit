# LinuxCNC — Verified Architecture Findings

**A living knowledge base.** Every statement here was verified by reading the source, not recalled
from memory. Each carries a `file:line` citation so it can be re-checked or invalidated.

> **If you are an AI agent picking this up:** treat this file as *evidence, not authority*. The
> citations were accurate at the HEAD recorded below. Before acting on any line, confirm the cited
> file and symbol still exist. Add what you verify; delete what you disprove. Do not add anything
> you have not read in the source.

---

## Repository state at time of writing

| | |
|---|---|
| Repository | `github.com/LinuxCNC/linuxcnc` |
| Branch | `master` |
| `VERSION` | `2.10.0~pre1` |
| HEAD | `caa13ca6ae` (2026-07-30) |
| Licence | GPL-2.0 |
| Tracked files | 9 442 (`git ls-files`) |
| Local clone | `./linuxcnc/` (full clone, ~1.2 GB with history) |

All paths below are relative to the repository root.

> ### ⚠ Release caveat — read this before quoting anything here
>
> **Everything in this file describes `master`, which is unreleased.** The newest tag in the
> repository is `v2.9.10`. Several findings below describe changes that exist *only* on `master` and
> have shipped in **no released LinuxCNC**.
>
> The sharpest example: *"moving all IO handling from iocontrol to task"* is commit `764655eb4d`
> (2023-05-16). `git tag --contains 764655eb4d` returns **nothing**, and `git branch -r --contains`
> returns only `origin/master`. **If you run LinuxCNC 2.9.x — the current stable — `iocontrol` is
> still a separate process.** Erratum 3 is a statement about `master`, not about the software most
> users have installed.
>
> Before repeating any finding to a user, ask which version they run.

---

## Method

1. Full clone, then read the actual source — never the documentation alone.
2. Every quantity comes from a header constant or a counted file list, not an estimate.
3. Where the official documentation and the code disagree, the code wins and the disagreement is
   recorded in [Part 3](#part-3--errata-against-the-official-code-notes).
4. Claims that could not be verified are listed in Part 5, not asserted.

### Audit trail

This file was re-audited against the source on **2026-08-03**, deliberately hunting for its own
errors. **Twelve were found and corrected.**

Where a *claim reversed meaning*, the old wording is preserved inline in a
`> **Correction, 2026-08-03.**` block — five such blocks exist, so a reader who saw the earlier
revision can tell what changed. The remaining seven were quantitative fixes (wrong counts, a wrong
file total, an over-confident inference) and were corrected in place; all twelve are itemised in the
changelog at the end of this file.

Two were substantive misreadings rather than sloppiness, and both are worth knowing about as failure
modes:

- **`RTLMEM` (§5.2)** — a `strcmp` was read as an implementation when it is a *rejection*. Recognising
  a string is not supporting it.
- **The error ring (§2.3)** — the saturation behaviour was stated backwards. When the ring is full the
  **newest** message is refused, not the oldest evicted.

The rest were quantitative: counts that conflated files with the things they implement (drivers vs
driver modules, registration calls vs devices, source files vs kinematics modules), and inferences
presented with more confidence than the evidence carried.

**Rule adopted from this audit:** a count is only trustworthy when the file-to-entity relationship is
stated. "65 drivers" was wrong because 42 of those files are modules of *one* driver.

---

## Part 1 — The shape of the system

LinuxCNC is two worlds — user space and the real-time domain — that share no call stack. Everything
crossing between them uses exactly **three** mechanisms:

| Mechanism | Who talks | Where |
|---|---|---|
| **NML** channels | GUIs ↔ task | `configs/common/linuxcnc.nml` |
| **`emcmot` shared memory** | task ↔ motion controller | RTAPI shmem, key 100 |
| **HAL** shared memory | every real-time component ↔ hardware | 2 MiB block, key `0x48414C32` |

Understanding LinuxCNC means understanding these three crossings and the queues that pace them.

### Process inventory

| Binary | Role | Source |
|---|---|---|
| `linuxcncsvr` | Creates and owns all NML buffers; TCP server on port 5005. **Starts first.** | `src/emc/task/emcsvr.cc` |
| `milltask` | Task loop + RS-274 interpreter + canon + `iocontrol.0.*` HAL pins | `src/emc/task/` |
| `rtapi_app` | Hosts every "real-time" component in the `uspace` flavours | `src/rtapi/uspace_rtapi_app.cc` |
| GUI | `axis`, `gmoccapy`, `qtvcp`, `touchy`, `gscreen`, `mdro` | `src/emc/usr_intf/` |

**What `milltask` is made of, and the three different things called EMCTASK.** *Read 2026-08-07.*
`src/emc/task/Submakefile:14-26` lists twelve sources — `emctask.cc`, `emctaskmain.cc`,
`emccanon.cc`, `taskintf.cc`, `taskclass.cc`, `backtrace.cc`, `usrmotintf.cc`, `emcmotglb.c`,
`emcmotutil.c`, `dbuf.c`, `stashf.c`, `mapini.cc` — and `:32-35` the libraries it links. Three of
those say more than the source list:

- **`librs274.so.0` — the interpreter is not *inside* milltask, it is a shared library.** The same
  code runs in two places, told apart by one flag: `extern int _task; // zero in gcodemodule, 1 in
  milltask`, declared identically at `interp_namedparams.cc:807`, `interpmodule.cc:39` and
  `pyparamclass.cc:28`. When a GUI previews a program's path, that is this interpreter.
- **`liblinuxcnchal.so.0` — milltask is a HAL component**, which is what its `iocontrol.0.*` pins
  are, and the mechanical confirmation of erratum 3: EMCIO is not a process, its work is here.
- `libtooldata.so.0` and `libpyplugin.so.0` — the tool table after the 2021 refactor, and the
  Python support behind remap and named parameters.

`usrmotintf.cc` being compiled *in* is the second confirmation that task attaches the `emcmot`
segment itself rather than reaching it through a server.

**EMCTASK names three unrelated things**, which is why it turns up in unrelated places. *(1)* In
the documentation it is the architectural component name of the 2012 era, beside EMCMOT and EMCIO
— `code-notes.adoc:97` and `:745`, `user-intro.adoc:28`. *(2)* In the start script it is a shell
variable holding the *program name to run*: `scripts/linuxcnc.in:522` sets `EMCTASK=$retval` after
`GetFromIni TASK TASK`, so it carries the value of the INI key `[TASK]TASK`. All 285 shipped
configurations set that key to `milltask`. *(3)* It was once a binary name, and the fossil is still
executable — see §6.3.2.

**A GUI is not confined to NML.** It is tempting to say the GUI never touches the real-time domain —
that is wrong. AXIS itself is a HAL component: `axis.py:3950` does `hal.component("axisui")`.
`halui` is a HAL component by definition, and any embedded `pyvcp`/`gladevcp` panel creates pins.
GUIs issue *motion* through NML, but they read and write HAL shared memory directly. The correct
statement is: **a GUI never runs inside a real-time thread**, not that it never touches real-time data.

Startup order is not negotiable. `configs/common/linuxcnc.nml` states it in its first line:
*"emcsvr is the master for all NML channels, and therefore is the first to start."*

---

## Part 2 — Verified facts by subsystem

### 2.1 NML

Neutral Message Language, inherited from the NIST RCS library. Two layers: **NML** handles typed
messages, **CMS** below it moves bytes and picks the transport.

**Transport classes present** in `src/libnml/buffer/`: `shmem`, `tcpmem`, `locmem`, `phantom`,
`physmem` (plus `memsem` and `rem_msg`, which are helpers, not transports).

Do not read that list as "five configurable options". Only **three** can be named as a `buffer_type`
in the NML config — `SHMEM`, `LOCMEM`, `PHANTOM` — while `TCPMEM` is reached through a *process*
line of type `REMOTE` (`cms_cfg.cc:743`), not a buffer type. See §5.2 for the full picture, including
two documented types that do not exist.

**Channels — there are exactly three** (`configs/common/linuxcnc.nml`):

| Channel | Size | Buffer no. | Mode |
|---|---|---|---|
| `emcCommand` | 8 192 B | 1001 | `queue confirm_write serial` — a real FIFO with acknowledgement |
| `emcStatus` | 20 480 B | 1002 | overwrite — last value wins, **not** a queue |
| `emcError` | 8 192 B | 1003 | `queue` |

All three carry `xdr` (architecture-neutral encoding) and `TCP=5005`.
Variants: `linuxcnc_big.nml` raises `emcStatus` to 170 000 B; `server.nml` / `client.nml` use 10 240 B.

**Message serialization.** A message is a C++ class deriving from `NMLmsg` with a single
`update(CMS*)` method that lists its members. The *same* method both encodes and decodes — CMS is in
one mode or the other. Example from `src/emc/nml_intf/emc.cc`:

```c
void EMC_IO_STAT::update(CMS *cms) {
    cms->update(debug);
    cms->update(reason);
    cms->update(fault);
    tool.update(cms);
}
```

These functions still carry the comment *"Automatically generated by NML CodeGen Java Applet,
Sat Oct 11 13:45:16 UTC 2003"*.

**API** (`src/libnml/nml/nml.hh`): `write()`, `read()` returns the message type id (0 = nothing new),
`get_address()` retrieves the object, `peek()` reads without consuming, `blocking_read(timeout)`.

**Key boundary: NML stops at the task.** It never crosses into real time.

### 2.2 HAL

Not a message bus — a 2 MiB shared memory block containing linked lists of objects.

| Constant | Value | Source |
|---|---|---|
| `HAL_KEY` | `0x48414C32` (ASCII `"HAL2"`) | `src/hal/hal_priv.h:120` |
| `HAL_VER` | `0x00000013` | `src/hal/hal_priv.h:121` |
| `HAL_SIZE` | `2*256*4096` = 2 MiB | `src/hal/hal_priv.h:122` |

`hal_data_t` sits at offset 0 and roots linked lists of `hal_comp_t`, `hal_pin_t`, `hal_sig_t`,
`hal_param_t`, `hal_funct_t`, `hal_thread_t`.

**All internal pointers are stored as offsets** from `hal_shmem_base` (the `SHMFIELD` macro), so the
block stays valid whatever address each process maps it at.

**A signal is a pointer redirect, not a copy.** A pin owns a `data_ptr_addr`; unlinked, it is pointed
at the component's own `dummysig` (`hal_lib.c:1161,1169`). `hal_link()` (`hal_lib.c:1478`) repoints it
at the signal's storage. Zero copy, zero serialization, no lock in the critical path.

**Two writers on one signal are refused** — verified, not inferred (`hal_lib.c:1552,1567`):

```c
if ((pin->dir == HAL_OUT) && ((sig->writers > 0) || (sig->bidirs > 0 ))) { /* reject */ }
if ((pin->dir == HAL_IO)  &&  (sig->writers > 0))                        { /* reject */ }
```

Short circuits are impossible by construction.

**Threads.** `motmod` creates them (`src/emc/motion/motion.c`):

```c
hal_create_thread("base-thread", base_period_nsec, base_thread_fp);
hal_create_thread("servo-thread", servo_period_nsec, 1);
```

The `base-thread` is created **only if the base period is genuinely faster than the servo period**
(`motion.c:1008-1014`):

```c
servo_base_ratio = (servo_period_sec / base_period_sec) + 0.5;   /* rounded */
/* only create base thread if it is faster than servo thread */
if (servo_base_ratio > 1) {
    retval = hal_create_thread("base-thread", base_period_nsec, base_thread_fp);
```

So with a Mesa card generating steps in its FPGA, there is no base thread at all.

> **Correction, 2026-08-03.** An earlier revision said the base thread is created "when
> `base_period_nsec` is non-zero". That is not the test — the test is the *ratio*. A base period set
> equal to or slower than the servo period also produces no base thread.

**`motmod` exports exactly two HAL functions**: `motion-command-handler` and `motion-controller`.
A third, `motion-traj-planner`, exists in `motion.c` but is wrapped in `#if 0` with the comment
*"currently the traj planner is called from the controller"* — **it is dead code**. The planner runs
inside the servo cycle.

**HAL stream FIFO** (`src/hal/hal.h:1229-1266`, `src/hal/components/streamer.h`): a genuine
single-producer/single-consumer ring in its own shmem segment, ≤ `HAL_STREAM_MAX_PINS` (21) pins,
depth set at load time, with `underruns`/`overruns` counters. Keys: `STREAMER_SHMEM_KEY 0x48535430`,
`SAMPLER_SHMEM_KEY 0x48534130`.

### 2.3 The `emcmot` shared segment

Created by `motmod` with `DEFAULT_SHMEM_KEY` = 100 (`emcmotcfg.h:49`, `motion.c:44`; overridable via
the `key` module parameter).

**Both sides make the same call, and the first one wins.** It is tempting to describe this as one
side *creating* and the other *attaching*, as two different operations. They are not: `motion.c:827`
calls `rtapi_shmem_new(key, mot_comp_id, sizeof(emcmot_struct_t))` from the realtime module, and
`usrmotintf.cc:578` calls `rtapi_shmem_new(SHMEM_KEY, module_id, sizeof(emcmot_struct_t))` from
milltask — **the same function, with the same size**. Whichever runs first creates the segment; the
second receives a mapping of it. The start order is what decides, not the code
(`scripts/linuxcnc.in`). This matters for any figure that draws the segment straddling the
scheduling boundary: the straddle is not a metaphor, it is two processes in different scheduling
classes holding the same pages.

Layout (`src/emc/motion/motion_struct.h`):

```c
typedef struct emcmot_struct_t {
    rtapi_mutex_t command_mutex;
    struct emcmot_command_t  command;   /* task -> motion */
    struct emcmot_status_t   status;    /* motion -> task */
    struct emcmot_config_t   config;
    struct emcmot_error_t    error;     /* ring buffer */
    struct emcmot_internal_t internal;
} emcmot_struct_t;
```

**The command slot is not a queue.** One slot, protected by `command_mutex`, with a
`commandNum` → `commandNumEcho` handshake. Timeout `DEFAULT_EMCMOT_COMM_TIMEOUT` = 1.0 s, reported as
`EMCMOT_COMM_ERROR_TIMEOUT` (`usrmotintf.h:60`).

**The mutex is used asymmetrically — this is the whole philosophy of the system:**

| Side | Call | Behaviour | Source |
|---|---|---|---|
| User space | `rtapi_mutex_get()` | **blocking** — waits its turn | `usrmotintf.cc:98` |
| Real time | `rtapi_mutex_try()` | **non-blocking** — gives up, retries next cycle | `command.c:2018` |

**Status uses a seqlock, not a mutex.** `emcmot_status_t`, `emcmot_config_t` and `emcmot_internal_t`
each begin with `head` and end with `tail`.

Writer (`control.c:245` and `:275`):
```c
emcmotStatus->head++;                       /* entering */
    /* ... entire servo cycle ... */
emcmotStatus->tail = emcmotStatus->head;    /* done */
```

Reader (`usrmotintf.cc:132-140`): `memcpy` the whole struct, then compare `s->head == s->tail` in the
*copy*. Mismatch means the write overlapped the copy — sleep 1 µs and retry, ultimately
`EMCMOT_COMM_SPLIT_READ_TIMEOUT`. **The real-time side never blocks and never even tests.**

**The error buffer is a genuine lock-free MPSC ring** (`motion.h:746`, implemented in
`emcmotutil.c:20-88`): 32 × 1024 B. The algorithm is documented in the file header —
producers are *"real-time threads invoked via the rtapi message handler"*, the consumer is the
single-threaded userspace task.

| Side | Behaviour |
|---|---|
| Producer `emcmotErrorPutfv()` | CAS-loop to claim a sequence on `write_reserve`; write the slot; `fetch_add(write_commit)` with release ordering |
| Producer, ring full | **`return -1` — the new message is discarded** (`emcmotutil.c:66-68`) |
| Consumer `emcmotErrorGet()` | if `write_reserve != write_commit` a producer is mid-write → return -1 and retry later, *"so the RT producer is never blocked"* |

> **Correction, 2026-08-03.** An earlier revision said the ring *"drops the oldest messages"*. It is
> the opposite: when full, the **newest** message is refused and the older ones survive.
> ```c
> if (w - r >= (unsigned long long)EMCMOT_ERROR_NUM) {
>     return -1;          /* full: caller's message is lost */
> }
> ```
> The half that was right: the real-time producer never blocks either way.

### 2.4 Queue and buffer inventory

The distinction matters — most of these are *not* FIFOs:

| Object | Kind | Capacity | Producer → Consumer | Sync |
|---|---|---|---|---|
| `interp_list` | **FIFO** `std::deque<NMLmsg>` | **≈1 000** — deque unbounded, producer throttled | Interp/canon → task loop | none, single-threaded |
| `emcCommand` | **FIFO** (CMS) | 8 192 B | GUI/halui/rsh → task | CMS semaphore + ack |
| `emcError` | **FIFO** (CMS) | 8 192 B | task → GUI | CMS semaphore |
| `emcStatus` | snapshot | 20 480 B | task → GUI | overwrite |
| `emcmot_command_t` | **single slot** | 1 command | task → motion | mutex + echo |
| `emcmot_status_t` | snapshot | 1 state | motion → task | seqlock |
| `emcmot_error_t` | **lock-free MPSC ring** | 32 × 1024 B | RT `emcmotErrorPutf()` → `emcmotErrorGet()` | atomics; newest lost when full |
| `TC_QUEUE_STRUCT` | **ring** + reverse history | 2000 × ~512 B ≈ 1 MB | `tpAddLine`/`tpAddCircle` → `tpRunCycle` | none, servo thread |
| `hal_stream_t` | **SPSC FIFO** | set at load | halstreamer ↔ RT ↔ halsampler | one reader, one writer |
| **tool table** | **mmap'd FILE** — not RTAPI shm | `TOOL_MMAP_SIZE` | task creates → GUIs and halui attach | `PROT_READ\|PROT_WRITE` **both sides** + mutex |

**Correction, 2026-08-07: `interp_list`'s capacity read `unbounded` here until today, and that
was the wrong level of description.** The container has no limit — `append()`
(`interpl.cc:33`) validates the pointer, the type and a size below 4, and never checks capacity.
But the *producer* is throttled: `emctaskmain.cc:493` reads further only while
`interp_list.len() <= emc_task_interp_max_len`, `:692` returns early above it, and `:613-615`
resume only at **two thirds** of it. The limit defaults to **1 000**
(`emccfg.h:34`) and is set by `[TASK]INTERP_MAX_LEN` (`emctaskmain.cc:3151`, and undocumented —
§6.3.3). So nothing fills the deque past about a thousand entries, and a reader told only
*"unbounded"* concludes something the machine never does. **This is the audit's own rule turned
on itself**: verify the gate, not only the destination. The container was read; the code that
fills it was not.

`TC_QUEUE_STRUCT` (`src/emc/tp/tcq.h`) carries `start`/`end`/`allFull` plus `_rlen`/`rend` for the
reverse-run history (`tcqBackStep`). Size from `DEFAULT_TC_QUEUE_SIZE` (`emcmotcfg.h:70`), whose
comment reads *"a TC_STRUCT is about 512 bytes so this queue is about a megabyte."*

**The tool table is a third shared region, and it was missing from this audit until 2026-08-07.**
§2.2 and §2.3 cover the two that matter for motion — HAL's block and the `emcmot` segment — and
the tool table is neither. It is a **file-backed `mmap`**, not RTAPI or SysV shared memory:

| Step | Evidence |
|---|---|
| milltask creates it | `taskclass.cc:162` — `tool_mmap_creator(&emcioStatus.tool, random_toolchanger)` |
| and immediately attaches as a user | `taskclass.cc:163` |
| the GUI attaches | `emcmodule.cc:1010` — `tool_mmap_user()` |
| **halui attaches too** | `halui.cc:2151` |
| the standalone interpreter creates its own | `sai/driver.cc:571` |
| both sides map **read-write** | `tooldata_mmap.cc:151-152` (creator) and `:186-187` (user), each `PROT_READ\|PROT_WRITE, MAP_SHARED` |
| serialised by a mutex | `tooldata_mmap.cc:164` — `tool_mmap_mutex_give()` |

Two things follow. **It is wholly non-realtime** — task, GUIs and halui, nothing below the
scheduling boundary — so unlike the other two segments it never straddles that line. And the
pairing is the same one the audit already uses to justify calling a region shared: **created on
one side, attached from the other.** The declared users are named in the source itself,
`tooldata_mmap.cc:167`: *"typ: milltask, guis (emcmodule,emcsh,...), halui"* — a comment, which is
why each attachment above is cited at its call site instead.

#### 2.4.1 `streamer` and `sampler` create RTAPI segments of their own — measured, 2026-08-08

**The table above already carried `hal_stream_t` as an SPSC FIFO. What it did not say is that each
one is a shared-memory region in the same family as HAL's block and the `emcmot` segment, and that a
configuration can create sixteen of them.** The row named the queue; this names the memory.

`hal_stream_create()` calls **`rtapi_shmem_new`** (`hal_lib.c:4859`) — the same call that creates HAL
memory at `hal_lib.c:285` — and `hal_stream_attach()` calls it again from the other side
(`hal_lib.c:5031`, then `:5067` once the header has been read and the real size is known; the attach
is two-step, mapping `sizeof(hal_stream_shm_t)` first to check `magic`). Size is not fixed:
`sizeof(hal_stream_shm_t) + sizeof(hal_stream_data_u) * depth * (1 + pin_count)` (`:4858`), the depth
being chosen at `loadrt`.

| | `streamer` + `halstreamer` | `sampler` + `halsampler` |
|---|---|---|
| Direction | file / `stdin` → HAL pins | HAL pins → `stdout` / file |
| Data pins | **`HAL_OUT`** (`streamer.c:279-284`) | **`HAL_IN`** (`sampler.c:233-238`) |
| Realtime side does | `hal_stream_read` (`streamer.c:217`) | `hal_stream_write` (`sampler.c:180`) |
| User side does | reads `stdin` (`streamer_usr.c:173`), `hal_stream_write` (`:249`) | `hal_stream_read` (`sampler_usr.c:197`), writes `stdout` (`:163`) |
| Key | `0x48535430` — ASCII *"HST0"* (`streamer.h:18`) | `0x48534130` — ASCII *"HSA0"* (`streamer.h:19`) |
| Created by | the realtime component (`streamer.c:135`) | the realtime component (`sampler.c:121`) |
| Attached by | `halstreamer`, an ordinary process (`streamer_usr.c:166`) | `halsampler`, an ordinary process (`sampler_usr.c:186`) |

**The keys are bases, not addresses.** Both call sites pass `KEY + n`, and `streamer.h:16-17` sets
`MAX_STREAMERS 8` and `MAX_SAMPLERS 8`, so the segments actually in use run `0x48535430`–`0x48535437`
and `0x48534130`–`0x48534137`: **up to sixteen regions beyond the two the figure draws.**

**They straddle the scheduling boundary, by the audit's own test** — created on one side, attached
from the other — exactly as `emcmot` does. **They are optional, and that is the whole of the
difference.** *An earlier version of this section said they were "outside the machine cycle". That
was wrong, and the error is instructive:* both export a HAL function — `hal_export_functf` at
`streamer.c:295` and `sampler.c:249`, one per FIFO, as the man pages state — and a HAL function
exists to be `addf`'d into a thread. The one shipped configuration that loads either does exactly
that: `configs/sim/axis/panelui-demo/panelui-demo.hal` carries `addf sampler.0 servo-thread`, so
**`sampler.0` runs in the servo thread every period, inside the cycle**. The slip was from *"no
stock machine loads them"*, which is measured and true, to *"nothing in the cycle uses them"*, which
is neither — **a claim about shipped configurations quietly became a claim about execution.**
What is true: they move data into and out of HAL rather than commanding the machine, though even
that is design intent rather than a guarantee, since `streamer`'s `HAL_OUT` pins can be wired to
anything an integrator chooses. *Measured across the 332 shipped
`.hal` files:* **`loadrt streamer` occurs 0 times, `loadrt sampler` exactly once** —
`configs/sim/axis/panelui-demo/panelui-demo.hal:13`, `loadrt sampler cfg=u depth=1025`, under the
comment *"sampler is needed for panelui"*, with `loadusr -W panelui` two lines below. That single case
closes the loop with `panelui.c:285`: the demo creates the segment in realtime and `panelui`, an
ordinary process, attaches it. That is why both are named on the figure in text rather than drawn as
boxes with connectors: *live traffic gets a line, everything else gets a caption.*

> **The first form of this check returned a false negative**, and only a second, differently written
> one caught the `panelui-demo` line. Had the first been believed, this section would have asserted
> that no shipped config loads either — a clean, plausible, wrong sentence. **A count of zero deserves
> a second query more than a count of nine does**, because zero is what a broken search returns.

**The facility has more clients than its two tools.** `panelui.c:285` attaches to
`SAMPLER_SHMEM_KEY+channel`; `histobinstream.comp` and `latencybinstream.comp` use the same API, and
so do the Python (`halmodule.cc`) and Tcl (`halsh.c`) bindings. `hal_stream` is general; `halstreamer`
and `halsampler` are simply its two shipped front ends.

**A gap worth recording**: `scripts/runtests.in:157-158` lists the six shared-memory keys the test
harness looks for after a run — `0x00000064` Emc motion, `0x48414c32` Hal, `0x48484c34` UUID,
`0x90280a48` Rtapi, `0x130cf406` Hal scope, `0x434c522b` Classicladder. **No `0x4853…` key is among
them**, so a leaked `streamer` or `sampler` segment is invisible to the check that exists precisely to
catch leaked segments. Two of those six — `UUID` and `Hal scope` — are also regions this audit has
never opened.

*Provenance note:* this was reached because a reader asked where `halstreamer` fits, and named its
counterpart only as *"a similar process in the other direction"*. Everything above is read from the
source at the lines cited, or counted across the shipped configs; nothing here rests on a man page.

### 2.5 The servo cycle

`emcmotController()` — `src/emc/motion/control.c:209-277`, exact call order:

| Line | Call |
|---|---|
| 245 | `emcmotStatus->head++` — open the seqlock |
| 248 | `read_homing_in_pins` |
| 249 | `handle_kinematicsSwitch` |
| 250 | `process_inputs` |
| 251 | `do_forward_kins` |
| 252 | `process_probe_inputs` |
| 253 | `check_for_faults` |
| 254 | `set_operating_mode` |
| 256 | `handle_jjogwheels` (if `jog-inhibit` is low) |
| 259 | `axis_handle_jogwheels` |
| 262 | `do_homing` (provided by `homemod`) |
| 266 | **`get_pos_cmds`** → `tpRunCycle` (`:1348`) → `kinematicsInverse` (`:1359`, `:1440`) |
| 267 | `compute_screw_comp` |
| 268 | `axis_plan_external_offsets` |
| 269 | `output_to_hal` |
| 270 | `write_homing_out_pins` |
| 271 | `update_status` |
| 275 | `emcmotStatus->tail = head` — close the seqlock |

#### 2.5.1 The order of the cycle is configuration — measured, 2026-08-07

`motmod` exports exactly **two** thread functions — `motion-controller` (`motion.c:1030`) and
`motion-command-handler` (`:1037`). A third export, `motion-traj-planner`, sits in a `#if 0` block
at `:1044-1056` whose comment states the structure plainly: *"currently the traj planner is called
from the controller / eventually it will be a separate function"*. It is dead code, and it is the
source's own statement that `tpmod` is **not** a thread function: the controller calls it from
inside its own execution (`tpRunCycle`, `control.c:1348`), while the command handler feeds it
(`tpAddLine :1056`, `tpAddCircle :1118`, `tpSetVmax :1153`, all `command.c`).

**Where the two functions run, and in what order, is not in the code at all** — the `.hal` file
decides, one `addf` line at a time. Reading the file top to bottom is safe: `addf`'s optional
third argument is a position, defaulting to **−1** (`halcmd_commands.cc:276`), and −1 means *from
the tail* (`hal_lib.c:2930`, *"+N from head, −N from tail"*) — so functions are appended in the
order the lines execute.

#### The base thread and the servo thread hand over through memory that is neither a pin nor a signal

`stepgen` exports three functions, and two of them run in **different threads**: `update-freq` in
the servo thread, `make-pulses` in the base thread. What passes between them is not a HAL pin. The
file's own header says so — *"'stepgen.update-freq' reads the position or frequency command and sets
**internal variables** used by 'stepgen.make-pulses'"* (`stepgen.c:48-49`).

Those internal variables are nonetheless **in HAL's shared memory block**: the per-channel array is
allocated by `hal_malloc` (`stepgen.c:494`), and `hal_malloc` returns a pointer inside the shared
block — `hal_lib.c:556` returns `SHMPTR(ref)`, and the header at `:109` states that the
`shmalloc_xx()` family *"allocate blocks of shared memory"*.

Two consequences. **A figure must draw the base thread as reaching HAL memory**, because that is
where its state lives. And **it must not draw a direct servo → base arrow**: nothing passes between
the threads except through that memory. The HAL box's own inventory — *pins · signals · params ·
functions · threads* — does not name this category, and it is the one carrying the machine's step
generation across a thread boundary.

Measured across the **189 shipped `.hal` files** that contain `addf`:

| | |
|---|---|
| configs where a hardware read **and** `motion-command-handler` are both `addf`'d | **55** |
| read **before** the handler | **54** |
| read **after** | **1** — `configs/by_interface/general_mechatronics/GM6-PCI/3-axis-servo.hal` |

That file runs `motion-command-handler`, `motion-controller`, **then** `gm.0.read`, then the PIDs,
then `gm.0.write`: it reads its board *after* the controller has already run. **So the read →
handler → controller → PID → write bracket is a convention, followed by 54 configs out of 55, and
it is not enforced by anything.** An earlier pass of this audit had inferred the bracket from two
files and called it *"the same five-step bracket"*; that was true of those two and under-sampled.
The measured form is both stronger and more useful: reorder the `addf` lines and you reorder the
machine's cycle, including into something that reads stale feedback — and one shipped
configuration already does.

### 2.6 The seven position representations

Documented in the Code Notes ("Block diagrams and Data Flow"). **All seven field names verified
present in `motion.h`** at the lines given below. Command side descends, feedback side climbs:

| # | Field | `motion.h` | Frame | Rate |
|---|---|---|---|---|
| 1 | `carte_pos_cmd` | :598 | Cartesian, commanded | trajectory |
| 2 | `joints[n].coarse_pos` | :462 | joint, before interpolation | trajectory |
| 3 | `joints[n].pos_cmd` | :463 | joint, after interpolation | **servo** |
| 4 | `joints[n].motor_pos_cmd` | :470 | motor (+ backlash, screw comp, offset) | servo |
| 5 | `joints[n].motor_pos_fb` | :471 | motor, measured | servo |
| 6 | `joints[n].pos_fb` | :472 | joint (− offset, − comp) | servo |
| 7 | `carte_pos_fb` | :600 | Cartesian, measured (forward kins) | trajectory |

The **cubic interpolator** (`src/emc/kinematics/cubic.c`, used via `joint->cubic` and `cubicDrain()`
in `control.c`) is what bridges the trajectory rate and the servo rate. It is still there.

### 2.7 Loadable modules

Three functions are separate modules loaded by `halcmd loadrt`. **"Since 2.9" is verified**:
`tpmod.c` and `homemod.c` both entered on 2022-02-09 in commit `08ac87d411` *"motion: allow alt
tp,home modules, demo comp files"*, and the earliest tag containing it is `v2.9.0-pre1`.

| Module | Source | Replaces |
|---|---|---|
| `tpmod` | `src/emc/tp/tpmod.c` | trajectory planner |
| `homemod` | `src/emc/motion/homemod.c` | homing sequence |
| kinematics | `src/emc/kinematics/` — **19** modules | joints ↔ axes transforms |

New in `master`: **`cruckig`** (`src/emc/tp/cruckig/`, 34 files) — a pure-C port of Ruckig giving a
finite-jerk planner. Pure C is a real-time constraint: no allocation, no exceptions, no STL.
`debian/changelog` records *"Add a finite-jerk trajectory planner"*.

**What `loadrt` actually is, and it is not a primitive.** On the uspace flavours — the default —
`halcmd` does not load anything itself: it **runs a program**. `do_loadrt_cmd`
(`halcmd_commands.cc:918`) branches on `#if defined(RTAPI_USPACE)` at `:922` and builds an argv of
`EMC2_BIN_DIR "/rtapi_app", "load", <module>` at `:925-926`. Unload takes the same route
(`:1154-1155`, `"unload"`), as do `newinst` (`:527`) and `debug` (`:197`). The `#else` branches
load kernel modules instead — `:934` for the load path, and `:1157` hands unloading to
`linuxcnc_module_helper`.

So **`rtapi_app` is the process every realtime component lives in**, and a component is a shared
object `dlopen`'d into it — `tpmod.c:31` says so in a comment on its own `hal_init` call:
`hal_init("tpmod"); // dlopen(".../tpmod.so")`. The same figure element is therefore a *process*
under uspace and a *kernel module loader* under RTAI-kernel; §2.8's table is what decides which.
This is why the scheduling boundary is a scheduling boundary and not a kernel one — see the
correction recorded there.

### 2.8 RTAPI flavours

| Flavour | File | Execution context |
|---|---|---|
| uspace / POSIX | `uspace_posix.cc` | `SCHED_FIFO` user-space threads — **the default** on `PREEMPT_RT` |
| uspace / RTAI | `uspace_rtai.cc` | RTAI user-space threads |
| uspace / Xenomai | `uspace_xenomai.cc` | Cobalt domain |
| uspace / Xenomai EVL | `uspace_xenomai_evl.cc` | EVL core |
| RTAI kernel | `rtai_rtapi.c` + `rtai_ulapi.c` | kernel modules |

In `uspace` mode a "real-time" component is just a shared object `dlopen`-ed into `rtapi_app`.
`tpmod.c` says it plainly: `hal_init("tpmod"); // dlopen(".../tpmod.so")`.

The headers `rtapi_math.h`, `rtapi_string.h`, `rtapi_stdint.h`, `rtapi_atomic.h` exist because libc
is unavailable in kernel context.

**Erratum against our own published work, 2026-08-07.** `sheets/linuxcnc-system-overview.html`
captioned the scheduling boundary *"a scheduling boundary, not a kernel boundary — **except under
RTAI**"*, and shipped it. The table above shows why that is wrong: **RTAI has two backends and
only one of them puts realtime in the kernel.** `uspace/RTAI` (`uspace_rtai.cc`) runs realtime as
user-space threads, where the sentence's own claim still holds; only `RTAI kernel`
(`rtai_rtapi.c` + `rtai_ulapi.c`) loads kernel modules. Naming the whole of RTAI as the exception
overstated it by four flavours out of five. Corrected in the working copy to *"kernel modules only
on the RTAI-**kernel** flavour — 1 of the 5 RTAPI flavours; uspace/RTAI is user space too"*.
**Published 2026-08-08.** This repository has already been corrected in public
once over an RTAI framing (issue #1, and the reporter was right); this one was found by asking
whether a sentence was worth keeping, and the answer turned out to be about accuracy rather than
economy.

### 2.9 EtherCAT

> The integration-facing material — the real `addf` order, the two activation paths side by side,
> the DC monitoring pins, and what to do about the RTAI hole — lives in **`ETHERCAT-NOTES.md`**.
> This section stays the audit trail: what the source says, and where.

**Headline: there is no EtherCAT driver in the LinuxCNC repository.** No source file speaks the
protocol, and no file name contains `ethercat` or `lcec`. The driver is a separate project. What the
repository *does* contain is a set of deliberate accommodations for that external driver — which is
the interesting part.

#### 2.9.1 Real accommodations in the core

**`initf` — a HAL command whose documented reason to exist is EtherCAT.** It is the real-time
analogue of `addf`: it registers a function to run **exactly once**, in real-time context, before any
cyclic function runs.

| Piece | Location |
|---|---|
| API contract | `src/hal/hal.h:1063-1080` |
| Implementation | `src/hal/hal_lib.c:2865` |
| Post-init rejection (`-EALREADY`) | `src/hal/hal_lib.c:2918-2927` |
| halcmd verb | `src/hal/utils/halcmd_commands.cc:291` (`do_initf_cmd`) |
| User doc | `docs/src/hal/basic-hal.adoc:95-106` |
| Man page | `docs/src/man/man1/halcmd.1.adoc:192` |

**`initf` is 2.10-only — it does not exist in 2.9.** Verified 2026-08-07 by comparing the two
branches inside the pinned clone, with `git grep <ref>`, without pulling or moving HEAD:
`hal_init_funct_to_thread` has **zero** occurrences anywhere in `origin/2.9` (`18c5bb5b1c`,
2026-07-26), and the halcmd verb is not registered there either. Counter-proof run: the same
patterns find both on `caa13ca6ae` (`src/hal/utils/halcmd.c:138` registers the verb), so the empty
result is not a bad-pattern artefact. **Consequence for anyone testing on the official 2.9.x ISO:**
`lcec` necessarily takes the legacy inline path of §2.9.4 and prints its own warning saying so. The
clean activation path cannot be exercised there at all.

The HAL manual names the use case outright: *"intended for one-shot setup that must execute in the
realtime task (for example EtherCAT master activation via `lcec.0.activate`)"*
(`basic-hal.adoc:100`). That line is also the in-repo evidence that the external driver's HAL
component prefix is `lcec`.

**The special init cycle** (`src/hal/hal_lib.c:3594-3632`). On the first cycle after `start`,
`thread_task()` runs the init list once and does four things the cyclic path never does:

1. no timing measurement, so a long init does not poison `maxtime`;
2. no tripping of the "unexpected realtime delay" catch-up loop;
3. the cyclic `funct_list` is **deliberately not executed** in that cycle;
4. the period is re-anchored — and the comment says why:
   *"lands the next wakeup at a clean period boundary (used to keep **EtherCAT send clear of
   SYNC0**)"*.

**The init cycle is unconditional.** The test is `hal_data->threads_running > 0 && !thread->init_done`
— nothing about the init list being non-empty. So *every* LinuxCNC machine gives up its first servo
pass, EtherCAT or not; with no `initf` registered the cycle simply runs an empty list and re-anchors.
The mechanism is general. The reason it exists is not.

That is a distributed-clocks concern: DC slaves latch I/O on the SYNC0 pulse, so the master's frame
transmission must keep a clean phase relationship to it. After the init pass the list is drained back
to the free pool and `init_done` is latched.

**`rtapi_task_self_resync()` — and its RTAI hole.** This is the primitive that performs the
re-anchoring. It is a **stub that warns once and does nothing on _both_ RTAI backends** — the kernel
one (`src/rtapi/rtai_rtapi.c:903-916`) and the uspace one (`src/rtapi/uspace_rtai.cc:190`). Only
`src/rtapi/uspace_rtapi_main.cc:1676` implements it. The RTAI stub's own comment explains the
reasoning: *"The primary consumer (EtherCAT init via initf) runs on the uspace backend."*

> **Scope of this hole, corrected 2026-08-06 after review.** Under RTAI the period re-anchoring does
> not happen, so the SYNC0 phase guarantee described above is a `uspace` feature only. But it is a gap
> in the LinuxCNC core, **not a hazard a machine builder can walk into: lcec does not build for RTAI
> at all.** Its kbuild rules are commented out under the note *"Currently disabled, and needs updated
> to work"* (`linuxcnc-ethercat/src/Makefile:62-76`); the only live `realtime` target links a userspace
> `lcec.so` (`:82,104`); `src/Kbuild` survives but is stale, naming three common objects against the
> Makefile's six; and the driver deprecated RTAI in release 0.9.3, March 2018 (`debian/changelog`).
> So the stub is **unreachable through lcec today** rather than a degraded mode in service — latent
> if RTAI EtherCAT support were ever restored, which the stub's own comment anticipates (*"If RTAI
> support is needed, store period_counts per task…"*). Not verified experimentally — this is what the
> source says.

#### 2.9.2 Mentions with no code behind them

| Where | What it says |
|---|---|
| `docs/src/getting-started/hardware-interface.adoc:20` | lists EtherCAT among the interface options |
| `docs/src/getting-started/hardware-interface.adoc:25` | example of mixing *"ethercat for servo drives, and parallel port for additional GPIO"* |
| `docs/src/getting-started/about-linuxcnc.adoc:57` | EtherCAT in the list of buses an integrator may use |
| `debian/control.top.in:119` and `debian/control.main-pkg.in:70` | **the package description advertises EtherCAT support** — *"A variety of interface hardware is supported including Modbus, EtherCAT…"* — for a package that ships no EtherCAT driver |

#### 2.9.3 The external driver — audited

Cloned to `./linuxcnc-ethercat/` and read on 2026-08-03.

| | |
|---|---|
| Repository | `linuxcnc-ethercat/linuxcnc-ethercat` — GPL-2.0, actively maintained |
| HEAD read | `87a72a8` (2026-08-03), `v1.42.1-10-g87a72a8` |
| Size | 548 tracked files, ~20 MB |
| Core | 75 `.c` + 35 `.h`; `lcec_main.c` 69 KB, `lcec_conf.c` 42 KB, `lcec_ethercat.c` 28 KB |
| Device drivers | 60 `.c` under `src/devices/` (Beckhoff EL/EP series, CiA402 class drivers, …) |
| Docs | `documentation/` — `distributed-clocks.md`, `cia402.md`, `configuration-reference.md`, `adding-drivers.md`, `DEVICES.md` |

**The IgH dependency is confirmed**: `src/lcec.h:29` and `src/lcec_conf.h:24` both
`#include "ecrt.h"`, and the code calls `ecrt_request_master()`, `ecrt_master_create_domain()`,
`ecrt_slave_config_dc()`. Release cadence is fast — `v1.42.1` (2026-07-30), `v1.42.0` (07-21),
`v1.41.2` (07-10), roughly monthly or better.

**The organisation maintains four repositories**, which is itself a finding:

| Repo | What |
|---|---|
| `linuxcnc-ethercat` | the HAL driver |
| `ethercat` | **their own fork of the IgH EtherLab master**, rebuilt with fixes |
| `apt` | Debian repository serving both; packages carry epoch `1:1.6.9-…` so they supersede the openSUSE build on a normal `apt upgrade` |
| `esi-data` | EtherCAT ESI data processed into YAML (Go) |

#### 2.9.4 How the two repositories meet — the loop closes

The `initf` facility described in §2.9.1 has exactly the consumer LinuxCNC's comments imply, and the
driver reaches for it through a **weak symbol** so one binary serves both old and new LinuxCNC
(`src/lcec_main.c:37-45`):

```c
#pragma weak hal_init_funct_to_thread
extern int hal_init_funct_to_thread(const char *funct_name, const char *thread_name, int position);
static int initf_supported = 0;
```

```c
initf_supported = (&hal_init_funct_to_thread != NULL);      /* lcec_main.c:200 */
if (!initf_supported) {
  rtapi_print_msg(RTAPI_MSG_WARN, LCEC_MSG_PFX
      "linuxcnc lacks initf support; using legacy inline activation. "
      "DC phasing will trim via PLL. Upgrade linuxcnc for clean activation.\n");
}
```

So there are two activation paths:

| LinuxCNC | Path | DC phase |
|---|---|---|
| ships `initf` | deferred activation from RT context via the `lcec.activate` funct | clean from the first cycle |
| lacks `initf` | legacy inline activation in `rtapi_app_main` | **trimmed afterwards by a PLL** |

Combined with §2.9.1: `uspace` + a LinuxCNC with `initf` gives clean DC phasing. RTAI does not enter
the comparison at all — **not because `rtapi_task_self_resync()` is a no-op there, but because lcec
does not build for RTAI** (`linuxcnc-ethercat/src/Makefile:62-76`). The core stub is a second-order
fact about a configuration that cannot currently be assembled; giving it as the reason put the causes
in the wrong order. Corrected 2026-08-06, see §2.9.1.

The DC parameters the LinuxCNC core comment alludes to are configured at `lcec_main.c:307`:
`ecrt_slave_config_dc(config, assignActivate, sync0Cycle, sync0Shift, sync1Cycle, sync1Shift)`.
One process-data domain is created **per Sync Unit** (`lcec_main.c:230-239`).

#### 2.9.5 A documentation error found by cross-checking the two repositories

`docs/src/hal/basic-hal.adoc:100` in LinuxCNC gives the example **`lcec.0.activate`**. The driver
exports it as **`lcec.activate`** — global, not per-master (`lcec_main.c:408`):

```c
rtapi_snprintf(name, HAL_NAME_LEN, "%s.activate", LCEC_MODULE_NAME);
```

Only the cyclic functs are per-master — `"%s.%s.read"` and `"%s.%s.write"` give
`lcec.<master>.read` / `.write`, so `lcec.0.read` is right while `lcec.0.activate` is not. There are
also global `lcec.read-all` (`lcec_main.c:416`) and `lcec.write-all` (`:422`), and **those are the
ones shipped configurations actually use**. A user copying the LinuxCNC manual's example into a
`.hal` file gets a funct that does not exist.

**And nobody exercises the path anyway.** No example under `linuxcnc-ethercat/examples/` contains an
`initf` line, and the driver's own `documentation/` never mentions the facility. The clean activation
path therefore exists on both sides, is reachable, and is used by nobody — which makes the wrong
funct name in the LinuxCNC manual the *only* user-facing description of it.

> This one is worth reporting upstream. It is a one-word fix in `basic-hal.adoc` and in
> `docs/src/man/man1/halcmd.1.adoc`.

**The erratum is master-only, and so is the patch that fixes it.** Verified 2026-08-07:
`lcec.0.activate` appears on `caa13ca6ae` at `basic-hal.adoc:100` and `:112`, and **nowhere in
`origin/2.9`** — the whole `initf` documentation postdates that branch, as does `initf` itself
(§2.9.1). So the 2.9-applicability question a reviewer of PR #4349 may raise has a simpler answer
for this patch than for the command counts: **the text patch `0001` corrects does not exist on
2.9. There is nothing to back-port, and no 2.9-applicable wording to find.**

#### 2.9.6 Why this matters architecturally

LinuxCNC's core carries real-time scheduling machinery — a whole HAL verb, a special thread cycle, and
an RTAPI primitive — for a driver it does not ship. `initf` has essentially one consumer, and that
consumer lives in another repository under different maintainers. It is a rare case of an out-of-tree
component shaping in-tree real-time design.

### 2.10 Repository map with counts

```
src/
├── emc/                    the machine controller
│   ├── motion/             motmod — control.c, command.c, axis.c, homing.c, homemod.c
│   ├── tp/                 planners — tp.c, tcq.c, blendmath.c, sp_scurve.c, cruckig/ (34 files)
│   ├── kinematics/         19 joints↔axes modules
│   ├── rs274ngc/           G-code interpreter, 48 files incl. Python bindings
│   ├── task/               milltask + linuxcncsvr
│   ├── nml_intf/           message definitions — emc.hh, canon.hh, interpl.hh
│   ├── usr_intf/           GUIs
│   ├── tooldata/           tool table — mmap, NML, database
│   ├── ini/                INI reading, exposed as HAL pins
│   ├── sai/                standalone interpreter
│   ├── canterp/            canonical-command interpreter
│   └── motion-logger/      stub motmod for tests
├── hal/
│   ├── hal_lib.c           the core
│   ├── components/         124 .comp + 25 .c
│   ├── drivers/            23 top-level driver files (17 .c + 6 .comp)
│   │                       + mesa-hostmot2/ = 42 .c, ONE driver in many modules
│   ├── user_comps/         17
│   ├── utils/              halcmd, halmeter, halscope, halcompile
│   └── classicladder/      ladder-logic PLC
├── libnml/                 cms/ buffer/ nml/ rcs/ linklist/ posemath/ os_intf/
├── rtapi/                  5 flavours + libc substitute headers
├── module_helper/          privilege helper for rtapi_app
└── tests/

configs/    2 017 files      docs/  387 .adoc      lib/python/  hal.py, qtvcp/, rs274/, vismach.py
```

### 2.11 HAL pins created by the GUIs — measured, 2026-08-07

Every screen exports its own HAL pins, **and the count differs per screen**. Two, counted at the
pinned HEAD:

| Screen | Pins | Where |
|---|---|---|
| `axisui` | **16** | `axis.py:3950` creates the component, `:3951-3966` the pins |
| `qtdragon` | **18** | `share/qtvcp/screens/qtdragon/qtdragon_handler.py`, `newPin(...)` |

qtdragon's eighteen are `spindle-amps`, `spindle-volts`, `spindle-fault{,-u32}`,
`spindle-modbus-errors{,-u32}`, `spindle-modbus-connection`, `spindle-inhibit`, `external-pause`,
`eoffset-{enable,clear,spindle-count,is-active,value}`, `mpg-in`, `dialog-{ok,no,cancel}`. **None
of them is a widget an integrator placed on the screen** — they are created in the shipped
screen's handler code. Widget pins exist too and are additional: `qt_halobjects.py:150` wraps the
ordinary `_hal.component.newpin`.

This matters because a claim circulating about "modern" LinuxCNC GUIs is that they create *only*
the pins of user-placed widgets, unlike AXIS. **The counts invert it**: the shipped qtdragon
handler creates more fixed pins than AXIS does.

**Two vocabulary traps in the same area, both verified by absence.** `qtvcp` is the framework and
`qtdragon` is a screen built on it — listing them side by side as if both were GUIs is a category
error, and this audit made a small version of it in its own figure until today. And **QtPyVCP is
not in the tree**: `grep -r qtpyvcp src/` returns **0 files**, as does ProbeBasic. QtPyVCP is a
separate third-party project; qtdragon is *not* built on it. Any description of "QtDragon's
QtPyVCP architecture" is describing something that is not in this repository.

---

## Part 3 — Errata against the official Code Notes

Target: `docs/src/code/code-notes.adoc` and its two block diagrams. The document opens with its own
warning: *"Much of this information is now outdated and has never been reviewed for accuracy."*

**Provenance of the overall diagram.** `LinuxCNC-block-diagram-small.png` entered the repository on
**2012-11-19**, commit `b60c20198e`, *"docs: add some architecture diagrams"*, by Sebastian
Kuzminsky — and `git log --follow` shows **exactly one commit**: it has never been modified since.
The drawing's *content* is clearly older (it depicts the EMC/EMC2 era), but nothing in the
repository dates it, so do not claim it goes back to the project's origins. What is verifiable:
**unchanged in the repository since 2012.**

Two useful dates for erratum 3: `iotaskintf.cc` was dropped from the task `Submakefile` on
**2011-08-03** (`d56fdbfcbb`), while IO handling actually moved into task on **2023-05-16**
(`764655eb4d`) — the latter still unreleased, see the caveat at the top.

### 3.1 Overall block diagram (`LinuxCNC-block-diagram-small.png`)

| # | The diagram says | The code says | Evidence |
|---|---|---|---|
| 1 | `"NML?"` between EMCTASK and shared memory | Not NML. Direct RTAPI shmem, key 100, via `usrmotWriteEmcmotCommand()`. And there is **one** NML triplet in the whole system, not three. | `motion.c:44`, `usrmotintf.h:67`, `linuxcnc.nml` |
| 2 | `"FIFOS?"` into EMCMOT | Not FIFOs. A **single slot** under `command_mutex` with `commandNum`/`commandNumEcho`. The only ring in that segment is `emcmot_error_t`. | `motion_struct.h:20-21`, `motion.h:211,584,746` |
| 3 | EMCIO as a fourth process with its own NML channels | The process is gone. `# disabled: emc/task/iotaskintf.cc`; the 14 `iocontrol.0.*` pins are created by `milltask` itself. | `task/Submakefile:13`, `taskclass.cc:41,133` |
| 4 | HAL appears nowhere | Structural omission — the diagram predates HAL. All hardware coupling now goes through the 2 MiB block. | `hal_priv.h:120-122` |
| 5 | `PID SERVO`, `D/A CONVERTER`, `ENCODER COUNTER`, `LIMIT SWITCHES` inside EMCMOT | All moved out; they are independent HAL components wired in a `.hal` file. `control.c:180` says the final motor position goes *"to the HAL (which routes it to the PID"*. Nothing in `src/emc/motion/` computes a PID. | `control.c:180`, `hal/components/pid.c` |
| 6 | `AXIS 1 … AXIS N` | These are **joints**, not axes. `EMCMOT_MAX_JOINTS 16` vs `EMCMOT_MAX_AXIS 9`. | `emcmotcfg.h:25,31` |
| 7 | `SPINDLE CONTROLLER` inside EMCIO (non-real-time) | The spindle moved **into** real time. `motmod` exports `spindle.N.on`, `speed-out`, `at-speed`, `index-enable`, `orient`… for 8 spindles. Threading and rigid tapping require servo-rate sync. | `motion.c:709-734`, `emcmotcfg.h:33` |
| 8 | Planner, kinematics, homing as fixed blocks | Separately loaded modules: `tpmod`, `homemod`, one of 19 `*kins`. | `tp/tpmod.c`, `motion/homemod.c` |
| 9 | `NON-REALTIME / REALTIME` line implies a kernel boundary | By default it is not. `uspace` on `PREEMPT_RT` runs "real-time" components as `SCHED_FIFO` user-space threads in `rtapi_app`. It is a **scheduling** boundary. | `rtapi/uspace_posix.cc` |
| 10 | No queue shown anywhere | The two real queues are absent: `interp_list` and `TC_QUEUE` (2000 segments ≈ 1 MB). | `interpl.hh:46`, `tp/tcq.h`, `emcmotcfg.h:70` |

### 3.2 Motion controller diagram (`LinuxCNC-motion-controller-small.png`)

**Audited 2026-08-05**, at the same HEADs as the rest of this file. This is the
**second** of the three images in `code-notes.adoc` (`:103`, `:154`, `:167`).
The original pass covered the first and the third only; Part 3 has been
reordered to follow the document's own sequence, so that a missing diagram now
shows as a gap in the numbering rather than hiding between two sections.

*Method.* The PNG was read directly and every block, label and arrow
transcribed, then each claim tested against the source. Two verification passes
followed: a machine read-back of all fifteen citations (15/15), then an
adversarial pass that attacked each finding with an independent oracle. That
second pass **broke one of the findings below** — erratum 30, which originally
overstated its case — and turned erratum 28 from a bare "this is wrong" into a
dated fact. The corrected finding was then re-verified on its own.

**Provenance.** The image entered the repository in the same 2012 commit as the
overall diagram (`b60c20198e`, 2012-11-19) and has never been modified since.
Its content is older still: `extintf.h` and `exthalmot.c`, which its caption
names, were deleted on **2005-11-05** (`7ed547ea17`, *"removed obsolete hal_intf
files"*). **The caption was already wrong on the day the image was committed** —
by seven years.

| # | The diagram says | The code says | Evidence |
|---|---|---|---|
| 28 | HAL is *"DEFINED IN 'EXTINTF.H' AND IMPLEMENTED IN 'EXT????.C'"* | Neither exists. HAL is `hal_lib.c`, `hal_lib_extra.c`, `hal_lib_query.c`, behind `hal.h`. **This is open upstream issue [#3843](https://github.com/LinuxCNC/linuxcnc/issues/3843).** | `7ed547ea17`; no `extintf*` anywhere under `src/` |
| 29 | `PID SERVO` inside each axis, inside EMCMOT | No PID in motion. Motion writes `joint.N.motor-pos-cmd`, and the comment over `output_to_hal()` says the position goes *"to the HAL (which routes it to the PID loop)"*. | `motion.c:753`, `control.c:180`, `hal/components/pid.c` |
| 30 | Two `UNIT CONVERT` blocks, one per path | **Right place, wrong operation.** Motion *does* transform joint↔motor, symmetrically: `motor_pos_cmd = pos_cmd + backlash_filt + motor_offset`, and the reverse on feedback. But it is **additive** — backlash, screw comp and motor offset. No scaling occurs in motion at all; unit scale is `stepgen`'s `position-scale`. | `control.c:2043-2044`, `:459-461`, `stepgen.c:360` |
| 31 | `AXIS 1 … AXIS N` | Joints, not axes — 16 against 9. Same root cause as erratum 6. | `emcmotcfg.h:25,31` |
| 32 | `EMCIO` as a fourth block with its own NML `CMD`/`STAT`/`ERR` | The process is gone, and the whole system defines **three** NML buffers — `emcCommand`, `emcStatus`, `emcError` — identical across all four `.nml` files, serving task. There is no EMCIO triplet. | `task/Submakefile:13`, `configs/common/linuxcnc.nml:9-11` |
| 33 | `TRAJECTORY PLANNER` and `LIMIT & HOME STATUS` as fixed blocks | Separately loaded modules — `tpmod` and `homemod`. Same root cause as erratum 8. | `homemod.c:23` |
| 34 | *(the image as a whole)* | **The prose introducing it contradicts it.** Fifteen lines above the image, the document describes `motmod` controlling hardware *via HAL*, and `tpmod`/`homemod` as swappable loadable modules — then displays a figure that attributes HAL to `EXTINTF.H` and draws both as fixed blocks. | `code-notes.adoc:138-154` |
| 35 | `⊗` summing junction feeding `PID SERVO` | **Two subtractions exist and the diagram merges them in the wrong place.** Motion computes `ferror = pos_cmd - pos_fb`, but that result only raises the following-error flag and is copied to status — it drives nothing. The subtraction that closes the servo loop is `error = *pid->command - *pid->feedback`, inside the HAL component. | `control.c:467`, `:486-490`, `:2145`, `pid.c:384` |
| 36 | `CARTESIAN POSITION` drawn as a flow beside `STATUS` | It is a field *inside* `emcmot_status_t`: the struct opens at `:580`, `carte_pos_cmd` sits at `:598`. One flow, not two. | `motion.h:580,598` |
| 37 | Three flows across the shared segment | The segment holds six members: `command_mutex`, `command`, `status`, `config`, `error`, `internal`. The error ring and the config block are not drawn at all. | `motion_struct.h:19-26` |
| 38 | `ENCODER COUNTER` and `D/A CONVERTER` below the HAL line, inside `HARDWARE` | These are canonical HAL **components**: `encoder.c` calls itself *"Encoder Counter for EMC HAL"*, `pwmgen.c` *"PWM/PDM Generator for EMC HAL"*. Only the encoder and the amplifier are hardware. | `hal/components/encoder.c`, `hal/components/pwmgen.c` |

**What holds up — and it is more than expected.**

The `INTERPOLATOR` per axis is live code, not a relic. Every joint carries a
`CUBIC_STRUCT cubic`, `cubicInterpolate()` is called each cycle, and the rate is
computed as the nearest integer to the traj/servo ratio. The block is right;
only the `AXIS` label wrapping it is wrong — it is `joints[t].cubic`.
`FORWARD KINEMATICS` and `INVERSE KINEMATICS` hold too: `do_forward_kins()` and
`kinematicsForward()` both run inside motion. And the three `?` marks on the
arrows are the 2012 author's own hedges — the same honesty as the `"FIFOS?"` on
the overall diagram, and worth preserving rather than resolving wrongly.

Evidence: `motion.h:482`, `control.c:1398`, `motion.c:1091-1096`,
`control.c:251`, `control.c:333`.

### 3.3 Joint controller diagram (`emc2-motion-joint-controller-block-diag.png`)

**Verdict: this one aged well.** All ten pins it shows still exist — `pos-lim-sw-in`, `neg-lim-sw-in`,
`home-sw-in`, `amp-enable-out`, `amp-fault-in`, `motor-pos-cmd`, `motor-pos-fb`, `pos-fb`,
`motor-offset`, backlash & screw comp. Two corrections only:

| # | The diagram says | The code says | Evidence |
|---|---|---|---|
| 11 | pin `index-pulse-in` | It is `joint.N.index-enable`, and it is **bidirectional** (`HAL_IO`) — a handshake where the encoder driver clears it when the index is seen. It is created by **`homemod`**, not `motmod`. | `homing.c:254-255,113,537` |
| 12 | no notion of axes | The whole `axis.L.*` family is missing — `axis.x.pos-cmd`, `axis.x.teleop-vel-cmd`, external offsets. Same root cause as erratum 6. | `motion.c`, `axis.c` |

### 3.4 Command list, libnml, tool table

| # | The document says | The code says | Evidence |
|---|---|---|---|
| 13 | 27 documented commands, presented as the inventory | `cmd_code_t` holds **76**. Seven documented names no longer exist; **57 were never documented**. | `motion.h`, `code-notes.adoc:227-740` |
| 14 | "LinuxCNC manages tool information in a tool table file" | Storage was rebuilt: **three back-ends** — `mmap` (readers map it read-only), an **external database** driven by `[EMCIO]DB_PROGRAM`, and NML. | `tooldata_mmap.cc`, `tooldata_db.cc`, `taskclass.cc:147` |
| 15 | buffer types "SHMEM, LOCMEM, FILEMEM, PHANTOM, or GLOBMEM" | Two of the five do not exist. **`FILEMEM` and `GLOBMEM` are recognised nowhere** — `GLOBMEM` survives only in a comment on the `buffer_type` field declaration. Only **three** types actually construct an object: `PHANTOM`, `SHMEM`, `LOCMEM`. A fourth string, `RTLMEM`, is recognised solely in order to be **refused** with `"RTLMEM not supported."`. See §5.2. | `cms_cfg.cc:729,819,844,849` |
| 22 | *"see the treatment of axes in `initraj.cc:loadTraj()`"* — offered as a live example of a joints/axes bug | **Fixed.** `initraj.cc:203-205` now reads *"originally, this code would only set axes X, Y and Z … Now all axes are set"*. Second instance of the document preserving a bug report past its repair. See §5.3. | `initraj.cc:203-205` |
| 23 | The block diagram shows EMCIO as a fourth process | The prose chapter says the opposite — *"The I/O Controller is part of TASK"* (`:756`) — then goes on to describe an "iocontrol main loop process" anyway. **The document contradicts itself**, independently of whether either version matches the code. | `code-notes.adoc:754-767` |
| 25 | `PAUSE` — *"It has no effect in free or teleop mode"*, and *"I don't know if it pauses all motion immediately, or if it completes the current move"* | Answered, and one omission is a safety fact. The machine **decelerates to a stop mid-segment** at that segment's acceleration limit — neither instant nor at the end of the move. The run-down is jerk-limited only where the S-curve planner is selected — `[TRAJ]PLANNER_TYPE = 1` **and** a non-zero `MAX_JERK`, both off by default — so a stock machine runs down on a trapezoidal profile. See §5.6. And **pause is silently ignored during threading and rigid tapping** (`TC_SYNC_POSITION`): `tpGetFeedScale()` returns `1.0` there, bypassing pause and feed override alike. Nothing in the chapter mentions this. See §5.6. | `tp.c:243-252, 2782-2787, 4083` |
| 24 | TELEOP requires all joints homed | True only when `kinType != KINEMATICS_IDENTITY`. On a `trivkins` machine teleop needs **no** homing. The requirement is stated unconditionally. See §5.1. | `motion.c:173-178` |

### 3.5 Command semantics

Of the 19 surviving commands, 4 are contradicted, 3 have no handler, 4 have no description at all
("*(More later)*"), and 8 hold up.

| # | The document says | The code says | Evidence |
|---|---|---|---|
| 16 | `ENABLE` — *"Requirements: None … always be accepted"* | **False.** Rejected if the `motion.enable` HAL pin is low. (The "no forward kins → free mode" clause *is* still right: the `KINEMATICS_INVERSE_ONLY` test.) | `command.c:1366` |
| 17 | `STEP` — *"Requirements: None … always be accepted"* | **False.** Only acts when `emcmotStatus->paused` is true; otherwise `reportError("MOTION: can't STEP while already executing")`. | `command.c:1261` |
| 18 | `JOG_CONT`/`JOG_INCR`/`JOG_ABS` — free mode only, joint given by `emcmotCommand->axis` | Three gaps. Jog is **no longer free-mode only** — the handler tests `!GET_MOTION_TELEOP_FLAG()` and also serves teleop (Cartesian) jogging. The field is `joint`; `axis` now means a Cartesian coordinate. And **five undocumented rejection conditions** were added: `jog-inhibit` pin, homing active, jogwheel already active, locking joint needs unlock, jogging further onto a limit (no longer silent — sets `SET_JOINT_ERROR_FLAG`). | `command.c:796-840` |
| 19 | `OVERRIDE_LIMITS` — *"This is currently broken…"* | **The bug was fixed; the document still describes it.** The code comment now reads *"they are automatically re-enabled at the end of the next jog"* — the behaviour the document presented as unrealised intent. Also, only limits **actually tripped** are overridden, via a mask built from `GET_JOINT_NHL_FLAG`/`GET_JOINT_PHL_FLAG` — not "all joints". | `command.c:702-730` |
| 20 | `SET_TELEOP_VECTOR`, `ENABLE_WATCHDOG`, `DISABLE_WATCHDOG` described as operational | All three have **no `case` in `command.c`**. Issuing them does nothing. | `motion.h` vs `command.c` |
| 21 | Internal note dated 6/5/2020: *"73 commands, but the switch contemplates only 70"* | The document contains a self-audit that is **itself stale**. Today the figures are **76 and 73**, the gap of three is unchanged, and it covers exactly the same three commands. Nothing was fixed in six years — neither the code nor the note. | `code-notes.adoc:242-246` |

**Counting method.** `command.c` has 76 `case EMCMOT_*` labels but **73 distinct values** — the three
jog commands appear in two different `switch` statements, one for handling and one only for an error
message. Against 76 enum values, three commands have no handler.

---

## Part 4 — What the Code Notes still get right

An audit that only found faults would be dishonest. Sixteen points hold:

1. **The NML triplet to the GUI** — CMD/STAT/ERR between interfaces and task. Correct, and it is the only one.
2. **EMCTASK's contents** — RS-274 interpreter and sequencing logic do share one process.
3. **The cubic interpolator** — still present and active (`joint->cubic`, `cubicDrain()`).
4. **Forward and inverse kinematics** — both directions and their place in the loop are right; only modularity changed.
5. **Limit & home status** — still a real block of the controller.
6. **Encoder and motor at the end of the chain** — the physical loop closes as drawn.
7. **The principle of a real-time boundary** — it exists and structures everything; only its nature changed.
8. **The joint controller's pins** — ten verified one by one, all present.
9. **The free-mode planner** — `simple_tp.c` is still there.
10. **libnml's classes** — all six exist at the described paths: `linklist.hh`, `shmem.hh`, `memsem.hh`, `timer.hh`, `cms.hh`, `nml.hh`. **The best-aged chapter of the document.**
11. **The toolchanger model** — random vs nonrandom, copy vs swap: still accurate.
12. **Pocket 0 and T0 semantics** — pocket 0 = spindle; T0 = "no tool" in nonrandom only.
13. **`FREE` — deferred switching** — the handler really does only clear `coordinating` and `teleoperating`.
14. **`PAUSE` and `RESUME`** — `tpPause()` / `tpResume()` and the `paused` flag, no hidden conditions.
15. **`DISABLE`** — always accepted, effect deferred to the controller cycle (unlike its counterpart `ENABLE`).
16. **`ENABLE`'s kinematics clause** — the `KINEMATICS_INVERSE_ONLY` test is still there.

---

## Part 5 — Agenda: closed, open, and unreachable

Not verified. Do not assert any of this without reading the source first.

### Closed on 2026-08-05

| Was open | Outcome |
|---|---|
| `LinuxCNC-motion-controller-small.png` never audited — a coverage gap recorded on 2026-08-04, not a judgement that the diagram was sound | **Resolved** — see §3.2. Eleven errata (28–38), and rather more than expected still holds. Upstream issue [#3843](https://github.com/LinuxCNC/linuxcnc/issues/3843) is erratum 28, now dated: the caption was already wrong when the image was committed. Part 3 was reordered so the three diagrams follow the source document's own sequence — a missing one would now leave a visible hole. |

**Note on what this gap cost.** It went unnoticed through four verification
passes because every one of them checked the claims that *were* made. Nothing
checked the perimeter — whether the set of audited objects matched the set of
objects in the source document. That question is answerable in one line
(`grep 'image::' code-notes.adoc`), and it was never asked. The lesson pairs
with the one in the 2026-08-04 changelog entry: verification confirms what is
present, and is structurally blind to what is absent. Coverage needs its own
check, derived from the source, not from our own table of contents.

### Closed on 2026-08-03

| Was open | Outcome |
|---|---|
| Delegating handlers (`switch_to_teleop_mode`, `tpPause`) | **Resolved** — see §5.1 |
| `GLOBMEM` status | **Resolved**, and it widens erratum 15 — see §5.2 |
| Code Notes chapters not examined | **Resolved** — see §5.3 |
| The `linuxcnc-ethercat/ethercat` fork | **Resolved** — see §5.4 |
| `linuxcnc-ethercat` config format and CiA402 | **Partly resolved** — see §5.5 |

#### 5.1 Where the handlers delegate

**`switch_to_teleop_mode()` is at `src/emc/motion/motion.c:169-187`** — not in `control.c`, which is
why the first search missed it. Its logic refines the documented TELEOP requirements:

```c
if (emcmotConfig->kinType != KINEMATICS_IDENTITY) {
    if (!get_allhomed()) {
        reportError(_("all joints must be homed before going into teleop mode"));
        return;
    }
}
```

The homing requirement is real, but **conditional on the kinematics type**. On an identity-kinematics
machine (`trivkins`) teleop mode needs no homing at all. The Code Notes state the requirement
unconditionally. The rest of the function disables every joint's `free_tp` and sets
`teleoperating = 1`, `coordinating = 0`.

**`tpPause()` is `src/emc/tp/tp.c:4174-4181` and does exactly one thing**: `tp->pausing = 1`. So the
document's admission — *"I don't know if it pauses all motion immediately, or if it completes the
current move"* — is **still not answered by this level**. The behaviour lives in how `tpRunCycle`
consumes the `pausing` flag. One level deeper again; not followed.

#### 5.2 CMS buffer types — the documented list is wrong twice over

`src/libnml/cms/cms_cfg.cc` recognises four strings, but **only three construct anything**:

| Type | Site | Outcome |
|---|---|---|
| `PHANTOM` | `cms_cfg.cc:729` | constructs `PHANTOMMEM` |
| `SHMEM` | `cms_cfg.cc:819` | constructs `SHMEM` |
| `LOCMEM` | `cms_cfg.cc:849` | constructs `LOCMEM` |
| `RTLMEM` | `cms_cfg.cc:844` | **refused** — `rcs_print_error("RTLMEM not supported.\n"); return (-1);` |

```c
if (!strcmp(buffer_type, "RTLMEM")) {
    rcs_print_error("RTLMEM not supported.\n");
    return (-1);
}
```

`RTLMEM` has no class in `libnml/buffer/` and appears nowhere else in `src/libnml/`. It is a
tombstone: the name is kept only so the parser can give a clear error instead of an obscure one.

`GLOBMEM` appears **only in a comment** on the `buffer_type` field declaration
(`/* "SHMEM" or "GLOBMEM" */`) — no parser branch, no class. It is as dead as `FILEMEM`, but more
quietly: declaring `GLOBMEM` falls through to a generic failure, while `RTLMEM` at least names itself.

**Erratum 15 widens**: the document lists five buffer types; **two of them (`FILEMEM`, `GLOBMEM`) do
not exist**, and only three of the five are usable.

> **Correction, 2026-08-03.** An earlier revision of this file listed `RTLMEM` as a working,
> undocumented fourth type. That was a misreading — the `strcmp` was taken for an implementation when
> it is a rejection. Corrected above.

#### 5.3 The remaining Code Notes chapters

- **"Backlash and Screw Error Compensation"** (`code-notes.adoc:741-743`) is **one line: `FIXME`.**
  An empty chapter.
- **"User Interfaces"** (`:769-771`) is likewise **just `FIXME`.**
- **"Task controller — State"** is accurate: three states, *E-stop*, *E-stop Reset*, *Machine On*,
  matching `docs/src/code/task-state-transitions.dot`.
- **"IO controller (EMCIO)" contradicts the block diagram.** Line 756 states *"The I/O Controller is
  part of TASK"* — already updated for the merge. But lines 759-767 still describe events "handled by
  iocontrol" and an "iocontrol main loop process". So the diagram shows a separate process
  (erratum 3), the first line of the prose says it is part of task, and the rest of the prose still
  describes a separate loop. **The document disagrees with itself.**
- **"Reckoning of joints and axes" is the best chapter in the document.** Current and self-aware.
  `axis_mask` confirmed at `emc_nml.hh:979`, `joints` at `:977`. Its claim that
  `status.motion.traj.axes` was *removed in 2.9* is **consistent with** what I checked — there is no
  `int axes` in `emc_nml.hh` — but I verified only its absence today, **not the release it went in**.
  Do not repeat the "2.9" part as verified.
- **It points at a bug that has since been fixed.** Line 1391: *"For an example of such a bug, see the
  treatment of axes in `src/emc/ini/initraj.cc:loadTraj()`"*. At `initraj.cc:203-205` the code now
  reads: *"NOTE: originally, this code would only set axes X, Y and Z and ignore everything else. Now
  all axes are set if provided in the [TRAJ]HOME position."*
  **This is the second time the document preserves a bug report for a bug that no longer exists**
  (the first was `OVERRIDE_LIMITS`, erratum 19). At two instances it stops being an accident and
  becomes a characteristic of the document: *it records defects and never records their repair*.
- Three inline `FIXME`s survive and are still valid, notably `:1343` — *"remove the
  EMCMOT_SET_OFFSET message"* — and the command is indeed still there at `command.c:1909`.

#### 5.4 The EtherCAT master fork

`linuxcnc-ethercat/ethercat` reports **`fork: false` with no declared parent**, so GitHub does not
consider it a fork of anything. *How* the IgH EtherLab code got there — import, subtree, manual copy —
is **not established**; only that GitHub records no fork relationship. Default branch `dev-1.6`.

Every tag is a pre-release: the newest is **`v1.6.9+parallelop1.pre9`**, and the series runs
`.pre4 … .pre9`. There is no final `v1.6.9+parallelop1` tag. So the master this project ships is a
**pre-release patch series on top of IgH 1.6.9**.

The divergence is legible from the branches and recent commits:

- **NIC driver backports for modern kernels**: `e1000e-5.4`, `e1000e-5.10`, `igb-6.8`, `igc_6.8`,
  `realtek-5.10` — the classic pain point of IgH, which needs patched network drivers.
- **Packaging**: DKMS, *"build all common NIC drivers and a parallel EoE variant"*, a udev rule for
  `/dev/EtherCAT*` owned by group `ethercat`, and the binary package renamed
  `ethercat` → `ethercat-master`.
- **Protocol work**: `speed-up-foe`, `skip-sii-read`, CCAT module loading, and distributed-clock
  reference-clock branches (`test/mr-204-dc-refclock`,
  `218-ecrt_master_select_reference_clock-…`).

#### 5.5 The lcec configuration model

Configuration is **XML**, not INI (`documentation/configuration-reference.md`):

```xml
<masters>
  <master idx="0" appTimePeriod="1000000" refClockSyncCycles="-1">
    <slave .../>
  </master>
</masters>
```

Two driver styles coexist: 60 **compiled-in device drivers** (easier to use, extra error checking,
harder to write) and a **generic driver** that maps HAL pins straight to EtherCAT PDOs with no code
at all — *"In many cases this is sufficient to get arbitrary hardware working."*

**CiA402** — the standard servo-drive profile — gets a substantial class layer:
`lcec_class_cia402.c` (43 KB), `lcec_class_cia402_opt.h` (31 KB), `lcec_basic_cia402.c` (12 KB).

The `examples/` folder also carries an **FSoE** case (Functional Safety over EtherCAT) with Beckhoff
TwinSAFE project files — safety traffic on the same wire.

#### 5.6 What PAUSE actually does — the Code Notes' own question, answered

The document admits: *"At this point I don't know if it pauses all motion immediately, or if it
completes the current move and then pauses before pulling another move from the queue."*
**Neither.** `tp->pausing` is consumed at exactly two decision points, both guarded by the same
condition:

```c
bool pausing = tp->pausing && (tc->synchronized == TC_SYNC_NONE || tc->synchronized == TC_SYNC_VELOCITY);
```

| Site | Effect |
|---|---|
| `tpGetFeedScale()` — `tp.c:243-247` | returns **`0.0`**, ahead of every other case |
| `tpCalculateSCurveAccel()` — `tp.c:2782-2787` | sets `use_velocity_control`, so Ruckig plans a controlled run-down to zero |

So the machine **decelerates to a stop inside the current segment**, at that segment's acceleration
limit. It neither stops instantly nor finishes the move: it halts wherever the deceleration ramp
ends, mid-segment. `tpHandleAbort()` (`tp.c:4083`) then returns `TP_ERR_STOPPED` once velocity
reaches zero.

> **Correction, 2026-08-05, prompted by an external reviewer — and corrected again 2026-08-06.**
> An earlier revision said the run-down happens at *"that segment's acceleration and jerk limits"*,
> and the upstream patch carried *"acceleration (and jerk) limits"*. grandixximo, reviewing the
> patches on PR #3718, pointed out that jerk limiting is not the default. He is right.
>
> **The first correction then got the mechanism wrong**, and it is recorded here rather than
> quietly replaced. It claimed the jerk-limited path is attempted, fails, and the planner reverts.
> Re-reading the source shows the path is never attempted. Jerk limiting is gated by an explicit
> planner selector:
>
> | Step | Evidence |
> |---|---|
> | `[TRAJ]PLANNER_TYPE` chooses the planner — `0` trapezoidal, `1` S-curve — and defaults to `0` | `emccfg.h:57`, `initraj.cc:157` |
> | a configuration asking for `1` with a jerk below `1.0` is silently forced back to `0` | `initraj.cc:159-162`, carrying its own `// FIXME: Should write a warning message to the user`; the runtime HAL-pin route applies the same rule at `inihal.cc:320-321` |
> | `MAX_JERK` defaults to `0.0` for traj, joints and axes | `emccfg.h:51,70,87` — the INI docs list `MAX_JERK = 0.0` too |
> | the coordinated planner enters the S-curve branch only when the type is `1` | `tp.c:3660,3664` |
> | the jogging and homing planner carries the same double gate | `simple_tp.c:23` |
>
> So on a stock configuration `tpCalculateSCurveAccel()` is **never called**. The deceleration is
> trapezoidal because no other profile was ever selected — not because one was tried and failed.
>
> The fallback the earlier revision described does exist, one level in: `tp.c:2759-2762` returns
> `TP_SCURVE_ACCEL_ERROR` when the effective jerk is `<= 1`, and `tp.c:3688` then reverts, in its
> own comment's words, *"to T-shaped acceleration/deceleration."* `ruckig_wrapper.c:236-241`
> refuses a zero-jerk plan further in still. These are defence in depth — reachable because
> `EMCMOT_SET_PLANNER_TYPE` (`command.c:1218-1227`) does not carry the jerk guard the INI and HAL
> routes apply — and they are not what makes a default machine trapezoidal.
>
> Two figures: of the 324 `.ini` files under `configs/`, exactly two set `MAX_JERK`, and the same
> two set `PLANNER_TYPE` — `configs/sim/axis/axis_9axis_scurve.ini` and `axis_mm_scurve.ini`.
>
> One nuance the reviewer's own wording missed: **cruckig is not a separate planner.** It lives
> inside `tpmod` — `tp.c:43` includes `ruckig_wrapper.h` and `tp.c:2795` instantiates a planner per
> segment, with the sources under `src/emc/tp/cruckig/`. Jerk limiting is a setting, not a
> different module.

> **The exception the Code Notes never mention, and it is a safety fact.**
> Pause is **ignored** while the segment is position-synchronized to the spindle
> (`TC_SYNC_POSITION`) — that is, **during threading and rigid tapping**. `tpGetFeedScale()` returns
> `1.0` for that case (`tp.c:251-252`), bypassing pause *and* feed override alike. The tool position
> is slaved to spindle angle; letting the operator pause mid-thread would destroy the thread.
> Velocity-synchronized moves (`TC_SYNC_VELOCITY`) *can* be paused.
>
> Pressing pause during a G33 or G84 does nothing until the synchronized move completes. Nothing in
> the LinuxCNC Code Notes says so.

`tp->pausing` is also cleared wholesale on planner reset, alongside `aborting` and `reverse_run`
(`tp.c:433-448`).

#### 5.7 lcec internals — the parser, the generator, the device registry

**The XML grammar is a table**, not ad-hoc parsing (`lcec_conf.c:80-95`). Fourteen element types with
an explicit parent→child relation and a per-element attribute handler:

```
masters > master > slave > { dcConf | watchdog | initCmds | modParam
                           | sdoConfig > sdoDataRaw
                           | idnConfig > idnDataRaw
                           | syncManager > pdo > pdoEntry > complexEntry }
```

Note `idnConfig` / `idnDataRaw`: those are **Sercos IDNs**, so the driver speaks SoE (Sercos over
EtherCAT) as well as CoE.

**`lcec_configgen.c` writes your config for you from a live bus.** It shells out to `ethercat slaves`,
`ethercat sdos`, `ethercat pdos` and `ethercat upload`, parses the output, looks up matching drivers
in the in-process registry linked from `liblcecdevices.a`, and emits an XML skeleton on stdout. It is
a **2026 C port of an earlier Go implementation** (`src/configgen/lcec_configgen.go`), by Luca
Toniolo after Scott Laird's original — one of the newest pieces in the project.

**Device drivers are registration tables, not code per device.** Each driver file declares a static
`lcec_typelist_t types[]` where one row binds a part number to a VID:PID and an init function:

```c
{"EL1002", LCEC_BECKHOFF_VID, 0x03EA3052, 0, NULL, lcec_el1xxx_init, NULL, EL1XXX_F_CHANNELS(2)},
{"EL1004", LCEC_BECKHOFF_VID, 0x03EC3052, 0, NULL, lcec_el1xxx_init, NULL, EL1XXX_F_CHANNELS(4)},
```

So `lcec_el1xxx.c` alone covers the whole EL1002/1004/1008/1012/1014/1018 family through one init
function plus a channel-count flag.

The counts, kept distinct because they are easy to conflate:

| What | Count |
|---|---|
| driver files (`src/devices/lcec_*.c`) | 60 |
| `ADD_TYPES` registration calls | 64 |
| **`types[]` rows — i.e. supported devices** | **~260** |
| device rows listed in `DEVICES.md` | 265 |

> **Correction, 2026-08-03.** An earlier revision offered "64 `ADD_TYPES` registrations" as though it
> were the device tally. It is the number of registration *calls*; the device count is roughly four
> times that.

**`documentation/DEVICES.md` is honest about coverage.** 279 lines, a table of
description / driver / VID:PID / device type / **testing status** / notes, opening with:
*"This is a work in progress, listing all of the devices that LinuxCNC-Ethercat has code to support
today. **Not all of these are well-tested.**"* Many rows have a blank testing status; some read
"Part of @scottlaird's test suite". For a machine builder that column is the most useful thing in the
repository.

### Still open

- **The 57 undocumented motion commands.** Grouped by theme in the errata document, but documenting
  them properly from the code is a *contribution to LinuxCNC*, not an audit finding. Out of scope
  here.
- **The individual lcec device drivers.** The registration mechanism, the parser and the generator are
  now understood (§5.7); the per-device PDO mappings inside the 60 files are not, and auditing them
  without the corresponding hardware would be sterile.
- **`LCNC_Architecture_C1.drawio`** — the C4 *context* diagram, first waved off here as making no
  falsifiable claim and being of low audit value. **That assessment was wrong twice over**, and is
  left on record: its connection claims are falsifiable, and two are false — the terminal tools'
  only link points at the core when two of the three are HAL clients, and the embedded panels lack
  the HAL link that is their whole purpose. Audited 2026-08-05, verified line by line 2026-08-06,
  and published as the third sheet, `sheets/linuxcnc-context-diagram.html`. Deliberately
  **not** folded into the errata numbering: the figure lives in `about-linuxcnc.adoc`, outside
  Part 3's scope, and the sheet carries its own evidence.
- **Other files in `docs/src/code/`** — style guide, building, writing tests. Process documents, not
  architecture claims. Not audit targets.

### Out of reach from source alone

- **The practical effect of the RTAI/EtherCAT gap** — *closed 2026-08-06, and not by hardware.*
  This item asked for a scope and a machine, to measure what the RTAI resync stub does to SYNC0
  phase. The question was malformed: lcec does not build for RTAI
  (`linuxcnc-ethercat/src/Makefile:62-76`), so there is no configuration in which the effect
  occurs. There is nothing to measure. See §2.9.1. **The lesson outlasts the item:** it stood here
  for three days as *"cannot be closed by reading code"*, and reading one Makefile closed it.

- **Do the shipped networked NML configs still hold `EMC_STAT`?** *Opened 2026-08-07.* The
  default `configs/common/linuxcnc.nml` declares `emcStatus` at **20480** bytes; the two
  networked configs, `client.nml` and `server.nml`, declare **10240**. **What is verified:** the
  divergence itself, read in all three files; and that the default tracked the struct while the
  other two did not. The default was raised to **170000** on 2020-04-07 (`b51ef8cc3c`, *"increase
  max tools from 55 to 1000"*) and cut to **20480** on 2021-01-31 (`2dbb2f640f`, the `tooldata`
  refactor that moved the tool table out of status). The `emcStatus` line in `client.nml` has
  **never been edited** — its only appearance in the history is a file move (`48e0f02754`), so
  10240 predates both changes. Also verified: NML gives a message only **half** the declared
  buffer, `max_message_size = (size_without_diagnostics / 2) - total_connections -
  encoded_header_size - 2` (`src/libnml/cms/cms.cc:729-731`), and under `xdr` the *guaranteed*
  space is divided again by `cms_encoded_data_explosion_factor`, which is **4**
  (`cms.cc:47`, used at `:735`). So 10240 declared leaves roughly 5 KB of message and ~1.3 KB
  guaranteed. **What is NOT verified, and why this is here rather than in the errata:**
  `sizeof(EMC_STAT)`. Measuring it needs a Linux build of the tree; this machine has no
  compiler, and adding up nested struct fields by hand — 16 joints, 9 axes, `LINELEN` strings,
  alignment and padding — is precisely the plausible-and-wrong arithmetic this audit exists to
  avoid. **The inference, labelled as such:** raising the default to 20480 *after* the refactor
  suggests 10240 no longer suffices, in which case both networked configs have shipped
  unusable since 2020. That is a suspicion, not a finding.
  **One command closes it**, and LinuxCNC ships it — `src/emc/tooldata/tool_watch.cc:56-66`
  prints the whole family:

  ```
  tool_watch
  ```

  It reports `sizeof(EMC_STAT)` and then `EMC_IO_STAT`, `EMC_TASK_STAT`, `EMC_MOTION_STAT`,
  `EMC_TRAJ_STAT`, `EMC_JOINT_STAT`, `EMC_AXIS_STAT`, `EMC_SPINDLE_STAT`. Compare the first
  figure against ~5 KB (the usable half of 10240) and against ~10 KB (the usable half of 20480).
  That the maintainers ship a tool whose job is to watch this number is itself a hint that it
  has been a problem before.
  *Citations here are prose, not manifest entries — widening the manifest is Open action 7 and
  doing it inside an unrelated change is the error that action warns against.*

---

## Part 6 — G-code reference audit (sampled) and the work products

### 6.1 Scope

A *targeted* audit of `docs/src/gcode/g-code.adoc` against `src/emc/rs274ngc/` — the sections tied
to spindle synchronization and path control: **G33, G33.1, G76 (head), G64, G96/G97**. The reference
is 2 786 lines; everything outside those sections is unaudited.

### 6.2 Errata 26–27: the reference documents errors that do not exist

| # | The reference claims | The code says | Evidence |
|---|---|---|---|
| 26 | G33 and G33.1: *"It is an error if … The requested linear motion exceeds machine velocity limits due to the spindle speed"* | **No such check exists** — not in the interpreter, not in task, not in motion. The real G33 checks are: an axis word present, **K present** (`NCE_K_WORD_MISSING_WITH_G33`), **F absent** (`NCE_F_WORD_USED_WITH_G33`), `$` valid, spindle *commanded* turning. The two real checks were missing from the documented list; the phantom one was present. | `interp_check.cc:375-378`, `interp_convert.cc:5496-5529` |
| 27 | G96: *"It is an error if … A feed move is specified in G96 mode while the spindle is not turning"* | **No such check exists anywhere.** The spindle-not-turning checks apply only to G33/G33.1/G76 and the tapping cycles (`interp_cycles.cc:270`). A plain G1 in CSS mode with a stopped spindle is accepted. | grep of `rs274ngc/`, `task/`, `motion/` |

Nuances recorded with them: "spindle not turning" tests `settings->spindle_turning[]` — the
**commanded** M3/M4 state in the interpreter's model, not measured rotation. G33.1's `I` multiplier
below 1 is silently clamped to 1 (`interp_convert.cc:5522-5527`). G64/G61 path-mode changes are
refused under cutter comp (`interp_convert.cc:2221`) — absent from the doc. G96 without `D` applies
**no** RPM limit: `SET_SPINDLE_MODE(s, 1e30)` (`interp_convert.cc:5087`).

**A pattern worth naming:** both phantom errors describe *physically sensible* constraints — things
a reader would believe a CNC ought to check. That is precisely why nobody caught them: they are
plausible. The documentation does not just rot by aging; it also contains **invented safety checks**
that were perhaps once planned and never implemented.

### 6.3 In-code defects found in passing (code, not docs)

| Where | Defect |
|---|---|
| `interp_convert.cc:5534` | G76's `$`-validity check reports *"Invalid D-number in G76 cycle"* — wrong word name, inconsistent with G33's message |
| `command.c:1475`, `:1553` | PROBE and RIGID_TAP carry the copy-pasted comment *"requires coordinated mode, enable off"*; the test requires enable **on** |
| `command.c:1966` | `SET_AXIS_LOCKING_JOINT` debug message prints `SET_AXIS_ACC_LOCKING_JOINT`, a name matching no command |

#### 6.3.1 The two networked NML configs instruct the user to run software that no longer exists

*Found 2026-08-07, while answering a question about remote operation.* **Not numbered among the
errata**, for the same reason the context-diagram findings were not: errata 1–38 are against the
Code Notes, and these are config files.

`configs/common/client.nml` and `configs/common/server.nml` are the shipped examples for running
a GUI on one machine and the realtime side on another. Their header comments are the only
instructions a reader gets, and three of their statements are stale:

| Statement | State at `caa13ca6ae` |
|---|---|
| `client.nml`: *"run the GUI with: `tcl/tkemc.tcl -ini emc.ini`"*, and *"Note: tkemc.tcl does not need to be run as 'root'"* | **`tkemc` is gone from the tree.** A whole-repository search returns five matches, all `.png` screenshots under `docs/`. No script, no executable. |
| both: *"Change the `NML_FILE` in `emc.ini`"* | **No file named `emc.ini` is shipped** — zero matches. The variable itself is fine and current: `ini-config.adoc:301` documents `NML_FILE`. Only the filename is a fossil. |
| both: *"a networked **emc2** system"* | The project was renamed to LinuxCNC. Cosmetic, but it dates the text: one occurrence in `client.nml`, two in `server.nml`. |

**The framing fact, and it explains the rot:** *neither file is installed.* `src/Makefile:745-746`
copies only `linuxcnc.nml` and `linuxcnc_big.nml` into `$(prefix)/share/linuxcnc`. A user who
installs from a package never receives `client.nml` or `server.nml`; they exist for whoever reads
the source tree. Nothing ships them, so nothing exercises them, so nothing caught the drift.

**Severity, stated honestly:** low for the ordinary user, who never sees these files; real for
the reader who goes looking for how to run LinuxCNC over a network, since what they find is the
only guidance offered and it names a GUI that cannot be started. **A fourth problem in the same
two files is *not* asserted here** — the `emcStatus` buffer at 10240 bytes — because
`sizeof(EMC_STAT)` was never measured. It is recorded in Part 5, *Out of reach from source
alone*, with the command that settles it.

#### 6.3.2 The start script renames a dead program to another dead program

*Found 2026-08-07, while tracing where the name EMCTASK comes from.*

```
scripts/linuxcnc.in:524    if [ "$EMCTASK" = emctask ]; then EMCTASK=linuxcnctask; fi
```

A compatibility shim, translating an old value of the INI key `[TASK]TASK` into a newer one.
**Both names are dead.** `linuxcnctask` occurs **exactly once in the whole repository — on that
line, the line that produces it**; it is never built, never installed, never referenced anywhere
else. `emctask` has no build target either. The only surviving `emctask` is the *source file*
`src/emc/task/emctask.cc`, which is compiled into `milltask`.

The consequence is a misleading error rather than a failure to run. A user whose INI still says
`TASK = emctask` — copied from an old configuration, or from documentation of that vintage — is
tested at `:825` and told at `:826`:

```
Can't execute TASK program linuxcnctask
```

naming a program they never wrote and cannot find anywhere in LinuxCNC, instead of the name they
did write. **Severity: low, and the fix is a deletion.** The shim protects nothing, because the
name it produces has not existed for as long as the name it replaces.

#### 6.3.3 `[TASK]INTERP_MAX_LEN` is read by task and documented nowhere

*Found 2026-08-07, while checking whether `interp_list` is really unbounded.*

Task reads the key at `emctaskmain.cc:3151`:

```c
if (auto inival = inifile.findSInt("INTERP_MAX_LEN", "TASK")) {
    emc_task_interp_max_len = *inival;
```

and it governs how far the interpreter may run ahead of the machine — `:493` and `:692` stop
reading above it, `:613-615` resume at two thirds of it. The default is **1000**
(`emccfg.h:34`, `DEFAULT_EMC_TASK_INTERP_MAX_LEN`).

**It appears nowhere in the documentation.** A case-insensitive search of the whole `docs/`
tree at `caa13ca6ae` returns nothing outside the translation catalogues. **Counter-proof:** the
`[TASK]` section of the INI reference does exist, at `ini-config.adoc:693`, and does document
`TASK = milltask` — so this is a missing entry in a section that is otherwise present, not a
missing section.

Consequence: the only tuning knob for interpreter look-ahead is invisible to anyone who has not
read `emctaskmain.cc`. **Not numbered among the errata** — those are against the Code Notes, and
this is the INI reference.

### 6.4 Work products

| Artefact | What it is |
|---|---|
| `tools/verify-citations.ps1` + `tools/citations-manifest.json` | Machine-checks every citation in this file against both clones. Run after any `git pull`; a FAIL means re-anchor the citation, not necessarily that the finding is wrong. |
| `upstream/0001…0003.patch` + `upstream/README.md` | Three reviewed patches on the `audit-fixes` branch of the clone, fixing errata 15–17, 19, 21–23, 25–27 in `basic-hal.adoc`, `code-notes.adoc`, `g-code.adoc`. Submission is the user's, under their identity. |
| `motion-commands-reference.md` | The complete 76-command inventory written from `command.c` — the Code Notes' missing chapter, with per-command gates and a verification-status statement. |

---

## Appendix — constants worth knowing

| Constant | Value | Source |
|---|---|---|
| `HAL_KEY` | `0x48414C32` | `hal_priv.h:120` |
| `HAL_VER` | `0x00000013` | `hal_priv.h:121` |
| `HAL_SIZE` | 2 MiB | `hal_priv.h:122` |
| `HAL_STREAM_MAX_PINS` | 21 | `hal.h:1236` |
| `STREAMER_SHMEM_KEY` | `0x48535430` | `components/streamer.h` |
| `SAMPLER_SHMEM_KEY` | `0x48534130` | `components/streamer.h` |
| `DEFAULT_SHMEM_KEY` | 100 | `emcmotcfg.h:49` |
| `EMCMOT_MAX_JOINTS` | 16 | `emcmotcfg.h:25` |
| `EMCMOT_MAX_AXIS` | 9 | `emcmotcfg.h:31` |
| `EMCMOT_MAX_SPINDLES` | 8 | `emcmotcfg.h:33` |
| `EMCMOT_MAX_DIO` / `AIO` | 64 / 64 | `emcmotcfg.h:34,35` |
| `EMCMOT_ERROR_NUM` × `LEN` | 32 × 1024 | `emcmotcfg.h:42,43` |
| `DEFAULT_TC_QUEUE_SIZE` | 2000 | `emcmotcfg.h:70` |
| `DEFAULT_EMCMOT_COMM_TIMEOUT` | 1.0 s | `emcmotcfg.h:52` |

### A recurring pattern: names outlive structures

Three times in this audit a name survived what it designated:

- Pins are still `iocontrol.0.*` though the `iocontrol` process is gone.
- The INI section holding `RANDOM_TOOLCHANGER`, `TOOL_TABLE` and `DB_PROGRAM` is still `[EMCIO]`,
  named after a component that no longer exists (`taskclass.cc:141-147`).
- `motion-traj-planner` is still exported in source form, inside `#if 0`.

This is deliberate backward compatibility — thousands of user `.hal` and `.ini` files keep working.
But it is exactly why documentation ages badly here: **the names stay right while the structure they
describe has been dismantled.** A reader trusting the names will conclude `iocontrol` is a process.
It has not been one for a long time.

---

## Verification rules earned from this audit

Not principles chosen in advance. Every line below is the residue of a specific failure in this
work, and the changelog entry that records it is named.

**The general rule.** Verify at the level where the failure would hurt, and choose a second check
that fails *differently* from the first. Two checks sharing one blind spot are one check with extra
steps. The instances:

| Object | The check that counts | Learned from |
|---|---|---|
| A patch | apply it **and read the produced text** — `git apply --check` validates the diff's mechanics, never its meaning | 2026-08-05: a patch can apply cleanly and say the wrong thing |
| A published file | read the blob back **from the remote**, not the local copy | 2026-08-03: mojibake shipped for a day, invisible locally |
| A figure | a geometric test — does a connector cross a box it should route around | 2026-08-05: two lines cut through boxes, invisible by eye |
| A number repeated across documents | extract **every** value attached to the concept and look for variants; never confirm the one you expect | 2026-08-04: two stale counts survived a pass that asserted consistency |
| An execution order | read the **shipped configuration**, not the source — in LinuxCNC the order is config data | 2026-08-05: a whole cycle step was missing from a figure |
| A citation | machine read-back of the cited line | 2026-08-03: two off-by-ones, invisible to eye inspection |
| A live page | fetch it over HTTP; a matching git hash is not a served page | 2026-08-04 |
| **A checker's own input set** | confirm it *has* an input — a filter that silently drops elements makes every rule below it vacuous | 2026-08-07: `ORTHO` in `diagram-check.js` had no `-?`, so **every path with a negative coordinate left the checked set without a word**. One connector in the system-overview sheet qualified — the one routing through the negative-x gutter the page argues for — and it had never been checked, for crossings or for landings, across every clean run ever reported. The tell was a persistent off-by-one between the checker's path count and a count taken outside it |
| **A graph built from a drawing** | count the edges that *resolve to two boxes*, and separately the edges that exist — the difference is the defect | 2026-08-07: `emcmot ↔ servo-thread`, the thickest connector on the figure, had lost its target and was anchored to a fixed point. It looked correct. Every check that counted only edges with both endpoints skipped it in silence. Three further edges carried stale fallback points behind valid references — the same defect, dormant |
| **A box in a diagram** | ask whether anything *reaches* it, not only whether arrows *land* on something | 2026-08-07: rule 3 had always asked the second question. Nothing asked the first, and the drivers and the machine sat as an island for as long as the figure existed. Implemented as `diagram-check.js` rule 7, on connected **components** rather than degree — a detached panel may be wired internally and still be off the machine graph |
| **A check that FAILS** | scrutinise it exactly as hard as one that passes | 2026-08-07: a verification reported a caption absent from an export. The caption was there; the search string was wrong. A failing check that is itself wrong sends you to repair what is already correct |
| **Coverage** | derive the expected set from the **source document**, not from your own table of contents | 2026-08-05: four passes missed a diagram because all of them checked the claims that *were* made |
| **A causal claim** | verify the **gate**, not only the destination — a citation proves a line exists, never that control flow reaches it | 2026-08-06: a four-step mechanism, every line correctly cited, describing a path that is never entered |
| **A quotation from a third party** | read the source with `gh`, never through a summarising fetch | 2026-08-06: a paraphrase dropped one word — *supported* — and would have produced a public correction of a claim never made |
| **A sweep for a class of error** | check what the search **excludes**, not only what it matches — a filter written to suppress noise will suppress signal that shares its shape | 2026-08-06: a line-range exclusion for changelog noise hid a live claim, which the reporter had to name |
| **A grouping frame in a figure** | test that it **encloses what its label claims** — a frame is an assertion about membership, and a checker aimed at collisions never reads it | 2026-08-06: a box labelled *non-realtime processes* left two non-realtime processes outside; the reader saw it, four automated passes had not |
| **An arrow** | test that it **terminates on a named target** — a leaf box, or a frame's *edge*; never a frame's interior | 2026-08-06: an arrow stopped 80 px short of the box it pointed at. The first checker written for this passed everything, because a point inside a large frame counts as "inside a rect" |
| **A checker you just wrote** | feed it the defect it exists to catch, and require it to fail — an unexercised checker certifies nothing | 2026-08-06, three times in one afternoon: a collision test blind to vertical segments, a landing test that accepted any point on the canvas, and a containment test that only worked once frames were told apart from boxes |
| **A double-headed arrow** | check what the renderer *draws*, not what the markup says — SVG `orient="auto"` points the start head **along** the path, so a two-marker arrow shows two heads the same way; `auto-start-reverse` is the fix | 2026-08-06: 31 arrows across four figures claimed to be bidirectional in the markup and rendered unidirectional on screen. Every geometry check passed throughout — they measure positions, never semantics |

**The last line is the one that took longest to learn.** Verification confirms what is present and
is structurally blind to what is absent. The citation verifier passed 111/111 throughout the period
when two of its own figures were stale and a third of the document's diagrams had never been looked
at. Coverage needs its own oracle, and it must come from outside the work being checked.

**Where none of this reaches.** Everything above is a software check. Nothing in it crosses into
hardware: the SYNC0 phase behaviour in §2.9 and `ETHERCAT-NOTES.md` is what the source says, and it
would take a machine and a scope to say more. A verification discipline that obscured that boundary
would be worse than none.

---

## Changelog

| Date | Change |
|---|---|
| 2026-08-08 (LCNC_04, third pass) | **A rule stated in prose cannot contradict another one out loud; a rule that executes can.** Every checker in this project so far read the *generated SVG*. That was a default, never examined, and it put whole classes of defect out of reach: the SVG carries no parent relations, no `source`/`target`, no style colours, and — as this pass discovered — **not the edge labels at all**, which the converter silently drops. A label overlapping a caption therefore stayed invisible until a human looked at a PNG export. **A checker that reads the `.drawio` model was written** (`drawio-check.ps1`, seven rules, each refusing to run unless it first fails on a deliberately broken copy). What the model settles that the SVG could only guess: a dangling connector is *an edge without `source` or `target`* rather than an endpoint within 14 px of something; containment is `parent`, so **a declared parent that does not geometrically contain its child** becomes detectable — the exact defect that footnote (1) of the sheet removed the domain frames for, and which no SVG check could ever see; and the colour rules printed on the sheet's own legend become executable. **Its first run on a figure believed finished returned two real defects and no false positive.** One of them is that **the figure asserts something about itself that is false**: the legend prints four colour rules and the sentence *"All four hold as drawn"*, and the fourth — *"every WHITE box must carry at least two links"* — does not hold, because `base-thread` carries one. That single link is itself a deliberate decision recorded elsewhere in this audit: the servo thread hands the base thread work through `stepgen`'s own state, which is neither a pin nor a signal, so by the project's *information crossing → line, code touching code → text* criterion it is text and not an arrow. **Two of our own rules contradicted each other, and both were true in isolation.** Neither prose nor a reader had caught it in two days; the model check caught it in one second. *The honest division that follows:* **the model carries the logic, the render carries the geometry of the lines.** Connector routing is not in the model — draw.io computes it at display time and stores only waypoints — so *"does this line cross that box"* stays with the SVG checker, as does rendered text width, for want of a font. Two checkers, two domains, and each must state where it stops. |
| 2026-08-08 (LCNC_04, later) | **A rule that corrects the one written hours earlier: a second oracle that shares the first one's environment is not a second oracle.** The entry below records a reported connector/text crossing being dismissed after a direct `getBBox` measurement put the text's left edge at x=825.5 against the connector's x=815. **That was wrong, and the crossing was real.** Measured again on the same two files, the caption runs from **x=781.3 to 1218.7** — the connector was inside it, and it was the *first* measurement that had resolved a narrower fallback face, 349 units of rendered text against 437. `getBBox` and the checker disagreed about the verdict while agreeing about the font, so measuring more carefully **in the same browser** could only reproduce the same accident with more decimal places. The two oracles were independent in method and identical in the thing that actually varied. **The repair is geometry robust to the range, not a ruling on which font is right:** the link now runs through a corridor 31 units clear of the text in the widest rendering observed and further in the narrow one. *General form, and it is the transferable part:* **when a check's verdict depends on the environment, make the artefact survive the whole range rather than picking the reading that lets you leave it alone.** Three further layout defects were fixed in the same pass and are recorded on the sheet as footnote (12). **A fourth rule, earned the same way:** repairing the first connector left its arrow seven units short of its box, because the converter decided whether a segment was horizontal or vertical **by exact equality** while the SVG export rounds to the unit — so a segment one unit off true matched neither branch, nothing was reported, and a box became unreachable. The test is a tolerance now, and **the verdict went FAIL → clean on the same file inside one pass**, which is the only real evidence that a check is doing work. |
| 2026-08-08 (LCNC_04) | **The system-overview figure is no longer written by hand: it is generated from a `.drawio`, and the return trip is what this entry records.** The drawing moved into a real editor so the reader could move a box and see the result — ten passes of correction had been made by editing SVG, which put the only person who could change the layout in the position of not being able to see it. `drawio-to-svg.ps1` v2 takes **the geometry of the boxes from the model and the routing of the arrows from draw.io's own SVG export**, because draw.io has already solved routing and v1's naive Z-routes crossed thirty boxes; the render→model offset is *derived* by matching rectangles on (width, height), 100 % agreement on 26, so the pairing is checked rather than assumed. **Only the `<svg>` block is replaced**, so the page's prose and its footnoted evidence make no round trip and cannot be damaged by one. Verified: citations **190/190**; `diagramCheck` **4 errors on three consecutive runs = two layout defects counted twice each**, plus a third that no check here can see — the two boundary lines span the canvas and pass behind the legend panel, and boundaries are exempt from the connector check by design. All three are recorded on the sheet rather than carried quietly. **Four rules earned, each from something that went wrong.** *(1) A name collision can silence a function completely and change more than it appears to:* a helper named `SV` was shadowed by PowerShell's alias for `Set-Variable`, so every style lookup returned nothing — **all colours came out `none`, and so did every text alignment**, without one error message. The `diagramCheck` verdict taken before the fix therefore described a figure whose text was in the wrong place; **a verdict is only about the artefact that produced it.** *(2) A geometric check that involves text is only as reproducible as the font that loads:* a crossing was reported once and not again on the same file; measured directly with `getBBox` — an oracle that fails differently from the checker — the text's left edge is at x=825.5 and the connector at x=815, so it clears by ten units. Had it been trusted, a connector that touched nothing would have been moved. *(3) A generated document should reach a **fixed point**:* re-converting the published page must return the published page, and it does, to the character. *(4) The prose around a figure ages while the figure is worked on, and no script reads it.* Four statements on the sheet had become false without anyone touching them — the number of domain markers, the claim of *no containers*, the count of corrections, and a verification note quoting the counts of a figure that no longer existed. **Worse than a false statement is an argument that reverses:** footnote (9) had justified deleting the NML compartments with *"with no named compartment for an arrow to point at, the per-channel claim can no longer be made"*, and the reader then asked for the compartments back. The published argument contradicted the published figure. It is recorded as a reversal, with a **replacement guarantee that is checkable where the old one was structural** — *no connector lands on a compartment*, verified in the model, five NML edges out of five targeting the parent box. |
| 2026-08-07 (LCNC_04) | **Four new facts, one erratum against our own published sheet, and four verification rules.** §2.4 gains the **tool table** as a third shared region — a file-backed `mmap`, created by milltask (`taskclass.cc:162`) and attached by the GUIs (`emcmodule.cc:1010`) and halui (`halui.cc:2151`), read-write on both sides (`tooldata_mmap.cc:151-152`, `:186-187`) under a mutex (`:164`), and **wholly non-realtime**, so unlike the other two it never straddles the scheduling boundary. §2.5 gains **§2.5.1**: `motmod` exports exactly two thread functions (`motion.c:1030`, `:1037`), a third sits dead in `#if 0` at `:1044-1056` whose comment states the structure — *"currently the traj planner is called from the controller"* — and the **execution order is configuration**, measured across the 189 shipped `.hal` files: of the 55 that `addf` both a hardware read and `motion-command-handler`, **54 put the read first and one does not** (`GM6-PCI/3-axis-servo.hal` reads its board after the controller). An earlier pass had inferred that bracket from two files; the measurement is stronger and names the exception. Reading file order is legitimate because `addf`'s position defaults to −1 (`halcmd_commands.cc:276`) and −1 means *from the tail* (`hal_lib.c:2930`). §2.7 gains what **`loadrt` actually is**: on uspace it runs a program — `rtapi_app load <mod>` (`halcmd_commands.cc:918`, `:922`, `:925`) — while the `#else` branches load kernel modules (`:934`, `:1157`); so `rtapi_app` is the process every realtime component is `dlopen`'d into (`tpmod.c:31`). §2.8 gains an **erratum against our own work**: the system-overview sheet shipped *"not a kernel boundary — except under RTAI"*, which overstates the exception by four flavours out of five — `uspace/RTAI` runs realtime in user space. Corrected, and **published 2026-08-08**. New **§2.11** counts GUI-created HAL pins — axisui **16** (`axis.py:3951-3966`), qtdragon **18** in its shipped handler, none of them integrator widgets — which inverts a circulating claim that modern GUIs create only widget pins; and records that **QtPyVCP and ProbeBasic are not in this tree at all** (0 files), qtdragon being a `qtvcp` screen. *Verification rules:* a checker's own input set must be confirmed non-empty (`ORTHO` silently dropped every path with a negative coordinate); a graph built from a drawing must count edges that *resolve*, not edges that exist (the figure's thickest connector had lost its target and was anchored to a point); a box must be asked whether anything **reaches** it, not only whether arrows land on something (now `diagram-check.js` rule 7, on connected components); and a check that **fails** deserves the same scrutiny as one that passes. |
| 2026-08-07 | **`interp_list` was published as "unbounded" in three places, and that was the audit's own rule broken on itself.** A reader asked why the box had a different colour in the working figure; checking the colour led to checking the label, and the label was the wrong level of description. The container genuinely has no limit — `append()` (`interpl.cc:33`) validates the pointer, the type and a size below 4, and never checks capacity. **The producer does have one.** `emctaskmain.cc:493` reads further only while `interp_list.len() <= emc_task_interp_max_len`, `:692` returns early above it, `:613-615` resume only at two thirds of it, and the limit defaults to **1 000** (`emccfg.h:34`), set by `[TASK]INTERP_MAX_LEN` (`emctaskmain.cc:3151`). Nothing fills the deque past about a thousand entries. **Verify the gate, not only the destination** — the rule this project wrote after the jerk and RTAI corrections, and it had been broken here since publication. Corrected in all three published places: §2.4's capacity cell, the label at `linuxcnc-code-notes-errata.html:448`, and the description plus `cap`/`cap2` in `linuxcnc-command-flow.html:358`, whose prose knew one drain (`emcTaskPlanSynch`) and not the one that matters. §2.4 carries a correction note rather than a silent repair. **A second finding fell out of the same check:** `[TASK]INTERP_MAX_LEN` is read by task and appears nowhere in the documentation — recorded as §6.3.3, with the counter-proof that the `[TASK]` section itself exists at `ini-config.adoc:693`. **And a note on the colour that started it:** the amber was not invented, it was inherited badly. The errata sheet uses `#B06E12` as its accent for `.bx-q` and for numbered erratum markers, and the `interp_list` box there carries marker 10 — *"No queue shown anywhere"*. The working figure copied an approximation of that accent, `#b08a2e`, without the marker and without the errata list, into a page with no legend. A colour can carry meaning and lose it in transit. |
| 2026-08-07 | **What `milltask` is made of, why EMCTASK appears in unrelated places, and a fossil in the start script.** Prompted by a reader asking both questions at once. `src/emc/task/Submakefile:14-26` lists twelve sources and `:32-35` the linked libraries; three of the libraries carry the architecture. **`librs274.so.0` means the interpreter is not inside milltask but shared**, and the same code runs in the GUI's previewer, told apart by one flag — `extern int _task; // zero in gcodemodule, 1 in milltask`, declared identically in three files (`interp_namedparams.cc:807`, `interpmodule.cc:39`, `pyparamclass.cc:28`). **`liblinuxcnchal.so.0` means milltask is a HAL component**, the mechanical confirmation of erratum 3: EMCIO is not a process, its work is here. And `usrmotintf.cc` being compiled in is a second confirmation that task attaches the `emcmot` segment itself rather than going through a server. Recorded in Part 1's process inventory, where the binary was already listed but not opened. **EMCTASK turned out to name three unrelated things** — the 2012 component name in the docs, a shell variable in `linuxcnc.in:522` carrying the value of INI key `[TASK]TASK` (all 285 shipped configs say `milltask`), and a former binary name. **The third produced a defect, §6.3.2:** `linuxcnc.in:524` renames `emctask` to `linuxcnctask`, and *both are dead* — `linuxcnctask` occurs exactly once in the repository, on the line that produces it, and `emctask` has no build target. A user with an old `TASK = emctask` is told *"Can't execute TASK program linuxcnctask"*, a name they never wrote. Low severity, and the fix is a deletion: the shim protects nothing. The figure gained the interpreter nuance in the same pass, since a box labelled *RS-274 interpreter* inside milltask implies the code lives only there. |
| 2026-08-07 | **The networked NML configs instruct the reader to run software that no longer exists — recorded as §6.3.1, deliberately not numbered among the errata.** Errata 1–38 are against the Code Notes; these are config files, so the same rule that kept the context-diagram findings out of the numbering applies here. Three stale statements, each checked at `caa13ca6ae`: `client.nml` tells the reader to run `tcl/tkemc.tcl` and **`tkemc` is gone** (five matches repository-wide, all `.png` screenshots under `docs/`); both files say to edit `emc.ini` and **no such file is shipped** (zero matches — the `NML_FILE` variable itself is current, `ini-config.adoc:301`); both still call the project *emc2*. **The framing fact came from checking whether the erratum was worth writing at all:** `src/Makefile:745-746` installs only `linuxcnc.nml` and `linuxcnc_big.nml`, so **neither networked config is installed** — they exist only in the source tree, which is why nothing exercised them and nothing caught the drift. That reframes the severity rather than the facts, and it is stated as such. **The discipline this entry is meant to record:** the open action that produced it carried the condition *"check the rest of both files before writing it — an erratum that fixes one stale line and leaves three is worse than none."* The audit found three, not one, plus a fourth that is **not** asserted: the `emcStatus` buffer at 10240 bytes, which stays in Part 5 *Out of reach from source alone* because `sizeof(EMC_STAT)` was never measured. Writing three verified defects and withholding the fourth in the same pass is the point. |
| 2026-08-07 | **An open question recorded rather than an erratum written: do the networked NML configs still hold `EMC_STAT`?** Reading `configs/common/client.nml` and `server.nml` while answering a question about remote operation turned up `emcStatus` at 10240 bytes against the default's 20480. The history explains the gap and is verified: the default went to 170000 on 2020-04-07 (`b51ef8cc3c`, tools 55 → 1000) and back to 20480 on 2021-01-31 (`2dbb2f640f`, the tooldata refactor), while the line in `client.nml` has **never been edited** — its only history entry is a file move. Also verified: NML gives a message half the declared buffer (`cms.cc:729-731`) and divides the guaranteed space again by 4 under `xdr` (`cms.cc:47`), so 10240 leaves ~5 KB usable. **`sizeof(EMC_STAT)` was not measured** — it needs a Linux build, this machine has no compiler, and summing nested struct fields by hand is the plausible-and-wrong arithmetic this audit exists to avoid. So the consequence — that both networked configs have shipped unusable since 2020 — is filed under *Out of reach from source alone* as a suspicion with the one command that settles it (`tool_watch`, which LinuxCNC ships precisely to print these sizes), **not as erratum 39**. The restraint is the point: the previous entry in that section stood for three days as unreachable and was closed by reading one Makefile, so the section is for questions whose oracle is named, not for conclusions reached without one. No manifest entries added — widening it is Open action 7, and doing that inside an unrelated change is the error that action warns against. |
| 2026-08-07 | **`initf` is 2.10-only, and the manifest is a curated set rather than an index. Citations 173 → 174.** Comparing the two branches inside the pinned clone with `git grep <ref>` — no pull, HEAD unmoved — establishes that `hal_init_funct_to_thread` has **zero** occurrences anywhere in `origin/2.9` (`18c5bb5b1c`, 2026-07-26), that the halcmd verb is not registered there, and that the `lcec.0.activate` text of §2.9.5 is likewise absent. A counter-proof was run: the same patterns find both on `caa13ca6ae`, so the empty result is not a bad-pattern artefact. Recorded in §2.9.1 and §2.9.5. **Two consequences.** For anyone bench-testing on the official 2.9.x ISO, the clean activation path cannot be exercised at all — lcec necessarily takes the legacy inline path and prints its own warning. For PR #4349, the 2.9-applicability question now has a second and simpler answer: **patch `0001` is master-only by nature, because the text it corrects does not exist on that branch.** One citation added, `src/hal/utils/halcmd.c:138`, anchoring the counter-proof. **And a defect in this project's own tooling, found while checking whether that citation was covered:** the manifest holds 174 entries but `LINUXCNC-FINDINGS.md` contains **126 distinct `file:line` citations, 39 of which have no manifest entry** — a proportion nobody had measured. The verifier's own header claimed to *"machine-check every citation backing LINUXCNC-FINDINGS.md"*, and `ETHERCAT-NOTES.md` §8 claimed its citations were covered; both were false, and both invited the same wrong inference — that a green run means the document has been checked. It means the *manifest* has been checked. Both claims corrected to say so. Widening the manifest to real coverage is deliberately **not** done here and is recorded as an open action instead: it is a curation job, not a one-line fix, and doing it silently inside an unrelated change would be the same kind of error. |
| 2026-08-06 | **The context-diagram comparison verified line by line, corrected, and published as the third sheet. Citations 148 → 173.** The 2026-08-05 comparison of PR #3781's merged C4 context diagram was re-verified in four passes with separate oracles: every cited line re-read in the pinned clone; the published `.drawio`'s **edge graph extracted** (31 edges) rather than the figure eyeballed; adversarial greps on the gates (the whole halcmd family carries zero NML references, `emcrsh.cc` zero HAL references, and the panel pin-creation paths are reachable — `makepins.py:55`, `axis.py:3978`); and the review-thread quotes re-read verbatim with `gh`. **Both errata are confirmed structurally**: in the merged XML the Terminal box's only functional link points at the Core Runtime, and the Embedded Tabs box's only functional link points at the GUI — no edge from either to HAL. **One real defect was found in our own rebuilt view, of exactly the class this audit criticises**: it drew `linuxcncsvr` inside "The LinuxCNC task process", when the start script runs it as its own process at step 4.3.1 (*"it owns/creates the NML buffers"*, `scripts/linuxcnc.in:795`) and task at 4.3.7, the kill list naming `linuxcncsvr milltask` side by side (`:678`). Corrected — the box is now two. Three fidelity slips also fixed and recorded in the sheet's own correction note: a c-morley quotation had silently repaired his "interrogators" into "integrators" (restored verbatim with [sic]); the as-published view wrote "joints, spindles" where the merged file says "axes, spindle" (published wording restored, the joints question moved to the *left alone* list); and the wizard names drifted from the published `PNCconf / Stepconf`. The *Still open* entry for `LCNC_Architecture_C1.drawio` — which had waved the figure off as unfalsifiable and of low audit value — is rewritten to say it was wrong, twice over. 25 citations added, one per drawn claim, including the three NML channel lines, both shared-memory keys, the error ring's refuse-newest guard, and the funct names. Deliberately **not** added to the errata numbering: the figure lives in `about-linuxcnc.adoc`, outside Part 3's scope. The three `upstream/*.patch` files were also regenerated from the submitted branch, so their `From` hashes are byte-for-byte the commits of PR #4349; re-verified two ways on the pinned master — `git apply --check`, then a real apply with the produced text read back. |
| 2026-08-06 | **§2.9's RTAI framing withdrawn — the second gate-check failure of the day, from the same reviewer. Citations 146 → 148.** grandixximo filed issue #1 against §2.9: framing the RTAI resync stub as a practical consequence implies a configuration that cannot be built. **Verified, and the evidence is harder than the issue states.** lcec does not build for RTAI — the kbuild branch is commented out under *"Rules for building RTAI. Currently disabled, and needs updated to work"* (`linuxcnc-ethercat/src/Makefile:62-76`), and the only live `realtime` target links a userspace `lcec.so` (`:82,104`). `src/Kbuild` survives but is **stale**, naming three common objects (`:3`) against the Makefile's six (`:18`), so uncommenting would not even link — a point neither side had made. **One claim in the issue does not hold:** RTAI was not absent from the driver's history, it was *deprecated* — the rules exist in comment form, and `debian/changelog` retires them in release 0.9.3, March 2018. **One claim could not be checked:** that the packaged IgH master lacks RTAI support concerns an external Debian package present in neither audited repository, so it is not repeated as established. Rewritten in §2.9.1 and §2.9.4, and in `ETHERCAT-NOTES.md` §1 and §5 (retitled *"RTAI: a closed door, not a trap"*). The narrow finding stands unchanged: the primitive is a no-op on both RTAI backends and implemented only in `uspace_rtapi_main.cc:1676`. Two citations added on the driver's build system, chosen as tripwires against a future re-enabling; the changelog line was deliberately **not** cited — that file is newest-first, so the line drifts on every release and would fail for reasons unrelated to the claim. **This is the same error as the jerk correction, hours apart:** a consequence asserted without checking that the configuration exercising it is reachable. A sweep of the remaining *practical consequence* claims confirmed one — pause bypassed during threading — whose path checks out end to end (`interp_convert.cc:5505,5520,5644,5651,5656` → `emccanon.cc:1503` → `command.c:1019` → `tp.c:4160-4164`, mode 0 giving `TC_SYNC_POSITION`, exempted from pause and feed override at `tp.c:243,251-252`). **That sweep was itself defective**, and is recorded as such: its search excluded lines 1000-1199 to suppress changelog noise, and the filter swallowed a live claim along with it — the *Out of reach from source alone* item asserting the RTAI effect *"cannot be closed by reading code"*. The reporter had named that very text in his issue; this pass had to be told about it. Now corrected, with the same claim in `ETHERCAT-NOTES.md` §7 narrowed to the `uspace` path, where hardware genuinely is required. Both were found only after reading the issue **verbatim** rather than through a summarising fetch — which had also dropped the word *supported* from his central sentence, and would have led to correcting him in public over a claim he never made. |
| 2026-08-06 | **The 2026-08-05 correction was itself wrong, and re-verification replaced its mechanism. Citations 139 → 146.** The conclusion held — jerk limiting applies only where it is configured, and a stock machine decelerates on a trapezoidal profile — but the *reason* given is not what the code does. The entry below has the jerk-limited path being attempted, `ruckig_plan_position()` refusing, `tpCalculateSCurveAccel()` returning `TP_SCURVE_ACCEL_ERROR`, and `tp.c` reverting. **That path is never entered.** Jerk limiting is gated by a selector: `[TRAJ]PLANNER_TYPE` defaults to `0` = trapezoidal (`emccfg.h:57`, `initraj.cc:157`); a configuration asking for `1` with a jerk below `1.0` is silently forced back to `0` (`initraj.cc:159-162`, and `inihal.cc:320-321` on the HAL-pin route); and `tp.c` enters the S-curve branch only for type `1` (`tp.c:3660,3664`), as does the jog/home planner (`simple_tp.c:23`). So `tpCalculateSCurveAccel()` is **never called** on a default machine, and the guards at `tp.c:2759-2762` and `ruckig_wrapper.c:236-241` are defence in depth — reachable only because `EMCMOT_SET_PLANNER_TYPE` (`command.c:1218-1227`) omits the jerk guard the INI and HAL routes apply. Of the 324 `.ini` files under `configs/`, exactly two set `MAX_JERK` and the same two set `PLANNER_TYPE`. Corrected in erratum 25, §5.6, the manifest, `README.md`, and patch `0002` (regenerated from the branch, not edited); the two sheets were already correct and were completed to name `PLANNER_TYPE` beside `MAX_JERK`. **The entry below is left exactly as written**, as the 2026-08-04 entry was: a changelog records what was concluded at the time. **The rule this earned** is now in *Verification rules earned from this audit* — the verifier passed 139/139 while attesting a mechanism that does not run, because a citation proves a cited line exists and says what it was said to say, never that control flow reaches it. Where a claim is causal, the gate needs verifying as well as the destination. |
| 2026-08-05 | **First correction from an external reviewer. Citations 134 → 139.** grandixximo, reviewing the three patches on PR #3718, reported that he had checked the claims at the cited locations — buffer types, the `OVERRIDE_LIMITS` mask, the 76/73 count, the `ENABLE`/`STEP` rejections, the G33/G33.1/G64/G96 checks — and that *"everything I verified was exact"*, and that the `lcec.0.activate` line in the HAL manual was his own. He raised one defect: the PAUSE paragraph's *"(and jerk)"* holds only where jerk limiting is configured. **He is right, and verification made the point sharper than he put it.** `MAX_JERK` defaults to `0.0` (`emccfg.h:51,70,87`); with a zero jerk `ruckig_plan_position()` refuses the plan and returns −1 (`ruckig_wrapper.c:236-241`); `tpCalculateSCurveAccel()` returns `TP_SCURVE_ACCEL_ERROR`; and `tp.c` reverts, in its own comment's words, *"to T-shaped acceleration/deceleration"* (`tp.c:3687-3709`). So it is not that jerk limiting is merely off by default — the jerk path **fails and the planner falls back**. One nuance his wording missed: **cruckig is not a separate planner**, it sits inside `tpmod` (`tp.c:43`, `:2795`); jerk limiting is a setting, not a different module. Corrected in five places — patch `0002` (regenerated from the branch, since editing the `.patch` body directly corrupted its hunk header), erratum 25, §5.6 with an inline correction block, and both sheets. All three patches re-checked with `git apply --check` on pristine master: clean. Five citations added so the corrected claim is machine-checked like the rest. |
| 2026-08-05 | **`ETHERCAT-NOTES.md` created; §2.9 extended in three places. Citations 126 → 134.** The new file is the integration-facing document — what someone building an EtherCAT machine needs — while §2.9 stays the audit trail; a pointer at the head of §2.9 says so, and the counts and sizes stay recorded once, there. Three findings were new enough to belong here rather than only in the new file. **(1)** The init cycle is *unconditional*: the test is `threads_running > 0 && !init_done`, with nothing about the list being non-empty, so every LinuxCNC machine gives up its first servo pass — the mechanism is general even though its reason is EtherCAT. **(2)** `rtapi_task_self_resync()` is a no-op on **both** RTAI backends, `rtai_rtapi.c:903-916` *and* `uspace_rtai.cc:190`; the earlier entry named only the first. **(3)** `lcec.write-all` exists beside `read-all`, and those globals are what shipped configurations actually use — and **no example under `linuxcnc-ethercat/examples/` contains an `initf` line**, nor does the driver's own documentation mention it, which makes the wrong funct name in LinuxCNC's HAL manual the only user-facing description of a facility nobody exercises. Also established, and kept in the new file as integration material rather than audit: the real `addf` order from a shipped machine config, identical to the Mesa bracket, and the DC monitoring pins with their default threshold of `app_time_period / 25`. |
| 2026-08-05 | **Third diagram audited — the coverage gap closed. Errata 27 → 38.** New §3.2 covers `LinuxCNC-motion-controller-small.png`, the middle of the three images in `code-notes.adoc`, which the original pass had skipped. Eleven errata: the `EXTINTF.H` caption (upstream issue #3843), `PID SERVO` and `UNIT CONVERT` drawn inside EMCMOT, `AXIS` for joints, `EMCIO` with a phantom NML triplet, planner and homing as fixed blocks, the summing junction, `CARTESIAN POSITION` as a separate flow, three flows where the segment has six members, and encoder/DAC placed below the HAL line. **Erratum 34 is the document contradicting itself across fifteen lines** — correct prose about `motmod`/`tpmod`/`homemod`, then a figure that denies it. More held up than expected: the per-axis cubic interpolator is live code, and both kinematics blocks are real. Part 3 was **reordered** to follow `code-notes.adoc`'s own sequence (§3.2 inserted, old §3.2–3.4 shifted to §3.3–3.5); the `§3.x` labels are referenced nowhere, so nothing broke. *Two passes, as before.* Pass 1, machine read-back: 15/15. Pass 2, adversarial: **it broke erratum 30** — I had claimed motion performs no joint↔motor conversion, but `control.c:2043` and `:459-461` do exactly that, symmetrically; the conversion is *additive* (backlash, screw comp, motor offset), and it is the *scaling* that belongs to HAL. The corrected finding was then re-verified alone. The same pass turned erratum 28 from "this is wrong" into a dated fact: `extintf.h` was deleted on 2005-11-05, **seven years before the image was committed**. |
| 2026-08-04 | **Triggered by reading upstream PR [#3718](https://github.com/LinuxCNC/linuxcnc/pull/3718)** (a live effort to redraw the same block diagram). Two findings, both about *this* file. **(1) Two stale counts corrected**: §2.10's repository map and erratum 8 still read "26" kinematics modules after the 2026-08-03 audit had corrected the figure to 19 — the correction reached §1's table and the changelog but not those two places. **(2) The consistency claim below, dated 2026-08-03, was overstated.** Pass A asserts that "every shared figure (… 19 kins …) agrees across all seven documents"; it did not — two occurrences survived. The entry is left as written, since a changelog records what was concluded at the time, but it should be read with this correction attached. Method note: the citation verifier passed 111/111 throughout and *structurally cannot* catch this class of error — it matches cited source lines, never figures asserted in prose. A number repeated in several places needs a different oracle from a citation. Coverage gap also recorded in *Still open*: `LinuxCNC-motion-controller-small.png` was never audited, and carries an open upstream issue. Errata count unchanged at 27; no claim about LinuxCNC was affected. |
| 2026-07-30 | Initial version. Parts 1–5 established from a full clone at HEAD `caa13ca6ae`. Errata 1–21 verified. |
| 2026-08-03 | Errata HTML snapshot refreshed to `_20260803_1811` (old `_1450` deleted): errata 22–27 added, PAUSE semantics row updated from “accurate” to “incomplete”, new Part 4 for the G-code reference with the phantom-error oracles, scope note rewritten (two limits lifted), prepared-fixes note added. Browser-verified: 27 rows, no gaps/duplicates, no stale strings. Scope divergence noted in the previous entry is closed. |
| 2026-08-03 | **Two further verification passes, two new methods.** *Pass A — cross-document consistency*: every shared figure (76/73/3, 19 kins, 48 files, 124+25, ~260, 2 MiB) agrees across all seven documents; errata numbering 1–27 complete, no gaps; all 73 handler lines in `motion-commands-reference.md` machine-matched against `command.c` in **both directions** (no missing, no extra, no drift). One scope divergence noted, not an error: the dated errata HTML snapshot stops at 21 corrections while this living file is at 27. *Pass B — adversarial*: all three patches `git apply --check` cleanly on pristine master; the two phantom-error claims re-attacked through **independent oracles** — the `NCE_*` catalog, every `_()` string in the interpreter, and all 26 `.po` translation catalogs: no trace, so the phantom errors were never real messages in any translated release either. The dead-commands claim came back **stronger**: a whole-tree search shows the three appear only in `motion.h` and `motion-logger.c` — nothing even emits them. Zero errors found by either pass. |
| 2026-08-03 | **From audit to production.** Built `tools/verify-citations.ps1` + manifest (111 checks, all passing). Prepared three upstream patches on the `audit-fixes` branch (errata 15–17, 19, 21–23, 25–27) with `upstream/README.md`. Wrote `motion-commands-reference.md` — all 76 commands from `command.c`. **Part 6 added**: sampled G-code reference audit found two *phantom errors* — documented checks (G33 over-velocity, G96 feed-while-stopped) that are implemented nowhere — plus three in-code defects (G76's "Invalid D-number" message, the stale "enable off" comments, the SET_AXIS_LOCKING_JOINT debug name). Errata now **27**. |
| 2026-08-03 | **Second pass: every `file:line` citation machine-checked** against the working tree — each cited line was read back and matched to the claim it supports. 60 citations tested, **58 passed**, two off-by-one errors fixed: `motion_struct.h:21`→`:20-21` (the mutex is on 20, the slot on 21) and `task/Submakefile:12`→`:13`. All constants in the appendix re-read from source. All lcec citations passed unchanged. Method note: automated read-back is worth more than re-reading prose — both errors were invisible to eye inspection and neither changed a conclusion, only its provenance. |
| 2026-08-03 | **Self-audit against the source. Twelve errors found and corrected.** Two substantive: `RTLMEM` was described as a working buffer type when `cms_cfg.cc:844` explicitly *refuses* it, and the error ring's saturation behaviour was stated backwards (the newest message is refused, not the oldest evicted). Ten quantitative or inferential: "65 drivers" (23 driver files + 42 modules of one driver), "26 kinematics modules" (19 distinct), rs274ngc 40→48 files, the base-thread creation test (ratio, not non-zero), "64 ADD_TYPES" offered as a device count (~260 devices), the five-transports implication, the unverified "removed in 2.9", the fork-provenance inference, the master version (all tags are `.preN`), and "tracked objects"→files. Verified-and-confirmed in passing: the seven position field names with line numbers, the single-writer refusal, NML `read()` semantics, and `tpmod`/`homemod` dating to `v2.9.0-pre1`. |
| 2026-08-03 | Remaining open items closed. **§5.6** answers the Code Notes' own long-standing question about `PAUSE` — deceleration to a stop mid-segment — and finds the omission that matters: **pause is ignored during threading and rigid tapping** (erratum 25). **§5.7** covers lcec's table-driven XML grammar, the live-bus config generator (a 2026 C port of a Go tool), and the registration-table device model — 64 `ADD_TYPES` across 60 files, with an honest tested/untested column in `DEVICES.md`. Errata now **25**. |
| 2026-08-03 | **Open agenda worked through.** Closed: delegating handlers (§5.1), `GLOBMEM` (§5.2 — widens erratum 15, and finds undocumented `RTLMEM`), the remaining Code Notes chapters (§5.3 — two are bare `FIXME`s, the EMCIO chapter contradicts the block diagram, and the document preserves a *second* repaired bug), the EtherCAT master fork (§5.4), the lcec configuration model (§5.5). Errata count rises to **24**. One item reclassified as unreachable from source alone: the practical RTAI/EtherCAT DC effect needs hardware. |
| 2026-08-03 | Cloned and audited `linuxcnc-ethercat` (§2.9.3–2.9.5): IgH dependency confirmed, weak-symbol `initf` probe and its PLL fallback documented, four-repository organisation mapped. **New documentation error found by cross-checking the two repositories**: LinuxCNC's `basic-hal.adoc:100` says `lcec.0.activate`, the driver exports `lcec.activate`. Added the EtherCAT line to the command-flow sheet. |
| 2026-08-03 | Added **§2.9 EtherCAT**: no driver in the repository, but real accommodations for the external one — the `initf` HAL verb, the special init cycle keeping EtherCAT send clear of SYNC0 (`hal_lib.c:3610`), and `rtapi_task_self_resync()` being a no-op under RTAI. External driver `linuxcnc-ethercat` identified but not audited. |
| 2026-08-03 | File naming switched to `<name>_YYYYMMDD_HHMM`; all `vN` documents deleted, only the latest kept. Current set: `linuxcnc-command-flow_20260803_1450.html`, `linuxcnc-code-notes-errata_20260803_1450.html`, this file. |
| 2026-08-03 | Added the **release caveat**: `master` is unreleased, latest tag `v2.9.10`; the IO migration (`764655eb4d`) carries no tag and is master-only. Corrected the claim that a GUI never touches real time — AXIS is itself a HAL component (`axis.py:3950`). Dated the overall block diagram: in the repository unchanged since 2012-11-19 (`b60c20198e`), content undatable. Verified the canon entry points `STRAIGHT_FEED`, `ARC_FEED`, `SET_SPINDLE_SPEED(int spindle, double r)` exist in `canon.hh`. |
