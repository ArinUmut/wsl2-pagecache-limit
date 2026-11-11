# wsl2-pagecache-limit

Page cache limit for the WSL2 kernel, independent of `[wsl2] memory=`. Every page the
guest touches stays committed in the host's `vmmemWSL`; this caps how much of it the
file cache can take.

Base: `linux-msft-wsl-6.18.58.1` (WSL 3.0.5). One patch: `mm/pagecache_limit.c`,
`include/linux/pagecache_limit.h`, 2 lines in `mm/filemap.c`, 1 line in `mm/Makefile`.

## Limits

| Parameter | Mode | Behaviour |
|---|---|---|
| `soft_limit` | async | File LRU (Active(file) + Inactive(file)) above the limit wakes `kpclimitd`, which reclaims down to `soft - clamp(soft/32, 16M, 256M)`. |
| `hard_limit` | sync | While clean page cache is above the limit, a task inserting folios into the page cache first reclaims as many file pages as it inserts (the memcg `memory.max` model, file pages only). |

Both default to 0 (off) and work alone or together. `soft > hard` is treated as `soft = hard`.

- **Hook:** top of `filemap_add_folio()`, before `mem_cgroup_charge()`, in the same
  context and gfp as memcg's `memory.max` reclaim. Behind a static key: a 5-byte NOP
  while no limit is set. When enabled, global counters are read every 64 pages per CPU.
- **Reclaim:** `try_to_free_mem_cgroup_pages(root_mem_cgroup, nr, gfp,
  MEMCG_RECLAIM_PROACTIVE, NULL)`, the `memory.reclaim` path without `MAY_SWAP`. Only
  file LRUs are scanned; anon memory and swap are not touched.
- **Dirty pages:** the hard limit counts clean cache. Dirty and writeback pages are
  bounded by `vm.dirty_bytes` (the installer sets 1G / 256M background).
- **Contexts without sync reclaim:** non-blocking, `__GFP_NOFAIL`, NOIO,
  `PF_MEMALLOC`, kthread, dying-task and `RWF_DONTCACHE` insertions, and cgroup v1.
  These wake the worker instead.
- **Back-off:** a sync call that reclaims less than half its target pauses sync
  reclaim for 20 ms, doubling to 1 s. The worker backs off from HZ/4 to 8 s.
- **Writeback:** while the file LRU is above `hard_limit`, the worker re-checks every
  HZ/4, because writeback turns dirty pages clean without new insertions.
- **No failures:** page cache allocations never fail because of a limit.

## Usage

```bash
# runtime, root
echo 3G > /sys/module/pagecache_limit/parameters/soft_limit
echo 4G > /sys/module/pagecache_limit/parameters/hard_limit
cat /sys/module/pagecache_limit/parameters/stats
scripts/pclimit.sh show
```

Values are bytes with an optional K/M/G/T suffix. 0 = off, otherwise ≥ 64M. No
decimals: use `1536M`, not `1.5G`.

Boot: in `.wslconfig`, `[wsl2] kernelCommandLine = pagecache_limit.soft_limit=3G pagecache_limit.hard_limit=4G`.

Persistent change from Windows, without a restart:

```powershell
.\scripts\set-limits.ps1 -Soft 3G -Hard 4G
.\scripts\set-limits.ps1 -DirtyBytes 1G -DirtyBackgroundBytes 256M
.\scripts\set-limits.ps1 -Soft 0 -Hard 0
```

Run the Windows scripts from the repo inside WSL (`\\wsl.localhost\<distro>\...`); they
derive the distro and repo path from their own location. `-Distro` and `-RepoLinux`
override that.

## Build, test, install

```bash
scripts/build.sh                    # release: bzImage + modules.vhdx in out/<tag>-release
scripts/build.sh --variant debug    # KASAN + lockdep kernel for the tests
tests/qemu/run.sh                   # QEMU/KVM suite on the debug kernel, 10 min stress
```

```powershell
.\scripts\install.ps1 -Soft 3G -Hard 4G -Apply   # back up .wslconfig, install, restart WSL, validate; rolls back on failure
.\scripts\rollback.ps1                           # restore the newest .wslconfig.pclimit-*.bak
```

Kernel config is `Microsoft/config-wsl` plus `config/pclimit.fragment`:

- `GCC_PLUGIN_LATENT_ENTROPY=y`.
- RANDSTRUCT off, because the GCC plugin disables `DEBUG_INFO_BTF`.
- Machine-specific options go in `config/local.fragment` (git-ignored), with the
  differences they cause listed in `config/local-allowed-diff.txt`.
