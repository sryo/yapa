package main

import (
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// Service is one thing yata watches. Check is "tcp:host:port".
type Service struct {
	Name  string `json:"name"`
	Check string `json:"check"`
}

type State struct {
	Name  string `json:"name"`
	Up    bool   `json:"up"`
	Since int64  `json:"since"`
}

type Snapshot struct {
	Up          int      `json:"up"`
	Total       int      `json:"total"`
	GreenAfterS *float64 `json:"green_after_s"`
	Services    []State  `json:"services"`
}

type Monitor struct {
	svcs    []Service
	now     func() time.Time
	started time.Time

	mu     sync.Mutex
	states []State
	polled bool
	green  *float64
}

func NewMonitor(svcs []Service, now func() time.Time) *Monitor {
	m := &Monitor{svcs: svcs, now: now, started: now(), states: make([]State, len(svcs))}
	for i, s := range svcs {
		m.states[i].Name = s.Name
	}
	return m
}

// Set replaces the services watched, keeping what's known of the ones that stay.
func (m *Monitor) Set(svcs []Service) {
	m.mu.Lock()
	defer m.mu.Unlock()
	old := map[string]State{}
	for _, s := range m.states {
		old[s.Name] = s
	}
	m.svcs, m.states = svcs, make([]State, len(svcs))
	for i, s := range svcs {
		if st, ok := old[s.Name]; ok {
			m.states[i] = st
		} else {
			m.states[i] = State{Name: s.Name, Since: m.now().Unix()}
		}
	}
}

func (m *Monitor) Poll() {
	m.mu.Lock()
	svcs := m.svcs
	m.mu.Unlock()
	up := make([]bool, len(svcs))
	for i, s := range svcs {
		up[i] = check(s.Check)
	}
	t := m.now()
	m.mu.Lock()
	defer m.mu.Unlock()
	if len(m.states) != len(up) {
		return // the list changed while checking; the next poll catches up
	}
	all := true
	for i := range m.states {
		if !m.polled || m.states[i].Up != up[i] {
			m.states[i].Up, m.states[i].Since = up[i], t.Unix()
		}
		all = all && up[i]
	}
	m.polled = true
	if all && m.green == nil {
		g := t.Sub(m.started).Seconds()
		m.green = &g
	}
}

func (m *Monitor) Snapshot() Snapshot {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := Snapshot{Total: len(m.states), GreenAfterS: m.green, Services: append([]State(nil), m.states...)}
	for _, st := range m.states {
		if st.Up {
			s.Up++
		}
	}
	return s
}

// ServeHTTP answers only loopback and private addresses: the tunnel never exposes /health.
func (m *Monitor) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	ip := net.ParseIP(host)
	if ip == nil || !(ip.IsLoopback() || ip.IsPrivate()) {
		http.Error(w, "yata answers the home network only", http.StatusForbidden)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(m.Snapshot())
}

func check(spec string) bool {
	addr, ok := strings.CutPrefix(spec, "tcp:")
	if !ok {
		return false
	}
	c, err := net.DialTimeout("tcp", addr, time.Second)
	if err != nil {
		return false
	}
	c.Close()
	return true
}
