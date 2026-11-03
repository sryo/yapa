package main

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// A log past logCap keeps its newest logKeep bytes; while all of them pass logsCap the largest is cut the same way,
// or emptied if it's already that small.
const (
	logCap  = 5 << 20
	logKeep = 1 << 20
	logsCap = 50 << 20
)

type logFile struct {
	path string
	size int64
}

// Tidy keeps yapa's logs in dir from filling the phone's disk.
func Tidy(dir string) error {
	ents, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var logs []logFile
	var total int64
	for _, e := range ents {
		if !e.Type().IsRegular() || !strings.HasSuffix(e.Name(), ".log") {
			continue
		}
		fi, err := e.Info()
		if err != nil {
			continue
		}
		l := logFile{filepath.Join(dir, e.Name()), fi.Size()}
		if l.size > logCap {
			if err := cutTo(l.path, logKeep); err != nil {
				return err
			}
			l.size = logKeep
		}
		logs = append(logs, l)
		total += l.size
	}
	sort.Slice(logs, func(i, j int) bool { return logs[i].size > logs[j].size })
	for i := 0; total > logsCap && i < len(logs); i++ {
		keep := int64(logKeep)
		if logs[i].size <= keep {
			keep = 0
		}
		if err := cutTo(logs[i].path, keep); err != nil {
			return err
		}
		total -= logs[i].size - keep
	}
	return nil
}

// cutTo rewrites the file in place with its last n bytes. Keeping the inode lets a daemon's open log go on
// writing to the same file.
func cutTo(path string, n int64) error {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return err
	}
	tail := make([]byte, min(n, fi.Size()))
	if _, err := f.ReadAt(tail, fi.Size()-int64(len(tail))); err != nil && err != io.EOF {
		return err
	}
	if _, err := f.WriteAt(tail, 0); err != nil {
		return err
	}
	return f.Truncate(int64(len(tail)))
}
