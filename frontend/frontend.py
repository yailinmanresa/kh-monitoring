"""Flask frontend for The Knowledge Hub monitoring app.
Gets the measurements from the API and shows them as a web page."""

import os

import requests
from dotenv import load_dotenv
from flask import Flask, render_template, request  # NEW: request reads the filter from the URL

load_dotenv()  # read settings from a .env file, if there is one

# Settings come from environment variables, not from the code (secure + flexible)
API_URL = os.environ.get("API_URL", "http://localhost:8000")
API_KEY = os.environ.get("API_KEY")

app = Flask(__name__)


def to_api_time(value):
    """NEW: turn the browser's '2026-11-18T10:00' into the API's '2026-11-18 10:00:00'."""
    if not value:
        return None
    return value.replace("T", " ") + ":00"


@app.route("/")
def dashboard():
    """Home page: ask the API for the measurements and show them."""
    # NEW: read the filter from the URL, e.g. /?start=2026-11-18T10:00&end=2026-11-18T12:00
    start = request.args.get("start", "")
    end = request.args.get("end", "")

    params = {}
    if start:
        params["start"] = to_api_time(start)
    if end:
        params["end"] = to_api_time(end)

    measurements = []
    error = None
    try:
        response = requests.get(
            API_URL + "/measurements",
            headers={"X-API-Key": API_KEY},  # the API only answers with the right key
            params=params,                   # NEW: send the time period to the API
            timeout=10,                      # don't wait forever if the API is down
        )
        if response.status_code == 200:
            measurements = response.json()
        else:
            error = f"The API answered with status {response.status_code}."
    except requests.RequestException:
        error = "The API can't be reached right now."

    # Newest first
    measurements.sort(key=lambda m: m["timestamp"], reverse=True)
    return render_template("dashboard.html", measurements=measurements, error=error,
                           start=start, end=end)  # NEW: keep the chosen times in the form


if __name__ == "__main__":
    app.run(port=5000, debug=True)