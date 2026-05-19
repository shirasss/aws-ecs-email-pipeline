"""Unit tests for service2 (the SQS-to-S3 worker)."""

import json
import os

import pytest
from botocore.exceptions import ClientError

# Must be set before importing service2.app so the background poller does not
# start during unit tests and no real AWS calls are made.
os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("ENABLE_SQS_POLLER", "false")
os.environ.setdefault("AWS_REGION", "us-east-2")
os.environ.setdefault(
    "QUEUE_URL",
    "https://sqs.us-east-2.amazonaws.com/123456789012/test-queue",
)
os.environ.setdefault("BUCKET_NAME", "email-pipeline-test-bucket")
os.environ.setdefault("POLL_INTERVAL_SECONDS", "1")

import app as app_module
from app import (
    process_messages,
    safe_json_load,
    upload_message_to_s3,
)


class FakeS3Client:
    def __init__(self, raise_exc=None):
        self.raise_exc = raise_exc
        self.put_calls = []

    def put_object(self, **kwargs):
        self.put_calls.append(kwargs)
        if self.raise_exc is not None:
            raise self.raise_exc


class FakeSQSClient:
    def __init__(self, raise_exc_on_delete=None):
        self.raise_exc_on_delete = raise_exc_on_delete
        self.deleted_receipts = []

    def delete_message(self, **kwargs):
        if self.raise_exc_on_delete is not None:
            raise self.raise_exc_on_delete
        self.deleted_receipts.append(kwargs.get("ReceiptHandle"))


@pytest.fixture
def fake_clients(monkeypatch):
    fake_s3 = FakeS3Client()
    fake_sqs = FakeSQSClient()
    monkeypatch.setattr(app_module, "s3_client", fake_s3)
    monkeypatch.setattr(app_module, "sqs_client", fake_sqs)
    return fake_s3, fake_sqs


@pytest.fixture
def client():
    app_module.app.config["TESTING"] = True
    with app_module.app.test_client() as test_client:
        yield test_client


# ----- safe_json_load -----


def test_safe_json_load_valid_object():
    body = json.dumps({"email_subject": "Hello"})

    assert safe_json_load(body) == {"email_subject": "Hello"}


def test_safe_json_load_invalid_payload_wraps_raw():
    assert safe_json_load("not-json") == {"raw": "not-json"}


def test_safe_json_load_none_returns_raw():
    assert safe_json_load(None) == {"raw": None}


def test_safe_json_load_array_passthrough():
    body = json.dumps([1, 2, 3])

    assert safe_json_load(body) == [1, 2, 3]


# ----- upload_message_to_s3 -----


def test_upload_message_to_s3_writes_object(fake_clients):
    fake_s3, _ = fake_clients

    upload_message_to_s3({"email_subject": "Test"}, "msg-123")

    assert len(fake_s3.put_calls) == 1
    call = fake_s3.put_calls[0]
    assert call["Bucket"] == "email-pipeline-test-bucket"
    assert call["Key"].startswith("emails/msg-123-")
    assert call["Key"].endswith(".json")
    assert call["ContentType"] == "application/json"
    assert json.loads(call["Body"].decode("utf-8")) == {"email_subject": "Test"}


def test_upload_message_to_s3_missing_bucket_raises(fake_clients, monkeypatch):
    monkeypatch.setenv("BUCKET_NAME", "")

    with pytest.raises(RuntimeError, match="BUCKET_NAME is required"):
        upload_message_to_s3({"email_subject": "Test"}, "msg-123")


def test_upload_message_to_s3_s3_error_propagates(fake_clients):
    fake_s3, _ = fake_clients
    fake_s3.raise_exc = ClientError(
        {"Error": {"Code": "InternalError", "Message": "boom"}},
        "PutObject",
    )

    with pytest.raises(ClientError):
        upload_message_to_s3({"email_subject": "Test"}, "msg-123")


# ----- process_messages -----


def _msg(msg_id, body, receipt="rcpt-default"):
    return {
        "MessageId": msg_id,
        "ReceiptHandle": receipt,
        "Body": json.dumps(body) if isinstance(body, (dict, list)) else body,
    }


def test_process_messages_happy_path_uploads_and_deletes(fake_clients):
    fake_s3, fake_sqs = fake_clients
    messages = [
        _msg("m1", {"email_subject": "A"}, receipt="r1"),
        _msg("m2", {"email_subject": "B"}, receipt="r2"),
    ]

    process_messages(messages)

    assert len(fake_s3.put_calls) == 2
    assert fake_s3.put_calls[0]["Key"].startswith("emails/m1-")
    assert fake_s3.put_calls[1]["Key"].startswith("emails/m2-")
    assert fake_sqs.deleted_receipts == ["r1", "r2"]


def test_process_messages_s3_failure_does_not_delete_message(fake_clients):
    """If the upload fails, the SQS message must NOT be deleted so it returns to the queue
    and eventually flows to the DLQ after maxReceiveCount. This is the most important
    behavior to verify for at-least-once delivery semantics."""
    fake_s3, fake_sqs = fake_clients
    fake_s3.raise_exc = ClientError(
        {"Error": {"Code": "InternalError", "Message": "boom"}},
        "PutObject",
    )

    process_messages([_msg("m1", {"email_subject": "A"}, receipt="r1")])

    assert len(fake_s3.put_calls) == 1, "S3 was attempted once"
    assert fake_sqs.deleted_receipts == [], (
        "Message must remain on the queue when upload fails"
    )


def test_process_messages_mixed_success_and_failure(fake_clients):
    """One message fails, the other succeeds — only the successful one is deleted."""
    fake_s3, fake_sqs = fake_clients

    call_counter = {"n": 0}

    def selective_put_object(**kwargs):
        call_counter["n"] += 1
        fake_s3.put_calls.append(kwargs)
        if call_counter["n"] == 1:
            raise ClientError(
                {"Error": {"Code": "InternalError", "Message": "boom"}},
                "PutObject",
            )

    fake_s3.put_object = selective_put_object

    process_messages([
        _msg("m1", {"x": 1}, receipt="r1"),
        _msg("m2", {"x": 2}, receipt="r2"),
    ])

    assert fake_sqs.deleted_receipts == ["r2"], (
        "Only the message whose upload succeeded should be deleted"
    )


def test_process_messages_handles_non_json_body(fake_clients):
    """If a message body is not JSON, the worker should still process it
    (wrapping it as {'raw': ...}) rather than crashing the loop."""
    fake_s3, fake_sqs = fake_clients

    process_messages([
        {
            "MessageId": "m1",
            "ReceiptHandle": "r1",
            "Body": "this is not json",
        }
    ])

    assert len(fake_s3.put_calls) == 1
    body = json.loads(fake_s3.put_calls[0]["Body"].decode("utf-8"))
    assert body == {"raw": "this is not json"}
    assert fake_sqs.deleted_receipts == ["r1"]


def test_process_messages_empty_list_noop(fake_clients):
    fake_s3, fake_sqs = fake_clients

    process_messages([])

    assert fake_s3.put_calls == []
    assert fake_sqs.deleted_receipts == []


# ----- HTTP endpoints -----


def test_healthz_returns_ok(client):
    response = client.get("/healthz")

    assert response.status_code == 200
    assert response.get_json() == {"status": "ok"}


def test_status_returns_running_with_poll_interval(client):
    response = client.get("/status")

    assert response.status_code == 200
    body = response.get_json()
    assert body["status"] == "running"
    assert "poll_interval_seconds" in body
    assert isinstance(body["poll_interval_seconds"], int)


def test_unknown_route_returns_404(client):
    response = client.get("/nope")

    assert response.status_code == 404
