#!/opt/bin/bash
export PATH=/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin

# ==============================================================================
# KEENETIC PINGTOOL v1.6.1 (CLI FLAGS)
# Features: 
# - CLI: Added '-ipv4' flag to force IPv4-only mode at runtime.
# - CLI: Arguments handling allows mixing flags (e.g., "-ipv4 force").
# - CORE: Optimized DB writes & UI hiding logic.
# ==============================================================================

# ==============================================================================
# USER CONFIGURATION
# ==============================================================================
ENABLE_IPV6="true"  # Default behavior (can be overridden by -ipv4 flag)
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

# CDN URLs for Chart.js libraries
URL_CHARTJS="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.js"
URL_ADAPTER="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns/dist/chartjs-adapter-date-fns.bundle.min.js"
URL_ZOOM="https://cdnjs.cloudflare.com/ajax/libs/chartjs-plugin-zoom/2.0.1/chartjs-plugin-zoom.min.js"

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================
FORCE_HTML_GEN="false"

for arg in "$@"; do
    case $arg in
        -ipv4|--ipv4-only)
            ENABLE_IPV6="false"
            ;;
        force|--force)
            FORCE_HTML_GEN="true"
            ;;
    esac
done

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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] pingtool: Starting test (IPv6: $ENABLE_IPV6)..."

mkdir -p "$DB_DIR"
mkdir -p "$WEB_DIR"

# --- CHECK & DOWNLOAD DEPENDENCIES ---
download_lib() {
    URL=$1; FILE=$2
    if [ ! -f "$WEB_DIR/$FILE" ]; then
        echo " - Missing library $FILE. Downloading..."
        wget --no-check-certificate -q -O "$WEB_DIR/$FILE" "$URL"
        if [ $? -eq 0 ]; then echo "   [OK] Downloaded $FILE"; else echo "   [ERR] Failed to download $FILE"; fi
    fi
}

download_lib "$URL_CHARTJS" "chart.js"
download_lib "$URL_ADAPTER" "chartjs-adapter-date-fns.js"
download_lib "$URL_ZOOM" "chartjs-plugin-zoom.js"

# --- DB INIT ---
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
# IPv6 TEST (Conditional)
# ==============================================================================
LOSS_V6=0; AVG_PING_V6=0; JITTER_V6=0

if [ "$ENABLE_IPV6" = "true" ]; then
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
    rm -f "$TMP_PING_V6"
else
    echo " - IPv6 Testing Disabled (by config or flag)."
fi

rm -f "$TMP_PING"

# ==============================================================================
# CLEANUP & ALERTS
# ==============================================================================
echo " - Cleaning old records (> $RETENTION_DAYS days)..."
sqlite3 "$DB_FILE" "DELETE FROM stats WHERE timestamp < strftime('%s', 'now', '-$RETENTION_DAYS days');"
if [ "$ENABLE_IPV6" = "true" ]; then
    sqlite3 "$DB_FILE" "DELETE FROM stats_v6 WHERE timestamp < strftime('%s', 'now', '-$RETENTION_DAYS days');"
fi

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

# Alert Logic IPv6 (Conditional)
if [ "$ENABLE_IPV6" = "true" ]; then
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
STATS_V4=$(sqlite3 "$DB_FILE" "SELECT AVG(ping), AVG(jitter), AVG(loss) FROM (SELECT ping, jitter, loss FROM stats ORDER BY timestamp DESC LIMIT $MAX_DISPLAY_POINTS);")

if [ "$ENABLE_IPV6" = "true" ]; then
    JSON_V6=$(sqlite3 "$DB_FILE" "SELECT timestamp, ping, jitter, loss FROM stats_v6 ORDER BY timestamp DESC LIMIT $MAX_DISPLAY_POINTS;" | awk -F'|' '{printf "{x:%s000,p:%s,j:%s,l:%s},", $1, $2, $3, $4}' | sed 's/,$//')
    STATS_V6=$(sqlite3 "$DB_FILE" "SELECT AVG(ping), AVG(jitter), AVG(loss) FROM (SELECT ping, jitter, loss FROM stats_v6 ORDER BY timestamp DESC LIMIT $MAX_DISPLAY_POINTS);")
    JS_V6_CONFIG="true"
else
    JSON_V6=""
    STATS_V6="0|0|0"
    JS_V6_CONFIG="false"
fi

