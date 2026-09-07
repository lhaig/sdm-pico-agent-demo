// Multiple redactions require separate matching permits. StrongDM aggregates
// the annotations from both permit reasons before returning the result.

@redact("email")
@maxrows("100")
permit (
  principal in StrongDM::Role::"${ai_agents_role_id}",
  action in [SQL::Action::"select", SQL::Action::"with"],
  resource in StrongDM::Resource::"${read_resource_id}"
) when {
  context has sql &&
  context.sql has tables &&
  context.sql.tables.contains("customers")
};

@redact("phone")
permit (
  principal in StrongDM::Role::"${ai_agents_role_id}",
  action in [SQL::Action::"select", SQL::Action::"with"],
  resource in StrongDM::Resource::"${read_resource_id}"
) when {
  context has sql &&
  context.sql has tables &&
  context.sql.tables.contains("customers")
};
