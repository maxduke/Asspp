#!/usr/bin/env python3
"""Keep Darwin's executable-memory helpers out of the TCI interpreter."""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for name in ["uc.c", "qemu/include/tcg/tcg-apple-jit.h", "qemu/accel/tcg/translate-all.c"]:
    path = root / name
    source = path.read_text()
    old = "#if defined(__APPLE__) && defined(HAVE_PTHREAD_JIT_PROTECT)"
    expected = 2 if name.endswith("tcg-apple-jit.h") else 1
    if source.count(old) != expected:
        raise SystemExit(f"Unexpected pinned TCI source: {name}")
    path.write_text(source.replace(old, "#if !defined(CONFIG_TCG_INTERPRETER) && defined(__APPLE__) && defined(HAVE_PTHREAD_JIT_PROTECT)"))
