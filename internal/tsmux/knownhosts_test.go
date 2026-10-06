package tsmux

import (
	"strings"
	"testing"
)

func TestKnownHosts(t *testing.T) {
	sts := []Status{
		{Devices: []Device{{Name: "nokeys.tail1.ts.net", Hostname: "nokeys"}}},
		{Devices: []Device{{
			Name: "box.tail2.ts.net", Hostname: "box", IPs: []string{"100.64.0.9"},
			SSHHostKeys: []string{"ssh-ed25519 AAAAkey1", "ecdsa-sha2-nistp256 AAAAkey2"},
		}}},
	}
	for _, host := range []string{"box", "BOX", "box.tail2.ts.net", "box.tail2.ts.net.", "100.64.0.9"} {
		got := string(KnownHosts(sts, host))
		lines := strings.Split(strings.TrimSpace(got), "\n")
		if len(lines) != 2 || !strings.HasSuffix(lines[0], " ssh-ed25519 AAAAkey1") {
			t.Fatalf("%s: got %q", host, got)
		}
		for _, want := range []string{"box.tail2.ts.net", "100.64.0.9"} {
			if !strings.Contains(lines[0], want) {
				t.Errorf("%s: line %q lacks %s", host, lines[0], want)
			}
		}
	}
	for _, host := range []string{"nokeys", "bo", "other"} {
		if got := KnownHosts(sts, host); got != nil {
			t.Errorf("%s: want nil, got %q", host, got)
		}
	}
}
