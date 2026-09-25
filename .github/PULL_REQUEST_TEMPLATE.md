## What and why

<!-- One paragraph: the problem, the change, the trade-off you took. -->

## Checklist

- [ ] `make test` passes (with a new test when behavior changed)
- [ ] `make fmt-check`, `make lint-text` and `make lint-blame` pass
- [ ] No attribution trailer such as `Co-authored-by` or `Signed-off-by`, no em dash character and no workflow skip instruction (a bracketed skip word or a `skip-checks` trailer) in the title, the body or the commits (see CONTRIBUTING.md, Commits)
- [ ] The title is at most 65 characters and carries no em dash: it becomes the squash commit's subject with ` (#N)` appended
- [ ] Docs updated when an option or command changed (README, and the vimdoc where the repository has one)
