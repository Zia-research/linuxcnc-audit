# LinuxCNC Motion Commands — a complete reference from the source

The Code Notes' "Commands" chapter documents 27 commands of the 76 that exist, and seven of those
names no longer match the code. This file is the missing inventory: **every `cmd_code_t` value**,
written by reading each handler in `src/emc/motion/command.c`.

| | |
|---|---|
| Source of truth | `src/emc/motion/motion.h` (`cmd_code_t`), `src/emc/motion/command.c` (handlers) |
| Verified at | `master` @ `caa13ca6ae` (2026-07-30), read 2026-08-03 |
| Handler count | 76 enum values, 73 with a handler in the main switch |

**How commands arrive.** There is no queue: task writes one `emcmot_command_t` into the shared
`emcmot` segment under `command_mutex`, increments `commandNum`, and waits for the echo in
`commandNumEcho`. The real-time side polls with `rtapi_mutex_try()` and never blocks. A command that
is rejected sets `commandStatus` (`EMCMOT_COMMAND_INVALID_COMMAND`, `_INVALID_PARAMS`, …) which task
reads back from status.

**Reading the tables.** *Line* = the `case` label in `command.c`. *Gate* = conditions under which the
command is refused or ignored; "none" means the handler runs unconditionally (it may still do nothing
useful in the wrong mode). Descriptions are from the handler code and its comments, not from any
other document.

---

## The three commands with no handler

These exist in `cmd_code_t` but have **no `case` in `command.c`** — issuing them reaches `default:`
("unrecognized command"). They appear only in `motion-logger.c`. Unchanged since at least 2020.

| Command | Status |
|---|---|
| `EMCMOT_SET_TELEOP_VECTOR` | dead — described by the old docs as a motion command, but nothing consumes it |
| `EMCMOT_ENABLE_WATCHDOG` | dead — relic of a sound-card watchdog |
| `EMCMOT_DISABLE_WATCHDOG` | dead — same |

---

## Mode and machine state

| Command | Line | What it does | Gate |
|---|---|---|---|
| `EMCMOT_ABORT` | 492 | Stops all motion in the current mode: teleop → `axis_jog_abort_all()`, coord → `tpAbort()`, free → disables every joint's free-mode planner. Also diagnoses the "aborted while waiting for spindle at-speed" case loudly. | none — always accepted |
| `EMCMOT_JOG_ABORT` | 559 | Aborts one joint's (or one axis's) jog only. | none |
| `EMCMOT_FREE` | 583 | Requests free (joint) mode by clearing `coordinating`/`teleoperating`; the transition happens in the controller cycle (`set_operating_mode`). | none; ignored while any joint is moving |
| `EMCMOT_COORD` | 596 | Requests coordinated mode the same deferred way. | same pattern |
| `EMCMOT_TELEOP` | 618 | Delegates to `switch_to_teleop_mode()` (`motion.c:169`). | rejected with error if kinematics is non-identity and not all joints are homed; **no homing needed on identity kins** |
| `EMCMOT_ENABLE` | 1366 | Requests controller enable (deferred to controller cycle). On `KINEMATICS_INVERSE_ONLY` also forces free mode. | **rejected if the `motion.enable` HAL pin is low** |
| `EMCMOT_DISABLE` | 1353 | Requests disable, deferred likewise. | none |
| `EMCMOT_JOINT_ACTIVATE` | 1383 | Marks a joint active so ENABLE/DISABLE drive its amp-enable pin. | none |
| `EMCMOT_JOINT_DEACTIVATE` | 1395 | Marks a joint inactive. | none |

## Trajectory queue (coordinated motion)

