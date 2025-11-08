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
    
    # Install NetworkManager if not present
    if ! command -v nmcli &> /dev/null; then
        log_info "Installing NetworkManager..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y network-manager
        echo -e "  ${GREEN}✓${NC} NetworkManager installed"
    else
        log_info "NetworkManager already installed"
    fi
    
    # Fix NetworkManager configuration to manage all interfaces
    log_info "Configuring NetworkManager..."
    
    if [[ -f /etc/NetworkManager/NetworkManager.conf ]]; then
        # Update managed=false to managed=true in [ifupdown] section
        if grep -q "^\[ifupdown\]" /etc/NetworkManager/NetworkManager.conf; then
            sed -i '/^\[ifupdown\]/,/^\[/ s/managed=false/managed=true/' /etc/NetworkManager/NetworkManager.conf
            echo -e "  ${GREEN}✓${NC} Set NetworkManager to manage all interfaces"
        fi
    fi
    
    # Disable conflicting services
    log_info "Disabling conflicting services..."
    systemctl disable dhcpcd 2>/dev/null || true
    systemctl stop dhcpcd 2>/dev/null || true
    systemctl disable wpa_supplicant 2>/dev/null || true
    systemctl stop wpa_supplicant 2>/dev/null || true
    killall wpa_supplicant 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Conflicting services disabled"
    
    # Enable and start NetworkManager
    systemctl enable NetworkManager 2>/dev/null || true
    systemctl restart NetworkManager
    sleep 3
    echo -e "  ${GREEN}✓${NC} NetworkManager enabled and started"
    
    # Make sure wlan0 is managed
    if ip link show wlan0 &> /dev/null; then
        nmcli device set wlan0 managed yes 2>/dev/null || true
        ip link set wlan0 up 2>/dev/null || true
        nmcli radio wifi on 2>/dev/null || true
        sleep 2
    fi
    
    # Show current connection status
    echo
    echo "Current network status:"
    
    # Check Ethernet
    if nmcli device status | grep -q "^eth0.*connected"; then
        echo -e "  ${GREEN}✓${NC} Connected via Ethernet"
        nmcli -t -f DEVICE,IP4.ADDRESS device show eth0 2>/dev/null | grep IP4.ADDRESS | cut -d: -f2 | sed 's/^/  IP Address: /' || true
    fi
    
    # Check WiFi
    current_wifi=$(nmcli -t -f ACTIVE,SSID dev wifi | grep '^yes' | cut -d: -f2)
    if [[ -n "$current_wifi" ]]; then
        echo -e "  ${GREEN}✓${NC} Connected to WiFi: $current_wifi"
        nmcli -t -f DEVICE,IP4.ADDRESS device show wlan0 2>/dev/null | grep IP4.ADDRESS | cut -d: -f2 | sed 's/^/  IP Address: /' || true
    fi
    
    # Show configured WiFi networks
    echo
    echo "WiFi networks already configured:"
    if nmcli -t -f NAME,TYPE connection show | grep -q ":802-11-wireless$"; then
        nmcli -t -f NAME,TYPE connection show | grep ":802-11-wireless$" | cut -d: -f1 | sed 's/^/  - /'
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
    
    # Scan for available networks
    if ip link show wlan0 &> /dev/null; then
        log_info "Scanning for WiFi networks..."
        nmcli device wifi rescan 2>/dev/null || true
        sleep 3
        
        echo
        echo "Available networks (showing top 10):"
        nmcli -t -f SSID,SIGNAL,SECURITY device wifi list 2>/dev/null | grep -v "^::" | sort -t: -k2 -rn | head -10 | while IFS=: read -r ssid signal security; do
            if [[ -n "$ssid" ]]; then
                printf "  - %-30s (Signal: %3s%%, Security: %s)\n" "$ssid" "$signal" "$security"
            fi
        done
        echo
    fi
    
    # Add networks
    while true; do
        echo
        read -rp "WiFi SSID (or press Enter to finish): " wifi_ssid
        
        if [[ -z "$wifi_ssid" ]]; then
            break
        fi
        
        # Password input with validation
        local password_valid=false
        local wifi_password=""
        
        while [[ "$password_valid" == false ]]; do
            read -rsp "WiFi Password: " wifi_password
            echo
            
            if [[ -z "$wifi_password" ]]; then
                log_error "Password cannot be empty"
                continue
            fi
            
            # Check password length (WPA requires 8-63 characters)
            local pass_length=${#wifi_password}
            if [[ $pass_length -lt 8 ]]; then
                log_error "Password too short (minimum 8 characters, you entered $pass_length)"
                continue
            elif [[ $pass_length -gt 63 ]]; then
                log_error "Password too long (maximum 63 characters, you entered $pass_length)"
                continue
            fi
            
            # Password is valid
            password_valid=true
        done
        
        # Try to connect with NetworkManager
        log_info "Adding network: $wifi_ssid"
        
        if nmcli device wifi connect "$wifi_ssid" password "$wifi_password" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Connected to: $wifi_ssid"
            # Show IP address
            sleep 2
            nmcli -t -f DEVICE,IP4.ADDRESS device show wlan0 2>/dev/null | grep IP4.ADDRESS | cut -d: -f2 | sed 's/^/  IP Address: /' || true
        else
            # Network might not be in range, but it's saved for later
            log_warning "Could not connect to $wifi_ssid (may not be in range)"
            
            # Try to add it as a saved connection anyway
            if nmcli connection add type wifi con-name "$wifi_ssid" ifname wlan0 ssid "$wifi_ssid" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$wifi_password" 2>/dev/null; then
                echo -e "  ${YELLOW}⚠${NC} Saved for later: $wifi_ssid"
            else
                log_error "Failed to save network: $wifi_ssid"
            fi
        fi
        
        echo
        read -p "Add another WiFi network? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            break
        fi
    done
    
    # Show summary
    echo
    echo "All configured WiFi networks:"
    if nmcli -t -f NAME,TYPE connection show | grep -q ":802-11-wireless$"; then
        nmcli -t -f NAME,TYPE connection show | grep ":802-11-wireless$" | cut -d: -f1 | sed 's/^/  - /'
    else
        echo "  (none)"
    fi
    
    # Show current connection
    echo
    current_wifi=$(nmcli -t -f ACTIVE,SSID dev wifi | grep '^yes' | cut -d: -f2)
    if [[ -n "$current_wifi" ]]; then
        echo -e "${GREEN}✓${NC} Currently connected to: $current_wifi"
        nmcli -t -f DEVICE,IP4.ADDRESS device show wlan0 2>/dev/null | grep IP4.ADDRESS | cut -d: -f2 | sed 's/^/  IP Address: /' || true
    else
        echo -e "${YELLOW}⚠${NC} Not currently connected to WiFi"
        echo "  Will auto-connect when in range of a configured network"
    fi
    
    echo
    log_success "WiFi configuration complete"
    log_info "NetworkManager will automatically connect to saved networks"
    echo
}



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
        "/var/lib/timelapse"  
    )
    
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        echo -e "  ${GREEN}✓${NC} Created: $dir"
    done
    
    # Set ownership for user directories
    chown -R admin:admin "$USER_HOME/photos" "$USER_HOME/backups" \
        "$USER_HOME/thumbnails" "$USER_HOME/archive" "$USER_HOME/logs" 2>/dev/null || true
    
    # Initialize counter file
    if [[ ! -f "/var/lib/timelapse/counter.txt" ]]; then
        echo "00001" > /var/lib/timelapse/counter.txt
        chmod 644 /var/lib/timelapse/counter.txt
    fi
    
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
        
        local attempts=0
        local max_attempts=3
        
        while [[ $attempts -lt $max_attempts ]]; do
            read -sp "Enter decryption password: " DECRYPT_PASSWORD || {
                echo
                log_error "Failed to read password input"
                exit 1
            }
            echo  # Newline after password entry
            
            if [[ -z "$DECRYPT_PASSWORD" ]]; then
                log_error "Password cannot be empty"
                attempts=$((attempts + 1))
                if [[ $attempts -lt $max_attempts ]]; then
                    log_info "Try again ($((max_attempts - attempts)) attempts remaining)"
                fi
                DECRYPT_PASSWORD=""
                continue
            fi
            
            # Password entered, will be validated when actually used
            return 0
        done
        
        log_error "Maximum password attempts reached"
        exit 1
    fi
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
    
    # Decrypt file with retry logic
    log_info "Decrypting file..."
    local decrypt_attempts=0
    local max_decrypt_attempts=3
    
    while [[ $decrypt_attempts -lt $max_decrypt_attempts ]]; do
        if echo "$DECRYPT_PASSWORD" | gpg --decrypt --batch --yes \
            --passphrase-fd 0 "$temp_encrypted" > "$output_file" 2>/tmp/gpg-error.log; then
            rm -f "$temp_encrypted" /tmp/gpg-error.log
            echo -e "  ${GREEN}✓${NC} Decrypted successfully"
            return 0
        else
            decrypt_attempts=$((decrypt_attempts + 1))
            
            if [[ $decrypt_attempts -lt $max_decrypt_attempts ]]; then
                echo -e "  ${RED}✗${NC} Decryption failed"
                local gpg_error=$(cat /tmp/gpg-error.log 2>/dev/null | grep -i "bad\|failed\|error" | head -1)
                log_warning "Error: $gpg_error"
                log_info "Try again ($((max_decrypt_attempts - decrypt_attempts)) attempts remaining)"
                
                # Clear the old password and prompt for new one
                DECRYPT_PASSWORD=""
                read -sp "Enter decryption password: " DECRYPT_PASSWORD
                echo
                
                if [[ -z "$DECRYPT_PASSWORD" ]]; then
                    log_error "Password cannot be empty"
                    continue
                fi
            fi
        fi
    done
    
    # All attempts failed
    echo -e "  ${RED}✗${NC} Decryption failed after $max_decrypt_attempts attempts"
    local gpg_error=$(cat /tmp/gpg-error.log 2>/dev/null || echo 'Unknown error')
    log_error "GPG error: $gpg_error"
    log_error "Possible causes:"
    log_error "  - Incorrect password"
    log_error "  - File is corrupted"
    log_error "  - Wrong encryption method"
    rm -f "$temp_encrypted" "$output_file" /tmp/gpg-error.log
    return 1
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
            
            # Don't echo the path - just return success
            return 0
        else
            echo
            log_error "Decrypted file is not valid JSON"
            log_error "File contents (first 5 lines):"
            head -n 5 "$json_dest" 2>/dev/null || echo "(unable to read file)"
            rm -f "$json_dest"
            return 1
        fi
    else
        echo
        log_error "Could not download/decrypt service account JSON"
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
    install_gcloud_json
    local install_result=$?
    
    # The function already printed the path, so we know where it is
    local json_path="$USER_HOME/timelapsecamdriveauth-12192b48330a.json"
    
    if [[ $install_result -ne 0 ]] || [[ ! -f "$json_path" ]]; then
        log_error "Failed to install service account JSON"
        echo
        log_info "Skipping rclone configuration"
        log_info "You can configure manually later with: sudo rclone config"
        echo
        return 0
    fi
    
    # Prompt for Shared Drive ID with default
    echo
    log_info "SHARED DRIVE CONFIGURATION"
    log_info "Service accounts require a Shared Drive (Team Drive)"
    echo
    
    local default_team_drive="0AG_E72sodQBVUk9PVA"
    local team_drive_id=""
    
    read -p "Enter Shared Drive ID (press Enter for default): " team_drive_id
    
    # Use default if empty
    if [[ -z "$team_drive_id" ]]; then
        team_drive_id="$default_team_drive"
        log_info "Using default Shared Drive ID: $team_drive_id"
    fi
    
    # Create rclone config automatically
    log_info "Creating rclone configuration..."
    cat > /root/.config/rclone/rclone.conf << EOF
