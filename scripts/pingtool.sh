#!/opt/bin/bash
export PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin

# ==============================================================================
# USER CONFIGURATION
# ==============================================================================

# 1. TARGET AND DURATION
PING_TARGET="8.8.8.8"
PING_DURATION=30

# 2. THRESHOLD FOR TRACEROUTE/MTR (in ms)
# If average ping exceeds this value, an MTR is executed and logged.
TRIGGER_LATENCY=30

# 3. WEB AND FILE PATHS
WEB_DIR="/opt/var/www"
HTML_FILENAME="pingtool.html"

# 4. CHART HISTORY
MAX_DISPLAY_POINTS=2000

# 5. DATABASE AND RETENTION
DB_DIR="/opt/etc/pingtool"
DB_FILE="$DB_DIR/pingtool.db"
RETENTION_DAYS=45

# ==============================================================================
# MONITORING LOGIC
# ==============================================================================

echo "[$(date '+%Y-%m-%d %H:%M:%S')] pingtool: Starting test towards $PING_TARGET..."

mkdir -p "$DB_DIR"
if [ ! -d "$WEB_DIR" ]; then mkdir -p "$WEB_DIR"; fi

# Init DB
if [ ! -f "$DB_FILE" ]; then
    sqlite3 "$DB_FILE" "CREATE TABLE IF NOT EXISTS stats (id INTEGER PRIMARY KEY, timestamp INTEGER, ping REAL, jitter REAL, loss REAL);"
    sqlite3 "$DB_FILE" "CREATE INDEX IF NOT EXISTS idx_ts ON stats (timestamp);"
fi

TMP_PING="/tmp/pingtool_ping_output.tmp"

# EXECUTE PING
ping -w "$PING_DURATION" -i 1 "$PING_TARGET" > "$TMP_PING"

# DATA ANALYSIS
LOSS=$(grep -oP '\d+(?=% packet loss)' "$TMP_PING")
if [ -z "$LOSS" ]; then LOSS=100; fi

# Extract Average Ping (cleaned of 'ms')
AVG_PING=$(tail -n 1 "$TMP_PING" | awk -F '/' '{print $5}' | sed 's/[^0-9.]//g')
if [ -z "$AVG_PING" ] || [ "$LOSS" -eq 100 ]; then AVG_PING=0; fi

# CALCULATE JITTER
if [ "$LOSS" -lt 100 ]; then
    TIMES=$(grep "time=" "$TMP_PING" | sed 's/.*time=\([0-9.]*\) .*/\1/')
    JITTER=$(echo "$TIMES" | awk 'BEGIN {prev=0;td=0;c=0;f=1} {cur=$1; if(f==0){d=cur-prev; if(d<0)d=-d; td+=d; c++} prev=cur; f=0} END {if(c>0)printf "%.2f",td/c; else print "0"}')
else
    JITTER=0
fi

rm "$TMP_PING"
NOW=$(date +%s)

# SAVE TO DB
sqlite3 "$DB_FILE" "INSERT INTO stats (timestamp, ping, jitter, loss) VALUES ($NOW, $AVG_PING, $JITTER, $LOSS);"
sqlite3 "$DB_FILE" "DELETE FROM stats WHERE timestamp < strftime('%s', 'now', '-$RETENTION_DAYS days');"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] RESULT: Ping=$AVG_PING ms | Jitter=$JITTER ms | Loss=$LOSS%"

# ==============================================================================
# MTR DIAGNOSTICS (ADDED LOGIC)
# ==============================================================================

# We use awk for comparison because AVG_PING is a decimal (float)
IS_HIGH_PING=$(awk -v p="$AVG_PING" -v t="$TRIGGER_LATENCY" 'BEGIN {print (p > t ? 1 : 0)}')

# If ping is high OR Packet Loss > 0%
if [ "$IS_HIGH_PING" -eq 1 ] || [ "$LOSS" -gt 0 ]; then
    echo "!!! WARNING: High Ping ($AVG_PING ms > $TRIGGER_LATENCY ms) or Packet Loss detected."
    echo "!!! Running diagnostic MTR towards $PING_TARGET..."
    echo "--------------------------------------------------------"
    
    # Runs MTR:
    # -r: Report mode (plain text)
    # -w: Wide (don't cut long names)
    # -c 10: Send 10 packets per hop (good speed/accuracy balance)
    if [ -x "$(command -v mtr)" ]; then
        mtr -r -w -c 10 "$PING_TARGET"
    else
        echo "Error: 'mtr' not installed. Running standard traceroute."
        traceroute "$PING_TARGET"
    fi
    
    echo "--------------------------------------------------------"
fi

# ==============================================================================
# HTML GENERATION
# ==============================================================================

JSON_DATA=$(sqlite3 "$DB_FILE" "SELECT timestamp, ping, jitter, loss FROM stats ORDER BY timestamp DESC LIMIT $MAX_DISPLAY_POINTS;" | \
awk -F'|' '{printf "{x:%s000,p:%s,j:%s,l:%s},", $1, $2, $3, $4}' | sed 's/,$//')

