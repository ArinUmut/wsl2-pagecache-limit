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

The Windows scripts expect the repo at `/root/work/wsl2-pagecache-limit` in distro
`Ubuntu-24.04`. Override with `-RepoLinux` and `-Distro`.

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

- KVM, KVM_AMD, VHOST and VHOST_VSOCK built in, for nested VMs. VHOST_NET stays `=m`
  because it depends on TUN, which is a module.
- `GCC_PLUGIN_LATENT_ENTROPY=y`.
- RANDSTRUCT off, because the GCC plugin disables `DEBUG_INFO_BTF`.
- `build.sh` fails if a fragment line is not honoured, or if `.config` differs from
  config-wsl outside `config/allowed-diff.txt`.

## Updating to a new Microsoft kernel

```bash
scripts/check-update.sh                             # exit 10: newer tag; "RETEST REQUIRED" if relevant config or functions changed
scripts/build.sh --tag <tag> && tests/qemu/run.sh
```

The patch is applied to `patches/BASE_TAG` with `git am`, then moved with
`git rebase --onto`; a conflict stops the build. After porting by hand, run
`scripts/export-patch.sh` and update `BASE_TAG`.

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
| limits off vs stock 6.18.40.1 (fio, median of 3) | seqread 4859 → 5244 MB/s, randread 23035 → 23519 IOPS, seqwrite 509 → 534 MB/s, syscall 0.124 → 0.123 µs, sched messaging 1.314 → 1.346 s |
| hook cost, RAM-backed (ext4 on loop on tmpfs, 2 GiB cold read, 7 interleaved runs) | off 10716, enabled below limit 11865, soft exceeded 11703, hard exceeded 9057 MB/s |
| VHDX A/B, 5 interleaved rounds | dominated by host-side variance (85–996 MB/s writes in one session); paired on/off median ratio: read 1.58, write 1.05 |

**Rebase:** the patch applies cleanly to 6.18.33.2 and 6.18.54.1 with `git rebase --onto`.

## Notes

- **Total cache bound:** total cache is bounded by `hard_limit + vm.dirty_bytes`;
  heavy writeback can overshoot the clean limit briefly.
- **Shared kernel:** all distros share one kernel, so root in any distro can change the
  VM-wide limits.
- **Internal API:** the patch uses the internal `try_to_free_mem_cgroup_pages()`.
  `check-update.sh` diffs it and the other functions the patch relies on.

## Requirements

- **Runtime:** WSL2 with Ubuntu 24.04; scripts run as root inside WSL.
- **Build:** `build-essential flex bison bc dwarves libelf-dev libssl-dev cpio qemu-utils rsync gcc-13-plugin-dev`.
- **Tests:** `qemu-system-x86 busybox-static fio`, `sparse` optional. QEMU tests need
  `/dev/kvm` inside WSL.

## Layout

| Path | Contents |
|---|---|
| `patches/` | kernel patch and its base tag |
| `config/` | config fragments, allowed config differences, dirty-page sysctl |
| `scripts/` | fetch, build, export-patch, check-update, install, rollback, set-limits, pclimit |
| `tests/qemu/` | test VM init, static I/O helper (`pcltest.c`), runner |
| `tests/` | install gates (`validate.sh`, plus optional git-ignored `validate.local.sh`), functional, hard-only, perf, A/B, hook-cost, counter diagnostics, host memory |
| `results/` | measurement output |

## License

GPL-2.0-only. The patch modifies GPL-2.0 kernel files, so the whole repository uses
the same license.
