#!/bin/bash
#
# =============================================================================
# Outline Server Installer - Version 3.2 (Final Gold Standard)
# Fully Interactive + Cloudflare Tunnel + WebSocket Support
# Designed for users in restricted networks (Iran, China, etc.)
# =============================================================================
#
# Copyright 2024 - Enhanced Edition
# Based on original Outline Server installation script
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# =============================================================================

set -euo pipefail

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================

# Directory paths
readonly SHADOWBOX_DIR="/opt/outline"
readonly STATE_DIR="${SHADOWBOX_DIR}/persisted-state"
readonly ACCESS_CONFIG="${SHADOWBOX_DIR}/access.txt"
readonly CONFIG_YAML="${SHADOWBOX_DIR}/config.yaml"
readonly CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
readonly CLOUDFLARED_CONFIG="/etc/cloudflared/config.yml"

# Container settings
readonly CONTAINER_NAME="shadowbox"
readonly SB_IMAGE="quay.io/outline/shadowbox:stable"

# Tunnel settings
readonly TUNNEL_NAME="outline-tunnel"
readonly TUNNEL_PORT="8080"

# User input variables
DOMAIN=""
API_PORT=""
KEYS_PORT=""

# Auto-generated variables
TUNNEL_ID=""
TCP_PATH=""
UDP_PATH=""
SECRET_KEY=""
TUNNEL_URL=""
CERT_SHA256=""

# Logging files
FULL_LOG="$(mktemp -t outline_install_log_XXXXXXXXXX)"
LAST_ERROR="$(mktemp -t outline_last_error_XXXXXXXXXX)"
readonly FULL_LOG LAST_ERROR

# Colors for output
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_MAGENTA='\033[0;35m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_WHITE='\033[1;37m'
readonly COLOR_RESET='\033[0m'
readonly COLOR_BOLD='\033[1m'

# =============================================================================
# LOGGING AND UTILITY FUNCTIONS
# =============================================================================

function log_command() {
    # Execute command and capture both stdout and stderr
    # stdout is forwarded to terminal and logged, stderr is logged and stored in LAST_ERROR
    "$@" > >(tee -a "${FULL_LOG}") 2> >(tee -a "${FULL_LOG}" > "${LAST_ERROR}")
}

function log_info() {
    local message="$1"
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} ${message}"
    echo "[INFO] ${message}" >> "${FULL_LOG}"
}

function log_success() {
    local message="$1"
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} ${message}"
    echo "[SUCCESS] ${message}" >> "${FULL_LOG}"
}

function log_warning() {
    local message="$1"
    echo -e "${COLOR_YELLOW}[WARNING]${COLOR_RESET} ${message}"
    echo "[WARNING] ${message}" >> "${FULL_LOG}"
}

function log_error() {
    local message="$1"
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} ${message}" >&2
    echo "[ERROR] ${message}" >> "${FULL_LOG}"
}

function log_start_step() {
    local message="$1"
    echo -ne "${COLOR_CYAN}>${COLOR_RESET} ${message} ... "
    echo "[STEP] ${message}" >> "${FULL_LOG}"
}

function log_step_result() {
    local status="$1"
    if [[ "${status}" == "OK" ]]; then
        echo -e "${COLOR_GREEN}✅ OK${COLOR_RESET}"
        echo "[STEP] OK" >> "${FULL_LOG}"
    else
        echo -e "${COLOR_RED}❌ FAILED${COLOR_RESET}"
        echo "[STEP] FAILED" >> "${FULL_LOG}"
        return 1
    fi
}

function run_step() {
    local step_name="$1"
    shift
    log_start_step "${step_name}"
    if log_command "$@"; then
        log_step_result "OK"
        return 0
    else
        log_step_result "FAILED"
        return 1
    fi
}

function confirm() {
    local prompt="$1"
    local default="${2:-yes}"
    local response=""
    
    if [[ "${default}" == "yes" ]]; then
        prompt="${prompt} [Y/n] "
    else
        prompt="${prompt} [y/N] "
    fi
    
    echo -ne "${COLOR_YELLOW}${prompt}${COLOR_RESET}"
    read -r response
    
    if [[ -z "${response}" ]]; then
        response="${default}"
    fi
    
    response=$(echo "${response}" | tr '[:upper:]' '[:lower:]')
    [[ "${response}" == "y" || "${response}" == "yes" ]]
}

function command_exists() {
    command -v "$@" &> /dev/null
}

