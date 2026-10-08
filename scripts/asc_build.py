"""What the App Store Connect scripts share: the API token and an export's build."""

import glob
import os
import plistlib
import time
import zipfile
from pathlib import Path

import jwt


def token() -> str:
    key_id, issuer = os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"]
    (path,) = glob.glob(os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8"))
    now = int(time.time())
    claims = {"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    return jwt.encode(claims, open(path).read(), algorithm="ES256", headers={"kid": key_id})


def platform(export: str) -> str:
    """IOS for an .ipa, MAC_OS for a .pkg."""
    return "MAC_OS" if export.endswith(".pkg") else "IOS"


def bundle_version(export: str) -> str:
    """CFBundleVersion of an exported .ipa, or of a .pkg from the AppStoreInfo.plist beside it."""
    if platform(export) == "IOS":
        with zipfile.ZipFile(export) as z:
            name = next(n for n in z.namelist() if n.count("/") == 2 and n.endswith(".app/Info.plist"))
            return plistlib.loads(z.read(name))["CFBundleVersion"]
    info = plistlib.loads((Path(export).parent / "AppStoreInfo.plist").read_bytes())
    return info["product-metadata"]["packages"][0]["bundles"][0]["CFBundleVersion"]
