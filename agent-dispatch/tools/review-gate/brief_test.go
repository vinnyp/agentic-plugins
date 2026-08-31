package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// runCapt runs run(args) capturing stdout; returns (rc, stdout).
// The pipe is drained in a CONCURRENT goroutine so a large write never
// deadlocks (mirrors coaching-scorecard/main_test.go captureRun). Used by the
// brief/log-new/cross-model tests.
func runCapt(t *testing.T, args ...string) (int, string) {
	t.Helper()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = w
	done := make(chan string, 1)
	go func() {
		var sb strings.Builder
		buf := make([]byte, 4096)
		for {
			n, rerr := r.Read(buf)
			sb.Write(buf[:n])
			if rerr != nil {
				break
			}
		}
		done <- sb.String()
	}()
	rc := run(args)
	w.Close()
	os.Stdout = old
	out := <-done
	return rc, out
}

func runCaptAll(t *testing.T, args ...string) (int, string, string) {
	t.Helper()
	oldStdout, oldStderr := os.Stdout, os.Stderr
	stdoutR, stdoutW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stderrR, stderrW, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout, os.Stderr = stdoutW, stderrW
	drain := func(r *os.File) <-chan string {
		done := make(chan string, 1)
		go func() {
			var sb strings.Builder
			buf := make([]byte, 4096)
			for {
				n, rerr := r.Read(buf)
				sb.Write(buf[:n])
				if rerr != nil {
					break
				}
			}
			done <- sb.String()
		}()
		return done
	}
	stdoutDone := drain(stdoutR)
	stderrDone := drain(stderrR)
	rc := run(args)
	stdoutW.Close()
	stderrW.Close()
	os.Stdout, os.Stderr = oldStdout, oldStderr
	return rc, <-stdoutDone, <-stderrDone
}

func briefFixture(t *testing.T) (personaDir, tmpl string) {
	t.Helper()
	personaDir = t.TempDir()
	writePersona(t, personaDir, "peer-code-reviewer", "FULL_PERSONA_BODY")
	tmplDir := t.TempDir()
	tmpl = filepath.Join(tmplDir, "review-brief-closing.md")
	if err := os.WriteFile(tmpl, []byte("FILE_LINE_CLAUSE_TOKEN\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("REVIEW_GATE_PERSONA_DIR", personaDir)
	return
}

// targetRoot returns a temp dir populated with the given repo-root-relative
// fixture files, for use as --repo-root. Brief targets must resolve, so the
// valid-case tests need targets that actually exist.
func targetRoot(t *testing.T, rel ...string) string {
	t.Helper()
	root := t.TempDir()
	for _, r := range rel {
		p := filepath.Join(root, r)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("fixture\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func TestBriefCrossModelIncludesPersonaBody(t *testing.T) {
	_, tmpl := briefFixture(t)
	root := targetRoot(t, "lib/x.go")
	rc, out := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "build",
		"--for", "cross-model", "--range", "HEAD~1..HEAD", "--source", "lib/x.go",
		"--repo-root", root, "--closing-template", tmpl)
	if rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	if !strings.Contains(out, "FULL_PERSONA_BODY") {
		t.Fatalf("cross-model brief missing persona body")
	}
	if !strings.Contains(out, "FILE_LINE_CLAUSE_TOKEN") {
		t.Fatalf("brief missing closing template")
	}
	if !strings.Contains(out, "HEAD~1..HEAD") || !strings.Contains(out, "lib/x.go") {
		t.Fatalf("brief missing target/source")
	}
}

func TestBriefClaudeOmitsPersonaBody(t *testing.T) {
	_, tmpl := briefFixture(t)
	root := gitRepoWithCommits(t)
	rc, out := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "build",
		"--for", "claude", "--range", "HEAD~1..HEAD", "--repo-root", root,
		"--closing-template", tmpl)
	if rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	if strings.Contains(out, "FULL_PERSONA_BODY") {
		t.Fatalf("claude brief must OMIT the persona body (subagent auto-loads it)")
	}
	if !strings.Contains(out, "FILE_LINE_CLAUSE_TOKEN") {
		t.Fatalf("claude brief still needs the closing template")
	}
}

func TestBriefDesignRejectsRange(t *testing.T) {
	_, tmpl := briefFixture(t)
	rc, _ := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "design",
		"--for", "claude", "--range", "HEAD~1..HEAD", "--closing-template", tmpl)
	if rc != 1 {
		t.Fatalf("design+--range rc=%d want 1 (validation)", rc)
	}
}

func TestBriefBuildRejectsSpec(t *testing.T) {
	_, tmpl := briefFixture(t)
	rc, _ := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "build",
		"--for", "claude", "--range", "A..B", "--spec", "foo.md", "--closing-template", tmpl)
	if rc != 1 {
		t.Fatalf("build+--spec rc=%d want 1 (validation)", rc)
	}
}

