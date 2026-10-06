// Command iosmem starts N tsnet nodes in one process so its footprint can be
// compared against the ~50 MB iOS Network Extension cap. With TS_AUTHKEY set
// (ephemeral, reusable) the nodes join a tailnet and pull a netmap; without it
// they sit at NeedsLogin, which measures the fixed per-node cost.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"tailscale.com/tsnet"
)

func main() {
	n := flag.Int("n", 1, "nodes to start")
	settle := flag.Duration("settle", 30*time.Second, "wait before reporting")
	flag.Parse()

	dir, err := os.MkdirTemp("", "iosmem")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(dir)

	ctx := context.Background()
	for i := range *n {
		srv := &tsnet.Server{
			Dir:       filepath.Join(dir, fmt.Sprint(i)),
			Hostname:  fmt.Sprintf("iosmem-%d", i),
			AuthKey:   os.Getenv("TS_AUTHKEY"),
			Ephemeral: true,
			Logf:      func(string, ...any) {},
		}
		defer srv.Close()
		if os.Getenv("TS_AUTHKEY") != "" {
			if _, err := srv.Up(ctx); err != nil {
				panic(err)
			}
		} else if err := srv.Start(); err != nil {
			panic(err)
		}
	}

	time.Sleep(*settle)
	runtime.GC()
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	fmt.Printf("pid=%d nodes=%d heap_inuse=%dMB sys=%dMB goroutines=%d\n",
		os.Getpid(), *n, m.HeapInuse>>20, m.Sys>>20, runtime.NumGoroutine())
	os.Stdout.Sync()
	time.Sleep(time.Hour)
}
