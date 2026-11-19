"""Flask frontend for The Knowledge Hub monitoring app.
Users sign in with Microsoft Entra ID (with MFA) before they can see the measurements."""
import os
from functools import wraps

import msal
import requests
from dotenv import load_dotenv
from flask import Flask, redirect, render_template, request, session, url_for

load_dotenv()

API_URL = os.environ.get("API_URL", "http://localhost:8000")
API_KEY = os.environ.get("API_KEY")
CLIENT_ID = os.environ.get("CLIENT_ID")
CLIENT_SECRET = os.environ.get("CLIENT_SECRET")
TENANT_ID = os.environ.get("TENANT_ID")
AUTHORITY = f"https://login.microsoftonline.com/{TENANT_ID}"
SCOPES = ["User.Read"]

app = Flask(__name__)
app.secret_key = os.environ["FLASK_SECRET_KEY"]       # locks the session cookie
app.config["SESSION_COOKIE_HTTPONLY"] = True          # JavaScript can't read the cookie
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"


def msal_app():
    """The MSAL client that talks to Entra ID for this app registration."""
    return msal.ConfidentialClientApplication(
        CLIENT_ID, authority=AUTHORITY, client_credential=CLIENT_SECRET
    )


def login_required(view):
    """Only signed-in users may open the page; others go to /login."""
    @wraps(view)
    def wrapper(*args, **kwargs):
        if not session.get("user"):
            return redirect(url_for("login"))
        return view(*args, **kwargs)
    return wrapper


@app.route("/login")
def login():
    # Start the login: Entra ID shows the sign-in page (with MFA)
    flow = msal_app().initiate_auth_code_flow(
        SCOPES, redirect_uri=url_for("authorized", _external=True)
    )
    session["flow"] = flow
    return redirect(flow["auth_uri"])


@app.route("/getAToken")
def authorized():
    # Entra ID sends the user back here with a code; swap it for a token
    try:
        result = msal_app().acquire_token_by_auth_code_flow(
            session.get("flow", {}), request.args
        )
    except ValueError:  # the state doesn't match: start again
        return redirect(url_for("login"))
    if "error" in result:
        return f"Login failed: {result.get('error_description', result['error'])}", 401
    session.pop("flow", None)
    session["user"] = result.get("id_token_claims")  # name and email of the user
    return redirect(url_for("dashboard"))


@app.route("/logout")
def logout():
    session.clear()
    return redirect(f"{AUTHORITY}/oauth2/v2.0/logout")


def to_api_time(value):
    if not value:
        return None
    return value.replace("T", " ") + ":00"


@app.route("/")
@login_required
def dashboard():
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
            headers={"X-API-Key": API_KEY},
            params=params,
            timeout=10,
        )
        if response.status_code == 200:
            measurements = response.json()
        else:
            error = f"The API answered with status {response.status_code}."
    except requests.RequestException:
        error = "The API can't be reached right now."

    measurements.sort(key=lambda m: m["timestamp"], reverse=True)
    return render_template(
        "dashboard.html",
        measurements=measurements,
        error=error,
        start=start,
        end=end,
        user=session["user"],
    )


if __name__ == "__main__":
    app.run(port=5000, debug=True)