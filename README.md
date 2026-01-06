# Keenetic PingTool

It logs Ping, Jitter, and Packet Loss to a SQLite database, visualizes the data via a responsive HTML5 dashboard using Chart.js, and automatically runs MTR diagnostics when latency spikes.

## Features

- 📊 **Dashboard:** Generates a standalone `pingtool.html` file with interactive graphs (Ping, Jitter, Loss).
- 💾 **SQLite Storage:** Efficiently stores historical data with auto-rotation (default 45 days).
- 🔍 **Auto-Diagnostics:** Trigger an `MTR` trace automatically when ping exceeds a threshold or packet loss is detected.
- 🚀 **Lightweight:** Written in Bash, optimized for routers.

## Prerequisites

This script requires **Entware** installed on your Keenetic/Router.
You need to install the following packages:

```bash
opkg update
opkg install bash sqlite3-cli ping mtr
```

Note: traceroute is used as a fallback if mtr is missing.

## Installation
**Download the script** Place the script in /opt/bin/ (or any persistent folder).

**Configuration** Edit the top section of pingtool.sh to customize:

PING_TARGET: The IP to ping (Default: 8.8.8.8)

TRIGGER_LATENCY: Threshold in ms to trigger MTR (Default: 30ms)

WEB_DIR: Where to save the HTML file (Default: /opt/var/www)

## Usage

### Manual Run
```bash
/opt/bin/pingtool.sh
```

### Automation (Cron)
Add a cron job to run it every minute. Edit crontab:
```bash
nano /opt/etc/crontab
```

Add this line:
```bash
*/1 * * * * root /opt/bin/pingtool.sh > /dev/null 2>&1
```

## Viewing the Dashboard
The script generates pingtool.html in /opt/var/www. If you have the Entware Web Server (nginx/lighttpd) running, you can access it via browser: http://192.168.1.1:81/ping/ (Port depends on your setup).

Alternatively, expose the folder via SMB or FTP to open the file locally.

## Web Server Setup (Lighttpd)

To view the dashboard in your browser, ensure **Lighttpd** is configured to serve the directory where the script saves the HTML file (`/opt/var/www`).

1. **Install Lighttpd** (if not installed):
```bash
opkg install lighttpd
```

2. **Configure Lighttpd:** Edit the configuration file:
```bash
nano /opt/etc/lighttpd/lighttpd.conf
```
Make sure these two lines are set correctly:
```bash
# The folder where connmon.html is saved
server.document-root = "/opt/var/www" 
# Use port 81 (or 8081) to avoid conflict with Router Admin UI
server.port = 81
```

3. **Restart the Service:**
```bash
/opt/etc/init.d/S80lighttpd restart
```

4. **Access the Dashboard:** Open your browser and navigate to:
http://YOUR_ROUTER_IP:81/ping/

![alt text](https://github.com/mattheweli/keenetic-pingtool/blob/main/Screenshot%202026-01-04%20155808.png)