function fetch_url() {
    curl --silent --show-error --fail --location "$@"
}

function sanitize_input() {
    local input="$1"
    # Remove carriage returns, non-printable characters, and trim whitespace
    echo "$input" | tr -d '\r\n' | sed 's/[^[:print:]]//g' | xargs
}

function print_banner() {
    cat <<EOF
${COLOR_CYAN}
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   ${COLOR_WHITE}Outline Server Installer v3.2${COLOR_CYAN}                          ║
║   ${COLOR_WHITE}Final Gold Standard - Cloudflare Tunnel + WebSocket${COLOR_CYAN}   ║
║                                                              ║
║   ${COLOR_YELLOW}Designed for Restricted Networks${COLOR_CYAN}                      ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
${COLOR_RESET}
EOF
}

function print_separator() {
    echo -e "${COLOR_CYAN}════════════════════════════════════════════════════════════════${COLOR_RESET}"
}

# =============================================================================
# FINISH TRAP - Cleanup on exit
# =============================================================================

function finish() {
    local exit_code=$?
    
    if [[ ${exit_code} -ne 0 ]]; then
        echo ""
        print_separator
        log_error "Installation failed with exit code: ${exit_code}"
        
        if [[ -s "${LAST_ERROR}" ]]; then
            log_error "Last error: $(< "${LAST_ERROR}")"
        fi
        
        log_error "Full installation log: ${FULL_LOG}"
        log_error "Please check the log file for detailed error information."
        
        # Copy log to permanent location for debugging
        if [[ -d "${SHADOWBOX_DIR}" ]]; then
            cp "${FULL_LOG}" "${SHADOWBOX_DIR}/install_error_$(date +%Y%m%d_%H%M%S).log" 2>/dev/null || true
            log_error "A copy of the log has been saved to: ${SHADOWBOX_DIR}/install_error_*.log"
        fi
        
        print_separator
    else
        # Clean up temporary log on success
        rm -f "${FULL_LOG}" "${LAST_ERROR}" 2>/dev/null || true
    fi
}

trap finish EXIT

# =============================================================================
# USER INPUT FUNCTIONS
# =============================================================================

function get_user_input() {
    echo ""
    print_separator
    log_info "Please provide the following information to configure your server:"
    echo ""
    
    # Get domain
    while true; do
        echo -ne "${COLOR_WHITE}Enter your domain (e.g., vpn.example.com):${COLOR_RESET} "
        read -r raw_domain
        DOMAIN=$(sanitize_input "${raw_domain}")
        
        if [[ -z "${DOMAIN}" ]]; then
            log_error "Domain cannot be empty. Please try again."
            continue
        fi
        
        # Basic domain validation
        if [[ ! "${DOMAIN}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,}$ ]]; then
            log_warning "The domain format seems invalid. Please verify your input."
            if ! confirm "Continue with '${DOMAIN}'?"; then
                continue
            fi
        fi
        
        break
    done
    
    # Get API port
    while true; do
        echo -ne "${COLOR_WHITE}Enter API port (press Enter for random port):${COLOR_RESET} "
        read -r raw_api_port
        API_PORT=$(sanitize_input "${raw_api_port}")
        
        if [[ -z "${API_PORT}" ]]; then
            API_PORT=$(( RANDOM % 55535 + 10000 ))
            log_info "Using randomly generated port: ${API_PORT}"
            break
        fi
        
        if [[ ! "${API_PORT}" =~ ^[0-9]+$ ]] || [[ "${API_PORT}" -lt 1 ]] || [[ "${API_PORT}" -gt 65535 ]]; then
            log_error "Invalid port number. Port must be between 1 and 65535."
            continue
        fi
        
        break
    done
    
    # Get keys port
    while true; do
        echo -ne "${COLOR_WHITE}Enter access keys port (press Enter for random port):${COLOR_RESET} "
        read -r raw_keys_port
        KEYS_PORT=$(sanitize_input "${raw_keys_port}")
        
        if [[ -z "${KEYS_PORT}" ]]; then
            KEYS_PORT=$(( RANDOM % 55535 + 10000 ))
            log_info "Using randomly generated port: ${KEYS_PORT}"
            break
        fi
        
        if [[ ! "${KEYS_PORT}" =~ ^[0-9]+$ ]] || [[ "${KEYS_PORT}" -lt 1 ]] || [[ "${KEYS_PORT}" -gt 65535 ]]; then
            log_error "Invalid port number. Port must be between 1 and 65535."
            continue
        fi
        
        break
    done
    
    # Check if ports are the same
    if [[ "${API_PORT}" -eq "${KEYS_PORT}" ]]; then
        log_warning "API port and Keys port are the same. This is not recommended."
        if ! confirm "Continue with same ports?"; then
            KEYS_PORT=$(( RANDOM % 55535 + 10000 ))
            log_info "Using new random port for keys: ${KEYS_PORT}"
        fi
    fi
    
    echo ""
    print_separator
    log_info "Configuration Summary:"
    echo ""
    echo "  ${COLOR_WHITE}Domain:${COLOR_RESET}       ${DOMAIN}"
    echo "  ${COLOR_WHITE}API Port:${COLOR_RESET}     ${API_PORT}"
    echo "  ${COLOR_WHITE}Keys Port:${COLOR_RESET}    ${KEYS_PORT}"
    echo ""
    print_separator
    
    if ! confirm "Proceed with these settings?"; then
        log_error "Installation cancelled by user."
        exit 0
    fi
    
    echo ""
}

# =============================================================================
# PREREQUISITE CHECK FUNCTIONS
# =============================================================================

function check_architecture() {
    local arch
    arch=$(uname -m)
    if [[ "${arch}" != "x86_64" ]]; then
        log_error "Unsupported architecture: ${arch}"
        log_error "This script only supports x86_64 (amd64) architecture."
        log_error "Your system architecture: ${arch}"
        exit 1
    fi
    log_info "Architecture: ${arch} (supported)"
}

function check_os_support() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "${ID}" == "ubuntu" ]] || [[ "${ID}" == "debian" ]]; then
            log_info "Operating System: ${PRETTY_NAME} (supported)"
        else
            log_warning "Operating System: ${PRETTY_NAME} (may not be fully supported)"
            if ! confirm "Continue with unsupported OS?"; then
                exit 0
            fi
        fi
    else
        log_warning "Could not detect operating system. Continuing anyway..."
    fi
}

