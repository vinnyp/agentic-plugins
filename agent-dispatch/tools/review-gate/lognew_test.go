package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func gitRepo(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	return root
}

func logNewPersonaFixture(t *testing.T) {
	t.Helper()
	personaDir := t.TempDir()
	writePersona(t, personaDir, "peer-code-reviewer", "CODE PERSONA BODY")
	t.Setenv("REVIEW_GATE_PERSONA_DIR", personaDir)
}

func TestLogNewStdoutSkeleton(t *testing.T) {
	logNewPersonaFixture(t)
	rc, out := runCapt(t, "log-new", "--topic", "mything", "--mode", "build",
		"--persona", "peer-code-reviewer", "--persona", "peer-test-reviewer", "--stdout")
	if rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	for _, want := range []string{"peer-code-reviewer", "peer-test-reviewer", "disposition", "finding", "raised-by", "persona-version"} {
		if !strings.Contains(strings.ToLower(out), strings.ToLower(want)) {
			t.Fatalf("skeleton missing %q", want)
		}
	}
}

func TestLogNewAcceptsRequirementsMode(t *testing.T) {
	logNewPersonaFixture(t)
	rc, out := runCapt(t, "log-new", "--topic", "prd", "--mode", "requirements",
		"--persona", "peer-product-manager-reviewer", "--stdout")
	if rc != 0 {
		t.Fatalf("rc=%d out=%s", rc, out)
	}
	if !strings.Contains(out, "**Mode:** requirements") {
		t.Fatalf("log skeleton did not carry the requirements mode:\n%s", out)
	}
}

func TestLogNewUnresolvedPersonaVersionIsLoud(t *testing.T) {
	clearPersonaEnv(t)
	t.Setenv("HOME", t.TempDir())
	rc, out, stderr := runCaptAll(t, "log-new", "--topic", "mything", "--mode", "build",
		"--persona", "peer-code-reviewer", "--stdout")
	if rc != 3 {
		t.Fatalf("rc=%d want 3", rc)
	}
	if !strings.Contains(out, "persona-version:** UNRESOLVED") {
		t.Fatalf("unresolved persona-version marker missing:\n%s", out)
	}
	if strings.Contains(out, "persona-version:** .") || strings.Contains(out, "persona-version:** \n") {
		t.Fatalf("persona-version was silently empty:\n%s", out)
	}
	if !strings.Contains(stderr, "warning") || !strings.Contains(stderr, "cannot resolve persona dir") {
		t.Fatalf("missing persona-resolution warning on stderr: %q", stderr)
	}
}

func TestLogNewUnresolvedPersonaVersionWritesFileAndReturnsRC3(t *testing.T) {
	clearPersonaEnv(t)
	t.Setenv("HOME", t.TempDir())
	root := gitRepo(t)
	t.Chdir(root)

	rc, out, stderr := runCaptAll(t, "log-new", "--topic", "missing-persona", "--mode", "build",
		"--persona", "peer-code-reviewer")
	if rc != 3 {
		t.Fatalf("rc=%d want 3", rc)
	}
	date := time.Now().Format("2006-01-02")
	rel := filepath.Join("docs", "agent-reviews", date+"-missing-persona-peer-reviews.md")
	if !strings.Contains(out, rel) {
		t.Fatalf("stdout %q missing path %q", out, rel)
	}
	written, err := os.ReadFile(filepath.Join(root, rel))
	if err != nil {
		t.Fatalf("log not written despite rc3: %v", err)
	}
	if !strings.Contains(string(written), "persona-version:** UNRESOLVED") {
		t.Fatalf("written log missing UNRESOLVED marker:\n%s", string(written))
	}
	if !strings.Contains(stderr, "warning") || !strings.Contains(stderr, "cannot resolve persona dir") {
		t.Fatalf("missing persona-resolution warning on stderr: %q", stderr)
	}
}

func TestLogNewWritesInPlaceAndPrintsPath(t *testing.T) {
	logNewPersonaFixture(t)
	root := gitRepo(t)
	t.Chdir(root)
	rc, out := runCapt(t, "log-new", "--topic", "mything", "--persona", "peer-code-reviewer")
	if rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	date := time.Now().Format("2006-01-02")
	want := filepath.Join("docs", "agent-reviews", date+"-mything-peer-reviews.md")
	if !strings.Contains(out, want) {
		t.Fatalf("stdout %q missing path %q", out, want)
	}
	if _, err := os.Stat(filepath.Join(root, want)); err != nil {
		t.Fatalf("log not written: %v", err)
	}
}

func TestLogNewWorktreeGitFile(t *testing.T) {
	logNewPersonaFixture(t)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ".git"), []byte("gitdir: /somewhere\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Chdir(root)
	rc, _ := runCapt(t, "log-new", "--topic", "wt", "--persona", "peer-code-reviewer")
	if rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	date := time.Now().Format("2006-01-02")
	want := filepath.Join(root, "docs", "agent-reviews", date+"-wt-peer-reviews.md")
	if _, err := os.Stat(want); err != nil {
		t.Fatalf("log not written: %v", err)
	}
}

