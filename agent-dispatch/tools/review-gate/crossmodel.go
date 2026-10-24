package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// Last-resort sanity backstop only: dispatch-worker owns the real review gate via
// DISPATCH_MIN_REVIEW_BYTES plus its evidence gate. Keep this low, but above the
// observed provenance case: a 392B no-findings sign-off must never pass.
const shortReviewBodyByteThreshold = 400

func rcMeaning(rc int) string {
	switch rc {
	case 0:
		return "ok"
	case 2:
		return "dispatch-worker usage error or dirty-tree refusal - fix the invocation/tree; NOT a build failure"
	case 3:
		return "runtime binary not on PATH, or no isolated review worktree could be allocated - fix the environment; NOT a build failure"
	case 4:
		return "require-dep gate (n/a in review mode)"
	case 5:
		return "codex auth rejected - run codex login; NOT a build failure"
	case 6:
		return "codex rate/usage limit - wait & re-dispatch; NOT a build failure"
	case 7:
		return "agy not authenticated - run `agy` to sign in; NOT a build failure"
	case 8:
		return "empty/short review - do NOT retry; fall back to a LOCAL (Claude) reviewer"
	case 9:
		return "agy model not offered: fix lib/agy-models.sh or pass a model, then re-run; NOT a build failure"
	case 10:
		return "source repo changed during the review window (reviewer or a concurrent session) - inspect the named changes and restore them before committing; the review stands only if every change is known concurrent work; NOT a build failure"
	case 124:
		return "blocked (timed out; for agy --review, after one internal retry) - re-run an agy lens once on codex if codex egress is approved, else use a Claude reviewer; a primary codex lens goes to Claude"
	default:
		return fmt.Sprintf("dispatch-worker rc %d", rc)
	}
}

func isInfrastructureRC(rc int) bool {
	switch rc {
	// rc 3 is dispatch-worker's "the review could not physically run" — the runtime
	// binary is not on PATH, or no isolated review worktree could be allocated. Passing
	// it through matters: without it, reviewDispositionRC would remap a short/empty body
	// on rc 3 to disposition 8 ("empty review - do NOT retry"), a wrong diagnosis that
	// tells the operator to fall back to a local reviewer when the real fix is to install
	// the binary or free up a worktree dir.
	// rc 9 is a model configuration refusal: fix the pin/override and re-run.
	// It must preserve the infrastructure disposition even with an empty review.
	case 2, 3, 4, 5, 6, 7, 9, 10, 124:
		return true
	default:
		return false
	}
}

func reviewDispositionRC(rc, bodyBytes int) int {
	if bodyBytes >= shortReviewBodyByteThreshold || isInfrastructureRC(rc) || rc == 8 {
		return rc
	}
	if rc == 0 || rc == 1 {
		return 8
	}
	return rc
}

// Mirror dispatch-worker's label-shaped severity and file:line evidence alternatives.
// Requirements row verdicts are checked separately below.
var reviewEvidence = regexp.MustCompile(`(?m)(^|\|)[[:blank:]]*([-*][[:blank:]]+)?(\*\*|\[)?(Blocker|Major|Minor|Nit|Critical|High|Medium|Low|Info)[[:blank:]]*(:|\]|\*\*|\||\))|(^|[^[:alnum:]_./-])[[:alnum:]_.-]+/[[:alnum:]_./-]*[[:alnum:]_-]:[0-9]+|(^|[^[:alnum:]_./-])[[:alnum:]_-]+\.[[:alpha:]][[:alnum:]]*:[0-9]+`)
var reviewRowVerdict = regexp.MustCompile(`(?m)(^|[^[:alnum:]_])(R[0-9]+\.[0-9]+|[EM][0-9]+)([^[:alnum:]_]|$).*(^|[^[:alnum:]_])(ALIGN|OBJECT|ABSTAIN)([^[:alnum:]_]|$)`)

func declaredBriefRepoRoot(brief string) (string, bool) {
	b, err := os.ReadFile(brief)
	if err != nil {
		return "", false
	}
	for _, line := range strings.Split(string(b), "\n") {
		if root, ok := strings.CutPrefix(line, "repo root: "); ok {
			root = strings.TrimSpace(root)
			if root != "" {
				return root, true
			}
			return "", false
		}
	}
	return "", false
}