function check_curl() {
    if command_exists curl; then
        log_success "curl is installed."
        return 0
    fi
    
    log_error "curl is not installed."
    if confirm "Install curl automatically using apt?"; then
        run_step "Installing curl" sudo apt update && sudo apt install -y curl
        if command_exists curl; then
            log_success "curl installed successfully."
            return 0
        else
            log_error "Failed to install curl. Please install it manually: sudo apt install curl"
            exit 1
        fi
    else
        log_error "curl is required for this installation."
        log_error "Please install curl: sudo apt install curl"
        exit 1
    fi
}

function check_docker() {
    if command_exists docker; then
        log_success "Docker is installed."
        return 0
    fi
    
    log_info "Docker is not installed."
    if confirm "Install Docker automatically using get.docker.com?"; then
        run_step "Installing Docker" install_docker
        if command_exists docker; then
            log_success "Docker installed successfully."
            return 0
        else
            log_error "Failed to install Docker. Please check the logs."
            exit 1
        fi
    else
        log_error "Docker is required for this installation."
        log_error "Please install Docker manually: curl -fsSL https://get.docker.com | sh"
        exit 1
    fi
}

function install_docker() {
    (
        umask 0022
        fetch_url https://get.docker.com/ | sh
    ) >&2
}

function check_docker_running() {
    if docker info &> /dev/null; then
        log_success "Docker daemon is running."
        return 0
    fi
    
    log_info "Docker daemon is not running."
    
    # Try to start Docker
    if command_exists systemctl; then
        log_info "Attempting to start Docker using systemctl..."
        if systemctl start docker 2>/dev/null; then
            log_success "Docker started successfully."
            return 0
        fi
    fi
    
    log_error "Docker daemon is not running and could not be started."
    if confirm "Try to enable and start Docker service?"; then
        systemctl enable docker --now 2>/dev/null || true
        if docker info &> /dev/null; then
            log_success "Docker started successfully."
            return 0
        fi
    fi
    
    log_error "Please start Docker manually and run this script again."
    log_error "Common commands: sudo systemctl start docker"
    exit 1
}

function check_openssl() {
    if command_exists openssl; then
        log_success "openssl is installed."
        return 0
    fi
    
    log_error "openssl is not installed."
    if confirm "Install openssl automatically using apt?"; then
        run_step "Installing openssl" sudo apt update && sudo apt install -y openssl
        if command_exists openssl; then
            log_success "openssl installed successfully."
            return 0
        else
            log_error "Failed to install openssl. Please install it manually: sudo apt install openssl"
            exit 1
        fi
    else
        log_error "openssl is required for certificate generation."
        log_error "Please install openssl: sudo apt install openssl"
        exit 1
    fi
}

