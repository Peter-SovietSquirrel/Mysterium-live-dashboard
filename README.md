# Mysterium Live Dashboard

A beautiful, real-time monitoring dashboard for Mysterium Network nodes with live session tracking and quality metrics.

## Features

- **Live Sessions Dashboard** - Real-time active session monitoring with 10-second refresh
- **Quality Monitor** - Node performance metrics including quality scores, uptime, bandwidth, and earnings
- **Beautiful Dark Purple Theme** - Matching aesthetic across all dashboards
- **Multi-Node Support** - Monitor multiple nodes (native + Docker) from one interface
- **Auto-Refresh** - Live data updates without manual refresh
- **Earnings Tracking** - 24-hour earnings display per node

## Requirements

- Linux system (Ubuntu 20.04+ recommended)
- Mysterium node(s) running (native or Docker)
- Python 3 (for web server)
- curl and jq packages
- systemd (for auto-start services)

## Quick Installation

1. Clone the repository:
```bash
git clone https://github.com/Peter-SovietSquirrel/mysterium-live-dashboard.git
cd mysterium-live-dashboard
```

2. Run the installer:
```bash
chmod +x install.sh
sudo ./install.sh
```

3. Follow the prompts to configure your nodes

4. Access your dashboards:
   - Live Sessions: http://YOUR_SERVER_IP:8888/live_sessions.html
   - Quality Monitor: http://YOUR_SERVER_IP:8888/quality_monitor.html

## Services

The dashboard runs three systemd services:

```bash
sudo systemctl status mysterium-sessions
sudo systemctl status mysterium-quality
sudo systemctl status mysterium-webserver
```

## Contributing

Contributions are welcome! Please submit a Pull Request.

## Credits

Created by **Peter** ([Peter-SovietSquirrel](https://github.com/Peter-SovietSquirrel))

Developed for the Mysterium Network community.

## License

MIT License - see LICENSE file for details

## Changelog

### v1.0.0 (2026-04-21)
- Initial release
- Live sessions dashboard
- Quality monitoring dashboard
- Auto-installer
- Multi-node support