func TestBriefDesignModeBody(t *testing.T) {
	_, tmpl := briefFixture(t)
	root := targetRoot(t, "s.md")
	rc, out := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "design",
		"--for", "claude", "--spec", "s.md", "--repo-root", root, "--closing-template", tmpl)
	if rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	if !strings.Contains(out, "Review the following DESIGN SPEC for soundness (consultant mode):") {
		t.Fatalf("design preamble missing: %q", out)
	}
	if !strings.Contains(out, "s.md") {
		t.Fatalf("design spec missing: %q", out)
	}
}

func TestBriefDefaultClosingTemplate(t *testing.T) {
	briefFixture(t)
	pluginRoot := t.TempDir()
	tmpl := filepath.Join(pluginRoot, "templates", "review-brief-closing.md")
	if err := os.MkdirAll(filepath.Dir(tmpl), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(tmpl, []byte("DEFAULT_TEMPLATE_TOKEN\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CLAUDE_PLUGIN_ROOT", pluginRoot)
	root := gitRepoWithCommits(t)
	rc, out := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "build",
		"--for", "claude", "--range", "HEAD~1..HEAD", "--repo-root", root)
	if rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	if !strings.Contains(out, "DEFAULT_TEMPLATE_TOKEN") {
		t.Fatalf("default closing template missing: %q", out)
	}
}

func TestBriefUnknownPersonaRC1WithList(t *testing.T) {
	_, tmpl := briefFixture(t)
	rc, _ := runCapt(t, "brief", "--persona", "peer-bogus-reviewer", "--mode", "build",
		"--for", "claude", "--range", "A..B", "--closing-template", tmpl)
	if rc != 1 {
		t.Fatalf("unknown persona rc=%d want 1", rc)
	}
}

func TestBriefStampsPersonaVersion(t *testing.T) {
	_, tmpl := briefFixture(t)
	root := gitRepoWithCommits(t)
	_, out := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "build",
		"--for", "claude", "--range", "HEAD~1..HEAD", "--repo-root", root,
		"--closing-template", tmpl)
	if !strings.Contains(out, "persona-version: override") {
		t.Fatalf("brief missing persona-version stamp: %q", out)
	}
}

func TestBriefIncludesWhatIntent(t *testing.T) {
	_, tmpl := briefFixture(t)
	root := gitRepoWithCommits(t)
	_, out := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "build",
		"--for", "claude", "--range", "HEAD~1..HEAD", "--repo-root", root,
		"--what", "WHAT_INTENT_TOKEN", "--closing-template", tmpl)
	if !strings.Contains(out, "WHAT_INTENT_TOKEN") {
		t.Fatalf("brief missing --what intent: %q", out)
	}
}

// --- repo root ---
//
// A review brief that names paths but no root is only resolvable by luck. These
// tests pin the root line onto BOTH modes, because the failure they exist to
// prevent (four excerpt-briefed rounds missing two Blockers a path-briefed round
// found) happened on a design-mode spec review.

