package main

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// The reviewer personas ship in the PUBLIC peer-reviewer-agents plugin, published to
// the agentic-plugins marketplace. Both halves are overridable by env so a fork, a
// rename, or a private persona set needs no rebuild.
const (
	defaultPersonaMarketplace = "agentic-plugins"
	defaultPersonaPlugin      = "peer-reviewer-agents"
)

// personaMarketplace / personaPlugin return the marketplace + plugin that own the
// peer-*-reviewer persona files, honouring REVIEW_GATE_PERSONA_MARKETPLACE and
// REVIEW_GATE_PERSONA_PLUGIN.
func personaMarketplace() string {
	if v := os.Getenv("REVIEW_GATE_PERSONA_MARKETPLACE"); v != "" {
		return v
	}
	return defaultPersonaMarketplace
}

func personaPlugin() string {
	if v := os.Getenv("REVIEW_GATE_PERSONA_PLUGIN"); v != "" {
		return v
	}
	return defaultPersonaPlugin
}

// resolvePersonaDir returns the reviewer-persona directory + a provenance label.
//
// Resolution order:
//
//	override     REVIEW_GATE_PERSONA_DIR points straight at an agents dir
//	plugin-root  resolved relative to CLAUDE_PLUGIN_ROOT (portable across install
//	             locations, e.g. ~/.claude vs ~/.gemini)
//	cache        ~/.claude/plugins/cache/<marketplace>/<plugin>/<newest>/agents
//	source       ~/Projects/<plugin>/agents — a working-tree checkout, last resort
//
// Resolving from the installed cache keeps the agy brief on the same persona version
// the Claude Agent tool loads. The label carries the resolved version where there is
// one (e.g. "cache/1.0.0") so a persona-version skew stays visible in the review log.
func resolvePersonaDir() (string, string, error) {
	if d := os.Getenv("REVIEW_GATE_PERSONA_DIR"); d != "" {
		return d, "override", nil
	}
	marketplace, plugin := personaMarketplace(), personaPlugin()
	if dir, label, ok := personaDirFromPluginRoot(marketplace, plugin); ok {
		return dir, label, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", "", err
	}
	// Fallback: the default Claude plugin cache, <cache>/<marketplace>/<plugin>/<v>/agents.
	cache := filepath.Join(home, ".claude", "plugins", "cache", marketplace, plugin)
	if dir, v, ok := newestAgentsDir(cache); ok {
		return dir, "cache/" + v, nil
	}
	// Last resort: the working-tree source of the plugin's own repo.
	src := filepath.Join(home, "Projects", plugin, "agents")
	if _, err := os.Stat(src); err == nil {
		return src, "source", nil
	}
	return "", "", os.ErrNotExist
}

// personaDirFromPluginRoot resolves the persona dir relative to CLAUDE_PLUGIN_ROOT.
//
// The plugin cache is laid out <cache>/<marketplace>/<plugin>/<version>/, so from THIS
// plugin's root the persona plugin sits at ../../<plugin>/<newest>/agents when it shares
// our marketplace, and at ../../../<marketplace>/<plugin>/<newest>/agents when it does
// not — the case whenever this CLI is installed from a different marketplace than the
// one publishing the personas. Both are tried against BOTH root layouts (root = the
// version dir, and the older root = the plugin dir).
func personaDirFromPluginRoot(marketplace, plugin string) (string, string, bool) {
	root := os.Getenv("CLAUDE_PLUGIN_ROOT")
	if root == "" {
		return "", "", false
	}
	up1 := filepath.Dir(root)
	up2 := filepath.Dir(up1)
	up3 := filepath.Dir(up2)
	for _, cand := range []string{
		filepath.Join(up2, plugin),              // same marketplace, root = <…>/<plugin>/<version>
		filepath.Join(up1, plugin),              // same marketplace, root = <…>/<plugin>
		filepath.Join(up3, marketplace, plugin), // cross marketplace, root = <…>/<plugin>/<version>
		filepath.Join(up2, marketplace, plugin), // cross marketplace, root = <…>/<plugin>
	} {
		if dir, v, ok := newestAgentsDir(cand); ok {
			return dir, "plugin-root/" + v, true
		}
	}
	return "", "", false
}

// newestAgentsDir returns <parent>/<newest-version>/agents (+ the version label) if any
// versioned subdir contains an agents/ dir.
func newestAgentsDir(parent string) (string, string, bool) {
	entries, err := os.ReadDir(parent)
	if err != nil {
		return "", "", false
	}
	var versions []string
	for _, e := range entries {
		if e.IsDir() {
			if _, err := os.Stat(filepath.Join(parent, e.Name(), "agents")); err == nil {
				versions = append(versions, e.Name())
			}
		}
	}
	if len(versions) == 0 {
		return "", "", false
	}
	sort.Sort(byVersion(versions))
	v := versions[len(versions)-1]
	return filepath.Join(parent, v, "agents"), v, true
}

// byVersion sorts dotted numeric version strings ascending (e.g. 0.5.0 < 0.6.0 < 0.10.0).
type byVersion []string

func (b byVersion) Len() int      { return len(b) }
func (b byVersion) Swap(i, j int) { b[i], b[j] = b[j], b[i] }
func (b byVersion) Less(i, j int) bool {
	pi, pj := strings.Split(b[i], "."), strings.Split(b[j], ".")
	for k := 0; k < len(pi) && k < len(pj); k++ {
		ni, nj := atoiSafe(pi[k]), atoiSafe(pj[k])
		if ni != nj {
			return ni < nj
		}
	}
	return len(pi) < len(pj)
}

func atoiSafe(s string) int {
	n := 0
	for _, r := range s {
		if r < '0' || r > '9' {
			return n
		}
		n = n*10 + int(r-'0')
	}
	return n
}

// validPersonas lists peer-*-reviewer persona slugs present in dir (glob, never hardcoded).
func validPersonas(dir string) ([]string, error) {
	matches, err := filepath.Glob(filepath.Join(dir, "peer-*-reviewer.md"))
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(matches))
	for _, m := range matches {
		out = append(out, strings.TrimSuffix(filepath.Base(m), ".md"))
	}
	sort.Strings(out)
	return out, nil
}

// readPersonaBody returns the persona file with a leading YAML frontmatter block stripped.
func readPersonaBody(dir, persona string) (string, error) {
	raw, err := os.ReadFile(filepath.Join(dir, persona+".md"))
	if err != nil {
		return "", err
	}
	s := string(raw)
	if strings.HasPrefix(s, "---\n") {
		if end := strings.Index(s[4:], "\n---\n"); end >= 0 {
			s = s[4+end+len("\n---\n"):]
		} else if trimmed := strings.TrimRight(s, "\n"); strings.HasSuffix(trimmed, "\n---") {
			s = s[len(trimmed):]
		}
	}
	return strings.TrimLeft(s, "\n"), nil
}
