# a6s.el — A6s for Emacs

[![Test](https://github.com/The-Autonoma/a6s-emacs/workflows/CI/badge.svg)](https://github.com/The-Autonoma/a6s-emacs/actions)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](./LICENSE)

Intelligent multi-agent orchestration inside Emacs. Invoke A6s RIGOR
agents to explain, refactor, review, and generate tests from any
buffer — without leaving your editor and without holding any API
credentials.

This package is a thin client that talks to the local A6s CLI daemon
(`a6s code --daemon`) over WebSocket. The daemon is the only component
that talks to the remote orchestrator.

## Install

### straight.el

```elisp
(straight-use-package
 '(a6s :type git :host github :repo "The-Autonoma/a6s-emacs"
       :files (:defaults)))
(a6s-setup)
```

### Manual

```sh
git clone https://github.com/The-Autonoma/a6s-emacs.git ~/.emacs.d/a6s
```

```elisp
(add-to-list 'load-path "~/.emacs.d/a6s")
(require 'a6s)
(a6s-setup)
```

## Prerequisites

- Emacs 27.1 or newer
- The A6s CLI running as a daemon: `a6s code --daemon`
- Packages: `websocket` 1.14+, `transient` 0.4+

## Quick start

1. Start the daemon in a terminal:
   ```sh
   a6s code --daemon
   ```

2. Enable the minor mode in any buffer:
   ```
   M-x a6s-mode
   ```

3. Open the transient menu with `C-c C-a`, then:

   | Key | Action |
   |---|---|
   | `c` / `d` | Connect / Disconnect |
   | `i` | Invoke agent (pick from list + task prompt) |
   | `e` | Explain selected region |
   | `r` | Refactor selected region |
   | `v` | Review selected region |
   | `t` | Generate tests for region |
   | `p` / `A` | Preview / Apply pending artifacts |
   | `l` / `x` | List tasks / Cancel task |

## Customization

All options live in the `a6s` customize group.

| Variable | Default | Description |
|---|---|---|
| `a6s-daemon-port` | `9876` | Daemon WebSocket port |
| `a6s-daemon-host` | `"localhost"` | Daemon host (leave default) |
| `a6s-auto-connect` | `t` | Connect when `a6s-mode` enables |
| `a6s-telemetry-enabled` | `nil` | Opt-in, prompted on first use |
| `a6s-request-timeout` | `30` | Per-request timeout (seconds) |
| `a6s-connect-timeout` | `5` | Connect timeout (seconds) |
| `a6s-max-input-length` | `10000` | Max user input (characters) |
| `a6s-max-reconnect-attempts` | `5` | Exponential-backoff cap |

## Security

- **No credentials** stored or transmitted by this package.
- **Localhost only** — the WebSocket client connects to
  `ws://localhost:<port>/ws` and rejects remote URLs.
- **Input validation** — every user-provided string is trimmed,
  non-empty, and ≤10,000 characters.
- **Telemetry** — opt-in, defaults to `nil`, prompted once.

## How it works

```
+-------------------+  WebSocket   +--------------+   (authenticated)   +--------------+
| Emacs (this pkg)  | <----------> |  a6s daemon  | ------------------> | Orchestrator |
+-------------------+              +--------------+                     +--------------+
```

The extension implements the
[A6s Daemon Protocol v2.0](https://www.theautonoma.io/docs/build/cli/daemon)
(20 RPC methods, 3 event streams), including fleet management and workflow orchestration.

## Development

```sh
cask install
make compile   # byte-compile, warnings as errors
make lint      # package-lint + checkdoc
make test      # ERT + undercover coverage (fails below 80%)
```

## Contributing

Bug reports and pull requests are welcome at
[The-Autonoma/a6s-emacs](https://github.com/The-Autonoma/a6s-emacs/issues).

## License

Apache 2.0 — see [LICENSE](./LICENSE).
