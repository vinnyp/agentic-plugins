package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type repeated []string

func (r *repeated) String() string     { return strings.Join(*r, ",") }
func (r *repeated) Set(v string) error { *r = append(*r, v); return nil }

// resolveClosingTemplate returns the path to templates/review-brief-closing.md when
// --closing-template is omitted: next to the binary (<plugin>/.bin/review-gate ->
// <plugin>/templates/...), else $CLAUDE_PLUGIN_ROOT/templates/. A robust default means
// the brief never crashes on an empty flag regardless of how the skill invokes it.
func resolveClosingTemplate(flagVal string) string {
	if flagVal != "" {
		return flagVal
	}
	if exe, err := os.Executable(); err == nil {
		if real, e := filepath.EvalSymlinks(exe); e == nil {
			exe = real
		}
		cand := filepath.Join(filepath.Dir(exe), "..", "templates", "review-brief-closing.md")
		if _, err := os.Stat(cand); err == nil {
			return cand
		}
	}
	if root := os.Getenv("CLAUDE_PLUGIN_ROOT"); root != "" {
		return filepath.Join(root, "templates", "review-brief-closing.md")
	}
	return ""
}

// resolveRepoRoot returns the absolute directory the brief's target paths are relative
// to. A brief that names paths but no root is only resolvable by luck: the reviewer
// runtime's cwd may be the shared checkout rather than the worktree under review (and
// agy does not load worktrees at all), so a reviewer handed a bare relative path can
// silently read the WRONG file — or nothing — and review the brief's own prose instead
// of the code. Emitting the root is what makes "paths, never excerpts" actionable.
//
// Order: explicit --repo-root, else the git toplevel of cwd, else cwd. It never fails
// the brief: a root is always better than none, and an unresolvable one is not worth
// blocking a review over.
func resolveRepoRoot(flagVal string) string {
	if flagVal != "" {
		if abs, err := filepath.Abs(flagVal); err == nil {
			return abs
		}
		return flagVal
	}
	if out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output(); err == nil {
		if root := strings.TrimSpace(string(out)); root != "" {
			return root
		}
	}
	if cwd, err := os.Getwd(); err == nil {
		return cwd
	}
	return ""
}

// targetExists reports whether a brief target path resolves to something the
// reviewer could actually open. A relative path is tried against the repo root
// the brief prints (the root the reviewer is told to resolve against) and then
// against the caller's cwd, so an author who passes either form is not punished.
func targetExists(root, p string) bool {
	if p == "" {
		return false
	}
	cands := []string{p}
	if !filepath.IsAbs(p) && root != "" {
		cands = []string{filepath.Join(root, p), p}
	}
	for _, c := range cands {
		if _, err := os.Stat(c); err == nil {
			return true
		}
	}
	return false
}

func isGitRepo(dir string) bool {
	if dir == "" {
		return false
	}
	return exec.Command("git", "-C", dir, "rev-parse", "--git-dir").Run() == nil
}

// validateTargets fails a brief that names something the reviewer cannot open.
//
// A brief is a promise that its targets are real. Emitting a typo'd --source, a
// --spec that was moved, or a --range that no longer resolves produces a brief
// byte-indistinguishable from a correct one, and the only thing left to notice
// is the reviewer's own self-report — the same "the check never evaluated its
// subject" shape the review gate exists to catch. Fail closed here instead.
//
// The --range probe is skipped when the root is not a git repo, so a brief
// authored against a non-repo directory is not failed for a check that cannot run.
func validateTargets(root string, specs, sources []string, rng string) error {
	for _, group := range [][]string{specs, sources} {
		for _, p := range group {
			if !targetExists(root, p) {
				return fmt.Errorf("target path not found: %s (resolved against repo root %s)", p, root)
			}
		}
	}
	if rng != "" && isGitRepo(root) {
		if err := exec.Command("git", "-C", root, "rev-list", "-1", rng, "--").Run(); err != nil {
			return fmt.Errorf("--range %q does not resolve in %s", rng, root)
		}
	}
	return nil
}

