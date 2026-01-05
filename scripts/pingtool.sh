#!/opt/bin/bash
export PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin

# ==============================================================================
# USER CONFIGURATION
# ==============================================================================

# 1. TARGET AND DURATION
PING_TARGET="8.8.8.8"
PING_DURATION=30

# 2. THRESHOLD FOR TRACEROUTE/MTR (in ms)
TRIGGER_LATENCY=30

# 3. WEB AND FILE PATHS
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

# Extract Average Ping
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
# MTR DIAGNOSTICS
# ==============================================================================

IS_HIGH_PING=$(awk -v p="$AVG_PING" -v t="$TRIGGER_LATENCY" 'BEGIN {print (p > t ? 1 : 0)}')

if [ "$IS_HIGH_PING" -eq 1 ] || [ "$LOSS" -gt 0 ]; then
    echo "!!! WARNING: High Ping ($AVG_PING ms > $TRIGGER_LATENCY ms) or Packet Loss detected."
fi

# ==============================================================================
# HTML GENERATION
# ==============================================================================

# 1. CALCULATE HISTORICAL AVERAGES
DB_STATS=$(sqlite3 "$DB_FILE" "SELECT AVG(ping), AVG(jitter), AVG(loss) FROM (SELECT ping, jitter, loss FROM stats ORDER BY timestamp DESC LIMIT $MAX_DISPLAY_POINTS);")

HIST_PING=$(echo "$DB_STATS" | awk -F'|' '{printf "%.2f", $1}')
HIST_JIT=$(echo "$DB_STATS" | awk -F'|' '{printf "%.2f", $2}')
HIST_LOSS=$(echo "$DB_STATS" | awk -F'|' '{printf "%.2f", $3}')

[ -z "$HIST_PING" ] && HIST_PING="0.00"
[ -z "$HIST_JIT" ] && HIST_JIT="0.00"
[ -z "$HIST_LOSS" ] && HIST_LOSS="0.00"

