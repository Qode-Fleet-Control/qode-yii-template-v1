# CLAUDE.md

Conventions for agents working in this repo.

- Keep the request logger: every HTTP request must log one JSON line with status and duration (Monitoring tab). It is marked `KEEP THIS` in the code, and the Build check fails without it. Health checks
  are logged too; never log request bodies, cookies, auth headers or query strings. If you add or
  replace the HTTP server, give it the same line.
