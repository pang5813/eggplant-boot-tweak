/* Build on macOS with the real implementation and an inert Substrate stub:
 * cc -std=c11 -D_DARWIN_C_SOURCE -c BootPolicy.c -o /tmp/boot_policy.o
 * clang -std=c11 -D_DARWIN_C_SOURCE -fobjc-arc -Wall -Wextra -Werror
 *   -I tests/stubs -framework Foundation tests/main_image_test.m /tmp/boot_policy.o
 *   -o main_image_test
 */

// Include system declarations before applying the test's dyld substitutions.
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    const struct mach_header *header;
    const char *path;
    intptr_t slide;
} BTMockImage;

static BTMockImage s_images[8];
// Static zero initialization is intentional: the actual implementation's
// constructor sees no images and returns before querying or hooking sysctl.
static uint32_t s_image_count;

static uint32_t BTMockImageCount(void) {
    return s_image_count;
}

static const struct mach_header *BTMockImageHeader(uint32_t index) {
    return index < s_image_count ? s_images[index].header : NULL;
}

static const char *BTMockImageName(uint32_t index) {
    return index < s_image_count ? s_images[index].path : NULL;
}

static intptr_t BTMockImageSlide(uint32_t index) {
    return index < s_image_count ? s_images[index].slide : 0;
}

#define _dyld_image_count BTMockImageCount
#define _dyld_get_image_header BTMockImageHeader
#define _dyld_get_image_name BTMockImageName
#define _dyld_get_image_vmaddr_slide BTMockImageSlide
#include "../eggplant_boot_tweak.m"
#undef _dyld_image_count
#undef _dyld_get_image_header
#undef _dyld_get_image_name
#undef _dyld_get_image_vmaddr_slide

typedef struct {
    struct mach_header_64 header;
    struct segment_command_64 text;
} BTMockMachO;

static BTMockMachO BTMakeImage(uint32_t filetype, uint64_t vmaddr,
                              uint64_t vmsize) {
    BTMockMachO image;
    memset(&image, 0, sizeof(image));
    image.header.magic = MH_MAGIC_64;
    image.header.filetype = filetype;
    image.header.ncmds = 1;
    image.header.sizeofcmds = sizeof(image.text);
    image.text.cmd = LC_SEGMENT_64;
    image.text.cmdsize = sizeof(image.text);
    memcpy(image.text.segname, "__TEXT", sizeof("__TEXT"));
    image.text.vmaddr = vmaddr;
    image.text.vmsize = vmsize;
    return image;
}

static void BTResetImages(void) {
    memset(s_images, 0, sizeof(s_images));
    s_image_count = 0;
    g_main_text_start = 0;
    g_main_text_end = 0;
    g_main_image_index = UINT32_MAX;
}

static void BTSetImage(uint32_t index, const struct mach_header_64 *header,
                       const char *path, intptr_t slide) {
    assert(index < sizeof(s_images) / sizeof(s_images[0]));
    s_images[index].header = (const void *)header;
    s_images[index].path = path;
    s_images[index].slide = slide;
    if (s_image_count <= index) s_image_count = index + 1;
}

static void BTTestRootHideOrder(void) {
    BTMockMachO systemhook = BTMakeImage(MH_DYLIB, 0x200000000, 0x1000);
    BTMockMachO same_name_dylib = BTMakeImage(MH_DYLIB, 0x300000000, 0x1000);
    BTMockMachO other_executable = BTMakeImage(MH_EXECUTE, 0x400000000, 0x1000);
    BTMockMachO executable = BTMakeImage(MH_EXECUTE, 0x100000000, 0x3000);
    const intptr_t slide = 0x234000;
    BTResetImages();
    BTSetImage(0, &systemhook.header, "/usr/lib/systemhook-test.dylib", 0x1000);
    BTSetImage(1, &same_name_dylib.header, "/usr/lib/Eggplant", 0x2000);
    BTSetImage(2, &other_executable.header, "/Applications/Other.app/Other", 0x3000);
    BTSetImage(3, &executable.header, "/Applications/Eggplant.app/Eggplant", slide);

    assert(BTFindMainText());
    assert(g_main_image_index == 3);
    assert(g_main_text_start == (uintptr_t)executable.text.vmaddr + (uintptr_t)slide);
    assert(g_main_text_end == g_main_text_start + 0x3000);
    assert(!BTCallerIsMain((void *)(g_main_text_start - 1)));
    assert(BTCallerIsMain((void *)g_main_text_start));
    assert(BTCallerIsMain((void *)(g_main_text_end - 1)));
    assert(!BTCallerIsMain((void *)g_main_text_end));

    s_image_count = 3;
    assert(!BTFindMainText());
}

