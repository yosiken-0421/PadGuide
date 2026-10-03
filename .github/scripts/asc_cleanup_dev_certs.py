#!/usr/bin/env python3
"""App Store Connect API で、GitHub Actions が自動作成した開発用証明書（"Created via API"）だけを取り消す。
秘密情報は表示しない。ほかの証明書（配布用・手動で作ったもの）には触らない。"""
import base64, json, os, subprocess, sys, time, urllib.request, urllib.error

API = "https://api.appstoreconnect.apple.com/v1"


def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    """ECDSA の DER 署名を JWT 用の r||s（64バイト）にする"""
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    assert der[i] == 0x02
    lr = der[i + 1]; r = int.from_bytes(der[i + 2:i + 2 + lr], "big"); i += 2 + lr
    assert der[i] == 0x02
    ls = der[i + 1]; s = int.from_bytes(der[i + 2:i + 2 + ls], "big")
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def make_jwt(key_path: str, key_id: str, issuer: str, now: int) -> str:
    head = b64u(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    body = b64u(json.dumps({"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}, separators=(",", ":")).encode())
    signing_input = f"{head}.{body}"
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path], input=signing_input.encode(),
                         capture_output=True, check=True).stdout
    return signing_input + "." + b64u(der_to_raw(der))


def call(method: str, url: str, token: str):
    req = urllib.request.Request(url, method=method, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = r.read()
        return r.status, (json.loads(data) if data else None)


def main() -> int:
    key_path = os.environ["ASC_KEY_PATH"]
    token = make_jwt(key_path, os.environ["KEY_ID"], os.environ["ISSUER_ID"], int(time.time()))
    try:
        _, res = call("GET", f"{API}/certificates?limit=200&fields[certificates]=certificateType,displayName,name", token)
    except urllib.error.HTTPError as e:
        print(f"::warning::証明書の一覧を取得できませんでした（HTTP {e.code}）。API キーのアクセスが Admin か確認してください")
        return 0
    targets = []
    for c in res.get("data", []):
        a = c.get("attributes", {})
        names = f"{a.get('displayName') or ''} {a.get('name') or ''}"
        if a.get("certificateType") in ("DEVELOPMENT", "IOS_DEVELOPMENT") and "Created via API" in names:
            targets.append(c["id"])
    revoked = 0
    for cid in targets:
        try:
            call("DELETE", f"{API}/certificates/{cid}", token)
            revoked += 1
        except urllib.error.HTTPError as e:
            print(f"::warning::証明書を 1 件取り消せませんでした（HTTP {e.code}）")
    print(f"自動作成された開発用証明書を {revoked} 件取り消しました（対象 {len(targets)} 件）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
