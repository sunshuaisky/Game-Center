"""Exercise the actual iOS code-bank allocator without signing game binaries.
The production allocator is compiled unchanged with directory/size fixtures; its
addresses must remain disjoint and stable across title and program transitions.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

engine = Path(sys.argv[1])
source = (engine / 'runtime/src/loader.c').read_text()
a = source.index('typedef struct { char id[128]; int program;')
b = source.index('\n#else\nuint64_t s2a_loader_container_code_size', a)
allocator = source[a:b]
fixture = r'''
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <stdarg.h>
typedef struct { char game_id[128]; } s2a_launch_ctx;
static s2a_launch_ctx selected;
static int image_program, current_program;
static __attribute__((noreturn)) void die(const char *message, ...) { fprintf(stderr, "%s\n", message); abort(); }
static int s2a_programs_count(const char *path) { return !strcmp(path, "A") ? 2 : 1; }
static int s2a_programs_dir(const char *path, int n, char *out, size_t cap) { snprintf(out, cap, "%s/%d", path, n); return 0; }
void s2a_loader_image_program(int p) { image_program = p; }
static uint64_t a0_size = 4ull << 20;
static uint64_t s2a_module_span(const char *path) {
    if (!strcmp(path, "A/0")) { assert(image_program == 0); return a0_size; }
    if (!strcmp(path, "A/1")) { assert(image_program == 1); return 6ull << 20; }
    if (!strcmp(path, "B/0")) { assert(image_program == 0); return 8ull << 20; }
    if (!strcmp(path, "C/0")) { assert(image_program == 0); return 12ull << 20; }
    if (!strcmp(path, "HUGE/0")) { assert(image_program == 0); return 1020ull << 20; }
    assert(0); return 0;
}
static const s2a_launch_ctx *s2a_launch_ctx_get(void) { return &selected; }
static int s2a_host_program_index(void) { return current_program; }
'''
checks = r'''
int main(void) {
    const uint64_t w = 4ull << 30;
    s2a_loader_container_code_add("title-A", "A");
    assert(s2a_loader_container_code_size() == 0); // preserve single-title layout
    s2a_loader_container_code_add("title-B", "B");
    assert(s2a_loader_container_code_size() == (1ull << 30));
    s2a_loader_container_code_add("title-A", "A"); // no duplicate reservation
    strcpy(selected.game_id, "title-A"); current_program = 0;
    assert(s2a_loader_container_code_base(w) == w && g_code_limit == w + (4ull << 20));
    strcpy(selected.game_id, "title-B");
    assert(s2a_loader_container_code_base(w) == w + (10ull << 20) && g_code_limit == w + (18ull << 20));
    strcpy(selected.game_id, "title-A");
    assert(s2a_loader_container_code_base(w) == w);
    current_program = 1;
    assert(s2a_loader_container_code_base(w) == w + (4ull << 20) && g_code_limit == w + (10ull << 20));
    current_program = 0;

    // Pre-lock update when title-A grows compacts slots cleanly.
    a0_size = 6ull << 20;
    assert(s2a_loader_container_code_ensure_tagged("title-A", "A", 101) == 0);
    strcpy(selected.game_id, "title-B");
    assert(s2a_loader_container_code_base(w) == w && g_code_limit == w + (8ull << 20));
    strcpy(selected.game_id, "title-A");
    assert(s2a_loader_container_code_base(w) == w + (8ull << 20) && g_code_limit == w + (14ull << 20));

    // Lock the 1 GiB bank and verify late-imported C, returning to A, updated A, and overflow rejection.
    s2a_loader_container_code_lock();
    assert(s2a_loader_container_code_size() == (1ull << 30));
    assert(s2a_loader_container_code_ensure_tagged("title-C", "C", 201) == 0);
    strcpy(selected.game_id, "title-C");
    assert(s2a_loader_container_code_base(w) == w + (20ull << 20) && g_code_limit == w + (32ull << 20));
    // Returning to unchanged title-A reuses its exact slot.
    assert(s2a_loader_container_code_ensure_tagged("title-A", "A", 101) == 0);
    strcpy(selected.game_id, "title-A");
    assert(s2a_loader_container_code_base(w) == w + (8ull << 20));
    // Re-imported updated title-A (different tag) gets a fresh disjoint slot after C.
    assert(s2a_loader_container_code_ensure_tagged("title-A", "A", 102) == 0);
    assert(s2a_loader_container_code_base(w) == w + (32ull << 20) && g_code_limit == w + (38ull << 20));
    // Overflowing the locked 1 GiB bank is rejected cleanly without losing existing slots.
    assert(s2a_loader_container_code_ensure_tagged("title-HUGE", "HUGE", 301) != 0);
    assert(s2a_loader_container_code_size() == (1ull << 30));
    strcpy(selected.game_id, "title-C");
    assert(s2a_loader_container_code_base(w) == w + (20ull << 20));
    puts("PASS: A -> B -> A, late-import C, updated A, overflow guard, ExecuteProgram slots");
}
'''
with tempfile.TemporaryDirectory(prefix='gc-code-bank-') as tmp:
    path = Path(tmp) / 'test.c'
    path.write_text(fixture + allocator + checks)
    binary = Path(tmp) / 'test'
    subprocess.run(['xcrun', 'clang', '-Werror', '-o', str(binary), str(path)], check=True)
    subprocess.run([str(binary)], check=True)
    # Negative control: assign every title the first slot, the B address assert
    # must fail. This proves the test detects the original overlapping design.
    path.write_text(fixture + allocator.replace('window + g_code_slots[i].offset;', 'window;') + checks)
    subprocess.run(['xcrun', 'clang', '-Werror', '-o', str(binary), str(path)], check=True)
    negative = subprocess.run([str(binary)], capture_output=True)
    assert negative.returncode != 0, 'Negative control did not detect overlapping title slots'
    print('PASS: negative control rejects shared title landing addresses')