static void BTTestNoTarget(void) {
    BTMockMachO executable = BTMakeImage(MH_EXECUTE, 0x100000000, 0x1000);
    BTResetImages();
    assert(!BTFindMainText());
    BTSetImage(0, NULL, "Eggplant", 0);
    assert(!BTFindMainText());
    BTSetImage(0, &executable.header, NULL, 0);
    assert(!BTFindMainText());
    BTSetImage(0, &executable.header, "/Applications/Eggplant/", 0);
    assert(!BTFindMainText());
    BTSetImage(0, &executable.header, "eggplant", 0);
    assert(!BTFindMainText());
    BTSetImage(0, &executable.header, "Eggplant", 0);
    executable.header.magic = MH_CIGAM_64;
    assert(!BTFindMainText());
    executable.header.magic = MH_MAGIC_64;
    assert(BTFindMainText());
    assert(g_main_image_index == 0);
}

static void BTExpectRejectedCommands(BTMockMachO *image) {
    BTResetImages();
    BTSetImage(0, &image->header, "Eggplant", 0);
    assert(!BTFindMainText());
}

static void BTTestBadCommands(void) {
    BTMockMachO image = BTMakeImage(MH_EXECUTE, 0x100000000, 0x1000);
    image.header.ncmds = 0;
    BTExpectRejectedCommands(&image);
    image.header.ncmds = 1;
    image.header.sizeofcmds = sizeof(struct load_command) - 1;
    BTExpectRejectedCommands(&image);
    image.header.sizeofcmds = sizeof(image.text);
    image.text.cmdsize = sizeof(struct load_command) - 1;
    BTExpectRejectedCommands(&image);
    image.text.cmdsize = sizeof(image.text) + 8;
    BTExpectRejectedCommands(&image);
    image.text.cmdsize = sizeof(struct load_command);
    BTExpectRejectedCommands(&image);
    image.text.cmdsize = sizeof(image.text);
    memcpy(image.text.segname, "__DATA", sizeof("__DATA"));
    BTExpectRejectedCommands(&image);
    memcpy(image.text.segname, "__TEXT", sizeof("__TEXT"));
    image.text.vmsize = 0;
    BTExpectRejectedCommands(&image);
    image.text.vmaddr = (uint64_t)UINTPTR_MAX - 0xfff;
    image.text.vmsize = 0x2000;
    BTExpectRejectedCommands(&image);
}

static void BTTestLaterTextCommand(void) {
    struct {
        struct mach_header_64 header;
        struct uuid_command uuid;
        struct segment_command_64 text;
    } image;
    memset(&image, 0, sizeof(image));
    BTMockMachO template = BTMakeImage(MH_EXECUTE, 0x100000000, 0x4000);
    image.header = template.header;
    image.header.ncmds = 2;
    image.header.sizeofcmds = sizeof(image.uuid) + sizeof(image.text);
    image.uuid.cmd = LC_UUID;
    image.uuid.cmdsize = sizeof(image.uuid);
    image.text = template.text;
    BTResetImages();
    BTSetImage(0, &image.header, "Eggplant", 0x5000);
    assert(BTFindMainText());
    assert(g_main_text_start == 0x100005000);
    assert(g_main_text_end == 0x100009000);
    // A second declared command without enough remaining bytes is rejected.
    image.header.sizeofcmds = sizeof(image.uuid) + sizeof(struct load_command) - 1;
    assert(!BTFindMainText());
}

int main(void) {
    assert(s_image_count == 0);
    assert(!atomic_load_explicit(&g_ready, memory_order_acquire));
    assert(g_original_sysctl == NULL && g_original_byname == NULL);
    assert(g_log_path[0] == '\0');
    BTTestRootHideOrder();
    BTTestNoTarget();
    BTTestBadCommands();
    BTTestLaterTextCommand();
    puts("Main image regression tests passed");
    return 0;
}
