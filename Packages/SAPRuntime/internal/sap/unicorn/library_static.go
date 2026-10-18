//go:build asspp_static

package unicorn

/*
#include <stdint.h>
#include <unicorn/unicorn.h>

// Apple arm64 passes variadic arguments on the stack. A fixed-signature
// trampoline is necessary; binding uc_ctl as a three-argument function is not
// ABI-compatible on a real iPhone or an Apple Silicon Mac.
static int asspp_uc_ctl(uintptr_t engine, uint32_t control, uint32_t model) {
    return uc_ctl((uc_engine *)engine, control, model);
}

// Direct references work when LiveContainer loads the guest with local symbol
// visibility, and anchor the functions against static-linker dead stripping.
static uintptr_t asspp_uc_symbol(int index) {
    switch (index) {
        case 0: return (uintptr_t)uc_version;
        case 1: return (uintptr_t)uc_open;
        case 2: return (uintptr_t)uc_close;
        case 3: return (uintptr_t)uc_query;
        case 4: return (uintptr_t)asspp_uc_ctl;
        case 5: return (uintptr_t)uc_strerror;
        case 6: return (uintptr_t)uc_mem_map;
        case 7: return (uintptr_t)uc_mem_unmap;
        case 8: return (uintptr_t)uc_mem_read;
        case 9: return (uintptr_t)uc_mem_write;
        case 10: return (uintptr_t)uc_reg_read;
        case 11: return (uintptr_t)uc_reg_write;
        case 12: return (uintptr_t)uc_emu_start;
        case 13: return (uintptr_t)uc_emu_stop;
        case 14: return (uintptr_t)uc_hook_add;
        case 15: return (uintptr_t)uc_hook_del;
        default: return 0;
    }
}
*/
import "C"

import "context"

func openLibrary(ctx context.Context) (library, error) {
	if err := ctx.Err(); err != nil {
		return library{}, err
	}
	symbols := []string{
		"uc_version", "uc_open", "uc_close", "uc_query", "uc_ctl", "uc_strerror",
		"uc_mem_map", "uc_mem_unmap", "uc_mem_read", "uc_mem_write",
		"uc_reg_read", "uc_reg_write", "uc_emu_start", "uc_emu_stop", "uc_hook_add", "uc_hook_del",
	}
	addresses := make(map[string]uintptr, len(symbols))
	for index, name := range symbols {
		addresses[name] = uintptr(C.asspp_uc_symbol(C.int(index)))
	}
	return library{close: func() error { return nil }, lookup: func(name string) uintptr { return addresses[name] }}, nil
}
