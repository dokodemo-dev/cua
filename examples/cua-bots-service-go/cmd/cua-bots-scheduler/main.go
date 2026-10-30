// SPDX-License-Identifier: FSL-1.1-MIT

// Command cua-bots-scheduler runs scheduled Bot prompts outside the GUI. It is
// the Go counterpart of the Swift scheduler: one lease holder claims a slot,
// hands it to --exec-command, and records the outcome; an unknown outcome is
// never resent automatically.
package main

import (
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/domain"
	"github.com/dokodemo-dev/cua/examples/cua-bots-service-go/internal/store"
)

func main() {
	var (
		stateDir    = flag.String("state", "", "state directory (required)")
		owner       = flag.String("owner", "cua-bots-scheduler", "lease owner name")
		interval    = flag.Duration("interval", time.Second, "how often to look for due slots")
		lease       = flag.Duration("lease", 30*time.Second, "lease duration")
		claimTTL    = flag.Duration("claim-timeout", 120*time.Second, "how long a claim may stay unconfirmed")
		limit       = flag.Int("limit", 4, "slots per tick")
		execCmd     = flag.String("exec-command", "", "command that receives a delivery (CUA_BOTS_* env)")
		execTTL     = flag.Duration("exec-timeout", 10*time.Minute, "how long one delivery may run")
		once        = flag.Bool("once", false, "run one tick and exit")
		ticks       = flag.Int("ticks", 0, "stop after this many ticks (0: forever)")
		seedBot     = flag.String("seed-bot", "", "Bot id to seed a job for, then exit")
		seedEvery   = flag.Duration("seed-every", time.Hour, "cadence for --seed-bot")
		systemd     = flag.Bool("print-systemd-unit", false, "print a systemd unit and exit")
		unconfirmed = flag.Bool("unconfirmed", false, "list slots whose outcome is unknown, then exit")
		jobs        = flag.Bool("jobs", false, "list schedules, then exit")
		addJob      = flag.String("add-job", "", "register a schedule for this Bot, then exit")
		removeJob   = flag.String("remove-job", "", "remove a schedule, then exit")
		pauseJob    = flag.String("pause-job", "", "pause a schedule, then exit")
		resumeJob   = flag.String("resume-job", "", "resume a schedule, then exit")
		jobTitle    = flag.String("job-title", "", "with --add-job: display name (default: the Bot id)")
		jobPrompt   = flag.String("job-prompt", "", "with --add-job: the prompt each slot sends")
		jobEvery    = flag.Duration("job-every", time.Hour, "with --add-job: cadence (at least 1m)")
		jobDelay    = flag.Duration("job-delay", 0, "with --add-job: wait this long before the first slot")
		ack         = flag.String("ack", "", "acknowledge one slot (with --resend or --give-up)")
		resend      = flag.Bool("resend", false, "with --ack: run the slot once more")
		giveUp      = flag.Bool("give-up", false, "with --ack: never run the slot again")
	)
	flag.Parse()
	if *stateDir == "" {
		log.Fatal("--state is required")
	}
	dir, err := filepath.Abs(*stateDir)
	if err != nil {
		log.Fatal(err)
	}
	if *systemd {
		fmt.Print(systemdUnit(dir, *owner, *execCmd, *interval, *lease))
		return
	}
	schedule, err := store.OpenSchedule(dir)
	if err != nil {
		log.Fatal(err)
	}
	defer func() { _ = schedule.Close() }()

	admin := jobAdmin{
		list: *jobs, add: *addJob, remove: *removeJob, pause: *pauseJob,
		resume: *resumeJob, title: *jobTitle, prompt: *jobPrompt,
		every: *jobEvery, delay: *jobDelay,
	}
	if admin.wants() {
		err := schedule.Lock(*owner, func(s *domain.Scheduler) error {
			lines, err := admin.apply(s)
			if err != nil {
				return err
			}
			for _, line := range lines {
				fmt.Println(line)
			}
			return nil
		})
		if err != nil {
			log.Fatal(err)
		}
		return
	}

	if *unconfirmed || *ack != "" {
		err := schedule.Lock(*owner, func(s *domain.Scheduler) error {
			if *unconfirmed {
				for _, delivery := range s.Unresolved() {
					fmt.Printf("%s state=%s attempt=%d\n", delivery.Key, delivery.State, delivery.Attempts)
				}
				return nil
			}
			if *resend == *giveUp {
				return errors.New("--ack needs exactly one of --resend or --give-up")
			}
			return s.Acknowledge(*ack, *resend, time.Now())
		})
		if err != nil {
			log.Fatal(err)
		}
		return
	}

	if *seedBot != "" {
		err := schedule.Lock(*owner, func(s *domain.Scheduler) error {
			if len(s.Jobs) > 0 {
				return nil
			}
			_, err := s.AddJob(*seedBot, "Scheduled work", "Summarize what changed since the last run.",
				seedEvery.Seconds(), time.Now())
			return err
		})
		if err != nil {
			log.Fatal(err)
		}
		fmt.Printf("SEEDED %s every %s\n", *seedBot, *seedEvery)
		return
	}

	executor := &commandExecutor{command: *execCmd, timeout: *execTTL}
	if *execCmd == "" {
		fmt.Println("NO_EXEC_COMMAND (deliveries are recorded, not sent)")
	}
	tick := 0
	delivered, failed := 0, 0
	for {
		tick++
		now := time.Now()
		var claims []domain.Claim
		err := schedule.Lock(*owner, func(s *domain.Scheduler) error {
			s.ClaimTimeout = claimTTL.Seconds()
			if err := s.AcquireLease(now, *lease); err != nil {
				return err
			}
			s.ReclaimExpired(now)
			got, err := s.ClaimDue(now, *limit)
			claims = got
			return err
		})
		if errors.Is(err, domain.ErrLeaseHeld) {
			fmt.Printf("LEASE_BUSY owner=%s\n", *owner)
			if *once {
				break
			}
			time.Sleep(*interval)
			continue
		}
		if err != nil {
			log.Fatal(err)
		}
		if tick == 1 {
			for _, delivery := range unresolved(schedule, *owner) {
				fmt.Printf("UNCONFIRMED %s attempt=%d (not resent)\n", delivery.Key, delivery.Attempts)
			}
		}
		for _, claim := range claims {
			fmt.Printf("CLAIM key=%s attempt=%d bot=%s\n", claim.Key, claim.Attempt, claim.BotID)
			runErr := executor.run(claim)
			_ = schedule.Lock(*owner, func(s *domain.Scheduler) error {
				if runErr != nil {
					failed++
					return s.MarkFailed(claim.Key, time.Now())
				}
				delivered++
				return s.MarkDelivered(claim.Key, time.Now())
			})
			if runErr != nil {
				fmt.Printf("FAILED key=%s error=%v\n", claim.Key, runErr)
			} else {
				fmt.Printf("DELIVERED key=%s\n", claim.Key)
			}
		}
		if *once || (*ticks > 0 && tick >= *ticks) {
			break
		}
		time.Sleep(*interval)
	}
	fmt.Printf("DONE delivered=%d failed=%d\n", delivered, failed)
}

