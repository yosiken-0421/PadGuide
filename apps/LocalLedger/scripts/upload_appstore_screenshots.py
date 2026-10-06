import hashlib
import os
import sys
import time
from pathlib import Path

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.yosiken0421.localkakeibo"
VERSION = "1.0"
LOCALE = "ja"
DISPLAY_TYPE = "APP_IPHONE_67"


def token():
    key_path = os.environ["ASC_KEY_PATH"]
    with open(key_path, "r", encoding="utf-8") as f:
        private_key = f.read()
    now = int(time.time())
    return jwt.encode(
        {
            "iss": os.environ["ASC_ISSUER_ID_CLEAN"],
            "iat": now,
            "exp": now + 900,
            "aud": "appstoreconnect-v1",
        },
        private_key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID_CLEAN"], "typ": "JWT"},
    )


AUTH = {"Authorization": f"Bearer {token()}", "Content-Type": "application/json"}


def api(method, path, *, params=None, payload=None, ok=(200, 201, 204)):
    response = requests.request(
        method,
        API + path,
        headers=AUTH,
        params=params,
        json=payload,
        timeout=60,
    )
    print(f"{method} {path} -> {response.status_code}")
    if response.status_code not in ok:
        print(response.text[:5000])
        raise RuntimeError(f"App Store Connect request failed: {response.status_code}")
    if response.status_code == 204 or not response.text.strip():
        return None
    return response.json()


def find_ids():
    apps = api("GET", "/apps", params={"filter[bundleId]": BUNDLE_ID, "limit": "10"})
    if not apps["data"]:
        raise RuntimeError("KakeiboLeaf app record not found")
    app_id = apps["data"][0]["id"]

    versions = api(
        "GET",
        f"/apps/{app_id}/appStoreVersions",
        params={"filter[platform]": "IOS", "limit": "50"},
    )
    version = next(
        x for x in versions["data"]
        if x.get("attributes", {}).get("versionString") == VERSION
    )

    localizations = api(
        "GET",
        f"/appStoreVersions/{version['id']}/appStoreVersionLocalizations",
        params={"limit": "50"},
    )
    localization = next(
        x for x in localizations["data"]
        if x.get("attributes", {}).get("locale") == LOCALE
    )
    return localization["id"]


def ensure_set(localization_id):
    sets = api(
        "GET",
        f"/appStoreVersionLocalizations/{localization_id}/appScreenshotSets",
        params={"filter[screenshotDisplayType]": DISPLAY_TYPE, "limit": "50"},
    )
    if sets["data"]:
        screenshot_set = sets["data"][0]
        print("Using existing screenshot set:", screenshot_set["id"])
        return screenshot_set["id"]

    payload = {
        "data": {
            "type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": DISPLAY_TYPE},
            "relationships": {
                "appStoreVersionLocalization": {
                    "data": {
                        "type": "appStoreVersionLocalizations",
                        "id": localization_id,
                    }
                }
            },
        }
    }
    created = api("POST", "/appScreenshotSets", payload=payload)
    print("Created screenshot set:", created["data"]["id"])
    return created["data"]["id"]


def clear_existing(screenshot_set_id):
    current = api(
        "GET",
        f"/appScreenshotSets/{screenshot_set_id}/appScreenshots",
        params={"limit": "50"},
    )
    for item in current.get("data", []):
        api("DELETE", f"/appScreenshots/{item['id']}", ok=(204,))
        print("Deleted old screenshot:", item["id"])


def reserve(screenshot_set_id, path):
    size = path.stat().st_size
    payload = {
        "data": {
            "type": "appScreenshots",
            "attributes": {
                "fileSize": size,
                "fileName": path.name,
            },
            "relationships": {
                "appScreenshotSet": {
                    "data": {
                        "type": "appScreenshotSets",
                        "id": screenshot_set_id,
                    }
                }
            },
        }
    }
    return api("POST", "/appScreenshots", payload=payload)["data"]


