#import <Foundation/Foundation.h>
#include <substrate.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/sysctl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include "BootPolicy.h"

#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

// Stability build: system scheduling clocks and libc syscall are never hooked.
typedef int (*BTSysctlFunction)(int *, u_int, void *, size_t *, void *, size_t);
typedef int (*BTByNameFunction)(const char *, void *, size_t *, void *, size_t);
static BTSysctlFunction g_original_sysctl;
static BTByNameFunction g_original_byname;
static uintptr_t g_main_text_start;
static uintptr_t g_main_text_end;
static uint32_t g_main_image_index;
static int64_t g_delta;
static struct timeval g_original_boot;
static time_t g_shifted_boot;
static _Atomic bool g_ready;
static _Atomic uint64_t g_sysctl_changes;
static _Atomic uint64_t g_byname_changes;
static _Thread_local unsigned g_depth;
static char g_log_path[1024];

static bool BTFindMainText(void) {
    // RootHide can put systemhook ahead of the executable in dyld's list.
    // Locate the actual MH_EXECUTE image instead of assuming image zero.
    const struct mach_header_64 *header = NULL;
    intptr_t slide = 0;
    uint32_t image_count = _dyld_image_count();
    for (uint32_t index = 0; index < image_count; ++index) {
        const struct mach_header_64 *candidate =
            (const void *)_dyld_get_image_header(index);
        const char *path = _dyld_get_image_name(index);
        if (!candidate || candidate->magic != MH_MAGIC_64 ||
            candidate->filetype != MH_EXECUTE || !path) continue;
        const char *base = strrchr(path, '/');
        if (strcmp(base ? base + 1 : path, "Eggplant") != 0) continue;
        header = candidate;
        slide = _dyld_get_image_vmaddr_slide(index);
        g_main_image_index = index;
        break;
    }
    if (!header) return false;
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    const uint8_t *commands_end = cursor + header->sizeofcmds;
    for (uint32_t index = 0; index < header->ncmds; ++index) {
        if ((size_t)(commands_end - cursor) < sizeof(struct load_command)) return false;
        const struct load_command *command = (const void *)cursor;
        if (command->cmdsize < sizeof(*command) ||
            command->cmdsize > (size_t)(commands_end - cursor)) return false;
        if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment = (const void *)cursor;
            if (strncmp(segment->segname, "__TEXT", sizeof(segment->segname)) == 0) {
                g_main_text_start = (uintptr_t)((intptr_t)segment->vmaddr + slide);
                g_main_text_end = g_main_text_start + (uintptr_t)segment->vmsize;
                return g_main_text_end > g_main_text_start;
            }
        }
        cursor += command->cmdsize;
    }
    return false;
}

static bool BTCallerIsMain(void *address) {
#if __has_feature(ptrauth_calls)
    address = ptrauth_strip(address, ptrauth_key_return_address);
#endif
    uintptr_t value = (uintptr_t)address;
    return value >= g_main_text_start && value < g_main_text_end;
}

__attribute__((noinline))
static int BTInterceptSysctl(int *mib, u_int count, void *output, size_t *length,
                           void *input, size_t input_length) {
    BTSysctlFunction original = g_original_sysctl;
    if (!original) { errno = ENOSYS; return -1; }
    bool eligible = atomic_load_explicit(&g_ready, memory_order_acquire) &&
                    g_depth == 0 && BTCallerIsMain(__builtin_return_address(0)) &&
                    output && length && !input && input_length == 0;
    size_t capacity = eligible ? *length : 0;
    unsigned previous_depth = g_depth;
    g_depth = previous_depth + 1;
    int result = original(mib, count, output, length, input, input_length);
    int result_errno = errno;
    g_depth = previous_depth;
    if (eligible && result == 0 && BTIsBootMIB(mib, count) &&
        BTApplyShift(output, capacity, *length, g_delta)) {
        atomic_fetch_add_explicit(&g_sysctl_changes, 1, memory_order_relaxed);
    }
    errno = result_errno;
    return result;
}

