import json
import logging
import os
import threading
import time

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from flask import Flask, jsonify

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

AWS_REGION = os.getenv("AWS_REGION", "us-east-2")
QUEUE_URL = os.getenv("QUEUE_URL")
POLL_INTERVAL_SECONDS = int(os.getenv("POLL_INTERVAL_SECONDS", "10"))
SQS_WAIT_SECONDS = min(20, max(0, POLL_INTERVAL_SECONDS))

app = Flask(__name__)

sqs_client = boto3.client("sqs", region_name=AWS_REGION)
s3_client = boto3.client("s3", region_name=AWS_REGION)


def safe_json_load(body):
    try:
        return json.loads(body)
    except (TypeError, ValueError):
        return {"raw": body}


def upload_message_to_s3(message_body, message_id):
    bucket_name = os.getenv("BUCKET_NAME")
    if not bucket_name:
        raise RuntimeError("BUCKET_NAME is required")
    key = f"emails/{message_id}.json"
    logger.info("Uploading message %s to s3://%s/%s", message_id, bucket_name, key)
    s3_client.put_object(
        Bucket=bucket_name,
        Key=key,
        Body=json.dumps(message_body).encode("utf-8"),
        ContentType="application/json",
    )


def delete_message_from_queue(receipt_handle):
    if not receipt_handle:
        return
    sqs_client.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=receipt_handle)


def process_messages(messages):
    for message in messages:
        receipt_handle = message.get("ReceiptHandle")
        message_id = message.get("MessageId")
        body = safe_json_load(message.get("Body"))

        try:
            upload_message_to_s3(body, message_id)
            delete_message_from_queue(receipt_handle)
            logger.info("Message %s processed and deleted", message_id)
        except (ClientError, BotoCoreError, RuntimeError):
            logger.exception("Failed to process message %s", message_id)


def poll_sqs_loop():
    if not QUEUE_URL:
        logger.error("QUEUE_URL is required for worker startup")
        return

    logger.info("Starting SQS poller (interval=%ss, wait=%ss)", POLL_INTERVAL_SECONDS, SQS_WAIT_SECONDS)

    while True:
        try:
            response = sqs_client.receive_message(
                QueueUrl=QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=SQS_WAIT_SECONDS,
                VisibilityTimeout=60,
            )

            messages = response.get("Messages", [])
            if messages:
                logger.info("Received %d messages", len(messages))
                process_messages(messages)
        except (ClientError, BotoCoreError):
            logger.exception("Error polling SQS queue")

        time.sleep(POLL_INTERVAL_SECONDS)


@app.route("/healthz", methods=["GET"])
def health_check():
    return jsonify({"status": "ok"}), 200


@app.route("/status", methods=["GET"])
def status():
    return jsonify({
        "status": "running",
        "poll_interval_seconds": POLL_INTERVAL_SECONDS,
    }), 200


_poller_started = False
_poller_lock = threading.Lock()


def start_sqs_poller():
    global _poller_started
    if os.getenv("ENABLE_SQS_POLLER", "true").lower() in ("0", "false", "no"):
        return
    with _poller_lock:
        if _poller_started:
            return
        _poller_started = True
        threading.Thread(target=poll_sqs_loop, daemon=True, name="sqs-poller").start()


start_sqs_poller()
