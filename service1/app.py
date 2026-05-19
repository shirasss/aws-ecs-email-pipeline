import json
import logging
import os
from datetime import datetime

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from flask import Flask, jsonify, request

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

app = Flask(__name__)

AWS_REGION = os.getenv("AWS_REGION", "us-east-2")
QUEUE_URL = os.getenv("QUEUE_URL")
TOKEN_PARAMETER_NAME = os.getenv("TOKEN_PARAMETER_NAME")

ssm_client = boto3.client("ssm", region_name=AWS_REGION)
sqs_client = boto3.client("sqs", region_name=AWS_REGION)

REQUIRED_FIELDS = [
    "email_subject",
    "email_sender",
    "email_timestream",
    "email_content",
]


class ValidationError(ValueError):
    """Client supplied a bad payload — maps to HTTP 400."""


class ServiceUnavailableError(RuntimeError):
    """A downstream AWS dependency (SSM/SQS) or required config is unavailable — maps to HTTP 503."""


def get_expected_token():
    if not TOKEN_PARAMETER_NAME:
        raise ServiceUnavailableError("Server misconfiguration: TOKEN_PARAMETER_NAME is required")

    try:
        response = ssm_client.get_parameter(Name=TOKEN_PARAMETER_NAME, WithDecryption=True)
        return response["Parameter"]["Value"]
    except (ClientError, BotoCoreError) as exc:
        logger.error("Failed to read auth token from SSM: %s", exc)
        raise ServiceUnavailableError("Unable to validate token") from exc


def validate_payload(payload):
    if not isinstance(payload, dict):
        raise ValidationError("Payload must be a JSON object")

    data = payload.get("data")
    if not isinstance(data, dict):
        raise ValidationError("Missing or invalid 'data' object")

    missing = [field for field in REQUIRED_FIELDS if field not in data or not str(data[field]).strip()]
    if missing:
        raise ValidationError(f"Missing or empty fields: {', '.join(missing)}")

    try:
        timestamp = int(data["email_timestream"])
        datetime.utcfromtimestamp(timestamp)
    except (ValueError, TypeError, OSError):
        raise ValidationError("email_timestream must be a valid Unix timestamp")

    token = payload.get("token")
    if not token:
        raise ValidationError("Missing token")

    return data, token


def publish_to_queue(data):
    if not QUEUE_URL:
        raise ServiceUnavailableError("Server misconfiguration: QUEUE_URL is required")

    try:
        response = sqs_client.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps(data),
            MessageAttributes={
                "source": {
                    "DataType": "String",
                    "StringValue": "ecs-assignment-api"
                }
            }
        )
        return response.get("MessageId")
    except (ClientError, BotoCoreError) as exc:
        logger.error("Failed to publish message to SQS: %s", exc)
        raise ServiceUnavailableError("Failed to enqueue message") from exc


@app.route("/healthz", methods=["GET"])
def health_check():
    return jsonify({"status": "ok!"}), 200


@app.route("/messages", methods=["POST"])
def create_message():
    try:
        payload = request.get_json(force=True, silent=True)
        if payload is None:
            raise ValidationError("Request body must be valid JSON")

        data, token = validate_payload(payload)
        expected_token = get_expected_token()

        if token != expected_token:
            logger.warning("Invalid token received")
            return jsonify({"error": "Invalid token"}), 401

        message_id = publish_to_queue(data)
        logger.info("Message enqueued successfully: %s", message_id)
        return jsonify({"message_id": message_id}), 202

    except ValidationError as exc:
        return jsonify({"error": str(exc)}), 400
    except ServiceUnavailableError as exc:
        return jsonify({"error": str(exc)}), 503
    except Exception:
        logger.exception("Unhandled error while processing request")
        return jsonify({"error": "Internal server error"}), 500


@app.errorhandler(404)
def not_found(_error):
    return jsonify({"error": "Not found"}), 404


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