func TestBriefEmitsRepoRootDesignMode(t *testing.T) {
	_, tmpl := briefFixture(t)
	root := targetRoot(t, "specs/x.md")
	rc, out := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "design",
		"--for", "claude", "--spec", "specs/x.md", "--repo-root", root,
		"--closing-template", tmpl)
	if rc != 0 {
		t.Fatalf("rc=%d out=%s", rc, out)
	}
	if !strings.Contains(out, "repo root: "+root) {
		t.Errorf("design brief missing repo root %q:\n%s", root, out)
	}
}

func TestBriefEmitsRepoRootBuildMode(t *testing.T) {
	_, tmpl := briefFixture(t)
	root := t.TempDir()
	rc, out := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "build",
		"--for", "cross-model", "--range", "HEAD~1..HEAD", "--repo-root", root,
		"--closing-template", tmpl)
	if rc != 0 {
		t.Fatalf("rc=%d out=%s", rc, out)
	}
	if !strings.Contains(out, "repo root: "+root) {
		t.Errorf("build brief missing repo root %q:\n%s", root, out)
	}
}

// The root must be present with no --repo-root flag too: a brief authored by an
// agent that forgets the flag is exactly the brief that goes wrong, so the
// default must not be "omit it".
func TestBriefRepoRootDefaultsWithoutFlag(t *testing.T) {
	_, tmpl := briefFixture(t)
	root := gitRepoWithCommits(t)
	t.Chdir(root)
	rc, out := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "build",
		"--for", "claude", "--range", "HEAD~1..HEAD", "--closing-template", tmpl)
	if rc != 0 {
		t.Fatalf("rc=%d out=%s", rc, out)
	}
	if !strings.Contains(out, "repo root: /") {
		t.Errorf("brief without --repo-root emitted no absolute root:\n%s", out)
	}
}

// The root is useless unless the brief also tells the reviewer to READ the paths
// rather than treat the brief as the subject.
func TestBriefInstructsReadingPathsNotExcerpts(t *testing.T) {
	_, tmpl := briefFixture(t)
	root := targetRoot(t, "specs/x.md")
	rc, out := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "design",
		"--for", "claude", "--spec", "specs/x.md", "--repo-root", root,
		"--closing-template", tmpl)
	if rc != 0 {
		t.Fatalf("rc=%d out=%s", rc, out)
	}
	if !strings.Contains(out, "READ them") {
		t.Errorf("brief does not instruct the reviewer to read the paths:\n%s", out)
	}
}

// Non-regression: an explicit relative --repo-root is still emitted absolute, so
// the reviewer never has to resolve it against its own cwd.
func TestBriefRepoRootIsAbsolute(t *testing.T) {
	_, tmpl := briefFixture(t)
	root := gitRepoWithCommits(t)
	t.Chdir(root)
	rc, out := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "build",
		"--for", "claude", "--range", "HEAD~1..HEAD", "--repo-root", ".",
		"--closing-template", tmpl)
	if rc != 0 {
		t.Fatalf("rc=%d out=%s", rc, out)
	}
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "repo root: ") {
			got := strings.TrimPrefix(line, "repo root: ")
			if !filepath.IsAbs(got) {
				t.Errorf("repo root %q is not absolute", got)
			}
			return
		}
	}
	t.Errorf("no repo root line in:\n%s", out)
}

// --- target validity (the brief must not promise what the reviewer cannot open) ---
//
// A brief naming a moved --spec, a typo'd --source, or a stale --range renders
// byte-identically to a correct one, so the only thing left to catch it is the
// reviewer's own self-report. These pin the fail-closed behaviour.

