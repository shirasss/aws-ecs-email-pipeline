import json
import os

import pytest
from botocore.exceptions import ClientError

os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("AWS_REGION", "us-east-2")
os.environ.setdefault(
    "QUEUE_URL",
    "https://sqs.us-east-2.amazonaws.com/123456789012/test-queue",
)
os.environ.setdefault("TOKEN_PARAMETER_NAME", "/email-pipeline/test-token")

import app as app_module
from app import validate_payload


# Fake test-only token. The real token lives in SSM Parameter Store and must
# proves that "whatever SSM returns == whatever the client sent" → 202.
TEST_TOKEN = "test-token-not-a-real-secret"  # pragma: allowlist secret

VALID_PAYLOAD = {
    "data": {
        "email_subject": "Happy new year!",
        "email_sender": "John doe",
        "email_timestream": "1693561101",
        "email_content": "Just want to say... Happy new year!!!",
    },
    "token": TEST_TOKEN,
}


# ---------- validate_payload (pure function) ----------


def test_validate_payload_success():
    data, token = validate_payload(VALID_PAYLOAD)

    assert data["email_subject"] == "Happy new year!"
    assert token == TEST_TOKEN


def test_validate_payload_rejects_non_dict():
    with pytest.raises(ValueError, match="JSON object"):
        validate_payload(["not", "a", "dict"])


def test_validate_payload_rejects_missing_data():
    with pytest.raises(ValueError, match="data"):
        validate_payload({"token": "x"})


@pytest.mark.parametrize(
    "missing_field",
    ["email_subject", "email_sender", "email_timestream", "email_content"],
)
def test_validate_payload_rejects_each_missing_field(missing_field):
    payload = json.loads(json.dumps(VALID_PAYLOAD))
    del payload["data"][missing_field]

    with pytest.raises(ValueError, match=missing_field):
        validate_payload(payload)


def test_validate_payload_rejects_empty_string_field():
    payload = json.loads(json.dumps(VALID_PAYLOAD))
    payload["data"]["email_sender"] = "   "

    with pytest.raises(ValueError, match="email_sender"):
        validate_payload(payload)


def test_validate_payload_rejects_non_numeric_timestamp():
    payload = json.loads(json.dumps(VALID_PAYLOAD))
    payload["data"]["email_timestream"] = "not-a-number"

    with pytest.raises(ValueError, match="email_timestream"):
        validate_payload(payload)


def test_validate_payload_rejects_missing_token():
    payload = json.loads(json.dumps(VALID_PAYLOAD))
    del payload["token"]

    with pytest.raises(ValueError, match="token"):
        validate_payload(payload)


# ---------- HTTP endpoint integration with mocked AWS ----------


class FakeSSMClient:
    def __init__(self, token_value=TEST_TOKEN, raise_exc=None):
        self.token_value = token_value
        self.raise_exc = raise_exc
        self.calls = []

    def get_parameter(self, **kwargs):
        self.calls.append(kwargs)
        if self.raise_exc is not None:
            raise self.raise_exc
        return {"Parameter": {"Value": self.token_value}}


class FakeSQSClient:
    def __init__(self, raise_exc=None):
        self.raise_exc = raise_exc
        self.sent = []

    def send_message(self, **kwargs):
        if self.raise_exc is not None:
            raise self.raise_exc
        self.sent.append(kwargs)
        return {"MessageId": "fake-message-id-123"}


@pytest.fixture
def fake_aws(monkeypatch):
    fake_ssm = FakeSSMClient()
    fake_sqs = FakeSQSClient()
    monkeypatch.setattr(app_module, "ssm_client", fake_ssm)
    monkeypatch.setattr(app_module, "sqs_client", fake_sqs)
    return fake_ssm, fake_sqs


@pytest.fixture
def client():
    app_module.app.config["TESTING"] = True
    with app_module.app.test_client() as c:
        yield c


def test_healthz_returns_ok(client):
    response = client.get("/healthz")

    assert response.status_code == 200
    assert response.get_json()["status"].startswith("ok")


def test_unknown_route_returns_404(client):
    response = client.get("/does-not-exist")

    assert response.status_code == 404


def test_post_messages_happy_path_enqueues_and_returns_202(client, fake_aws):
    fake_ssm, fake_sqs = fake_aws

    response = client.post(
        "/messages",
        data=json.dumps(VALID_PAYLOAD),
        content_type="application/json",
    )

    assert response.status_code == 202
    assert response.get_json() == {"message_id": "fake-message-id-123"}
    assert len(fake_sqs.sent) == 1
    sent_body = json.loads(fake_sqs.sent[0]["MessageBody"])
    assert sent_body == VALID_PAYLOAD["data"], "Only data is sent to SQS, not the token"


def test_post_messages_rejects_wrong_token_with_401(client, fake_aws):
    fake_ssm, fake_sqs = fake_aws
    bad_payload = json.loads(json.dumps(VALID_PAYLOAD))
    bad_payload["token"] = "wrong-token"

    response = client.post(
        "/messages",
        data=json.dumps(bad_payload),
        content_type="application/json",
    )

    assert response.status_code == 401
    assert fake_sqs.sent == [], "Invalid token must NOT enqueue anything"


def test_post_messages_rejects_invalid_json_with_400(client, fake_aws):
    response = client.post(
        "/messages",
        data="this is not json",
        content_type="application/json",
    )

    assert response.status_code == 400


def test_post_messages_rejects_missing_field_with_400(client, fake_aws):
    _, fake_sqs = fake_aws
    bad_payload = json.loads(json.dumps(VALID_PAYLOAD))
    del bad_payload["data"]["email_content"]

    response = client.post(
        "/messages",
        data=json.dumps(bad_payload),
        content_type="application/json",
    )

    assert response.status_code == 400
    assert fake_sqs.sent == []


def test_post_messages_ssm_failure_returns_503(client, fake_aws):
    """If SSM is unreachable we cannot validate the token; fail closed."""
    fake_ssm, fake_sqs = fake_aws
    fake_ssm.raise_exc = ClientError(
        {"Error": {"Code": "InternalError", "Message": "boom"}},
        "GetParameter",
    )

    response = client.post(
        "/messages",
        data=json.dumps(VALID_PAYLOAD),
        content_type="application/json",
    )

    assert response.status_code == 503
    assert fake_sqs.sent == [], "Must not enqueue when token can't be verified"


def test_post_messages_sqs_failure_returns_503(client, fake_aws):
    fake_ssm, fake_sqs = fake_aws
    fake_sqs.raise_exc = ClientError(
        {"Error": {"Code": "InternalError", "Message": "boom"}},
        "SendMessage",
    )

    response = client.post(
        "/messages",
        data=json.dumps(VALID_PAYLOAD),
        content_type="application/json",
    )

    assert response.status_code == 503
