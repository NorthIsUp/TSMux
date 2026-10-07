"""Run the public TestFlight beta for TSMux.

  setup        test info, review contact (copied from another of the team's
               apps so the phone number stays out of this repo) and the
               "public" group with its public link; safe to rerun
  ship IPA     wait for the .ipa's build to process, add it to "public" and
               submit it for Beta App Review

env: ASC_KEY_ID, ASC_ISSUER_ID; key at ~/.appstoreconnect/private_keys.
"""

import glob
import json
import os
import plistlib
import sys
import time
import urllib.error
import urllib.request
import zipfile

import jwt

APP_ID = "6819539345"
CONTACT_FROM_APP = "6816750932"
GROUP = "public"
API = "https://api.appstoreconnect.apple.com/v1"
PROCESS_SECONDS = 1800

DESCRIPTION = (
    "TSMux keeps every one of your Tailscale tailnets connected at once: work, a "
    "client's, your homelab. Names resolve to the right tailnet on their own, and "
    "you can open an SSH shell on machines that allow Tailscale SSH."
)
WHAT_TO_TEST = "Add your tailnets, turn the VPN on, and reach machines on each by name."
REVIEW_NOTES = (
    "TSMux needs a Tailscale account, which is free: tap +, then sign in with Google, "
    "Microsoft, GitHub or Apple on Tailscale's page. No demo account is needed. Turn "
    "on the VPN switch, then open any machine's name in Safari."
)


def token() -> str:
    key_id, issuer = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
    (path,) = glob.glob(os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8"))
    now = int(time.time())
    claims = {"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    return jwt.encode(claims, open(path).read(), algorithm="ES256", headers={"kid": key_id})


def call(method: str, path: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body else None,
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path}: {e.code} {e.read().decode()}")
    return json.loads(raw) if raw else {}


def group() -> dict | None:
    groups = call("GET", f"/apps/{APP_ID}/betaGroups")["data"]
    return next((g for g in groups if g["attributes"]["name"] == GROUP), None)


def setup() -> None:
    attrs = {
        "description": DESCRIPTION,
        "feedbackEmail": "adam@northisup.com",
        "privacyPolicyUrl": "https://github.com/NorthIsUp/TSMux/blob/main/PRIVACY.md",
        "marketingUrl": "https://github.com/NorthIsUp/TSMux",
    }
    locs = call("GET", f"/apps/{APP_ID}/betaAppLocalizations")["data"]
    if locs:
        call("PATCH", f"/betaAppLocalizations/{locs[0]['id']}",
             {"data": {"type": "betaAppLocalizations", "id": locs[0]["id"], "attributes": attrs}})
    else:
        call("POST", "/betaAppLocalizations", {"data": {
            "type": "betaAppLocalizations",
            "attributes": {**attrs, "locale": "en-US"},
            "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}},
        }})

    src = call("GET", f"/apps/{CONTACT_FROM_APP}/betaAppReviewDetail")["data"]["attributes"]
    contact = {k: src[k] for k in ("contactFirstName", "contactLastName", "contactPhone", "contactEmail")}
    call("PATCH", f"/betaAppReviewDetails/{APP_ID}", {"data": {
        "type": "betaAppReviewDetails", "id": APP_ID,
        "attributes": {**contact, "demoAccountRequired": False, "notes": REVIEW_NOTES},
    }})

    g = group()
    if g is None:
        g = call("POST", "/betaGroups", {"data": {
            "type": "betaGroups",
            "attributes": {"name": GROUP, "publicLinkEnabled": True, "feedbackEnabled": True},
            "relationships": {"app": {"data": {"type": "apps", "id": APP_ID}}},
        }})["data"]
    print(g["attributes"]["publicLink"])


def bundle_version(ipa: str) -> str:
    with zipfile.ZipFile(ipa) as z:
        name = next(n for n in z.namelist() if n.count("/") == 2 and n.endswith(".app/Info.plist"))
        return plistlib.loads(z.read(name))["CFBundleVersion"]


def ship(ipa: str) -> None:
    version = bundle_version(ipa)
    deadline = time.monotonic() + PROCESS_SECONDS
    while True:
        builds = call("GET", f"/builds?filter[app]={APP_ID}&filter[version]={version}&limit=1")["data"]
        state = builds[0]["attributes"]["processingState"] if builds else "MISSING"
        if state == "VALID":
            break
        if state in ("FAILED", "INVALID") or time.monotonic() > deadline:
            sys.exit(f"build {version} is {state}")
        time.sleep(30)
    build = builds[0]["id"]

    locs = call("GET", f"/builds/{build}/betaBuildLocalizations")["data"]
    if not locs:
        call("POST", "/betaBuildLocalizations", {"data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": "en-US", "whatsNew": WHAT_TO_TEST},
            "relationships": {"build": {"data": {"type": "builds", "id": build}}},
        }})

    g = group() or sys.exit(f'no "{GROUP}" group; run setup first')
    call("POST", f"/betaGroups/{g['id']}/relationships/builds",
         {"data": [{"type": "builds", "id": build}]})
    call("POST", "/betaAppReviewSubmissions", {"data": {
        "type": "betaAppReviewSubmissions",
        "relationships": {"build": {"data": {"type": "builds", "id": build}}},
    }})
    print(f"build {version} is in {GROUP} and submitted for Beta App Review")


if __name__ == "__main__":
    match sys.argv[1:]:
        case ["setup"]:
            setup()
        case ["ship", ipa]:
            ship(ipa)
        case _:
            sys.exit(__doc__)
