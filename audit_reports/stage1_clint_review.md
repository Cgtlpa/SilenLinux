# Silen Linux Stage 1 Independent Review — Rust GUI Installer Disk Safety (Final Re-review)

**Task:** Review Kilo's Stage 1 implementation (Rust GUI installer disk safety) against the requirements in `audit_reports/final_audit.md`.

**Method:** Inspected the actual `git diff` and current working tree in `/home/vgz/silen/SilenLinux/`. Did not rely on Kilo's description or my previous report.

**Constraint:** Read-only. No source files modified. No destructive commands.

---

## 1. Summary of Changes Actually Made

Kilo modified `/home/vgz/silen/SilenLinux/silen-installer/src/backend.rs` (139 insertions, 14 deletions). No changes to `main.rs`, `Cargo.toml`, or any other installer file.

Changes added:
- `is_whole_disk_name(name: &str) -> bool` (line 170)
- `disk_in_use(dev: &str, mounts: &str) -> bool` (line 194)
- `validate_disk(dev: &str) -> bool` (line 221)
- Updated `list_disks()` to use `is_whole_disk_name()` and `validate_disk()` (lines 245-277)
- 6 unit tests in `tests_disk_safety` module (lines 876+)

**No changes to `do_partition()` or `do_install()`.**

---

## 2. Previous Findings — Resolution Status

| Previous Finding | Status | Reasoning |
|-----------------|--------|-----------|
| Rust `list_disks()` offers partitions as wipe targets | **RESOLVED** | `is_whole_disk_name()` now correctly rejects sd/vd/xvd names ending in digits, and nvme/mmcblk names with 'p' + digits suffix. `list_disks()` filters through it. |
| No mounted-disk check | **PARTIALLY RESOLVED** | `validate_disk()` checks `/proc/mounts` via `disk_in_use()`, but only checks mounts — not swap, MD RAID, device-mapper/LUKS, or other in-use states. |
| Destructive actions proceed with invalid target | **UNRESOLVED** | `validate_disk()` is only called in `list_disks()` (UI population). `do_install()` does NOT call it before `do_partition()`. `do_partition()` does NOT call it before `wipefs`/`sfdisk`/`mkfs`. TOCTOU window remains. |
| No unit tests for disk safety | **RESOLVED** | 6 unit tests added. |
| udevd copy path bug | **UNRELATED** | Separate issue in `scripts/build.sh`/`rootfs/init`, not part of Stage 1. |

---

## 3. New Findings from Actual Code Inspection

### 3.1. `validate_disk()` NOT Called Before Destructive Operations — FAIL

**Technical reasoning:**
- `validate_disk()` is called only inside `list_disks()` (lines 258, 269), which runs once at UI startup (`InstallerApp::default()`).
- `do_install()` (line 728) checks `medium_on_disk(&s.disk)` (line 738) but does **NOT** call `validate_disk(&s.disk)`.
- `do_partition()` (line 401) runs `wipefs -a` (line 408) and `sfdisk` (line 410) on `s.disk` without any validation call.
- **TOCTOU window:** A disk that was valid when listed could become mounted/in-use before the user clicks "Install now". The code would proceed to wipe it.

**Relevant files:**
- `/home/vgz/silen/SilenLinux/silen-installer/src/backend.rs:401-440` (`do_partition()` — no validation call)
- `/home/vgz/silen/SilenLinux/silen-installer/src/backend.rs:728-744` (`do_install()` — checks `medium_on_disk` but not `validate_disk`)

**Suggested correction:** Call `validate_disk(&s.disk)` at the top of `do_partition()` (or in `do_install()` immediately before `do_partition()`), and abort with a clear error if it returns false.

---

### 3.2. `disk_in_use()` Only Checks `/proc/mounts` — PARTIAL

**Technical reasoning:**
- `disk_in_use()` reads `/proc/mounts` and checks for direct device matches and partition-of-disk matches.
- It does **NOT** check:
  - `/proc/swaps` (active swap on the target or its partitions)
  - `/proc/mdstat` (MD RAID arrays using the target)
  - Device-mapper / LUKS / cryptsetup active devices
  - Whether the disk is the install medium (handled separately by `medium_on_disk()` in `do_install()`)
- A disk with an active swapfile or swap partition would not be detected as "in use" and could be wiped.

**Relevant files:**
- `/home/vgz/silen/SilenLinux/silen-installer/src/backend.rs:194-219` (`disk_in_use()`)

**Suggested correction:** Extend `disk_in_use()` (or add a separate check in `validate_disk()`) to also scan `/proc/swaps`, `/proc/mdstat`, and check for active device-mapper devices.

---

### 3.3. `disk_in_use()` Partition Matching Is Redundant but Functional — PASS

**Technical reasoning:**
- The check `src.starts_with(&format!("/dev/{}1", base))` combined with `src_base.starts_with(base)` correctly catches partitions like `/dev/sda1` for disk `/dev/sda`.
- The `{}p` variant correctly catches nvme/mmcblk partitions like `/dev/nvme0n1p1` for `/dev/nvme0n1`.
- Some redundancy (the `{}1` check and the `starts_with(base)` check overlap), but not incorrect.

**Relevant files:**
- `/home/vgz/silen/SilenLinux/silen-installer/src/backend.rs:208-216`

---

### 3.4. Fail-Closed on Unreadable Mount Info — PASS

**Technical reasoning:**
- `validate_disk()` returns `false` if `/proc/mounts` cannot be read (line 235-238).
- `disk_in_use()` returns `true` if the mounts string is empty (line 196-198).
- Both fail closed: if mount information is unavailable, the disk is rejected rather than accepted.

