// Service accounts cannot write to production. The sole exception is the
// Nightshift identity updating only public.orders through the separately
// granted remediation resource. Policy 30 supplies the matching permit.

@error("Autonomous agents cannot write through standing production access. For the approved public.orders remediation only, request pg-prod-shopfront-remediation for 15 minutes; otherwise stop and hand off to a human.")
forbid (
  principal,
  action,
  resource
) when {
  principal.accountType == "service" &&
  context has sql &&
  context.sql has writeTables &&
  !context.sql.writeTables.isEmpty() &&
  resource has sdm &&
  resource.sdm.hasTag("env") &&
  resource.sdm.getTag("env") == "prod"
} unless {
  principal == StrongDM::Account::"${agent_account_id}" &&
  action == SQL::Action::"update" &&
  resource in StrongDM::Resource::"${remediation_resource_id}" &&
  context.sql has qualifiedWriteTables &&
  context.sql.qualifiedWriteTables == ["public.orders"]
};
