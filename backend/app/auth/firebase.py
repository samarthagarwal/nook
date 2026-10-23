"""Firebase Authentication - verify ID tokens from iOS app."""

import firebase_admin
from firebase_admin import auth, credentials
from fastapi import HTTPException, Security
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config import get_settings

# Security scheme for Bearer token
security = HTTPBearer()

# Track if Firebase has been initialized
_firebase_initialized = False


def init_firebase() -> None:
    """Initialize Firebase Admin SDK. Call once at startup."""
    global _firebase_initialized
    if _firebase_initialized:
        return

    settings = get_settings()
    cred = credentials.Certificate(settings.firebase_credentials)
    firebase_admin.initialize_app(cred)
    _firebase_initialized = True


async def get_current_user(
    credentials: HTTPAuthorizationCredentials = Security(security),
) -> dict:
    """
    Verify Firebase ID token and extract user info.

    Returns:
        dict with keys: uid, email (optional), name (optional)

    Raises:
        HTTPException 401 if token is invalid or expired
    """
    try:
        decoded = auth.verify_id_token(credentials.credentials)
        return {
            "uid": decoded["uid"],
            "email": decoded.get("email"),
            "name": decoded.get("name"),
        }
    except auth.ExpiredIdTokenError:
        raise HTTPException(status_code=401, detail="Token has expired")
    except auth.RevokedIdTokenError:
        raise HTTPException(status_code=401, detail="Token has been revoked")
    except auth.InvalidIdTokenError as e:
        raise HTTPException(status_code=401, detail=f"Invalid token: {e}")
    except Exception as e:
        raise HTTPException(status_code=401, detail=f"Authentication failed: {e}")
