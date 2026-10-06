# Slack Remediation Feedback

Runtime Slack messages report:

- Incident ID
- Environment
- Alarm name
- Remediation action
- Action result
- Desired and InService capacity
- Healthy/unhealthy ALB targets
- Automated remediation boundary
- Success or manual-review-required status

The runtime webhook is supplied through the sensitive Terraform variable `slack_webhook_url`. It is never stored in source control.
