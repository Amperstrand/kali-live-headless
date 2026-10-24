FROM python:3-slim

# Unit-test container for the rescue-channel ws relay. No dependencies —
# the library and the test client are pure stdlib by design.
WORKDIR /repo
ENTRYPOINT ["python3", "-m", "unittest", "discover", "-s", "test/ws-relay", "-v"]