- `build.sh` fails if a fragment line is not honoured, or if `.config` differs from
  config-wsl outside the allowed lists.

## Compatibility

- **Minimum kernel:** Linux 6.18; for WSL, `linux-msft-wsl-6.18.20.1`, the first
  6.18-based WSL tag. The patch uses `folio_test_dropbehind()` (6.14) and hooks
  `filemap_add_folio()` in its 6.18 form; 6.6-based WSL kernels are not supported.
- **Checked:** applies cleanly to 6.18.20.1, 6.18.33.2, 6.18.54.1 and 6.18.58.1;
  compiles warning-free (`W=1`) on 6.18.20.1 and 6.18.58.1; built, tested and
  installed on 6.18.58.1.
- **WSL:** tested with 3.0.5.

`scripts/build.sh --tag <tag>` builds for another 6.18.y tag; `scripts/check-update.sh`
reports newer tags and changes in the kernel code the patch relies on.

## Results

Setup: `linux-msft-wsl-6.18.58.1`, Ryzen 7 7800X3D, 20 GB WSL VM. Raw output is in
`results/`.

**Patch checks:** `checkpatch --strict` 0 errors (only the MAINTAINERS warning for new
files); `W=1` and sparse clean.

**QEMU/KVM, debug kernel** (KASAN, lockdep, DEBUG_VM, hung-task), 4 GB VM, soft 384M /
hard 512M. All cases and a 10 min stress run pass, with no lockdep, KASAN, WARN or
hung-task reports.

| Case | Result |
|---|---|
| hard only, 2 GiB read | peak clean cache 512–514 MiB |
| soft only | ≤ soft after the read |
| dirty write, sendfile | transient clean peak 526–616 MiB; ≤ hard within 0.2 s of `sync` |
| cache protected by `memory.min` | back-off engages, no spinning |
| mmap, RWF_NOWAIT, RWF_DONTCACHE, loop, tmpfs, mlock, 200 cgroups | pass |
| invalid boot values (`12Q`, `stats=1`) | rejected |

**WSL, installed kernel** (3G / 4G, dirty 1G / 256M):

| Case | Result |
|---|---|
| 10 GiB read | peak cache 3.0 GiB, ≤ soft right after; sync path unused |
| hard only, 10 GiB read | peak clean 4.0 GiB (+2 MiB), 1567 sync calls |
| hard only, 6 GiB write | transient clean peak 4.11 GiB, ≤ hard right after `sync` |
| host `vmmemWSL`, same 10 GiB read | peak 12.5 → 4.4 GiB; 30 s later 9.8 → 1.8 GiB |

**Performance:**

| Case | Result |
|---|---|
| limits off vs 6.18.40.1 without the patch (`perf bench`, median of 3) | syscall 0.124 → 0.123 µs/op, sched messaging 1.314 → 1.346 s |
| hook cost, RAM-backed (ext4 on loop on tmpfs, 2 GiB cold read, 7 interleaved runs) | off 10716, enabled below limit 11865, soft exceeded 11703, hard exceeded 9057 MB/s |

## Notes

- **Total cache bound:** total cache is bounded by `hard_limit + vm.dirty_bytes`;
  heavy writeback can overshoot the clean limit briefly.
- **Shared kernel:** all distros share one kernel, so root in any distro can change the
  VM-wide limits.
- **Internal API:** the patch uses the internal `try_to_free_mem_cgroup_pages()`.
  `check-update.sh` diffs it and the other functions the patch relies on.

## Requirements

- **Runtime:** WSL2 with Ubuntu 24.04; scripts run as root inside WSL.
- **Build:** `build-essential flex bison bc dwarves libelf-dev libssl-dev cpio qemu-utils rsync`,
  plus `gcc-<N>-plugin-dev` for the installed gcc major version.
- **Tests:** `qemu-system-x86 busybox-static fio`, `sparse` optional. QEMU tests need
  `/dev/kvm` inside WSL.

## Layout

| Path | Contents |
|---|---|
| `patches/` | kernel patch and its base tag |
| `config/` | config fragments, allowed config differences, dirty-page sysctl; optional git-ignored `local.fragment` and `local-allowed-diff.txt` |
| `scripts/` | fetch, build, export-patch, check-update, install, rollback, set-limits, pclimit |
| `tests/qemu/` | test VM init, static I/O helper (`pcltest.c`), runner |
| `tests/` | install gates (`validate.sh`, plus optional git-ignored `validate.local.sh`), functional, hard-only, perf, A/B, hook-cost, counter diagnostics, host memory |
| `results/` | measurement output |

## License

GPL-2.0-only. The patch modifies GPL-2.0 kernel files, so the whole repository uses
the same license.
