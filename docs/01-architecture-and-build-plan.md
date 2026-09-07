# Architecture And Build Plan

## Objective

Demonstrate a useful autonomous agent operating live while StrongDM controls
identity, data access, remediation escalation, MCP tools, revocation, and audit.
The demo must not depend on a recording or on the model making a spectacular
mistake.

## Trust Model

The agent VM contains an OpenAI key and a revocable StrongDM
service identity. It contains no reusable database, Grafana, or GitHub target
credentials. Compromise of the VM gives an attacker the agent's current
StrongDM mandate, not unrestricted target credentials.

The agent has no StrongDM SSH grant to the application hosts. Its executable
wrappers and `workspace/bin` directory are root-owned. Agent file writes are
limited to `memory/` and `sessions/`.

The agent VM is itself a StrongDM SSH resource named `agent-vm`. It has a fixed
private IP, accepts SSH only from the StrongDM relay, and receives only the
public half of a StrongDM-generated key. Operator port forwarding and shell
access are therefore brokered, authorised, and audited by StrongDM. SSM Session
Manager is the break-glass path when StrongDM is unavailable. SSH port
forwarding must also be enabled in the StrongDM organisation settings.

## Data Path

```text
Operator laptop -- StrongDM SSH --> agent-vm
                                      +-- forwards loopback shim/MCP for control

PicoClaw
  |
  +-- 127.0.0.1:5432 --> pg-prod-shopfront-read
  |                         standing grant, SQL reads only, PII redacted
  |
  +-- 127.0.0.1:5434 --> pg-prod-shopfront-remediation
  |                         absent by default, 15-minute approved grant
  |                         UPDATE public.orders only
  |
  +-- 127.0.0.1:10001 -> Grafana MCP
  |                         read and append evidence; no state changes
  |
  +-- 127.0.0.1:10002 -> GitHub MCP
                            read and propose; no merge, push, or delete
```

Both PostgreSQL StrongDM resources point to the disposable demo database. Their
separation is the access boundary: only the read resource is in the standing
agent role, while only the remediation resource is exposed by the workflow.
Cedar is an additional action boundary on both resources.

## Policy Composition

- `00-baseline.cedar` permits agent connection and reads on the read resource,
  and explicitly permits the human operator role within its existing grants.
- `10-agents-are-readonly.cedar` forbids service-account writes on production.
  Its only exception is the exact Nightshift identity updating only
  `public.orders` through the remediation resource.
- `20-redact-pii.cedar` applies `@redact` to the tested email and phone result
  columns using separate matching permits and caps customer results at 100 rows.
- `30-approve-remediation-write.cedar` permits only the narrow remediation
  update. Human approval is handled by the access workflow, not inline policy.
- `40-mcp-tool-limits.cedar` explicitly permits required tools and forbids
  incident-state and code-merge actions.

Cedar remains default-deny. Every intended action needs a matching permit, and
any matching forbid wins. Resource grants are separate prerequisites and do not
replace policy.

## Live Sequence

1. Strict preflight proves the read path, redaction, hard denial, immutable
   wrappers, MCP tool inventory, clean data, clean incident state, and open PR.
2. Fault injection marks exactly 400 orders as malformed.
3. A real Grafana IRM incident is opened.
4. Nightshift investigates and attempts one write through standing access.
5. StrongDM denies it. The agent requests the remediation resource with a full
   justification and stops.
6. A human approves in Slack.
7. The same agent session connects the remediation resource and retries exactly
   the justified update once.
8. The driver verifies zero poisoned rows remain.
9. The agent attempts one explicitly requested MCP merge validation and StrongDM
   denies it.
10. The presenter shows StrongDM query, activity, and access-request audit data.

## Runtime Gates

Before customer use, confirm in the actual organisation:

- Policy enforcement and required entitlements are enabled.
- No unmanaged broad permit changes the intended policy composition.
- PostgreSQL `select`, `with`, and `update` actions match the observed requests.
- `qualifiedWriteTables` reports exactly `public.orders` for the remediation.
- Both PII redactions apply to the agent's real query shapes.
- Every MCP action string matches the pinned servers' observed tool names.
- The Slack approval integration delivers and approves the access request.
- Access expiry and role revocation have the latency shown in the talk track.

`terraform apply` proves only that the API accepted the policy text. The strict
preflight and a full rehearsal prove runtime behaviour.

Redaction is result-column enforcement, not general SQL data-flow analysis. The
demo preflight covers direct and aliased result columns; it does not claim that
arbitrary derived expressions cannot encode source data. Use database-native
views or column privileges when that stronger guarantee is required.

The remediation policy is action-and-table scoped, not predicate scoped. The
live driver requires one canonical audited statement, but Cedar does not bind a
workflow approval to one SQL predicate or execution. Use a narrowly privileged
stored procedure or database-native remediation identity when that stronger
production boundary is required.
