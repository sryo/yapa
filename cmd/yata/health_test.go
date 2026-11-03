package main

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time      { return c.t }
func (c *fakeClock) add(d time.Duration) { c.t = c.t.Add(d) }
func listen(t *testing.T) net.Listener {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	return l
}

// R1: /health says whether each service is up or down, and since when.
func TestR1_ReflectsServiceUpAndDown(t *testing.T) {
	l := listen(t)
	clock := &fakeClock{time.Unix(1000, 0)}
	m := NewMonitor([]Service{{Name: "web", Check: "tcp:" + l.Addr().String()}}, clock.now)

	m.Poll()
	s := m.Snapshot()
	if s.Up != 1 || s.Total != 1 || !s.Services[0].Up || s.Services[0].Since != 1000 {
		t.Fatalf("after start: %+v", s)
	}

	l.Close()
	clock.add(5 * time.Second)
	m.Poll()
	s = m.Snapshot()
	if s.Up != 0 || s.Services[0].Up || s.Services[0].Since != 1005 {
		t.Fatalf("after stop: %+v", s)
	}
}

// R1: /health reports how long it took from yata starting to every service up.
func TestR1_RecordsGreenAfter(t *testing.T) {
	clock := &fakeClock{time.Unix(1000, 0)}
	l := listen(t)
	addr := l.Addr().String()
	l.Close()
	m := NewMonitor([]Service{{Name: "web", Check: "tcp:" + addr}}, clock.now)

	m.Poll()
	if g := m.Snapshot().GreenAfterS; g != nil {
		t.Fatalf("green before any service was up: %v", *g)
	}

	clock.add(3 * time.Second)
	l2, err := net.Listen("tcp", addr)
	if err != nil {
		t.Skip("port taken again before relisten:", err)
	}
	defer l2.Close()
	m.Poll()
	if g := m.Snapshot().GreenAfterS; g == nil || *g != 3 {
		t.Fatalf("green_after_s = %v, want 3", g)
	}
}

// R1: /health answers the home network only, never the internet.
func TestR1_AnswersHomeNetworkOnly(t *testing.T) {
	m := NewMonitor(nil, time.Now)
	for addr, want := range map[string]int{
		"192.168.1.5:4000": http.StatusOK,
		"10.0.0.2:4000":    http.StatusOK,
		"127.0.0.1:4000":   http.StatusOK,
		"8.8.8.8:4000":     http.StatusForbidden,
	} {
		r := httptest.NewRequest("GET", "/health", nil)
		r.RemoteAddr = addr
		w := httptest.NewRecorder()
		m.ServeHTTP(w, r)
		if w.Code != want {
			t.Errorf("%s: %d, want %d", addr, w.Code, want)
		}
		if want == http.StatusOK {
			var s Snapshot
			if err := json.Unmarshal(w.Body.Bytes(), &s); err != nil {
				t.Errorf("%s: body isn't a snapshot: %v", addr, err)
			}
		}
	}
}