func TestLogNewRefusesOverwriteUnlessForce(t *testing.T) {
	logNewPersonaFixture(t)
	root := gitRepo(t)
	t.Chdir(root)
	if rc, _ := runCapt(t, "log-new", "--topic", "dup", "--persona", "peer-code-reviewer"); rc != 0 {
		t.Fatalf("first write rc=%d", rc)
	}
	if rc, _ := runCapt(t, "log-new", "--topic", "dup", "--persona", "peer-code-reviewer"); rc != 1 {
		t.Fatalf("second write rc=%d want 1 (refuse-overwrite)", rc)
	}
	if rc, _ := runCapt(t, "log-new", "--topic", "dup", "--persona", "peer-code-reviewer", "--force"); rc != 0 {
		t.Fatalf("--force rc=%d want 0", rc)
	}
}

func TestLogNewOutsideGitRepoRC2(t *testing.T) {
	plain := t.TempDir()
	t.Chdir(plain)
	if rc, _ := runCapt(t, "log-new", "--topic", "x", "--persona", "peer-code-reviewer"); rc != 2 {
		t.Fatalf("non-git rc=%d want 2", rc)
	}
}

func TestLogNewVaultTargetEmitsFrontmatter(t *testing.T) {
	logNewPersonaFixture(t)
	root := gitRepo(t)
	if err := os.MkdirAll(filepath.Join(root, ".obsidian"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Chdir(root)
	rc, out := runCapt(t, "log-new", "--topic", "vaulted", "--project", "agent-tooling", "--persona", "peer-code-reviewer")
	if rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	date := time.Now().Format("2006-01-02")
	written, err := os.ReadFile(filepath.Join(root, "docs", "agent-reviews", date+"-vaulted-peer-reviews.md"))
	if err != nil {
		t.Fatalf("log not written: %v", err)
	}
	body := string(written)
	if !strings.HasPrefix(body, "---\n") {
		t.Fatalf("vault-target scaffold missing frontmatter fence:\n%s", body)
	}
	for _, want := range []string{"type: note", `project: "agent-tooling"`, "status: active", "created: " + date, "- peer-review"} {
		if !strings.Contains(body, want) {
			t.Fatalf("frontmatter missing %q:\n%s", want, body)
		}
	}
	if !strings.Contains(out, filepath.Join("docs", "agent-reviews", date+"-vaulted-peer-reviews.md")) {
		t.Fatalf("stdout %q missing written path", out)
	}
}

func TestLogNewNonVaultTargetOmitsFrontmatter(t *testing.T) {
	logNewPersonaFixture(t)
	root := gitRepo(t) // no .obsidian/ — not a vault
	t.Chdir(root)
	rc, _ := runCapt(t, "log-new", "--topic", "plain", "--persona", "peer-code-reviewer")
	if rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	date := time.Now().Format("2006-01-02")
	written, err := os.ReadFile(filepath.Join(root, "docs", "agent-reviews", date+"-plain-peer-reviews.md"))
	if err != nil {
		t.Fatalf("log not written: %v", err)
	}
	if strings.HasPrefix(string(written), "---\n") {
		t.Fatalf("non-vault scaffold unexpectedly got frontmatter:\n%s", string(written))
	}
}

// --- topic containment (arbitrary-file-write guard) ---
//
// The output path is built from --topic, and this command is driven by agents on
// slugs derived from branch names and issue titles. Before the guard,
// `--topic '../../../../../tmp/x'` wrote outside the repo at exit 0.

func TestLogNewRejectsTraversalTopicAndWritesNothing(t *testing.T) {
	root := gitRepo(t)
	t.Chdir(root)
	outside := t.TempDir()
	escape := filepath.Join(outside, "escaped")

	for _, topic := range []string{
		"../../etc/x",
		"../" + filepath.Base(outside) + "/escaped",
		"..",
		"a/b",
		`a\b`,
		escape,
	} {
		rc, _ := runCapt(t, "log-new", "--topic", topic, "--persona", "peer-code-reviewer")
		if rc == 0 {
			t.Fatalf("--topic %q was accepted; it must fail closed", topic)
		}
	}

	// Nothing at all may have been created: not the escape target, not even the
	// docs/agent-reviews/ directory the write path would have made on its way out.
	if _, err := os.Stat(escape + "-peer-reviews.md"); err == nil {
		t.Fatalf("a rejected topic still wrote %s", escape+"-peer-reviews.md")
	}
	if entries, err := os.ReadDir(outside); err == nil && len(entries) != 0 {
		t.Fatalf("a rejected topic wrote into %s: %v", outside, entries)
	}
	if _, err := os.Stat(filepath.Join(root, "docs")); err == nil {
		t.Fatalf("a rejected topic created docs/ before failing")
	}
}

func TestLogNewAcceptsOrdinarySlugs(t *testing.T) {
	logNewPersonaFixture(t)
	root := gitRepo(t)
	t.Chdir(root)
	for _, topic := range []string{"json-flag", "review_gate.v2", "ABC123"} {
		rc, _ := runCapt(t, "log-new", "--topic", topic, "--persona", "peer-code-reviewer")
		if rc != 0 {
			t.Fatalf("--topic %q rejected (rc=%d); ordinary slugs must still work", topic, rc)
		}
	}
}

// --- frontmatter injection guard ---

func TestLogNewRejectsProjectWithNewline(t *testing.T) {
	root := gitRepo(t)
	if err := os.MkdirAll(filepath.Join(root, ".obsidian"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Chdir(root)
	rc, out := runCapt(t, "log-new", "--topic", "ok", "--project", "x\nmalicious: true", "--stdout")
	if rc == 0 {
		t.Fatalf("--project with a newline was accepted (rc=0); frontmatter injection:\n%s", out)
	}
	if strings.Contains(out, "malicious: true") {
		t.Fatalf("injected key reached the frontmatter:\n%s", out)
	}
}

// A legitimate project name containing a colon and quotes must still work AND emit
// PARSEABLE YAML — the silent-broken-frontmatter failure this tool exists to prevent.
// Before the YAML-quoting fix, `--project 'foo: bar "baz"'` emitted the line
// `project: foo: bar "baz"`, which is a YAML syntax error, at rc 0.
func TestLogNewProjectWithColonAndQuotesYieldsParseableYAML(t *testing.T) {
	logNewPersonaFixture(t)
	root := gitRepo(t)
	if err := os.MkdirAll(filepath.Join(root, ".obsidian"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Chdir(root)
	const project = `foo: bar "baz"`
	rc, out := runCapt(t, "log-new", "--topic", "ok", "--project", project, "--stdout")
	if rc != 0 {
		t.Fatalf("rc=%d want 0 (a legit name with a colon/quotes must work): %s", rc, out)
	}
	fm := frontmatterBlock(t, out)
	if !strings.Contains(fm, "project:") {
		t.Fatalf("no project key emitted:\n%s", fm)
	}
	// Real proof: a YAML parser accepts the block and reads back the exact value.
	got := yamlLoadProject(t, fm)
	if got != project {
		t.Fatalf("frontmatter did not parse to the input project: got %q want %q\n%s", got, project, fm)
	}
}

// A project name with a backslash must also round-trip through the double-quote escaping.
func TestLogNewProjectWithBackslashYieldsParseableYAML(t *testing.T) {
	logNewPersonaFixture(t)
	root := gitRepo(t)
	if err := os.MkdirAll(filepath.Join(root, ".obsidian"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Chdir(root)
	const project = `a\b "c"`
	rc, out := runCapt(t, "log-new", "--topic", "ok", "--project", project, "--stdout")
	if rc != 0 {
		t.Fatalf("rc=%d want 0: %s", rc, out)
	}
	if got := yamlLoadProject(t, frontmatterBlock(t, out)); got != project {
		t.Fatalf("backslash project did not round-trip: got %q want %q", got, project)
	}
}

// frontmatterBlock returns the text between the first '---' fence and the next.
func frontmatterBlock(t *testing.T, doc string) string {
	t.Helper()
	if !strings.HasPrefix(doc, "---\n") {
		t.Fatalf("document does not open with a frontmatter fence:\n%s", doc)
	}
	rest := doc[len("---\n"):]
	end := strings.Index(rest, "\n---\n")
	if end < 0 {
		t.Fatalf("frontmatter fence not closed:\n%s", doc)
	}
	return rest[:end]
}

// yamlLoadProject parses the frontmatter with a real YAML parser (python3's, already a
// documented dependency of this plugin's suite) and returns the `project` value. It
// fails the test if the block is not valid YAML — which is the whole point: malformed
// frontmatter must not pass. python3 is guaranteed on CI (ubuntu-latest) and dev; a
// genuine absence fails loudly rather than skipping so the guarantee is never silently lost.
func yamlLoadProject(t *testing.T, frontmatter string) string {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 not found; cannot verify YAML validity: %v", err)
	}
	const script = `import sys,yaml; d=yaml.safe_load(sys.stdin.read()); print(d["project"])`
	cmd := exec.Command(py, "-c", script)
	cmd.Stdin = strings.NewReader(frontmatter)
	var stdout, stderr strings.Builder
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("frontmatter is not parseable YAML (%v): %s\n--- frontmatter ---\n%s", err, stderr.String(), frontmatter)
	}
	return strings.TrimRight(stdout.String(), "\n")
}
