// commitlint.config.cjs — the single source of commit-message rules.
//
// CI and agent-dispatch/bin/wrap-merge-body.sh both read THIS file; a wrapper
// carrying its own copy of the limit would drift from the gate it is meant to
// satisfy, which is exactly how an unlintable body reached public main twice
// (vinnyp/foundry#202). CI previously wrote an identical config inline at
// runtime, so the rules existed only inside a workflow step and nothing outside
// GitHub Actions could read them.
module.exports = { extends: ['@commitlint/config-conventional'] };
