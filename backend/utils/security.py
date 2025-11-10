import os
import base64
import hashlib
import secrets
import re
from datetime import timezone as _tz

UTC = _tz.utc
MIN_LEN_PASSWORD = 8
SCRYPT_N = 2**14  # CPU/memory cost factor
SCRYPT_R = 8      # block size
SCRYPT_P = 8      # parallelization factor

def generate_token() -> str:
    return secrets.token_urlsafe(48) # 256-bit+ token, URL-safe

def hash_password(password: str) -> str:
    if not check_register_password(password):
        raise ValueError("Too weak password")
    salt = os.urandom(32) # 32 bytes salt
    try:
        key = hashlib.scrypt(password.encode(encoding = 'utf-8', errors = 'strict'), salt = salt, n = SCRYPT_N,r = SCRYPT_R, p = SCRYPT_P)
        return base64.b64encode(salt + key).decode(encoding = 'utf-8')
    except ValueError as e:
        raise ValueError(f"Hashing error: {e}") from e

def verify_password(hash: str, non_hash: str) -> bool:
    data = base64.b64decode(hash.encode(encoding = 'utf-8', errors = 'strict'))
    salt, stored_key = data[:32], data[32:]
    new_key = hashlib.scrypt(non_hash.encode(encoding = 'utf-8', errors = 'strict'), salt = salt, n = SCRYPT_N, r = SCRYPT_R, p = SCRYPT_P)
    return secrets.compare_digest(new_key, stored_key)

def check_register_password(password: str) -> bool:
    if not isinstance(password, str) or len(password) < MIN_LEN_PASSWORD:
        return False
    if not re.search(r'[A-Z]', password):  # at least one uppercase
        return False
    if not re.search(r'[a-z]', password):  # at least one lowercase
        return False
    if not re.search(r'\d', password):     # at least one digit
        return False
    return True