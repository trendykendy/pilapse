#!/usr/bin/env bash
set -euo pipefail

# Timelapse Camera System Installer
# This script handles system-level setup (run once per Pi)

VERSION="1.0.0"
REPO_URL="https://raw.githubusercontent.com/trendykendy/pilapse/main"
INSTALL_DIR="/usr/local/bin"
USER_HOME="/home/admin"

# Remote config file URLs (encrypted versions)
GCLOUD_JSON_URL="${REPO_URL}/config/timelapsecamdriveauth-12192b48330a.json.gpg"
MSMTP_CONFIG_URL="${REPO_URL}/config/msmtprc.gpg"
TIMELAPSE_SCRIPT_URL="${REPO_URL}/timelapse.sh"

# Decryption password (will be prompted)
DECRYPT_PASSWORD=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

########################################
# LOGGING FUNCTIONS
########################################
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

########################################
# SYSTEM CHECKS
########################################
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

fix_terminal() {
    # If stdin is not a terminal (piped execution), try to reconnect to TTY
    if [[ ! -t 0 ]]; then
        if [[ -e /dev/tty ]]; then
            log_warning "Script is piped - reconnecting to terminal for interactive prompts..."
            exec < /dev/tty
            
            # Verify it worked
            if [[ ! -t 0 ]]; then
                log_error "Failed to reconnect to terminal"
                log_error "Please download and run directly:"
                log_error "  curl -fsSL https://raw.githubusercontent.com/trendykendy/pilapse/main/timelapse-installer.sh -o timelapse-installer.sh"
                log_error "  sudo bash timelapse-installer.sh"
                exit 1
            fi
        else
            log_error "This script requires an interactive terminal"
            log_error "Please download and run directly:"
            log_error "  curl -fsSL https://raw.githubusercontent.com/trendykendy/pilapse/main/timelapse-installer.sh -o timelapse-installer.sh"
            log_error "  sudo bash timelapse-installer.sh"
            exit 1
        fi
    fi
}

show_banner() {
    clear
    cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║     TIMELAPSE CAMERA SYSTEM INSTALLER                     ║
║     Version 1.0.0                                         ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF
    echo
}

check_requirements() {
    log_info "Checking system requirements..."
    
    # Check OS
    if ! grep -q "Raspbian\|Debian" /etc/os-release; then
        log_warning "This script is designed for Raspberry Pi OS/Debian"
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Check if running on Raspberry Pi (fix null byte warning)
    if [[ -f /proc/device-tree/model ]]; then
        PI_MODEL=$(tr -d '\0' < /proc/device-tree/model)
        log_info "Detected: $PI_MODEL"
    fi
    
    # Check internet connection
    if ! ping -c 1 google.com &> /dev/null; then
        log_error "No internet connection detected"
        log_info "Please configure WiFi first or connect ethernet"
        exit 1
    fi
    
    log_success "System requirements met"
}

