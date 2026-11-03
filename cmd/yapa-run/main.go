// yapa-run sets iOS's per-process memory cap (jetsam) for a launchd daemon, then becomes that daemon.
// launchd gives jobs it doesn't know a cap too small for cloudflared, and ignores JetsamProperties in /var/jb plists.
//
//	yapa-run <MB> <program> [args...]
package main

/*
#include <stddef.h>
#include <stdint.h>
// From xnu's sys/kern_memorystatus.h, which the SDK doesn't ship.
int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);
#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT 6
static int set_cap(int mb) { return memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, 0, mb, NULL, 0); }
*/
import "C"

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"syscall"
)

func main() {
	if len(os.Args) < 3 {
		fail("usage: yapa-run <MB> <program> [args...]")
	}
	mb, err := strconv.Atoi(os.Args[1])
	if err != nil || mb <= 0 {
		fail("yapa-run: the cap is a number of MB, like 128, not %q", os.Args[1])
	}
	// pid 0 is this process; the cap stays with it across exec. Only root may raise it, and macOS has no cap to
	// raise, so a failure is reported and the daemon starts anyway.
	if r, err := C.set_cap(C.int(mb)); r != 0 {
		fmt.Fprintf(os.Stderr, "yapa-run: couldn't set a %d MB memory cap: %v\n", mb, err)
	}
	prog, err := exec.LookPath(os.Args[2])
	if err != nil {
		fail("yapa-run: %v", err)
	}
	err = syscall.Exec(prog, os.Args[2:], os.Environ())
	fail("yapa-run: %s: %v", prog, err)
}

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", a...)
	os.Exit(2)
}
