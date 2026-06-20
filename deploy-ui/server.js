const express = require('express');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const app = express();
const PORT = 3000;
const DEPLOY_SCRIPT = path.join(__dirname, 'deploy.sh');
const LOCK_FILE = path.join(__dirname, '.deploy.lock');

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// ── Active deploy tracker ──────────────────────────────────────────────────────
let activeClients = [];
let deployLog = [];
let isDeploying = false;
let deployStatus = 'idle'; // idle | running | done | failed

function broadcast(data) {
  const msg = `data: ${JSON.stringify(data)}\n\n`;
  activeClients.forEach(res => res.write(msg));
}

function appendLog(line, type = 'info') {
  const entry = { time: new Date().toTimeString().slice(0, 8), line, type };
  deployLog.push(entry);
  // Keep last 2000 lines
  if (deployLog.length > 2000) deployLog.shift();
  broadcast({ event: 'log', ...entry });
}

// ── SSE endpoint ──────────────────────────────────────────────────────────────
app.get('/api/logs/stream', (req, res) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.flushHeaders();

  // Send current status + backlog immediately
  res.write(`data: ${JSON.stringify({ event: 'status', status: deployStatus })}\n\n`);
  deployLog.forEach(entry => {
    res.write(`data: ${JSON.stringify({ event: 'log', ...entry })}\n\n`);
  });

  activeClients.push(res);
  req.on('close', () => {
    activeClients = activeClients.filter(c => c !== res);
  });
});

// ── Status endpoint ───────────────────────────────────────────────────────────
app.get('/api/status', (req, res) => {
  res.json({ status: deployStatus, logCount: deployLog.length });
});

// ── Deploy endpoint ───────────────────────────────────────────────────────────
app.post('/api/deploy', (req, res) => {
  if (isDeploying) {
    return res.status(409).json({ error: 'A deploy is already running.' });
  }

  const { branch, version, services } = req.body;

  if (!branch || !version || !services || services.length === 0) {
    return res.status(400).json({ error: 'branch, version and services are required.' });
  }

  // Validate inputs — no shell injection
  if (!/^[\w\-\/\.]+$/.test(branch)) {
    return res.status(400).json({ error: 'Invalid branch name.' });
  }
  if (!/^[\w\-\.]+$/.test(version)) {
    return res.status(400).json({ error: 'Invalid version string.' });
  }

  res.json({ ok: true, message: 'Deploy started.' });

  // Clear previous log
  deployLog = [];
  isDeploying = true;
  deployStatus = 'running';
  broadcast({ event: 'status', status: 'running' });
  broadcast({ event: 'clear' });

  // Write lock
  fs.writeFileSync(LOCK_FILE, String(process.pid));

  // Build env for the script
  const env = {
    ...process.env,
    DEPLOY_BRANCH: branch,
    DEPLOY_VERSION: version,
    DEPLOY_SERVICES: services.join(','),
  };

  appendLog(`Starting deploy — branch: ${branch}, version: ${version}`, 'head');
  appendLog(`Services: ${services.join(', ')}`, 'info');
  appendLog('────────────────────────────────────────', 'dim');

  const child = spawn('bash', [DEPLOY_SCRIPT], {
    cwd: __dirname,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  const classify = (line) => {
    if (/error|failed|❌/i.test(line)) return 'err';
    if (/✅|done|success|completed|pushed/i.test(line)) return 'ok';
    if (/warning/i.test(line)) return 'warn';
    if (/^#|────/.test(line)) return 'dim';
    return 'info';
  };

  child.stdout.on('data', (data) => {
    data.toString().split('\n').forEach(line => {
      if (line.trim()) appendLog(line, classify(line));
    });
  });

  child.stderr.on('data', (data) => {
    data.toString().split('\n').forEach(line => {
      if (line.trim()) appendLog(line, 'err');
    });
  });

  child.on('close', (code) => {
    isDeploying = false;
    deployStatus = code === 0 ? 'done' : 'failed';
    fs.unlink(LOCK_FILE, () => {});
    appendLog('────────────────────────────────────────', 'dim');
    if (code === 0) {
      appendLog('Deploy finished successfully.', 'ok');
    } else {
      appendLog(`Deploy exited with code ${code}.`, 'err');
    }
    broadcast({ event: 'status', status: deployStatus });
  });

  child.on('error', (err) => {
    isDeploying = false;
    deployStatus = 'failed';
    fs.unlink(LOCK_FILE, () => {});
    appendLog(`Failed to start script: ${err.message}`, 'err');
    broadcast({ event: 'status', status: 'failed' });
  });
});

// ── Cancel endpoint ───────────────────────────────────────────────────────────
app.post('/api/cancel', (req, res) => {
  if (!isDeploying) return res.json({ ok: false, message: 'Nothing running.' });
  try {
    const pid = fs.readFileSync(LOCK_FILE, 'utf8').trim();
    process.kill(-parseInt(pid), 'SIGTERM');
  } catch (_) {}
  isDeploying = false;
  deployStatus = 'failed';
  appendLog('Deploy cancelled by user.', 'warn');
  broadcast({ event: 'status', status: 'failed' });
  res.json({ ok: true });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`TrackWizz Deploy UI running on http://0.0.0.0:${PORT}`);
});
