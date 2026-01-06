#!/opt/bin/bash
export PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin

# ==============================================================================
# USER CONFIGURATION
# ==============================================================================

# 1. TARGETS
PING_TARGET="8.8.8.8"
PING_TARGET_V6="2001:4860:4860::8888" # Google DNS IPv6

# 2. DURATION & THRESHOLDS
PING_DURATION=30
TRIGGER_LATENCY=30

WEB_DIR="/opt/var/www/ping"
HTML_FILENAME="index.html"

# 4. CHART HISTORY
MAX_DISPLAY_POINTS=2000

# 5. DATABASE AND RETENTION
DB_DIR="/opt/etc/pingtool"
DB_FILE="$DB_DIR/pingtool.db"
RETENTION_DAYS=45

# ==============================================================================
# MONITORING LOGIC
# ==============================================================================

echo "[$(date '+%Y-%m-%d %H:%M:%S')] pingtool: Starting Dual-Stack test..."

mkdir -p "$DB_DIR"
if [ ! -d "$WEB_DIR" ]; then mkdir -p "$WEB_DIR"; fi

# Init DB (Create both tables if missing)
if [ ! -f "$DB_FILE" ]; then
    sqlite3 "$DB_FILE" "CREATE TABLE IF NOT EXISTS stats (id INTEGER PRIMARY KEY, timestamp INTEGER, ping REAL, jitter REAL, loss REAL);"
    sqlite3 "$DB_FILE" "CREATE INDEX IF NOT EXISTS idx_ts ON stats (timestamp);"
    
    sqlite3 "$DB_FILE" "CREATE TABLE IF NOT EXISTS stats_v6 (id INTEGER PRIMARY KEY, timestamp INTEGER, ping REAL, jitter REAL, loss REAL);"
    sqlite3 "$DB_FILE" "CREATE INDEX IF NOT EXISTS idx_ts_v6 ON stats_v6 (timestamp);"
else
    # Ensure v6 table exists even if file exists
    sqlite3 "$DB_FILE" "CREATE TABLE IF NOT EXISTS stats_v6 (id INTEGER PRIMARY KEY, timestamp INTEGER, ping REAL, jitter REAL, loss REAL);"
    sqlite3 "$DB_FILE" "CREATE INDEX IF NOT EXISTS idx_ts_v6 ON stats_v6 (timestamp);"
fi

NOW=$(date +%s)

# --- PART 1: IPv4 MONITORING ---
TMP_PING="/tmp/pingtool_v4.tmp"
ping -w "$PING_DURATION" -i 1 "$PING_TARGET" > "$TMP_PING"

# Analysis V4
LOSS=$(grep -oP '\d+(?=% packet loss)' "$TMP_PING")
[ -z "$LOSS" ] && LOSS=100

AVG_PING=$(tail -n 1 "$TMP_PING" | awk -F '/' '{print $5}' | sed 's/[^0-9.]//g')
if [ -z "$AVG_PING" ] || [ "$LOSS" -eq 100 ]; then AVG_PING=0; fi

if [ "$LOSS" -lt 100 ]; then
    TIMES=$(grep "time=" "$TMP_PING" | sed 's/.*time=\([0-9.]*\) .*/\1/')
    JITTER=$(echo "$TIMES" | awk 'BEGIN {prev=0;td=0;c=0;f=1} {cur=$1; if(f==0){d=cur-prev; if(d<0)d=-d; td+=d; c++} prev=cur; f=0} END {if(c>0)printf "%.2f",td/c; else print "0"}')
else
    JITTER=0
fi
rm "$TMP_PING"

# Save V4
sqlite3 "$DB_FILE" "INSERT INTO stats (timestamp, ping, jitter, loss) VALUES ($NOW, $AVG_PING, $JITTER, $LOSS);"
sqlite3 "$DB_FILE" "DELETE FROM stats WHERE timestamp < strftime('%s', 'now', '-$RETENTION_DAYS days');"


# --- PART 2: IPv6 MONITORING ---
TMP_PING_V6="/tmp/pingtool_v6.tmp"
PING6_CMD="ping6"
if ! command -v ping6 >/dev/null 2>&1; then PING6_CMD="ping -6"; fi

$PING6_CMD -w "$PING_DURATION" -i 1 "$PING_TARGET_V6" > "$TMP_PING_V6" 2>/dev/null

# Analysis V6
LOSS_V6=$(grep -oP '\d+(?=% packet loss)' "$TMP_PING_V6")
[ -z "$LOSS_V6" ] && LOSS_V6=100