| Command | Line | What it does | Gate |
|---|---|---|---|
| `EMCMOT_SET_LINE` | 1022 | Queues a straight move (`tpAddLine`) with id, motion type, vel/ini_maxvel/acc, turn, and tag. | coord mode + enabled + within soft limits + `inRange()`; queue-full sets `EMCMOT_COMMAND_INVALID_PARAMS` |
| `EMCMOT_SET_CIRCLE` | 1091 | Queues a circular/helical move (`tpAddCircle`). | same gates as SET_LINE |
| `EMCMOT_SET_TERM_COND` | 1012 | Sets blend/exact-stop termination and tolerance for subsequent moves (`tpSetTermCond`). | none |
| `EMCMOT_SET_SPINDLESYNC` | 1018 | Arms spindle-synchronized motion: `tpSetSpindleSync(spindle, uu_per_rev, wait_for_index_flag)`. Basis of G33/G95. | none |
| `EMCMOT_SET_VEL` | 1148 | Velocity for subsequent moves (also stored in status). | none |
| `EMCMOT_SET_VEL_LIMIT` | 1156 | Absolute max velocity (traj). | none |
| `EMCMOT_SET_ACC` | 1203 | Trajectory acceleration limit. | none |
| `EMCMOT_SET_JERK` | 1211 | Trajectory jerk limit (finite-jerk planner). | none |
| `EMCMOT_SET_PLANNER_TYPE` | 1218 | Selects planner: 0 = trapezoidal, 1 = S-curve/finite-jerk. | none |
| `EMCMOT_SETUP_ARC_BLENDS` | 1984 | Writes the six arc-blend tunables (`arcBlendEnable`, `FallbackEnable`, `OptDepth`, `GapCycles`, `RampFreq`, `TangentKinkRatio`) into config. | none |

## Pause, resume, reverse

| Command | Line | What it does | Gate |
|---|---|---|---|
| `EMCMOT_PAUSE` | 1230 | `tpPause()` — feed ramps to zero within the current segment. **Bypassed while the active segment is position-synchronized to the spindle** (threading / rigid tapping): those segments force full feed. | none |
| `EMCMOT_RESUME` | 1252 | Clears stepping, `tpResume()`, clears paused. | none |
| `EMCMOT_STEP` | 1261 | If paused: records current motion id (`idForStep`), sets `stepping`, resumes; planner re-pauses when the id changes (end of the current program line). | **error unless already paused** ("can't STEP while already executing") |
| `EMCMOT_REVERSE` | 1238 | Runs the queue **backwards** (`tpSetRunDir(TC_DIR_REVERSE)`); uses TC_QUEUE's reverse history. | only while paused |
| `EMCMOT_FORWARD` | 1245 | Returns to forward execution. | only while paused |

## Feed and override

| Command | Line | What it does | Gate |
|---|---|---|---|
| `EMCMOT_FEED_SCALE` | 1275 | Feed override value. | none |
| `EMCMOT_RAPID_SCALE` | 1285 | Rapid override value. | none |
| `EMCMOT_FS_ENABLE` | 1295 | Enables/disables feed override having any effect. | none |
| `EMCMOT_FH_ENABLE` | 1307 | Enables/disables feed hold. | none |
| `EMCMOT_AF_ENABLE` | 1341 | Enables/disables adaptive feed from the `motion.adaptive-feed` HAL pin. | none |
| `EMCMOT_SET_MAX_FEED_OVERRIDE` | 1980 | Upper bound for feed override (`maxFeedScale`). | none |
| `EMCMOT_SPINDLE_SCALE` | 1319 | Spindle speed override. | none |
| `EMCMOT_SS_ENABLE` | 1329 | Enables/disables spindle override. | none |

## Jogging (free and teleop)

One handler serves all three; joint jogs in free mode, Cartesian ("axis") jogs in teleop mode.

| Command | Line | What it does | Gate (all three) |
|---|---|---|---|
| `EMCMOT_JOG_CONT` | 796 | Continuous jog — implemented as an incremental jog to the soft limit; ABORT stops it. | rejected with error if: motion not enabled; `jog-inhibit` HAL pin true; homing active; wheel jog already active on that joint; locking joint not unlocked; would move further onto a limit (`SET_JOINT_ERROR_FLAG`) |
| `EMCMOT_JOG_INCR` | 867 | Incremental jog; increments are cumulative while moving. | same |
| `EMCMOT_JOG_ABS` | 944 | Absolute jog to a joint position. | same |

