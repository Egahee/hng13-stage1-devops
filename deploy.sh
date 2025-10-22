#!/bin/sh
# Docker deploy script - DevOps bootcamp project
# This handles full app deployment to remote servers

set -e

# Setup logging
LOG_FILE="deploy_$(date +%Y%m%d).log"
echo "Starting deployment at $(date)" | tee -a "$LOG_FILE"

fail() {
    echo "FAILED: $1" | tee -a "$LOG_FILE"
    exit 1
}

# 1. Get deployment settings from user
echo "=== Deployment Setup ==="

printf "Git repo URL: "
read REPO_URL
[ -z "$REPO_URL" ] && fail "Need a repo URL"

printf "GitHub token: "
stty -echo
read PAT
stty echo
printf "\n"
[ -z "$PAT" ] && fail "Need a token"

printf "Branch [main]: "
read BRANCH
BRANCH=${BRANCH:-main}

printf "Server user: "
read REMOTE_USER
[ -z "$REMOTE_USER" ] && fail "Need server username"

printf "Server IP: "
read SERVER_IP
[ -z "$SERVER_IP" ] && fail "Need server IP"

printf "SSH key path: "
read SSH_KEY_PATH
[ ! -f "$SSH_KEY_PATH" ] && fail "SSH key missing"

printf "App port [3000]: "
read APP_PORT
APP_PORT=${APP_PORT:-3000}

# 2. Get the code
echo "=== Getting Application Code ==="

PROJECT_NAME=$(basename "$REPO_URL" .git)
# Add token to URL for private repos
REPO_URL_WITH_TOKEN=$(echo "$REPO_URL" | sed "s|https://|https://$PAT@|")

if [ -d "$PROJECT_NAME" ]; then
    echo "Repo exists - updating..."
    cd "$PROJECT_NAME"
    git pull origin "$BRANCH" || echo "Note: Update had issues" | tee -a "$LOG_FILE"
else
    echo "Cloning repo..."
    if git clone -b "$BRANCH" "$REPO_URL_WITH_TOKEN" "$PROJECT_NAME"; then
        cd "$PROJECT_NAME"
        echo "Cloned successfully" | tee -a "$LOG_FILE"
    else
        fail "Couldn't clone the repo"
    fi
fi

# 3. Check for Docker config
echo "=== Checking Docker Setup ==="
if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ]; then
    echo "Docker config found" | tee -a "$LOG_FILE"
else
    fail "No Dockerfile or compose file found"
fi

# 4. Test server connection
echo "=== Testing Server Connection ==="
if ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=10 "$REMOTE_USER@$SERVER_IP" "echo 'Connected'"; then
    echo "Server connection good" | tee -a "$LOG_FILE"
else
    fail "Can't connect to server"
fi

# 5. Setup server environment
echo "=== Preparing Server ==="
ssh -i "$SSH_KEY_PATH" "$REMOTE_USER@$SERVER_IP" "
    echo 'Installing dependencies...'
    sudo apt-get update -qq
    curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh
    sudo curl -L 'https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)' -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    sudo apt-get install -y nginx
    sudo usermod -aG docker $REMOTE_USER
    sudo systemctl enable docker nginx
    sudo systemctl start docker
" | tee -a "$LOG_FILE"

# 6. Deploy the app
echo "=== Deploying Application ==="

echo "Copying files to server..." | tee -a "$LOG_FILE"
scp -i "$SSH_KEY_PATH" -r . "$REMOTE_USER@$SERVER_IP:~/app" | tee -a "$LOG_FILE"

ssh -i "$SSH_KEY_PATH" "$REMOTE_USER@$SERVER_IP" "
    cd ~/app
    if [ -f 'docker-compose.yml' ] || [ -f 'docker-compose.yaml' ]; then
        sudo docker-compose down || true
        sudo docker-compose up -d --build
    else
        sudo docker stop app || true
        sudo docker rm app || true  
        sudo docker build -t app .
        sudo docker run -d -p $APP_PORT:$APP_PORT --name app app
    fi
" | tee -a "$LOG_FILE"

# 7. Setup Nginx
echo "=== Configuring Web Server ==="
ssh -i "$SSH_KEY_PATH" "$REMOTE_USER@$SERVER_IP" "
    sudo bash -c 'cat > /etc/nginx/sites-available/app << EOF
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \\$host;
        proxy_set_header X-Real-IP \\$remote_addr;
    }
}
EOF'
    sudo ln -sf /etc/nginx/sites-available/app /etc/nginx/sites-enabled/
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo nginx -t && sudo systemctl reload nginx
" | tee -a "$LOG_FILE"

# 8. Verify everything works
echo "=== Final Checks ==="
ssh -i "$SSH_KEY_PATH" "$REMOTE_USER@$SERVER_IP" "
    echo 'Containers running:'
    sudo docker ps
    echo 'Testing app...'
    curl -f http://localhost:$APP_PORT >/dev/null 2>&1 && echo 'App works' || echo 'App check failed'
    echo 'Testing web server...'
    curl -f http://localhost >/dev/null 2>&1 && echo 'Nginx works' || echo 'Nginx check failed'
" | tee -a "$LOG_FILE"

echo "=== Deployment finished at $(date) ===" | tee -a "$LOG_FILE"
echo "See $LOG_FILE for details" | tee -a "$LOG_FILE"
