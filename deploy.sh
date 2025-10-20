#!/bin/bash

set -euo pipefail

LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
TEMP_DIR=$(mktemp -d)
CLEANUP_MODE=false

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit "${2:-1}"
}

cleanup() {
    log "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
}

trap cleanup EXIT
trap 'error_exit "Script interrupted" 130' INT TERM

validate_input() {
    local var_name=$1
    local var_value=$2
    local pattern=$3
    
    if [[ -z "$var_value" ]]; then
        error_exit "$var_name cannot be empty" 2
    fi
    
    if [[ -n "$pattern" ]] && ! [[ "$var_value" =~ $pattern ]]; then
        error_exit "$var_name format is invalid" 3
    fi
}

check_dependencies() {
    log "Checking local dependencies..."
    local deps=("git" "ssh" "scp")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error_exit "$dep is not installed" 4
        fi
    done
    log "All local dependencies satisfied"
}

collect_parameters() {
    log "Collecting deployment parameters..."
    
    read -rp "Enter Git Repository URL: " GIT_REPO_URL
    validate_input "Git Repository URL" "$GIT_REPO_URL" "^https?://.+"
    
    read -rsp "Enter Personal Access Token (PAT): " GIT_PAT
    echo
    validate_input "Personal Access Token" "$GIT_PAT" ""
    
    read -rp "Enter Branch name [main]: " GIT_BRANCH
    GIT_BRANCH=${GIT_BRANCH:-main}
    
    read -rp "Enter SSH Username: " SSH_USER
    validate_input "SSH Username" "$SSH_USER" ""
    
    read -rp "Enter Server IP Address: " SERVER_IP
    validate_input "Server IP" "$SERVER_IP" "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
    
    read -rp "Enter SSH Key Path [~/.ssh/id_rsa]: " SSH_KEY_PATH
    SSH_KEY_PATH=${SSH_KEY_PATH:-~/.ssh/id_rsa}
    SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
    
    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        error_exit "SSH key not found at $SSH_KEY_PATH" 5
    fi
    
    read -rp "Enter Application Port: " APP_PORT
    validate_input "Application Port" "$APP_PORT" "^[0-9]+$"
    
    if [[ $APP_PORT -lt 1 || $APP_PORT -gt 65535 ]]; then
        error_exit "Port must be between 1 and 65535" 6
    fi
    
    REPO_NAME=$(basename "$GIT_REPO_URL" .git)
    REPO_DIR="$TEMP_DIR/$REPO_NAME"
    
    log "Parameters collected successfully"
}

