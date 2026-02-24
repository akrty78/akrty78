"""
OTA Resolver Module — extracted from OPlus-Tracker/tomboy_pro.py
Queries OPPO/OnePlus/Realme OTA servers for firmware download links.
Uses AES-CTR + RSA-OAEP encryption with --anti 1 + taste mode for ColorOS 16 bypass.
"""

import os
import json
import base64
import time
import random
import string
import re
import binascii
from typing import Dict, List, Tuple, Optional, Any
from dataclasses import dataclass, field
from datetime import datetime

import requests
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.backends import default_backend

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  RSA Public Keys (per region)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
PUBLIC_KEYS = {
    "cn": """-----BEGIN RSA PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApXYGXQpNL7gmMzzvajHa
oZIHQQvBc2cOEhJc7/tsaO4sT0unoQnwQKfNQCuv7qC1Nu32eCLuewe9LSYhDXr9
KSBWjOcCFXVXteLO9WCaAh5hwnUoP/5/Wz0jJwBA+yqs3AaGLA9wJ0+B2lB1vLE4
FZNE7exUfwUc03fJxHG9nCLKjIZlrnAAHjRCd8mpnADwfkCEIPIGhnwq7pdkbamZ
coZfZud1+fPsELviB9u447C6bKnTU4AaMcR9Y2/uI6TJUTcgyCp+ilgU0JxemrSI
PFk3jbCbzamQ6Shkw/jDRzYoXpBRg/2QDkbq+j3ljInu0RHDfOeXf3VBfHSnQ66H
CwIDAQAB
-----END RSA PUBLIC KEY-----""",
    "eu": """-----BEGIN RSA PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAh8/EThsK3f0WyyPgrtXb
/D0Xni6UZNppaQHUqHWo976cybl92VxmehE0ISObnxERaOtrlYmTPIxkVC9MMueD
vTwZ1l0KxevZVKU0sJRxNR9AFcw6D7k9fPzzpNJmhSlhpNbt3BEepdgibdRZbacF
3NWy3ejOYWHgxC+I/Vj1v7QU5gD+1OhgWeRDcwuV4nGY1ln2lvkRj8EiJYXfkSq/
wUI5AvPdNXdEqwou4FBcf6mD84G8pKDyNTQwwuk9lvFlcq4mRqgYaFg9DAgpDgqV
K4NTJWM7tQS1GZuRA6PhupfDqnQExyBFhzCefHkEhcFywNyxlPe953NWLFWwbGvF
KwIDAQAB
-----END RSA PUBLIC KEY-----""",
    "in": """-----BEGIN RSA PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwYtghkzeStC9YvAwOQmW
ylbp74Tj8hhi3f9IlK7A/CWrGbLgzz/BeKxNb45zBN8pgaaEOwAJ1qZQV5G4nPro
WCPOP1ro1PkemFJvw/vzOOT5uN0ADnHDzZkZXCU/knxqUSfLcwQlHXsYhNsAm7uO
KjY9YXF4zWzYN0eFPkML3Pj/zg7hl/ov9clB2VeyI1/blMHFfcNA/fvqDTENXcNB
IhgJvXiCpLcZqp+aLZPC5AwY/sCb3j5jTWer0Rk0ZjQBZE1AncwYvUx4mA65U59c
WpTyl4c47J29MsQ66hqWv6eBHlDNZSEsQpHePUqgsf7lmO5Wd7teB8ugQki2oz1Y
5QIDAQAB
-----END RSA PUBLIC KEY-----""",
    "sg": """-----BEGIN RSA PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAkA980wxi+eTGcFDiw2I6
RrUeO4jL/Aj3Yw4dNuW7tYt+O1sRTHgrzxPD9SrOqzz7G0KgoSfdFHe3JVLPN+U1
waK+T0HfLusVJshDaMrMiQFDUiKajb+QKr+bXQhVofH74fjat+oRJ8vjXARSpFk4
/41x5j1Bt/2bHoqtdGPcUizZ4whMwzap+hzVlZgs7BNfepo24PWPRujsN3uopl+8
u4HFpQDlQl7GdqDYDj2zNOHdFQI2UpSf0aIeKCKOpSKF72KDEESpJVQsqO4nxMwE
i2jMujQeCHyTCjBZ+W35RzwT9+0pyZv8FB3c7FYY9FdF/+lvfax5mvFEBd9jO+dp
MQIDAQAB
-----END RSA PUBLIC KEY-----"""
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Region Configuration
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
REGION_CONFIG = {
    "cn":       {"host": "component-ota-cn.allawntech.com", "language": "zh-CN", "carrier_id": "10010111", "public_key_version": "1615879139745"},
    "cn_gray":  {"host": "component-ota-gray.coloros.com",  "language": "zh-CN", "carrier_id": "10010111", "public_key_version": "1615879139745"},
    "eu":       {"host": "component-ota-eu.allawnos.com",   "language": "en-GB", "carrier_id": "01000100", "public_key_version": "1615897067573"},
    "in":       {"host": "component-ota-in.allawnos.com",   "language": "en-IN", "carrier_id": "00011011", "public_key_version": "1615896309308"},
    "sg_host":  {"host": "component-ota-sg.allawnos.com",   "public_key_version": "1615895993238"},
    "sg":       {"language": "en-SG", "carrier_id": "01011010"},
    "ru":       {"language": "ru-RU", "carrier_id": "00110111"},
    "tr":       {"language": "tr-TR", "carrier_id": "01010001"},
    "th":       {"language": "th-TH", "carrier_id": "00111001"},
    "gl":       {"language": "en-US", "carrier_id": "10100111"},
    "id":       {"language": "id-ID", "carrier_id": "00110011"},
    "tw":       {"language": "zh-TW", "carrier_id": "00011010"},
    "my":       {"language": "ms-MY", "carrier_id": "00111000"},
    "vn":       {"language": "vi-VN", "carrier_id": "00111100"},
}

REGION_LABELS = {
    "cn": "🇨🇳 China", "gl": "🌍 Global", "in": "🇮🇳 India", "eu": "🇪🇺 Europe",
    "id": "🇮🇩 Indonesia", "sg": "🇸🇬 SEA", "tw": "🇹🇼 Taiwan", "ru": "🇷🇺 Russia",
    "tr": "🇹🇷 Turkey", "th": "🇹🇭 Thailand", "my": "🇲🇾 Malaysia", "vn": "🇻🇳 Vietnam",
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Data Classes
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
@dataclass
class OTAResult:
    success: bool
    error: Optional[str] = None
    version: Optional[str] = None
    ota_version: Optional[str] = None
    download_url: Optional[str] = None
    size: Optional[str] = None
    md5: Optional[str] = None
    security_patch: Optional[str] = None
    published_time: Optional[str] = None
    changelog: Optional[str] = None
    expires: Optional[datetime] = None
    response_code: int = 0

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Crypto Helpers
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
def _generate_random_string(length: int = 64) -> str:
    return ''.join(random.choices(string.ascii_uppercase + string.digits, k=length))

def _generate_random_bytes(length: int) -> bytes:
    return os.urandom(length)

def _generate_protected_key(aes_key: bytes, public_key_pem: str) -> str:
    public_key = serialization.load_pem_public_key(public_key_pem.encode(), backend=default_backend())
    key_b64 = base64.b64encode(aes_key)
    ciphertext = public_key.encrypt(
        key_b64,
        padding.OAEP(mgf=padding.MGF1(algorithm=hashes.SHA1()), algorithm=hashes.SHA1(), label=None)
    )
    return base64.b64encode(ciphertext).decode()

def _aes_ctr_encrypt(data: bytes, key: bytes, iv: bytes) -> bytes:
    cipher = Cipher(algorithms.AES(key), modes.CTR(iv), backend=default_backend())
    enc = cipher.encryptor()
    return enc.update(data) + enc.finalize()

def _aes_ctr_decrypt(ciphertext: bytes, key: bytes, iv: bytes) -> bytes:
    cipher = Cipher(algorithms.AES(key), modes.CTR(iv), backend=default_backend())
    dec = cipher.decryptor()
    return dec.update(ciphertext) + dec.finalize()

def _replace_gauss_url(url: str) -> str:
    if not url or url == "N/A":
        return url
    return url.replace(
        "https://gauss-otacostauto-cn.allawnfs.com/",
        "https://gauss-componentotacostmanual-cn.allawnfs.com/"
    )

def _extract_expiration(url: str) -> Optional[datetime]:
    for pattern in [r'Expires=(\d+)', r'x-oss-expires=(\d+)']:
        m = re.search(pattern, url)
        if m:
            try:
                return datetime.fromtimestamp(int(m.group(1)))
            except (ValueError, TypeError):
                continue
    return None

def _get_redirect_url(url: str, max_retries: int = 3) -> str:
    headers = {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 13; SM-G998B) AppleWebKit/537.36',
        'Accept': 'application/json,text/html,*/*',
        'userId': 'oplus-ota|00000001',
    }
    for attempt in range(max_retries):
        try:
            r = requests.get(url, headers=headers, allow_redirects=False, timeout=10)
            if r.status_code == 302:
                return r.headers.get('Location', url)
            return url
        except Exception:
            if attempt == max_retries - 1:
                return url
            time.sleep(2 * (attempt + 1))
    return url

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Region / Key Helpers
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
def _get_public_key_for_region(region: str, gray: int = 0):
    key_region = "sg" if region not in ["cn", "eu", "in"] else region
    if gray == 1 and region == "cn":
        region = "cn_gray"
    public_key = PUBLIC_KEYS[key_region]
    if region in ["cn", "cn_gray", "eu", "in"]:
        config = REGION_CONFIG[region]
    else:
        config = REGION_CONFIG["sg_host"].copy()
        config.update(REGION_CONFIG[region])
    return public_key, config

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  OTA Query Core
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
def _process_ota_version(ota_prefix: str, region: str) -> Tuple[str, str]:
    """Convert OTA prefix + region into full OTA version string and model."""
    parts = ota_prefix.split("_")
    base_model = parts[0]

    if region.lower() in ["eu", "ru", "tr"]:
        model = f"{base_model}{region.upper()}"
    else:
        model = base_model

    ota_version = f"{ota_prefix}.01_0001_197001010000" if len(parts) < 3 else ota_prefix
    return ota_version, model

def _build_headers(ota_version: str, model: str, mode: str, region_config: dict,
                   device_id: str, protected_key: str) -> dict:
    lang = region_config["language"]
    return {
        "language": lang, "newLanguage": lang,
        "androidVersion": "unknown", "colorOSVersion": "unknown", "romVersion": "unknown",
        "infVersion": "1", "otaVersion": ota_version, "model": model, "mode": mode,
        "nvCarrier": region_config["carrier_id"],
        "pipelineKey": "ALLNET", "operator": "ALLNET", "companyId": "", "version": "2",
        "deviceId": device_id,
        "Content-Type": "application/json; charset=utf-8",
        "protectedKey": json.dumps({
            "SCENE_1": {
                "protectedKey": protected_key,
                "version": str(time.time_ns() + 10**9 * 60 * 60 * 24),
                "negotiationVersion": region_config["public_key_version"]
            }
        })
    }

def _query_single(ota_version: str, model: str, region: str, mode: str = "taste") -> OTAResult:
    """Execute a single OTA query against the server."""
    try:
        public_key, region_config = _get_public_key_for_region(region)
    except KeyError:
        return OTAResult(False, error=f"Unsupported region: {region}")

    aes_key = _generate_random_bytes(32)
    iv = _generate_random_bytes(16)
    device_id = _generate_random_string(64)
    guid = "0" * 64

    headers = _build_headers(ota_version, model, mode, region_config, device_id,
                              _generate_protected_key(aes_key, public_key))

    body = {
        "mode": "0", "time": int(time.time() * 1000),
        "isRooted": "0", "isLocked": True, "type": "0",
        "deviceId": guid.lower(), "opex": {"check": True}
    }
    cipher_text = _aes_ctr_encrypt(json.dumps(body).encode(), aes_key, iv)
    url = f"https://{region_config['host']}/update/v3"

    for attempt in range(3):
        try:
            resp = requests.post(url, headers=headers, timeout=30, json={
                "params": json.dumps({
                    "cipher": base64.b64encode(cipher_text).decode(),
                    "iv": base64.b64encode(iv).decode()
                })
            })
            return _parse_response(resp, aes_key)
        except Exception as e:
            if attempt == 2:
                return OTAResult(False, error=f"Connection failed: {e}")
            time.sleep(5 * (attempt + 1))

    return OTAResult(False, error="Max retries exceeded")

def _parse_response(response: requests.Response, aes_key: bytes) -> OTAResult:
    """Parse encrypted OTA server response."""
    try:
        result = response.json()
    except json.JSONDecodeError:
        return OTAResult(False, error="Invalid JSON response")

    status = result.get("responseCode", 0)
    if status != 200:
        error_map = {
            2004: "No update available for this device/region",
            308: "Rate limited — try again later",
            500: "Server error",
            204: "Device not in test set",
            2200: "Device not in test set",
        }
        return OTAResult(False, error=error_map.get(status, f"Server error (code {status})"), response_code=status)

    try:
        encrypted_body = json.loads(result["body"])
        decrypted = _aes_ctr_decrypt(
            base64.b64decode(encrypted_body["cipher"]),
            aes_key,
            base64.b64decode(encrypted_body["iv"])
        )
        data = json.loads(decrypted.decode())

        # Extract published time
        published_time = None
        if ts := data.get("publishedTime"):
            try:
                published_time = datetime.fromtimestamp(ts / 1000).strftime("%Y-%m-%d %H:%M")
            except Exception:
                pass

        # Extract download link from first component
        download_url = None
        size = None
        md5 = None
        expires = None
        comp_list = data.get("components", [])
        if isinstance(comp_list, list) and comp_list:
            comp = comp_list[0]
            if isinstance(comp, dict):
                pkts = comp.get("componentPackets", {})
                if isinstance(pkts, dict):
                    manual_url = _replace_gauss_url(pkts.get("manualUrl", ""))
                    if manual_url and manual_url != "N/A":
                        if "downloadCheck" in manual_url:
                            download_url = _replace_gauss_url(_get_redirect_url(manual_url))
                            expires = _extract_expiration(download_url)
                        else:
                            download_url = manual_url
                    size = pkts.get("size", "N/A")
                    md5 = pkts.get("md5", "N/A")

        # Extract changelog
        desc = data.get("description")
        changelog = None
        if isinstance(desc, dict):
            changelog = _replace_gauss_url(desc.get("panelUrl"))

        version = data.get("realVersionName", data.get("versionName", "N/A"))
        ota_version = data.get("realOtaVersion", data.get("otaVersion", "N/A"))

        return OTAResult(
            success=True, version=version, ota_version=ota_version,
            download_url=download_url, size=size, md5=md5,
            security_patch=data.get("securityPatch", "N/A"),
            published_time=published_time, changelog=changelog,
            expires=expires, response_code=200
        )
    except Exception as e:
        return OTAResult(False, error=f"Parse error: {e}", response_code=status)

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Public API
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# In-memory cache: {(prefix, region): {"result": OTAResult, "ts": timestamp}}
_ota_cache: Dict[Tuple[str, str], dict] = {}
_CACHE_TTL = 6 * 3600  # 6 hours

def resolve_ota(ota_prefix: str, region: str) -> OTAResult:
    """
    Resolve OTA for a device prefix + region.
    Uses taste mode + anti=1 bypass for ColorOS 16.
    Auto-tries suffixes _11.A, _11.C, _11.F, _11.H, _11.J.
    Returns the first successful result.
    """
    cache_key = (ota_prefix.upper(), region.lower())
    cached = _ota_cache.get(cache_key)
    if cached and (time.time() - cached["ts"]) < _CACHE_TTL:
        # Return cached metadata but re-resolve download URL (links expire in 10-30 min)
        result = cached["result"]
        if result.success and result.download_url and "downloadCheck" in (result.download_url or ""):
            # URL may have expired — but we still return it, workflow must start fast
            pass
        return result

    # Auto-complete: try all suffixes
    suffixes = ["_11.A", "_11.C", "_11.F", "_11.H", "_11.J"]
    base = ota_prefix.upper()
    best_result = None

    for suffix in suffixes:
        candidate = base + suffix
        ota_version, model = _process_ota_version(candidate, region)

        # Try taste mode first (anti-query bypass)
        result = _query_single(ota_version, model, region, mode="taste")

        # Fallback: try IN suffix for India
        if not result.success and result.response_code == 2004 and region == "in":
            result = _query_single(ota_version, f"{model}IN", region, mode="taste")

        # Fallback: manual mode
        if not result.success and result.response_code == 2004:
            result = _query_single(ota_version, model, region, mode="manual")

        if result.success:
            _ota_cache[cache_key] = {"result": result, "ts": time.time()}
            return result

        if best_result is None:
            best_result = result

    # None succeeded — cache the failure too (shorter TTL)
    fail_result = best_result or OTAResult(False, error="No firmware found")
    return fail_result


def format_size(size_str: str) -> str:
    """Convert size string (bytes) to human-readable GB/MB."""
    try:
        size_bytes = int(size_str)
        if size_bytes > 1_000_000_000:
            return f"{size_bytes / 1_073_741_824:.1f} GB"
        elif size_bytes > 1_000_000:
            return f"{size_bytes / 1_048_576:.0f} MB"
        else:
            return f"{size_bytes / 1024:.0f} KB"
    except (ValueError, TypeError):
        return size_str or "Unknown"
