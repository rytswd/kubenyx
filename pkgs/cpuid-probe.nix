# Userspace CPUID prober for CPU-template validation
# (air/v0.1/snapshot/portable-snapshots.org §D4): /proc/cpuinfo cannot prove a
# template masks anything — clearcpuid already scrubs it kernel-side and
# would fake a pass — so this executes the CPUID instruction from
# userspace and prints the AMX/XTILE-bearing leaves raw. Boot it inside a
# guest (console oneshot + repeating timer: the timer's ticks after a
# snapshot restore are the §D4 bake-in proof, since resume-console.log
# only ever contains post-restore output) and diff baseline vs templated.
#
# Deliberately NOT part of any preset guest closure: adding it to
# internal.tools would change every drv. Validation variants import it
# ad hoc.
{ runCommandCC }:
runCommandCC "kubenyx-cpuid" { } ''
  mkdir -p $out/bin
  cat > probe.c <<'EOC'
  #include <stdio.h>
  #include <cpuid.h>

  static void leaf(unsigned l, unsigned s) {
    unsigned a = 0, b = 0, c = 0, d = 0;
    __cpuid_count(l, s, a, b, c, d);
    printf("KUBENYX-CPUID leaf=0x%x.%u eax=0x%08x ebx=0x%08x ecx=0x%08x edx=0x%08x\n",
           l, s, a, b, c, d);
  }

  int main(void) {
    unsigned a = 0, b = 0, c = 0, d = 0;
    /* The named bits the amx-mask template forces to 0 (leaf 0x7.0 EDX
       22/24/25, leaf 0x7.1 EAX 21, leaf 0xD.0 EAX 17/18) — one summary
       line for greppable pass/fail, raw leaves after it for forensics. */
    unsigned bf16, tile, int8, fp16, cfg, data;
    __cpuid_count(7, 0, a, b, c, d);
    bf16 = (d >> 22) & 1; tile = (d >> 24) & 1; int8 = (d >> 25) & 1;
    __cpuid_count(7, 1, a, b, c, d);
    fp16 = (a >> 21) & 1;
    __cpuid_count(0xd, 0, a, b, c, d);
    cfg = (a >> 17) & 1; data = (a >> 18) & 1;
    printf("KUBENYX-CPUID amx_bf16=%u amx_tile=%u amx_int8=%u amx_fp16=%u "
           "xtilecfg=%u xtiledata=%u\n", bf16, tile, int8, fp16, cfg, data);
    leaf(0x7, 0);
    leaf(0x7, 1);
    leaf(0xd, 0);
    leaf(0xd, 1);
    return 0;
  }
  EOC
  $CC -O2 -o $out/bin/kubenyx-cpuid probe.c
''
