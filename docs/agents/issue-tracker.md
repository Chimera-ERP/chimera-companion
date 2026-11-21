# Issue tracker

Use GitHub Issues in `Chimera-ERP/chimera-companion` for tickets and specs. Before the first write, verify the target with `gh repo view --json nameWithOwner`.

Use `gh issue view` and `gh issue list` to read work. Publish with `gh issue create --body-file <file>`. Use GitHub sub-issues for parent and child tickets, and issue dependencies for blockers. If unavailable, record `Part of #<parent>` and `Blocked by: #<number>` in the issue body. Comment with the outcome before closing a ticket.

For `/wayfinder`, use one `wayfinder:map` issue and its child tickets. Claim the first unassigned child in map order whose blockers are closed. Record the result on the child and link it from the map.

**PRs as a request surface: no.**