function check_wget() {
    if command_exists wget; then
        log_success "wget is installed."
        return 0
    fi
    
    log_info "wget is not installed. Installing automatically..."
    run_step "Installing wget" sudo apt update && sudo apt install -y wget
    if command_exists wget; then
        log_success "wget installed successfully."
        return 0
    else
        log_warning "wget installation failed. Will use curl as fallback."
        return 0
    fi
}

function check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (sudo)."
        log_error "Please re-run with: sudo $0"
        exit 1
    fi
    log_success "Running as root."
}

function check_disk_space() {
    local required_mb=1024
    local available_mb
    available_mb=$(df -m "${SHADOWBOX_DIR%/*}" | awk 'NR==2 {print $4}')
    
    if [[ -z "${available_mb}" ]]; then
        available_mb=$(df -m / | awk 'NR==2 {print $4}')
    fi
    
    if [[ ${available_mb} -lt ${required_mb} ]]; then
        log_error "Not enough disk space."
        log_error "Required: ${required_mb}MB, Available: ${available_mb}MB"
        log_error "Please free up disk space and try again."
        exit 1
    fi
    
    log_info "Disk space available: ${available_mb}MB (Required: ${required_mb}MB)"
}

# =============================================================================
# CLOUDFLARE TUNNEL FUNCTIONS
# =============================================================================

function install_cloudflared() {
    if command_exists cloudflared; then
        log_success "cloudflared is already installed."
        return 0
    fi
    
    log_info "Installing cloudflared..."
    local temp_file
    temp_file=$(mktemp)
    
    if fetch_url -o "${temp_file}" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"; then
        sudo mv "${temp_file}" "${CLOUDFLARED_BIN}"
        sudo chmod +x "${CLOUDFLARED_BIN}"
        
        if command_exists cloudflared; then
            log_success "cloudflared installed successfully."
            return 0
        fi
    fi
    
    log_error "Failed to install cloudflared."
    rm -f "${temp_file}" 2>/dev/null || true
    return 1
}

function check_cloudflare_auth() {
    if [[ -f ~/.cloudflared/cert.pem ]]; then
        log_success "Cloudflare authentication found."
        return 0
    fi
    
    log_warning "Cloudflare authentication required."
    echo ""
    log_info "Please follow these steps to authenticate with Cloudflare:"
    echo ""
    echo "  1. ${COLOR_WHITE}Run the following command to get a login URL:${COLOR_RESET}"
    echo "     ${COLOR_WHITE}cloudflared tunnel login${COLOR_RESET}"
    echo ""
    echo "  2. ${COLOR_WHITE}Copy the URL shown in the terminal.${COLOR_RESET}"
    echo "  3. ${COLOR_WHITE}Open the URL in your browser (on your computer).${COLOR_RESET}"
    echo "  4. ${COLOR_WHITE}Log in to Cloudflare and select your domain (${DOMAIN}).${COLOR_RESET}"
    echo "  5. ${COLOR_WHITE}After authorization, return to this terminal and press Enter.${COLOR_RESET}"
    echo ""
    
    if confirm "Run cloudflared login now?"; then
        echo ""
        log_info "Running cloudflared tunnel login. Please look for the URL in the output below:"
        echo ""
        # Run cloudflared login and capture output, but let user see it
        cloudflared tunnel login 2>&1 | tee -a "${FULL_LOG}"
        echo ""
        log_info "After completing the browser authorization, press Enter to continue."
        read -r
    else
        log_error "Cloudflare authentication is required to continue."
        log_error "Please run manually: cloudflared tunnel login"
        exit 1
    fi
    
    if [[ -f ~/.cloudflared/cert.pem ]]; then
        log_success "Cloudflare authentication successful."
        return 0
    else
        log_error "Cloudflare authentication failed. Please run: cloudflared tunnel login"
        return 1
    fi
}

