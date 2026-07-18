"""Unambiguous import alias for the shared schema module."""
try:
    from .schema import *  # noqa: F401,F403
except ImportError:  # Standalone HM2019 entry compatibility.
    from schema import *  # noqa: F401,F403