cat <<EOF > "$WEB_DIR/$HTML_FILENAME"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Keenetic PingTool</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns"></script>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #f4f6f9; margin: 0; padding: 20px; color: #495057; }
        .container { max-width: 1200px; margin: 0 auto; }
        .status-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 20px; margin-bottom: 30px; }
        .card { background: #fff; padding: 20px; border-radius: 10px; text-align: center; box-shadow: 0 2px 4px rgba(0,0,0,0.05); border-top: 4px solid #ccc; }
        .card.ping { border-color: #3498db; }
        .card.jitter { border-color: #f39c12; }
        .card.loss { border-color: #e74c3c; }
        .card h3 { margin: 0; font-size: 13px; text-transform: uppercase; color: #888; letter-spacing: 1px; }
        .card .value { font-size: 32px; font-weight: 700; color: #333; margin-top: 5px; }
        .charts-wrapper { display: flex; flex-direction: column; gap: 25px; }
        .chart-box { background: #fff; padding: 20px; border-radius: 10px; box-shadow: 0 2px 4px rgba(0,0,0,0.05); position: relative; }
        .chart-header-row { display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px; border-bottom: 1px solid #eee; padding-bottom: 10px; }
        .chart-title { font-size: 16px; font-weight: 600; }
        .scale-toggle { font-size: 12px; display: flex; align-items: center; gap: 8px; color: #666; cursor: pointer; user-select: none; }
        .canvas-container { position: relative; height: 250px; width: 100%; }
        .footer { text-align: center; margin-top: 30px; font-size: 12px; color: #aaa; }
    </style>
</head>
<body>
    <div class="container">
        <h2 style="text-align:center; color:#2c3e50; margin-bottom:30px;">Connection Monitor ($PING_TARGET)</h2>
        <div class="status-grid">
            <div class="card ping"><h3>Last Ping</h3><div class="value">${AVG_PING} <small>ms</small></div></div>
            <div class="card jitter"><h3>Last Jitter</h3><div class="value">${JITTER} <small>ms</small></div></div>
            <div class="card loss"><h3>Packet Loss</h3><div class="value">${LOSS}<small>%</small></div></div>
        </div>
        <div class="charts-wrapper">
            <div class="chart-box">
                <div class="chart-header-row"><div class="chart-title" style="color:#2980b9">Latency (Ping)</div><label class="scale-toggle"><input type="checkbox" onchange="toggleScale(this, 'pingChart')"> Log Scale</label></div>
                <div class="canvas-container"><canvas id="pingChart"></canvas></div>
            </div>
            <div class="chart-box">
                <div class="chart-header-row"><div class="chart-title" style="color:#d35400">Stability (Jitter)</div><label class="scale-toggle"><input type="checkbox" onchange="toggleScale(this, 'jitterChart')"> Log Scale</label></div>
                <div class="canvas-container"><canvas id="jitterChart"></canvas></div>
            </div>
            <div class="chart-box">
                <div class="chart-header-row"><div class="chart-title" style="color:#c0392b">Packet Loss</div><label class="scale-toggle"><input type="checkbox" onchange="toggleScale(this, 'lossChart')"> Log Scale</label></div>
                <div class="canvas-container"><canvas id="lossChart"></canvas></div>
            </div>
        </div>
        <div class="footer">Last update: $(date "+%d/%m/%Y %H:%M:%S") | Retention: $RETENTION_DAYS days</div>
    </div>
    <script>
        const rawData = [$JSON_DATA].reverse();
        const timeScaleConfig = { type: 'time', time: { displayFormats: { minute: 'HH:mm', hour: 'dd/MM HH:mm', day: 'dd/MM' }, tooltipFormat: 'dd/MM/yyyy HH:mm:ss' }, ticks: { autoSkip: true, maxTicksLimit: 12, maxRotation: 0 }, grid: { color: 'rgba(0,0,0,0.03)' } };
        const commonOptions = { responsive: true, maintainAspectRatio: false, interaction: { mode: 'index', intersect: false }, plugins: { legend: { display: false } } };
        function toggleScale(checkbox, chartId) { const chart = Chart.getChart(chartId); if (chart) { chart.options.scales.y.type = checkbox.checked ? 'logarithmic' : 'linear'; chart.update(); } }
        
        new Chart(document.getElementById('pingChart'), { type: 'line', data: { datasets: [{ label: 'Ping (ms)', data: rawData.map(d => ({x: d.x, y: d.p})), borderColor: '#3498db', backgroundColor: 'rgba(52, 152, 219, 0.1)', borderWidth: 2, fill: true, tension: 0.2, pointRadius: 2, pointHoverRadius: 6, pointBackgroundColor: '#fff', pointBorderColor: '#3498db' }] }, options: { ...commonOptions, scales: { x: timeScaleConfig, y: { type: 'linear', beginAtZero: true, grid: { color: 'rgba(0,0,0,0.05)' } } } } });
        new Chart(document.getElementById('jitterChart'), { type: 'line', data: { datasets: [{ label: 'Jitter (ms)', data: rawData.map(d => ({x: d.x, y: d.j})), borderColor: '#f39c12', backgroundColor: 'rgba(243, 156, 18, 0.1)', borderWidth: 2, fill: true, tension: 0.2, pointRadius: 2, pointHoverRadius: 6, pointBackgroundColor: '#fff', pointBorderColor: '#f39c12' }] }, options: { ...commonOptions, scales: { x: timeScaleConfig, y: { type: 'linear', beginAtZero: true, grid: { color: 'rgba(0,0,0,0.05)' } } } } });
        new Chart(document.getElementById('lossChart'), { type: 'bar', data: { datasets: [{ label: 'Loss (%)', data: rawData.map(d => ({x: d.x, y: d.l})), backgroundColor: '#e74c3c', minBarLength: 4 }] }, options: { ...commonOptions, scales: { x: timeScaleConfig, y: { type: 'linear', min: 0, suggestedMax: 10, ticks: { stepSize: 5 }, grid: { color: 'rgba(0,0,0,0.05)' } } } } });
    </script>
</body>
</html>
EOF