## Joint configuration

| Command | Line | What it does | Gate |
|---|---|---|---|
| `EMCMOT_SET_NUM_JOINTS` | 623 | Sets active joint count (1..`EMCMOT_MAX_JOINTS`). | range check |
| `EMCMOT_SET_JOINT_POSITION_LIMITS` | 745 | Soft min/max for a joint. | none |
| `EMCMOT_SET_JOINT_BACKLASH` | 758 | Backlash value. | none |
| `EMCMOT_SET_JOINT_MIN_FERROR` | 786 | Following-error floor. | none |
| `EMCMOT_SET_JOINT_MAX_FERROR` | 776 | Following-error ceiling. | none |
| `EMCMOT_SET_JOINT_VEL_LIMIT` | 1165 | Joint velocity limit. | none |
| `EMCMOT_SET_JOINT_ACC_LIMIT` | 1178 | Joint acceleration limit. | none |
| `EMCMOT_SET_JOINT_JERK_LIMIT` | 1191 | Joint jerk limit. | none |
| `EMCMOT_SET_JOINT_MOTOR_OFFSET` | 736 | Joint↔motor offset (homing bookkeeping). | none |
| `EMCMOT_SET_JOINT_COMP` | 1874 | Appends one screw-compensation table entry (position, forward trim, reverse trim). | table-full / ordering checks |
| `EMCMOT_SET_JOINT_HOMING_PARAMS` | 669 | Full homing parameter set for a joint (offsets, velocities, flags, sequence). | none |
| `EMCMOT_UPDATE_JOINT_HOMING_PARAMS` | 688 | The subset that may change while running (offset/home/sequence). | none |
| `EMCMOT_JOINT_HOME` | 1407 | Starts the homing state machine for one joint (or -1 = all, per sequence). | free mode + enabled |
| `EMCMOT_JOINT_UNHOME` | 1437 | Unhomes one joint, all (-1), or volatile-home joints only (-2). | mode checks |
| `EMCMOT_OVERRIDE_LIMITS` | 702 | Overrides **currently tripped** limits (mask from NHL/PHL flags) until the end of the next jog, which re-enables them automatically; joint < 0 cancels explicitly. | none |

## Axis (Cartesian) configuration

| Command | Line | What it does | Gate |
|---|---|---|---|
| `EMCMOT_SET_AXIS_POSITION_LIMITS` | 1914 | Soft limits per Cartesian axis. | axis index check |
| `EMCMOT_SET_AXIS_VEL_LIMIT` | 1927 | Axis velocity limit. | axis index check |
| `EMCMOT_SET_AXIS_ACC_LIMIT` | 1940 | Axis acceleration limit. | axis index check |
| `EMCMOT_SET_AXIS_JERK_LIMIT` | 1953 | Axis jerk limit. | axis index check |
| `EMCMOT_SET_AXIS_LOCKING_JOINT` | 1965 | Binds a locking (indexer) joint to an axis. | axis index check |
| `EMCMOT_SET_WORLD_HOME` | 664 | Sets the world-home pose (`world_home = pos`). | none |

## Spindle (8 spindles max; `spindle = -1` addresses all)