__attribute__((noinline))
static int BTInterceptByName(const char *name, void *output, size_t *length,
                           void *input, size_t input_length) {
    BTByNameFunction original = g_original_byname;
    if (!original) { errno = ENOSYS; return -1; }
    bool eligible = atomic_load_explicit(&g_ready, memory_order_acquire) &&
                    g_depth == 0 && BTCallerIsMain(__builtin_return_address(0)) &&
                    output && length && !input && input_length == 0;
    size_t capacity = eligible ? *length : 0;
    unsigned previous_depth = g_depth;
    g_depth = previous_depth + 1;
    int result = original(name, output, length, input, input_length);
    int result_errno = errno;
    g_depth = previous_depth;
    if (eligible && result == 0 && name && strcmp(name, "kern.boottime") == 0 &&
        BTApplyShift(output, capacity, *length, g_delta)) {
        atomic_fetch_add_explicit(&g_byname_changes, 1, memory_order_relaxed);
    }
    errno = result_errno;
    return result;
}

static void BTLogSnapshot(void) {
    if (!g_log_path[0]) return;
    char temporary[1100];
    int size = snprintf(temporary, sizeof(temporary), "%s.tmp", g_log_path);
    if (size < 0 || (size_t)size >= sizeof(temporary)) return;
    FILE *file = fopen(temporary, "w");
    if (!file) return;
    fprintf(file,
        "EggplantBoot stability build 1.0.37\n"
        "scope=Eggplant main executable boot-date queries only\n"
        "main_image_index=%u\n"
        "ready=%d\noriginal_boot_sec=%lld\nshifted_boot_sec=%lld\n"
        "shift_seconds=%lld\ncalendar=UTC, three months, clamp month end\n"
        "sysctl_changed=%llu\nsysctlbyname_changed=%llu\n"
        "global_syscall_hook=disabled\nscheduling_clock_hooks=disabled\n"
        "systemUptime_hook=disabled\nfile_timestamp_hooks=disabled\n"
        "private_direct_svc=not intercepted\n",
        g_main_image_index,
        atomic_load_explicit(&g_ready, memory_order_acquire) ? 1 : 0,
        (long long)g_original_boot.tv_sec, (long long)g_shifted_boot,
        (long long)g_delta,
        (unsigned long long)atomic_load_explicit(&g_sysctl_changes, memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&g_byname_changes, memory_order_relaxed));
    bool success = !ferror(file);
    if (fclose(file) != 0) success = false;
    if (success) (void)rename(temporary, g_log_path);
    else (void)unlink(temporary);
}

static void *BTLogger(void *unused) {
    (void)unused;
    for (;;) {
        BTLogSnapshot();
        sleep(5);
    }
    return NULL;
}

__attribute__((constructor))
static void BTInitialize(void) {
    int entry_errno = errno;
    @autoreleasepool {
        if (!BTFindMainText()) { errno = entry_errno; return; }
        const char *home = getenv("HOME");
        if (home && home[0]) {
            int size = snprintf(g_log_path, sizeof(g_log_path),
                                "%s/Library/Caches/EggplantBootStable.log", home);
            if (size < 0 || (size_t)size >= sizeof(g_log_path)) g_log_path[0] = '\0';
        }
        int mib[2] = {CTL_KERN, KERN_BOOTTIME};
        size_t size = sizeof(g_original_boot);
        if (sysctl(mib, 2, &g_original_boot, &size, NULL, 0) != 0 ||
            size < sizeof(g_original_boot) ||
            !BTComputeShift(g_original_boot.tv_sec, 3, &g_delta, &g_shifted_boot)) {
            errno = entry_errno;
            return;
        }
        MSHookFunction((void *)sysctl, (void *)BTInterceptSysctl, (void **)&g_original_sysctl);
        MSHookFunction((void *)sysctlbyname, (void *)BTInterceptByName, (void **)&g_original_byname);
        atomic_store_explicit(&g_ready, g_original_sysctl && g_original_byname, memory_order_release);
        pthread_t thread;
        if (pthread_create(&thread, NULL, BTLogger, NULL) == 0) pthread_detach(thread);
    }
    errno = entry_errno;
}
