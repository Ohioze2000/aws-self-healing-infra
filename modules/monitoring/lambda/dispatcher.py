import hashlib
import json
import logging
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ddb = boto3.client("dynamodb")
lambda_client = boto3.client("lambda")
TABLE_NAME = os.environ["INCIDENT_TABLE_NAME"]
WORKER_FUNCTION_NAME = os.environ["WORKER_FUNCTION_NAME"]
ENV_PREFIX = os.environ.get("ENV_PREFIX", "prod")
TTL_SECONDS = int(os.environ.get("INCIDENT_TTL_SECONDS", "86400"))


def _incident_id(alarm_name, state_change_time):
    raw = f"{alarm_name}|{state_change_time}"
    return "INC-" + hashlib.sha256(raw.encode("utf-8")).hexdigest()[:12].upper()


def _ttl():
    return int(datetime.now(timezone.utc).timestamp()) + TTL_SECONDS


def lambda_handler(event, context):
    accepted = []
    for record in event.get("Records", []):
        message = json.loads(record["Sns"]["Message"])
        alarm_name = message.get("AlarmName", "UnknownAlarm")
        state = message.get("NewStateValue", "UNKNOWN")
        state_change_time = message.get("StateChangeTime", context.aws_request_id)

        if state != "ALARM":
            logger.info("Ignoring non-ALARM state for %s: %s", alarm_name, state)
            continue

        incident_id = _incident_id(alarm_name, state_change_time)
        item = {
            "incident_id": {"S": incident_id},
            "alarm_name": {"S": alarm_name},
            "state_change_time": {"S": state_change_time},
            "environment": {"S": ENV_PREFIX},
            "status": {"S": "RECEIVED"},
            "created_at": {"S": datetime.now(timezone.utc).isoformat()},
            "expires_at": {"N": str(_ttl())},
            "alarm": {"S": json.dumps(message)},
        }

        try:
            ddb.put_item(
                TableName=TABLE_NAME,
                Item=item,
                ConditionExpression="attribute_not_exists(incident_id)",
            )
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
                logger.info("Duplicate incident ignored: %s", incident_id)
                continue
            raise

        payload = {
            "incident_id": incident_id,
            "environment": ENV_PREFIX,
            "alarm": message,
        }
        lambda_client.invoke(
            FunctionName=WORKER_FUNCTION_NAME,
            InvocationType="Event",
            Payload=json.dumps(payload).encode("utf-8"),
        )
        accepted.append(incident_id)

    return {"accepted_incidents": accepted}