func cmdBrief(args []string) int {
	fs := flag.NewFlagSet("brief", flag.ContinueOnError)
	persona := fs.String("persona", "", "peer-X-reviewer slug")
	mode := fs.String("mode", "", "design|build")
	forRoute := fs.String("for", "", "claude|cross-model")
	rng := fs.String("range", "", "SHA..range (build mode)")
	what := fs.String("what", "", "what the change should do")
	tmpl := fs.String("closing-template", "", "path to review-brief-closing.md")
	repoRoot := fs.String("repo-root", "", "absolute dir the target paths resolve against (default: git toplevel of cwd)")
	var specs, sources repeated
	fs.Var(&specs, "spec", "spec path (design mode; repeatable)")
	fs.Var(&sources, "source", "contract source to read (repeatable)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *mode != "design" && *mode != "build" {
		fmt.Fprintln(os.Stderr, "brief: --mode must be design|build")
		return 1
	}
	if *forRoute != "claude" && *forRoute != "cross-model" {
		fmt.Fprintln(os.Stderr, "brief: --for must be claude|cross-model")
		return 1
	}
	// mode gates --spec vs --range
	if *mode == "design" {
		if len(specs) == 0 || *rng != "" {
			fmt.Fprintln(os.Stderr, "brief: design mode requires --spec and forbids --range")
			return 1
		}
	} else {
		if *rng == "" || len(specs) > 0 {
			fmt.Fprintln(os.Stderr, "brief: build mode requires --range and forbids --spec")
			return 1
		}
	}
	dir, version, err := resolvePersonaDir()
	if err != nil {
		fmt.Fprintln(os.Stderr, "brief: cannot resolve persona dir:", err)
		return 2
	}
	valid, err := validPersonas(dir)
	if err != nil {
		return 2
	}
	if !contains(valid, *persona) {
		fmt.Fprintf(os.Stderr, "brief: unknown persona %q; valid: %s\n", *persona, strings.Join(valid, ", "))
		return 1
	}
	closing, err := os.ReadFile(resolveClosingTemplate(*tmpl))
	if err != nil {
		fmt.Fprintln(os.Stderr, "brief: cannot read closing template:", err)
		return 2
	}
	root := resolveRepoRoot(*repoRoot)
	if err := validateTargets(root, specs, sources, *rng); err != nil {
		fmt.Fprintln(os.Stderr, "brief:", err)
		return 1
	}

	var b strings.Builder
	if *forRoute == "cross-model" {
		body, err := readPersonaBody(dir, *persona)
		if err != nil {
			return 2
		}
		b.WriteString(body)
		b.WriteString("\n\n---\n\n")
	}
	fmt.Fprintf(&b, "# Review brief - %s (%s mode)\n", *persona, *mode)
	fmt.Fprintf(&b, "persona-version: %s\n\n", version)
	if root != "" {
		fmt.Fprintf(&b, "repo root: %s\n", root)
		b.WriteString("Every path below is relative to that root. READ them — the brief does not\n" +
			"quote the code, and an excerpt is not the subject under review.\n\n")
	}
	if *mode == "design" {
		b.WriteString("Review the following DESIGN SPEC for soundness (consultant mode):\n")
		for _, s := range specs {
			fmt.Fprintf(&b, "- %s\n", s)
		}
	} else {
		fmt.Fprintf(&b, "Verify the following DIFF against the real contracts:\n- range: %s\n", *rng)
	}
	if len(sources) > 0 {
		b.WriteString("\nContract sources to READ:\n")
		for _, s := range sources {
			fmt.Fprintf(&b, "- %s\n", s)
		}
	}
	if *what != "" {
		fmt.Fprintf(&b, "\nWhat it should do: %s\n", *what)
	}
	b.WriteString("\n")
	b.Write(closing)
	fmt.Fprint(os.Stdout, b.String())
	return 0
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}
