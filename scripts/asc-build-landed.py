"""Exit 0 once App Store Connect lists the .ipa's build, 1 if it never does.

Used when Transporter reports a failed upload: it has done so for uploads
that went through, so ask App Store Connect rather than trusting the exit code.
"""

import glob
import json
import os
import plistlib
import sys
import time
import urllib.request
import zipfile

import jwt

APP_ID = "6819539345"
WAIT_SECONDS = 600


def bundle_version(ipa: str) -> str:
    with zipfile.ZipFile(ipa) as z:
        name = next(n for n in z.namelist() if n.count("/") == 2 and n.endswith(".app/Info.plist"))
        return plistlib.loads(z.read(name))["CFBundleVersion"]


def token() -> str:
    key_id, issuer = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
    (path,) = glob.glob(os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8"))
    now = int(time.time())
    claims = {"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    return jwt.encode(claims, open(path).read(), algorithm="ES256", headers={"kid": key_id})


def landed(version: str) -> bool:
    url = (
        "https://api.appstoreconnect.apple.com/v1/builds"
        f"?filter[app]={APP_ID}&filter[version]={version}&limit=1"
    )
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token()}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return bool(json.load(r)["data"])


def main() -> int:
    version = bundle_version(sys.argv[1])
    deadline = time.monotonic() + WAIT_SECONDS
    while time.monotonic() < deadline:
        if landed(version):
            print(f"build {version} is in App Store Connect despite Transporter's error")
            return 0
        time.sleep(30)
    print(f"build {version} never appeared in App Store Connect", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
