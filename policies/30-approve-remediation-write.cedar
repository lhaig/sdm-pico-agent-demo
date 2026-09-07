// Human approval is handled by the time-bound StrongDM access workflow. This
// policy independently bounds what the approved remediation resource can do.

permit (
  principal == StrongDM::Account::"${agent_account_id}",
  action == SQL::Action::"update",
  resource in StrongDM::Resource::"${remediation_resource_id}"
) when {
  context has sql &&
  context.sql has qualifiedWriteTables &&
  context.sql.qualifiedWriteTables == ["public.orders"]
};
