# Operator Scripts

Run these from the operator laptop. `AGENT_SSH_RESOURCE` identifies the
StrongDM-managed agent VM;
`live-demo.sh operator-tunnel` forwards only the loopback ports needed for
operator control and preflight. The agent's StrongDM traffic is independent.
StrongDM generates the SSH configuration and key material; no EC2 key pair or
public SSH ingress is used.

```bash
./scripts/live-demo.sh operator-tunnel
./scripts/live-demo.sh prepare
./scripts/live-demo.sh start
# approve the StrongDM request in Slack
./scripts/live-demo.sh resume
./scripts/live-demo.sh deny
./scripts/live-demo.sh audit
./scripts/live-demo.sh reset
```

`prepare` runs a fail-closed reset and preflight. `start` injects a deterministic
400-row fault, creates a real Grafana incident, and waits for the autonomous
agent to submit its remediation request. `resume` continues the same PicoClaw
session after approval and checks the database outcome. `deny` performs one
explicit MCP merge-policy test. `audit` displays StrongDM evidence from the
start of the run.

Supporting scripts:

- `verify.sh`: strict live-demo invariants
- `reset.sh`: restore data, close incidents, clear agent state, disconnect remediation
- `break-it.sh`: deterministic fault injection
- `trigger-agent.sh`: create or continue one PicoClaw job
- `common.sh`: shared StrongDM, Grafana, database, MCP, and shim helpers

The human operator connection is separate from the agent:

```bash
sdm connect pg-prod-shopfront-read 5433
```

The agent has standing read access on 5432. Its remediation endpoint on 5434
appears only after the human-approved workflow grant.
