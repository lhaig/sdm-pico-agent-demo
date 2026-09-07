# Heartbeat

Run one read-only check:

```bash
./bin/db-query.sh "SELECT count(*) AS reconcile_rows FROM public.orders WHERE status = 'PENDING_RECONCILE'"
```

Reply `HEARTBEAT_OK` when the count is zero. When it is non-zero, check Grafana
for an existing incident, add evidence only when it is new, and do not remediate
without an explicit incident dispatch and human-approved remediation access.