########################################
# DEPENDENCY INSTALLATION
########################################
install_dependencies() {
    echo
    log_info "═══════════════════════════════════════════════════════"
    log_info "  INSTALLING DEPENDENCIES"
    log_info "═══════════════════════════════════════════════════════"
    echo
    
    # Pre-configure msmtp to disable AppArmor prompt
    log_info "Pre-configuring package options..."
    echo "msmtp msmtp/apparmor boolean false" | debconf-set-selections
    echo
    
    log_info "Updating package lists..."
    echo
    apt-get update
    echo
    
    local packages=(
        "gphoto2"
        "imagemagick"
        "rclone"
        "msmtp"
        "msmtp-mta"
        "curl"
        "jq"
        "bc"
    )
    
    local total=${#packages[@]}
    local current=0
    
    log_info "Installing ${total} packages..."
    echo
    
    for package in "${packages[@]}"; do
        current=$((current + 1))
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "${CYAN}[$current/$total]${NC} Installing: ${YELLOW}$package${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo
        
        if dpkg -l 2>/dev/null | grep -q "^ii  $package "; then
            echo -e "  ${GREEN}✓${NC} $package is already installed"
            echo
        else
            # Install with live output, non-interactive
            if DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"; then
                echo
                echo -e "  ${GREEN}✓${NC} $package installed successfully"
                echo
            else
                echo
                echo -e "  ${RED}✗${NC} Failed to install $package"
                log_error "Installation failed for $package"
                read -p "Continue anyway? (y/n): " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    exit 1
                fi
            fi
        fi
    done
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "All dependencies installed"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

########################################
# WIFI CONFIGURATION
########################################
configure_wifi() {
    echo
    log_info "═══════════════════════════════════════════════════════"
    log_info "  WIFI CONFIGURATION"
    log_info "═══════════════════════════════════════════════════════"
    echo
    
    # Check if wpa_supplicant.conf exists
    WPA_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"
    
    if [[ ! -f "$WPA_CONF" ]]; then
        # Create basic wpa_supplicant.conf if it doesn't exist
        cat > "$WPA_CONF" <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=IE

EOF
        log_info "Created new wpa_supplicant.conf"
    fi
    
    # Show current connection status (informational only)
    echo "Current network status:"
    if command -v iwgetid &> /dev/null; then
        current_ssid=$(iwgetid -r 2>/dev/null || echo "")
        if [[ -n "$current_ssid" ]]; then
            echo -e "  ${GREEN}✓${NC} Currently connected to WiFi: $current_ssid"
            ip addr show wlan0 2>/dev/null | grep "inet " | awk '{print "  IP Address: " $2}' || true
        else
            # Check if wired connection exists
            if ip addr show eth0 2>/dev/null | grep -q "state UP"; then
                echo -e "  ${GREEN}✓${NC} Connected via Ethernet"
                ip addr show eth0 | grep "inet " | awk '{print "  IP Address: " $2}'
            else
                echo -e "  ${YELLOW}⚠${NC} Not currently connected to any network"
            fi
        fi
    fi
    echo
    
    # Show currently configured WiFi networks
    echo "WiFi networks configured in wpa_supplicant.conf:"
    if grep -q "^[[:space:]]*network=" "$WPA_CONF" 2>/dev/null; then
        grep "ssid=" "$WPA_CONF" | sed 's/.*ssid="\(.*\)".*/  - \1/'
    else
        echo "  (none configured yet)"
    fi
    echo
    
    log_info "You can configure WiFi networks that the Pi will connect to"
    log_info "when available (useful for multiple locations/job sites)"
    echo
    
    read -p "Configure WiFi networks? (y/n): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Skipping WiFi configuration"
        return 0
    fi
    
    # Add networks
    while true; do
        echo
        read -rp "WiFi SSID (or press Enter to finish): " wifi_ssid
        
        if [[ -z "$wifi_ssid" ]]; then
            break
        fi
        
        # Check if this SSID already exists
        if grep -q "ssid=\"$wifi_ssid\"" "$WPA_CONF" 2>/dev/null; then
            log_warning "Network '$wifi_ssid' is already configured"
            read -p "Reconfigure it? (y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                continue
            fi
            # Remove existing entry
            awk '/network=\{/,/\}/ {if (/ssid="'"$wifi_ssid"'"/) {skip=1} if (skip && /\}/) {skip=0; next} if (!skip) print; next} 1' "$WPA_CONF" > "$WPA_CONF.tmp"
            mv "$WPA_CONF.tmp" "$WPA_CONF"
        fi
        
        read -rsp "WiFi Password: " wifi_password
        echo
        
        if [[ -z "$wifi_password" ]]; then
            log_error "Password cannot be empty"
            continue
        fi
        
        # Generate PSK using wpa_passphrase
        log_info "Adding network: $wifi_ssid"
        wpa_passphrase "$wifi_ssid" "$wifi_password" >> "$WPA_CONF"
        echo -e "  ${GREEN}✓${NC} Added: $wifi_ssid"
        
        echo
        read -p "Add another WiFi network? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            break
        fi
    done
    
    # Show summary of all configured networks
    echo
    echo "All WiFi networks now configured:"
    grep "ssid=" "$WPA_CONF" | sed 's/.*ssid="\(.*\)".*/  - \1/'
    echo
    
    # Reconfigure WiFi (only if wlan0 exists)
    if ip link show wlan0 &> /dev/null; then
        log_info "Applying WiFi configuration..."
        wpa_cli -i wlan0 reconfigure > /dev/null 2>&1 || true
        echo -e "  ${GREEN}✓${NC} WiFi configuration applied"
        
        echo
        log_info "The Pi will automatically connect to any configured network"
        log_info "when it's in range. No need to be connected now."
        
        # Give it a moment and show status
        sleep 3
        echo
        echo "Current WiFi status:"
        current_ssid=$(iwgetid -r 2>/dev/null || echo "")
        if [[ -n "$current_ssid" ]]; then
            echo -e "  ${GREEN}✓${NC} Connected to: $current_ssid"
            ip addr show wlan0 2>/dev/null | grep "inet " | awk '{print "  IP Address: " $2}' || true
        else
            echo -e "  ${YELLOW}⚠${NC} Not connected to WiFi right now"
            echo "  (Will connect automatically when in range of a configured network)"
        fi
    else
        log_warning "No WiFi interface (wlan0) detected"
        log_info "WiFi networks saved - will be used when WiFi hardware is available"
    fi
    
    echo
    return 0
}

########################################
# DIRECTORY CREATION
########################################
create_directories() {
    echo
    log_info "═══════════════════════════════════════════════════════"
    log_info "  CREATING DIRECTORY STRUCTURE"
    log_info "═══════════════════════════════════════════════════════"
    echo
    
    local dirs=(
        "$USER_HOME/photos"
        "$USER_HOME/backups"
        "$USER_HOME/thumbnails"
        "$USER_HOME/archive"
        "$USER_HOME/logs"
        "/mnt/BackupArchive"
        "/root/.config/rclone"
    )
    
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        echo -e "  ${GREEN}✓${NC} Created: $dir"
    done
    
    # Set ownership for user directories
    chown -R admin:admin "$USER_HOME/photos" "$USER_HOME/backups" \
        "$USER_HOME/thumbnails" "$USER_HOME/archive" "$USER_HOME/logs" 2>/dev/null || true
    
    echo
    log_success "Directory structure created"
}

########################################
# CONFIG FILE INSTALLATION
########################################
prompt_decrypt_password() {
    if [[ -z "$DECRYPT_PASSWORD" ]]; then
        echo
        log_info "Configuration files are encrypted for security"
        log_info "You need the decryption password to continue"
        log_info "(This password will be used for both Google Drive and email config)"
        echo
        
        read -sp "Enter decryption password: " DECRYPT_PASSWORD || {
            echo
            log_error "Failed to read password input"
            log_error "Make sure you're running this in an interactive terminal"
            exit 1
        }
        echo  # Newline after password entry
        
        if [[ -z "$DECRYPT_PASSWORD" ]]; then
            log_error "Password cannot be empty"
            exit 1
        fi
    fi
}


########################################
# RASPBERRY PI CONNECT
########################################
install_rpi_connect() {
    echo
    log_info "═══════════════════════════════════════════════════════"
    log_info "  RASPBERRY PI CONNECT (REMOTE ACCESS)"
    log_info "═══════════════════════════════════════════════════════"
    echo
    
    log_info "Raspberry Pi Connect Lite provides remote shell access"
    log_info "to your Pi from anywhere via connect.raspberrypi.com"
    echo
    
    read -p "Install Raspberry Pi Connect Lite? (y/n): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Skipping Raspberry Pi Connect installation"
        return 0
    fi
    
    # Get the actual user (not root)
    ACTUAL_USER="${SUDO_USER:-admin}"
    
    # Check if already installed
    if command -v rpi-connect &> /dev/null; then
        log_warning "rpi-connect is already installed"
        log_info "You can manage it with: rpi-connect on/off/signin"
        return 0
    fi
    
    # Install Raspberry Pi Connect Lite
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${CYAN}Installing rpi-connect-lite package${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    
    if DEBIAN_FRONTEND=noninteractive apt-get install -y rpi-connect-lite; then
        echo
        echo -e "  ${GREEN}✓${NC} rpi-connect-lite package installed"
    else
        echo
        echo -e "  ${RED}✗${NC} Failed to install rpi-connect-lite"
        log_info "You can install it manually later with: sudo apt install rpi-connect-lite"
        return 0
    fi
    
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Enable user lingering (so remote shell works when not logged in)
    log_info "Enabling user lingering for $ACTUAL_USER..."
    if loginctl enable-linger "$ACTUAL_USER" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} User lingering enabled"
    else
        echo -e "  ${YELLOW}⚠${NC} Failed to enable user lingering"
    fi
    
    echo
    log_success "Raspberry Pi Connect Lite installed"
    echo
    
    log_info "IMPORTANT: rpi-connect must be started as a regular user"
    log_info "After this installer completes, log in as $ACTUAL_USER and run:"
    echo
    echo -e "  ${YELLOW}rpi-connect on${NC}       # Start the service"
    echo -e "  ${YELLOW}rpi-connect signin${NC}   # Link with your Raspberry Pi ID"
    echo
    log_info "Then access your Pi at: https://connect.raspberrypi.com"
    echo
    
    return 0
}

download_and_decrypt() {
    local url="$1"
    local output_file="$2"
    local temp_encrypted=$(mktemp)
    
    log_info "Downloading encrypted file..."
    
    # Download encrypted file
    if curl -fsSL "$url" -o "$temp_encrypted"; then
        echo -e "  ${GREEN}✓${NC} Downloaded encrypted file"
    else
        echo -e "  ${RED}✗${NC} Failed to download from: $url"
        rm -f "$temp_encrypted"
        return 1
    fi
    
    # Check if file is encrypted (GPG or PGP)
    local file_type=$(file "$temp_encrypted" 2>/dev/null)
    if ! echo "$file_type" | grep -qE "GPG|PGP|encrypted"; then
        log_error "Downloaded file does not appear to be encrypted"
        log_error "File type: $file_type"
        rm -f "$temp_encrypted"
        return 1
    fi
    
    # Decrypt file
    log_info "Decrypting file..."
    if echo "$DECRYPT_PASSWORD" | gpg --decrypt --batch --yes \
        --passphrase-fd 0 "$temp_encrypted" > "$output_file" 2>/tmp/gpg-error.log; then
        rm -f "$temp_encrypted"
        echo -e "  ${GREEN}✓${NC} Decrypted successfully"
        return 0
    else
        echo -e "  ${RED}✗${NC} Decryption failed"
        local gpg_error=$(cat /tmp/gpg-error.log 2>/dev/null || echo 'Unknown error')
        log_error "GPG error: $gpg_error"
        log_error "Possible causes:"
        log_error "  - Incorrect password"
        log_error "  - File is corrupted"
        log_error "  - Wrong encryption method"
        rm -f "$temp_encrypted" "$output_file" /tmp/gpg-error.log
        return 1
    fi
}


install_gcloud_json() {
    log_info "Installing Google Cloud service account credentials..."
    echo
    
    local json_dest="$USER_HOME/timelapsecamdriveauth-12192b48330a.json"
    
    # Prompt for password if not already set
    prompt_decrypt_password
    
    # Download and decrypt from remote
    if download_and_decrypt "$GCLOUD_JSON_URL" "$json_dest"; then
        # Verify it's valid JSON
        if jq empty "$json_dest" 2>/dev/null; then
            chmod 644 "$json_dest"
            chown admin:admin "$json_dest" 2>/dev/null || true
            echo
            log_success "Service account JSON installed"
            
            # Show service account email
            local sa_email=$(jq -r '.client_email' "$json_dest" 2>/dev/null || echo "unknown")
            log_info "Service account email: $sa_email"
            echo
            log_warning "Make sure this email has access to your Google Drive folder!"
            echo
            
            echo "$json_dest"
            return 0
        else
            echo
            log_error "Decrypted file is not valid JSON"
            log_error "File contents:"
            head -n 5 "$json_dest" 2>/dev/null || echo "(unable to read file)"
            rm -f "$json_dest"
            return 1
        fi
    else
        echo
        log_error "Could not download/decrypt service account JSON"
        log_error "URL: $GCLOUD_JSON_URL"
        log_error "Please check:"
        log_error "  1. The file exists at the URL above"
        log_error "  2. The decryption password is correct"
        log_error "  3. You have internet connectivity"
        
        # Test if we can reach the URL
        if curl -fsSL --head "$GCLOUD_JSON_URL" &> /dev/null; then
            log_info "✓ URL is reachable"
        else
            log_error "✗ Cannot reach URL - check your internet connection"
        fi
        
        return 1
    fi
}
configure_rclone() {
    echo
    log_info "═══════════════════════════════════════════════════════"
    log_info "  GOOGLE DRIVE CONFIGURATION"
    log_info "═══════════════════════════════════════════════════════"
    echo
    
    if [[ -f "/root/.config/rclone/rclone.conf" ]]; then
        log_warning "rclone configuration already exists"
        read -p "Reconfigure rclone? (y/n): " -n 1 -r || {
            echo
            log_info "Using existing rclone configuration"
            return 0
        }
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            # Test existing config
            if rclone listremotes 2>/dev/null | grep -q "aperturetimelapsedrive"; then
                log_success "Using existing rclone configuration"
                return 0
            fi
        fi
    fi
    
    # Install JSON file (will auto-download and decrypt)
    if ! json_path=$(install_gcloud_json); then
        log_error "Failed to install service account JSON"
        echo
        log_info "Skipping rclone configuration"
        log_info "You can configure manually later with: sudo rclone config"
        echo
        return 0  # Don't fail the entire installation
    fi
    
    if [[ -z "$json_path" ]] || [[ ! -f "$json_path" ]]; then
        log_error "Service account JSON file not found at: $json_path"
        log_info "Skipping rclone configuration"
        return 0
    fi
    
    # Create rclone config automatically
    log_info "Creating rclone configuration..."
    cat > /root/.config/rclone/rclone.conf << EOF
[aperturetimelapsedrive]
type = drive
scope = drive
service_account_file = $json_path
team_drive = 
EOF
    
    chmod 600 /root/.config/rclone/rclone.conf
    echo -e "  ${GREEN}✓${NC} rclone configuration created"
    
    # Test connection
    echo
    log_info "Testing Google Drive connection..."
    if timeout 10 rclone lsd aperturetimelapsedrive: > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} Google Drive connection successful"
        log_info "Remote name: aperturetimelapsedrive"
        echo
        log_success "Google Drive configured successfully"
    else
        echo -e "  ${RED}✗${NC} Google Drive connection failed"
        echo
        log_warning "Connection test failed. This could mean:"
        log_warning "  1. The service account JSON is incorrect"
        log_warning "  2. The Drive folder hasn't been shared with the service account"
        log_warning "  3. Network connectivity issues"
        echo
        
        local sa_email=$(jq -r '.client_email' "$json_path" 2>/dev/null || echo 'unknown')
        log_info "Service account email: $sa_email"
        log_info "Make sure you've shared your Google Drive folder with this email!"
        echo
        
        read -p "Continue anyway? (y/n): " -n 1 -r || {
            echo
            log_info "Continuing installation..."
            return 0
        }
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "You can reconfigure later with: sudo rclone config"
            return 0
        fi
    fi
    
    return 0
}


install_msmtp_config() {
    log_info "Installing email (msmtp) configuration..."
    echo
    
    local msmtprc_dest="/root/.msmtprc"
    
    # Prompt for password if not already set
    prompt_decrypt_password
    
    # Try to download and decrypt from remote
    if download_and_decrypt "$MSMTP_CONFIG_URL" "$msmtprc_dest"; then
        chmod 600 "$msmtprc_dest"
        echo
        log_success "msmtp configuration installed"
        
        # Show configured email
        local from_email=$(grep "^from" "$msmtprc_dest" | awk '{print $2}')
        log_info "Email configured: $from_email"
        
        return 0
    else
        log_warning "Could not download/decrypt msmtp config from remote"
        return 1
    fi
}

configure_email() {
    echo
    log_info "═══════════════════════════════════════════════════════"
    log_info "  EMAIL CONFIGURATION"
    log_info "═══════════════════════════════════════════════════════"
    echo
    
    if [[ -f "/root/.msmtprc" ]]; then
        log_warning "msmtp configuration already exists"
        read -p "Reconfigure email? (y/n): " -n 1 -r || {
            echo
            log_success "Using existing msmtp configuration"
            return 0
        }
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_success "Using existing msmtp configuration"
            return 0
        fi
    fi
    
    # Try to install from remote first
    if install_msmtp_config; then
        # Test the configuration
        log_info "Testing email configuration..."
        read -p "Send test email? (y/n): " -n 1 -r || {
            echo
            return 0
        }
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            read -p "Test email recipient: " test_recipient || {
                log_info "Skipping test email"
                return 0
            }
            
            if echo -e "Subject: Timelapse Installer Test\n\nThis is a test email from the timelapse installer.\n\nIf you received this, email is configured correctly." | msmtp "$test_recipient" 2>/dev/null; then
                log_success "Test email sent successfully"
                log_info "Check spam folder if not received"
            else
                log_warning "Test email may have failed"
                log_info "Check /root/.msmtp.log for details"
            fi
        fi
        return 0
    else
        log_error "Failed to install email configuration"
        log_info "Skipping email configuration"
        log_info "You can configure manually later"
        return 0
    fi
}

########################################
# SCRIPT INSTALLATION
########################################
download_timelapse_script() {
    echo
    log_info "═══════════════════════════════════════════════════════"
    log_info "  TIMELAPSE SCRIPT INSTALLATION"
    log_info "═══════════════════════════════════════════════════════"
    echo
    
    if curl -fsSL "$TIMELAPSE_SCRIPT_URL" -o "$INSTALL_DIR/timelapse"; then
        chmod +x "$INSTALL_DIR/timelapse"
        echo -e "  ${GREEN}✓${NC} Timelapse script installed"
        log_info "Location: $INSTALL_DIR/timelapse"
    else
        echo -e "  ${RED}✗${NC} Failed to download timelapse script"
        log_info "You can manually place timelapse.sh at $INSTALL_DIR/timelapse"
        read -p "Do you have the script locally? (y/n): " -n 1 -r || {
            echo
            return 1
        }
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            read -p "Enter path to timelapse.sh: " script_path || return 1
            if [[ -f "$script_path" ]]; then
                cp "$script_path" "$INSTALL_DIR/timelapse"
                chmod +x "$INSTALL_DIR/timelapse"
                log_success "Script installed from local path"
            else
                log_error "File not found: $script_path"
                return 1
            fi
        else
            return 1
        fi
    fi
}

########################################
# CAMERA TEST
########################################
test_camera() {
    echo
    log_info "═══════════════════════════════════════════════════════"
    log_info "  CAMERA CONNECTION TEST"
    log_info "═══════════════════════════════════════════════════════"
    echo
    
    read -p "Test camera connection? (y/n): " -n 1 -r || {
        echo
        log_info "Skipping camera test"
        return 0
    }
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Skipping camera test"
        return 0
    fi
    
    if timeout 10 gphoto2 --auto-detect 2>/dev/null | grep -q "usb:"; then
        echo -e "  ${GREEN}✓${NC} Camera detected"
        gphoto2 --auto-detect | grep "usb:"
    else
        echo -e "  ${YELLOW}⚠${NC} No camera detected"
        log_info "Make sure your camera is:"
        log_info "  - Connected via USB"
        log_info "  - Powered on"
        log_info "  - In the correct mode (not in mass storage mode)"
    fi
}

########################################
# UNINSTALL SCRIPT
########################################
create_uninstall_script() {
    echo
    log_info "Creating uninstall script..."
    
    cat > "$INSTALL_DIR/timelapse-uninstall" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "This will remove the timelapse system."
read -p "Are you sure? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo "Uninstall cancelled"
    exit 0
fi

echo "Removing timelapse system..."

# Remove cron jobs
rm -f /etc/cron.d/timelapse

# Remove scripts
rm -f /usr/local/bin/timelapse
rm -f /usr/local/bin/timelapse-uninstall

# Remove config
rm -f /etc/timelapse.conf

echo "Timelapse system removed."
echo "Note: User data in /home/admin (photos, backups, etc.) was NOT removed."
echo "Note: Raspberry Pi Connect, rclone, and msmtp configs were NOT removed."
echo "Remove manually if needed:"
echo "  rm -rf /home/admin/{photos,backups,thumbnails,archive,logs}"
echo "  rm /root/.config/rclone/rclone.conf"
echo "  rm /root/.msmtprc"
EOF
    
    chmod +x "$INSTALL_DIR/timelapse-uninstall"
    log_success "Uninstall script created at $INSTALL_DIR/timelapse-uninstall"
}

########################################
# SUMMARY
########################################
show_summary() {
    echo
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                                                           ║"
    echo "║     INSTALLATION COMPLETE!                                ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo
    log_success "System-level installation completed successfully"
    echo
    
    # Show Raspberry Pi Connect status
    if command -v rpi-connect &> /dev/null; then
        echo "Remote Access:"
        if systemctl is-active --quiet rpi-connect; then
            echo "  ${GREEN}✓${NC} Raspberry Pi Connect is running"
            echo "  🌐 Access at: https://connect.raspberrypi.com"
            
            # Check lingering
            ACTUAL_USER="${SUDO_USER:-admin}"
            if loginctl show-user "$ACTUAL_USER" 2>/dev/null | grep -q "Linger=yes"; then
                echo "  ${GREEN}✓${NC} Remote shell enabled (works when logged out)"
            fi
        fi
        echo
    fi
    
    echo "What was installed:"
    echo "  ${GREEN}✓${NC} System dependencies (gphoto2, rclone, msmtp, etc.)"
    echo "  ${GREEN}✓${NC} WiFi networks configured"
    echo "  ${GREEN}✓${NC} Raspberry Pi Connect (remote access)"
    echo "  ${GREEN}✓${NC} Google Drive connection (rclone)"
    echo "  ${GREEN}✓${NC} Email configuration (msmtp)"
    echo "  ${GREEN}✓${NC} Timelapse script (/usr/local/bin/timelapse)"
    echo "  ${GREEN}✓${NC} Directory structure"
    echo
    echo "${CYAN}NEXT STEP - Configure your project:${NC}"
    echo "  ${YELLOW}sudo timelapse setup${NC}"
    echo
    echo "This will configure:"
    echo "  - USB backup drive"
    echo "  - Project name"
    echo "  - Capture schedule"
    echo "  - End-of-day tasks"
    echo
    echo "Useful commands:"
    echo "  timelapse setup          - Configure project"
    echo "  timelapse add-wifi       - Add WiFi network"
    echo "  timelapse test-camera    - Test camera"
    echo "  timelapse test-all       - Run all tests"
    echo "  timelapse status         - Show status"
    echo
    echo "To uninstall: sudo timelapse-uninstall"
    echo
}

########################################
# MAIN INSTALLATION FLOW
########################################
main() {
    show_banner
    check_root
    fix_terminal
    check_requirements
    
    echo
    log_info "Starting system installation..."
    echo
    
    # System-level installation steps
    install_dependencies
    configure_wifi
    install_rpi_connect
    create_directories
    configure_rclone
    configure_email
    download_timelapse_script
    test_camera
    create_uninstall_script
    
    show_summary
}

# Run main function
main "$@"
