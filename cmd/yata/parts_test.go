package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A phone's yapa folders in a temp dir: two parts (hello needs app), Caddy's and cloudflared's jobs, and every
// command yata would run logged instead of run.
func phone(t *testing.T) (*Parts, *[]string) {
	t.Helper()
	d := t.TempDir()
	for name, part := range map[string]string{"hello": "kind=service\naddress=api\nneeds=app\n", "app": "kind=service\n", "blog": "kind=site\n"} {
		os.MkdirAll(filepath.Join(d, "etc/parts", name), 0o755)
		os.WriteFile(filepath.Join(d, "etc/parts", name, "part"), []byte("name="+name+"\n"+part), 0o644)
	}
	os.MkdirAll(filepath.Join(d, "jobs"), 0o755)
	for _, n := range []string{"caddy", "cloudflared", "hello", "app"} {
		os.WriteFile(filepath.Join(d, "jobs", "com.sryo.yapa."+n+".plist"), nil, 0o644)
	}
	var ran []string
	m := NewMonitor([]Service{{Name: "caddy", Check: "tcp:127.0.0.1:1"}, {Name: "hello", Check: "tcp:127.0.0.1:1"}}, time.Now)
	p := &Parts{Dir: filepath.Join(d, "etc/parts"), Etc: filepath.Join(d, "etc"), Jobs: filepath.Join(d, "jobs"), Logs: filepath.Join(d, "logs"), Mon: m,
		Run: func(name string, args ...string) error { ran = append(ran, name+" "+strings.Join(args, " ")); return nil }}
	return p, &ran
}

func call(p *Parts, method, path, from string) (int, map[string]any) {
	r := httptest.NewRequest(method, path, nil)
	r.RemoteAddr = from
	w := httptest.NewRecorder()
	p.ServeHTTP(w, r)
	var out map[string]any
	json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, out
}

// R1: /parts lists the core's jobs and every part, each on or off, with its address, and the disk's free space.
func TestR1_PartsListsWhatRuns(t *testing.T) {
	p, _ := phone(t)
	os.WriteFile(filepath.Join(p.Dir, "app", "down"), nil, 0o644)
	l := p.List()
	var names []string
	for _, x := range l.Parts {
		names = append(names, x.Name)
	}
	if strings.Join(names, " ") != "yata caddy cloudflared app blog hello" {
		t.Fatalf("parts: %v", names)
	}
	for _, x := range l.Parts {
		if x.Name == "app" && x.On || x.Name == "hello" && (!x.On || x.Address != "api" || !x.Watched) || x.Name == "blog" && x.Watched {
			t.Errorf("%+v", x)
		}
	}
	if l.DiskFreeMB <= 0 {
		t.Errorf("disk free: %d", l.DiskFreeMB)
	}
}

// R1: turning a part off writes its down file and runs ./ya's setup on the phone's parts; on takes it away again,
// but not while a part it needs is off.
func TestR1_OnAndOffRegenerate(t *testing.T) {
	p, ran := phone(t)
	if code, _ := call(p, "POST", "/parts/app/off", "127.0.0.1:5000"); code != 200 {
		t.Fatalf("off: %d", code)
	}
	if _, err := os.Stat(filepath.Join(p.Dir, "app", "down")); err != nil {
		t.Fatal("off left no down file")
	}
	if len(*ran) != 1 || !strings.Contains((*ran)[0], "setup") || !strings.HasSuffix((*ran)[0], " off") {
		t.Fatalf("ran %q", *ran)
	}
	if code, out := call(p, "POST", "/parts/hello/off", "127.0.0.1:5000"); code != 200 {
		t.Fatalf("hello off: %d %v", code, out)
	}
	if code, out := call(p, "POST", "/parts/hello/on", "127.0.0.1:5000"); code != 409 || !strings.Contains(out["error"].(string), "needs app") {
		t.Fatalf("hello on with app off: %d %v", code, out)
	}
	call(p, "POST", "/parts/app/on", "127.0.0.1:5000")
	if _, err := os.Stat(filepath.Join(p.Dir, "app", "down")); err == nil {
		t.Fatal("on left the down file")
	}
}

// R1: restart reloads the part's launchd job; a site's is Caddy's; yata never restarts itself, and the core
// never goes off.
func TestR1_Restart(t *testing.T) {
	p, ran := phone(t)
	call(p, "POST", "/parts/hello/restart", "127.0.0.1:5000")
	call(p, "POST", "/parts/blog/restart", "127.0.0.1:5000")
	if len(*ran) != 4 || !strings.HasSuffix((*ran)[1], "com.sryo.yapa.hello.plist") || !strings.HasSuffix((*ran)[3], "com.sryo.yapa.caddy.plist") {
		t.Fatalf("ran %q", *ran)
	}
	for _, path := range []string{"/parts/yata/restart", "/parts/caddy/off", "/parts/nope/on"} {
		if code, _ := call(p, "POST", path, "127.0.0.1:5000"); code != 409 {
			t.Errorf("%s: %d, want 409", path, code)
		}
	}
}

// R1: the home network can look, but only the phone itself (the pad) can change anything, and the internet can't
// even look.
func TestR1_OnlyThePhoneChanges(t *testing.T) {
	p, ran := phone(t)
	if code, _ := call(p, "GET", "/parts", "192.168.1.5:4000"); code != http.StatusOK {
		t.Errorf("home network can't look: %d", code)
	}
	if code, _ := call(p, "POST", "/parts/app/off", "192.168.1.5:4000"); code != http.StatusForbidden {
		t.Errorf("home network changed a part: %d", code)
	}
	if code, _ := call(p, "GET", "/parts", "8.8.8.8:4000"); code != http.StatusForbidden {
		t.Errorf("the internet looked: %d", code)
	}
	if len(*ran) != 0 {
		t.Fatalf("ran %q", *ran)
	}
}

// R1: a watch list rewritten while yata runs is taken as is, keeping what's known of services that stay.
func TestR1_SetKeepsKnownStates(t *testing.T) {
	clock := &fakeClock{time.Unix(1000, 0)}
	m := NewMonitor([]Service{{Name: "a", Check: "tcp:127.0.0.1:1"}}, clock.now)
	m.Poll()
	clock.add(time.Minute)
	m.Set([]Service{{Name: "a", Check: "tcp:127.0.0.1:1"}, {Name: "b", Check: "tcp:127.0.0.1:1"}})
	s := m.Snapshot()
	if s.Total != 2 || s.Services[0].Since != 1000 || s.Services[1].Since != 1060 {
		t.Fatalf("%+v", s)
	}
}
