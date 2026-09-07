# Nightshift Agent

PicoClaw runs as the `nightshift-agent` StrongDM service identity.

Standing connections:

- `127.0.0.1:5432`: read-only PostgreSQL resource
- `127.0.0.1:10001`: Grafana MCP
- `127.0.0.1:10002`: GitHub MCP

The remediation resource is deliberately not connected at bootstrap. After a
human approves the 15-minute workflow request, the agent connects it on 5434.

Operator access to this host is also brokered by StrongDM through the separate
`agent-vm` SSH resource. The VM has no public SSH ingress or EC2 key pair.

The agent doctrine exposes these expected commands:

- `bin/db-query.sh`
- `bin/sdm-request-access.sh`
- `sdm status`

`workspace/bin`, `AGENT.md`, and `HEARTBEAT.md` are root-owned. PicoClaw may
write only to `workspace/memory` and `workspace/sessions`. There is no general
SSH wrapper and the StrongDM role contains no application-server SSH resources.

Bootstrap:

```bash
sudo OPENAI_API_KEY='...' \
  ./agent/bootstrap.sh
```

The host still contains model and StrongDM identity credentials. The
security claim is specifically that reusable target database, Grafana, and
GitHub credentials are not exposed to the agent.