AVG_PING_V6=$(tail -n 1 "$TMP_PING_V6" | awk -F '/' '{print $5}' | sed 's/[^0-9.]//g')
if [ -z "$AVG_PING_V6" ] || [ "$LOSS_V6" -eq 100 ]; then AVG_PING_V6=0; fi

if [ "$LOSS_V6" -lt 100 ]; then
    TIMES_V6=$(grep "time=" "$TMP_PING_V6" | sed 's/.*time=\([0-9.]*\) .*/\1/')
    JITTER_V6=$(echo "$TIMES_V6" | awk 'BEGIN {prev=0;td=0;c=0;f=1} {cur=$1; if(f==0){d=cur-prev; if(d<0)d=-d; td+=d; c++} prev=cur; f=0} END {if(c>0)printf "%.2f",td/c; else print "0"}')
else
    JITTER_V6=0
fi
rm "$TMP_PING_V6"

# Save V6
sqlite3 "$DB_FILE" "INSERT INTO stats_v6 (timestamp, ping, jitter, loss) VALUES ($NOW, $AVG_PING_V6, $JITTER_V6, $LOSS_V6);"
sqlite3 "$DB_FILE" "DELETE FROM stats_v6 WHERE timestamp < strftime('%s', 'now', '-$RETENTION_DAYS days');"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] RESULTS:"
echo " IPv4 ($PING_TARGET): Ping=$AVG_PING ms | Jitter=$JITTER ms | Loss=$LOSS%"
echo " IPv6 ($PING_TARGET_V6): Ping=$AVG_PING_V6 ms | Jitter=$JITTER_V6 ms | Loss=$LOSS_V6%"


# ==============================================================================
# MTR DIAGNOSTICS & ALERTS (Dual Stack)
# ==============================================================================

INCIDENT_LOG="$WEB_DIR/incidents.txt"

# --- IPv4 CHECK ---
IS_HIGH_PING=$(awk -v p="$AVG_PING" -v t="$TRIGGER_LATENCY" 'BEGIN {print (p > t ? 1 : 0)}')
if [ "$IS_HIGH_PING" -eq 1 ] || [ "$LOSS" -gt 0 ]; then
    MSG="[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ WARNING IPv4: Ping ($AVG_PING ms) > Threshold or Loss ($LOSS%) detected."
    echo "$MSG"
    echo "$MSG" >> "$INCIDENT_LOG"
    
    # Runs MTR if present (uncomment below if you have mtr installed)
    # mtr -r -c 10 -w "$PING_TARGET" >> "$INCIDENT_LOG" 2>&1
    echo "------------------------------------------------" >> "$INCIDENT_LOG"
fi

# --- IPv6 CHECK ---
IS_HIGH_PING_V6=$(awk -v p="$AVG_PING_V6" -v t="$TRIGGER_LATENCY" 'BEGIN {print (p > t ? 1 : 0)}')
if [ "$IS_HIGH_PING_V6" -eq 1 ] || [ "$LOSS_V6" -gt 0 ]; then
    MSG="[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ WARNING IPv6: Ping ($AVG_PING_V6 ms) > Threshold or Loss ($LOSS_V6%) detected."
    echo "$MSG"
    echo "$MSG" >> "$INCIDENT_LOG"
    
    # Runs MTR v6 if present (uncomment below if you have mtr installed)
    # mtr -6 -r -c 10 -w "$PING_TARGET_V6" >> "$INCIDENT_LOG" 2>&1
    echo "------------------------------------------------" >> "$INCIDENT_LOG"
fi

# Keep log size reasonable (last 100 lines)
if [ -f "$INCIDENT_LOG" ]; then
    tail -n 100 "$INCIDENT_LOG" > "$INCIDENT_LOG.tmp" && mv "$INCIDENT_LOG.tmp" "$INCIDENT_LOG"
fi


# ==============================================================================
# HTML GENERATION
# ==============================================================================

# 1. GET HISTORICAL AVERAGES
DB_STATS=$(sqlite3 "$DB_FILE" "SELECT AVG(ping), AVG(jitter), AVG(loss) FROM (SELECT ping, jitter, loss FROM stats ORDER BY timestamp DESC LIMIT $MAX_DISPLAY_POINTS);")
HIST_PING=$(echo "$DB_STATS" | awk -F'|' '{printf "%.2f", $1}'); [ -z "$HIST_PING" ] && HIST_PING="0.00"
HIST_JIT=$(echo "$DB_STATS" | awk -F'|' '{printf "%.2f", $2}'); [ -z "$HIST_JIT" ] && HIST_JIT="0.00"
HIST_LOSS=$(echo "$DB_STATS" | awk -F'|' '{printf "%.2f", $3}'); [ -z "$HIST_LOSS" ] && HIST_LOSS="0.00"