clone_repository() {
    log "Cloning repository from $GIT_REPO_URL..."
    
    local auth_url
    if [[ "$GIT_REPO_URL" =~ ^https://github.com ]]; then
        auth_url="${GIT_REPO_URL/https:\/\//https://${GIT_PAT}@}"
    else
        auth_url="https://${GIT_PAT}@${GIT_REPO_URL#https://}"
    fi
    
    if [[ -d "$REPO_DIR" ]]; then
        log "Repository already exists, pulling latest changes..."
        cd "$REPO_DIR"
        git pull origin "$GIT_BRANCH" >> "$LOG_FILE" 2>&1 || error_exit "Failed to pull repository" 7
    else
        git clone "$auth_url" "$REPO_DIR" >> "$LOG_FILE" 2>&1 || error_exit "Failed to clone repository" 7
        cd "$REPO_DIR"
    fi
    
    git checkout "$GIT_BRANCH" >> "$LOG_FILE" 2>&1 || error_exit "Failed to checkout branch $GIT_BRANCH" 8
    log "Repository ready at $REPO_DIR on branch $GIT_BRANCH"
}

verify_dockerfile() {
    log "Verifying Dockerfile or docker-compose.yml..."
    
    if [[ -f "Dockerfile" ]]; then
        log "Found Dockerfile"
        USE_COMPOSE=false
    elif [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; then
        log "Found docker-compose.yml"
        USE_COMPOSE=true
    else
        error_exit "No Dockerfile or docker-compose.yml found" 9
    fi
}

test_ssh_connection() {
    log "Testing SSH connection to $SSH_USER@$SERVER_IP..."
    
    if ! ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        "$SSH_USER@$SERVER_IP" "echo 'SSH connection successful'" >> "$LOG_FILE" 2>&1; then
        error_exit "SSH connection failed" 10
    fi
    
    log "SSH connection verified"
}

prepare_remote_environment() {
    log "Preparing remote environment on $SERVER_IP..."
    
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" << 'ENDSSH' >> "$LOG_FILE" 2>&1
        set -e
        
        echo "Updating system packages..."
        sudo apt-get update -qq
        
        echo "Installing Docker..."
        if ! command -v docker &> /dev/null; then
            sudo apt-get install -y docker.io
            sudo systemctl enable docker
            sudo systemctl start docker
        fi
        
        echo "Installing Docker Compose..."
        if ! command -v docker-compose &> /dev/null; then
            sudo apt-get install -y docker-compose
        fi
        
        echo "Installing Nginx..."
        if ! command -v nginx &> /dev/null; then
            sudo apt-get install -y nginx
            sudo systemctl enable nginx
            sudo systemctl start nginx
        fi
        
        echo "Adding user to docker group..."
        sudo usermod -aG docker $USER || true
        
        echo "Verifying installations..."
        docker --version
        docker-compose --version
        nginx -v
        
        echo "Remote environment ready"
ENDSSH
    
    if [[ $? -ne 0 ]]; then
        error_exit "Failed to prepare remote environment" 11
    fi
    
    log "Remote environment prepared successfully"
}

deploy_application() {
    log "Deploying application to remote server..."
    
    local remote_path="/home/$SSH_USER/deployments/$REPO_NAME"
    
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" \
        "mkdir -p $remote_path" >> "$LOG_FILE" 2>&1
    
    log "Transferring files to remote server..."
    rsync -avz --exclude='.git' -e "ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no" \
        "$REPO_DIR/" "$SSH_USER@$SERVER_IP:$remote_path/" >> "$LOG_FILE" 2>&1 || \
        error_exit "Failed to transfer files" 12
    
    log "Building and running Docker containers..."
    
    if [[ "$USE_COMPOSE" == true ]]; then
        ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" << ENDSSH >> "$LOG_FILE" 2>&1
            set -e
            cd $remote_path
            
            echo "Stopping existing containers..."
            docker-compose down || true
            
            echo "Building and starting containers..."
            docker-compose up -d --build
            
            echo "Waiting for containers to be healthy..."
            sleep 10
            
            docker-compose ps
ENDSSH
    else
        ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" << ENDSSH >> "$LOG_FILE" 2>&1
            set -e
            cd $remote_path
            
            CONTAINER_NAME="${REPO_NAME}_app"
            IMAGE_NAME="${REPO_NAME}:latest"
            
            echo "Stopping and removing existing container..."
            docker stop \$CONTAINER_NAME 2>/dev/null || true
            docker rm \$CONTAINER_NAME 2>/dev/null || true
            
            echo "Building Docker image..."
            docker build -t \$IMAGE_NAME .
            
            echo "Running container..."
            docker run -d --name \$CONTAINER_NAME -p $APP_PORT:$APP_PORT \$IMAGE_NAME
            
            echo "Waiting for container to be healthy..."
            sleep 10
            
            docker ps -a | grep \$CONTAINER_NAME
ENDSSH
    fi
    
    if [[ $? -ne 0 ]]; then
        error_exit "Failed to deploy application" 13
    fi
    
    log "Application deployed successfully"
}

configure_nginx() {
    log "Configuring Nginx reverse proxy..."
    
    local nginx_config="/etc/nginx/sites-available/$REPO_NAME"
    local nginx_enabled="/etc/nginx/sites-enabled/$REPO_NAME"
    
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" << ENDSSH >> "$LOG_FILE" 2>&1
        set -e
        
        echo "Creating Nginx configuration..."
        sudo tee $nginx_config > /dev/null << 'EOF'
server {
    listen 80;
    server_name _;
    
    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
        
        echo "Enabling site..."
        sudo rm -f $nginx_enabled
        sudo ln -s $nginx_config $nginx_enabled
        
        echo "Removing default site..."
        sudo rm -f /etc/nginx/sites-enabled/default
        
        echo "Testing Nginx configuration..."
        sudo nginx -t
        
        echo "Reloading Nginx..."
        sudo systemctl reload nginx
        
        echo "Nginx configured successfully"
ENDSSH
    
    if [[ $? -ne 0 ]]; then
        error_exit "Failed to configure Nginx" 14
    fi
    
    log "Nginx configured successfully"
}

validate_deployment() {
    log "Validating deployment..."
    
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" << 'ENDSSH' >> "$LOG_FILE" 2>&1
        set -e
        
        echo "Checking Docker service..."
        sudo systemctl is-active docker
        
        echo "Checking running containers..."
        docker ps
        
        echo "Checking Nginx service..."
        sudo systemctl is-active nginx
        
        echo "Testing local endpoint..."
        curl -sf http://localhost > /dev/null || echo "Warning: Local endpoint not responding"
ENDSSH
    
    if [[ $? -ne 0 ]]; then
        error_exit "Deployment validation failed" 15
    fi
    
    log "Testing remote endpoint..."
    if curl -sf "http://$SERVER_IP" > /dev/null 2>&1; then
        log "Remote endpoint is accessible"
    else
        log "WARNING: Remote endpoint not accessible via HTTP"
    fi
    
    log "Deployment validated successfully"
}

cleanup_resources() {
    log "Cleaning up deployment resources..."
    
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$SSH_USER@$SERVER_IP" << ENDSSH >> "$LOG_FILE" 2>&1
        set -e
        
        REMOTE_PATH="/home/$SSH_USER/deployments/$REPO_NAME"
        
        echo "Stopping containers..."
        cd \$REMOTE_PATH
        if [[ -f "docker-compose.yml" ]] || [[ -f "docker-compose.yaml" ]]; then
            docker-compose down -v
        else
            docker stop ${REPO_NAME}_app || true
            docker rm ${REPO_NAME}_app || true
            docker rmi ${REPO_NAME}:latest || true
        fi
        
        echo "Removing Nginx configuration..."
        sudo rm -f /etc/nginx/sites-enabled/$REPO_NAME
        sudo rm -f /etc/nginx/sites-available/$REPO_NAME
        sudo nginx -t && sudo systemctl reload nginx
        
        echo "Removing deployment directory..."
        rm -rf \$REMOTE_PATH
        
        echo "Cleanup completed"
ENDSSH
    
    if [[ $? -ne 0 ]]; then
        error_exit "Cleanup failed" 16
    fi
    
    log "Cleanup completed successfully"
}

main() {
    log "Starting deployment script..."
    
    if [[ "${1:-}" == "--cleanup" ]]; then
        CLEANUP_MODE=true
        log "Running in cleanup mode"
        
        read -rp "Enter SSH Username: " SSH_USER
        read -rp "Enter Server IP Address: " SERVER_IP
        read -rp "Enter SSH Key Path [~/.ssh/id_rsa]: " SSH_KEY_PATH
        SSH_KEY_PATH=${SSH_KEY_PATH:-~/.ssh/id_rsa}
        SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
        read -rp "Enter Repository Name: " REPO_NAME
        
        cleanup_resources
        log "Cleanup completed. Exiting."
        exit 0
    fi
    
    check_dependencies
    collect_parameters
    clone_repository
    verify_dockerfile
    test_ssh_connection
    prepare_remote_environment
    deploy_application
    configure_nginx
    validate_deployment
    
    log "Deployment completed successfully!"
    log "Application is accessible at: http://$SERVER_IP"
    log "Log file: $LOG_FILE"
}

main "$@"
