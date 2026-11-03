package main

import (
	"os/exec"
	"path/filepath"
	"testing"
)

// yapa-run sets the memory cap, then becomes the daemon: its output is the daemon's, and so is its exit code.
func TestBecomesTheDaemon(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "yapa-run")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	out, err := exec.Command(bin, "64", "/bin/echo", "hi").Output()
	if err != nil || string(out) != "hi\n" {
		t.Fatalf("yapa-run 64 /bin/echo hi = %q, %v; want hi", out, err)
	}
	err = exec.Command(bin, "64", "/bin/sh", "-c", "exit 3").Run()
	if e, ok := err.(*exec.ExitError); !ok || e.ExitCode() != 3 {
		t.Fatalf("exit code = %v, want 3", err)
	}
	if err := exec.Command(bin, "lots", "/bin/echo").Run(); err == nil {
		t.Fatal("a cap that isn't a number of MB must fail")
	}
}
