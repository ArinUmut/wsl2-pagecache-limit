# wsl2-pagecache-limit — WSL2 çekirdeği için page cache limiti

WSL2 VM'inde çekirdeğin dokunduğu her sayfa Windows'taki `vmmemWSL` sürecinde kalır.
11 Kasım 2026'daki 0x154 mavi ekranından hemen önce VM 20 GB sınırına dayanmıştı;
bunun ~16.9 GB'ı page cache idi. Bu repo, Microsoft'un WSL çekirdeğine toplam bellek
limitinden **ayrı** bir page cache limiti ekleyen tek bir yama ile bu yamayı
derleyen, test eden, kuran ve güncelleyen script'leri içerir.

> BSOD'un kök nedeni kanıtlanmadı (dump yazılamadı). Bu iş bellek baskısını azaltır;
> çökmenin tekrarlanmayacağını garanti etmez.

## Ne yapar

İki bağımsız limit, ikisi de varsayılan olarak kapalıdır (0) ve birlikte ya da tek
başına kullanılabilir:

| Limit | Mod | Davranış |
|---|---|---|
| `soft_limit` | async reclaim | File LRU'lar (Active(file)+Inactive(file)) limiti aşınca `kpclimitd` kthread'i arka planda dosya sayfalarını geri kazanır; limitin biraz altına iner (soft/32, 16M–256M arası pay). |
| `hard_limit` | sync reclaim | **Temiz** page cache limitin üstündeyken, page cache'e sayfa ekleyen işlem önce eklediği kadar dosya sayfasını kendisi geri kazanır (memcg `memory.max` modeli, yalnız dosya sayfaları). Worker da uyandırılır. |

- Geri kazanım `memory.reclaim`'in kullandığı yoldur: root memcg üzerinde
  `try_to_free_mem_cgroup_pages(..., MEMCG_RECLAIM_PROACTIVE)`, `MAY_SWAP` olmadan.
  Yalnız file LRU taranır; anon belleğe ve swap'a dokunulmaz.
- Hard limit **best-effort**'tur ve hiçbir allocation'ı başarısız yapmaz:
  - dirty/writeback sayfalar hariç tutulur (direct reclaim onları yazamaz; onları
    `vm.dirty_bytes` sınırlar);
  - bloklayamayan, NOFAIL, NOIO, PF_MEMALLOC, kthread, ölmekte olan işlem ve
    RWF_DONTCACHE eklemeleri sync reclaim yapmaz, yalnız worker'ı uyandırır;
  - cgroup v1'de sync reclaim yapılmaz;
  - hedefinin yarısından azını geri kazanan çağrı 20 ms'lik (1 s'ye kadar ikiye
    katlanan) bir back-off başlatır; geri kazanılamayan cache her eklemede yeniden
    taranmaz.
- Limit kapalıyken kanca, `filemap_add_folio()` içinde yamalanmış bir NOP'tur
  (static key). Açıkken global sayaçlar CPU başına 64 sayfada bir okunur.

## Arayüz

```bash
# çalışma anında (root)
cat /sys/module/pagecache_limit/parameters/soft_limit     # bayt
echo 3G > /sys/module/pagecache_limit/parameters/soft_limit
echo 4G > /sys/module/pagecache_limit/parameters/hard_limit
cat /sys/module/pagecache_limit/parameters/stats           # sayaçlar
scripts/pclimit.sh show
```

- Değerler: bayt, isteğe bağlı K/M/G/T son eki, `0` = kapalı, değilse en az 64M.
  Ondalık kabul edilmez (`1.5G` yerine `1536M`).
- Soft limit hard'dan büyükse hard'a eşit sayılır (iki yazmanın sırası önemsiz).
- Açılışta: `.wslconfig` → `[wsl2] kernelCommandLine = pagecache_limit.soft_limit=3G pagecache_limit.hard_limit=4G`.

**Kalıcı değiştirmek için (Windows, restart gerekmez):**

```powershell
.\scripts\set-limits.ps1 -Soft 3G -Hard 4G
.\scripts\set-limits.ps1 -DirtyBytes 1G -DirtyBackgroundBytes 256M
.\scripts\set-limits.ps1 -Soft 0 -Hard 0      # kapat
```