cat <<EOF > "$DATA_JS"
window.PING_DATA = {
    updated: "$DATE_UPDATE",
    config: { ipv6: $JS_V6_CONFIG },
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
# GENERATE STATIC HTML
# ==============================================================================
HTML_FILE="$WEB_DIR/index.html"
# Force regeneration to apply UI changes if requested
if [ ! -f "$HTML_FILE" ] || [ "$FORCE_HTML_GEN" = "true" ]; then
    echo " - Generating new HTML template (Adaptive UI)..."
cat <<'HTML_EOF' > "$HTML_FILE"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>Keenetic Dual-Stack Ping Monitor</title>
    <link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>⚡</text></svg>">
    
    <script src="chart.js"></script>
    <script src="chartjs-adapter-date-fns.js"></script>
    <script src="chartjs-plugin-zoom.js"></script>

    <style>
        /* CSS VARIABLES */
        :root { 
            --bg: #f4f7f6; --card: #ffffff; --text: #333333; --muted: #666666;
            --border: #e9ecef; --shadow: rgba(0,0,0,0.03);
            --blue: #007bff; --orange: #fd7e14; --red: #dc3545; 
            --teal: #20c997; --purple: #6f42c1; --darkred: #b02a37; 
        }
        @media (prefers-color-scheme: dark) {
            :root { --bg: #121212; --card: #1e1e1e; --text: #e0e0e0; --muted: #a0a0a0; --border: #2c2c2c; --shadow: rgba(0,0,0,0.5); }
        }

        body { font-family: -apple-system, sans-serif; background: var(--bg); color: var(--text); padding: 20px; margin: 0; transition: background 0.3s, color 0.3s; }
        .container { max-width: 1200px; margin: 0 auto; }
        
        /* HEADER - UNIFIED STYLE */
        .status-bar { 
            display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; 
            background: var(--card); padding: 15px 20px; border-radius: 8px; 
            border: 1px solid var(--border); margin-bottom: 25px; gap: 15px;
        }
        .header-title { margin: 0; font-weight: 700; display: flex; align-items: center; gap: 15px; font-size: 1.5rem; }
        .btn-home { text-decoration: none; font-size: 22px; border-right: 1px solid var(--border); padding-right: 15px; transition: transform 0.2s; }
        .btn-home:hover { transform: scale(1.1); }
        
        .status-controls { display: flex; align-items: center; gap: 15px; }
        
        .btn-refresh { background-color: var(--blue); color: #fff; border: none; padding: 8px 16px; border-radius: 4px; cursor: pointer; text-decoration: none; font-size: 13px; font-weight: 600;}
        .btn-refresh:hover { opacity: 0.9; }
        
        /* CONTENT */
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(100px, 1fr)); gap: 15px; margin-bottom: 25px; }
        .card { background: var(--card); padding: 15px; border-radius: 8px; text-align: center; box-shadow: 0 2px 5px var(--shadow); border: 1px solid var(--border); }
        .card h2 { margin: 0 0 5px; font-size: 12px; text-transform: uppercase; color: var(--muted); }
        .val { font-size: 26px; font-weight: 700; }
        small { color: var(--muted); }
        
        .chart-box { background: var(--card); padding: 15px; border-radius: 8px; margin-bottom: 25px; box-shadow: 0 2px 5px var(--shadow); border: 1px solid var(--border); }
        .chart-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px; border-bottom: 1px solid var(--border); padding-bottom: 10px; }
        .chart-title { font-weight: bold; font-size: 16px; }
        .chart-controls { display: flex; align-items: center; gap: 15px; font-size: 12px; color: var(--muted); }
        
        canvas { touch-action: pan-y !important; height: 220px; width: 100%; }
        .zoom-hint { font-weight: normal; font-size: 12px; color: var(--muted); margin-left: 5px; }
        .badge { background: var(--border); padding: 2px 6px; border-radius: 4px; font-size: 0.8em; margin-left: 5px; color: var(--text); }
        
        /* Mobile Breakpoint for Header */
        @media(max-width: 768px) {
            .status-bar { flex-direction: column; text-align: center; } 
            .header-title { font-size: 1.3rem; justify-content: center; }
            .status-controls { width: 100%; justify-content: center; }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="status-bar">
            <h2 class="header-title">
                <a href="../index.html" class="btn-home" title="Back to Dashboard">🏠</a>
                <span>⚡ Keenetic Ping Monitor</span>
            </h2>
            <div class="status-controls">
                <div>Last Update: <span id="lastUpdate" style="font-weight:700">Loading...</span></div>
                <a href="javascript:location.reload()" class="btn-refresh">Refresh</a>
            </div>
        </div>

        <h3 style="border-left: 4px solid var(--blue); padding-left: 10px; display:flex; align-items:center; flex-wrap:wrap; gap:10px;">
            IPv4 <span class="badge" id="targetV4"></span> 
            <span style="font-size:13px; font-weight:400; color:var(--muted); margin-left:10px" id="countV4"></span>
        </h3>
        
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

        <div id="ipv6_section">
            <h3 style="border-left: 4px solid var(--teal); padding-left: 10px; margin-top: 40px; display:flex; align-items:center; flex-wrap:wrap; gap:10px;">
                IPv6 <span class="badge" id="targetV6"></span>
                <span style="font-size:13px; font-weight:400; color:var(--muted); margin-left:10px" id="countV6"></span>
            </h3>
            
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
    </div>

    <script src="data.js"></script>

    <script>
        const commonOptions = {
            responsive: true, maintainAspectRatio: false,
            interaction: { mode: 'index', intersect: false },
            plugins: {
                legend: { display: false },
                zoom: { zoom: { drag: { enabled: true, backgroundColor: 'rgba(54, 162, 235, 0.2)' }, mode: 'x' } },
                tooltip: {
                    callbacks: {
                        title: function(context) {
                            const d = new Date(context[0].parsed.x);
                            return d.toLocaleString([], { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });
                        }
                    }
                }
            },
            scales: { 
                x: { type: 'time', time: { tooltipFormat: 'dd/MM/yyyy HH:mm', displayFormats: { minute: 'HH:mm', hour: 'dd/MM HH:mm', day: 'dd/MM' } }, ticks: { maxRotation: 0, autoSkip: true } }, 
                y: { beginAtZero: true } 
            },
            elements: { point: { radius: 2, hoverRadius: 5 } }
        };

        function toggleLog(cb, id) { 
            const c = Chart.getChart(id); 
            if(c) { 
                c.options.scales.y = cb.checked ? { type: 'logarithmic', min: 0.1, beginAtZero: false } : { type: 'linear', beginAtZero: true };
                c.update(); 
            } 
        }

        function render() {
            if(typeof window.PING_DATA === 'undefined') return;
            const d = window.PING_DATA;

            // HIDE IPv6 IF DISABLED IN CONFIG
            if (!d.config.ipv6) {
                document.getElementById('ipv6_section').style.display = 'none';
            }

            document.getElementById('lastUpdate').innerText = d.updated;
            document.getElementById('targetV4').innerText = d.targets.v4;
            
            // Populate Sample Counts
            document.getElementById('countV4').innerText = "(" + d.history.v4.length + " samples)";

            // Update DOM V4
            document.getElementById('v4_p').innerText = d.current.v4.ping + "ms";
            document.getElementById('v4_j').innerText = d.current.v4.jitter + "ms";
            document.getElementById('v4_l').innerText = d.current.v4.loss + "%";
            document.getElementById('v4_avg_p').innerText = d.averages.v4.p;
            document.getElementById('v4_avg_j').innerText = d.averages.v4.j;
            document.getElementById('v4_avg_l').innerText = d.averages.v4.l;

            const createChart = (id, dArr, color, isBar=false) => {
                if(!document.getElementById(id)) return; // Skip if element hidden/missing
                new Chart(document.getElementById(id), {
                    type: isBar ? 'bar' : 'line',
                    data: { datasets: [{ 
                        data: dArr, 
                        borderColor: color, backgroundColor: color, 
                        borderWidth: 1, fill: false 
                    }] },
                    options: commonOptions
                });
            };

            createChart('c_p4', d.history.v4.map(i=>({x:i.x, y:i.p})), '#007bff');
            createChart('c_j4', d.history.v4.map(i=>({x:i.x, y:i.j})), '#fd7e14');
            createChart('c_l4', d.history.v4.map(i=>({x:i.x, y:i.l})), '#dc3545', true);

            // ONLY RENDER IPv6 IF ENABLED
            if (d.config.ipv6) {
                document.getElementById('targetV6').innerText = d.targets.v6;
                document.getElementById('countV6').innerText = "(" + d.history.v6.length + " samples)";
                
                document.getElementById('v6_p').innerText = d.current.v6.ping + "ms";
                document.getElementById('v6_j').innerText = d.current.v6.jitter + "ms";
                document.getElementById('v6_l').innerText = d.current.v6.loss + "%";
                document.getElementById('v6_avg_p').innerText = d.averages.v6.p;
                document.getElementById('v6_avg_j').innerText = d.averages.v6.j;
                document.getElementById('v6_avg_l').innerText = d.averages.v6.l;

                createChart('c_p6', d.history.v6.map(i=>({x:i.x, y:i.p})), '#20c997');
                createChart('c_j6', d.history.v6.map(i=>({x:i.x, y:i.j})), '#6f42c1');
                createChart('c_l6', d.history.v6.map(i=>({x:i.x, y:i.l})), '#b02a37', true);
            }

            document.querySelectorAll('canvas').forEach(c => { c.ondblclick = () => Chart.getChart(c).resetZoom(); });
        }
        render();
    </script>
</body>
</html>
HTML_EOF
chmod 644 "$HTML_FILE"
fi