function setup_cloudflare_tunnel() {
    log_info "Setting up Cloudflare Tunnel..."
    
    # Check if tunnel already exists
    local tunnel_exists=false
    if cloudflared tunnel list 2>/dev/null | grep -q "${TUNNEL_NAME}"; then
        tunnel_exists=true
        log_info "Tunnel '${TUNNEL_NAME}' already exists."
        if ! confirm "Use existing tunnel or create new one?" "no"; then
            tunnel_exists=false
        fi
    fi
    
    if [[ "${tunnel_exists}" == "false" ]]; then
        log_info "Creating new tunnel: ${TUNNEL_NAME}"
        if ! cloudflared tunnel create "${TUNNEL_NAME}"; then
            log_error "Failed to create tunnel."
            return 1
        fi
        log_success "Tunnel created successfully."
    fi
    
    # Get tunnel ID
    TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | grep "${TUNNEL_NAME}" | awk '{print $1}')
    if [[ -z "${TUNNEL_ID}" ]]; then
        log_error "Failed to get tunnel ID."
        return 1
    fi
    log_info "Tunnel ID: ${TUNNEL_ID}"
    
    # Route DNS
    log_info "Routing DNS for: ${DOMAIN}"
    if cloudflared tunnel route dns "${TUNNEL_NAME}" "${DOMAIN}" 2>&1 | tee -a "${FULL_LOG}"; then
        log_success "DNS route configured successfully."
    else
        log_warning "DNS route may already exist. Continuing..."
    fi
    
    # Create config directory
    sudo mkdir -p /etc/cloudflared
    
    # Create config file
    log_info "Creating Cloudflare config file..."
    local config_content
    config_content=$(cat <<EOF
tunnel: ${TUNNEL_NAME}
credentials-file: /root/.cloudflared/${TUNNEL_ID}.json

ingress:
  - hostname: ${DOMAIN}
    service: http://localhost:${TUNNEL_PORT}
  - service: http_status:404
EOF
)
    
    echo "${config_content}" | sudo tee "${CLOUDFLARED_CONFIG}" > /dev/null
    log_success "Config file created: ${CLOUDFLARED_CONFIG}"
    
    # Install as systemd service
    log_info "Installing Cloudflare Tunnel as systemd service..."
    cloudflared service install "${TUNNEL_NAME}" 2>&1 | tee -a "${FULL_LOG}"
    
    # Enable and start service
    local service_name="cloudflared-${TUNNEL_NAME}"
    if systemctl enable "${service_name}" 2>/dev/null && systemctl start "${service_name}" 2>/dev/null; then
        log_success "Cloudflare Tunnel service started."
    else
        log_error "Failed to start Cloudflare Tunnel service."
        return 1
    fi
    
    # Wait for tunnel to be ready
    log_info "Waiting for tunnel to be ready..."
    local attempts=0
    local max_attempts=30
    while [[ ${attempts} -lt ${max_attempts} ]]; do
        if systemctl is-active --quiet "${service_name}"; then
            log_success "Cloudflare Tunnel is running."
            # Get tunnel URL
            TUNNEL_URL="https://${DOMAIN}"
            log_info "Tunnel URL: ${TUNNEL_URL}"
            return 0
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    
    log_error "Cloudflare Tunnel failed to start within ${max_attempts} seconds."
    return 1
}

# =============================================================================
# OUTLINE SS SERVER FUNCTIONS
# =============================================================================

function install_outline_ss_server() {
    local binary_path="${SHADOWBOX_DIR}/outline-ss-server"
    
    if [[ -f "${binary_path}" ]]; then
        log_info "outline-ss-server already downloaded."
        if confirm "Use existing binary or download fresh copy?" "no"; then
            return 0
        fi
    fi
    
    log_info "Downloading outline-ss-server..."
    local temp_file
    temp_file=$(mktemp)
    
    if fetch_url -o "${temp_file}" "https://github.com/OutlineFoundation/outline-ss-server/releases/latest/download/outline-ss-server-linux-amd64"; then
        sudo mv "${temp_file}" "${binary_path}"
        sudo chmod +x "${binary_path}"
        log_success "outline-ss-server downloaded successfully."
        return 0
    fi
    
    log_error "Failed to download outline-ss-server."
    rm -f "${temp_file}" 2>/dev/null || true
    return 1
}

