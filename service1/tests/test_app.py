import pytest

from app import validate_payload


def test_validate_payload_success():
    payload = {
        "data": {
            "email_subject": "Have a great day!",
            "email_sender": "John doe",
            "email_timestream": "1693561101",
            "email_content": "Just want to say... have a great day!!!"
        },
        "token": "secret"
    }

    data, token = validate_payload(payload)

    assert data["email_subject"] == "Have a great day!"
    assert token == "secret"


def test_validate_payload_missing_field():
    payload = {
        "data": {
            "email_subject": "Hello",
            "email_sender": "John",
            "email_timestream": "1693561101"
        },
        "token": "secret"
    }

    with pytest.raises(ValueError):
        validate_payload(payload)


def test_validate_payload_invalid_timestamp():
    payload = {
        "data": {
            "email_subject": "Hello",
            "email_sender": "John",
            "email_timestream": "not-a-number",
            "email_content": "Hello"
        },
        "token": "secret"
    }

    with pytest.raises(ValueError):
        validate_payload(payload)