# 2. PREPARE CHART DATA
JSON_DATA=$(sqlite3 "$DB_FILE" "SELECT timestamp, ping, jitter, loss FROM stats ORDER BY timestamp DESC LIMIT $MAX_DISPLAY_POINTS;" | \
awk -F'|' '{printf "{x:%s000,p:%s,j:%s,l:%s},", $1, $2, $3, $4}' | sed 's/,$//')

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
        :root {
            --bg-color: #f0f2f5;
            --text-color: #333333;
            --card-bg: #ffffff;
            --card-shadow: 0 2px 8px rgba(0,0,0,0.08);
            --border-color: #e4e6eb;
            --accent-blue: #007bff;
        }

        body { font-family: -apple-system, system-ui, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif; background-color: var(--bg-color); color: var(--text-color); margin: 0; padding: 20px; }
        .container { max-width: 1000px; margin: 0 auto; }
        
        h1 { color: #1a1a1a; text-align: center; border-bottom: 2px solid #e4e6eb; padding-bottom: 15px; margin-bottom: 30px; letter-spacing: -0.5px; }
        
        .refresh-bar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; font-size: 13px; color: #65676b; background: white; padding: 10px 15px; border-radius: 8px; border: 1px solid #e4e6eb; }
        .btn { display: inline-block; background: #007bff; color: white; padding: 8px 16px; text-decoration: none; border-radius: 6px; font-size: 13px; font-weight: 600; transition: background 0.2s; box-shadow: 0 2px 4px rgba(0,123,255,0.3); }
        .btn:hover { background: #0056b3; }

        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 20px; margin-bottom: 30px; }
        
        .card { background-color: var(--card-bg); border-radius: 12px; padding: 20px; text-align: center; border: 1px solid var(--border-color); box-shadow: var(--card-shadow); transition: transform 0.2s; }
        .card:hover { transform: translateY(-2px); }
        
        .card h2 { margin: 0 0 5px 0; font-size: 13px; color: #65676b; text-transform: uppercase; letter-spacing: 1px; font-weight: 600; }
        
        .card .value { font-size: 36px; font-weight: 800; color: #1a1a1a; margin: 5px 0 0 0; }
        .card .unit { font-size: 14px; color: #909296; font-weight: 400; }
        .sub-label { font-size: 13px; color: #909296; margin-bottom: 15px; font-weight: 400; }
        .avg-row { margin-top: 0; padding-top: 10px; border-top: 1px solid #f1f3f5; font-size: 13px; color: #868e96; display: flex; justify-content: center; align-items: center; }
        .avg-row strong { color: #495057; font-weight: 600; }

        .hl-red { color: #dc3545 !important; }
        .hl-orange { color: #fd7e14 !important; }
        .hl-blue { color: #007bff !important; }
        
        .chart-card { background-color: var(--card-bg); border-radius: 12px; padding: 20px; border: 1px solid var(--border-color); box-shadow: var(--card-shadow); margin-bottom: 25px; }
        .chart-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px; border-bottom: 1px solid #eee; padding-bottom: 10px; }
        .chart-title { font-size: 15px; font-weight: 700; color: #333; }
        .scale-toggle { font-size: 12px; display: flex; align-items: center; gap: 8px; color: #666; cursor: pointer; user-select: none; }
        .canvas-container { position: relative; height: 250px; width: 100%; }

        .footer { text-align: center; margin-top: 40px; font-size: 12px; color: #909296; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🌐 Keenetic Ping Monitor: $PING_TARGET</h1>
        
        <div class="refresh-bar">
            <span>Last Update: <strong>$DATE_UPDATE</strong></span>
            <a href="javascript:location.reload()" class="btn">Refresh Now</a>
        </div>

        <div class="grid">
            <div class="card">
                <h2>Latency (Ping)</h2>
                <div class="value hl-blue">${AVG_PING}<span class="unit">ms</span></div>
                <div class="sub-label">Last Test</div>
                <div class="avg-row">
                    <span>Avg: <strong>${HIST_PING}</strong> ms</span>
                </div>
            </div>
            <div class="card">
                <h2>Stability (Jitter)</h2>
                <div class="value hl-orange">${JITTER}<span class="unit">ms</span></div>
                <div class="sub-label">Last Test</div>
                <div class="avg-row">
                    <span>Avg: <strong>${HIST_JIT}</strong> ms</span>
                </div>
            </div>
            <div class="card">
                <h2>Packet Loss</h2>
                <div class="value hl-red">${LOSS}<span class="unit">%</span></div>
                <div class="sub-label">Last Test</div>
                <div class="avg-row">
                    <span>Avg: <strong>${HIST_LOSS}</strong> %</span>
                </div>
            </div>
        </div>

        <div class="chart-card">
            <div class="chart-header">
                <div class="chart-title" style="color:#007bff">Latency History</div>
                <label class="scale-toggle"><input type="checkbox" onchange="toggleScale(this, 'pingChart')"> Log Scale</label>
            </div>
            <div class="canvas-container"><canvas id="pingChart"></canvas></div>
        </div>

        <div class="chart-card">
            <div class="chart-header">
                <div class="chart-title" style="color:#fd7e14">Jitter History</div>
                <label class="scale-toggle"><input type="checkbox" onchange="toggleScale(this, 'jitterChart')"> Log Scale</label>
            </div>
            <div class="canvas-container"><canvas id="jitterChart"></canvas></div>
        </div>

        <div class="chart-card">
            <div class="chart-header">
                <div class="chart-title" style="color:#dc3545">Packet Loss History</div>
            </div>
            <div class="canvas-container"><canvas id="lossChart"></canvas></div>
        </div>

        <div class="footer">
            Data Retention: $RETENTION_DAYS days | Database: SQLite3
        </div>
    </div>

    <script>
        const rawData = [$JSON_DATA].reverse();
        
        const timeScaleConfig = { 
            type: 'time', 
            time: { 
                displayFormats: { minute: 'HH:mm', hour: 'dd/MM HH:mm', day: 'dd/MM' }, 
                tooltipFormat: 'dd/MM/yyyy HH:mm:ss' 
            }, 
            ticks: { autoSkip: true, maxTicksLimit: 12, maxRotation: 0 }, 
            grid: { color: 'rgba(0,0,0,0.03)' } 
        };
        
        const commonOptions = { 
            responsive: true, 
            maintainAspectRatio: false, 
            interaction: { mode: 'index', intersect: false }, 
            plugins: { legend: { display: false } } 
        };
        
        function toggleScale(checkbox, chartId) { 
            const chart = Chart.getChart(chartId); 
            if (chart) { 
                chart.options.scales.y.type = checkbox.checked ? 'logarithmic' : 'linear'; 
                chart.update(); 
            } 
        }
        
        new Chart(document.getElementById('pingChart'), { 
            type: 'line', 
            data: { 
                datasets: [{ 
                    label: 'Ping (ms)', 
                    data: rawData.map(d => ({x: d.x, y: d.p})), 
                    borderColor: '#007bff', 
                    backgroundColor: 'rgba(0, 123, 255, 0.1)', 
                    borderWidth: 2, 
                    fill: true, 
                    tension: 0.2, 
                    pointRadius: 1, 
                    pointHoverRadius: 5 
                }] 
            }, 
            options: { ...commonOptions, scales: { x: timeScaleConfig, y: { type: 'linear', beginAtZero: true } } } 
        });

        new Chart(document.getElementById('jitterChart'), { 
            type: 'line', 
            data: { 
                datasets: [{ 
                    label: 'Jitter (ms)', 
                    data: rawData.map(d => ({x: d.x, y: d.j})), 
                    borderColor: '#fd7e14', 
                    backgroundColor: 'rgba(253, 126, 20, 0.1)', 
                    borderWidth: 2, 
                    fill: true, 
                    tension: 0.2, 
                    pointRadius: 1, 
                    pointHoverRadius: 5 
                }] 
            }, 
            options: { ...commonOptions, scales: { x: timeScaleConfig, y: { type: 'linear', beginAtZero: true } } } 
        });

        new Chart(document.getElementById('lossChart'), { 
            type: 'bar', 
            data: { 
                datasets: [{ 
                    label: 'Loss (%)', 
                    data: rawData.map(d => ({x: d.x, y: d.l})), 
                    backgroundColor: '#dc3545', 
                    minBarLength: 4 
                }] 
            }, 
            options: { ...commonOptions, scales: { x: timeScaleConfig, y: { type: 'linear', min: 0, suggestedMax: 5 } } } 
        });
    </script>
</body>
</html>
HTML
