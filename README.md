# Project Nightshift

**A fully live autonomous incident response demo governed by StrongDM.**

Nightshift investigates a real, deterministic Shopfront incident through a
first-class StrongDM service identity. It can read useful production data with
PII redacted, but it cannot write through standing access. A human can approve
15 minutes of access to a separate remediation resource, where Cedar still
limits the agent to `UPDATE public.orders`. MCP policy lets the agent add
evidence while preventing it from closing incidents or merging code.

No recording or external customer footage is part of the demo.

## Live Flow

```bash
./scripts/live-demo.sh operator-tunnel # StrongDM SSH control; agent access is independent
./scripts/live-demo.sh prepare  # strict reset and preflight
./scripts/live-demo.sh start    # inject fault, open incident, autonomous triage
# approve the remediation request in Slack
./scripts/live-demo.sh resume   # approved remediation and verification
./scripts/live-demo.sh deny     # prove the MCP merge boundary
./scripts/live-demo.sh audit    # show queries, activity, and access requests
./scripts/live-demo.sh reset
```

## What It Proves

1. The agent has no reusable target-system credentials.
2. Every action is attributable to a dedicated machine identity.
3. The tested email and phone result columns are redacted before they reach the model.
4. Standing production access cannot write.
5. Human approval grants a separate remediation resource for 15 minutes.
6. Approval does not grant arbitrary write access; Cedar still limits the action and table.
7. MCP tools are explicitly allowlisted, and dangerous state changes are denied.
8. Queries, policy decisions, and access requests are available for audit.

## Read Next

- **First-time setup:** [`docs/03-runbook.md`](docs/03-runbook.md)
- [`docs/01-architecture-and-build-plan.md`](docs/01-architecture-and-build-plan.md)
- [`docs/02-demo-script.md`](docs/02-demo-script.md)
- [`terraform/README.md`](terraform/README.md)

The environment is disposable demo infrastructure, not a production reference
architecture. Validate the exact MCP action names and Cedar decisions in the
target StrongDM organisation before presenting.
