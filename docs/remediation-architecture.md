# Bounded Remediation Architecture — DynamoDB State

## Flow

CloudWatch → SNS → Dispatcher Lambda → DynamoDB incident state → Remediation Worker Lambda → Verify → Slack

## Why DynamoDB

DynamoDB is used as the durable incident-state and idempotency store rather than AWS Step Functions. The dispatcher creates one incident record using a conditional `PutItem`; repeated delivery of the same alarm event therefore does not create a second remediation record. AWS documents conditional writes as a mechanism for idempotent write behavior.

## Remediation boundaries

- CPU and memory: increase desired capacity by one, capped by `remediation_max_capacity`.
- ALB unhealthy target: deregister and detach one unhealthy instance while preserving desired capacity so the ASG replaces it.
- Disk: issue bounded SSM cleanup against InService instances.
- Application errors: replace an unhealthy target when present; otherwise bounded scale-out.
- Unknown conditions: observe only.

## Incident lifecycle

1. Dispatcher receives an SNS CloudWatch alarm.
2. Dispatcher derives a deterministic incident ID from alarm name and state-change time.
3. DynamoDB conditional `PutItem` creates the incident only if it does not already exist.
4. Dispatcher invokes the worker asynchronously.
5. Worker records `REMEDIATING`, performs the bounded action, and records `WAITING_FOR_RECOVERY`.
6. Worker waits for the configured verification delay, checks ASG capacity and ALB target health, then records `SUCCEEDED` or `FAILED`.
7. Worker sends structured Slack feedback.
8. DynamoDB TTL removes expired incident records.

## Operational trade-off

This design intentionally uses Lambda for the orchestration logic and DynamoDB for durable state/idempotency. It avoids a Step Functions state machine, but the verification delay occurs inside the worker Lambda, so the configured delay must remain within the Lambda timeout budget. For longer workflows, a scheduler or Step Functions would be a better orchestration mechanism.
