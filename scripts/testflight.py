"""Post-upload App Store Connect steps for TSMux builds.

  setup          test info, review contact (copied from another of the team's
                 apps so the phone number stays out of this repo) and the
                 "public" group with its public link; safe to rerun
  attach EXPORT  wait for an .ipa's or .pkg's build to process and attach it
                 to its platform's App Store version, which is where App
                 Store Connect's app grid takes its icon from; submits nothing
  ship EXPORT    wait for the build to process, add it to "public" and
                 submit it for Beta App Review

env: ASC_KEY_ID, ASC_ISSUER_ID; key at ~/.appstoreconnect/private_keys.
"""

import json
import sys
import time
import urllib.error
import urllib.request

from asc_build import bundle_version, platform, token

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


def processed(ipa: str) -> str:
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
    return builds[0]["id"]


def attach(ipa: str) -> None:
    versions = call("GET", f"/apps/{APP_ID}/appStoreVersions?filter[platform]={platform(ipa)}"
                    "&filter[appStoreState]=PREPARE_FOR_SUBMISSION")["data"]
    if not versions:
        print(f"no {platform(ipa)} version in Prepare for Submission; nothing to attach to")
        return
    build = processed(ipa)
    call("PATCH", f"/appStoreVersions/{versions[0]['id']}/relationships/build",
         {"data": {"type": "builds", "id": build}})
    print(f"build {bundle_version(ipa)} is attached to {platform(ipa)} {versions[0]['attributes']['versionString']}")


def ship(ipa: str) -> None:
    version = bundle_version(ipa)
    build = processed(ipa)

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
        case ["attach", ipa]:
            attach(ipa)
        case ["ship", ipa]:
            ship(ipa)
        case _:
            sys.exit(__doc__)
