package tsmux

import (
	"bytes"
	"strings"
)

// KnownHosts returns known_hosts lines pinning the Tailscale SSH host keys of
// the device host names, as `tailscale ssh` does: the keys come from control,
// so a client can check them strictly instead of trusting on first use. host
// matches a device's MagicDNS name, short name or Tailscale IP, and the lines
// cover the name as typed so ssh finds them. Nil when nothing matches or the
// device advertises no keys.
func KnownHosts(statuses []Status, host string) []byte {
	host = strings.TrimSuffix(strings.ToLower(host), ".")
	for _, st := range statuses {
		for _, d := range st.Devices {
			if len(d.SSHHostKeys) == 0 || !deviceMatches(d, host) {
				continue
			}
			names := append([]string{host, d.Name}, d.IPs...)
			var buf bytes.Buffer
			for _, k := range d.SSHHostKeys {
				buf.WriteString(strings.Join(dedupe(names), ",") + " " + k + "\n")
			}
			return buf.Bytes()
		}
	}
	return nil
}

func deviceMatches(d Device, host string) bool {
	name := strings.ToLower(d.Name)
	if host == name || strings.EqualFold(host, d.Hostname) || strings.HasPrefix(name, host+".") {
		return true
	}
	for _, ip := range d.IPs {
		if host == ip {
			return true
		}
	}
	return false
}

func dedupe(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		if s != "" && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}
