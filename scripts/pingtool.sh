#!/opt/bin/bash
export PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin

# ==============================================================================
# USER CONFIGURATION
# ==============================================================================
PING_TARGET="8.8.8.8"
PING_TARGET_V6="2001:4860:4860::8888"
PING_DURATION=30
TRIGGER_LATENCY=30

WEB_DIR="/opt/var/www/ping"
DB_DIR="/opt/etc/pingtool"
DB_FILE="$DB_DIR/pingtool.db"
LOCK_FILE="/tmp/pingtool.lock"
RETENTION_DAYS=45
MAX_DISPLAY_POINTS=2000

# ==============================================================================
# LOCK MANAGEMENT & INIT
# ==============================================================================
if [ -f "$LOCK_FILE" ]; then
    if [ $(($(date +%s) - $(date +%s -r "$LOCK_FILE"))) -gt 180 ]; then
        echo "WARNING: Stale lock file found (>3 min). Forcing removal."
        rm -f "$LOCK_FILE"
    else
        echo "Script already running. Exiting."
        exit 1
    fi
fi
touch "$LOCK_FILE"
trap "rm -f $LOCK_FILE" EXIT

echo "[$(date '+%Y-%m-%d %H:%M:%S')] pingtool: Starting Dual-Stack test..."

mkdir -p "$DB_DIR"
mkdir -p "$WEB_DIR"

if [ ! -f "$DB_FILE" ]; then
    echo " - First run: Initializing SQLite Database..."
    sqlite3 "$DB_FILE" "CREATE TABLE IF NOT EXISTS stats (id INTEGER PRIMARY KEY, timestamp INTEGER, ping REAL, jitter REAL, loss REAL);"
    sqlite3 "$DB_FILE" "CREATE INDEX IF NOT EXISTS idx_ts ON stats (timestamp);"
    sqlite3 "$DB_FILE" "CREATE TABLE IF NOT EXISTS stats_v6 (id INTEGER PRIMARY KEY, timestamp INTEGER, ping REAL, jitter REAL, loss REAL);"
    sqlite3 "$DB_FILE" "CREATE INDEX IF NOT EXISTS idx_ts_v6 ON stats_v6 (timestamp);"
fi

NOW=$(date +%s)

# ==============================================================================
# IPv4 TEST
# ==============================================================================
echo -n " - Testing IPv4 ($PING_TARGET)... "
TMP_PING="/tmp/pingtool_v4.tmp"
ping -w "$PING_DURATION" -i 1 "$PING_TARGET" > "$TMP_PING"

LOSS=$(grep -oP '\d+(?=% packet loss)' "$TMP_PING"); [ -z "$LOSS" ] && LOSS=100
AVG_PING=$(tail -n 1 "$TMP_PING" | awk -F '/' '{print $5}' | sed 's/[^0-9.]//g'); [ -z "$AVG_PING" ] && AVG_PING=0

if [ "$LOSS" -lt 100 ]; then
    TIMES=$(grep "time=" "$TMP_PING" | sed 's/.*time=\([0-9.]*\) .*/\1/')
    JITTER=$(echo "$TIMES" | awk 'BEGIN {prev=0;td=0;c=0;f=1} {cur=$1; if(f==0){d=cur-prev; if(d<0)d=-d; td+=d; c++} prev=cur; f=0} END {if(c>0)printf "%.2f",td/c; else print "0"}')
else 
    JITTER=0
fi

echo "Ping=$AVG_PING ms | Jitter=$JITTER ms | Loss=$LOSS%"
sqlite3 "$DB_FILE" "INSERT INTO stats (timestamp, ping, jitter, loss) VALUES ($NOW, $AVG_PING, $JITTER, $LOSS);"

# ==============================================================================
# IPv6 TEST
# ==============================================================================
echo -n " - Testing IPv6 ($PING_TARGET_V6)... "
TMP_PING_V6="/tmp/pingtool_v6.tmp"
PING6_CMD="ping6"; command -v ping6 >/dev/null 2>&1 || PING6_CMD="ping -6"
$PING6_CMD -w "$PING_DURATION" -i 1 "$PING_TARGET_V6" > "$TMP_PING_V6" 2>/dev/null

LOSS_V6=$(grep -oP '\d+(?=% packet loss)' "$TMP_PING_V6"); [ -z "$LOSS_V6" ] && LOSS_V6=100
AVG_PING_V6=$(tail -n 1 "$TMP_PING_V6" | awk -F '/' '{print $5}' | sed 's/[^0-9.]//g'); [ -z "$AVG_PING_V6" ] && AVG_PING_V6=0

