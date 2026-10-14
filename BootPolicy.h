#ifndef EGGPLANT_BOOT_POLICY_H
#define EGGPLANT_BOOT_POLICY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/time.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Move a UTC calendar date back by whole months, clamping the day at month end.
 * Failure leaves both output arguments unchanged. */
bool BTComputeShift(time_t boot, int months, int64_t *delta, time_t *shifted);

/* Modify only a complete, valid timeval. Fractional seconds are preserved.
 * Failure leaves the supplied buffer unchanged. */
bool BTApplyShift(struct timeval *value, size_t input_capacity,
                  size_t returned_length, int64_t delta);

/* Accept only the exact Darwin CTL_KERN / KERN_BOOTTIME MIB. */
bool BTIsBootMIB(const int *mib, unsigned count);

#ifdef __cplusplus
}
#endif

#endif
