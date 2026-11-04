// yata watches yapa's services on the phone, reports them on /health, and lets the pad see and change the parts on /parts.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

func main() {
	addr := flag.String("addr", ":8077", "listen address for /health")
	config := flag.String("config", "/var/jb/etc/yapa/services.json", "services to watch")
	poll := flag.Duration("poll", 2*time.Second, "how often to check each service")
	logs := flag.String("logs", "/var/jb/var/log/yapa", "folder of yapa's logs, cut hourly so they can't fill the disk")
	etc := flag.String("etc", "/var/jb/etc/yapa", "yapa's settings on the phone: the parts, and the setup ./ya left")
	jobs := flag.String("jobs", "/var/jb/Library/LaunchDaemons", "launchd's plists")
	flag.Parse()
	// Rootless Dopamine keeps sh, launchctl and the rest under /var/jb; iOS itself has none of them.
	os.Setenv("PATH", "/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:"+os.Getenv("PATH"))

	go func() {
		for {
			if err := Tidy(*logs); err != nil {
				log.Printf("yata: tidying %s: %v", *logs, err)
			}
			time.Sleep(time.Hour)
		}
	}()

	read := func() ([]Service, time.Time, error) {
		var svcs []Service
		st, err := os.Stat(*config)
		if err != nil {
			return nil, time.Time{}, err
		}
		b, err := os.ReadFile(*config)
		if err == nil {
			err = json.Unmarshal(b, &svcs)
		}
		return svcs, st.ModTime(), err
	}
	svcs, seen, err := read()
	if err != nil {
		log.Fatalf("yata: can't read %s (%v); it lists the services to watch, like [{\"name\":\"web\",\"check\":\"tcp:127.0.0.1:80\"}]", *config, err)
	}

	m := NewMonitor(svcs, time.Now)
	go func() {
		for {
			// A part turned on or off from the pad rewrites the list; it's read again rather than restarting yata.
			if st, err := os.Stat(*config); err == nil && !st.ModTime().Equal(seen) {
				if s, t, err := read(); err == nil {
					m.Set(s)
					seen = t
				}
			}
			m.Poll()
			time.Sleep(*poll)
		}
	}()
	http.Handle("/health", m)
	p := &Parts{Dir: *etc + "/parts", Etc: *etc, Jobs: *jobs, Logs: *logs, Mon: m,
		Run: func(name string, args ...string) error {
			out, err := exec.Command(name, args...).CombinedOutput()
			if err != nil && len(out) > 0 {
				return fmt.Errorf("%s", strings.TrimSpace(string(out)))
			}
			return err
		}}
	http.Handle("/parts", p)
	http.Handle("/parts/", p)
	log.Fatal(http.ListenAndServe(*addr, nil))
}
