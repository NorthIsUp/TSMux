package main

import (
	"context"
	"strings"
	"testing"
)

// Anything that would change a node is refused before any tailnet is touched.
func TestTailscaleRefusesWrites(t *testing.T) {
	for _, args := range [][]string{
		{"up"}, {"logout"}, {"switch", "x"}, {"set", "--exit-node=x"},
		{"exit-node", "connect"}, {"-p", "work", "down"}, {"--socket=/tmp/x", "up"},
	} {
		err := runTailscale(context.Background(), args)
		if err == nil || !strings.Contains(err.Error(), "isn't available through tsmux") {
			t.Errorf("%v: err = %v, want a refusal", args, err)
		}
	}
}
