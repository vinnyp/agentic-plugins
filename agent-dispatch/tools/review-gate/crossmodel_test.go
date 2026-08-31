package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

func TestCrossModelBackstopDoesNotExceedDispatchWorkerDefault(t *testing.T) {
	// dispatch-worker ships in agent-dispatch@agentic-plugins, not this repo, so the
	// subject of this cross-repo invariant is the dispatch-worker that crossmodel.go
	// actually execs: the one on PATH. When it is absent the invariant is NOT checked —
	// say so loudly rather than reporting a green that evaluated nothing.
	dispatchWorker, err := exec.LookPath("dispatch-worker")
	if err != nil {
		t.Skipf("NOT EVALUATED: dispatch-worker is not on PATH (%v) — the Go backstop (%d) was "+
			"never compared against DISPATCH_MIN_REVIEW_BYTES. Install agent-dispatch@agentic-plugins.",
			err, shortReviewBodyByteThreshold)
	}
	b, err := os.ReadFile(dispatchWorker)
	if err != nil {
		t.Fatalf("read dispatch-worker at %s: %v", dispatchWorker, err)
	}
	re := regexp.MustCompile(`MIN_REVIEW_BYTES="\$\{DISPATCH_MIN_REVIEW_BYTES:-([0-9]+)\}"`)
	m := re.FindSubmatch(b)
	if m == nil {
		t.Fatalf("could not read DISPATCH_MIN_REVIEW_BYTES default from %s", dispatchWorker)
	}
	bashDefault, err := strconv.Atoi(string(m[1]))
	if err != nil {
		t.Fatal(err)
	}
	if shortReviewBodyByteThreshold > bashDefault {
		t.Fatalf("Go sanity backstop %d exceeds dispatch-worker default %d", shortReviewBodyByteThreshold, bashDefault)
	}
}

