#include "BootPolicy.h"

#include <errno.h>
#include <limits.h>
#include <string.h>

_Static_assert(sizeof(time_t) <= sizeof(int64_t),
               "BootPolicy requires a time_t no wider than int64_t");

static bool BTTimeToInt64(time_t value, int64_t *converted) {
    if ((time_t)-1 > (time_t)0 && value > (time_t)INT64_MAX) {
        return false;
    }
    int64_t candidate = (int64_t)value;
    if ((time_t)candidate != value) {
        return false;
    }
    *converted = candidate;
    return true;
}

static int BTDaysInMonth(int64_t year, int month) {
    static const int days[12] = {
        31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
    };
    if (month == 1 && year % 4 == 0 &&
        (year % 100 != 0 || year % 400 == 0)) {
        return 29;
    }
    return days[month];
}

bool BTComputeShift(time_t boot, int months, int64_t *delta, time_t *shifted) {
    if (months <= 0 || delta == NULL || shifted == NULL) {
        return false;
    }

    int saved_errno = errno;
    struct tm original;
    if (gmtime_r(&boot, &original) == NULL ||
        original.tm_mon < 0 || original.tm_mon > 11 ||
        original.tm_mday < 1 || original.tm_mday > 31) {
        errno = saved_errno;
        return false;
    }

    int64_t month_index = ((int64_t)original.tm_year + 1900) * 12 +
                          original.tm_mon - (int64_t)months;
    int64_t target_year = month_index / 12;
    int target_month = (int)(month_index % 12);
    if (target_month < 0) {
        target_month += 12;
        target_year--;
    }
    int64_t target_tm_year = target_year - 1900;
    if (target_tm_year < INT_MIN || target_tm_year > INT_MAX) {
        errno = saved_errno;
        return false;
    }

    struct tm target = original;
    target.tm_year = (int)target_tm_year;
    target.tm_mon = target_month;
    int last_day = BTDaysInMonth(target_year, target_month);
    if (target.tm_mday > last_day) {
        target.tm_mday = last_day;
    }
    target.tm_isdst = 0;
    struct tm intended = target;

    errno = 0;
    time_t candidate = timegm(&target);
    if (candidate == (time_t)-1 && errno != 0) {
        errno = saved_errno;
        return false;
    }
    struct tm verified;
    if (gmtime_r(&candidate, &verified) == NULL ||
        verified.tm_year != intended.tm_year ||
        verified.tm_mon != intended.tm_mon ||
        verified.tm_mday != intended.tm_mday ||
        verified.tm_hour != intended.tm_hour ||
        verified.tm_min != intended.tm_min ||
        verified.tm_sec != intended.tm_sec) {
        errno = saved_errno;
        return false;
    }

    int64_t raw_seconds;
    int64_t shifted_seconds;
    if (!BTTimeToInt64(boot, &raw_seconds) ||
        !BTTimeToInt64(candidate, &shifted_seconds) ||
        shifted_seconds >= raw_seconds) {
        errno = saved_errno;
        return false;
    }
    /* Unsigned subtraction also handles two representable dates whose signed
     * difference would overflow. Reject a difference too large for the API. */
    uint64_t difference = (uint64_t)raw_seconds - (uint64_t)shifted_seconds;
    if (difference > (uint64_t)INT64_MAX) {
        errno = saved_errno;
        return false;
    }

    *delta = (int64_t)difference;
    *shifted = candidate;
    errno = saved_errno;
    return true;
}

bool BTApplyShift(struct timeval *value, size_t input_capacity,
                  size_t returned_length, int64_t delta) {
    if (value == NULL || input_capacity < sizeof(struct timeval) ||
        returned_length < sizeof(struct timeval) || delta <= 0) {
        return false;
    }

    struct timeval original;
    memcpy(&original, value, sizeof(original));
    int64_t raw_seconds;
    if (!BTTimeToInt64((time_t)original.tv_sec, &raw_seconds) ||
        original.tv_usec < 0 || original.tv_usec >= 1000000 ||
        raw_seconds < delta) {
        return false;
    }

    original.tv_sec = (time_t)(raw_seconds - delta);
    memcpy(value, &original, sizeof(original));
    return true;
}

bool BTIsBootMIB(const int *mib, unsigned count) {
    if (mib == NULL || count != 2) {
        return false;
    }
    int values[2];
    memcpy(values, mib, sizeof(values));
    return values[0] == 1 && values[1] == 21;
}
