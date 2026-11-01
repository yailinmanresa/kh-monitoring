"""Unit tests for the Knowledge Hub monitoring API.

Run them with:  pytest -v
Each test sends a message to the API and checks the answer.
The tests use their own temporary database and test key,
so they never touch your real data or your real key.
"""

import os

os.environ["API_KEY"] = "test-key"  # a fake key, only for the tests

import pytest

import app as api

GOOD_KEY = {"X-API-Key": "test-key"}
GOOD_MEASUREMENT = {
    "timestamp": "2026-11-01 10:00:00",
    "host": "kh-srv01",
    "metric": "cpu-usage",
    "value": 23.5,
}


@pytest.fixture
def client(tmp_path, monkeypatch):
    """A test version of the API with an empty, temporary database."""
    monkeypatch.setattr(api, "API_KEY", "test-key")
    monkeypatch.setattr(api, "DB_FILE", str(tmp_path / "test.db"))
    return api.app.test_client()


def test_health_works_without_key(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json() == {"status": "ok"}


def test_post_without_key_is_rejected(client):
    response = client.post("/measurements", json=GOOD_MEASUREMENT)
    assert response.status_code == 401


def test_post_with_wrong_key_is_rejected(client):
    response = client.post("/measurements", json=GOOD_MEASUREMENT, headers={"X-API-Key": "wrong"})
    assert response.status_code == 401


def test_post_with_key_is_stored(client):
    response = client.post("/measurements", json=GOOD_MEASUREMENT, headers=GOOD_KEY)
    assert response.status_code == 201
    assert response.get_json() == {"stored": 1}


def test_value_above_100_is_rejected(client):
    bad = dict(GOOD_MEASUREMENT, value=150)
    response = client.post("/measurements", json=bad, headers=GOOD_KEY)
    assert response.status_code == 400


def test_unknown_metric_is_rejected(client):
    bad = dict(GOOD_MEASUREMENT, metric="temperature")
    response = client.post("/measurements", json=bad, headers=GOOD_KEY)
    assert response.status_code == 400


def test_missing_field_is_rejected(client):
    bad = {"timestamp": "2026-11-01 10:00:00", "metric": "cpu-usage", "value": 23.5}  # no host
    response = client.post("/measurements", json=bad, headers=GOOD_KEY)
    assert response.status_code == 400


def test_wrong_time_format_is_rejected(client):
    bad = dict(GOOD_MEASUREMENT, timestamp="yesterday")
    response = client.post("/measurements", json=bad, headers=GOOD_KEY)
    assert response.status_code == 400


def test_stored_measurement_can_be_read_back(client):
    client.post("/measurements", json=GOOD_MEASUREMENT, headers=GOOD_KEY)
    response = client.get("/measurements?start=2026-11-01", headers=GOOD_KEY)
    assert response.status_code == 200
    assert response.get_json() == [GOOD_MEASUREMENT]


def test_rejected_measurement_is_not_stored(client):
    client.post("/measurements", json=dict(GOOD_MEASUREMENT, value=150), headers=GOOD_KEY)
    response = client.get("/measurements", headers=GOOD_KEY)
    assert response.get_json() == []
