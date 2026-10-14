#include "../BootPolicy.h"

#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

static time_t UTCDate(int year, int month, int day,
                      int hour, int minute, int second) {
    struct tm date;
    memset(&date, 0, sizeof(date));
    date.tm_year = year - 1900;
    date.tm_mon = month - 1;
    date.tm_mday = day;
    date.tm_hour = hour;
    date.tm_min = minute;
    date.tm_sec = second;
    time_t result = timegm(&date);
    assert(result != (time_t)-1);
    return result;
}

static void CheckCalendarShift(int year, int month, int day, int months,
                               int expected_year, int expected_month,
                               int expected_day) {
    time_t raw = UTCDate(year, month, day, 12, 34, 56);
    time_t expected = UTCDate(expected_year, expected_month, expected_day,
                              12, 34, 56);
    int64_t delta = -1;
    time_t shifted = (time_t)-1;
    errno = EDOM;
    assert(BTComputeShift(raw, months, &delta, &shifted));
    assert(errno == EDOM);
    assert(shifted == expected);
    assert(delta == (int64_t)raw - (int64_t)expected);
    assert(delta > 0);
}

static void TestCalendar(void) {
    CheckCalendarShift(2026, 5, 31, 3, 2026, 2, 28);
    CheckCalendarShift(2024, 5, 31, 3, 2024, 2, 29);
    CheckCalendarShift(2025, 1, 31, 3, 2024, 10, 31);
    CheckCalendarShift(2025, 3, 30, 1, 2025, 2, 28);
    CheckCalendarShift(2024, 2, 29, 12, 2023, 2, 28);
    CheckCalendarShift(2000, 3, 31, 1, 2000, 2, 29);
    CheckCalendarShift(2100, 3, 31, 1, 2100, 2, 28);

    time_t raw = UTCDate(2026, 10, 15, 0, 0, 0);
    int64_t delta = 123;
    time_t shifted = 456;
    errno = ERANGE;
    assert(!BTComputeShift(raw, 0, &delta, &shifted));
    assert(!BTComputeShift(raw, -3, &delta, &shifted));
    assert(delta == 123 && shifted == 456 && errno == ERANGE);
    assert(!BTComputeShift(raw, 3, NULL, &shifted));
    assert(shifted == 456);
    assert(!BTComputeShift(raw, 3, &delta, NULL));
    assert(delta == 123);
    if (sizeof(time_t) == sizeof(int64_t)) {
        assert(!BTComputeShift((time_t)INT64_MAX, 3, &delta, &shifted));
        assert(delta == 123 && shifted == 456 && errno == ERANGE);
    }
}

static void TestMIB(void) {
    const int boot[] = {1, 21};
    const int other[] = {1, 20};
    const int extra[] = {1, 21, 0};
    assert(BTIsBootMIB(boot, 2));
    assert(!BTIsBootMIB(other, 2));
    assert(!BTIsBootMIB(boot, 1));
    assert(!BTIsBootMIB(extra, 3));
    assert(!BTIsBootMIB(boot, 0));
    assert(!BTIsBootMIB(NULL, 2));

    unsigned char unaligned[sizeof(boot) + 1];
    memcpy(unaligned + 1, boot, sizeof(boot));
    assert(BTIsBootMIB((const int *)(const void *)(unaligned + 1), 2));
}

static void CheckRejectedValue(struct timeval value, size_t capacity,
                               size_t length, int64_t delta) {
    struct timeval before = value;
    assert(!BTApplyShift(&value, capacity, length, delta));
    assert(memcmp(&value, &before, sizeof(value)) == 0);
}

static void TestApply(void) {
    const size_t full = sizeof(struct timeval);
    struct timeval raw;
    memset(&raw, 0, sizeof(raw));
    raw.tv_sec = 1000;
    raw.tv_usec = 123456;
    struct timeval first = raw;
    struct timeval second = raw;
    assert(BTApplyShift(&first, full, full, 100));
    assert(BTApplyShift(&second, full, full, 100));
    assert(first.tv_sec == 900 && first.tv_usec == 123456);
    assert(memcmp(&first, &second, full) == 0);
    assert(raw.tv_sec == 1000 && raw.tv_usec == 123456);

    CheckRejectedValue(raw, full - 1, full, 100);
    CheckRejectedValue(raw, full, full - 1, 100);
    CheckRejectedValue(raw, full, full, 0);
    CheckRejectedValue(raw, full, full, -1);
    CheckRejectedValue(raw, full, full, 1001);
    assert(!BTApplyShift(NULL, full, full, 100));
    struct timeval invalid = raw;
    invalid.tv_usec = -1;
    CheckRejectedValue(invalid, full, full, 100);
    invalid.tv_usec = 1000000;
    CheckRejectedValue(invalid, full, full, 100);
    invalid = raw;
    invalid.tv_sec = -1;
    CheckRejectedValue(invalid, full, full, 100);

    struct timeval zero = raw;
    assert(BTApplyShift(&zero, full, full, 1000));
    assert(zero.tv_sec == 0 && zero.tv_usec == raw.tv_usec);
    struct timeval last_fraction = raw;
    last_fraction.tv_usec = 999999;
    assert(BTApplyShift(&last_fraction, full, full, 100));
    assert(last_fraction.tv_sec == 900 && last_fraction.tv_usec == 999999);
    unsigned char unaligned[sizeof(raw) + 1];
    memcpy(unaligned + 1, &raw, full);
    assert(BTApplyShift((struct timeval *)(void *)(unaligned + 1),
                        full, full, 100));
    struct timeval checked;
    memcpy(&checked, unaligned + 1, full);
    assert(checked.tv_sec == 900 && checked.tv_usec == 123456);
}

int main(void) {
    TestCalendar();
    TestMIB();
    TestApply();
    puts("BootPolicy tests passed");
    return 0;
}