if [ "$LOSS_V6" -lt 100 ]; then
    TIMES_V6=$(grep "time=" "$TMP_PING_V6" | sed 's/.*time=\([0-9.]*\) .*/\1/')
    JITTER_V6=$(echo "$TIMES_V6" | awk 'BEGIN {prev=0;td=0;c=0;f=1} {cur=$1; if(f==0){d=cur-prev; if(d<0)d=-d; td+=d; c++} prev=cur; f=0} END {if(c>0)printf "%.2f",td/c; else print "0"}')
else 
    JITTER_V6=0
fi

echo "Ping=$AVG_PING_V6 ms | Jitter=$JITTER_V6 ms | Loss=$LOSS_V6%"
sqlite3 "$DB_FILE" "INSERT INTO stats_v6 (timestamp, ping, jitter, loss) VALUES ($NOW, $AVG_PING_V6, $JITTER_V6, $LOSS_V6);"

rm -f "$TMP_PING" "$TMP_PING_V6"

# ==============================================================================
# CLEANUP & ALERTS
# ==============================================================================
echo " - Cleaning old records (> $RETENTION_DAYS days)..."
sqlite3 "$DB_FILE" "DELETE FROM stats WHERE timestamp < strftime('%s', 'now', '-$RETENTION_DAYS days');"
sqlite3 "$DB_FILE" "DELETE FROM stats_v6 WHERE timestamp < strftime('%s', 'now', '-$RETENTION_DAYS days');"

INCIDENT_LOG="$WEB_DIR/incidents.txt"

# Alert Logic IPv4
IS_HIGH_V4=$(awk -v p="$AVG_PING" -v t="$TRIGGER_LATENCY" 'BEGIN {print (p > t ? 1 : 0)}')
if [ "$LOSS" -gt 0 ] || [ "$IS_HIGH_V4" -eq 1 ]; then
    echo " ! ALERT IPv4: Anomalous values detected. Running MTR..."
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ IPv4 Alert: Ping=$AVG_PING ms | Loss=$LOSS%" >> "$INCIDENT_LOG"
    if command -v mtr >/dev/null 2>&1; then
        echo "--- MTR IPv4 Report ---" >> "$INCIDENT_LOG"
        mtr -4 -r -c 10 -w "$PING_TARGET" >> "$INCIDENT_LOG" 2>&1
        echo "-----------------------" >> "$INCIDENT_LOG"
    else
        echo "Error: mtr not found" >> "$INCIDENT_LOG"
    fi
fi

# Alert Logic IPv6
IS_HIGH_V6=$(awk -v p="$AVG_PING_V6" -v t="$TRIGGER_LATENCY" 'BEGIN {print (p > t ? 1 : 0)}')
if [ "$LOSS_V6" -gt 0 ] || [ "$IS_HIGH_V6" -eq 1 ]; then
    echo " ! ALERT IPv6: Anomalous values detected. Running MTR..."
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ IPv6 Alert: Ping=$AVG_PING_V6 ms | Loss=$LOSS_V6%" >> "$INCIDENT_LOG"
    if command -v mtr >/dev/null 2>&1; then
        echo "--- MTR IPv6 Report ---" >> "$INCIDENT_LOG"
        mtr -6 -r -c 10 -w "$PING_TARGET_V6" >> "$INCIDENT_LOG" 2>&1
        echo "-----------------------" >> "$INCIDENT_LOG"
    else
        echo "Error: mtr not found" >> "$INCIDENT_LOG"
    fi
fi

if [ -f "$INCIDENT_LOG" ]; then
    tail -n 200 "$INCIDENT_LOG" > "$INCIDENT_LOG.tmp" && mv "$INCIDENT_LOG.tmp" "$INCIDENT_LOG"
fi

# ==============================================================================
# GENERATE DATA.JS
# ==============================================================================
echo -n " - Generating JSON data file (data.js)... "
DATA_JS="$WEB_DIR/data.js"
DATE_UPDATE=$(date "+%d/%m/%Y %H:%M:%S")