function configure_outline_ss_server() {
    log_info "Configuring outline-ss-server..."
    
    # Generate random paths and secret
    TCP_PATH="/$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)"
    UDP_PATH="/$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)"
    SECRET_KEY="$(openssl rand -base64 32 | tr -d '\n=')"
    
    log_info "TCP Path: ${TCP_PATH}"
    log_info "UDP Path: ${UDP_PATH}"
    log_info "Secret key generated."
    
    # Create config directory
    sudo mkdir -p "${SHADOWBOX_DIR}"
    
    # Create config file
    local config_content
    config_content=$(cat <<EOF
# Outline SS Server Configuration
# Generated by Outline Installer v3.2

web:
  servers:
    - id: server1
      listen: "127.0.0.1:${TUNNEL_PORT}"
      services:
        - listeners:
            - type: websocket-stream
              web_server: server1
              path: ${TCP_PATH}
            - type: websocket-packet
              web_server: server1
              path: ${UDP_PATH}

keys:
  - id: 1
    cipher: chacha20-ietf-poly1305
    secret: ${SECRET_KEY}
EOF
)
    
    echo "${config_content}" | sudo tee "${CONFIG_YAML}" > /dev/null
    sudo chmod 600 "${CONFIG_YAML}"
    log_success "Configuration file created: ${CONFIG_YAML}"
}

function start_outline_ss_server() {
    log_info "Starting outline-ss-server..."
    
    # Check if already running
    if pgrep -f "outline-ss-server" > /dev/null; then
        log_warning "outline-ss-server appears to be running."
        if confirm "Kill existing process and restart?"; then
            pkill -f "outline-ss-server" 2>/dev/null || true
            sleep 2
        else
            log_info "Continuing with existing process."
            return 0
        fi
    fi
    
    # Start server in background
    local binary_path="${SHADOWBOX_DIR}/outline-ss-server"
    nohup "${binary_path}" -config "${CONFIG_YAML}" >> "${SHADOWBOX_DIR}/outline-ss.log" 2>&1 &
    local pid=$!
    
    sleep 3
    
    if kill -0 "${pid}" 2>/dev/null; then
        log_success "outline-ss-server started successfully (PID: ${pid})."
        return 0
    else
        log_error "outline-ss-server failed to start."
        return 1
    fi
}

# =============================================================================
# ACCESS KEY GENERATION FUNCTIONS
# =============================================================================

function generate_certificate() {
    log_info "Generating SSL certificate..."
    
    local cert_dir="${STATE_DIR}"
    sudo mkdir -p "${cert_dir}"
    
    local cert_file="${cert_dir}/shadowbox-selfsigned.crt"
    local key_file="${cert_dir}/shadowbox-selfsigned.key"
    
    # Generate self-signed certificate
    openssl req -x509 -nodes -days 36500 -newkey rsa:4096 \
        -subj "/CN=${DOMAIN}" \
        -keyout "${key_file}" \
        -out "${cert_file}" 2>&1 | tee -a "${FULL_LOG}"
    
    if [[ -f "${cert_file}" ]] && [[ -f "${key_file}" ]]; then
        sudo chmod 600 "${cert_file}" "${key_file}"
        log_success "Certificate generated: ${cert_file}"
        
        # Get fingerprint
        CERT_SHA256=$(openssl x509 -in "${cert_file}" -noout -sha256 -fingerprint 2>/dev/null | cut -d= -f2 | tr -d ':')
        log_info "Certificate SHA256: ${CERT_SHA256}"
        return 0
    else
        log_error "Failed to generate certificate."
        return 1
    fi
}

function generate_access_key() {
    log_info "Generating access key..."
    
    # Read the secret key from config
    local secret
    secret=$(grep "^[[:space:]]*secret:" "${CONFIG_YAML}" | awk '{print $2}' | tr -d '"' | head -1)
    if [[ -z "${secret}" ]]; then
        secret="${SECRET_KEY}"
    fi
    
    # Read the TCP and UDP paths
    local tcp_path
    local udp_path
    tcp_path=$(grep -A1 "websocket-stream" "${CONFIG_YAML}" | grep "path:" | awk '{print $2}' | head -1)
    udp_path=$(grep -A1 "websocket-packet" "${CONFIG_YAML}" | grep "path:" | awk '{print $2}' | head -1)
    
    if [[ -z "${tcp_path}" ]] || [[ -z "${udp_path}" ]]; then
        tcp_path="${TCP_PATH}"
        udp_path="${UDP_PATH}"
    fi
    
    # Build access key in Outline Manager format
    local api_url="https://${DOMAIN}/key"
    
    # Create access config file
    sudo mkdir -p "${SHADOWBOX_DIR}"
    sudo tee "${ACCESS_CONFIG}" > /dev/null <<EOF
apiUrl:${api_url}
certSha256:${CERT_SHA256}
tcpPath:${tcp_path}
udpPath:${udp_path}
secret:${secret}
EOF
    
    sudo chmod 600 "${ACCESS_CONFIG}"
    
    log_success "Access key generated successfully."
    log_info "Access config saved to: ${ACCESS_CONFIG}"
}

