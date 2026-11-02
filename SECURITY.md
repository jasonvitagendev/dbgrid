# Security

dbgrid talks to databases with the credentials you give it, runs the SQL you
write, and can hand SQL, schema and result rows to a coding-agent CLI. The
README section "What leaves your machine, what is written to disk" lists
exactly what goes where.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's
private vulnerability reporting instead:

https://github.com/jasonvitagendev/dbgrid/security/advisories/new

Include the plugin commit or version, your Neovim version, and the steps that
reproduce the problem. You will get an acknowledgement within a week, and a
fix or a plan for one as soon as the problem is understood.

## What counts

- Anything that sends data somewhere the README does not say it goes.
- Anything that writes credentials, parameter values or result rows to a file
  the README says is safe to commit.
- A way to run a statement that the safety rails (read-only connections,
  write confirmation, cascade warnings) say they stop.
- Shell injection through a connection URL, a file name, a parameter value
  or an agent response.

Bugs in the database, the `aws` CLI or the agent CLIs themselves belong with
those projects.
