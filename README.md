# autonoma.el — A6s for Emacs

[![MELPA](https://melpa.org/packages/autonoma-badge.svg)](https://melpa.org/#/autonoma)
[![Test](https://github.com/The-Autonoma/autonoma-emacs/workflows/test/badge.svg)](https://github.com/The-Autonoma/autonoma-emacs/actions)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](./LICENSE)

Intelligent multi-agent orchestration inside Emacs. Invoke A6s RIGOR
agents to explain, refactor, review, and generate tests from any
buffer — without leaving your editor and without holding any API
credentials.

This package is a thin client that talks to the local A6s CLI daemon
(`a6s code --daemon`) over WebSocket. The daemon is the only component
that talks to the remote orchestrator.

## Install

### MELPA

```elisp
(use-package autonoma
  :ensure t
  :hook (prog-mode . autonoma-mode)
  :custom
  (autonoma-daemon-port 9876)
  (autonoma-auto-connect t))
```

### straight.el

```elisp
(straight-use-package
 '(autonoma :type git :host github :repo "The-Autonoma/autonoma-emacs"
            :files (:defaults)))
(autonoma-setup)
```

### Manual

```sh
git clone https://github.com/The-Autonoma/autonoma-emacs.git ~/.emacs.d/autonoma
```

```elisp
(add-to-list 'load-path "~/.emacs.d/autonoma")
(require 'autonoma)
(autonoma-setup)
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
   M-x autonoma-mode
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

All options live in the `autonoma` customize group.

| Variable | Default | Description |
|---|---|---|
| `autonoma-daemon-port` | `9876` | Daemon WebSocket port |
| `autonoma-daemon-host` | `"localhost"` | Daemon host (leave default) |
| `autonoma-auto-connect` | `t` | Connect when `autonoma-mode` enables |
| `autonoma-telemetry-enabled` | `nil` | Opt-in, prompted on first use |
| `autonoma-request-timeout` | `30` | Per-request timeout (seconds) |
| `autonoma-connect-timeout` | `5` | Connect timeout (seconds) |
| `autonoma-max-input-length` | `10000` | Max user input (characters) |
| `autonoma-max-reconnect-attempts` | `5` | Exponential-backoff cap |

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
[DAEMON-PROTOCOL](https://github.com/The-Autonoma/autonoma-emacs/blob/main/CLAUDE.md#protocol-conformance)
(13 RPC methods, 3 event streams). See
[`CLAUDE.md`](./CLAUDE.md) for architecture details.

## Development

```sh
cask install
make compile   # byte-compile, warnings as errors
make lint      # package-lint + checkdoc
make test      # ERT + undercover coverage (fails below 80%)
```

## Contributing

Bug reports and pull requests are welcome at
[The-Autonoma/autonoma-emacs](https://github.com/The-Autonoma/autonoma-emacs/issues).

## License

Apache 2.0 — see [LICENSE](./LICENSE).