func cmdCrossModel(args []string) int {
	fs := flag.NewFlagSet("cross-model", flag.ContinueOnError)
	runtime := fs.String("runtime", "agy", "agy|codex (default agy - the capability-confirmed reviewer)")
	model := fs.String("model", "", "model override passed to dispatch-worker")
	timeout := fs.String("timeout", "14m", "per-brief external timeout")
	workdir := fs.String("workdir", "", "checkout directory dispatch-worker reviews (default: each brief's declared repo root, else current working directory)")
	var briefs repeated
	fs.Var(&briefs, "brief", "brief file (repeatable; runs serialized)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	explicitWorkdir := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "workdir" {
			explicitWorkdir = true
		}
	})
	reviewWorkdir := *workdir
	if explicitWorkdir {
		if abs, err := filepath.Abs(reviewWorkdir); err == nil {
			reviewWorkdir = abs
		}
	}
	if *runtime != "agy" && *runtime != "codex" {
		fmt.Fprintln(os.Stderr, "cross-model: --runtime must be agy|codex")
		return 1
	}
	if len(briefs) == 0 {
		fmt.Fprintln(os.Stderr, "cross-model: at least one --brief required")
		return 1
	}
	cwd, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(os.Stderr, "cross-model: cannot resolve current working directory:", err)
		return 2
	}
	worst := 0
	sourceRepoDrift := false
	var summary strings.Builder
	summary.WriteString("# cross-model run summary\n\n")
	for i, b := range briefs { // serialized - never concurrent (agy wedge risk)
		if sourceRepoDrift {
			fmt.Fprintf(&summary, "- brief %d (%s): rc - (not dispatched: stopped after rc 10)\n", i+1, b)
			continue
		}
		briefWorkdir := reviewWorkdir
		if !explicitWorkdir {
			briefWorkdir = cwd
			if root, ok := declaredBriefRepoRoot(b); ok {
				briefWorkdir = root
			}
		}
		cmd := exec.Command("dispatch-worker", "--runtime", *runtime, "--review", "--brief", b, "--timeout", *timeout, "--workdir", briefWorkdir)
		if *model != "" {
			cmd.Args = append(cmd.Args, "--model", *model)
		}
		var stdout, stderr strings.Builder
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
		err := cmd.Run()
		rc := 0
		if ee, ok := err.(*exec.ExitError); ok {
			rc = ee.ExitCode()
		} else if err != nil {
			if errors.Is(err, exec.ErrNotFound) {
				fmt.Fprintln(os.Stderr, "cross-model: dispatch-worker not found on PATH (install the agent-dispatch plugin)")
			} else {
				fmt.Fprintln(os.Stderr, err)
			}
			rc = 2
		}
		fmt.Fprint(os.Stderr, stderr.String())
		reviewBody := stdout.String()
		bodyBytes := len(reviewBody)
		dispositionRC := reviewDispositionRC(rc, bodyBytes)
		if *runtime == "codex" && (rc == 0 || rc == 1) {
			if reviewRowVerdict.MatchString(reviewBody) {
				dispositionRC = rc
			} else if bodyBytes > 0 && os.Getenv("DISPATCH_REVIEW_REQUIRE_EVIDENCE") != "0" && !reviewEvidence.MatchString(reviewBody) {
				dispositionRC = 8
			}
		}
		state := ""
		for _, line := range strings.Split(stderr.String(), "\n") {
			if value, ok := strings.CutPrefix(line, "DISPATCH_REVIEW_STATE="); ok {
				state, _, _ = strings.Cut(value, " ")
			}
		}
		fmt.Fprintf(&summary, "- brief %d (%s): rc %d - %s (body_bytes=%d) runtime=%s", i+1, b, dispositionRC, rcMeaning(dispositionRC), bodyBytes, *runtime)
		if state != "" {
			fmt.Fprintf(&summary, " state=%s", state)
		}
		summary.WriteByte('\n')
		if dispositionRC == 10 {
			sourceRepoDrift = true
		}
		// The review itself (dispatch-worker's stdout) is the deliverable:
		fmt.Fprintf(os.Stdout, "===== review: brief %d (%s) rc=%d =====\n%s\n", i+1, b, dispositionRC, reviewBody)
		if dispositionRC > worst {
			worst = dispositionRC
		}
		// NO retry on rc 8 (or any rc): dispatch-worker mandates fall-back-to-local, not retry.
	}
	fmt.Fprint(os.Stdout, summary.String())
	if sourceRepoDrift {
		return 10
	}
	if worst != 0 {
		return worst
	}
	return 0
}