def upload_parts(reservation, path):
    data = path.read_bytes()
    operations = reservation.get("attributes", {}).get("uploadOperations", [])
    if not operations:
        raise RuntimeError(f"No upload operations returned for {path.name}")

    for operation in operations:
        offset = int(operation["offset"])
        length = int(operation["length"])
        chunk = data[offset:offset + length]
        headers = {
            header["name"]: header["value"]
            for header in operation.get("requestHeaders", [])
        }
        response = requests.request(
            operation["method"],
            operation["url"],
            headers=headers,
            data=chunk,
            timeout=120,
        )
        print(
            f"Upload {path.name} bytes {offset}:{offset + length} "
            f"-> {response.status_code}"
        )
        if response.status_code < 200 or response.status_code >= 300:
            print(response.text[:2000])
            raise RuntimeError(f"Asset part upload failed for {path.name}")


def commit(reservation_id, path):
    checksum = hashlib.md5(path.read_bytes()).hexdigest()
    payload = {
        "data": {
            "type": "appScreenshots",
            "id": reservation_id,
            "attributes": {
                "uploaded": True,
                "sourceFileChecksum": checksum,
            },
        }
    }
    api("PATCH", f"/appScreenshots/{reservation_id}", payload=payload)


def wait_complete(screenshot_id, path):
    deadline = time.time() + 180
    last = None
    while time.time() < deadline:
        item = api("GET", f"/appScreenshots/{screenshot_id}")
        state = (
            item["data"]
            .get("attributes", {})
            .get("assetDeliveryState", {})
            .get("state")
        )
        if state != last:
            print(f"{path.name}: asset state {state}")
            last = state
        if state == "COMPLETE":
            return
        if state == "FAILED":
            raise RuntimeError(f"Screenshot processing failed for {path.name}")
        time.sleep(4)
    raise RuntimeError(f"Timed out waiting for {path.name}")


def reorder(screenshot_set_id, ids):
    payload = {
        "data": [{"type": "appScreenshots", "id": screenshot_id} for screenshot_id in ids]
    }
    api(
        "PATCH",
        f"/appScreenshotSets/{screenshot_set_id}/relationships/appScreenshots",
        payload=payload,
        ok=(204,),
    )


def main():
    directory = Path(os.environ["SCREENSHOT_DIR"])
    files = sorted(
        [p for p in directory.rglob("*") if p.suffix.lower() in {".jpg", ".jpeg", ".png"}]
    )
    if len(files) != 3:
        print("Found screenshot files:", [str(p) for p in files])
        raise RuntimeError(f"Expected exactly 3 screenshots, found {len(files)}")

    for path in files:
        if path.stat().st_size < 100000:
            raise RuntimeError(f"Screenshot looks too small/incomplete: {path.name}")

    localization_id = find_ids()
    screenshot_set_id = ensure_set(localization_id)
    clear_existing(screenshot_set_id)

    uploaded_ids = []
    for path in files:
        reservation = reserve(screenshot_set_id, path)
        screenshot_id = reservation["id"]
        upload_parts(reservation, path)
        commit(screenshot_id, path)
        wait_complete(screenshot_id, path)
        uploaded_ids.append(screenshot_id)

    reorder(screenshot_set_id, uploaded_ids)

    final = api(
        "GET",
        f"/appScreenshotSets/{screenshot_set_id}/appScreenshots",
        params={"limit": "50"},
    )
    rows = final.get("data", [])
    if len(rows) != 3:
        raise RuntimeError(f"Expected 3 uploaded screenshots, found {len(rows)}")

    print("KakeiboLeaf App Store screenshots uploaded successfully.")
    print("Screenshot set:", screenshot_set_id)
    for row in rows:
        attrs = row.get("attributes", {})
        state = (attrs.get("assetDeliveryState") or {}).get("state")
        print(row["id"], attrs.get("fileName"), state)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"::error::{exc}")
        sys.exit(1)
