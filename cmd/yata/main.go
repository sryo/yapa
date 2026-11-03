// yata watches yapa's services on the phone and reports them on /health.
package main

import (
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	addr := flag.String("addr", ":8077", "listen address for /health")
	config := flag.String("config", "/var/jb/etc/yapa/services.json", "services to watch")
	poll := flag.Duration("poll", 2*time.Second, "how often to check each service")
	flag.Parse()

	var svcs []Service
	b, err := os.ReadFile(*config)
	if err == nil {
		err = json.Unmarshal(b, &svcs)
	}
	if err != nil {
		log.Fatalf("yata: can't read %s (%v); it lists the services to watch, like [{\"name\":\"web\",\"check\":\"tcp:127.0.0.1:80\"}]", *config, err)
	}

	m := NewMonitor(svcs, time.Now)
	go func() {
		for {
			m.Poll()
			time.Sleep(*poll)
		}
	}()
	http.Handle("/health", m)
	log.Fatal(http.ListenAndServe(*addr, nil))
}