DB_STATS_V6=$(sqlite3 "$DB_FILE" "SELECT AVG(ping), AVG(jitter), AVG(loss) FROM (SELECT ping, jitter, loss FROM stats_v6 ORDER BY timestamp DESC LIMIT $MAX_DISPLAY_POINTS);")
HIST_PING_V6=$(echo "$DB_STATS_V6" | awk -F'|' '{printf "%.2f", $1}'); [ -z "$HIST_PING_V6" ] && HIST_PING_V6="0.00"
HIST_JIT_V6=$(echo "$DB_STATS_V6" | awk -F'|' '{printf "%.2f", $2}'); [ -z "$HIST_JIT_V6" ] && HIST_JIT_V6="0.00"
HIST_LOSS_V6=$(echo "$DB_STATS_V6" | awk -F'|' '{printf "%.2f", $3}'); [ -z "$HIST_LOSS_V6" ] && HIST_LOSS_V6="0.00"

# 2. PREPARE JSON DATA
JSON_DATA=$(sqlite3 "$DB_FILE" "SELECT timestamp, ping, jitter, loss FROM stats ORDER BY timestamp DESC LIMIT $MAX_DISPLAY_POINTS;" | awk -F'|' '{printf "{x:%s000,p:%s,j:%s,l:%s},", $1, $2, $3, $4}' | sed 's/,$//')
JSON_DATA_V6=$(sqlite3 "$DB_FILE" "SELECT timestamp, ping, jitter, loss FROM stats_v6 ORDER BY timestamp DESC LIMIT $MAX_DISPLAY_POINTS;" | awk -F'|' '{printf "{x:%s000,p:%s,j:%s,l:%s},", $1, $2, $3, $4}' | sed 's/,$//')

DATE_UPDATE=$(date "+%d/%m/%Y %H:%M:%S")