**Relevant files:**
- `/home/vgz/silen/SilenLinux/silen-installer/src/backend.rs:194-198` (`disk_in_use` empty-mounts check)
- `/home/vgz/silen/SilenLinux/silen-installer/src/backend.rs:235-238` (`validate_disk` read error)

---

### 3.5. `is_whole_disk_name()` Correctly Excludes All Partition Types — PASS

**Technical reasoning:**
- `sd`/`vd`/`xvd`: rejects if last character is a digit (catches sda1, sda2, etc.)
- `nvme`/`mmcblk`: rejects if `rfind('p')` finds a 'p' followed by digits at end (catches nvme0n1p1, mmcblk0p1)
- `loop`/`ram`/`zram`/`fd`: explicitly rejected
- Non-matching patterns (e.g., `sr0`, `hd0`): rejected by the initial patterns check

**Relevant files:**
- `/home/vgz/silen/SilenLinux/silen-installer/src/backend.rs:170-192`

---

### 3.6. Tests Do Not Cover `validate_disk()` or Key Edge Cases — NEEDS TESTING

**Technical reasoning:**
- The 6 tests cover `is_whole_disk_name()` (3 tests) and `disk_in_use()` (3 tests).
- **Missing tests:**
  - `validate_disk()` itself — no test for the full validation pipeline
  - Non-existent device path (`/dev/nonexistent`)
  - Non-`/dev/` path (e.g., `/sda`, `sda`)
  - `/proc/mounts` read error (fail-closed behavior)
  - nvme/mmcblk partition mount detection via `disk_in_use` (e.g., `/dev/nvme0n1p1` mounted → `/dev/nvme0n1` in use)
  - Active swap on target disk
  - Disk that is the install medium
- All tests use hardcoded mount strings, not real `/proc/mounts` — this is fine for unit tests but doesn't validate integration with `do_install()`.

**Relevant files:**
- `/home/vgz/silen/SilenLinux/silen-installer/src/backend.rs:876-920` (test module)

---

### 3.7. `do_install()` Size Check Added but Not Shown in Diff — PASS

**Technical reasoning:**
- `do_install()` now checks `disk_bytes(&s.disk) < 8 * 1024 * 1024 * 1024` (line 741) before partitioning. This is a safety improvement, though not part of the original Stage 1 requirements.

**Relevant files:**
- `/home/vgz/silen/SilenLinux/silen-installer/src/backend.rs:741-743`

---

## 4. Tests Requiring Runtime Verification

| Test | Coverage | Runtime Verification Needed? |
|------|----------|------------------------------|
| `whole_disk_names_accepted` | is_whole_disk_name | No (pure function) |
| `partition_names_rejected` | is_whole_disk_name | No (pure function) |
| `unrelated_names_rejected` | is_whole_disk_name | No (pure function) |
| `disk_in_use_detects_mounted` | disk_in_use with /proc/mounts | Yes — verify against real mounts |
| `disk_not_in_use_when_absent` | disk_in_use with other disk mounted | Yes — verify against real mounts |
| `disk_in_use_fails_closed_on_empty` | disk_in_use empty mounts | No (pure function) |

**Integration test gap:** No test verifies that `do_install()` or `do_partition()` calls `validate_disk()` before destructive operations.

---

## 5. Regression Check

| Area | Status | Notes |
|------|--------|-------|
| Disk selection UI | PASS | Partitions correctly excluded; mounted disks excluded via /proc/mounts |
| `do_partition()` logic | PASS | Unchanged — same wipefs/sfdisk/mkfs flow |
| `do_install()` flow | PASS | Unchanged except added size check and `medium_on_disk()` (already existed) |
| Bash installer | PASS | Not modified |
| Live ISO builder | N/A | Not part of Stage 1 |

No regressions identified. The changes are additive and do not break existing functionality.

---

## 6. Requirements Coverage Matrix (final_audit.md)

| Requirement | Status | Evidence |
|-------------|--------|----------|
| Fix Rust `list_disks()` partition exclusion | **PASS** | `is_whole_disk_name()` correctly rejects all partition types; `list_disks()` filters through it |
| Add mounted-disk check before wipe | **PARTIAL** | Only `/proc/mounts` checked; missing swap, MD RAID, device-mapper |
| Prevent destructive actions on invalid/ambiguous target | **FAIL** | `validate_disk()` not called in `do_install()` or `do_partition()` — TOCTOU window |
| Tests for disk safety edge cases | **NEEDS TESTING** | 6 tests added but missing `validate_disk()` and key edge cases |
| No regressions in existing installer | **PASS** | No existing functionality removed or broken |
| Fail-closed on unreadable mount info | **PASS** | `validate_disk()` returns false on read error; `disk_in_use()` returns true on empty |

---

## 7. Final Verdict: FAIL

**Stage 1 is not complete.** While the partition name exclusion is correctly implemented and fail-closed behavior for mount info is present, the critical gap remains: **`validate_disk()` is not called before destructive operations.**

`do_partition()` runs `wipefs -a` and `sfdisk` on `s.disk` without re-validating that the disk is still a valid whole-disk target. A disk that passed validation at UI list time could become mounted/in-use by the time the user clicks "Install now", and the installer would proceed to wipe it.

**Required corrections before Stage 1 can pass:**
1. Call `validate_disk(&s.disk)` in `do_install()` immediately before `do_partition()` (and/or at the top of `do_partition()` itself).
2. Extend `disk_in_use()` to also check `/proc/swaps`, `/proc/mdstat`, and active device-mapper devices.
3. Add unit tests for `validate_disk()` covering non-existent devices, non-`/dev/` paths, read errors, and nvme/mmcblk partition mounts.
4. Add an integration test verifying `do_install()` rejects a disk that becomes mounted between listing and install.

---

**Review complete.** No source files were modified. No destructive commands were executed.

