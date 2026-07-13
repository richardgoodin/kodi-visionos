# _scproxy stub for visionOS (xrOS) Python.
# The real _scproxy C extension is macOS-only and is not built for the
# iOS/tvOS/visionOS CPython, but urllib (sys.platform == 'darwin') imports it
# to auto-detect system proxies. This device uses no system proxy, so return
# empty results. This lets urllib.getproxies()/proxy_bypass succeed for every
# Python add-on instead of raising ModuleNotFoundError: No module named '_scproxy'.

def _get_proxies():
    return {}

def _get_proxy_settings():
    return {'exclude_simple': False, 'exceptions': []}
