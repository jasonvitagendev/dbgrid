# Contributing

Thanks for looking at dbgrid.nvim. Bug reports, questions and pull requests
are all welcome.

## Reporting a bug

Open an issue with your Neovim version, the database (PostgreSQL or SQLite
and its version), the output of `:checkhealth dbgrid`, and the smallest
notebook cell that shows the problem. Security problems go through the
private channel described in [SECURITY.md](SECURITY.md), not an issue.

## Proposing a feature

Open an issue first, or comment on an existing one labelled `idea`, before
writing a large change. That way we can agree on the shape before you spend
time on it. Small, obvious improvements can go straight to a pull request.

## Working on the code

```sh
tests/run.sh                                                   # unit tests (plus SQLite when sqlite3 is on PATH)
DBGRID_TEST_URL=postgres://postgres@localhost:5432/dbgrid_test tests/run.sh   # plus the Postgres integration tests
stylua lua tests                                               # format
```

The Postgres tests need `tests/seed.sql` loaded into a database called
`dbgrid_test` that accepts the `postgres` user without a password, as a local
`postgres` with trust auth does. A throwaway one:

```sh
docker run -d --name dbgrid-pg -e POSTGRES_USER=postgres -e POSTGRES_HOST_AUTH_METHOD=trust \
  -e POSTGRES_DB=dbgrid_test -p 5432:5432 postgres:16
psql postgres://postgres@localhost:5432/dbgrid_test -v ON_ERROR_STOP=1 -q -f tests/seed.sql
```

The AWS and agent features are tested against a fake `aws` CLI and a fake
agent in `tests/fixtures`, so no account and no model are needed.

## Pull requests

- One change per pull request. Refactors and features in separate PRs are
  far easier to review.
- Run `tests/run.sh` and `stylua --check lua tests` before pushing; CI runs
  both on Neovim 0.10, stable and nightly.
- Add or extend a test in `tests/` for behaviour you change. The harness is
  `tests/harness.lua`; look at a neighbouring `*_spec.lua` for the style.
- Update `README.md` and `doc/dbgrid.txt` when a keymap, command or option
  changes. Both describe the same features; keep them in step.
- Write the commit subject as `area: what changed` (for example
  `results: keep the plan view when leaving a cell`), in the imperative.

## Adding a database adapter

Adapters live in `lua/dbgrid/adapters/`. The README section "Other
databases" describes the interface; `sqlite.lua` is the smallest complete
example to copy from.

## Re-recording the demo

`assets/demo.gif` is made with [vhs](https://github.com/charmbracelet/vhs)
from `assets/demo.tape` against the test database above:

```sh
brew install vhs
vhs assets/demo.tape
```
