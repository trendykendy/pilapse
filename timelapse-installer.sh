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
# PROGRESS BAR FUNCTIONS
########################################

# Animated spinner with dots
show_spinner() {
    local pid=$1
    local message=$2
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    
    while ps -p $pid > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf "\r  ${CYAN}%s${NC} %s" "$spinstr" "$message"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    
    wait $pid
    return $?
}

# Progress bar with percentage
show_progress() {
    local current=$1
    local total=$2
    local width=40
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    local remaining=$((width - completed))
    
    printf "\r  ${CYAN}["
    printf "%${completed}s" | tr ' ' '█'
    printf "%${remaining}s" | tr ' ' '░'
    printf "]${NC} %3d%%" $percentage
}

# Animated progress for long-running tasks
show_animated_progress() {
    local pid=$1
    local message=$2
    local dots=0
    local max_dots=3
    
    while ps -p $pid > /dev/null 2>&1; do
        local dot_str=$(printf "%${dots}s" | tr ' ' '.')
        printf "\r  ${CYAN}▶${NC} %-50s${dot_str}   " "$message"
        dots=$(( (dots + 1) % (max_dots + 1) ))
        sleep 0.5
    done
    
    wait $pid
    return $?
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
    
    # Check if running on Raspberry Pi
    if [[ -f /proc/device-tree/model ]]; then
        PI_MODEL=$(cat /proc/device-tree/model)
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
    
    log_info "Updating package lists..."
    apt-get update > /tmp/apt-update.log 2>&1 &
    show_animated_progress $! "Updating package lists"
    echo -e "\r  ${GREEN}✓${NC} Package lists updated                                        "
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
        
        # Show overall progress
        show_progress $current $total
        echo -ne "  Installing packages..."
        echo
        
        if dpkg -l 2>/dev/null | grep -q "^ii  $package "; then
            echo -e "  ${GREEN}✓${NC} $package ${CYAN}(already installed)${NC}"
        else
            # Install package with live progress indicator
            apt-get install -y "$package" > /tmp/apt-install-$package.log 2>&1 &
            local install_pid=$!
            
            show_animated_progress $install_pid "Installing $package"
            
            if wait $install_pid; then
                echo -e "\r  ${GREEN}✓${NC} $package ${CYAN}(installed)${NC}                                        "
            else
                echo -e "\r  ${RED}✗${NC} $package ${RED}(failed)${NC}                                        "
                log_error "Failed to install $package. Check /tmp/apt-install-$package.log for details"
            fi
        fi
    done
    
    echo
    log_success "All dependencies installed"
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
        bash -c "cat > '$WPA_CONF' <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=IE

EOF"
        log_info "Created new wpa_supplicant.conf"
    fi
    
    # Show current networks
    echo "Current WiFi networks:"
    if grep -q "^network=" "$WPA_CONF"; then
        grep "ssid=" "$WPA_CONF" | sed 's/.*ssid="\(.*\)".*/  - \1/'
    else
        echo "  (none configured)"
    fi
    echo
    
    read -p "Configure WiFi networks? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Skipping WiFi configuration"
        return
    fi
    
    # Add networks
    while true; do
        read -rp "WiFi SSID (or press Enter to finish): " wifi_ssid
        
        if [[ -z "$wifi_ssid" ]]; then
            break
        fi
        
        read -rsp "WiFi Password: " wifi_password
        echo
        
        if [[ -z "$wifi_password" ]]; then
            echo "Error: Password cannot be empty" >&2
            continue
        fi
        
        # Generate PSK using wpa_passphrase
        wpa_passphrase "$wifi_ssid" "$wifi_password" >> "$WPA_CONF" 2>&1 &
        show_animated_progress $! "Adding network: $wifi_ssid"
        
        echo -e "\r  ${GREEN}✓${NC} Added: $wifi_ssid                                        "
        echo
        
        read -p "Add another WiFi network? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            break
        fi
    done
    
    # Show summary
    echo
    echo "WiFi networks configured:"
    grep "ssid=" "$WPA_CONF" | sed 's/.*ssid="\(.*\)".*/  - \1/'
    echo
    
    # Reconfigure WiFi
    wpa_cli -i wlan0 reconfigure > /dev/null 2>&1 &
    show_animated_progress $! "Applying WiFi configuration"
    echo -e "\r  ${GREEN}✓${NC} WiFi configuration applied                                        "
    
    echo
    
    # Show current connection status
    echo "Current WiFi status:"
    sleep 2  # Give it a moment to connect
    if command -v iwgetid &> /dev/null; then
        current_ssid=$(iwgetid -r)
        if [[ -n "$current_ssid" ]]; then
            echo "  ${GREEN}✓${NC} Connected to: $current_ssid"
            ip addr show wlan0 | grep "inet " | awk '{print "  IP Address: " $2}'
        else
            echo "  ${YELLOW}⚠${NC} Not connected yet"
            echo "  The Pi will connect to one of the configured networks shortly"
        fi
    fi
    echo
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
    
    read -p "Install Raspberry Pi Connect for remote access? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Skipping Raspberry Pi Connect installation"
        return
    fi
    
    # Check if already installed
    if command -v rpi-connect &> /dev/null; then
        log_warning "Raspberry Pi Connect is already installed"
        return
    fi
    
    # Check if running on actual Raspberry Pi
    if [[ ! -f /proc/device-tree/model ]] || ! grep -q "Raspberry Pi" /proc/device-tree/model; then
        log_warning "Not running on a Raspberry Pi"
        read -p "Install Raspberry Pi Connect anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping Raspberry Pi Connect installation"
            return
        fi
    fi
    
    # Install Raspberry Pi Connect
    apt-get install -y rpi-connect > /tmp/rpi-connect-install.log 2>&1 &
    show_animated_progress $! "Installing rpi-connect package"
    
    if wait $!; then
        echo -e "\r  ${GREEN}✓${NC} rpi-connect package installed                                        "
    else
        echo -e "\r  ${RED}✗${NC} Failed to install rpi-connect                                        "
        log_info "You can install it manually later with: sudo apt install rpi-connect"
        return
    fi
    
    # Enable and start the service
    systemctl enable rpi-connect > /dev/null 2>&1 &
    systemctl start rpi-connect > /dev/null 2>&1 &
    show_animated_progress $! "Enabling Raspberry Pi Connect service"
    echo -e "\r  ${GREEN}✓${NC} Raspberry Pi Connect service enabled                                        "
    
    # Enable user lingering (so remote shell works when not logged in)
    ACTUAL_USER="${SUDO_USER:-admin}"
    loginctl enable-linger "$ACTUAL_USER" 2>/dev/null &
    show_animated_progress $! "Enabling user lingering for remote shell"
    echo -e "\r  ${GREEN}✓${NC} User lingering enabled for $ACTUAL_USER                                        "
    
    echo
    log_success "Raspberry Pi Connect installed"
    
    # Check service status
    if systemctl is-active --quiet rpi-connect; then
        echo "  ${GREEN}✓${NC} Service is running"
    else
        echo "  ${YELLOW}⚠${NC} Service failed to start"
    fi
    
    echo
    log_info "To complete Raspberry Pi Connect setup:"
    log_info "  1. Go to https://connect.raspberrypi.com"
    log_info "  2. Sign in with your Raspberry Pi ID"
    log_info "  3. Run: rpi-connect signin"
    echo
    
    read -p "Sign in to Raspberry Pi Connect now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Opening sign-in process..."
        if [[ -n "${SUDO_USER:-}" ]]; then
            sudo -u "$SUDO_USER" rpi-connect signin
        else
            rpi-connect signin
        fi
        log_success "Raspberry Pi Connect sign-in process completed"
    else
        log_info "You can sign in later with: rpi-connect signin"
    fi
    echo
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
    
    local total=${#dirs[@]}
    local current=0
    
    for dir in "${dirs[@]}"; do
        current=$((current + 1))
        mkdir -p "$dir" 2>&1 &
        show_animated_progress $! "Creating directories"
        echo -e "\r  ${GREEN}✓${NC} Created: $dir                                        "
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
        echo
        read -sp "Enter decryption password: " DECRYPT_PASSWORD
        echo
        
        if [[ -z "$DECRYPT_PASSWORD" ]]; then
            log_error "Password cannot be empty"
            exit 1
        fi
    fi
}

download_and_decrypt() {
    local url="$1"
    local output_file="$2"
    local temp_encrypted=$(mktemp)
    
    # Download encrypted file
    curl -fsSL "$url" -o "$temp_encrypted" 2>&1 &
    show_animated_progress $! "Downloading encrypted file"
    
    if ! wait $!; then
        echo -e "\r  ${RED}✗${NC} Failed to download                                        "
        rm -f "$temp_encrypted"
        return 1
    fi
    echo -e "\r  ${GREEN}✓${NC} Downloaded encrypted file                                        "
    
    # Check if file is actually encrypted
    if ! file "$temp_encrypted" | grep -q "GPG"; then
        echo "  ${RED}✗${NC} File is not GPG encrypted"
        rm -f "$temp_encrypted"
        return 1
    fi
    
    # Decrypt file
    (echo "$DECRYPT_PASSWORD" | gpg --decrypt --batch --yes \
        --passphrase-fd 0 "$temp_encrypted" > "$output_file" 2>/dev/null) &
    show_animated_progress $! "Decrypting file"
    
    if wait $!; then
        rm -f "$temp_encrypted"
        echo -e "\r  ${GREEN}✓${NC} Decrypted successfully                                        "
        return 0
    else
        echo -e "\r  ${RED}✗${NC} Decryption failed - incorrect password?                                        "
        rm -f "$temp_encrypted" "$output_file"
        return 1
    fi
}

install_gcloud_json() {
    log_info "Installing Google Cloud service account credentials..."
    echo
    
    local json_dest="$USER_HOME/timelapsecamdriveauth-12192b48330a.json"
    
    # Prompt for password if not already set
    prompt_decrypt_password
    
    # Try to download and decrypt from remote
    if download_and_decrypt "$GCLOUD_JSON_URL" "$json_dest"; then
        # Verify it's valid JSON
        if jq empty "$json_dest" 2>/dev/null; then
            chmod 644 "$json_dest"
            echo
            log_success "Service account JSON installed"
            
            # Show service account email
            local sa_email=$(jq -r '.client_email' "$json_dest")
            log_info "Service account email: $sa_email"
            echo
            log_warning "Make sure this email has access to your Google Drive folder!"
            echo
            
            echo "$json_dest"
            return 0
        else
            log_error "Decrypted file is not valid JSON"
            rm -f "$json_dest"
        fi
    else
        log_warning "Could not download/decrypt service account JSON from remote"
    fi
    
    # Fallback to manual entry
    log_info "Please provide the service account JSON file manually"
    read -p "Enter path to local JSON file (or press Enter to skip): " local_json
    
    if [[ -n "$local_json" ]] && [[ -f "$local_json" ]]; then
        if jq empty "$local_json" 2>/dev/null; then
            cp "$local_json" "$json_dest"
            chmod 644 "$json_dest"
            log_success "Service account JSON installed from local file"
            echo "$json_dest"
            return 0
        else
            log_error "File is not valid JSON: $local_json"
            return 1
        fi
    else
        log_warning "Skipping Google Cloud JSON installation"
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
        read -p "Reconfigure rclone? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            # Test existing config
            if rclone listremotes | grep -q "aperturetimelapsedrive"; then
                log_success "Using existing rclone configuration"
                return 0
            fi
        fi
    fi
    
    # Install JSON file
    json_path=$(install_gcloud_json)
    
    if [[ -z "$json_path" ]] || [[ ! -f "$json_path" ]]; then
        log_error "No service account JSON available"
        log_info "Please configure rclone manually: sudo rclone config"
        return 1
    fi
    
    # Create rclone config automatically
    cat > /root/.config/rclone/rclone.conf << EOF
[aperturetimelapsedrive]
type = drive
scope = drive
service_account_file = $json_path
team_drive = 
EOF
    
    chmod 600 /root/.config/rclone/rclone.conf
    echo "  ${GREEN}✓${NC} rclone configuration created"
    
    # Test connection
    (timeout 10 rclone lsd aperturetimelapsedrive: > /dev/null 2>&1) &
    show_animated_progress $! "Testing Google Drive connection"
    
    if wait $!; then
        echo -e "\r  ${GREEN}✓${NC} Google Drive connection successful                                        "
        log_info "Remote name: aperturetimelapsedrive"
    else
        echo -e "\r  ${RED}✗${NC} Google Drive connection failed                                        "
        log_warning "You may need to:"
        log_warning "  1. Verify the service account JSON is correct"
        log_warning "  2. Share your Drive folder with the service account email"
        
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
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
    fi
    
    # Fallback to manual entry
    log_info "Please provide msmtp configuration"
    read -p "Enter path to local msmtprc file (or press Enter to configure manually): " local_msmtprc
    
    if [[ -n "$local_msmtprc" ]] && [[ -f "$local_msmtprc" ]]; then
        cp "$local_msmtprc" "$msmtprc_dest"
        chmod 600 "$msmtprc_dest"
        log_success "msmtp configuration installed from local file"
        return 0
    else
        log_info "Manual configuration required"
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
        read -p "Reconfigure email? (y/n): " -n 1 -r
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
        read -p "Send test email? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            read -p "Test email recipient: " test_recipient
            
            (echo -e "Subject: Timelapse Installer Test\n\nThis is a test email from the timelapse installer.\n\nIf you received this, email is configured correctly." | msmtp "$test_recipient" 2>/dev/null) &
            show_animated_progress $! "Sending test email"
            
            if wait $!; then
                echo -e "\r  ${GREEN}✓${NC} Test email sent successfully                                        "
                log_info "Check spam folder if not received"
            else
                echo -e "\r  ${YELLOW}⚠${NC} Test email may have failed                                        "
                log_info "Check /root/.msmtp.log for details"
            fi
        fi
        return 0
    fi
    
    # Manual configuration fallback
    log_info "Manual email configuration..."
    echo
    
    read -p "SMTP Server (e.g., smtp.mxroute.com): " smtp_host
    read -p "SMTP Port (587 or 465): " smtp_port
    read -p "From Email Address: " from_email
    read -p "SMTP Username: " smtp_user
    read -sp "SMTP Password: " smtp_pass
    echo
    
    # Determine TLS settings based on port
    if [[ "$smtp_port" == "465" ]]; then
        tls_starttls="off"
    else
        tls_starttls="on"
    fi
    
    # Create msmtprc for root
    cat > /root/.msmtprc << EOF
# msmtp configuration
defaults
auth           on
tls            on
tls_starttls   ${tls_starttls}
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /root/.msmtp.log

account        default
host           ${smtp_host}
port           ${smtp_port}
from           ${from_email}
user           ${smtp_user}
password       ${smtp_pass}
EOF
    
    chmod 600 /root/.msmtprc
    log_success "Email configuration saved"
    
    # Test email
    read -p "Send test email? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -p "Test email recipient: " test_recipient
        
        (echo -e "Subject: Timelapse Test\n\nThis is a test email from the timelapse system." | msmtp "$test_recipient" 2>/dev/null) &
        show_animated_progress $! "Sending test email"
        
        if wait $!; then
            echo -e "\r  ${GREEN}✓${NC} Test email sent successfully                                        "
            log_info "Check spam folder if not received"
        else
            echo -e "\r  ${RED}✗${NC} Test email failed                                        "
            log_info "Check /root/.msmtp.log for details"
        fi
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
    
    curl -fsSL "$TIMELAPSE_SCRIPT_URL" -o "$INSTALL_DIR/timelapse" 2>&1 &
    show_animated_progress $! "Downloading timelapse script"
    
    if wait $!; then
        chmod +x "$INSTALL_DIR/timelapse"
        echo -e "\r  ${GREEN}✓${NC} Timelapse script installed                                        "
        log_info "Location: $INSTALL_DIR/timelapse"
    else
        echo -e "\r  ${RED}✗${NC} Failed to download timelapse script                                        "
        log_info "You can manually place timelapse.sh at $INSTALL_DIR/timelapse"
        read -p "Do you have the script locally? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            read -p "Enter path to timelapse.sh: " script_path
            if [[ -f "$script_path" ]]; then
                cp "$script_path" "$INSTALL_DIR/timelapse"
                chmod +x "$INSTALL_DIR/timelapse"
                log_success "Script installed from local path"
            else
                log_error "File not found: $script_path"
                exit 1
            fi
        else
            exit 1
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
    
    read -p "Test camera connection? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Skipping camera test"
        return
    fi
    
    (timeout 10 gphoto2 --auto-detect 2>/dev/null | grep -q "usb:") &
    show_animated_progress $! "Detecting camera"
    
    if wait $!; then
        echo -e "\r  ${GREEN}✓${NC} Camera detected                                        "
        gphoto2 --auto-detect | grep "usb:"
    else
        echo -e "\r  ${YELLOW}⚠${NC} No camera detected                                        "
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