JSON_V4=$(sqlite3 "$DB_FILE" "SELECT timestamp, ping, jitter, loss FROM stats ORDER BY timestamp DESC LIMIT $MAX_DISPLAY_POINTS;" | awk -F'|' '{printf "{x:%s000,p:%s,j:%s,l:%s},", $1, $2, $3, $4}' | sed 's/,$//')
JSON_V6=$(sqlite3 "$DB_FILE" "SELECT timestamp, ping, jitter, loss FROM stats_v6 ORDER BY timestamp DESC LIMIT $MAX_DISPLAY_POINTS;" | awk -F'|' '{printf "{x:%s000,p:%s,j:%s,l:%s},", $1, $2, $3, $4}' | sed 's/,$//')

STATS_V4=$(sqlite3 "$DB_FILE" "SELECT AVG(ping), AVG(jitter), AVG(loss) FROM (SELECT ping, jitter, loss FROM stats ORDER BY timestamp DESC LIMIT $MAX_DISPLAY_POINTS);")
STATS_V6=$(sqlite3 "$DB_FILE" "SELECT AVG(ping), AVG(jitter), AVG(loss) FROM (SELECT ping, jitter, loss FROM stats_v6 ORDER BY timestamp DESC LIMIT $MAX_DISPLAY_POINTS);")

cat <<EOF > "$DATA_JS"
window.PING_DATA = {
    updated: "$DATE_UPDATE",
    targets: { v4: "$PING_TARGET", v6: "$PING_TARGET_V6" },
    current: {
        v4: { ping: $AVG_PING, jitter: $JITTER, loss: $LOSS },
        v6: { ping: $AVG_PING_V6, jitter: $JITTER_V6, loss: $LOSS_V6 }
    },
    averages: {
        v4: { p: "$(echo $STATS_V4 | cut -d'|' -f1 | awk '{printf "%.2f",$1}')", j: "$(echo $STATS_V4 | cut -d'|' -f2 | awk '{printf "%.2f",$1}')", l: "$(echo $STATS_V4 | cut -d'|' -f3 | awk '{printf "%.2f",$1}')" },
        v6: { p: "$(echo $STATS_V6 | cut -d'|' -f1 | awk '{printf "%.2f",$1}')", j: "$(echo $STATS_V6 | cut -d'|' -f2 | awk '{printf "%.2f",$1}')", l: "$(echo $STATS_V6 | cut -d'|' -f3 | awk '{printf "%.2f",$1}')" }
    },
    history: {
        v4: [$JSON_V4].reverse(),
        v6: [$JSON_V6].reverse()
    }
};
EOF
echo "Done."

# ==============================================================================
# GENERATE STATIC HTML (FIXED: No Fill, Dots, Log Scale Fix)
# ==============================================================================
HTML_FILE="$WEB_DIR/index.html"
if [ ! -f "$HTML_FILE" ]; then
    echo " - index.html missing. Generating new template..."
