package tsmux

import (
	"strings"
	"testing"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/types/key"
)

func TestTailnetLockOf(t *testing.T) {
	nk := key.NewNode().Public()
	tlpub := key.NewNLPrivate().Public()

	tests := []struct {
		name       string
		in         *ipnstate.TailnetLockStatus
		wantNil    bool
		wantLocked bool
		wantNode   bool
		wantPub    bool
	}{
		{name: "nil", in: nil, wantNil: true},
		{name: "disabled", in: &ipnstate.TailnetLockStatus{PublicKey: tlpub, NodeKey: &nk}, wantNode: true, wantPub: true},
		{name: "signed", in: &ipnstate.TailnetLockStatus{Enabled: true, PublicKey: tlpub, NodeKey: &nk, NodeKeySigned: true}, wantNode: true, wantPub: true},
		{name: "locked out", in: &ipnstate.TailnetLockStatus{Enabled: true, PublicKey: tlpub, NodeKey: &nk}, wantLocked: true, wantNode: true, wantPub: true},
		// Not logged in yet: no node key, so nothing an admin could sign.
		{name: "enabled before login", in: &ipnstate.TailnetLockStatus{Enabled: true, PublicKey: tlpub}, wantPub: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tailnetLockOf(tt.in)
			if tt.wantNil {
				if got != nil {
					t.Fatalf("got %+v, want nil", got)
				}
				return
			}
			if got.LockedOut != tt.wantLocked {
				t.Errorf("LockedOut = %v, want %v", got.LockedOut, tt.wantLocked)
			}
			if (got.NodeKey != "") != tt.wantNode || (got.NodeKey != "" && !strings.HasPrefix(got.NodeKey, "nodekey:")) {
				t.Errorf("NodeKey = %q", got.NodeKey)
			}
			if (got.PublicKey != "") != tt.wantPub || (got.PublicKey != "" && !strings.HasPrefix(got.PublicKey, "tlpub:")) {
				t.Errorf("PublicKey = %q", got.PublicKey)
			}
			wantCmd := ""
			if tt.wantLocked {
				wantCmd = "tailscale lock sign " + got.NodeKey + " " + got.PublicKey
			}
			if got.SignCommand != wantCmd {
				t.Errorf("SignCommand = %q, want %q", got.SignCommand, wantCmd)
			}
		})
	}
}
