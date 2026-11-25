// Exercise the production native retirement controller with deterministic
// providers. These tests do not claim to verify real game or GPU teardown.
#include <assert.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include "s2a_session.h"
static atomic_int completed, stopped_services, stopped_graphics, rebuilt;
static int fail_join;
static atomic_int expected_state;
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec; }
int s2a_thread_restart_supported(void) { return 1; }
int s2a_window_ok(void) { return 1; }
int s2a_thread_stop_all(int timeout) { return fail_join; }
int s2a_svc_park_all(int timeout) { return 0; }
int S2A_CancelSessionWaits(unsigned generation) { assert(generation == s2a_session_generation()); return 0; }
int s2a_graphics_request_stop(void) { return 0; }
int s2a_graphics_restart_check(void) { return 0; }
void s2a_track_bind_host(void) {}
int S2A_InitSession(void) { return 0; }
int S2A_ShutdownSession(void) { assert(!fail_join); atomic_fetch_add(&stopped_services, 1); return 0; }
int s2a_graphics_shutdown_session(void) { assert(atomic_load(&stopped_services) > atomic_load(&stopped_graphics)); atomic_fetch_add(&stopped_graphics, 1); return 0; }
int s2a_host_rebuild(void) { atomic_fetch_add(&rebuilt, 1); return 0; }
static void done(int result, const char *detail, void *context) {
    if (fail_join) assert(result != 0);
    else { assert(result == 0); assert(s2a_host_session_state() == atomic_load(&expected_state)); }
    atomic_store(&completed, 1);
}
int main(int argc, char **argv) {
    fail_join = argc > 1;
    assert(s2a_session_prepare() == 0);
    assert(s2a_session_running(1) == 0);
    atomic_store(&expected_state, S2A_SESSION_STOPPED);
    assert(s2a_host_stop(done, NULL) == 0);
    for (int i = 0; i < 1200 && !atomic_load(&completed); i++) usleep(10000);
    assert(atomic_load(&completed));
    assert(atomic_load(&rebuilt) == 0);
    assert(atomic_load(&stopped_services) == !fail_join);
    assert(atomic_load(&stopped_graphics) == !fail_join);
    if (!fail_join) {
        int (*resume)(s2a_restart_callback, void *) = dlsym(RTLD_DEFAULT, "s2a_host_resume");
        assert(resume && "retired session must be restartable without exiting the process");
        for (unsigned generation = 2; generation <= 3; generation++) {
            atomic_store(&completed, 0);
            atomic_store(&expected_state, S2A_SESSION_RUNNING);
            assert(resume(done, NULL) == 0);
            for (int i = 0; i < 1200 && !atomic_load(&completed); i++) usleep(10000);
            assert(atomic_load(&completed));
            assert(s2a_session_generation() == generation);
            assert(atomic_load(&stopped_services) == generation - 1);
            assert(atomic_load(&rebuilt) == generation - 1);
            atomic_store(&completed, 0);
            atomic_store(&expected_state, S2A_SESSION_STOPPED);
            assert(s2a_host_stop(done, NULL) == 0);
            for (int i = 0; i < 1200 && !atomic_load(&completed); i++) usleep(10000);
            assert(atomic_load(&completed));
            assert(atomic_load(&stopped_services) == generation);
            assert(atomic_load(&stopped_graphics) == generation);
        }
    }
    puts(fail_join ? "PASS: failed guest join retains resources" : "PASS: stop/resume/stop repeats for 3 generations without duplicate retirement");
}
