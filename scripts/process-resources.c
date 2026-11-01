// macOS per-process counters; read-only and usable for the current user's processes.
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: process-resources PID\n"); return 2; }
    int pid = atoi(argv[1]);
    struct rusage_info_v4 info = {0};
    if (pid <= 0 || proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&info) != 0) {
        perror("proc_pid_rusage"); return 1;
    }
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    // These CPU counters use Mach absolute ticks on Apple Silicon. Convert,
    // rather than assuming the counter unit equals one nanosecond.
    uint64_t user_ns = (uint64_t)((long double)info.ri_user_time * timebase.numer / timebase.denom);
    uint64_t system_ns = (uint64_t)((long double)info.ri_system_time * timebase.numer / timebase.denom);
    printf("{\"pid\":%d,\"userNanoseconds\":%" PRIu64 ",\"systemNanoseconds\":%" PRIu64
           ",\"packageIdleWakeups\":%" PRIu64 ",\"interruptWakeups\":%" PRIu64
           ",\"rss\":%" PRIu64 ",\"physicalFootprint\":%" PRIu64 "}\n",
           pid, user_ns, system_ns, info.ri_pkg_idle_wkups,
           info.ri_interrupt_wkups, info.ri_resident_size, info.ri_phys_footprint);
    return 0;
}
