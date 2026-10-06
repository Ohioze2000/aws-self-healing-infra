import json
import logging
import os
import time
import urllib.request

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

elbv2 = boto3.client("elbv2")
autoscaling = boto3.client("autoscaling")
ec2 = boto3.client("ec2")
ssm = boto3.client("ssm")
ddb = boto3.client("dynamodb")

SLACK_WEBHOOK_URL = os.environ["SLACK_WEBHOOK_URL"]
TARGET_GROUP_ARN = os.environ["TARGET_GROUP_ARN"]
ASG_NAME = os.environ["ASG_NAME"]
ENV_PREFIX = os.environ.get("ENV_PREFIX", "prod")
MAX_CAPACITY = int(os.environ.get("MAX_CAPACITY", "4"))
INCIDENT_TABLE_NAME = os.environ["INCIDENT_TABLE_NAME"]
VERIFICATION_DELAY = int(os.environ.get("VERIFICATION_DELAY_SECONDS", "60"))


def update_incident(incident_id, status, **fields):
    names = {"#s": "status"}
    values = {":s": {"S": status}}
    updates = ["#s = :s"]
    for key, value in fields.items():
        names[f"#{key}"] = key
        if isinstance(value, bool):
            values[f":{key}"] = {"BOOL": value}
        elif isinstance(value, (int, float)):
            values[f":{key}"] = {"N": str(value)}
        else:
            values[f":{key}"] = {"S": str(value)}
        updates.append(f"#{key} = :{key}")
    ddb.update_item(
        TableName=INCIDENT_TABLE_NAME,
        Key={"incident_id": {"S": incident_id}},
        UpdateExpression="SET " + ", ".join(updates),
        ExpressionAttributeNames=names,
        ExpressionAttributeValues=values,
    )


def alarm(event):
    return event.get("alarm", {})


def action_for_alarm(alarm_name):
    if "High-CPU" in alarm_name:
        return "scale_out"
    if "High-Memory" in alarm_name:
        return "scale_out"
    if "High-Disk" in alarm_name:
        return "disk_cleanup"
    if "App-Log-Errors" in alarm_name:
        return "replace_or_scale"
    if "ALB-Unhealthy-Targets" in alarm_name:
        return "replace_unhealthy"
    return "observe_only"


def asg_state():
    group = autoscaling.describe_auto_scaling_groups(
        AutoScalingGroupNames=[ASG_NAME]
    )["AutoScalingGroups"][0]
    instances = [
        i["InstanceId"]
        for i in group.get("Instances", [])
        if i.get("LifecycleState") == "InService"
    ]
    return group, instances


def unhealthy_targets():
    descriptions = elbv2.describe_target_health(
        TargetGroupArn=TARGET_GROUP_ARN
    ).get("TargetHealthDescriptions", [])
    return [
        d for d in descriptions
        if d.get("TargetHealth", {}).get("State") == "unhealthy"
    ]


def replace_instance(target, incident_id):
    instance_id = target["Target"]["Id"]
    elbv2.deregister_targets(
        TargetGroupArn=TARGET_GROUP_ARN,
        Targets=[{"Id": instance_id}],
    )
    autoscaling.detach_instances(
        AutoScalingGroupName=ASG_NAME,
        InstanceIds=[instance_id],
        ShouldDecrementDesiredCapacity=False,
    )
    ec2.create_tags(
        Resources=[instance_id],
        Tags=[
            {"Key": "Incident_Status", "Value": "Quarantined"},
            {"Key": "Incident_ID", "Value": incident_id},
        ],
    )
    return f"Replaced unhealthy instance {instance_id}; desired capacity preserved."


def scale_out(reason):
    group, _ = asg_state()
    desired = int(group["DesiredCapacity"])
    maximum = min(int(group["MaxSize"]), MAX_CAPACITY)
    if desired >= maximum:
        return False, f"Scale-out blocked at remediation ceiling {maximum}: {reason}"
    autoscaling.set_desired_capacity(
        AutoScalingGroupName=ASG_NAME,
        DesiredCapacity=desired + 1,
        HonorCooldown=True,
    )
    return True, f"Scaled desired capacity from {desired} to {desired + 1}: {reason}"


def disk_cleanup(incident_id):
    _, instances = asg_state()
    if not instances:
        return False, "Disk cleanup skipped: no InService instances."
    response = ssm.send_command(
        InstanceIds=instances,
        DocumentName="AWS-RunShellScript",
        Parameters={
            "commands": [
                "sudo journalctl --vacuum-time=3d",
                "sudo docker image prune -af",
                "df -h /",
            ]
        },
        MaxConcurrency="1",
        MaxErrors="1",
        CloudWatchOutputConfig={
            "CloudWatchOutputEnabled": True,
            "CloudWatchLogGroupName": f"/aws/ssm/{ENV_PREFIX}/remediation",
        },
    )
    return True, f"Started bounded disk cleanup command {response['Command']['CommandId']} for {len(instances)} instance(s)."