cat <<HTML > "$WEB_DIR/$HTML_FILENAME"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Keenetic Ping Monitor</title>
    <link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>🌐</text></svg>">
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns"></script>
    <style>
        :root { --bg-color: #f0f2f5; --text-color: #333; --card-bg: #fff; --card-shadow: 0 2px 8px rgba(0,0,0,0.08); --border-color: #e4e6eb; }
        body { font-family: -apple-system, sans-serif; background-color: var(--bg-color); color: var(--text-color); margin: 0; padding: 20px; }
        .container { max-width: 1000px; margin: 0 auto; }
        h1 { text-align: center; color: #1a1a1a; margin-bottom: 30px; border-bottom: 2px solid #e4e6eb; padding-bottom: 15px; }
        
        .refresh-bar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; background: white; padding: 10px 15px; border-radius: 8px; border: 1px solid #e4e6eb; font-size: 13px; color: #666; }
        .btn { background: #007bff; color: white; padding: 8px 16px; text-decoration: none; border-radius: 6px; font-weight: 600; font-size: 13px; }
        
        .section-title { font-size: 18px; font-weight: 700; color: #444; margin: 40px 0 20px 0; padding-left: 10px; border-left: 4px solid #007bff; display: flex; align-items: center; gap: 10px; }
        .v6-title { border-color: #20c997; }
        .badge { font-size: 11px; background: #eee; padding: 2px 8px; border-radius: 4px; color: #666; font-weight: normal; }

        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 20px; margin-bottom: 20px; }
        .card { background: var(--card-bg); padding: 20px; border-radius: 12px; text-align: center; border: 1px solid var(--border-color); box-shadow: var(--card-shadow); }
        .card h2 { margin: 0 0 5px; font-size: 12px; color: #888; text-transform: uppercase; letter-spacing: 1px; }
        .card .value { font-size: 32px; font-weight: 800; color: #1a1a1a; margin: 5px 0 0 0; }
        .card .unit { font-size: 14px; color: #999; font-weight: 400; }
        .sub-label { font-size: 13px; color: #999; margin-bottom: 15px; }
        .avg-row { margin-top: 0; padding-top: 10px; border-top: 1px solid #f1f3f5; font-size: 13px; color: #888; display: flex; justify-content: center; }
        .avg-row strong { color: #555; font-weight: 600; margin-left: 4px; }

        .hl-blue { color: #007bff !important; }
        .hl-orange { color: #fd7e14 !important; }
        .hl-red { color: #dc3545 !important; }
        .hl-teal { color: #20c997 !important; }
        .hl-purple { color: #6f42c1 !important; }
        .hl-darkred { color: #b02a37 !important; }

        .chart-card { background: var(--card-bg); padding: 20px; border-radius: 12px; border: 1px solid var(--border-color); box-shadow: var(--card-shadow); margin-bottom: 20px; }
        .chart-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px; border-bottom: 1px solid #eee; padding-bottom: 10px; }
        .chart-title { font-size: 15px; font-weight: 700; color: #333; }
        .scale-toggle { font-size: 12px; color: #666; display: flex; align-items: center; gap: 5px; cursor: pointer; }
        .canvas-container { position: relative; height: 220px; width: 100%; }
        
        .footer { text-align: center; margin-top: 40px; font-size: 12px; color: #999; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🌐 Keenetic Dual-Stack Ping Monitor</h1>
        
        <div class="refresh-bar">
            <span>Last Update: <strong>$DATE_UPDATE</strong></span>
            <a href="javascript:location.reload()" class="btn">Refresh Now</a>
        </div>

        <div class="section-title">IPv4 Protocol <span class="badge">$PING_TARGET</span></div>
        
        <div class="grid">
            <div class="card">
                <h2>Latency</h2>
                <div class="value hl-blue">${AVG_PING}<span class="unit">ms</span></div>
                <div class="sub-label">Last Test</div>
                <div class="avg-row">Avg: <strong>${HIST_PING}</strong> ms</div>
            </div>
            <div class="card">
                <h2>Jitter</h2>
                <div class="value hl-orange">${JITTER}<span class="unit">ms</span></div>
                <div class="sub-label">Last Test</div>
                <div class="avg-row">Avg: <strong>${HIST_JIT}</strong> ms</div>
            </div>
            <div class="card">
                <h2>Loss</h2>
                <div class="value hl-red">${LOSS}<span class="unit">%</span></div>
                <div class="sub-label">Last Test</div>
                <div class="avg-row">Avg: <strong>${HIST_LOSS}</strong> %</div>
            </div>
        </div>
        
        <div class="chart-card">
            <div class="chart-header">
                <div class="chart-title" style="color:#007bff">IPv4 Latency History</div>
                <label class="scale-toggle"><input type="checkbox" onchange="toggleScale(this, 'pingChart')"> Log Scale</label>
            </div>
            <div class="canvas-container"><canvas id="pingChart"></canvas></div>
        </div>
        
        <div class="chart-card">
            <div class="chart-header">
                <div class="chart-title" style="color:#fd7e14">IPv4 Jitter History</div>
                <label class="scale-toggle"><input type="checkbox" onchange="toggleScale(this, 'jitterChart')"> Log Scale</label>
            </div>
            <div class="canvas-container"><canvas id="jitterChart"></canvas></div>
        </div>

        <div class="chart-card">
            <div class="chart-header">
                <div class="chart-title" style="color:#dc3545">IPv4 Packet Loss History</div>
            </div>
            <div class="canvas-container"><canvas id="lossChart"></canvas></div>
        </div>


        <div class="section-title v6-title" style="color:#20c997; border-color:#20c997">IPv6 Protocol <span class="badge">$PING_TARGET_V6</span></div>
        
        <div class="grid">
            <div class="card">
                <h2>Latency (v6)</h2>
                <div class="value hl-teal">${AVG_PING_V6}<span class="unit">ms</span></div>
                <div class="sub-label">Last Test</div>
                <div class="avg-row">Avg: <strong>${HIST_PING_V6}</strong> ms</div>
            </div>
            <div class="card">
                <h2>Jitter (v6)</h2>
                <div class="value hl-purple">${JITTER_V6}<span class="unit">ms</span></div>
                <div class="sub-label">Last Test</div>
                <div class="avg-row">Avg: <strong>${HIST_JIT_V6}</strong> ms</div>
            </div>
            <div class="card">
                <h2>Loss (v6)</h2>
                <div class="value hl-darkred">${LOSS_V6}<span class="unit">%</span></div>
                <div class="sub-label">Last Test</div>
                <div class="avg-row">Avg: <strong>${HIST_LOSS_V6}</strong> %</div>
            </div>
        </div>

        <div class="chart-card">
            <div class="chart-header">
                <div class="chart-title" style="color:#20c997">IPv6 Latency History</div>
                <label class="scale-toggle"><input type="checkbox" onchange="toggleScale(this, 'pingChartV6')"> Log Scale</label>
            </div>
            <div class="canvas-container"><canvas id="pingChartV6"></canvas></div>
        </div>

        <div class="chart-card">
            <div class="chart-header">
                <div class="chart-title" style="color:#6f42c1">IPv6 Jitter History</div>
                <label class="scale-toggle"><input type="checkbox" onchange="toggleScale(this, 'jitterChartV6')"> Log Scale</label>
            </div>
            <div class="canvas-container"><canvas id="jitterChartV6"></canvas></div>
        </div>

        <div class="chart-card">
            <div class="chart-header">
                <div class="chart-title" style="color:#b02a37">IPv6 Packet Loss History</div>
            </div>
            <div class="canvas-container"><canvas id="lossChartV6"></canvas></div>
        </div>

        <div class="footer">Data Retention: $RETENTION_DAYS days | Database: SQLite3</div>
    </div>

    <script>
        const dataV4 = [$JSON_DATA].reverse();
        const dataV6 = [$JSON_DATA_V6].reverse();
        
        const commonOptions = { responsive: true, maintainAspectRatio: false, interaction: { mode: 'index', intersect: false }, plugins: { legend: { display: false } } };
        const timeScale = { type: 'time', time: { displayFormats: { minute: 'HH:mm', hour: 'dd/MM HH' }, tooltipFormat: 'dd/MM HH:mm:ss' }, ticks: { autoSkip: true, maxTicksLimit: 12 }, grid: { color: 'rgba(0,0,0,0.03)' } };

        function toggleScale(cb, id) { const c = Chart.getChart(id); if(c){ c.options.scales.y.type = cb.checked?'logarithmic':'linear'; c.update(); } }

        function createLineChart(id, label, dataKey, color, bg) {
            new Chart(document.getElementById(id), {
                type: 'line',
                data: { datasets: [{ 
                    label: label, 
                    data: dataV4.map(d=>({x:d.x, y:d[dataKey]})), 
                    borderColor: color, 
                    backgroundColor: bg, 
                    borderWidth: 2, 
                    fill: true, 
                    pointRadius: 2,            // CHANGED: From 0 to 2 to make dots visible
                    pointHoverRadius: 5        // CHANGED: Increased for hover
                }]},
                options: { ...commonOptions, scales: { x: timeScale, y: { beginAtZero: true } } }
            });
        }
        function createLineChartV6(id, label, dataKey, color, bg) {
            new Chart(document.getElementById(id), {
                type: 'line',
                data: { datasets: [{ 
                    label: label, 
                    data: dataV6.map(d=>({x:d.x, y:d[dataKey]})), 
                    borderColor: color, 
                    backgroundColor: bg, 
                    borderWidth: 2, 
                    fill: true, 
                    pointRadius: 2,            // CHANGED: From 0 to 2 to make dots visible
                    pointHoverRadius: 5        // CHANGED: Increased for hover
                }]},
                options: { ...commonOptions, scales: { x: timeScale, y: { beginAtZero: true } } }
            });
        }
        function createBarChart(id, label, dataKey, color, dataSet) {
             new Chart(document.getElementById(id), {
                type: 'bar',
                data: { datasets: [{ label: label, data: dataSet.map(d=>({x:d.x, y:d[dataKey]})), backgroundColor: color, minBarLength: 4 }]},
                options: { ...commonOptions, scales: { x: timeScale, y: { min: 0, suggestedMax: 5 } } }
            });
        }

        // IPv4 Charts
        createLineChart('pingChart', 'Ping (ms)', 'p', '#007bff', 'rgba(0,123,255,0.1)');
        createLineChart('jitterChart', 'Jitter (ms)', 'j', '#fd7e14', 'rgba(253,126,20,0.1)');
        createBarChart('lossChart', 'Loss (%)', 'l', '#dc3545', dataV4);

        // IPv6 Charts
        createLineChartV6('pingChartV6', 'Ping (ms)', 'p', '#20c997', 'rgba(32,201,151,0.1)');
        createLineChartV6('jitterChartV6', 'Jitter (ms)', 'j', '#6f42c1', 'rgba(111,66,193,0.1)');
        createBarChart('lossChartV6', 'Loss (%)', 'l', '#b02a37', dataV6);

    </script>
</body>
</html>
HTML
