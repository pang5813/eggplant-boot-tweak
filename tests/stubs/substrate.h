#ifndef BT_TEST_SUBSTRATE_H
#define BT_TEST_SUBSTRATE_H

/* The native regression test never patches executable code. */
static inline void MSHookFunction(void *symbol, void *replacement,
                                  void **original) {
    (void)replacement;
    if (original) *original = symbol;
}

#endif
