#!/bin/busybox sh
# shellcheck shell=dash
# /init of the QEMU test VM (busybox). Every check prints PASS/FAIL; the last
# line is "RESULT fails=N". Limits in the VM (4 GiB RAM): soft 384M, hard 512M.
/bin/busybox --install -s /bin
export PATH=/bin
mkdir -p /proc /sys /dev /tmp /mnt /data
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /tmp
mount -t cgroup2 none /sys/fs/cgroup
if ! mount -t ext4 /dev/vda /data; then
	echo "FAIL mount /dev/vda"; echo "RESULT fails=1"; poweroff -f
fi

P=/sys/module/pagecache_limit/parameters
STRESS=$(sed -n 's/.*pcltest\.stress=\([0-9][0-9]*\).*/\1/p' /proc/cmdline)
STRESS=${STRESS:-600}
SOFT=402653184
HARD=536870912
TOL_KB=65536
fails=0

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
setl() { echo "$1" > $P/soft_limit && echo "$2" > $P/hard_limit; }
drop() { sync; echo 3 > /proc/sys/vm/drop_caches; }
val() { echo "$1" | sed -n "s/.*$2=\([0-9.]*\).*/\1/p"; }
st() { awk -v k="$1" '$1 == k { print $2 }' $P/stats; }
file_kb() { awk '/^Active\(file\):/ { a = $2 } /^Inactive\(file\):/ { i = $2 } END { print a + i }' /proc/meminfo; }
clean_kb() { awk '/^Active\(file\):/ { a = $2 } /^Inactive\(file\):/ { i = $2 } /^Dirty:/ { d = $2 } /^Writeback:/ { w = $2 } END { f = a + i; u = d + w; print (u < f ? f - u : 0) }' /proc/meminfo; }
# Write loads: writeback turns pages clean without insertions, so the hard
# limit can only be restored after the fact by the worker. The property checked
# is convergence (clean back under hard + 64M within 5 s of the write and sync);
# the transient peak is reported, not asserted.
check_converges() {	# $1 = name, $2 = pcltest output, $3 = limit bytes
	n=0; lim=$(($3 / 1024 + TOL_KB))
	while [ "$(clean_kb)" -gt "$lim" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
	if [ "$(clean_kb)" -le "$lim" ]; then
		pass "$1 clean back <= $lim kB in $((n / 10)).$((n % 10))s (transient $2)"
	else
		fail "$1 clean still $(clean_kb) kB > $lim kB after 5s ($2)"
	fi
}
wait_file_below() {	# $1 = kB, $2 = seconds
	n=0
	while [ "$(file_kb)" -gt "$1" ] && [ $n -lt $(($2 * 10)) ]; do sleep 0.1; n=$((n + 1)); done
	[ "$(file_kb)" -le "$1" ]
}
snap() { awk '{ printf "%s=%s ", $1, $2 }' $P/stats; }
delta() {	# $1 = name, $2 = snap before: prints counter deltas
	echo "$2" | tr ' ' '\n' | grep -E '^(sync_calls|sync_short|skip_backoff|skip_context|async_wakeups|async_reclaimed_pages|async_stuck)=' |
	while IFS='=' read -r k v; do
		now=$(st "$k"); printf '%s+%s ' "$k" $((now - v))
	done | sed "s/^/info $1 counters: /"; echo
}
check_peak() {	# $1 = name, $2 = pcltest output, $3 = limit bytes [, $4 = tolerance kB]
	pk=$(val "$2" peak_clean_kb)
	lim=$(($3 / 1024 + ${4:-$TOL_KB}))
	if [ -n "$pk" ] && [ "$pk" -le "$lim" ]; then
		pass "$1 peak_clean_kb=$pk <= $lim ($2)"
	else
		fail "$1 peak_clean_kb=$pk > $lim ($2)"
	fi
}

echo "== kernel $(uname -r), cmdline: $(cat /proc/cmdline)"

# 0. command line: '12Q' and 'stats=1' must be rejected, the later values kept.
[ "$(cat $P/soft_limit)" = "$SOFT" ] && pass "boot soft_limit=$SOFT" || fail "boot soft_limit=$(cat $P/soft_limit)"
[ "$(cat $P/hard_limit)" = "$HARD" ] && pass "boot hard_limit=$HARD" || fail "boot hard_limit=$(cat $P/hard_limit)"
ps | grep -q '[k]pclimitd' && pass "kpclimitd running" || fail "kpclimitd missing"
dmesg | grep -q 'pagecache_limit: soft_limit=384M hard_limit=512M' && pass "init message" || fail "init message missing"

# 1. parameter parsing
for v in abc 10M 1.5G "" 99999999999999999999 16777216T -1 "12 M" 0x10000000; do
	if echo "$v" > $P/hard_limit 2>/dev/null; then fail "accepted invalid hard_limit '$v'"; fi
done
[ "$(cat $P/hard_limit)" = "$HARD" ] && pass "invalid values rejected, hard_limit unchanged" || fail "hard_limit changed to $(cat $P/hard_limit)"
if echo 1 > $P/stats 2>/dev/null; then fail "stats writable"; else pass "stats read-only"; fi
for v in 64M 1G 0 2048M 3g 65536k; do echo "$v" > $P/soft_limit || fail "rejected valid soft_limit $v"; done
[ "$(cat $P/soft_limit)" = 67108864 ] && pass "suffixes parsed (65536k -> 67108864)" || fail "soft_limit=$(cat $P/soft_limit)"
setl 2G 1G
awk '$1 == "effective_soft_bytes" && $2 == 1073741824 { ok = 1 } END { exit !ok }' $P/stats && pass "soft above hard is capped at hard" || fail "soft cap: $(grep effective $P/stats)"

# 2. reference: no limit
setl 0 0; drop
r=$(pcltest read /data/big1.dat); echo "info no-limit read: $r"

# 3. hard only
setl 0 512M; drop; c0=$(st sync_calls)
r=$(pcltest read /data/big1.dat); check_peak "hard-only read" "$r" $HARD
[ "$(st sync_calls)" -gt "$c0" ] && pass "sync reclaim ran ($(st sync_calls) calls)" || fail "no sync reclaim calls"

# 4. soft only: overshoot allowed, then the worker brings it below soft
setl 384M 0; drop; a0=$(st async_reclaimed_pages)
r=$(pcltest read /data/big1.dat); echo "info soft-only read: $r"
wait_file_below $((SOFT / 1024)) 20 && pass "soft-only settles <= soft ($(file_kb) kB)" || fail "soft-only still at $(file_kb) kB"
[ "$(st async_reclaimed_pages)" -gt "$a0" ] && pass "async reclaim ran" || fail "no async reclaim"

# 5. both
setl 384M 512M; drop
r=$(pcltest read /data/big1.dat); check_peak "both read" "$r" $HARD
wait_file_below $((SOFT / 1024)) 20 && pass "both settles <= soft ($(file_kb) kB)" || fail "both still at $(file_kb) kB"

# 6. mmap
drop; r=$(pcltest mmap /data/big1.dat); check_peak "mmap read" "$r" $HARD

# 7. RWF_NOWAIT and RWF_DONTCACHE complete; they skip sync reclaim
setl 0 512M; drop; s0=$(st skip_context)
r=$(pcltest nowait /data/big2.dat) && pass "nowait read ($r)" || fail "nowait read"
drop
r=$(pcltest dontcache /data/big2.dat) && pass "dontcache read ($r)" || fail "dontcache read"
echo "info skip_context $s0 -> $(st skip_context)"

# 8. sendfile
drop; s=$(snap); r=$(pcltest sendfile /data/big2.dat /data/sf.out); sync; delta sendfile "$s"
check_converges "sendfile" "$r" $HARD
rm -f /data/sf.out

# 9. dirty data larger than the hard limit must not stall
setl 0 512M; drop
s=$(snap); t0=$(date +%s); r=$(pcltest write /data/dirty.dat 1536); sync; t1=$(date +%s); delta dirty-write "$s"
[ $((t1 - t0)) -lt 180 ] && pass "1.5G dirty write + sync in $((t1 - t0))s ($r)" || fail "dirty write took $((t1 - t0))s"
check_converges "dirty write" "$r" $HARD
rm -f /data/dirty.dat

# 10. mlocked file larger than the limit
setl 384M 512M; drop
pcltest mlock /data/lock.dat 120 > /tmp/mlock.out &
mlp=$!; sleep 15
t0=$(date +%s); r=$(pcltest read /data/big2.dat); t1=$(date +%s)
[ $((t1 - t0)) -lt 120 ] && pass "read next to 768M mlocked file in $((t1 - t0))s ($r)" || fail "read next to mlock took $((t1 - t0))s"
kill $mlp 2>/dev/null; wait $mlp 2>/dev/null

# 11. cache that cannot be reclaimed (memory.min) must back off, not spin
echo +memory > /sys/fs/cgroup/cgroup.subtree_control
mkdir -p /sys/fs/cgroup/prot
echo 3G > /sys/fs/cgroup/prot/memory.min
setl 0 512M; drop; b0=$(st sync_short)
t0=$(date +%s)
r=$(sh -c 'echo $$ > /sys/fs/cgroup/prot/cgroup.procs; exec pcltest read /data/big1.dat')
t1=$(date +%s)
echo "info protected read: $r, sync_short $b0 -> $(st sync_short), skip_backoff $(st skip_backoff)"
[ $((t1 - t0)) -lt 120 ] && pass "protected-cache read in $((t1 - t0))s" || fail "protected-cache read took $((t1 - t0))s"
[ "$(st sync_short)" -gt "$b0" ] && pass "back-off armed on unreclaimable cache" || fail "back-off never armed"
echo 0 > /sys/fs/cgroup/prot/memory.min
drop

# 12. loop device (reads go through loop kworkers)
setl 384M 512M
if losetup /dev/loop0 /data/loop.img && mount -t ext4 /dev/loop0 /mnt; then
	drop; r=$(pcltest read /mnt/f.dat) && pass "loop-device read ($r)" || fail "loop-device read"
	umount /mnt; losetup -d /dev/loop0
else
	fail "loop setup"
fi

# 13. tmpfs is not page cache for this limit; writing it must still work
dd if=/dev/zero of=/tmp/t.dat bs=1M count=600 2>/dev/null && pass "tmpfs 600M write" || fail "tmpfs write"
rm -f /tmp/t.dat

# 14. many cgroups
i=0; while [ $i -lt 200 ]; do mkdir -p /sys/fs/cgroup/g$i; i=$((i + 1)); done
drop; t0=$(date +%s)
r=$(sh -c 'echo $$ > /sys/fs/cgroup/g150/cgroup.procs; exec pcltest read /data/big1.dat')
t1=$(date +%s)
check_peak "read with 200 cgroups ($((t1 - t0))s)" "$r" $HARD
echo $$ > /sys/fs/cgroup/cgroup.procs

# 15. stress: readers, writer, mmap, tmpfs and a limit toggler for STRESS s
echo "== stress ${STRESS}s"
( while :; do pcltest read /data/big1.dat > /dev/null; done ) & p1=$!
( while :; do pcltest read /data/big2.dat > /dev/null; done ) & p2=$!
( while :; do pcltest mmap /data/big2.dat > /dev/null; done ) & p3=$!
( while :; do pcltest write /data/w.dat 512 > /dev/null; rm -f /data/w.dat; done ) & p4=$!
( while :; do dd if=/dev/zero of=/tmp/s.dat bs=1M count=256 2>/dev/null; rm -f /tmp/s.dat; done ) & p5=$!
( while :; do
	for l in "384M 512M" "0 512M" "384M 0" "0 0" "1G 768M" "64M 64M"; do
		set -- $l; echo "$1" > $P/soft_limit; echo "$2" > $P/hard_limit; sleep 1
	done
  done ) & p6=$!
sleep "$STRESS"
kill $p6 $p5 $p4 $p3 $p2 $p1 2>/dev/null
wait 2>/dev/null
setl 0 0; rm -f /data/w.dat; sync
pass "stress finished"

# 16. kernel log must be clean
# (the SRSO line is QEMU -cpu host printing the host CPU's mitigation notice at boot)
if dmesg | grep -E 'BUG:|WARNING:|KASAN|possible circular|possible recursive|inconsistent lock|blocked for more than|soft lockup|hard LOCKUP|general protection|Call Trace' |
   grep -v 'Speculative Return Stack Overflow' > /tmp/bad.txt; then
	fail "kernel log has $(wc -l < /tmp/bad.txt) bad lines:"; cat /tmp/bad.txt
else
	pass "kernel log clean (no lockdep/KASAN/WARN/hung task)"
fi

echo "== stats"; cat $P/stats
echo "RESULT fails=$fails"
sync
poweroff -f
