"""Extract only the installed app's client ID and client secret for a release."""
import json
import plistlib
import sys

try:
    client = json.load(sys.stdin)["installed"]
    client_id = client["client_id"]
    secret = client["client_secret"]
    if not isinstance(client_id, str) or not client_id.endswith(".apps.googleusercontent.com"):
        raise ValueError
    if not isinstance(secret, str) or not secret.strip():
        raise ValueError
except (KeyError, TypeError, ValueError):
    sys.exit("Expected Google Desktop app JSON with client_id and client_secret.")

plistlib.dump({"MarginsGoogleClientID": client_id, "MarginsGoogleClientSecret": secret}, sys.stdout.buffer)
