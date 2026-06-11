# Tiny Node HTTP server used as a CONTROL workload for substrate gVisor tests.
# Pure Node + a single-file server, no browser. If THIS doesn't reach
# STATUS_RUNNING under substrate's golden-actor workflow, the failure isn't
# Chromium-specific.
FROM node:22-bookworm-slim

WORKDIR /app
COPY server.js /app/server.js

EXPOSE 9222
CMD ["node", "/app/server.js"]
