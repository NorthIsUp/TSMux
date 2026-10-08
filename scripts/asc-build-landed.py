"""Exit 0 once App Store Connect lists an export's (.ipa or .pkg) build, 1 if it never does.

Used when Transporter reports a failed upload: it has done so for uploads
that went through, so ask App Store Connect rather than trusting the exit code.
"""

import json
import sys
import time
import urllib.request

from asc_build import bundle_version, token

APP_ID = "6819539345"
WAIT_SECONDS = 600


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