| Command | Line | What it does | Gate |
|---|---|---|---|
| `EMCMOT_SET_NUM_SPINDLES` | 638 | Active spindle count (1..`EMCMOT_MAX_SPINDLES`). | range check |
| `EMCMOT_SET_SPINDLE_PARAMS` | 1623 | Speed envelope (max/min pos/neg), orient home params, increment. | "non-existent spindle" check |
| `EMCMOT_SPINDLE_ON` | 1644 | Starts spindle(s) at a signed speed; also latches CSS state. | spindle exists |
| `EMCMOT_SPINDLE_OFF` | 1698 | Stops spindle(s). | spindle exists |
| `EMCMOT_SPINDLE_INCREASE` | 1784 | Bumps speed up by the configured increment. | spindle exists |
| `EMCMOT_SPINDLE_DECREASE` | 1808 | Bumps speed down. | spindle exists |
| `EMCMOT_SPINDLE_BRAKE_ENGAGE` | 1832 | Engages brake (stops output first). | spindle exists |
| `EMCMOT_SPINDLE_BRAKE_RELEASE` | 1854 | Releases brake. | spindle exists |
| `EMCMOT_SPINDLE_ORIENT` | 1733 | M19: drives `spindle.N.orient-angle`/`orient-mode`/`orient` pins and waits on `is-oriented`. | spindle exists |

## Probing and rigid tapping

| Command | Line | What it does | Gate |
|---|---|---|---|
| `EMCMOT_PROBE` | 1472 | Queues a probe move; `probe_type` bits select error-suppression and trip-on-clear; pre-checks the probe pin state unless suppressed. | **enabled + coord mode** + in range + limits ok |
| `EMCMOT_CLEAR_PROBE_FLAGS` | 1466 | Clears `probing` and `probeTripped`. | none |
| `EMCMOT_RIGID_TAP` | 1550 | Queues a rigid-tap cycle (`tpAddRigidTap`) — spindle-synchronized reversal handled by the planner. | **enabled + coord mode** + in range + limits ok |
| `EMCMOT_SET_PROBE_ERR_INHIBIT` | 1993 | Configures whether probe-tripped-during-jog / probe-on-home are errors. | none |

## Synchronized I/O and misc

| Command | Line | What it does | Gate |
|---|---|---|---|
| `EMCMOT_SET_DOUT` | 1613 | Digital out: immediate (`now`) or queued on the TP — **queue holds one entry; a second overwrites it** (comment in code). | none |
| `EMCMOT_SET_AOUT` | 1603 | Analog out, same immediate/queued split and same one-slot warning. | none |
| `EMCMOT_SET_OFFSET` | 1909 | Stores the applied tool offset in status (the live `FIXME` at `code-notes.adoc:1343` wants this moved out of motion). | none |
| `EMCMOT_SET_DEBUG` | 1596 | Sets the debug level in config. | none |

---

## Stale comments found in command.c while writing this

Two in-code comment defects surfaced during the read — candidates for a tiny upstream code patch
(comments only, no behaviour change):

1. **`command.c:1475` and `:1553`** — both PROBE and RIGID_TAP carry the copy-pasted comment
   *"requires coordinated mode, enable off, not on limits"*. The test three lines below each is
   `!GET_MOTION_COORD_FLAG() || !GET_MOTION_ENABLE_FLAG()` — it requires enable **on**.
2. **`command.c:1966`** — `SET_AXIS_LOCKING_JOINT`'s debug message prints
   `"SET_AXIS_ACC_LOCKING_JOINT"`, a name that matches no command.

## Verification status

Handlers read in full: ABORT, FREE, TELEOP (+ its delegate), ENABLE, DISABLE, PAUSE, RESUME, STEP,
OVERRIDE_LIMITS, JOG_CONT/INCR/ABS, PROBE, RIGID_TAP, SET_WORLD_HOME, SET_SPINDLESYNC,
CLEAR_PROBE_FLAGS, SET_DEBUG, SET_AOUT, SET_DOUT, SET_SPINDLE_PARAMS, SPINDLE_ON (head),
SPINDLE_ORIENT (head), SET_OFFSET, SET_AXIS_LOCKING_JOINT, SET_MAX_FEED_OVERRIDE, SETUP_ARC_BLENDS.
The rest are summarized from their in-code comments plus the visible handler shape; none of those
descriptions goes beyond what the extracted text supports. REVERSE/FORWARD's "only while paused"
comes from the code comment at `command.c:1238-1245`.
