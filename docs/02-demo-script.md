# Fully Live Demo Script

Target: 20 minutes plus questions. Everything shown is running now.

## Before The Room

```bash
./scripts/live-demo.sh operator-tunnel
./scripts/live-demo.sh prepare
```

Keep the terminal, Slack approval channel, StrongDM Policy Monitor, and Grafana
incident open. Use at least an 18 point terminal font.

## 0:00 - The Problem

> Autonomous agents are already receiving production access. The useful
> question is not whether we trust the prompt. It is whether every action has an
> attributable identity, an enforceable boundary, and a record.

Show the `nightshift-agent` service account and the two database resources.
State the credential claim precisely: no reusable target database, Grafana, or
GitHub credential is exposed to the agent.

## 2:00 - Useful Access Without Raw PII

Run `trigger-agent.sh --ask` with a customer-impact question. Show the successful
terminal result and the redacted email/phone values.

> The query succeeded. StrongDM removed the protected result columns before the
> model received them. The agent still gets the answer it needs.

Show `policies/20-redact-pii.cedar`.

## 5:00 - Start The Incident

```bash
./scripts/live-demo.sh start
```

The command injects exactly 400 malformed orders, opens a real Grafana incident,
and dispatches Nightshift. Let the agent investigate without narrating every
step. It should read the incident, query the data, count the exact
predicate, and add its evidence to the incident timeline.

The agent then attempts its narrow update through standing access. StrongDM
denies it.

> The session is open, but this individual statement is refused. Standing
> access is useful for diagnosis and cannot write.

The agent submits one 15-minute request for
`pg-prod-shopfront-remediation`, including the incident ID, SQL, predicate, row
count, and rollback. It then stops.

## 10:00 - Human Approval, Bounded Remediation

Point to Slack and approve the request.

> The human approved temporary access to a separate remediation resource. They
> did not hand the agent a password and they did not remove the policy boundary.

```bash
./scripts/live-demo.sh resume
```

The same agent session connects the newly granted resource and executes the
previously justified update once. The driver independently verifies that zero
poisoned rows remain.

Show `policies/30-approve-remediation-write.cedar`.

> Even after approval, Cedar permits only UPDATE against public.orders through
> this resource. Customers, payments, DELETE, and multi-table writes remain
> unavailable. The resource grant expires after 15 minutes; standing read access
> remains.

## 14:00 - MCP Action Boundary

```bash
./scripts/live-demo.sh deny
```

The authenticated operator asks Nightshift to perform one explicit merge
control validation. The tool genuinely exists and the GitHub endpoint exposes
the full toolset. StrongDM denies `merge_pull_request`.

> The agent may investigate and propose. It may not merge. MCP policy is an
> explicit allowlist, so a newly added upstream tool fails closed.

Optionally ask it to close the Grafana incident and show the equivalent denial.

## 17:00 - Evidence

```bash
./scripts/live-demo.sh audit
```

Show the allowed reads, denied standing write, access request, approved
remediation, and denied MCP action in StrongDM. Do not claim fields the current
audit output does not show.

## Close

> The agent stayed useful throughout. StrongDM supplied identity, removed data
> the model should not see, denied standing writes, inserted a human boundary,
> constrained the approved action, governed MCP tools, and recorded the result.

Afterwards:

```bash
./scripts/live-demo.sh reset
```

If a phase fails, stop and show the last successful policy decision. Do not
debug live and do not claim an action succeeded when the verification command
did not prove it.
