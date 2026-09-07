// Explicit allowlists fail closed when an MCP server adds or renames a tool.
// Reconcile these observed tool names whenever a pinned server image changes.

permit (
  principal == StrongDM::Account::"${agent_account_id}",
  action in [
    MCP::Action::"initialize",
    MCP::Action::"notifications/initialized",
    MCP::Action::"tools/list",
    MCP::Action::"ping",
    MCP::Action::"sse_stream",
    MCP::Action::"list_incidents",
    MCP::Action::"get_incident",
    MCP::Action::"list_datasources",
    MCP::Action::"add_activity_to_incident",
    MCP::Action::"list_alert_groups",
    MCP::Action::"get_alert_group",
    MCP::Action::"query_prometheus",
    MCP::Action::"get_current_oncall_users",
    MCP::Action::"list_oncall_schedules"
  ],
  resource in StrongDM::Resource::"${grafana_mcp_resource_id}"
);

permit (
  principal == StrongDM::Account::"${agent_account_id}",
  action in [
    MCP::Action::"initialize",
    MCP::Action::"notifications/initialized",
    MCP::Action::"tools/list",
    MCP::Action::"ping",
    MCP::Action::"sse_stream",
    MCP::Action::"get_file_contents",
    MCP::Action::"list_pull_requests",
    MCP::Action::"create_issue",
    MCP::Action::"create_pull_request"
  ],
  resource in StrongDM::Resource::"${github_mcp_resource_id}"
);

@error("Autonomous agents may add evidence to an incident but may not change incident or alert state.")
forbid (
  principal == StrongDM::Account::"${agent_account_id}",
  action == MCP::Action::"create_incident",
  resource in StrongDM::Resource::"${grafana_mcp_resource_id}"
);

@error("Autonomous agents may propose changes but may not merge, push, or delete code.")
forbid (
  principal == StrongDM::Account::"${agent_account_id}",
  action in [
    MCP::Action::"merge_pull_request",
    MCP::Action::"push_files",
    MCP::Action::"delete_file"
  ],
  resource in StrongDM::Resource::"${github_mcp_resource_id}"
);
