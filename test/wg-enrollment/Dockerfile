FROM python:3-slim

# Unit-test container for the WG M1 enrollment primitives.
# coincurve binds libsecp256k1 — the independent BIP340 oracle.
RUN pip install --no-cache-dir coincurve==21.0.0

WORKDIR /repo
# The repo is bind-mounted at run time (see run.sh); nothing is copied
# into the image, so the tests always exercise the checkout you point
# them at.
ENTRYPOINT ["python3", "-m", "unittest", "discover", "-s", "test/wg-enrollment", "-v"]
