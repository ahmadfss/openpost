#!/usr/bin/env python3
"""Minimal S3/R2 get/put/list using only the Python standard library.

Reads credentials from the environment (never prints them):
  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_ENDPOINT_URL
  AWS_REGION (default auto)
  OPENPOST_BACKUP_BUCKET
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import hmac
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


def _must(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"missing environment variable: {name}")
    return value


def _sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def _signing_key(secret: str, date_stamp: str, region: str, service: str) -> bytes:
    k_date = _sign(("AWS4" + secret).encode("utf-8"), date_stamp)
    k_region = hmac.new(k_date, region.encode("utf-8"), hashlib.sha256).digest()
    k_service = hmac.new(k_region, service.encode("utf-8"), hashlib.sha256).digest()
    return hmac.new(k_service, b"aws4_request", hashlib.sha256).digest()


def _request(method: str, key: str, body: bytes | None = None, content_type: str = "application/octet-stream"):
    access = _must("AWS_ACCESS_KEY_ID")
    secret = _must("AWS_SECRET_ACCESS_KEY")
    endpoint = _must("AWS_ENDPOINT_URL").rstrip("/")
    bucket = _must("OPENPOST_BACKUP_BUCKET")
    region = os.environ.get("AWS_REGION", "auto") or "auto"
    parsed = urllib.parse.urlparse(endpoint)
    host = parsed.netloc
    # Virtual-hosted-style: https://bucket.endpoint-host/key
    # Path-style is more reliable for R2 custom endpoints.
    path = f"/{bucket}/{key}" if method != "LIST" else f"/{bucket}"
    if method == "LIST":
        method = "GET"
    url = f"{parsed.scheme}://{host}{path}"
    if method == "GET" and body is None and key == "" or False:
        pass
    now = dt.datetime.utcnow()
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    payload = body or b""
    payload_hash = hashlib.sha256(payload).hexdigest()
    canonical_headers = f"host:{host}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n"
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    canonical_qs = ""
    if method == "GET" and body is None and os.environ.get("_R2_LIST_PREFIX") is not None and key.startswith("?"):
        # handled below
        pass
    canonical_request = "\n".join(
        [
            method,
            urllib.parse.urlparse(url).path,
            urllib.parse.urlparse(url).query,
            canonical_headers,
            signed_headers,
            payload_hash,
        ]
    )
    scope = f"{date_stamp}/{region}/s3/aws4_request"
    string_to_sign = "\n".join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )
    signature = hmac.new(_signing_key(secret, date_stamp, region, "s3"), string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    authorization = (
        f"AWS4-HMAC-SHA256 Credential={access}/{scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )
    headers = {
        "Host": host,
        "x-amz-date": amz_date,
        "x-amz-content-sha256": payload_hash,
        "Authorization": authorization,
    }
    if body is not None:
        headers["Content-Type"] = content_type
        headers["Content-Length"] = str(len(body))
    req = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        err = exc.read()
        raise SystemExit(f"R2 request failed: HTTP {exc.code} ({len(err)} bytes)") from None


def cmd_put(args: argparse.Namespace) -> None:
    data = open(args.file, "rb").read()
    status, _ = _request("PUT", args.key, body=data)
    if status not in (200, 201, 204):
        raise SystemExit(f"put failed: HTTP {status}")
    print(f"uploaded {args.key} ({len(data)} bytes)")


def cmd_get(args: argparse.Namespace) -> None:
    status, data = _request("GET", args.key)
    if status != 200:
        raise SystemExit(f"get failed: HTTP {status}")
    os.makedirs(os.path.dirname(args.file) or ".", exist_ok=True)
    with open(args.file, "wb") as fh:
        fh.write(data)
    print(f"downloaded {args.key} ({len(data)} bytes)")


def cmd_list(args: argparse.Namespace) -> None:
    prefix = args.prefix or ""
    access = _must("AWS_ACCESS_KEY_ID")
    secret = _must("AWS_SECRET_ACCESS_KEY")
    endpoint = _must("AWS_ENDPOINT_URL").rstrip("/")
    bucket = _must("OPENPOST_BACKUP_BUCKET")
    region = os.environ.get("AWS_REGION", "auto") or "auto"
    parsed = urllib.parse.urlparse(endpoint)
    host = parsed.netloc
    qs = urllib.parse.urlencode({"list-type": "2", "prefix": prefix})
    path = f"/{bucket}"
    url = f"{parsed.scheme}://{host}{path}?{qs}"
    now = dt.datetime.utcnow()
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(b"").hexdigest()
    canonical_headers = f"host:{host}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n"
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    canonical_request = "\n".join(["GET", path, qs, canonical_headers, signed_headers, payload_hash])
    scope = f"{date_stamp}/{region}/s3/aws4_request"
    string_to_sign = "\n".join(
        ["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical_request.encode("utf-8")).hexdigest()]
    )
    signature = hmac.new(_signing_key(secret, date_stamp, region, "s3"), string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    authorization = (
        f"AWS4-HMAC-SHA256 Credential={access}/{scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )
    headers = {
        "Host": host,
        "x-amz-date": amz_date,
        "x-amz-content-sha256": payload_hash,
        "Authorization": authorization,
    }
    req = urllib.request.Request(url, method="GET", headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read()
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"R2 list failed: HTTP {exc.code}") from None
    ns = {"s3": "http://s3.amazonaws.com/doc/2006-03-01/"}
    root = ET.fromstring(body)
    keys = [el.text for el in root.findall(".//s3:Key", ns) if el.text]
    if not keys:
        # Some endpoints omit the namespace
        keys = [el.text for el in root.findall(".//Key") if el.text]
    if not keys:
        return
    for key in keys:
        print(key)


def main() -> None:
    parser = argparse.ArgumentParser(description="Minimal R2 get/put/list")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_put = sub.add_parser("put")
    p_put.add_argument("file")
    p_put.add_argument("key")
    p_put.set_defaults(func=cmd_put)
    p_get = sub.add_parser("get")
    p_get.add_argument("key")
    p_get.add_argument("file")
    p_get.set_defaults(func=cmd_get)
    p_list = sub.add_parser("list")
    p_list.add_argument("prefix", nargs="?")
    p_list.set_defaults(func=cmd_list)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
