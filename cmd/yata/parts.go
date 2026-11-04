package main

import (
	"encoding/json"
	"errors"
	"io/fs"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
)

// Parts lets the pad see and change what runs on the phone, on /parts. GET lists the core and every part, each up
// or down and on or off, with disk and log sizes. POST /parts/<name>/on, /off or /restart changes one. Turning a
// part on or off writes its down file and then regenerates the launchd jobs, yata's watch list and the Caddyfile
// the way ./ya does, with the setup script ./ya left on the phone. The Mac's ./ya reads the phone's down files
// before every sync, so a part turned off here stays off. Only the phone itself may change anything: the pad
// runs there, and the rest of the home network can only look.
type Parts struct {
	Dir  string // the parts: <name>/part, and <name>/down when it's off
	Etc  string // setup, Caddyfile.core and domain, left by ./ya
	Jobs string // launchd's plists, com.sryo.yapa.<name>.plist
	Logs string
	Mon  *Monitor
	// Run runs a command on the phone; tests replace it.
	Run func(name string, args ...string) error

	mu sync.Mutex
}

// Part is one thing on the phone, as the pad shows it.
type Part struct {
	Name    string `json:"name"`
	Kind    string `json:"kind"` // core, site or service
	Address string `json:"address,omitempty"`
	On      bool   `json:"on"`
	Up      bool   `json:"up"`
	Watched bool   `json:"watched"` // yata checks it, so Up means something
}

type PartsReply struct {
	Parts      []Part `json:"parts"`
	DiskFreeMB int64  `json:"disk_free_mb"`
	LogsMB     int64  `json:"logs_mb"`
}

// The core's own jobs: always on, and only restarted, never turned off from the pad.
var core = []string{"yata", "caddy", "cloudflared"}

func (p *Parts) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	ip := net.ParseIP(host)
	if ip == nil || !(ip.IsLoopback() || ip.IsPrivate()) {
		http.Error(w, "yata answers the home network only", http.StatusForbidden)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if r.Method == http.MethodGet && r.URL.Path == "/parts" {
		json.NewEncoder(w).Encode(p.List())
		return
	}
	rest, _ := strings.CutPrefix(r.URL.Path, "/parts/")
	name, verb, ok := strings.Cut(rest, "/")
	if r.Method != http.MethodPost || !ok {
		w.WriteHeader(http.StatusNotFound)
		json.NewEncoder(w).Encode(map[string]string{"error": "GET /parts, or POST /parts/<name>/on, off or restart"})
		return
	}
	if !ip.IsLoopback() {
		w.WriteHeader(http.StatusForbidden)
		json.NewEncoder(w).Encode(map[string]string{"error": "only the pad, on the phone itself, can change what runs"})
		return
	}
	if err := p.Change(name, verb); err != nil {
		w.WriteHeader(http.StatusConflict)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}
	json.NewEncoder(w).Encode(p.List())
}

// List is the core's jobs that are installed, then the parts by name.
func (p *Parts) List() PartsReply {
	up := map[string]bool{}
	for _, s := range p.Mon.Snapshot().Services {
		up[s.Name] = s.Up
	}
	var out []Part
	for _, n := range core {
		if _, err := os.Stat(p.job(n)); err == nil || n == "yata" {
			_, watched := up[n]
			out = append(out, Part{Name: n, Kind: "core", On: true, Up: up[n], Watched: watched})
		}
	}
	ents, _ := os.ReadDir(p.Dir)
	sort.Slice(ents, func(i, j int) bool { return ents[i].Name() < ents[j].Name() })
	for _, e := range ents {
		kv, err := readPart(filepath.Join(p.Dir, e.Name(), "part"))
		if err != nil {
			continue
		}
		_, down := os.Stat(filepath.Join(p.Dir, e.Name(), "down"))
		_, watched := up[e.Name()]
		out = append(out, Part{Name: e.Name(), Kind: kv["kind"], Address: kv["address"], On: down != nil,
			Up: up[e.Name()], Watched: watched})
	}
	reply := PartsReply{Parts: out, LogsMB: dirSize(p.Logs) >> 20}
	var st syscall.Statfs_t
	if syscall.Statfs(p.Dir, &st) == nil {
		reply.DiskFreeMB = int64(st.Bavail) * int64(st.Bsize) >> 20
	}
	return reply
}

// Change turns a part on or off, or restarts it or a core job.
func (p *Parts) Change(name, verb string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	isCore := false
	for _, n := range core {
		isCore = isCore || n == name
	}
	dir := filepath.Join(p.Dir, name)
	kv, err := readPart(filepath.Join(dir, "part"))
	if !isCore && err != nil {
		return errors.New("there's no part called " + name)
	}
	switch verb {
	case "restart":
		job := name
		if kv["kind"] == "site" {
			job = "caddy" // a site is a block in Caddy's file, so restarting it is restarting Caddy
		}
		if job == "yata" {
			return errors.New("yata can't restart itself from here")
		}
		if _, err := os.Stat(p.job(job)); err != nil {
			return errors.New(name + " isn't running, so there's nothing to restart")
		}
		_ = p.Run("launchctl", "unload", p.job(job))
		return p.Run("launchctl", "load", p.job(job))
	case "on", "off":
		if isCore {
			return errors.New(name + " is part of yapa itself and stays on")
		}
		if verb == "on" {
			for _, n := range strings.Fields(kv["needs"]) {
				if _, err := os.Stat(filepath.Join(p.Dir, n, "down")); err == nil {
					return errors.New(name + " needs " + n + ", which is off: turn " + n + " on first")
				}
			}
			if err := os.Remove(filepath.Join(dir, "down")); err != nil && !errors.Is(err, fs.ErrNotExist) {
				return err
			}
		} else if err := os.WriteFile(filepath.Join(dir, "down"), nil, 0o644); err != nil {
			return err
		}
		// The setup ./ya runs, run here on the phone's own parts; yata reloads its watch list itself.
		return p.Run("sh", "-c", `d=$(mktemp -d) && cp -R "$1" "$d/parts" && cp "$2/Caddyfile.core" "$d/" &&
YATA_SELF=1 sh "$2/setup" "$d" "$3" "$(cat "$2/domain")" >/dev/null; s=$?; rm -rf "$d"; exit $s`, "sh", p.Dir, p.Etc, verb)
	}
	return errors.New("a part can be turned on, off or restarted")
}

func (p *Parts) job(name string) string { return filepath.Join(p.Jobs, "com.sryo.yapa."+name+".plist") }

func readPart(path string) (map[string]string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	kv := map[string]string{}
	for _, l := range strings.Split(string(b), "\n") {
		if k, v, ok := strings.Cut(l, "="); ok {
			kv[k] = v
		}
	}
	return kv, nil
}

func dirSize(dir string) int64 {
	var n int64
	filepath.WalkDir(dir, func(_ string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			if i, err := d.Info(); err == nil {
				n += i.Size()
			}
		}
		return nil
	})
	return n
}
