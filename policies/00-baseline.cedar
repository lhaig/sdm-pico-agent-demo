// Standing access for the autonomous agent is read-only. Resource grants still
// decide which concrete resources each principal can reach.

permit (
  principal in StrongDM::Role::"${ai_agents_role_id}",
  action == StrongDM::Action::"connect",
  resource
) when {
  resource in [
    StrongDM::Resource::"${read_resource_id}",
    StrongDM::Resource::"${remediation_resource_id}",
    StrongDM::Resource::"${grafana_mcp_resource_id}",
    StrongDM::Resource::"${github_mcp_resource_id}"
  ]
};

permit (
  principal in StrongDM::Role::"${ai_agents_role_id}",
  action in [
    SQL::Action::"select",
    SQL::Action::"with",
    SQL::Action::"values",
    SQL::Action::"show",
    SQL::Action::"set"
  ],
  resource in StrongDM::Resource::"${read_resource_id}"
) when {
  context has sql &&
  context.sql has tables &&
  !context.sql.tables.contains("customers")
};

permit (
  principal == StrongDM::Account::"${agent_account_id}",
  action == StrongDM::Resource::Action::"requestAccess",
  resource in StrongDM::Resource::"${remediation_resource_id}"
);

permit (
  principal == StrongDM::Account::"${agent_account_id}",
  action in [
    StrongDM::AccessRequest::Action::"create",
    StrongDM::AccessRequest::Action::"list"
  ],
  resource
);

// Human operators remain constrained by their StrongDM grants, but policy does
// not block the setup, fault-injection, reset, or approval work they perform.
permit (
  principal in StrongDM::Role::"${sre_oncall_role_id}",
  action,
  resource
);
