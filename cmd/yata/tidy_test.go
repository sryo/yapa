package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func fill(t *testing.T, path string, n int, tail string) {
	t.Helper()
	if err := os.WriteFile(path, append(bytes.Repeat([]byte("x"), n), tail...), 0o644); err != nil {
		t.Fatal(err)
	}
}

func size(t *testing.T, path string) int64 {
	t.Helper()
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return fi.Size()
}

// R6: yata keeps each log under 5 MB, keeping its newest lines, and all of them under 50 MB.
func TestR6_TidyCapsLogs(t *testing.T) {
	dir := t.TempDir()
	big := filepath.Join(dir, "caddy.log")
	fill(t, big, 6<<20, "newest line\n")
	for i := range 11 {
		fill(t, filepath.Join(dir, "old"+string(rune('a'+i))+".log"), 4900<<10, "")
	}
	small := filepath.Join(dir, "yata.log")
	fill(t, small, 100, "")
	// A daemon keeps its log open; it must go on writing to the same file after a cut.
	open, err := os.OpenFile(big, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer open.Close()

	if err := Tidy(dir); err != nil {
		t.Fatal(err)
	}

	if s := size(t, big); s > logCap {
		t.Fatalf("a 6 MB log is still %d bytes", s)
	}
	b, _ := os.ReadFile(big)
	if !bytes.HasSuffix(b, []byte("newest line\n")) {
		t.Fatal("tidy lost the newest lines")
	}
	var total int64
	ents, _ := os.ReadDir(dir)
	for _, e := range ents {
		total += size(t, filepath.Join(dir, e.Name()))
	}
	if total > logsCap {
		t.Fatalf("logs total %d bytes, over 50 MB", total)
	}
	if size(t, small) == 0 {
		t.Fatal("tidy emptied a small log")
	}
	if _, err := open.WriteString("after\n"); err != nil {
		t.Fatal(err)
	}
	b, _ = os.ReadFile(big)
	if !bytes.HasSuffix(b, []byte("after\n")) {
		t.Fatal("an open log no longer reaches the file after a cut")
	}
}

func TestR6_TidyWithoutLogs(t *testing.T) {
	if err := Tidy(filepath.Join(t.TempDir(), "none")); err != nil {
		t.Fatalf("a missing log folder is nothing to tidy, not an error: %v", err)
	}
}