def remediate(event):
    incident_id = event["incident_id"]
    name = alarm(event).get("AlarmName", "UnknownAlarm")
    action = action_for_alarm(name)

    if action == "replace_unhealthy":
        targets = unhealthy_targets()
        if not targets:
            return {"action": action, "changed": False, "summary": "No unhealthy ALB target found during diagnosis."}
        return {"action": action, "changed": True, "summary": replace_instance(targets[0], incident_id)}

    if action == "replace_or_scale":
        targets = unhealthy_targets()
        if targets:
            return {"action": action, "changed": True, "summary": replace_instance(targets[0], incident_id)}
        changed, summary = scale_out("application error spike with no unhealthy target")
        return {"action": action, "changed": changed, "summary": summary}

    if action == "scale_out":
        changed, summary = scale_out(name)
        return {"action": action, "changed": changed, "summary": summary}

    if action == "disk_cleanup":
        changed, summary = disk_cleanup(incident_id)
        return {"action": action, "changed": changed, "summary": summary}

    return {"action": action, "changed": False, "summary": "No automated remediation rule matched this alarm."}


def verify():
    group, instances = asg_state()
    targets = elbv2.describe_target_health(TargetGroupArn=TARGET_GROUP_ARN).get("TargetHealthDescriptions", [])
    healthy = [d for d in targets if d.get("TargetHealth", {}).get("State") == "healthy"]
    unhealthy = [d for d in targets if d.get("TargetHealth", {}).get("State") == "unhealthy"]
    desired = int(group["DesiredCapacity"])
    minimum = int(group["MinSize"])
    maximum = min(int(group["MaxSize"]), MAX_CAPACITY)
    capacity_ok = len(instances) >= minimum and desired <= maximum
    healthy_ok = len(unhealthy) == 0 and len(healthy) >= minimum
    return {
        "success": bool(capacity_ok and healthy_ok),
        "desired": desired,
        "in_service": len(instances),
        "healthy_targets": len(healthy),
        "unhealthy_targets": len(unhealthy),
        "capacity_boundary": maximum,
    }


def slack(text, success):
    payload = json.dumps({"text": text}).encode("utf-8")
    request = urllib.request.Request(
        SLACK_WEBHOOK_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        if response.status >= 300:
            raise RuntimeError(f"Slack webhook returned HTTP {response.status}")


def lambda_handler(event, context):
    incident_id = event["incident_id"]
    name = alarm(event).get("AlarmName", "UnknownAlarm")
    update_incident(incident_id, "REMEDIATING", action=action_for_alarm(name))

    try:
        remediation = remediate(event)
        update_incident(
            incident_id,
            "WAITING_FOR_RECOVERY",
            remediation_summary=remediation["summary"],
            remediation_changed=remediation["changed"],
        )
        time.sleep(VERIFICATION_DELAY)
        verification = verify()
        success = verification["success"]
        status = "SUCCESS" if success else "FAILED / MANUAL REVIEW REQUIRED"
        update_incident(
            incident_id,
            "SUCCEEDED" if success else "FAILED",
            verification=json.dumps(verification),
        )
        text = (
            f"*{('✅' if success else '🚨')} SELF-HEALING {status}*\n"
            f"*Incident:* `{incident_id}`\n"
            f"*Environment:* `{ENV_PREFIX}`\n"
            f"*Alarm:* `{name}`\n"
            f"*Action:* {remediation['summary']}\n"
            f"*Verification:* desired={verification['desired']}, in_service={verification['in_service']}, "
            f"healthy_targets={verification['healthy_targets']}, unhealthy_targets={verification['unhealthy_targets']}\n"
            f"*Boundary:* max remediation capacity `{verification['capacity_boundary']}`"
        )
        slack(text, success)
        return {"incident_id": incident_id, "status": status}
    except Exception as exc:
        logger.exception("Remediation failed for %s", incident_id)
        try:
            update_incident(incident_id, "FAILED", error=str(exc))
        finally:
            slack(
                f"*🚨 SELF-HEALING FAILED*\n*Incident:* `{incident_id}`\n*Environment:* `{ENV_PREFIX}`\n*Alarm:* `{name}`\n*Error:* `{exc}`",
                False,
            )
        raise