function get_json_output() {
    local api_url
    local cert_sha256
    
    if [[ -f "${ACCESS_CONFIG}" ]]; then
        api_url=$(grep "^apiUrl:" "${ACCESS_CONFIG}" | cut -d: -f2- | sed 's/^ *//')
        cert_sha256=$(grep "^certSha256:" "${ACCESS_CONFIG}" | cut -d: -f2- | sed 's/^ *//')
    else
        api_url="https://${DOMAIN}/key"
        cert_sha256="${CERT_SHA256:-DUMMY_CERT_SHA256}"
    fi
    
    echo "{\"apiUrl\":\"${api_url}\",\"certSha256\":\"${cert_sha256}\"}"
}

# =============================================================================
# FIREWALL FUNCTIONS
# =============================================================================

function check_firewall() {
    log_info "Checking firewall configuration..."
    
    # Check for UFW
    if command_exists ufw; then
        log_info "UFW firewall detected."
        echo ""
        log_warning "Please ensure the following ports are open:"
        echo "  - TCP ${API_PORT} (Management API)"
        echo "  - TCP ${KEYS_PORT} (Access Keys)"
        echo "  - UDP ${KEYS_PORT} (Access Keys)"
        echo ""
        echo "To open these ports with UFW, run:"
        echo "  sudo ufw allow ${API_PORT}/tcp"
        echo "  sudo ufw allow ${KEYS_PORT}/tcp"
        echo "  sudo ufw allow ${KEYS_PORT}/udp"
        echo ""
        
        if confirm "Open these ports with UFW now?"; then
            run_step "Opening UFW ports" ufw allow "${API_PORT}/tcp"
            run_step "Opening UFW keys port TCP" ufw allow "${KEYS_PORT}/tcp"
            run_step "Opening UFW keys port UDP" ufw allow "${KEYS_PORT}/udp"
        fi
    else
        log_info "UFW not found. Please ensure firewall ports are open manually."
    fi
    
    # Check for iptables
    if command_exists iptables; then
        log_info "iptables detected. Please ensure ports are open."
    fi
}

# =============================================================================
# FINAL OUTPUT FUNCTIONS
# =============================================================================

