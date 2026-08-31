// Command review-gate is the helper CLI for the tiered peer-review gate.
//
// Subcommands (persona-agnostic -- the standard owns tier selection):
//
//	brief        assemble a route-conditional review brief
//	log-new      scaffold the durable review log
//	cross-model  serialize a different-model review run via dispatch-worker
//	             (--workdir selects the checkout under review; defaults to the brief's repo root, else cwd)
//
// Reviewer personas are resolved from the installed peer-reviewer-agents plugin
// (marketplace agentic-plugins). Environment overrides:
//
//	REVIEW_GATE_PERSONA_DIR          an agents/ dir to use verbatim (highest priority)
//	REVIEW_GATE_PERSONA_MARKETPLACE  marketplace owning the personas (default agentic-plugins)
//	REVIEW_GATE_PERSONA_PLUGIN       plugin owning the personas (default peer-reviewer-agents)
//
// Exit codes: 0 ok, 1 validation failure, 2 I/O or system error, 3 log-new wrote but persona provenance is unresolved.
package main

import (
	"fmt"
	"os"
)

func main() { os.Exit(run(os.Args[1:])) }

func run(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: review-gate <brief|log-new|cross-model> [flags]")
		return 2
	}
	cmd, rest := args[0], args[1:]
	switch cmd {
	case "brief":
		return cmdBrief(rest)
	case "log-new":
		return cmdLogNew(rest)
	case "cross-model":
		return cmdCrossModel(rest)
	default:
		fmt.Fprintf(os.Stderr, "review-gate: unknown subcommand %q\n", cmd)
		return 2
	}
}
