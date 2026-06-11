# playwright-k8s-sandbox

A Kubernetes proxy that fronts Playwright (MCP HTTP + native WebSocket) and
routes each calling agent pod to its own Playwright sandbox. Three backends:
`agent-sandbox`, `openshell`, `substrate`.

- Code: [`cmd/`](cmd/) and [`internal/`](internal/)
- How it works, sequence diagrams, bench results: **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**
- Local kind harness and bench script: [`test/`](test/)
- Deployment: **[DEPLOYMENT.md](DEPLOYMENT.md)** and [`deploy/`](deploy/)