function display_final_output() {
    echo ""
    print_separator
    echo -e "${COLOR_GREEN}${COLOR_BOLD}🎉 CONGRATULATIONS! YOUR OUTLINE SERVER IS UP AND RUNNING!${COLOR_RESET}"
    print_separator
    echo ""
    
    local json_output
    json_output=$(get_json_output)
    
    echo -e "${COLOR_WHITE}${COLOR_BOLD}📋 Server Information:${COLOR_RESET}"
    echo ""
    echo "  ${COLOR_WHITE}Domain:${COLOR_RESET}      ${DOMAIN}"
    echo "  ${COLOR_WHITE}API Port:${COLOR_RESET}    ${API_PORT}"
    echo "  ${COLOR_WHITE}Keys Port:${COLOR_RESET}   ${KEYS_PORT}"
    echo "  ${COLOR_WHITE}Tunnel Port:${COLOR_RESET} ${TUNNEL_PORT}"
    echo "  ${COLOR_WHITE}TCP Path:${COLOR_RESET}    ${TCP_PATH}"
    echo "  ${COLOR_WHITE}UDP Path:${COLOR_RESET}    ${UDP_PATH}"
    echo ""
    
    echo -e "${COLOR_WHITE}${COLOR_BOLD}🔑 To manage your server, copy this line into Outline Manager:${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_GREEN}${COLOR_BOLD}${json_output}${COLOR_RESET}"
    echo ""
    
    echo -e "${COLOR_WHITE}${COLOR_BOLD}📁 Important Files:${COLOR_RESET}"
    echo "  ${COLOR_WHITE}Access Config:${COLOR_RESET}     ${ACCESS_CONFIG}"
    echo "  ${COLOR_WHITE}Server Config:${COLOR_RESET}     ${CONFIG_YAML}"
    echo "  ${COLOR_WHITE}Cloudflare Config:${COLOR_RESET} ${CLOUDFLARED_CONFIG}"
    echo "  ${COLOR_WHITE}Installation Log:${COLOR_RESET}  ${FULL_LOG}"
    echo ""
    
    echo -e "${COLOR_YELLOW}${COLOR_BOLD}⚠️  IMPORTANT NOTES:${COLOR_RESET}"
    echo ""
    echo "  ${COLOR_YELLOW}1.${COLOR_RESET} Firewall Rules: If using UFW, run these commands:"
    echo "     sudo ufw allow ${API_PORT}/tcp"
    echo "     sudo ufw allow ${KEYS_PORT}/tcp"
    echo "     sudo ufw allow ${KEYS_PORT}/udp"
    echo ""
    echo "  ${COLOR_YELLOW}2.${COLOR_RESET} Cloudflare Configuration:"
    echo "     - Ensure ${DOMAIN} is properly configured on Cloudflare"
    echo "     - SSL/TLS mode should be set to 'Full (strict)'"
    echo "     - Cloudflare Tunnel should be running:"
    echo "       systemctl status cloudflared-${TUNNEL_NAME}"
    echo ""
    echo "  ${COLOR_YELLOW}3.${COLOR_RESET} Security:"
    echo "     - The certificate is self-signed (valid for 100 years)"
    echo "     - Keep the access config file secure: ${ACCESS_CONFIG}"
    echo "     - Change the secret key periodically for better security"
    echo ""
    
    echo -e "${COLOR_GREEN}${COLOR_BOLD}🚀 NEXT STEPS:${COLOR_RESET}"
    echo ""
    echo "  1. ${COLOR_WHITE}Copy the JSON line above${COLOR_RESET}"
    echo "  2. ${COLOR_WHITE}Open Outline Manager${COLOR_RESET}"
    echo "  3. ${COLOR_WHITE}Click 'Add Server' > 'Enter server information manually'${COLOR_RESET}"
    echo "  4. ${COLOR_WHITE}Paste the JSON and click 'Done'${COLOR_RESET}"
    echo "  5. ${COLOR_WHITE}Create access keys and share them with users${COLOR_RESET}"
    echo ""
    
    print_separator
    echo ""
    
    log_success "Installation completed successfully!"
}

# =============================================================================
# MAIN INSTALLATION FUNCTION
# =============================================================================

function main() {
    # Print banner
    print_banner
    
    # Check root privileges
    check_root
    
    # Start installation
    log_info "Starting Outline Server installation..."
    log_info "Installation log: ${FULL_LOG}"
    echo ""
    
    # Get user input
    get_user_input
    
    # System checks
    log_info "=== System Verification ==="
    check_architecture
    check_os_support
    check_disk_space
    echo ""
    
    # Prerequisite checks
    log_info "=== Prerequisite Checks ==="
    run_step "Checking curl" check_curl
    run_step "Checking wget" check_wget
    run_step "Checking openssl" check_openssl
    run_step "Checking Docker" check_docker
    run_step "Checking Docker daemon" check_docker_running
    echo ""
    
    # Create directories
    log_info "=== Directory Setup ==="
    run_step "Creating Outline directories" sudo mkdir -p "${SHADOWBOX_DIR}" "${STATE_DIR}"
    run_step "Setting directory permissions" sudo chmod 700 "${SHADOWBOX_DIR}" && sudo chmod 700 "${STATE_DIR}"
    echo ""
    
    # Cloudflare Tunnel setup
    log_info "=== Cloudflare Tunnel Setup ==="
    run_step "Installing cloudflared" install_cloudflared
    run_step "Cloudflare authentication" check_cloudflare_auth
    run_step "Setting up Cloudflare Tunnel" setup_cloudflare_tunnel
    echo ""
    
    # Outline SS Server setup
    log_info "=== Outline SS Server Setup ==="
    run_step "Downloading outline-ss-server" install_outline_ss_server
    run_step "Configuring outline-ss-server" configure_outline_ss_server
    run_step "Starting outline-ss-server" start_outline_ss_server
    echo ""
    
    # Certificate and access key
    log_info "=== Access Key Generation ==="
    run_step "Generating SSL certificate" generate_certificate
    run_step "Generating access key" generate_access_key
    echo ""
    
    # Firewall check
    log_info "=== Firewall Configuration ==="
    check_firewall
    echo ""
    
    # Final output
    display_final_output
}

# =============================================================================
# SCRIPT EXECUTION - Direct call (no conditional check needed)
# =============================================================================

main "$@"
