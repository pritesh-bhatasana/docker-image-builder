# TrackWizz Deploy UI

A web UI that runs on your server and lets you select services, enter a branch + version, and deploy — with live log streaming.

---

## Setup on the server

```bash
# 1. Upload/copy this folder to:
/datadisk/home/pritesh.bhatasana/image-builder/

# 2. Install Node.js if not already installed
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# 3. Go to the project folder
cd /datadisk/home/pritesh.bhatasana/image-builder

# 4. Install dependencies
npm install

# 5. Make the deploy script executable
chmod +x deploy.sh

# 6. Start the server
node server.js
```

Then open in your browser:
```
http://192.168.107.139:3000
```

---

## Run as a background service (recommended)

Install pm2 so it keeps running after you close the terminal:

```bash
npm install -g pm2
pm2 start server.js --name trackwizz-deploy
pm2 save
pm2 startup   # follow the printed command to auto-start on reboot
```

To check logs:
```bash
pm2 logs trackwizz-deploy
```

To restart:
```bash
pm2 restart trackwizz-deploy
```

---

## Project structure

```
image-builder/
├── server.js          ← Express server (serves UI + runs deploy)
├── deploy.sh          ← The actual build/push script
├── package.json
├── public/
│   └── index.html     ← The web UI
└── TrackWizzNext/     ← Repo cloned here automatically on first deploy
```

---

## How it works

1. Open `http://192.168.107.139:3000` in your browser
2. Pick stack filter (All / .NET / Java / Frontend)
3. Select the services you want to build
4. Enter branch name and version number
5. Click **Deploy** — logs stream live into the terminal panel
6. Click **Cancel** (same button) to abort a running deploy

The server reads `DEPLOY_BRANCH`, `DEPLOY_VERSION`, and `DEPLOY_SERVICES` environment variables
and passes them to `deploy.sh`. The script handles repo clone/pull, build, Docker image creation and push to ACR.

---

## Port / firewall

If port 3000 is not accessible from your machine, open it:

```bash
sudo ufw allow 3000/tcp
```

Or change the port in `server.js` (line: `const PORT = 3000`).