[aperturetimelapsedrive]
type = drive
scope = drive
service_account_file = $json_path
team_drive = $team_drive_id
EOF
    
    chmod 600 /root/.config/rclone/rclone.conf
    echo -e "  ${GREEN}✓${NC} rclone configuration created"
    
    # Test connection
    echo
    log_info "Testing Google Drive connection..."
    if timeout 10 rclone lsd aperturetimelapsedrive: > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} Google Drive connection successful"
        log_info "Remote name: aperturetimelapsedrive"
        log_info "Shared Drive ID: $team_drive_id"
        echo
        log_success "Google Drive configured successfully"
    else
        echo -e "  ${RED}✗${NC} Google Drive connection failed"
        echo
        log_warning "Connection test failed. This could mean:"
        log_warning "  1. The service account JSON is incorrect"
        log_warning "  2. The Shared Drive ID is incorrect"
        log_warning "  3. The service account hasn't been added to the Shared Drive"
        log_warning "  4. Network connectivity issues"
        echo
        
        local sa_email=$(jq -r '.client_email' "$json_path" 2>/dev/null || echo 'unknown')
        log_info "Service account email: $sa_email"
        echo
        log_warning "IMPORTANT: Add this email to your Shared Drive:"
        log_warning "  1. Go to drive.google.com and open 'Shared drives'"
        log_warning "  2. Click on your Shared Drive"
        log_warning "  3. Click 'Manage members'"
        log_warning "  4. Add: $sa_email"
        log_warning "  5. Give it 'Content manager' or 'Manager' permissions"
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
    
    # Show WiFi status
    if ip link show wlan0 &> /dev/null; then
        echo "WiFi Status:"
        current_ssid=$(iwgetid -r 2>/dev/null || echo "")
        if [[ -n "$current_ssid" ]]; then
            echo -e "  ${GREEN}✓${NC} Connected to: $current_ssid"
            ip addr show wlan0 | grep "inet " | awk '{print "  IP Address: " $2}' || true
        else
            echo -e "  ${YELLOW}⚠${NC} Not currently connected"
            echo "  WiFi will connect automatically when in range"
        fi
        echo
    fi
    
    # Show Raspberry Pi Connect status
    if command -v rpi-connect &> /dev/null; then
        echo "Remote Access:"
        ACTUAL_USER="${SUDO_USER:-admin}"
        if loginctl show-user "$ACTUAL_USER" 2>/dev/null | grep -q "Linger=yes"; then
            echo -e "  ${GREEN}✓${NC} Raspberry Pi Connect Lite installed"
            echo -e "  ${GREEN}✓${NC} User lingering enabled (works when logged out)"
            echo -e "  ${CYAN}ℹ${NC}  Run as $ACTUAL_USER: ${YELLOW}rpi-connect on${NC} then ${YELLOW}rpi-connect signin${NC}"
            echo "  🌐 Access at: https://connect.raspberrypi.com"
        fi
        echo
    fi
    
    echo "What was installed:"
    echo -e "  ${GREEN}✓${NC} System dependencies (gphoto2, rclone, msmtp, etc.)"
    echo -e "  ${GREEN}✓${NC} WiFi networks configured"
    echo -e "  ${GREEN}✓${NC} Raspberry Pi Connect (remote access)"
    echo -e "  ${GREEN}✓${NC} Google Drive connection (rclone)"
    echo -e "  ${GREEN}✓${NC} Email configuration (msmtp)"
    echo -e "  ${GREEN}✓${NC} Timelapse script (/usr/local/bin/timelapse)"
    echo -e "  ${GREEN}✓${NC} Directory structure"
    echo
    echo -e "${CYAN}NEXT STEP - Configure your project:${NC}"
    echo -e "  ${YELLOW}sudo timelapse setup${NC}"
    echo
    echo "This will configure:"
    echo "  - USB backup drive"
    echo "  - Project name"
    echo "  - Capture schedule"
    echo "  - End-of-day tasks"
    echo
    echo "Useful commands:"
    echo -e "  ${CYAN}timelapse setup${NC}          - Configure project"
    echo -e "  ${CYAN}timelapse test-camera${NC}    - Test camera"
    echo -e "  ${CYAN}timelapse test-all${NC}       - Run all tests"
    echo -e "  ${CYAN}timelapse status${NC}         - Show status"
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
    configure_wifi              # Now uses NetworkManager - much simpler!
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
