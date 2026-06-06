# Shared slim Playwright image used by ALL THREE backends (agent-sandbox,
# OpenShell, substrate). Consumers:
#   - proxy/test/playwright-sandboxtemplate.yaml          (agent-sandbox e2e)
#   - proxy/test/playwright-client-job.yaml               (e2e client)
#   - proxy/test/substrate-actortemplate-playwright.yaml  (substrate flavour)
#   - proxy/deploy/examples/agent-sandbox/sandboxtemplate.yaml
#   - proxy/deploy/examples/openshell/sandboxtemplate.yaml
#
# The official mcr.microsoft.com/playwright image is ~1.5 GiB (bundles Chromium,
# Firefox, WebKit, ffmpeg, plus npm/yarn/corepack). atelet OOM-kills while
# streaming an image that large into rustfs, even with 16 GiB host memory.
#
# This builds on node:22-bookworm-slim (~150 MiB) and installs only the
# chromium runtime + npm playwright client. Final image is ~400-500 MiB.
FROM node:22-bookworm-slim

# Playwright installs browsers into a stable path; freeze it at build time so
# the install-deps step puts the system libs where chromium will look.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    NODE_PATH=/usr/local/lib/node_modules

RUN npm install -g --silent playwright@1.49.0 \
 && npx --yes playwright@1.49.0 install --with-deps chromium \
 && rm -rf /root/.npm /tmp/* /var/lib/apt/lists/* \
 && node -e "require('playwright')"   # fail the build if NODE_PATH is wrong

COPY server.js /server.js

EXPOSE 80 9222
CMD ["node", "/server.js"]
