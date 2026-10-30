"""Knowledge Hub monitoring API.

Receives measurements from monitor.py and stores them in a database.
For now it uses SQLite on my laptop; later it moves to Azure SQL.

Endpoints:
    GET  /health                        check that the API is running
    POST /measurements                  store one measurement or a list of them
    GET  /measurements?start=...&end=...  show stored measurements

Every request to /measurements must send the API key in the header
"X-API-Key". The key itself is stored in the .env file, never in the code.
"""

import hmac
import logging
import os
import sqlite3
from datetime import datetime

from dotenv import load_dotenv
from flask import Flask, jsonify, request

load_dotenv()  # reads the settings from the .env file

API_KEY = os.environ.get("API_KEY")
DB_FILE = os.environ.get("DB_FILE", "api.db")
LOG_FILE = "api.log"
TIME_FORMAT = "%Y-%m-%d %H:%M:%S"
ALLOWED_METRICS = {"cpu-usage", "memory-usage", "disk-usage"}

if not API_KEY:
    raise SystemExit("API_KEY is missing. Put it in the .env file.")

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)

app = Flask(__name__)


@app.before_request
def check_api_key():
    """Block requests to /measurements that don't send the right API key."""
    if request.path.startswith("/measurements"):
        sent_key = request.headers.get("X-API-Key", "")
        if not hmac.compare_digest(sent_key, API_KEY):
            logging.warning("Rejected request from %s: wrong or missing API key", request.remote_addr)
            return jsonify(error="wrong or missing API key"), 401


@app.after_request
def log_request(response):
    """Write every request to api.log."""
    logging.info("%s %s %s from %s", request.method, request.path, response.status_code, request.remote_addr)
    return response


def get_db():
    """Open the database and create the table if it doesn't exist yet."""
    connection = sqlite3.connect(DB_FILE)
    connection.row_factory = sqlite3.Row
    connection.execute(
        "CREATE TABLE IF NOT EXISTS measurements ("
        " id INTEGER PRIMARY KEY AUTOINCREMENT,"
        " timestamp TEXT NOT NULL,"
        " host TEXT NOT NULL,"
        " metric TEXT NOT NULL,"
        " value REAL NOT NULL)"
    )
    return connection


def validate(measurement):
    """Return an error message, or None if the measurement is valid."""
    if not isinstance(measurement, dict):
        return "each measurement must be a JSON object"
    for field in ("timestamp", "host", "metric", "value"):
        if field not in measurement:
            return f"missing field: {field}"
    if measurement["metric"] not in ALLOWED_METRICS:
        return f"unknown metric: {measurement['metric']}"
    try:
        datetime.strptime(measurement["timestamp"], TIME_FORMAT)
    except (TypeError, ValueError):
        return "timestamp must look like 2026-11-02 10:00:00"
    value = measurement["value"]
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 <= value <= 100:
        return "value must be a number between 0 and 100"
    if not isinstance(measurement["host"], str) or not measurement["host"].strip():
        return "host must be a name"
    return None


@app.get("/health")
def health():
    return jsonify(status="ok")


@app.post("/measurements")
def add_measurements():
    data = request.get_json(silent=True)
    if data is None:
        return jsonify(error="the body must be JSON"), 400

    # Accept one measurement or a list of them.
    measurements = data if isinstance(data, list) else [data]
    if not measurements:
        return jsonify(error="no measurements sent"), 400

    for measurement in measurements:
        error = validate(measurement)
        if error:
            logging.warning("Rejected measurement: %s", error)
            return jsonify(error=error), 400

    connection = get_db()
    with connection:  # saves (commits) everything, or nothing if something fails
        connection.executemany(
            "INSERT INTO measurements (timestamp, host, metric, value) VALUES (?, ?, ?, ?)",
            [(m["timestamp"], m["host"].strip(), m["metric"], m["value"]) for m in measurements],
        )
    connection.close()
    logging.info("Stored %d measurement(s)", len(measurements))
    return jsonify(stored=len(measurements)), 201


@app.get("/measurements")
def list_measurements():
    start = request.args.get("start", "0000-01-01")
    end = request.args.get("end", "9999-12-31")
    connection = get_db()
    rows = connection.execute(
        "SELECT timestamp, host, metric, value FROM measurements"
        " WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp",
        (start, end),
    ).fetchall()
    connection.close()
    return jsonify([dict(row) for row in rows])


if __name__ == "__main__":
    # debug=True is only for testing on my own laptop, never in Azure.
    app.run(host="127.0.0.1", port=5000, debug=True)