func TestBriefFailsOnMissingSpec(t *testing.T) {
	_, tmpl := briefFixture(t)
	root := targetRoot(t) // empty: nothing to find
	rc, out := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "design",
		"--for", "claude", "--spec", "specs/gone.md", "--repo-root", root,
		"--closing-template", tmpl)
	if rc != 1 {
		t.Fatalf("missing --spec rc=%d want 1", rc)
	}
	if strings.Contains(out, "specs/gone.md") {
		t.Fatalf("a rejected brief must not be emitted:\n%s", out)
	}
}

func TestBriefFailsOnMissingSource(t *testing.T) {
	_, tmpl := briefFixture(t)
	root := targetRoot(t, "lib/real.go")
	rc, out := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "build",
		"--for", "claude", "--range", "HEAD~1..HEAD",
		"--source", "lib/real.go", "--source", "lib/typo.go",
		"--repo-root", root, "--closing-template", tmpl)
	if rc != 1 {
		t.Fatalf("missing --source rc=%d want 1", rc)
	}
	if strings.Contains(out, "lib/typo.go") {
		t.Fatalf("a rejected brief must not be emitted:\n%s", out)
	}
}

func TestBriefFailsWhenRelativeSourceExistsOnlyInCwd(t *testing.T) {
	_, tmpl := briefFixture(t)
	cwd := targetRoot(t, "lib/only-cwd.go")
	root := targetRoot(t)
	t.Chdir(cwd)

	rc, out := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "build",
		"--for", "claude", "--range", "HEAD~1..HEAD", "--source", "lib/only-cwd.go",
		"--repo-root", root, "--closing-template", tmpl)
	if rc != 1 {
		t.Fatalf("source present only in cwd rc=%d want 1", rc)
	}
	if strings.Contains(out, "lib/only-cwd.go") {
		t.Fatalf("a rejected brief must not be emitted:\n%s", out)
	}
}

func TestBriefFailsOnUnresolvableRange(t *testing.T) {
	_, tmpl := briefFixture(t)
	root := gitRepoWithCommits(t)
	rc, out := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "build",
		"--for", "claude", "--range", "deadbeef..cafebabe", "--repo-root", root,
		"--closing-template", tmpl)
	if rc != 1 {
		t.Fatalf("unresolvable --range rc=%d want 1", rc)
	}
	if strings.Contains(out, "deadbeef..cafebabe") {
		t.Fatalf("a rejected brief must not be emitted:\n%s", out)
	}
}

func TestBriefAcceptsResolvableRange(t *testing.T) {
	_, tmpl := briefFixture(t)
	root := gitRepoWithCommits(t)
	rc, out := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "build",
		"--for", "claude", "--range", "HEAD~1..HEAD", "--repo-root", root,
		"--closing-template", tmpl)
	if rc != 0 {
		t.Fatalf("resolvable --range rc=%d want 0: %s", rc, out)
	}
	if !strings.Contains(out, "HEAD~1..HEAD") {
		t.Fatalf("brief missing the range:\n%s", out)
	}
}

// A root that is not a git repo cannot answer the range question, so the probe
// must be skipped rather than failing a brief on a check that could not run.
func TestBriefSkipsRangeProbeOutsideGitRepo(t *testing.T) {
	_, tmpl := briefFixture(t)
	root := targetRoot(t) // a plain directory, no .git
	rc, _ := runCapt(t, "brief", "--persona", "peer-code-reviewer", "--mode", "build",
		"--for", "claude", "--range", "deadbeef..cafebabe", "--repo-root", root,
		"--closing-template", tmpl)
	if rc != 0 {
		t.Fatalf("range probe must be skipped outside a git repo; rc=%d", rc)
	}
}

// gitRepoWithCommits builds a real two-commit repo so a range probe has
// something to resolve against.
func gitRepoWithCommits(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.invalid",
			"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.invalid")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-q", ".")
	for _, n := range []string{"one", "two"} {
		if err := os.WriteFile(filepath.Join(root, n+".txt"), []byte(n), 0o644); err != nil {
			t.Fatal(err)
		}
		run("add", "-A")
		run("commit", "-q", "-m", n)
	}
	return root
}
