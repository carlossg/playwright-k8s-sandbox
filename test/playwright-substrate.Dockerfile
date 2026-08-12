# Shared slim Playwright image used by ALL THREE backends (agent-sandbox,
# OpenShell, substrate). Consumers:
#   - proxy/test/playwright-sandboxtemplate.yaml          (agent-sandbox e2e)
#   - proxy/test/playwright-client-job.yaml               (e2e WS client)
#   - proxy/test/playwright-mcp-client-job.yaml           (e2e MCP client)
#   - proxy/test/substrate-actortemplate-playwright.yaml  (substrate flavour)
#   - proxy/deploy/examples/agent-sandbox/sandboxtemplate.yaml
#   - proxy/deploy/examples/openshell/sandboxtemplate.yaml
#
# The official mcr.microsoft.com/playwright image is ~1.5 GiB (bundles Chromium,
# Firefox, WebKit, ffmpeg, plus npm/yarn/corepack). atelet OOM-kills while
# streaming an image that large into rustfs, even with 16 GiB host memory.
#
# This builds on node:22-bookworm-slim (~150 MiB) and installs only the
# chromium runtime + npm playwright client. Final image is ~500-600 MiB.
#
# Dual-protocol: the image serves both the native Playwright WebSocket
# (chromium.launchServer, server.js on PORT) AND MCP-over-HTTP
# (@playwright/mcp on MCP_PORT). @playwright/mcp cannot share a process/port
# with chromium.launchServer, so server.js spawns it as a second listener.
# playwright is pinned to 1.53.0 because that is the version @playwright/mcp
# @0.0.29 depends on; both share the single installed Chromium build.
FROM node:22-bookworm-slim

# Playwright installs browsers into a stable path; freeze it at build time so
# the install-deps step puts the system libs where chromium will look.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    NODE_PATH=/usr/local/lib/node_modules

# playwright-core is installed explicitly at the global root. @playwright/mcp
# is ESM and its `import 'playwright-core'` uses Node's ESM resolver, which
# ignores NODE_PATH and only walks node_modules upward from the importing file.
# npm nests playwright-core under playwright/node_modules (not hoisted to the
# global root), so without this line the MCP CLI dies with
# ERR_MODULE_NOT_FOUND: Cannot find package 'playwright-core'. Pinned to 1.53.0
# to match the single installed Chromium build.
RUN npm install -g --silent \
      playwright@1.53.0 \
      playwright-core@1.53.0 \
      @playwright/mcp@0.0.29 \
      @modelcontextprotocol/sdk@1.30.0 \
 && npx --yes playwright@1.53.0 install --with-deps chromium \
 && rm -rf /root/.npm /tmp/* /var/lib/apt/lists/* \
 && node -e "require('playwright')" \
 && node -e "require('@modelcontextprotocol/sdk/client/index.js')" \
 && node -e "require.resolve('playwright-core', { paths: [require('path').dirname(require.resolve('@playwright/mcp/package.json'))] })"   # fail build if @playwright/mcp can't resolve playwright-core (its ESM import walks node_modules from the package dir, ignoring NODE_PATH)

COPY server.js /server.js

# 9222 = native Playwright WebSocket (chromium.launchServer)
# 9223 = MCP-over-HTTP (@playwright/mcp), only started when MCP_PORT is set
EXPOSE 80 9222 9223
CMD ["node", "/server.js"]