cat <<'HTML_EOF' > "$HTML_FILE"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>Keenetic Dual-Stack Ping Monitor</title>
    <link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>🌐</text></svg>">
    
    <script src="chart.js"></script>
    <script src="chartjs-adapter-date-fns.js"></script>
    <script src="chartjs-plugin-zoom.js"></script>

    <style>
        :root { --bg: #f4f7f6; --card: #fff; --text: #333; --blue: #007bff; --orange: #fd7e14; --red: #dc3545; --teal: #20c997; --purple: #6f42c1; --darkred: #b02a37; }
        body { font-family: -apple-system, sans-serif; background: var(--bg); color: var(--text); padding: 20px; margin: 0; }
        .container { max-width: 1000px; margin: 0 auto; }
        h1 { text-align: center; color: #1a1a1a; margin-bottom: 20px; }
        
        .head-bar { display: flex; justify-content: space-between; align-items: center; background: #fff; padding: 15px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 5px rgba(0,0,0,0.05); }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(100px, 1fr)); gap: 15px; margin-bottom: 25px; }
        .card { background: var(--card); padding: 15px; border-radius: 8px; text-align: center; box-shadow: 0 2px 5px rgba(0,0,0,0.05); }
        .card h2 { margin: 0 0 5px; font-size: 12px; text-transform: uppercase; color: #888; }
        .val { font-size: 26px; font-weight: 700; }
        
        .chart-box { background: var(--card); padding: 15px; border-radius: 8px; margin-bottom: 25px; box-shadow: 0 2px 5px rgba(0,0,0,0.05); }
        .chart-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px; border-bottom: 1px solid #eee; padding-bottom: 10px; }
        .chart-title { font-weight: bold; font-size: 16px; }
        .chart-controls { display: flex; align-items: center; gap: 15px; font-size: 12px; color: #666; }
        
        canvas { touch-action: pan-y !important; height: 220px; width: 100%; }
        .zoom-hint { font-weight: normal; font-size: 12px; color: #999; margin-left: 5px; }
        .badge { background: #eee; padding: 2px 6px; border-radius: 4px; font-size: 0.8em; margin-left: 5px; }
        button { background: var(--blue); color: #fff; border: none; padding: 8px 15px; border-radius: 4px; cursor: pointer; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🌐 Keenetic Dual-Stack Ping Monitor</h1>
        
        <div class="head-bar">
            <div>Last Update: <span style="font-weight:bold" id="lastUpdate">Loading...</span></div>
            <button onclick="location.reload()">Refresh Now</button>
        </div>

        <h3 style="border-left: 4px solid var(--blue); padding-left: 10px;">IPv4 <span class="badge" id="targetV4"></span></h3>
        <div class="grid">
            <div class="card"><h2>Latency</h2><div class="val" style="color:var(--blue)" id="v4_p">-</div><small>Avg: <span id="v4_avg_p">-</span></small></div>
            <div class="card"><h2>Jitter</h2><div class="val" style="color:var(--orange)" id="v4_j">-</div><small>Avg: <span id="v4_avg_j">-</span></small></div>
            <div class="card"><h2>Loss</h2><div class="val" style="color:var(--red)" id="v4_l">-</div><small>Avg: <span id="v4_avg_l">-</span></small></div>
        </div>
        
        <div class="chart-box">
            <div class="chart-header">
                <div class="chart-title" style="color:var(--blue)">Latency (ms) <span class="zoom-hint">(Select area to zoom)</span></div>
                <div class="chart-controls"><label><input type="checkbox" autocomplete="off" onchange="toggleLog(this, 'c_p4')"> Log Scale</label></div>
            </div>
            <div style="position:relative; height:220px"><canvas id="c_p4"></canvas></div>
        </div>
        <div class="chart-box">
            <div class="chart-header">
                <div class="chart-title" style="color:var(--orange)">Jitter (ms)</div>
                <div class="chart-controls"><label><input type="checkbox" autocomplete="off" onchange="toggleLog(this, 'c_j4')"> Log Scale</label></div>
            </div>
            <div style="position:relative; height:220px"><canvas id="c_j4"></canvas></div>
        </div>
        <div class="chart-box">
            <div class="chart-header"><div class="chart-title" style="color:var(--red)">Packet Loss (%)</div></div>
            <div style="position:relative; height:220px"><canvas id="c_l4"></canvas></div>
        </div>

        <h3 style="border-left: 4px solid var(--teal); padding-left: 10px; margin-top: 40px;">IPv6 <span class="badge" id="targetV6"></span></h3>
        <div class="grid">
            <div class="card"><h2>Latency</h2><div class="val" style="color:var(--teal)" id="v6_p">-</div><small>Avg: <span id="v6_avg_p">-</span></small></div>
            <div class="card"><h2>Jitter</h2><div class="val" style="color:var(--purple)" id="v6_j">-</div><small>Avg: <span id="v6_avg_j">-</span></small></div>
            <div class="card"><h2>Loss</h2><div class="val" style="color:var(--darkred)" id="v6_l">-</div><small>Avg: <span id="v6_avg_l">-</span></small></div>
        </div>

        <div class="chart-box">
            <div class="chart-header">
                <div class="chart-title" style="color:var(--teal)">Latency (ms) <span class="zoom-hint">(Select area to zoom)</span></div>
                <div class="chart-controls"><label><input type="checkbox" autocomplete="off" onchange="toggleLog(this, 'c_p6')"> Log Scale</label></div>
            </div>
            <div style="position:relative; height:220px"><canvas id="c_p6"></canvas></div>
        </div>
        <div class="chart-box">
            <div class="chart-header">
                <div class="chart-title" style="color:var(--purple)">Jitter (ms)</div>
                <div class="chart-controls"><label><input type="checkbox" autocomplete="off" onchange="toggleLog(this, 'c_j6')"> Log Scale</label></div>
            </div>
            <div style="position:relative; height:220px"><canvas id="c_j6"></canvas></div>
        </div>
        <div class="chart-box">
            <div class="chart-header"><div class="chart-title" style="color:var(--darkred)">Packet Loss (%)</div></div>
            <div style="position:relative; height:220px"><canvas id="c_l6"></canvas></div>
        </div>
    </div>

    <script src="data.js"></script>

    <script>
        // Common Options (Dots Enabled, No Fill)
        const commonOptions = {
            responsive: true, maintainAspectRatio: false,
            interaction: { mode: 'index', intersect: false },
            plugins: {
                legend: { display: false },
                zoom: {
                    zoom: {
                        drag: { enabled: true, backgroundColor: 'rgba(54, 162, 235, 0.2)' },
                        mode: 'x'
                    }
                }
            },
            scales: { x: { type: 'time', time: { displayFormats: { minute: 'HH:mm' } } }, y: { beginAtZero: true } },
            elements: {
                point: { radius: 2, hoverRadius: 5 } // Explicit dots
            }
        };

        // FIXED LOG TOGGLE FUNCTION
        function toggleLog(cb, id) { 
            const c = Chart.getChart(id); 
            if(c) { 
                // We recreate the scale object to ensure cleaner transition (avoids double click issue)
                if (cb.checked) {
                    c.options.scales.y = { type: 'logarithmic', min: 0.1, beginAtZero: false };
                } else {
                    c.options.scales.y = { type: 'linear', beginAtZero: true };
                }
                c.update(); 
            } 
        }

        function render() {
            if(typeof window.PING_DATA === 'undefined') return;
            const d = window.PING_DATA;

            document.getElementById('lastUpdate').innerText = d.updated;
            document.getElementById('targetV4').innerText = d.targets.v4;
            document.getElementById('targetV6').innerText = d.targets.v6;

            // Update DOM V4
            document.getElementById('v4_p').innerText = d.current.v4.ping + "ms";
            document.getElementById('v4_j').innerText = d.current.v4.jitter + "ms";
            document.getElementById('v4_l').innerText = d.current.v4.loss + "%";
            document.getElementById('v4_avg_p').innerText = d.averages.v4.p;
            document.getElementById('v4_avg_j').innerText = d.averages.v4.j;
            document.getElementById('v4_avg_l').innerText = d.averages.v4.l;

            // Update DOM V6
            document.getElementById('v6_p').innerText = d.current.v6.ping + "ms";
            document.getElementById('v6_j').innerText = d.current.v6.jitter + "ms";
            document.getElementById('v6_l').innerText = d.current.v6.loss + "%";
            document.getElementById('v6_avg_p').innerText = d.averages.v6.p;
            document.getElementById('v6_avg_j').innerText = d.averages.v6.j;
            document.getElementById('v6_avg_l').innerText = d.averages.v6.l;

            // Chart Helpers (fill: false)
            const createChart = (id, label, dataKey, color, isBar=false) => {
                new Chart(document.getElementById(id), {
                    type: isBar ? 'bar' : 'line',
                    data: { datasets: [{ 
                        label: label, 
                        data: d.history.v4.map(i=>({x:i.x, y:i[dataKey]})), 
                        borderColor: color, 
                        backgroundColor: color, // Point color
                        borderWidth: 1, 
                        fill: false 
                    }] },
                    options: commonOptions
                });
            };
            const createChartV6 = (id, label, dataKey, color, isBar=false) => {
                new Chart(document.getElementById(id), {
                    type: isBar ? 'bar' : 'line',
                    data: { datasets: [{ 
                        label: label, 
                        data: d.history.v6.map(i=>({x:i.x, y:i[dataKey]})), 
                        borderColor: color, 
                        backgroundColor: color, // Point color
                        borderWidth: 1, 
                        fill: false 
                    }] },
                    options: commonOptions
                });
            };

            // Create 6 Separate Charts
            createChart('c_p4', 'Ping', 'p', '#007bff');
            createChart('c_j4', 'Jitter', 'j', '#fd7e14');
            createChart('c_l4', 'Loss', 'l', '#dc3545', true);

            createChartV6('c_p6', 'Ping', 'p', '#20c997');
            createChartV6('c_j6', 'Jitter', 'j', '#6f42c1');
            createChartV6('c_l6', 'Loss', 'l', '#b02a37', true);

            // Double Click Reset
            document.querySelectorAll('canvas').forEach(c => { c.ondblclick = () => Chart.getChart(c).resetZoom(); });
        }

        render();
    </script>
</body>
</html>
HTML_EOF
fi
