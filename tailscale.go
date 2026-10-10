package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"slices"
	"strings"

	"github.com/spf13/cobra"
	"tailscale.com/cmd/tailscale/cli"
)

// tailscaleReadOnly is what `tsmux tailscale` lets through: commands that read
// a node or reach through it, with the subcommands allowed where some of a
// command's would change it. Sign-in, prefs and profile switches belong to the
// TSMux app or `tsmux profile`; the real CLI would quietly fight them.
var tailscaleReadOnly = map[string][]string{
	"status": nil, "ip": nil, "ping": nil, "netcheck": nil, "whois": nil,
	"version": nil, "dns": nil, "nc": nil, "metrics": nil, "licenses": nil,
	"exit-node": {"list", "suggest"},
	"help":      nil, "-h": nil, "--help": nil, "-help": nil, "-V": nil, "--version": nil,
}

func cmdTailscale() *cobra.Command {
	return &cobra.Command{
		Use:   "tailscale [-p profile] <command> [args...]",
		Short: "Run the tailscale CLI against a tailnet (the first one unless -p or $TSMUX_PROFILE says)",
		Long: "Runs the real tailscale CLI against one of TSMux's tailnets. Only read-only\n" +
			"commands are allowed: " + strings.Join(tailscaleAllowed(), ", ") + ".\n" +
			"Linked or copied as `tailscale`, tsmux behaves as `tsmux tailscale`.",
		DisableFlagParsing: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			return runTailscale(cmd.Context(), args)
		},
	}
}

func tailscaleAllowed() []string {
	var out []string
	for c, subs := range tailscaleReadOnly {
		if strings.HasPrefix(c, "-") || c == "help" {
			continue
		}
		if subs != nil {
			c += " " + strings.Join(subs, "|")
		}
		out = append(out, c)
	}
	slices.Sort(out)
	return out
}

func runTailscale(ctx context.Context, args []string) error {
	profile := os.Getenv("TSMUX_PROFILE")
	for len(args) > 0 {
		if v, ok := strings.CutPrefix(args[0], "--profile="); ok {
			profile, args = v, args[1:]
		} else if (args[0] == "-p" || args[0] == "--profile") && len(args) > 1 {
			profile, args = args[1], args[2:]
		} else {
			break
		}
	}
	if len(args) > 0 {
		subs, ok := tailscaleReadOnly[args[0]]
		if ok && subs != nil && len(args) > 1 {
			ok = slices.Contains(subs, args[1])
		}
		if !ok {
			return fmt.Errorf("`tailscale %s` isn't available through tsmux: sign-in, prefs and profiles are the TSMux app's. Allowed: %s",
				strings.Join(args[:min(len(args), 2)], " "), strings.Join(tailscaleAllowed(), ", "))
		}
	}

	cfg, err := load()
	if err != nil {
		return err
	}
	ps := cfg.Ordered()
	if len(ps) == 0 {
		return errors.New("no tailnets yet; add one in the TSMux app or with `tsmux profile add`")
	}
	if profile == "" {
		profile = ps[0].Name
	} else if cfg.Profiles[profile] == nil {
		var names []string
		for _, p := range ps {
			names = append(names, p.Name)
		}
		return fmt.Errorf("no profile %q (have %s)", profile, strings.Join(names, ", "))
	}
	sock, stop, err := cfg.TailscaleSocket(profile)
	if err != nil {
		return err
	}
	defer stop()
	return cli.RunWithContext(ctx, append([]string{"--socket=" + sock}, args...))
}
