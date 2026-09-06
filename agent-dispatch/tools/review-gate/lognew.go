package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// validTopic constrains --topic to a single filename segment.
//
// The output path is built from the topic, so an unconstrained one escapes the
// repo entirely — `--topic '../../../../../tmp/x'` walks out of
// docs/agent-reviews/ and writes wherever it lands, at exit 0. This command is
// built to be driven by agents on slugs derived from branch names, issue titles
// and diff summaries, so that is a live arbitrary-file-write, not a theoretical
// one. Constrain positively and fail closed before anything is created.
var validTopic = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)

func validateTopic(topic string) error {
	if !validTopic.MatchString(topic) {
		return fmt.Errorf("--topic %q must be a single path segment matching [A-Za-z0-9._-]+", topic)
	}
	if strings.Contains(topic, "..") || filepath.Base(topic) != topic {
		return fmt.Errorf("--topic %q must not contain a path traversal", topic)
	}
	return nil
}

func repoRoot(start string) (string, bool) {
	d := start
	for {
		if _, err := os.Stat(filepath.Join(d, ".git")); err == nil {
			return d, true
		}
		parent := filepath.Dir(d)
		if parent == d {
			return "", false
		}
		d = parent
	}
}

// isObsidianVault reports whether root looks like an Obsidian vault: a
// .obsidian/ config directory at the repo root. Vaults conventionally require
// YAML frontmatter on every note, so the log scaffold grows a frontmatter block
// there and nowhere else. Inert in an ordinary repo.
func isObsidianVault(root string) bool {
	info, err := os.Stat(filepath.Join(root, ".obsidian"))
	return err == nil && info.IsDir()
}

// yamlDoubleQuote renders s as a YAML double-quoted scalar: wrap in quotes and
// escape the two characters that are special inside one, `\` and `"`. Interpolating
// a raw --project value straight into `project: %s` emits MALFORMED frontmatter the
// moment the value contains a colon or a quote (`foo: bar "baz"`) — the exact
// silent-broken-frontmatter failure this scaffold exists to avoid. Quoting keeps a
// legitimate project name with spaces or a colon working AND valid; an allowlist
// would instead reject valid input. Raw newlines are rejected upstream (a control
// character has no place in a project slug), so this need not fold lines.
func yamlDoubleQuote(s string) string {
	r := strings.NewReplacer(`\`, `\\`, `"`, `\"`)
	return `"` + r.Replace(s) + `"`
}

// vaultFrontmatter renders a minimal YAML frontmatter block for a `type: note`
// vault document (type, status, created, tags), plus a project key when the
// caller supplies one via --project. Emitting it is what lets the scaffold pass
// a vault's own note-validation hooks without a hand-edit.
func vaultFrontmatter(date, project string) string {
	var b strings.Builder
	b.WriteString("---\n")
	b.WriteString("type: note\n")
	if project != "" {
		fmt.Fprintf(&b, "project: %s\n", yamlDoubleQuote(project))
	}
	b.WriteString("status: active\n")
	fmt.Fprintf(&b, "created: %s\n", date)
	b.WriteString("tags:\n  - peer-review\n")
	b.WriteString("---\n\n")
	return b.String()
}

func cmdLogNew(args []string) int {
	fs := flag.NewFlagSet("log-new", flag.ContinueOnError)
	topic := fs.String("topic", "", "log topic slug")
	mode := fs.String("mode", "", "design|build|requirements (informational)")
	toStdout := fs.Bool("stdout", false, "emit to stdout instead of writing in place")
	force := fs.Bool("force", false, "overwrite an existing log")
	project := fs.String("project", "", "vault project slug (only used when the target repo is an Obsidian vault; adds a project: frontmatter key)")
	var personas repeated
	fs.Var(&personas, "persona", "reviewer persona (repeatable)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *topic == "" {
		fmt.Fprintln(os.Stderr, "log-new: --topic required")
		return 1
	}
	if err := validateTopic(*topic); err != nil {
		fmt.Fprintln(os.Stderr, "log-new:", err)
		return 1
	}
	// --project is interpolated straight into YAML frontmatter; a newline would
	// let a caller append arbitrary keys to the emitted block.
	if strings.ContainsAny(*project, "\n\r") {
		fmt.Fprintln(os.Stderr, "log-new: --project must not contain a newline (it is written into YAML frontmatter)")
		return 1
	}
	date := time.Now().Format("2006-01-02")
	rendered := renderLogSkeleton(date, *topic, *mode, personas)
	skeleton := rendered.body

	cwd, err := os.Getwd()
	if err != nil {
		return 2
	}
	root, ok := repoRoot(cwd)
	if !ok && !*toStdout {
		fmt.Fprintln(os.Stderr, "log-new: not inside a git repo (review logs live in the reviewed repo)")
		return 2
	}
	if ok && isObsidianVault(root) {
		skeleton = vaultFrontmatter(date, *project) + skeleton
	}

	if *toStdout {
		fmt.Fprint(os.Stdout, skeleton)
		if rendered.personaUnresolved {
			return 3
		}
		return 0
	}
	rel := filepath.Join("docs", "agent-reviews", fmt.Sprintf("%s-%s-peer-reviews.md", date, *topic))
	abs := filepath.Join(root, rel)
	if _, err := os.Stat(abs); err == nil && !*force {
		fmt.Fprintf(os.Stderr, "log-new: %s exists; use --force to overwrite\n", rel)
		return 1
	}
	if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
		return 2
	}
	if err := os.WriteFile(abs, []byte(skeleton), 0o644); err != nil {
		return 2
	}
	fmt.Fprintln(os.Stdout, rel)
	if rendered.personaUnresolved {
		return 3
	}
	return 0
}

func modeOr(m string) string {
	if m == "" {
		return "n/a"
	}
	return m
}

// renderLogSkeleton builds the durable review-log scaffold. It stamps the
// resolved persona-version so a skew between routes is visible in the log.
type logSkeleton struct {
	body              string
	personaUnresolved bool
}

func renderLogSkeleton(date, topic, mode string, personas []string) logSkeleton {
	_, version, err := resolvePersonaDir()
	personaUnresolved := false
	if err != nil {
		version = "UNRESOLVED"
		personaUnresolved = true
		fmt.Fprintln(os.Stderr, "log-new: warning: cannot resolve persona dir for persona-version (is the peer-reviewer-agents plugin installed?):", err)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "# Peer-review gate — %s (%s)\n\n", topic, date)
	fmt.Fprintf(&b, "**Mode:** %s. **Reviewers:** %s. **persona-version:** %s.\n\n",
		modeOr(mode), strings.Join(personas, ", "), version)
	b.WriteString("## Findings\n\n")
	for _, p := range personas {
		fmt.Fprintf(&b, "### %s\n\n(paste findings)\n\n", p)
	}
	b.WriteString("## Verify-the-reviewer dispositions\n\n")
	b.WriteString("| # | finding | raised-by | verify | disposition |\n")
	b.WriteString("|---|---|---|---|---|\n")
	b.WriteString("| 1 |  |  |  |  |\n")
	return logSkeleton{body: b.String(), personaUnresolved: personaUnresolved}
}
