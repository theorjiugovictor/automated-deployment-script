# Automated Deployment Bash Script

A production-grade bash script for automated deployment of Dockerized applications with Nginx reverse proxy configuration.

## Features

- ✅ Interactive parameter collection with validation
- ✅ Git repository cloning with PAT authentication
- ✅ SSH connectivity testing
- ✅ Automated Docker, Docker Compose, and Nginx installation
- ✅ Support for both Dockerfile and docker-compose.yml
- ✅ Nginx reverse proxy configuration
- ✅ Comprehensive logging with timestamps
- ✅ Error handling with meaningful exit codes
- ✅ Idempotent operations (safe to re-run)
- ✅ Cleanup mode for resource removal

## Prerequisites

### Local Machine
- Bash 4.0+
- Git
- SSH client
- rsync

### Remote Server
- Ubuntu/Debian-based Linux
- SSH access with key-based authentication
- Sudo privileges for the SSH user

## Installation

1. Clone or download the script:
```bash
wget https://raw.githubusercontent.com/yourusername/yourrepo/main/deploy.sh
chmod +x deploy.sh
```

2. Ensure your SSH key is set up:
```bash
ssh-keygen -t rsa -b 4096 -C "your_email@example.com"
ssh-copy-id user@your-server-ip
```

## Usage

### Standard Deployment

Run the script:
```bash
./deploy.sh
```

You'll be prompted for:
1. **Git Repository URL** - HTTPS URL of your repository
2. **Personal Access Token** - GitHub/GitLab PAT with repo access
3. **Branch Name** - Defaults to `main` if not specified
4. **SSH Username** - Remote server username
5. **Server IP Address** - Target server IP
6. **SSH Key Path** - Defaults to `~/.ssh/id_rsa`
7. **Application Port** - Internal container port

### Cleanup Mode

Remove all deployed resources:
```bash
./deploy.sh --cleanup
```

## What the Script Does

### 1. Parameter Collection
- Validates all user inputs
- Checks SSH key existence
- Validates IP address and port format

### 2. Repository Management
- Clones repository using PAT authentication
- Pulls latest changes if repo exists
- Switches to specified branch
- Verifies Dockerfile or docker-compose.yml exists

### 3. SSH Connection
- Tests connectivity to remote server
- Validates SSH key authentication

### 4. Environment Setup
- Updates system packages
- Installs Docker, Docker Compose, Nginx
- Adds user to docker group
- Enables and starts services
- Verifies installations

### 5. Application Deployment
- Transfers project files via rsync
- Stops existing containers gracefully
- Builds Docker image
- Runs container with proper port mapping
- Validates container health

### 6. Nginx Configuration
- Creates reverse proxy configuration
- Forwards port 80 to application port
- Removes default site
- Tests and reloads Nginx

### 7. Validation
- Checks Docker service status
- Verifies container is running
- Tests Nginx service
- Validates endpoint accessibility

### 8. Logging
- Creates timestamped log file
- Logs all operations with timestamps
- Captures errors and outputs

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Empty parameter |
| 3 | Invalid parameter format |
| 4 | Missing dependency |
| 5 | SSH key not found |
| 6 | Invalid port number |
| 7 | Git clone/pull failed |
| 8 | Branch checkout failed |
| 9 | No Dockerfile found |
| 10 | SSH connection failed |
| 11 | Environment setup failed |
| 12 | File transfer failed |
| 13 | Application deployment failed |
| 14 | Nginx configuration failed |
| 15 | Validation failed |
| 16 | Cleanup failed |

## Directory Structure

After deployment:
```
Remote Server:
/home/username/deployments/
└── your-repo-name/
    ├── Dockerfile (or docker-compose.yml)
    ├── (your application files)
    └── ...

/etc/nginx/sites-available/
└── your-repo-name

/etc/nginx/sites-enabled/
└── your-repo-name -> ../sites-available/your-repo-name
```

## Examples

### Example 1: Simple Node.js App
```bash
./deploy.sh

# When prompted:
Git Repository URL: https://github.com/username/nodejs-app
PAT: ghp_xxxxxxxxxxxx
Branch: main
SSH Username: ubuntu
Server IP: 192.168.1.100
SSH Key Path: ~/.ssh/id_rsa
Application Port: 3000
```

### Example 2: Docker Compose App
```bash
./deploy.sh

# The script automatically detects docker-compose.yml
# and uses docker-compose commands instead
```

## Troubleshooting

### SSH Connection Issues
- Verify SSH key permissions: `chmod 600 ~/.ssh/id_rsa`
- Test manual SSH: `ssh -i ~/.ssh/id_rsa user@server-ip`
- Check server firewall rules

### Docker Issues
- Check Docker service: `sudo systemctl status docker`
- View container logs: `docker logs container-name`
- Verify ports aren't in use: `sudo netstat -tulpn | grep PORT`

### Nginx Issues
- Test configuration: `sudo nginx -t`
- Check Nginx logs: `sudo tail -f /var/log/nginx/error.log`
- Verify Nginx is running: `sudo systemctl status nginx`

### Application Not Accessible
- Check firewall: `sudo ufw status`
- Open port 80: `sudo ufw allow 80/tcp`
- Verify container is running: `docker ps`

## Security Considerations

- PAT is used in memory only and not stored
- SSH key-based authentication required
- Script uses `set -euo pipefail` for safety
- Temporary files cleaned up automatically
- StrictHostKeyChecking disabled for automation (consider enabling in production)

## Idempotency

The script is designed to be idempotent:
- Re-running won't break existing setups
- Old containers are stopped before new deployment
- Nginx configs are overwritten safely
- Repository is updated (not re-cloned)

## Logging

All operations are logged to `deploy_YYYYMMDD_HHMMSS.log`:
- Timestamped entries
- Success and error messages
- Command outputs for debugging

## Contributing

To improve this script:
1. Test thoroughly on your target environment
2. Add error handling for edge cases
3. Extend logging for better debugging
4. Add SSL/TLS certificate support
5. Implement health checks with retries

## License

MIT License - Feel free to modify and distribute

## Support

For issues or questions:
1. Check the log file for detailed error messages
2. Review the troubleshooting section
3. Verify all prerequisites are met
4. Test each component manually if needed

---

**Note**: This script is designed for learning and development. For production deployments, consider using mature tools like Ansible, Terraform, or Kubernetes.
