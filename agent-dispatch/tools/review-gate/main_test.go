package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writePersona creates a peer-X-reviewer.md with frontmatter + a body line.
func writePersona(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	content := "---\nname: " + name + "\n---\n\n" + body + "\n"
	if err := os.WriteFile(filepath.Join(dir, name+".md"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestRunNoArgsUsageRC2(t *testing.T) {
	if rc := run(nil); rc != 2 {
		t.Fatalf("no-args rc=%d want 2", rc)
	}
}

func TestResolvePersonaDirHonorsEnvOverride(t *testing.T) {
	dir := t.TempDir()
	writePersona(t, dir, "peer-code-reviewer", "CODE PERSONA BODY")
	t.Setenv("REVIEW_GATE_PERSONA_DIR", dir)
	got, version, err := resolvePersonaDir()
	if err != nil {
		t.Fatal(err)
	}
	if got != dir {
		t.Fatalf("dir=%q want %q", got, dir)
	}
	if version != "override" {
		t.Fatalf("version=%q want override", version)
	}
}

func TestReadPersonaBodyStripsFrontmatter(t *testing.T) {
	dir := t.TempDir()
	writePersona(t, dir, "peer-code-reviewer", "CODE PERSONA BODY")
	body, err := readPersonaBody(dir, "peer-code-reviewer")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(body, "name: peer-code-reviewer") {
		t.Fatalf("frontmatter not stripped: %q", body)
	}
	if !strings.Contains(body, "CODE PERSONA BODY") {
		t.Fatalf("body missing: %q", body)
	}
}

func TestValidPersonasGlob(t *testing.T) {
	dir := t.TempDir()
	writePersona(t, dir, "peer-code-reviewer", "x")
	writePersona(t, dir, "peer-interface-reviewer", "y")
	got, err := validPersonas(dir)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]bool{"peer-code-reviewer": true, "peer-interface-reviewer": true}
	if len(got) != 2 || !want[got[0]] || !want[got[1]] {
		t.Fatalf("validPersonas=%v want the two seeded", got)
	}
}

// clearPersonaEnv neutralises every persona-resolution env var so an ambient
// CLAUDE_PLUGIN_ROOT (this suite often runs inside an installed plugin) cannot leak
// into a test that is asserting a different resolution arm.
func clearPersonaEnv(t *testing.T) {
	t.Helper()
	for _, k := range []string{
		"REVIEW_GATE_PERSONA_DIR",
		"REVIEW_GATE_PERSONA_MARKETPLACE",
		"REVIEW_GATE_PERSONA_PLUGIN",
		"CLAUDE_PLUGIN_ROOT",
	} {
		t.Setenv(k, "")
	}
}

// seedCachePlugin builds <cache>/<marketplace>/<plugin>/<version>/agents with one
// persona and returns the agents dir.
func seedCachePlugin(t *testing.T, cache, marketplace, plugin, version string) string {
	t.Helper()
	agents := filepath.Join(cache, marketplace, plugin, version, "agents")
	writePersona(t, agents, "peer-code-reviewer", "CACHED PERSONA BODY")
	return agents
}

func TestResolvePersonaDirFromPublicCache(t *testing.T) {
	clearPersonaEnv(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	cache := filepath.Join(home, ".claude", "plugins", "cache")
	want := seedCachePlugin(t, cache, "agentic-plugins", "peer-reviewer-agents", "1.0.0")

	got, label, err := resolvePersonaDir()
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("dir=%q want %q", got, want)
	}
	if label != "cache/1.0.0" {
		t.Fatalf("label=%q want cache/1.0.0", label)
	}
}

func TestResolvePersonaDirCachePicksNewestVersion(t *testing.T) {
	clearPersonaEnv(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	cache := filepath.Join(home, ".claude", "plugins", "cache")
	seedCachePlugin(t, cache, "agentic-plugins", "peer-reviewer-agents", "0.9.0")
	want := seedCachePlugin(t, cache, "agentic-plugins", "peer-reviewer-agents", "1.10.0")

	got, label, err := resolvePersonaDir()
	if err != nil {
		t.Fatal(err)
	}
	if got != want || label != "cache/1.10.0" {
		t.Fatalf("dir=%q label=%q want %q / cache/1.10.0", got, label, want)
	}
}

func TestNewestAgentsDirRanksStableAboveSameBasePrerelease(t *testing.T) {
	parent := t.TempDir()
	want := filepath.Join(parent, "1.0.0", "agents")
	for _, version := range []string{"1.0.0", "1.0.0-rc1"} {
		if err := os.MkdirAll(filepath.Join(parent, version, "agents"), 0o755); err != nil {
			t.Fatal(err)
		}
	}

	got, label, ok := newestAgentsDir(parent)
	if !ok {
		t.Fatal("newestAgentsDir ok=false")
	}
	if got != want || label != "1.0.0" {
		t.Fatalf("dir=%q label=%q want %q / 1.0.0", got, label, want)
	}
}

func TestNewestAgentsDirRanksHigherBasePrereleaseAboveStable(t *testing.T) {
	parent := t.TempDir()
	want := filepath.Join(parent, "1.0.1-rc1", "agents")
	for _, version := range []string{"1.0.0", "1.0.1-rc1"} {
		if err := os.MkdirAll(filepath.Join(parent, version, "agents"), 0o755); err != nil {
			t.Fatal(err)
		}
	}

	got, label, ok := newestAgentsDir(parent)
	if !ok {
		t.Fatal("newestAgentsDir ok=false")
	}
	if got != want || label != "1.0.1-rc1" {
		t.Fatalf("dir=%q label=%q want %q / 1.0.1-rc1", got, label, want)
	}
}

func TestResolvePersonaDirHonorsMarketplaceAndPluginEnv(t *testing.T) {
	clearPersonaEnv(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	cache := filepath.Join(home, ".claude", "plugins", "cache")
	// The default location is populated too: the env overrides must win over it.
	seedCachePlugin(t, cache, "agentic-plugins", "peer-reviewer-agents", "1.0.0")
	want := seedCachePlugin(t, cache, "forked-marketplace", "forked-reviewers", "2.3.0")
	t.Setenv("REVIEW_GATE_PERSONA_MARKETPLACE", "forked-marketplace")
	t.Setenv("REVIEW_GATE_PERSONA_PLUGIN", "forked-reviewers")

	got, label, err := resolvePersonaDir()
	if err != nil {
		t.Fatal(err)
	}
	if got != want || label != "cache/2.3.0" {
		t.Fatalf("dir=%q label=%q want %q / cache/2.3.0", got, label, want)
	}
}

// This CLI installed from one marketplace, the personas published in another —
// a CROSS-marketplace hop from the plugin root.
func TestResolvePersonaDirFromPluginRootCrossMarketplace(t *testing.T) {
	clearPersonaEnv(t)
	t.Setenv("HOME", t.TempDir()) // empty: the cache arm must not be what answers
	cache := t.TempDir()
	want := seedCachePlugin(t, cache, "agentic-plugins", "peer-reviewer-agents", "1.0.0")
	root := filepath.Join(cache, "other-marketplace", "host-plugin", "0.39.0")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CLAUDE_PLUGIN_ROOT", root)

	got, label, err := resolvePersonaDir()
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("dir=%q want %q", got, want)
	}
	if label != "plugin-root/1.0.0" {
		t.Fatalf("label=%q want plugin-root/1.0.0", label)
	}
}

func TestResolvePersonaDirFromPluginRootSameMarketplace(t *testing.T) {
	clearPersonaEnv(t)
	t.Setenv("HOME", t.TempDir())
	cache := t.TempDir()
	want := seedCachePlugin(t, cache, "same-marketplace", "peer-reviewer-agents", "1.0.0")
	root := filepath.Join(cache, "same-marketplace", "host-plugin", "0.39.0")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CLAUDE_PLUGIN_ROOT", root)

	got, label, err := resolvePersonaDir()
	if err != nil {
		t.Fatal(err)
	}
	if got != want || label != "plugin-root/1.0.0" {
		t.Fatalf("dir=%q label=%q want %q / plugin-root/1.0.0", got, label, want)
	}
}

func TestResolvePersonaDirFallsBackToSourceCheckout(t *testing.T) {
	clearPersonaEnv(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	want := filepath.Join(home, "Projects", "peer-reviewer-agents", "agents")
	writePersona(t, want, "peer-code-reviewer", "SOURCE PERSONA BODY")

	got, label, err := resolvePersonaDir()
	if err != nil {
		t.Fatal(err)
	}
	if got != want || label != "source" {
		t.Fatalf("dir=%q label=%q want %q / source", got, label, want)
	}
}

func TestResolvePersonaDirNotFound(t *testing.T) {
	clearPersonaEnv(t)
	t.Setenv("HOME", t.TempDir())
	if _, _, err := resolvePersonaDir(); err == nil {
		t.Fatal("want an error when no persona dir exists anywhere")
	}
}
