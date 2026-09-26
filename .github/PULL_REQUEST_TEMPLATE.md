## What and why

<!-- One paragraph: the problem, the change, the trade-off you took. The
description becomes the squash commit's body on main, wrapped at 72
columns, so the checklist below is deleted before merging (or the
maintainer replaces the body). -->

## Checklist

- [ ] `make test` passes (with a new test when behavior changed), and `make test-browser` where the repository has one
- [ ] `make fmt-check`, `make lint-text`, `make lint-blame`, `make shellcheck` and `actionlint .github/workflows/*.yml` pass
- [ ] No attribution trailer such as `Co-authored-by` or `Signed-off-by`, no em dash character and no workflow skip instruction (a bracketed skip word or a `skip-checks` trailer) in the title, the body or the commits (see CONTRIBUTING.md, Commits)
- [ ] The title is at most 65 characters and carries no em dash: it becomes the squash commit's subject with ` (#N)` appended
- [ ] Docs updated when an option or command changed (README, and the vimdoc where the repository has one), and a `CHANGELOG.md` Unreleased line when the change is user-visible