// commandExecutor runs one delivery as a shell command, with the claim in the
// environment so the callee can be idempotent on its own key.
type commandExecutor struct {
	command string
	timeout time.Duration
}

func (c *commandExecutor) run(claim domain.Claim) error {
	if c.command == "" {
		return nil
	}
	cmd := exec.Command("/bin/sh", "-c", c.command)
	cmd.Env = append(os.Environ(),
		"CUA_BOTS_DELIVERY_KEY="+claim.Key,
		"CUA_BOTS_BOT_ID="+claim.BotID,
		"CUA_BOTS_TITLE="+claim.Title,
		"CUA_BOTS_PROMPT="+claim.Prompt,
		fmt.Sprintf("CUA_BOTS_ATTEMPT=%d", claim.Attempt),
	)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return err
	case <-time.After(c.timeout):
		_ = cmd.Process.Kill()
		<-done
		return fmt.Errorf("timed out after %s", c.timeout)
	}
}

func unresolved(schedule *store.Schedule, owner string) []domain.Delivery {
	var out []domain.Delivery
	_ = schedule.Lock(owner, func(s *domain.Scheduler) error {
		out = s.Unresolved()
		return nil
	})
	return out
}

func systemdUnit(dir, owner, execCmd string, interval, lease time.Duration) string {
	args := []string{
		"--state", dir, "--owner", owner,
		"--interval", interval.String(), "--lease", lease.String(),
	}
	if execCmd != "" {
		args = append(args, "--exec-command", execCmd)
	}
	quoted := make([]string, 0, len(args))
	for _, a := range args {
		quoted = append(quoted, fmt.Sprintf("%q", a))
	}
	return fmt.Sprintf(`[Unit]
Description=Cua Bots scheduler
After=network-online.target cua-bots-service.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cua-bots-scheduler %s
Restart=always
RestartSec=5
StateDirectory=cua-bots
User=cua-bots
Group=cua-bots
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
`, strings.Join(quoted, " "))
}
