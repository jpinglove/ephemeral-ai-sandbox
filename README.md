# Ephemeral AI SSH Sandbox

A secure, fully isolated, and auto-expiring **Arch Linux** container sandbox designed for AI coding agents and LLM execution. 

This script lets you safely provision a temporary environment with SSH access on **Debian, Ubuntu, or Arch Linux** hosts, allowing AI agents to run commands, install dependencies, and edit code without risking host-system corruption.

## 🚀 Key Features

*   **Zero-Proxy Reliable Build:** Explicitly bypasses host-level proxies during image construction to ensure consistent `pacman` repository synchronization.
*   **Auto-Expiry Self-Destruction:** Automatically schedules host-side cleanups using Systemd timers to completely wipe the container and custom build images once the duration lapses.
*   **Strict Security Isolation:** Runs with strict resource bounds (`--cpus`, `--memory`, and `--pids-limit`) without privileged modes or access to the host's Docker socket.
*   **Native Host Mounting:** Seamlessly pairs guest workspaces with chosen host subdirectories for easy code synchronization while leaving root assets safe.
*   **Plug-and-Play提权 (Sudo):** Grants passwordless `sudo` rights strictly *inside* the container, ensuring AI agents have full workspace configuration power without compromising the host machine.

## 🛠️ Requirements

*   **Host OS:** Debian 12+, Ubuntu 22.04+, Pop!_OS, or Arch Linux.
*   **Dependencies:** Docker Core/CE, Systemd, and `iproute2`.

## 📖 Quick Start

Simply run the script with root privileges on your host machine:

```bash
sudo bash ai-sandbox-arch-no-proxy.sh
```

### Custom Configurations

You can tune the runtime lifespan, SSH connectivity port, or the base OS image using transient environment overrides:

```bash
sudo env DURATION_SECONDS=3600 SSH_PORT=2223 bash ai-sandbox-arch-no-proxy.sh
```

## ⚠️ Safety Warning

This sandbox environment is strictly temporary. All changes, packages, and unmounted files within the container will be permanently destroyed upon expiry. Make sure your AI workflow saves output artifacts into the mapped host file hierarchy.


