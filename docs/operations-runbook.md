# Operations Runbook

## Normal health checks

Check:

- ALB target health.
- ASG desired/in-service capacity.
- CloudWatch CPU, disk, application-error, and unhealthy-host alarms.
- Application availability through the HTTPS endpoint.
- CloudWatch application/bootstrap logs.
- Recent remediation Lambda executions.

## Unhealthy instance remediation

The intended automated flow is:

1. CloudWatch detects the configured unhealthy-target condition.
2. SNS invokes the remediation Lambda.
3. Lambda inspects ALB target health.
4. An unhealthy target is deregistered from the target group.
5. The instance is detached from the ASG without reducing desired capacity.
6. The ASG launches replacement capacity as required.
7. The quarantined instance is tagged for incident tracking.
8. Slack receives the remediation status when configured.

## If automated remediation fails

1. Check the remediation Lambda logs in CloudWatch.
2. Confirm the Lambda execution role still has the required permissions.
3. Check the target group's health reason for the affected instance.
4. Check ASG activity history for launch/termination errors.
5. Verify subnet routing/NAT availability for private instances.
6. Check EC2 bootstrap and application logs.
7. Correct the underlying failure before manually removing production capacity.

## Rollback considerations

For Terraform changes, use the HCP Terraform run history and a reviewed plan to determine the appropriate rollback. Do not manually modify resources simply to make Terraform state appear consistent.

## Intentional destruction

The repository's destroy workflow is protected by an explicit `DESTROY` confirmation and production-environment controls. ALB deletion protection is enabled by default and is only disabled as part of an intentional teardown workflow.