// stubDispatchWorker writes a fake dispatch-worker that echoes a review to stdout,
// the REVIEW_OUTFILE line to stderr, appends to a call-log, and exits rc.
func stubDispatchWorker(t *testing.T, reviewBody string, rc int) (callLog string) {
	t.Helper()
	dir := t.TempDir()
	callLog = filepath.Join(dir, "calls.log")
	script := "#!/usr/bin/env bash\n" +
		"echo \"$@\" >> " + callLog + "\n" +
		"echo '" + reviewBody + "'\n" +
		"echo 'REVIEW_OUTFILE=/tmp/x (rc=" + strconv.Itoa(rc) + ")' >&2\n" +
		"exit " + strconv.Itoa(rc) + "\n"
	p := filepath.Join(dir, "dispatch-worker")
	if err := os.WriteFile(p, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return callLog
}

func stubDispatchWorkerScript(t *testing.T, script string) (callLog string) {
	t.Helper()
	dir := t.TempDir()
	callLog = filepath.Join(dir, "calls.log")
	p := filepath.Join(dir, "dispatch-worker")
	if err := os.WriteFile(p, []byte(strings.ReplaceAll(script, "CALLLOG", callLog)), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return callLog
}

func writeBrief(t *testing.T, name string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, []byte("BRIEF BODY long enough to be a real review brief for the stub.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func writeBriefCleanPath(t *testing.T, name string) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "reviewgate-brief-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("BRIEF BODY long enough to be a real review brief for the stub.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestCrossModelCapturesStdoutReview(t *testing.T) {
	stubDispatchWorker(t, "AGY REVIEW FINDINGS HERE "+strings.Repeat("details ", 300), 0)
	b := writeBrief(t, "b1.md")
	rc, out := runCapt(t, "cross-model", "--runtime", "agy", "--brief", b, "--timeout", "1m")
	if rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	if !strings.Contains(out, "AGY REVIEW FINDINGS HERE") {
		t.Fatalf("did not capture stdout review: %q", out)
	}
}

func TestCrossModelRc8NoRetryFallback(t *testing.T) {
	callLog := stubDispatchWorker(t, "short", 8)
	b := writeBrief(t, "b1.md")
	rc, out := runCapt(t, "cross-model", "--runtime", "agy", "--brief", b, "--timeout", "1m")
	if rc == 0 {
		t.Fatalf("rc8 should surface non-zero")
	}
	if !strings.Contains(strings.ToLower(out), "fall back") && !strings.Contains(strings.ToLower(out), "local reviewer") {
		t.Fatalf("rc8 must surface the fall-back-to-local guidance: %q", out)
	}
	calls := readFile(t, callLog)
	if strings.Count(calls, "\n") != 1 {
		t.Fatalf("rc8 must NOT retry; got %d dispatch calls", strings.Count(calls, "\n"))
	}
}

func TestCrossModelRc1EmptyBodyFallbackDisposition(t *testing.T) {
	stubDispatchWorkerScript(t, `#!/usr/bin/env bash
echo "$@" >> "CALLLOG"
echo 'REVIEW_OUTFILE=/tmp/x (rc=1)' >&2
exit 1
`)
	b := writeBriefCleanPath(t, "plain.md")
	rc, out := runCapt(t, "cross-model", "--runtime", "agy", "--brief", b)
	if rc != 8 {
		t.Fatalf("rc=%d want 8", rc)
	}
	if !strings.Contains(out, "rc 8 - empty/short review") {
		t.Fatalf("empty rc1 body must use fallback disposition: %q", out)
	}
	if !strings.Contains(out, "body_bytes=0") {
		t.Fatalf("summary must report measured length 0: %q", out)
	}
}

func TestCrossModelRc0EmptyBodyFallbackDisposition(t *testing.T) {
	stubDispatchWorkerScript(t, `#!/usr/bin/env bash
echo "$@" >> "CALLLOG"
echo 'REVIEW_OUTFILE=/tmp/x (rc=0)' >&2
exit 0
`)
	b := writeBriefCleanPath(t, "plain.md")
	rc, out := runCapt(t, "cross-model", "--runtime", "agy", "--brief", b)
	if rc != 8 {
		t.Fatalf("rc=%d want 8", rc)
	}
	if !strings.Contains(out, "rc 8 - empty/short review") || !strings.Contains(out, "body_bytes=0") {
		t.Fatalf("empty rc0 body must use fallback disposition and report length: %q", out)
	}
}

func TestReviewDispositionShortBodyPreservesUnknownAndSignalRCs(t *testing.T) {
	for _, tc := range []struct {
		name string
		rc   int
		want int
	}{
		{name: "successful_rc0", rc: 0, want: 8},
		{name: "successful_rc1", rc: 1, want: 8},
		{name: "unknown_rc9", rc: 9, want: 9},
		{name: "signal_rc137", rc: 137, want: 137},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := reviewDispositionRC(tc.rc, shortReviewBodyByteThreshold-1)
			if got != tc.want {
				t.Fatalf("reviewDispositionRC(%d, short body)=%d want %d", tc.rc, got, tc.want)
			}
		})
	}
}

// rc 3 is dispatch-worker's "the review could not physically run" (runtime binary
// not on PATH, or no isolated review worktree could be allocated). It must pass
// through as 3 with its own diagnosis, NOT be remapped to disposition 8
// ("empty/short review - do NOT retry"): a missing binary is not a short review, and
// "fall back to a local reviewer" is the wrong instruction when the fix is to install
// the binary or free a worktree dir. An empty body on rc 3 is expected — a review that
// could not run produces nothing.
func TestCrossModelRc3InfraEmptyBodyPassesThrough(t *testing.T) {
	stubDispatchWorkerScript(t, `#!/usr/bin/env bash
echo "$@" >> "CALLLOG"
echo 'dispatch-worker: agy not on PATH' >&2
exit 3
`)
	b := writeBriefCleanPath(t, "plain.md")
	rc, out := runCapt(t, "cross-model", "--runtime", "agy", "--brief", b)
	if rc != 3 {
		t.Fatalf("rc=%d want 3 (infra, passed through)", rc)
	}
	if !strings.Contains(out, "rc 3 - runtime binary not on PATH") {
		t.Fatalf("rc3 must surface the environment diagnosis: %q", out)
	}
	if strings.Contains(out, "empty/short review") {
		t.Fatalf("rc3 must NOT be remapped to the empty/short-review fallback: %q", out)
	}
	if !strings.Contains(out, "body_bytes=0") {
		t.Fatalf("summary must report measured length 0: %q", out)
	}
}

func TestCrossModelRc7AgyAuthSurfaced(t *testing.T) {
	stubDispatchWorker(t, "x", 7)
	b := writeBrief(t, "b1.md")
	_, out := runCapt(t, "cross-model", "--runtime", "agy", "--brief", b)
	if !strings.Contains(strings.ToLower(out), "authenticat") {
		t.Fatalf("rc7 must surface agy-not-authenticated: %q", out)
	}
}

func TestCrossModelRc124Blocked(t *testing.T) {
	stubDispatchWorker(t, "x", 124) // strconv-based stub handles multi-digit rc
	b := writeBriefCleanPath(t, "plain.md")
	rc, out := runCapt(t, "cross-model", "--runtime", "agy", "--brief", b)
	if rc != 124 {
		t.Fatalf("rc=%d want 124", rc)
	}
	if !strings.Contains(out, "timeout - BLOCKED") || !strings.Contains(out, "BLOCKED") {
		t.Fatalf("rc124 must surface literal BLOCKED meaning: %q", out)
	}
}

func TestCrossModelInfraCodesPreserveEmptyBodyDisposition(t *testing.T) {
	for _, tc := range []struct {
		name string
		rc   int
		want string
	}{
		{name: "timeout", rc: 124, want: "timeout - BLOCKED"},
		{name: "codex_auth", rc: 5, want: "codex auth rejected"},
		{name: "dispatch_worker", rc: 2, want: "dispatch-worker usage error or dirty-tree refusal"},
		{name: "runtime_missing", rc: 3, want: "runtime binary not on PATH"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stubDispatchWorkerScript(t, `#!/usr/bin/env bash
echo "$@" >> "CALLLOG"
echo 'REVIEW_OUTFILE=/tmp/x' >&2
exit `+strconv.Itoa(tc.rc)+`
`)
			b := writeBriefCleanPath(t, "plain.md")
			rc, out := runCapt(t, "cross-model", "--runtime", "agy", "--brief", b)
			if rc != tc.rc {
				t.Fatalf("rc=%d want %d", rc, tc.rc)
			}
			if !strings.Contains(out, "rc "+strconv.Itoa(tc.rc)+" - "+tc.want) {
				t.Fatalf("empty infra rc must preserve disposition %q: %q", tc.want, out)
			}
			if strings.Contains(out, "empty/short review") {
				t.Fatalf("empty infra rc must not be remapped to fallback: %q", out)
			}
			if !strings.Contains(out, "body_bytes=0") {
				t.Fatalf("summary must report measured length 0: %q", out)
			}
		})
	}
}

func TestCrossModelThreadsFlags(t *testing.T) {
	callLog := stubDispatchWorker(t, strings.Repeat("review details ", 200), 0)
	b := writeBrief(t, "b1.md")
	rc, _ := runCapt(t, "cross-model", "--runtime", "codex", "--timeout", "9m", "--brief", b)
	if rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	calls := readFile(t, callLog)
	for _, want := range []string{"--runtime codex", "--timeout 9m", "--review", "--brief"} {
		if !strings.Contains(calls, want) {
			t.Fatalf("call log missing %q: %q", want, calls)
		}
	}
}

func TestCrossModelThreadsWorkdir(t *testing.T) {
	callLog := stubDispatchWorker(t, strings.Repeat("review details ", 200), 0)
	b := writeBrief(t, "b1.md")
	workdir := t.TempDir()
	rc, _ := runCapt(t, "cross-model", "--runtime", "agy", "--brief", b, "--workdir", workdir)
	if rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	calls := readFile(t, callLog)
	if !strings.Contains(calls, "--workdir "+workdir) {
		t.Fatalf("dispatch-worker invocation missing --workdir %q: %q", workdir, calls)
	}
}

func TestCrossModelDefaultsWorkdirFromBriefRepoRoot(t *testing.T) {
	callLog := stubDispatchWorker(t, strings.Repeat("review details ", 200), 0)
	dir := t.TempDir()
	b := filepath.Join(dir, "brief.md")
	const briefRoot = "/tmp/review-gate-brief-root"
	body := "repo root: " + briefRoot + "\n\nBRIEF BODY long enough to be a real review brief for the stub.\n"
	if err := os.WriteFile(b, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	rc, _ := runCapt(t, "cross-model", "--runtime", "agy", "--brief", b)
	if rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	calls := readFile(t, callLog)
	if !strings.Contains(calls, "--workdir "+briefRoot) {
		t.Fatalf("dispatch-worker invocation did not default --workdir from brief repo root %q: %q", briefRoot, calls)
	}
}

func TestCrossModelExplicitWorkdirOverridesBriefRepoRoot(t *testing.T) {
	callLog := stubDispatchWorker(t, strings.Repeat("review details ", 200), 0)
	dir := t.TempDir()
	b := filepath.Join(dir, "brief.md")
	const briefRoot = "/tmp/review-gate-brief-root"
	body := "repo root: " + briefRoot + "\n\nBRIEF BODY long enough to be a real review brief for the stub.\n"
	if err := os.WriteFile(b, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	workdir := filepath.Join(t.TempDir(), "override")
	rc, _ := runCapt(t, "cross-model", "--runtime", "agy", "--brief", b, "--workdir", workdir)
	if rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	calls := readFile(t, callLog)
	if !strings.Contains(calls, "--workdir "+workdir) {
		t.Fatalf("dispatch-worker invocation missing explicit --workdir %q: %q", workdir, calls)
	}
	if strings.Contains(calls, "--workdir "+briefRoot) {
		t.Fatalf("explicit --workdir must override brief repo root %q: %q", briefRoot, calls)
	}
}

func TestCrossModelHealthyLongBodyReportsLength(t *testing.T) {
	body := strings.Repeat("healthy review body ", 120)
	stubDispatchWorkerScript(t, `#!/usr/bin/env bash
echo "$@" >> "CALLLOG"
printf %s `+strconv.Quote(body)+`
echo 'REVIEW_OUTFILE=/tmp/x (rc=0)' >&2
exit 0
`)
	b := writeBriefCleanPath(t, "plain.md")
	rc, out := runCapt(t, "cross-model", "--runtime", "agy", "--brief", b)
	if rc != 0 {
		t.Fatalf("rc=%d want 0", rc)
	}
	if !strings.Contains(out, "body_bytes="+strconv.Itoa(len(body))) {
		t.Fatalf("summary must report real body length %d: %q", len(body), out)
	}
	if strings.Contains(out, "empty/short review") {
		t.Fatalf("long healthy body must not be marked short: %q", out)
	}
}

func TestCrossModelShortBodyThresholdBoundary(t *testing.T) {
	for _, tc := range []struct {
		name string
		n    int
		want int
	}{
		{name: "just_under", n: shortReviewBodyByteThreshold - 1, want: 8},
		{name: "at_threshold", n: shortReviewBodyByteThreshold, want: 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := strings.Repeat("x", tc.n)
			stubDispatchWorkerScript(t, `#!/usr/bin/env bash
echo "$@" >> "CALLLOG"
printf %s `+strconv.Quote(body)+`
echo 'REVIEW_OUTFILE=/tmp/x (rc=0)' >&2
exit 0
`)
			b := writeBriefCleanPath(t, "plain.md")
			rc, out := runCapt(t, "cross-model", "--runtime", "agy", "--brief", b)
			if rc != tc.want {
				t.Fatalf("rc=%d want %d", rc, tc.want)
			}
			if !strings.Contains(out, "body_bytes="+strconv.Itoa(tc.n)) {
				t.Fatalf("summary must report boundary body length %d: %q", tc.n, out)
			}
		})
	}
}

func TestCrossModelRc0AgySignoff392BytesFallsBack(t *testing.T) {
	body := "Review complete. I checked the diff and found no issues requiring changes. The implementation looks good and the tests pass. " +
		"This is only a sign-off, not a substantive cross-model review with findings, risks, or verification notes. " +
		"Proceeding would recreate the regression where a short agy completion was counted as a review. "
	if len(body) > 392 {
		t.Fatalf("base fixture length=%d exceeds target 392", len(body))
	}
	body += strings.Repeat("x", 392-len(body))
	stubDispatchWorkerScript(t, `#!/usr/bin/env bash
echo "$@" >> "CALLLOG"
printf %s `+strconv.Quote(body)+`
echo 'REVIEW_OUTFILE=/tmp/x (rc=0)' >&2
exit 0
`)
	b := writeBriefCleanPath(t, "plain.md")
	rc, out := runCapt(t, "cross-model", "--runtime", "agy", "--brief", b)
	if rc != 8 {
		t.Fatalf("rc=%d want 8", rc)
	}
	if !strings.Contains(out, "rc 8 - empty/short review") || !strings.Contains(out, "body_bytes=392") {
		t.Fatalf("392B sign-off must fail over to fallback: %q", out)
	}
}

func TestCrossModelRc5(t *testing.T) {
	stubDispatchWorker(t, "x", 5)
	b := writeBriefCleanPath(t, "plain.md")
	rc, out := runCapt(t, "cross-model", "--runtime", "codex", "--brief", b)
	if rc != 5 {
		t.Fatalf("rc=%d want 5", rc)
	}
	if !strings.Contains(out, "codex auth") {
		t.Fatalf("rc5 must surface codex auth guidance: %q", out)
	}
}

func TestCrossModelRc6(t *testing.T) {
	stubDispatchWorker(t, "x", 6)
	b := writeBriefCleanPath(t, "plain.md")
	rc, out := runCapt(t, "cross-model", "--runtime", "codex", "--brief", b)
	if rc != 6 {
		t.Fatalf("rc=%d want 6", rc)
	}
	if !strings.Contains(out, "limit") {
		t.Fatalf("rc6 must surface limit guidance: %q", out)
	}
}

func TestCrossModelMultiBriefSerializedSummary(t *testing.T) {
	callLog := stubDispatchWorker(t, strings.Repeat("review details ", 200), 0)
	b1, b2 := writeBrief(t, "b1.md"), writeBrief(t, "b2.md")
	rc, out := runCapt(t, "cross-model", "--runtime", "agy", "--brief", b1, "--brief", b2)
	if rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	if n := strings.Count(readFile(t, callLog), "\n"); n != 2 {
		t.Fatalf("want 2 serialized dispatch calls, got %d", n)
	}
	if !strings.Contains(out, "brief 1") || !strings.Contains(out, "brief 2") {
		t.Fatalf("summary must carry a per-brief rc line for each brief: %q", out)
	}
}

func TestCrossModelPartialFailure(t *testing.T) {
	body := strings.Repeat("review details ", 200)
	callLog := stubDispatchWorkerScript(t, `#!/usr/bin/env bash
n=0
if [ -f "CALLLOG" ]; then
  n=$(wc -l < "CALLLOG")
fi
echo "$@" >> "CALLLOG"
echo "`+body+`"
if [ "$n" -ge 1 ]; then
  exit 5
fi
exit 0
`)
	b1, b2 := writeBriefCleanPath(t, "one.md"), writeBriefCleanPath(t, "two.md")
	rc, out := runCapt(t, "cross-model", "--runtime", "agy", "--brief", b1, "--brief", b2)
	if rc != 5 {
		t.Fatalf("rc=%d want 5", rc)
	}
	if n := strings.Count(readFile(t, callLog), "\n"); n != 2 {
		t.Fatalf("want both dispatches to run, got %d", n)
	}
	if !strings.Contains(out, "brief 1") || !strings.Contains(out, "brief 2") {
		t.Fatalf("summary must carry both brief lines: %q", out)
	}
}

func readFile(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