Script'ler WSL içinde `/root/work/wsl2-pagecache-limit/scripts/` altında; Windows'tan
`\\wsl.localhost\Ubuntu-24.04\root\work\wsl2-pagecache-limit\scripts\` yoluyla çalıştırılır.

## Çekirdek config'i

`Microsoft/config-wsl` + [config/pclimit.fragment](config/pclimit.fragment):

- KVM, KVM_AMD, VHOST, VHOST_VSOCK `=y` (WSL içinde iç içe VM'ler için). VHOST_NET
  `=m`: TUN modül olduğu için `=y` olamıyor.
- `GCC_PLUGIN_LATENT_ENTROPY=y` (Microsoft'ta kapalı).
- RANDSTRUCT **kapalı**: GCC randstruct eklentisi BTF'yi kapatıyor
  (`DEBUG_INFO_BTF depends on !GCC_PLUGIN_RANDSTRUCT`); BTF açık kalsın diye seçildi.
- `scripts/build.sh` her fragment satırının uygulandığını ve config-wsl'den her farkın
  [config/allowed-diff.txt](config/allowed-diff.txt) içinde olduğunu doğrular; aksi
  halde build durur.

## Kurulum, geri alma, güncelleme

```bash
scripts/build.sh                       # release: bzImage + modules.vhdx (out/<tag>-release)
scripts/build.sh --variant debug       # KASAN + lockdep test çekirdeği
tests/qemu/run.sh                      # debug çekirdekte QEMU/KVM testleri (10 dk stres)
```

```powershell
.\scripts\install.ps1 -Soft 3G -Hard 4G -Apply   # yedek + .wslconfig + restart + doğrulama, hata olursa otomatik geri dönüş
.\scripts\rollback.ps1                           # en son .wslconfig.pclimit-*.bak'a dön
.\scripts\rollback.ps1 -BackupPath <ilk kurulumdan önceki .wslconfig yedeği>   # önceki çekirdeğe dön
```

Microsoft yeni bir çekirdek yayınladığında:

```bash
scripts/check-update.sh      # 0 = güncel, 10 = yeni tag; yamanın bağlı olduğu config/fonksiyonlar değiştiyse "RETEST REQUIRED"
scripts/build.sh --tag <yeni-tag> && tests/qemu/run.sh
```

Yama `patches/BASE_TAG` üstüne `git am` ile uygulanır, ardından `git rebase --onto`
ile yeni tag'e taşınır; çakışma olursa build durur. Yama elle taşındıktan sonra
`scripts/export-patch.sh` ile dışa aktarılır ve `BASE_TAG` güncellenir.

## Dosyalar

| Yol | İçerik |
|---|---|
| `patches/0001-*.patch` | Çekirdek yaması: `mm/pagecache_limit.c`, `include/linux/pagecache_limit.h`, `mm/filemap.c` (+2 satır), `mm/Makefile` (+1) |
| `config/` | config fragment'ları, izin verilen farklar, dirty sysctl dosyası |
| `scripts/` | fetch, build, export-patch, check-update, install, rollback, set-limits, pclimit |
| `tests/qemu/` | test VM'i (`init.sh`), statik yardımcı (`pcltest.c`), çalıştırıcı |
| `tests/` | `validate.sh` (kurulum kapıları; makineye özgü ek kapılar git'e girmeyen `validate.local.sh`'ye yazılabilir), `wsl-func.sh`, `wsl-hardonly.sh`, `wsl-perf.sh`, `wsl-ab.sh` (dönüşümlü A/B), `wsl-hookcost.sh`, `wsl-diag.sh` (sayaç farkları), `host-effect.ps1` |
| `results/` | ölçüm çıktıları |

## Test ve ölçüm sonuçları (11 Kasım 2026, `linux-msft-wsl-6.18.58.1`)

Ham çıktılar `results/` altında.

**Yama kalitesi:** 4 dosya, +619 satır. `checkpatch.pl --strict`: 0 hata, yalnız ağaç
dışı yamada beklenen MAINTAINERS uyarısı. `W=1` + sparse: yeni dosyada uyarı yok.
Kapalıyken kanca, `filemap_add_folio` içinde 5 baytlık bir `nopl`'dur (objdump).

**QEMU/KVM, debug çekirdek** (KASAN, lockdep, DEBUG_VM, hung-task; 4 GB VM, soft 384M / hard 512M):
tüm senaryolar ve 10 dakikalık stres `RESULT fails=0`, kernel logu temiz.

| Senaryo | Sonuç |
|---|---|
| yalnız hard, 2 GiB okuma | temiz cache tepe 512–514 MiB |
| yalnız soft | okuma sonrası ≤ soft |
| dirty yazım / sendfile | geçici temiz tepe 526–616 MiB; yazma+sync'ten 0.0–0.2 sn sonra ≤ hard |
| `memory.min` ile korunan cache | back-off devreye giriyor, spin yok |
| mmap, RWF_NOWAIT, RWF_DONTCACHE, loop, tmpfs, mlock, 200 cgroup | geçti |
| açılışta hatalı parametre (`12Q`, `stats=1`) | reddedildi, oops yok |

**Gerçek WSL** (kurulu çekirdek, 3G/4G, dirty 1G/256M):

| Ölçüm | Sonuç |
|---|---|
| 10 GiB okuma | cache tepe 3.0 GiB (soft), okuma bitince hemen ≤ soft; senkron yol hiç gerekmedi |
| yalnız hard, 10 GiB okuma | temiz cache tepe 4.0 GiB (limitin 2 MiB üstü), 1,567 sync çağrısı |
| yalnız hard, 6 GiB yazma | geçici temiz tepe 4.11 GiB, sync'ten hemen sonra ≤ hard |
| **Windows `vmmemWSL`, aynı 10 GiB okuma** | **tepe 12.5 GiB → 4.4 GiB**; 30 sn sonra 9.8 GiB → 1.8 GiB |

**Performans:**

| Ölçüm | Sonuç |
|---|---|
| Limit kapalı, 6.18.40.1 baseline'a karşı (fio, 3 tekrar medyan) | seqread 4859 → 5244 MB/s, randread 23035 → 23519 IOPS, seqwrite 509 → 534 MB/s, syscall 0.124 → 0.123 µs, sched messaging 1.314 → 1.346 s (+2.4%) |
| Kanca maliyeti, RAM-destekli (tmpfs'te loop ext4, 2 GB okuma, 7 tur, dönüşümlü) | kapalı 10716 MB/s, açık-limit-altında 11865, soft aşımı 11703, hard aşımı 9057 MB/s (−24%: senkron geri kazanımın okuyan işleme maliyeti) |
| Disk (VHDX) A/B, 5 tur dönüşümlü | host tarafı oynaklık çok yüksek (aynı oturumda yazma 996 → 85 MB/s). Eşleştirilmiş açık/kapalı oran medyanı okuma 1.58, yazma 1.05. Tutarlı bir yavaşlama görülmedi, ama bu ölçüm kesin sonuç vermiyor. |

**Güncelleme dayanıklılığı:** yama 6.18.33.2 ve 6.18.54.1'e `git rebase --onto` ile
çakışmasız taşındı. `check-update.sh`, 54.1 → 58.1'de değişiklik bulmadı (dosyalar aynı),
33.2 → 58.1'de `__filemap_add_folio` ve `shrink_folio_list` değişikliklerini işaretledi.

## Bilinen sınırlar

- **Hard limit senkron ama best-effort.** Dirty/writeback sayfalar hariçtir; yazma
  yüklerinde writeback sayfaları toplu temizlediği için temiz cache kısa süre limiti
  aşabilir. Worker bunu limitin üstünde kaldığı sürece HZ/4 aralıkla izleyip eritir.
  Toplam cache ≈ hard + `vm.dirty_bytes` ile sınırlıdır.
- **Tüm distro'lar aynı çekirdeği paylaşır.** Herhangi bir distro'nun root'u VM çapındaki
  limiti değiştirebilir.
- **Ayrıcalıksız kullanıcı cache'i doldurarak başkalarını sync reclaim ödemeye zorlayabilir.**
  Bunu çağrı başı reclaim miktarı ve back-off sınırlar; bugün RAM'i doldurmakla aynı sınıf.
- **İç API bağımlılığı:** `try_to_free_mem_cgroup_pages` bir iç API'dir. İmza değişirse
  build kırılır; davranış değişirse `check-update.sh` "RETEST REQUIRED" der.
- **Kanca ölçümü:** planda brd ramdisk vardı; yerine eşdeğer bir RAM-destekli düzen
  (tmpfs üzerinde loop-mount ext4) kullanıldı.

## Gereksinimler

- WSL2 (3.0.5 ile test edildi). İçinde Ubuntu 24.04, script'ler root olarak çalışır.
- **Derleme:** `build-essential flex bison bc dwarves libelf-dev libssl-dev cpio qemu-utils rsync`,
  ayrıca `gcc-13-plugin-dev` (LATENT_ENTROPY için GCC eklentileri).
- **Testler:** `qemu-system-x86 busybox-static fio`, isteğe bağlı `sparse`. QEMU testleri için
  WSL'de `/dev/kvm` (iç içe sanallaştırma) gerekir.

## Lisans

GPL-2.0-only ([LICENSE](LICENSE)). Çekirdek yaması Linux çekirdeğinin GPL-2.0 dosyalarını
değiştirdiği için repo bütünüyle aynı lisansla dağıtılır.
