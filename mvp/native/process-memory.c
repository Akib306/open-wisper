#include <errno.h>
#include <libproc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
  for (int index = 1; index < argc; index += 1) {
    char *end = NULL;
    errno = 0;
    long parsed_pid = strtol(argv[index], &end, 10);
    if (errno != 0 || end == argv[index] || *end != '\0' || parsed_pid <= 0) continue;

    struct rusage_info_v4 usage = {0};
    int result = proc_pid_rusage(
      (int)parsed_pid,
      RUSAGE_INFO_V4,
      (rusage_info_t *)&usage
    );
    if (result != 0) continue;

    printf(
      "%ld %llu %llu\n",
      parsed_pid,
      (unsigned long long)usage.ri_phys_footprint,
      (unsigned long long)usage.ri_lifetime_max_phys_footprint
    );
  }

  return 0;
}
