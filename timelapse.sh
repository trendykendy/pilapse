#!/usr/bin/env bash
set -euo pipefail

########################################
# 1) CONFIG & SETUP HANDLER
########################################
CONFIG_FILE="/etc/timelapse.conf"
CRON_FILE="/etc/cron.d/timelapse"

# Load existing config (if any), else init empties
if [[ -r "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
else
  PROJECT_NAME=""
  USB_BACKUP_LABEL=""
  INTERVAL_MINS=""
  START_HOUR="7"
  STOP_HOUR="19"
  SYNC_TIME="22:00"
  MONTAGE_TIME="23:00"
  CLEANUP_TIME="00:00"
fi

# 
# change-interval handler
# 
cmd_interval() {
  # accept either a flag or a positional argument
  if [[ "${1-}" =~ ^[0-9]+$ ]]; then
    NEW_INTERVAL="$1"
  else
    read -rp "New interval in minutes: " NEW_INTERVAL
  fi

  # validate
  if ! [[ "$NEW_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: interval must be a positive integer." >&2
    exit 1
  fi

  # Calculate cron stop hour
  CRON_STOP_HOUR=$((${STOP_HOUR:-19} - 1))

  # overwrite just the interval in the config (preserve other values)
  sudo bash -c "cat > '$CONFIG_FILE' <<EOF
PROJECT_NAME=\"${PROJECT_NAME}\"
USB_BACKUP_LABEL=\"${USB_BACKUP_LABEL}\"
INTERVAL_MINS=\"${NEW_INTERVAL}\"
START_HOUR=\"${START_HOUR:-7}\"
STOP_HOUR=\"${STOP_HOUR:-19}\"
SYNC_TIME=\"${SYNC_TIME:-22:00}\"
MONTAGE_TIME=\"${MONTAGE_TIME:-23:00}\"
CLEANUP_TIME=\"${CLEANUP_TIME:-00:00}\"
EOF"
  sudo chmod 644 "$CONFIG_FILE"
  echo "Updated /etc/timelapse.conf with INTERVAL_MINS=$NEW_INTERVAL"

  # Parse times into hour and minute for end-of-day tasks
  SYNC_HOUR=$(echo "${SYNC_TIME:-22:00}" | cut -d: -f1)
  SYNC_MIN=$(echo "${SYNC_TIME:-22:00}" | cut -d: -f2)
  
  MONTAGE_HOUR=$(echo "${MONTAGE_TIME:-23:00}" | cut -d: -f1)
  MONTAGE_MIN=$(echo "${MONTAGE_TIME:-23:00}" | cut -d: -f2)
  
  CLEANUP_HOUR=$(echo "${CLEANUP_TIME:-00:00}" | cut -d: -f1)
  CLEANUP_MIN=$(echo "${CLEANUP_TIME:-00:00}" | cut -d: -f2)

  # rewrite ALL cron jobs in single file
  sudo bash -c "cat > '$CRON_FILE' <<EOF
# Timelapse photo capture: runs every ${NEW_INTERVAL} minutes between ${START_HOUR:-7}:00 and ${STOP_HOUR:-19}:00
*/${NEW_INTERVAL} ${START_HOUR:-7}-${CRON_STOP_HOUR} * * * root /usr/local/bin/timelapse capture >/var/log/timelapse.log 2>&1

# Timelapse end-of-day tasks
$SYNC_MIN $SYNC_HOUR * * * root /usr/local/bin/timelapse end_of_day_sync
$MONTAGE_MIN $MONTAGE_HOUR * * * root /usr/local/bin/timelapse create_daily_montage
$CLEANUP_MIN $CLEANUP_HOUR * * * root /usr/local/bin/timelapse cleanup_directories
EOF"
  sudo chmod 644 "$CRON_FILE"
  echo "Cron jobs updated: photo capture runs every ${NEW_INTERVAL} minutes from ${START_HOUR:-7}:00 to ${STOP_HOUR:-19}:00"
  exit 0
}

cmd_setup() {
  # parse any flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)     PROJECT_NAME="$2";     shift 2 ;;
      --usb-label)   USB_BACKUP_LABEL="$2"; shift 2 ;;
      --interval)    INTERVAL_MINS="$2";    shift 2 ;;  # in minutes
      --email)       EMAIL_RECIPIENTS="$2"; shift 2 ;;
      --slack-webhook) SLACK_WEBHOOK="$2";  shift 2 ;;
      --slack-user)  SLACK_USER_ID="$2";    shift 2 ;;
      -h|--help)
        cat <<EOF
Usage: timelapse setup [--project NAME] [--usb-label LABEL] [--interval MINUTES]
                       [--email RECIPIENTS] [--slack-webhook URL] [--slack-user ID]

  --project       : name of this timelapse project
  --usb-label     : filesystem label of your USB backup drive
  --interval      : how often (in minutes) to run 'timelapse capture'
  --email         : email recipients (space-separated)
  --slack-webhook : Slack webhook URL for notifications
  --slack-user    : Slack user ID for mentions
EOF
        exit 0 ;;
      *)
        echo "Unknown option: $1" >&2
        exit 1 ;;
    esac
  done

  echo
  echo "═══════════════════════════════════════════════════════"
  echo "  TIMELAPSE PROJECT SETUP"
  echo "═══════════════════════════════════════════════════════"
  echo

  # 
  # USB-drive detection & selection
  # 
  if [[ -z "$USB_BACKUP_LABEL" ]]; then
    echo "USB BACKUP DRIVE"
    echo "────────────────────────────────────────────────────────"
    echo
    while :; do
      # Use lsblk with pairs output for easier parsing
      mapfile -t devices < <(
        lsblk -n -o NAME,LABEL -P \
          | grep 'NAME="sd[a-z][0-9]\+"' \
          | grep -v 'LABEL=""' \
          | while IFS= read -r line; do
              eval "$line"
              echo "/dev/$NAME:$LABEL"
            done
      )

      if (( ${#devices[@]} > 0 )); then
        echo "Detected USB drives:"
        for i in "${!devices[@]}"; do
          dev="${devices[i]%%:*}"
          lbl="${devices[i]#*:}"
          printf "  %2d) %-12s (label=\"%s\")\n" $((i+1)) "$dev" "$lbl"
        done
        echo

        read -rp "Select a drive [1-${#devices[@]}] or S to skip: " choice
        
        # Check if user wants to skip
        if [[ "${choice^^}" == "S" ]]; then
          echo "Skipping USB setup."
          USB_BACKUP_LABEL=""
          break
        fi
        
        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && (( choice <= ${#devices[@]} )); then
          USB_BACKUP_LABEL="${devices[choice-1]#*:}"
          echo "Using label: $USB_BACKUP_LABEL"
          break
        else
          echo "Invalid choice." >&2
        fi

      else
        echo "No labeled USB drives found."
        read -rp "[R]etry, [M]anual entry, or [S]kip USB setup? " ans
        case "${ans^^}" in
          R)  continue ;;
          M)  
            read -rp "Enter USB label manually: " USB_BACKUP_LABEL
            if [[ -n "$USB_BACKUP_LABEL" ]]; then
              break
            else
              echo "Label cannot be empty. Please try again."
            fi
            ;;
          S)  
            echo "Skipping USB setup."
            USB_BACKUP_LABEL=""
            break
            ;;
          *)  echo "Please choose R, M, or S." ;;
        esac
      fi
    done
    echo
  fi

  # interactive for anything missing
  echo "PROJECT DETAILS"
  echo "────────────────────────────────────────────────────────"
  echo
  [[ -z "$PROJECT_NAME" ]] && read -rp "Project name: " PROJECT_NAME
  if [[ -z "$INTERVAL_MINS" ]]; then
    read -rp "Capture interval in minutes (e.g. 5): " INTERVAL_MINS
  fi
  echo

  # Configure capture time window
  echo "CAPTURE TIME WINDOW"
  echo "────────────────────────────────────────────────────────"
  echo "Set the hours during which photos should be captured"
  echo
  
  read -rp "Start capturing at hour (0-23, default 7): " START_HOUR
  START_HOUR=${START_HOUR:-7}
  
  read -rp "Stop capturing at hour (0-23, default 19): " STOP_HOUR
  STOP_HOUR=${STOP_HOUR:-19}

  # Validate hours
  if ! [[ "$START_HOUR" =~ ^([0-1]?[0-9]|2[0-3])$ ]] || ! [[ "$STOP_HOUR" =~ ^([0-1]?[0-9]|2[0-3])$ ]]; then
    echo "Error: Hours must be between 0 and 23" >&2
    exit 1
  fi

  if (( START_HOUR >= STOP_HOUR )); then
    echo "Error: Start hour must be before stop hour" >&2
    exit 1
  fi
  echo

  # Configure end-of-day task times
  echo "END-OF-DAY TASK SCHEDULING"
  echo "────────────────────────────────────────────────────────"
  echo "Configure when the end-of-day tasks should run"
  echo
  
  read -rp "Time for photo sync (HH:MM, default 22:00): " SYNC_TIME
  SYNC_TIME=${SYNC_TIME:-22:00}
  
  read -rp "Time for daily montage (HH:MM, default 23:00): " MONTAGE_TIME
  MONTAGE_TIME=${MONTAGE_TIME:-23:00}
  
  read -rp "Time for cleanup (HH:MM, default 00:00): " CLEANUP_TIME
  CLEANUP_TIME=${CLEANUP_TIME:-00:00}

  # Validate time format
  validate_time() {
    local time=$1
    if [[ ! "$time" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
      echo "Invalid time format: $time (use HH:MM)" >&2
      return 1
    fi
    return 0
  }

  if ! validate_time "$SYNC_TIME" || ! validate_time "$MONTAGE_TIME" || ! validate_time "$CLEANUP_TIME"; then
    echo "Error: Invalid time format. Please use HH:MM (24-hour format)" >&2
    exit 1
  fi

  # Parse times into hour and minute
  SYNC_HOUR=$(echo "$SYNC_TIME" | cut -d: -f1)
  SYNC_MIN=$(echo "$SYNC_TIME" | cut -d: -f2)
  
  MONTAGE_HOUR=$(echo "$MONTAGE_TIME" | cut -d: -f1)
  MONTAGE_MIN=$(echo "$MONTAGE_TIME" | cut -d: -f2)
  
  CLEANUP_HOUR=$(echo "$CLEANUP_TIME" | cut -d: -f1)
  CLEANUP_MIN=$(echo "$CLEANUP_TIME" | cut -d: -f2)

  # Configure notifications
  echo
  echo "NOTIFICATION SETTINGS"
  echo "────────────────────────────────────────────────────────"
  echo
  
  # Email configuration
  if [[ -z "$EMAIL_RECIPIENTS" ]]; then
    echo "Email Notifications:"
    echo "  Enter email addresses for daily reports (space-separated)"
    echo "  Example: user1@example.com user2@example.com"
    echo "  Press Enter to skip email notifications"
    echo
    read -rp "Email recipients: " EMAIL_RECIPIENTS
    echo
  fi
  
  # Slack configuration
  if [[ -z "$SLACK_WEBHOOK" ]]; then
    echo "Slack Notifications:"
    echo "────────────────────────────────────────────────────────"
    echo
    echo "To get your Slack Webhook URL:"
    echo "  1. Go to: https://api.slack.com/apps"
    echo "  2. Click 'Create New App' → 'From scratch' OR click on the app you have already created and skip to step 7"  
    echo "  3. Name your app (e.g., 'Timelapse Bot') and select your workspace"
    echo "  4. Click 'Incoming Webhooks' → Toggle 'Activate Incoming Webhooks' ON"
    echo "  5. Click 'Add New Webhook to Workspace'"
    echo "  6. If the webhook already exits, copy it."
    echo "  6. Select the channel for notifications"
    echo "  7. Copy the Webhook URL (starts with https://hooks.slack.com/...)"
    echo
    echo "Press Enter to skip Slack notifications"
    echo
    read -rp "Slack Webhook URL: " SLACK_WEBHOOK
    echo
    
    if [[ -n "$SLACK_WEBHOOK" ]]; then
      echo "Slack User ID (for mentions):"
      echo "────────────────────────────────────────────────────────"
      echo
      echo "To get your Slack User ID:"
      echo "  1. In Slack, click on your profile picture"
      echo "  2. Click 'Profile'"
      echo "  3. Click the three dots (···) → 'Copy member ID'"
      echo "  OR"
      echo "  1. Right-click on your name in any channel"
      echo "  2. Select 'Copy member ID'"
      echo
      echo "The ID looks like: U0RSCG38X"
      echo "Press Enter to skip user mentions (notifications will still be sent)"
      echo
      read -rp "Slack User ID: " SLACK_USER_ID
      echo
    fi
  fi

  # persist config
  sudo bash -c "cat > '$CONFIG_FILE' <<EOF
PROJECT_NAME=\"${PROJECT_NAME}\"
USB_BACKUP_LABEL=\"${USB_BACKUP_LABEL}\"
INTERVAL_MINS=\"${INTERVAL_MINS}\"
START_HOUR=\"${START_HOUR}\"
STOP_HOUR=\"${STOP_HOUR}\"
SYNC_TIME=\"${SYNC_TIME}\"
MONTAGE_TIME=\"${MONTAGE_TIME}\"
CLEANUP_TIME=\"${CLEANUP_TIME}\"
EMAIL_RECIPIENTS=\"${EMAIL_RECIPIENTS}\"
SLACK_WEBHOOK=\"${SLACK_WEBHOOK}\"
SLACK_USER_ID=\"${SLACK_USER_ID}\"
EOF"
  sudo chmod 600 "$CONFIG_FILE"
  echo
  echo "✓ Saved config to $CONFIG_FILE"

  # Calculate hour range for cron
  CRON_STOP_HOUR=$((STOP_HOUR - 1))
  
  # install/update ALL cron jobs in single file
  sudo bash -c "cat > '$CRON_FILE' <<EOF
# Timelapse photo capture: runs every ${INTERVAL_MINS} minutes between ${START_HOUR}:00 and ${STOP_HOUR}:00
*/${INTERVAL_MINS} ${START_HOUR}-${CRON_STOP_HOUR} * * * root /usr/local/bin/timelapse capture >/var/log/timelapse.log 2>&1

# Timelapse end-of-day tasks
$SYNC_MIN $SYNC_HOUR * * * root /usr/local/bin/timelapse end_of_day_sync
$MONTAGE_MIN $MONTAGE_HOUR * * * root /usr/local/bin/timelapse create_daily_montage
$CLEANUP_MIN $CLEANUP_HOUR * * * root /usr/local/bin/timelapse cleanup_directories
EOF"
  sudo chmod 644 "$CRON_FILE"
  echo "✓ Cron jobs installed in $CRON_FILE"

  echo
  echo "═══════════════════════════════════════════════════════"
  echo "  SETUP COMPLETE"
  echo "═══════════════════════════════════════════════════════"
  echo
  echo "Configuration:"
  echo "  Project: $PROJECT_NAME"
  echo "  USB Label: ${USB_BACKUP_LABEL:-Not configured}"
  echo "  Capture Interval: Every $INTERVAL_MINS minutes"
  echo "  Capture Hours: ${START_HOUR}:00 to ${STOP_HOUR}:00"
  echo
  echo "End-of-Day Schedule:"
  echo "  Photo Sync:      $SYNC_TIME"
  echo "  Daily Montage:   $MONTAGE_TIME"
  echo "  Cleanup:         $CLEANUP_TIME"
  echo
  echo "Notifications:"
  echo "  Email: ${EMAIL_RECIPIENTS:-Not configured}"
  echo "  Slack: ${SLACK_WEBHOOK:+Configured}${SLACK_WEBHOOK:-Not configured}"
  if [[ -n "$SLACK_USER_ID" ]]; then
    echo "  Slack Mentions: Enabled (User ID: $SLACK_USER_ID)"
  fi
  echo
  echo "All cron jobs are in: /etc/cron.d/timelapse"
  echo
  echo "Next steps:"
  echo "  - Test camera: sudo timelapse test-camera"
  echo "  - Take photo:  sudo timelapse capture"
  echo "  - View status: sudo timelapse status"
  echo

  exit 0
}

########################################
# 2) YOUR EXISTING SCRIPT LOGIC BELOW
########################################
# Date variables - MUST be defined before using them
DATE=$(date +%d-%m-%Y)
CURRENT_MONTH=$(date +"%B %Y")

# Global settings
PHOTO_DIR="/home/admin/photos"                  # Where photos are stored hourly
BACKUP_DIR="/home/admin/backups"                # Local backup folder
THUMBNAIL_DIR="/home/admin/thumbnails"          # Folder for thumbnails
REMOTE_FOLDER="Daily Photos"                    # Remote Google Drive folder with daily structure
ARCHIVE_DIR="/home/admin/archive"               # Folder for archived backups (older than 30 days)
DAILY_MONTAGE="/home/admin/daily_report_$DATE.jpg"   # Path for the daily thumbnail table
LOG_FILE="/var/log/timelapse.log"       # Log file
VERBOSE=true                                    # Toggle verbose output
# These will be loaded from config file or set during setup
EMAIL_RECIPIENTS="${EMAIL_RECIPIENTS:-}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
SLACK_USER_ID="${SLACK_USER_ID:-}"
# Rate limiting for Slack mentions
MENTION_COOLDOWN_FILE="/tmp/timelapse_mention_cooldown_${PROJECT_NAME// /_}"
MENTION_COOLDOWN_SECONDS=3600  # 1 hour
EMAIL_SUBJECT="Daily Report - $DATE"            # Subject for the email
GDRIVE_REMOTE="aperturetimelapsedrive"          # Google Drive remote name
MOUNT_POINT="/mnt/BackupArchive"

# Find the device by label
if [[ -n "${USB_BACKUP_LABEL}" ]]; then
    DEVICE=$(findfs LABEL="${USB_BACKUP_LABEL}" 2>/dev/null || echo "")
    if [[ -z "$DEVICE" ]]; then
        # Fallback: try to find it manually
        DEVICE=$(lsblk -ln -o NAME,LABEL | grep -F "${USB_BACKUP_LABEL}" | awk '{print "/dev/"$1}' | head -n1)
    fi
else
    DEVICE=""
fi

########################################
# 0.5) Log File Setup
########################################
# Ensure log file exists and is writable
ensure_log_file() {
    # Try to create/access the main log file
    if [[ ! -f "$LOG_FILE" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
        touch "$LOG_FILE" 2>/dev/null || {
            echo "WARNING: Cannot create log file: $LOG_FILE" >&2
            LOG_FILE="/tmp/timelapse_$(date +%Y%m%d).log"
            echo "WARNING: Using fallback log: $LOG_FILE" >&2
            touch "$LOG_FILE" 2>/dev/null || {
                echo "ERROR: Cannot create fallback log file" >&2
                LOG_FILE="/dev/null"
            }
        }
    fi

    # Make sure log file is writable
    if [[ ! -w "$LOG_FILE" ]] && [[ "$LOG_FILE" != "/dev/null" ]]; then
        echo "WARNING: Log file not writable: $LOG_FILE" >&2
        LOG_FILE="/tmp/timelapse_$(date +%Y%m%d).log"
        echo "WARNING: Using fallback log: $LOG_FILE" >&2
        touch "$LOG_FILE" 2>/dev/null || {
            echo "ERROR: Cannot create fallback log file" >&2
            LOG_FILE="/dev/null"
        }
    fi
}

# Call this before any logging
ensure_log_file

# Helper function for logging with fallback
log() {
    local message="[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo "$message" >> "$LOG_FILE" 2>/dev/null || {
        echo "$message" >&2  # If can't write to log, print to stderr
        # Also try to notify via Slack if logging completely fails
        if [[ "$LOG_FILE" == "/dev/null" ]]; then
            notify_slack "⚠️ Logging system failure - using stderr only" "true" 2>/dev/null || true
        fi
    }
}


# Initialize the counter file if it doesn't exist
COUNTER_FILE="/var/lib/timelapse/counter.txt"
COUNTER_BACKUP_FILE="/mnt/BackupArchive/timelapse_counter_backup.txt"
GDRIVE_COUNTER_FILE="$GDRIVE_REMOTE:$PROJECT_NAME/.timelapse_counter.txt"

# Function to initialize counter directory
init_counter() {
    if [ ! -d "/var/lib/timelapse" ]; then
        sudo mkdir -p "/var/lib/timelapse"
        sudo chmod 755 "/var/lib/timelapse"
    fi
    
    if [ ! -f "$COUNTER_FILE" ]; then
        echo "00001" > "$COUNTER_FILE"
    fi
}

# Function to extract counter from filename
extract_counter_from_filename() {
    local filename="$1"
    # Extract the counter part (before first underscore)
    echo "$filename" | grep -oE '^[0-9]{5}' || echo "0"
}

# Function to update Google Drive counter
update_gdrive_counter() {
    local counter_value="$1"
    local temp_file=$(mktemp)
    
    printf "%05d" "$counter_value" > "$temp_file"
    
    if rclone copyto "$temp_file" "$GDRIVE_COUNTER_FILE" 2>/dev/null; then
        verbose_log "Updated Google Drive counter to: $counter_value"
        log "Google Drive counter updated: $counter_value"
    else
        verbose_log "Failed to update Google Drive counter"
        log "Warning: Failed to update Google Drive counter"
    fi
    
    rm -f "$temp_file"
}

# Function to read Google Drive counter
read_gdrive_counter() {
    local temp_file=$(mktemp)
    
    if rclone copyto "$GDRIVE_COUNTER_FILE" "$temp_file" 2>/dev/null; then
        local counter=$(cat "$temp_file" | tr -d '\n')
        rm -f "$temp_file"
        echo "$((10#$counter))"
    else
        rm -f "$temp_file"
        echo "0"
    fi
}

# Function to find highest counter from multiple sources
find_highest_counter() {
    local max_counter=0
    local source="default"
    
    verbose_log "Searching for highest counter across all sources..."
    
    # 1. Check local counter file
    if [ -f "$COUNTER_FILE" ]; then
        local local_counter=$(cat "$COUNTER_FILE" | tr -d '\n')
        local_counter=$((10#$local_counter))  # Convert to decimal, removing leading zeros
        if [ "$local_counter" -gt "$max_counter" ]; then
            max_counter=$local_counter
            source="local_file"
        fi
        verbose_log "Local counter file: $local_counter"
    fi
    
    # 2. Check USB backup counter file
    if [[ -n "$DEVICE" ]] && [[ -b "$DEVICE" ]]; then
        local usb_mounted=false
        if ! mountpoint -q "$MOUNT_POINT"; then
            mkdir -p "$MOUNT_POINT"
            if mount "$DEVICE" "$MOUNT_POINT" 2>/dev/null; then
                verbose_log "USB mounted for counter check"
                usb_mounted=true
            fi
        fi
        
        if mountpoint -q "$MOUNT_POINT" && [ -f "$COUNTER_BACKUP_FILE" ]; then
            local usb_counter=$(cat "$COUNTER_BACKUP_FILE" | tr -d '\n')
            usb_counter=$((10#$usb_counter))
            if [ "$usb_counter" -gt "$max_counter" ]; then
                max_counter=$usb_counter
                source="usb_backup"
            fi
            verbose_log "USB backup counter: $usb_counter"
        fi
        
        # Unmount if we mounted it
        if [ "$usb_mounted" = true ]; then
            umount "$MOUNT_POINT" 2>/dev/null
            verbose_log "USB unmounted after counter check"
        fi
    fi
    
    # 3. Check Google Drive counter file (fast!)
    verbose_log "Checking Google Drive counter file..."
    local gdrive_counter=$(read_gdrive_counter)
    if [ "$gdrive_counter" -gt 0 ]; then
        if [ "$gdrive_counter" -gt "$max_counter" ]; then
            max_counter=$gdrive_counter
            source="google_drive"
        fi
        verbose_log "Google Drive counter: $gdrive_counter"
    else
        verbose_log "No Google Drive counter found or connection failed"
    fi
    
    # 4. Fallback: Check local backup folder for actual files (slower)
    if [ "$max_counter" -eq 0 ]; then
        verbose_log "No counters found, scanning local backup files as fallback..."
        local backup_highest=$(find "$BACKUP_DIR" -type f -name "[0-9][0-9][0-9][0-9][0-9]_*.jpg" 2>/dev/null | \
            while read -r file; do
                extract_counter_from_filename "$(basename "$file")"
            done | sort -rn | head -1)
        
        if [ -n "$backup_highest" ]; then
            local backup_counter=$((10#$backup_highest))
            if [ "$backup_counter" -gt "$max_counter" ]; then
                max_counter=$backup_counter
                source="local_backup_files"
            fi
            verbose_log "Highest local backup counter: $backup_counter"
        fi
    fi
    
    # 5. Fallback: Check local photos folder (slower)
    if [ "$max_counter" -eq 0 ]; then
        verbose_log "No counters found, scanning local photo files as fallback..."
        local photo_highest=$(find "$PHOTO_DIR" -type f -name "[0-9][0-9][0-9][0-9][0-9]_*.jpg" 2>/dev/null | \
            while read -r file; do
                extract_counter_from_filename "$(basename "$file")"
            done | sort -rn | head -1)
        
        if [ -n "$photo_highest" ]; then
            local photo_counter=$((10#$photo_highest))
            if [ "$photo_counter" -gt "$max_counter" ]; then
                max_counter=$photo_counter
                source="local_photo_files"
            fi
            verbose_log "Highest local photo counter: $photo_counter"
        fi
    fi
    
    verbose_log "Highest counter found: $max_counter (source: $source)"
    log "Counter recovered from $source: $max_counter"
    
    # If we found a counter from files but not from counter files, initialize the counter files
    if [ "$max_counter" -gt 0 ] && [ "$source" != "local_file" ] && [ "$source" != "usb_backup" ] && [ "$source" != "google_drive" ]; then
        verbose_log "Initializing counter files with recovered value: $max_counter"
        printf "%05d" "$max_counter" > "$COUNTER_FILE"
        update_gdrive_counter "$max_counter"
    fi
    
    echo "$max_counter"
}

# Function to get and increment the counter
get_next_counter() {
    # Initialize if needed
    init_counter
    
    # Find the highest counter from all sources
    local highest=$(find_highest_counter)
    
    # Get current counter from file
    local current=$(cat "$COUNTER_FILE" | tr -d '\n')
    current=$((10#$current))
    
    # Use whichever is higher
    if [ "$highest" -gt "$current" ]; then
        verbose_log "Counter mismatch detected. Local: $current, Highest found: $highest. Using highest."
        log "Counter recovered: was $current, now using $highest"
        current=$highest
    fi
    
    # Increment for next photo
    local next=$((current + 1))
    
    # Save the incremented counter locally
    printf "%05d" "$next" > "$COUNTER_FILE"
    
    # Backup to USB if available
    if [[ -n "$DEVICE" ]] && [[ -b "$DEVICE" ]]; then
        local usb_mounted=false
        if ! mountpoint -q "$MOUNT_POINT"; then
            mkdir -p "$MOUNT_POINT"
            if mount "$DEVICE" "$MOUNT_POINT" 2>/dev/null; then
                usb_mounted=true
            fi
        fi
        
        if mountpoint -q "$MOUNT_POINT"; then
            printf "%05d" "$next" > "$COUNTER_BACKUP_FILE" 2>/dev/null
            verbose_log "Counter backed up to USB"
        fi
        
        if [ "$usb_mounted" = true ]; then
            umount "$MOUNT_POINT" 2>/dev/null
        fi
    fi
    
    # Return current counter (before increment)
    printf "%05d" "$current"
}


generate_filename() {
    COUNTER=$(get_next_counter) # Get the next counter value
    TIMESTAMP=$(date +"%Y%m%d_%H%M") # Format timestamp as YYYYMMDD_HHMM
    FILENAME="${COUNTER}_${TIMESTAMP}.jpg" # Combine counter and timestamp
    echo "$FILENAME"
}

# Helper function for verbose output
verbose_log() {
    if [ "$VERBOSE" = true ]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    fi
}

# Helper function to send Slack notification
notify_slack() {
    local message="$1"
    local force_mention="${2:-false}"  # Optional parameter to force mention
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Debug logging
    verbose_log "notify_slack called with message: $message"
    log "Attempting to send Slack notification"
    
    # Check if we should mention the user
    local mention=""
    if [[ -n "${SLACK_USER_ID:-}" ]]; then
        verbose_log "SLACK_USER_ID is set: $SLACK_USER_ID"
        local should_mention=false
        
        # Force mention if explicitly requested
        if [[ "$force_mention" == "true" ]]; then
            should_mention=true
        else
            # Check cooldown
            if [[ -f "$MENTION_COOLDOWN_FILE" ]]; then
                local last_mention=$(cat "$MENTION_COOLDOWN_FILE")
                local current_time=$(date +%s)
                local time_diff=$((current_time - last_mention))
                
                verbose_log "Cooldown check: last=$last_mention, current=$current_time, diff=$time_diff"
                
                if [[ $time_diff -ge $MENTION_COOLDOWN_SECONDS ]]; then
                    should_mention=true
                fi
            else
                # No cooldown file exists, so mention
                should_mention=true
            fi
        fi
        
        # Add mention if appropriate
        if [[ "$should_mention" == "true" ]]; then
            mention="<@${SLACK_USER_ID}> "
            # Update cooldown file
            date +%s > "$MENTION_COOLDOWN_FILE"
            verbose_log "Adding mention to message"
        else
            # Still indicate it's an alert, just don't ping
            mention="🔔 "
            verbose_log "Using bell emoji (cooldown active)"
        fi
    else
        verbose_log "SLACK_USER_ID not set"
    fi
    
    local full_message="*[${PROJECT_NAME}]* ${timestamp}\n${mention}${message}"
    
    verbose_log "Sending to Slack: $full_message"
    
    local response=$(curl -X POST -H 'Content-type: application/json' \
        --data '{"text":"'"$full_message"'"}' "$SLACK_WEBHOOK" 2>&1)
    
    local curl_exit=$?
    
    if [[ $curl_exit -eq 0 ]]; then
        verbose_log "Slack notification sent successfully. Response: $response"
        log "Slack notification sent"
    else
        verbose_log "Slack notification failed. Exit code: $curl_exit, Response: $response"
        log "ERROR: Slack notification failed with exit code $curl_exit"
    fi
}



# Helper function to send email with attachment using msmtp
send_email() {
    local attachment="$1"
    # Get image counts for the report
    report_data=$(count_images_for_report)
    
    verbose_log "Sending email with attachment using msmtp."
    
    (
        echo "Subject: $EMAIL_SUBJECT"
        echo "Content-Type: multipart/mixed; boundary=\"FILEBOUNDARY\""
        echo
        echo "--FILEBOUNDARY"
        echo "Content-Type: text/plain; charset=utf-8"
        echo
        echo "Please find the daily montage attached."
        echo
        echo "Daily Report: $report_data"
        echo
        echo "--FILEBOUNDARY"
        echo "Content-Type: image/jpeg; name=$(basename "$attachment")"
        echo "Content-Disposition: attachment; filename=$(basename "$attachment")"
        echo "Content-Transfer-Encoding: base64"
        echo
        base64 "$attachment"
        echo "--FILEBOUNDARY--"
    ) | msmtp "$EMAIL_RECIPIENTS"

    if [ $? -eq 0 ]; then
        verbose_log "Email with attachment sent successfully to $EMAIL_RECIPIENTS."
        log "Email with attachment sent successfully to $EMAIL_RECIPIENTS."
    else
        verbose_log "Failed to send email with attachment to $EMAIL_RECIPIENTS."
        log "Failed to send email with attachment to $EMAIL_RECIPIENTS."
        notify_slack "<@U0RSCG38X> Failed to send email with attachment for daily montage."
    fi
}


# Capture photo
take_photo() {
    local base_folder="$PHOTO_DIR/$PROJECT_NAME/Daily Photos/$CURRENT_MONTH/$DATE"
    mkdir -p "$base_folder"

    # Generate filename with auto-incrementing counter and timestamp
    local counter=$(get_next_counter)
    local timestamp=$(date +%Y%m%d_%H%M)
    local photo_filename="${counter}_${timestamp}.jpg"
    local photo_path="$base_folder/$photo_filename"

    verbose_log "Attempting to capture photo: $photo_path"
    log "Attempting to capture photo: $photo_path"

    # Function to attempt capturing the photo with timeout
    capture_with_timeout() {
        timeout 30 gphoto2 --capture-image-and-download --filename "$photo_path"
    }

    # First attempt
    if capture_with_timeout; then
        if [ -f "$photo_path" ]; then
            verbose_log "Photo captured successfully: $photo_path"
            log "Photo captured: $photo_path"
            process_photo "$photo_path"
            return 0
        else
            verbose_log "Photo capture failed: File not created."
            log "Photo capture failed: File not created."
        fi
    else
        verbose_log "Photo capture timed out or failed."
        log "Photo capture timed out or failed."
    fi

    # Retry after failure or timeout
    verbose_log "Retrying photo capture in 10 seconds..."
    log "Retrying photo capture in 10 seconds..."
    sleep 10

    if capture_with_timeout; then
        if [ -f "$photo_path" ]; then
            verbose_log "Photo captured successfully on retry: $photo_path"
            log "Photo captured on retry: $photo_path"
            process_photo "$photo_path"
            return 0
        else
            verbose_log "Photo capture failed on retry: File not created."
            log "Photo capture failed on retry: File not created."
            notify_slack "🚨 *Photo Capture Failed* (after retry)\nProject: ${PROJECT_NAME}\nTime: $(date '+%Y-%m-%d %H:%M:%S')\nFile not created: \`${photo_filename}\`"
        fi
    else
        verbose_log "Photo capture timed out on retry."
        log "Photo capture timed out on retry."
        notify_slack "🚨 *Photo Capture Timed Out* (after retry)\nProject: ${PROJECT_NAME}\nTime: $(date '+%Y-%m-%d %H:%M:%S')\nExpected file: \`${photo_filename}\`"
    fi

    verbose_log "All attempts to capture the photo have failed."
    log "All attempts to capture the photo have failed."
    return 1
}


# Process photo: upload and backup
process_photo() {
    local photo_path="$1"
    verbose_log "Processing photo: $photo_path"
    
    # Attempt to upload the photo
    if upload_photo "$photo_path"; then
        verbose_log "Photo uploaded successfully, moving to backup: $photo_path"
    else
        verbose_log "Photo upload failed, moving to backup: $photo_path"
    fi
    
    # Generate a thumbnail
    generate_thumbnail "$photo_path"
    
    # Move the photo to the backup folder
    backup_photo "$photo_path"
    
}


# Upload photo to Google Drive
upload_photo() {
    local photo_path="$1"
    local photo_filename=$(basename "$photo_path")
    local gdrive_folder="$GDRIVE_REMOTE:$PROJECT_NAME/Daily Photos/$CURRENT_MONTH/$DATE/"
    local remote_file_path="$gdrive_folder$photo_filename"

    verbose_log "Uploading photo to Google Drive: $photo_path"

    # Capture rclone output
    local upload_log=$(mktemp)
    rclone copy "$photo_path" "$gdrive_folder" --low-level-retries 3 --retries 3 --progress 2>"$upload_log"
    local upload_result=$?
    local upload_error=$(cat "$upload_log")
    rm -f "$upload_log"

    if [[ $upload_result -eq 0 ]]; then
        verbose_log "Photo uploaded successfully. Verifying checksum..."

        # Verify remote file exists
        rclone ls "$remote_file_path" > /dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            verbose_log "Remote file not found: $remote_file_path"
            log "Error: Remote file not found for checksum verification: $photo_path"
            notify_slack "Upload verification failed: Remote file not found\nFile: $photo_filename"
            return 1
        fi

        # Calculate local checksum
        local_checksum=$(md5sum "$photo_path" | awk '{print $1}')

        # Get remote checksum
        remote_checksum=$(rclone md5sum "$gdrive_folder" | grep "$photo_filename" | awk '{print $1}')

        if [[ "$local_checksum" = "$remote_checksum" ]]; then
            verbose_log "Checksum match: File integrity verified for $photo_filename"
            log "Upload successful and verified: $photo_path"
            
            # Extract counter from filename and update Google Drive counter
            local counter=$(extract_counter_from_filename "$photo_filename")
            counter=$((10#$counter))
            update_gdrive_counter "$counter"
            
            return 0
        else
            verbose_log "Checksum mismatch: File may be corrupted. Local: $local_checksum, Remote: $remote_checksum"
            log "Error: Checksum mismatch for $photo_filename"
            notify_slack "Checksum mismatch for photo: $photo_filename\nLocal: $local_checksum\nRemote: $remote_checksum"
            return 1
        fi
    else
        verbose_log "Upload failed for: $photo_path"
        log "Upload failed for: $photo_path"
        
        # Extract useful error info
        local error_summary=$(echo "$upload_error" | grep -i "error\|failed\|quota" | head -3)
        if [[ -z "$error_summary" ]]; then
            error_summary="Upload failed (exit code: $upload_result)"
        fi
        
        notify_slack "Upload failed for photo: $photo_filename\nError: $error_summary"
        return 1
    fi
}

# Backup photo locally with checksum verification
backup_photo() {
    local photo_path="$1"
    local backup_path="$BACKUP_DIR/$DATE/"
    local photo_name=$(basename "$photo_path")

    verbose_log "Backing up photo locally: $photo_path"

    # Create the backup directory if it doesn't exist
    mkdir -p "$backup_path" 2>&1
    if [[ $? -ne 0 ]]; then
        local error_msg="Failed to create backup directory: $backup_path"
        verbose_log "$error_msg"
        log "Error: $error_msg"
        notify_slack "<@U0RSCG38X> Backup directory creation failed\nPath: $backup_path\nPossible USB drive failure"
        return 1
    fi

    # Calculate checksum of the original file
    local original_checksum
    original_checksum=$(md5sum "$photo_path" | awk '{print $1}')
    if [[ -z "$original_checksum" ]]; then
        verbose_log "Failed to calculate checksum for original file: $photo_path"
        log "Error: Failed to calculate checksum for original file: $photo_path"
        notify_slack "<@U0RSCG38X> Checksum calculation failed\nFile: $photo_name"
        return 1
    fi

    # Attempt to move the file to the backup directory
    local mv_error=$(mv "$photo_path" "$backup_path" 2>&1)
    if [[ $? -ne 0 ]]; then
        verbose_log "Failed to move photo to backup directory: $backup_path"
        log "Error: Failed to back up photo: $photo_path"
        notify_slack "<@U0RSCG38X> Failed to backup photo\nFile: $photo_name\nError: $mv_error\nPossible USB drive failure"
        return 1
    fi

    # Verify the file in the backup directory
    local backup_checksum
    backup_checksum=$(md5sum "$backup_path/$photo_name" | awk '{print $1}')
    if [[ -z "$backup_checksum" ]]; then
        verbose_log "Failed to calculate checksum for backup file: $backup_path/$photo_name"
        log "Error: Failed to calculate checksum for backup file: $backup_path/$photo_name"
        notify_slack "<@U0RSCG38X> Backup checksum verification failed\nFile: $photo_name\nPossible USB drive failure"
        return 1
    fi

    if [[ "$original_checksum" != "$backup_checksum" ]]; then
        verbose_log "Checksum mismatch: Backup may be corrupted. Original: $original_checksum, Backup: $backup_checksum"
        log "Error: Backup verification failed for photo: $photo_path"
        notify_slack "<@U0RSCG38X> Backup verification failed\nFile: $photo_name\nOriginal checksum: $original_checksum\nBackup checksum: $backup_checksum\nPossible USB drive failure"
        return 1
    fi

    verbose_log "Photo backed up and verified successfully: $backup_path$photo_name"
    log "Photo backed up and verified locally: $backup_path$photo_name"
    return 0
}


# Generate thumbnail for a photo with time label
generate_thumbnail() {
    local photo_path="$1"
    local photo_name=$(basename "$photo_path" | tr -d '\n')  # Clean the basename
    local raw_time=$(echo "$photo_name" | cut -d'_' -f3 | cut -d'.' -f1)  # Extract raw time part (HHMM)

    # Reformat time to HH:MM (24-hour format)
    local formatted_time="${raw_time:0:2}:${raw_time:2:2}"

    # Thumbnail directory and path
    local thumbnail_dir="$THUMBNAIL_DIR/$DATE"
    local thumbnail_path="$thumbnail_dir/$photo_name"

    verbose_log "Generating thumbnail for photo: $photo_path"

    # Create the thumbnail directory
    mkdir -p "$thumbnail_dir"
    if [ $? -ne 0 ]; then
        verbose_log "Failed to create thumbnail directory: $thumbnail_dir"
        log "Error: Failed to create thumbnail directory: $thumbnail_dir"
        notify_slack "Error creating thumbnail directory: $thumbnail_dir"
        return 1
    fi

    # Create the thumbnail with formatted time label
    convert "$photo_path" -thumbnail 200x200 -pointsize 20 -fill yellow -gravity north \
        -annotate +0+0 "$formatted_time" "$thumbnail_path"

    if [ $? -eq 0 ]; then
        verbose_log "Thumbnail generated: $thumbnail_path"
        log "Thumbnail generated with time label: $thumbnail_path"
        return 0
    else
        verbose_log "Failed to generate thumbnail for photo: $photo_path"
        log "Error: Thumbnail generation failed for: $photo_path"
        notify_slack "Thumbnail generation failed for photo: $photo_path"
        return 1
    fi
}

# End-of-day sync function with robust logging and summary report
end_of_day_sync() {
    local backup_folder_path="$BACKUP_DIR/$DATE"
    local remote_folder_path="$GDRIVE_REMOTE:$PROJECT_NAME/Daily Photos/$CURRENT_MONTH/$DATE"
    local failed_uploads_folder="/mnt/BackupArchive/$DATE"
    local logs_folder="/home/admin/logs"
    local logs_remote_folder="$GDRIVE_REMOTE:$PROJECT_NAME/Logs"
    
    verbose_log "Starting End-of-Day Sync for $DATE"
    log "Starting End-of-Day Sync for $DATE"

    # Initialize counters
    local_total_files=0
    total_remote_files=0
    remote_files_present=0
    successful_uploads=0
    failed_uploads=0

    # Ensure the failed uploads folder exists
    mkdir -p "$failed_uploads_folder"

    # Populate remote files list
    verbose_log "Fetching file list from remote folder: $remote_folder_path"
    remote_files_list=$(rclone lsf "$remote_folder_path" 2>/dev/null || echo "")
    
    # Count only jpg files on remote
    if [[ -n "$remote_files_list" ]]; then
        total_remote_files=$(echo "$remote_files_list" | grep -c "\.jpg$" || echo "0")
    else
        total_remote_files=0
    fi

    # Check if backup folder exists
    if [ ! -d "$backup_folder_path" ]; then
        verbose_log "No backup folder found for today at $backup_folder_path. Skipping sync."
        log "No backup folder found for today at $backup_folder_path. Skipping sync."
        notify_slack "📁 No backup folder found for today ($DATE). End-of-Day Sync skipped."
        return
    fi

    # Count local files before sync
    local_total_files=$(find "$backup_folder_path" -type f -name "*.jpg" 2>/dev/null | wc -l)
    
    # Count how many local files are already on remote
    if [[ -n "$remote_files_list" ]]; then
        for file in "$backup_folder_path"/*.jpg; do
            if [ -f "$file" ]; then
                file_name=$(basename "$file")
                if echo "$remote_files_list" | grep -q "^$file_name$"; then
                    remote_files_present=$((remote_files_present + 1))
                fi
            fi
        done
    fi

    verbose_log "Before sync - Local: $local_total_files, Remote: $total_remote_files, Already synced: $remote_files_present"

    # Iterate through local backup files to upload missing ones
    for file in "$backup_folder_path"/*.jpg; do
        # Check if glob matched any files
        if [ ! -f "$file" ]; then
            continue
        fi
        
        file_name=$(basename "$file")

        # Check if file exists on remote
        if [[ -n "$remote_files_list" ]] && echo "$remote_files_list" | grep -q "^$file_name$"; then
            # Already on remote, skip
            continue
        else
            # Attempt to upload missing file
            verbose_log "Uploading missing file: $file"
            if rclone copy "$file" "$remote_folder_path" --low-level-retries 3 --retries 3 --progress 2>/dev/null; then
                successful_uploads=$((successful_uploads + 1))
                verbose_log "Successfully uploaded: $file"
                log "Successfully uploaded: $file"
            else
                failed_uploads=$((failed_uploads + 1))
                verbose_log "Failed to upload: $file"
                log "Upload failed for file: $file"

                # Move file to failed uploads folder
                if mv "$file" "$failed_uploads_folder" 2>/dev/null; then
                    verbose_log "Moved failed file to: $failed_uploads_folder"
                fi
            fi
        fi
    done

    # Copy the logs to Google Drive
    verbose_log "Copying logs to remote Google Drive folder: $logs_remote_folder"
    if rclone copy "$logs_folder" "$logs_remote_folder" --progress 2>/dev/null; then
        verbose_log "Successfully copied logs to Google Drive."
        log "Successfully copied logs to Google Drive."
    else
        verbose_log "Failed to copy logs to Google Drive."
        log "Failed to copy logs to Google Drive."
    fi

    # Rotate logs
    if [ -f "$LOG_FILE" ]; then
        mv "$LOG_FILE" "$LOG_FILE.$(date +%Y-%m-%d)"
    fi
    touch "$LOG_FILE"

    # ===== VERIFY FINAL STATE =====
    verbose_log "Verifying final state..."
    
    # Re-fetch remote file list to get actual final count
    local final_remote_files_list=$(rclone lsf "$remote_folder_path" 2>/dev/null || echo "")
    local final_remote_total=0
    if [[ -n "$final_remote_files_list" ]]; then
        final_remote_total=$(echo "$final_remote_files_list" | grep -c "\.jpg$" || echo "0")
    fi
    
    # Count remaining local files
    local final_local_total=$(find "$backup_folder_path" -type f -name "*.jpg" 2>/dev/null | wc -l)
    
    # Verify each uploaded file actually exists on remote
    local verified_uploads=0
    local unverified_uploads=0
    
    if [ "$successful_uploads" -gt 0 ]; then
        verbose_log "Verifying uploaded files exist on remote..."
        # We need to track which files we uploaded - let's check the log
        # For now, we'll trust the upload count if final remote count increased appropriately
        local expected_remote_total=$((total_remote_files + successful_uploads))
        if [ "$final_remote_total" -eq "$expected_remote_total" ]; then
            verified_uploads=$successful_uploads
            verbose_log "✓ All uploads verified on remote"
        else
            verbose_log "⚠ Warning: Remote file count mismatch. Expected: $expected_remote_total, Actual: $final_remote_total"
            unverified_uploads=$successful_uploads
        fi
    fi
    
    # Generate the summary report
    verbose_log "End-of-Day Sync Summary:"
    verbose_log "Initial state - Local: $local_total_files, Remote: $total_remote_files"
    verbose_log "Files already synced: $remote_files_present"
    verbose_log "Files successfully uploaded: $successful_uploads"
    verbose_log "Files failed to upload: $failed_uploads"
    verbose_log "Final state (verified) - Local: $final_local_total, Remote: $final_remote_total"

    log "End-of-Day Sync Summary:"
    log "Initial state - Local: $local_total_files, Remote: $total_remote_files"
    log "Files already synced: $remote_files_present"
    log "Files successfully uploaded: $successful_uploads"
    log "Files failed to upload: $failed_uploads"
    log "Final state (verified) - Local: $final_local_total, Remote: $final_remote_total"

    # Build Slack message with verified data
    local slack_message="📊 *End-of-Day Sync Report* - $DATE\n\n"
    slack_message+="*Initial Status:*\n"
    slack_message+="💾 Local backup: $local_total_files images\n"
    slack_message+="☁️ Google Drive: $total_remote_files images\n"
    slack_message+="✓ Already synced: $remote_files_present images\n\n"
    
    slack_message+="*Sync Activity:*\n"
    if [ "$successful_uploads" -gt 0 ]; then
        if [ "$unverified_uploads" -gt 0 ]; then
            slack_message+="⚠️ Uploaded: $successful_uploads images (verification mismatch)\n"
        else
            slack_message+="⬆️ Uploaded: $successful_uploads images ✅\n"
        fi
    fi
    if [ "$failed_uploads" -gt 0 ]; then
        slack_message+="❌ Failed: $failed_uploads images (moved to USB backup)\n"
    fi
    if [ "$successful_uploads" -eq 0 ] && [ "$failed_uploads" -eq 0 ]; then
        slack_message+="✓ All files already synced - no action needed\n"
    fi
    
    slack_message+="\n*Final Status (Verified):*\n"
    slack_message+="💾 Local backup: $final_local_total images\n"
    slack_message+="☁️ Google Drive: $final_remote_total images"
    
    if [ "$failed_uploads" -gt 0 ]; then
        slack_message+="\n\n⚠️ $failed_uploads files moved to USB backup folder"
    fi
    
    if [ "$unverified_uploads" -gt 0 ]; then
        slack_message+="\n\n⚠️ Warning: Remote file count doesn't match expected value"
    fi

    # Notify via Slack with verified data
    notify_slack "$slack_message"

    verbose_log "End-of-Day Sync for $DATE completed."
    log "End-of-Day Sync for $DATE completed."

    # After upload, run the cleanup process
    cleanup_uploaded_files
}

#Remove any local files that have been uploaded to google drive.
cleanup_uploaded_files() {
    local backup_folder_path="$BACKUP_DIR/$DATE"

    verbose_log "Starting cleanup of uploaded files in: $backup_folder_path"

    for file in "$backup_folder_path"/*; do
        if [ -f "$file" ]; then
            local remote_file_path="$GDRIVE_REMOTE:$PROJECT_NAME/Daily Photos/$CURRENT_MONTH/$DATE/$(basename "$file")"
            
            verbose_log "Checking remote existence for: $remote_file_path"
            if rclone ls "$remote_file_path" &>/dev/null; then
                verbose_log "File exists on remote: $remote_file_path. Attempting to delete local copy: $file"
                if rm -f "$file"; then
                    log "Deleted local file after confirmation: $file"
                else
                    log "Failed to delete local file: $file"
                fi
            else
                verbose_log "File not found on remote: $remote_file_path. Skipping deletion for: $file"
                log "Skipped deletion. File not found on remote: $file"
            fi
        fi
    done

    verbose_log "Cleanup process completed for: $backup_folder_path"
}

# Create daily montage of thumbnails
create_daily_montage() {
    verbose_log "Creating daily montage."

    # Format the current date as "Jan 23, 2025"
    local human_readable_date=$(date +"%b %d, %Y")
    local formatted_date=$(date +"%d-%m-%Y")
    local month=$(date +"%B")  # Get the month (e.g., January)

    # Define the thumbnail directory for today
    local thumbnail_dir="$THUMBNAIL_DIR/$DATE"

    # Check if the thumbnail directory exists
    if [ ! -d "$thumbnail_dir" ]; then
        verbose_log "No thumbnails found for today."
        log "No thumbnails found for today."
        notify_slack "No thumbnails found for today."
        return
    fi

    # Find and sort thumbnails for today by modification time (earliest to latest)
    local today_thumbnails=($(find "$thumbnail_dir" -type f -name "*.jpg" | xargs ls -rt))

    # Check if any thumbnails were found
    if [ ${#today_thumbnails[@]} -eq 0 ]; then
        verbose_log "No thumbnails found for today."
        log "No thumbnails found for today."
        notify_slack "No thumbnails found for today."
        return
    fi

    # Create the montage with the sorted thumbnails, limiting to 6 images horizontally
    local temp_montage="$THUMBNAIL_DIR/temp_montage.jpg"
    montage "${today_thumbnails[@]}" -tile 6x -geometry +2+2 "$temp_montage" || {
        verbose_log "montage command failed."
        log "montage command failed."
        notify_slack "<@U0RSCG38X> montage command failed."
        return
    }

    # Add heading with the formatted human-readable date to the montage
    convert "$temp_montage" -gravity north -background white -splice 0x40 -annotate +0+10 "Daily Review: $human_readable_date" "$DAILY_MONTAGE" || {
        verbose_log "convert command failed."
        log "convert command failed."
        notify_slack "convert command failed."
        return
    }

    # Clean up temporary files
    rm "$temp_montage" || {
        verbose_log "Failed to remove temporary file."
        log "Failed to remove temporary file."
        notify_slack "Failed to remove temporary file."
    }

    verbose_log "Daily montage created: $DAILY_MONTAGE"
    log "Daily montage created: $DAILY_MONTAGE"

    # Send daily report via Slack and email
    send_daily_report "$DAILY_MONTAGE"
    send_email "$DAILY_MONTAGE"

    # Define paths for uploading to Google Drive and renaming
    local renamed_montage_path="/home/admin/$formatted_date.jpg"
    local remote_file_path="$GDRIVE_REMOTE:$PROJECT_NAME/Daily Reviews/$month/$formatted_date.jpg"

    # Rename the daily montage file
    mv "$DAILY_MONTAGE" "$renamed_montage_path" || {
        verbose_log "Failed to rename daily montage file."
        log "Failed to rename daily montage file."
        notify_slack "Failed to rename daily montage file."
        return
    }

    # Upload the renamed daily montage to Google Drive with the correct filename
    if rclone copyto "$renamed_montage_path" "$remote_file_path" --progress; then
        verbose_log "Daily montage uploaded to Google Drive: $remote_file_path"
        log "Daily montage uploaded to Google Drive: $remote_file_path"
        
        # Clean up: remove the renamed local file after successful upload
        rm "$renamed_montage_path" || {
            verbose_log "Failed to remove renamed local file."
            log "Failed to remove renamed local file."
            notify_slack "Failed to remove renamed local file."
        }
    else
        verbose_log "Failed to upload daily montage to Google Drive."
        log "Failed to upload daily montage to Google Drive."

        # Try to save to USB backup if available
        if [[ -n "$DEVICE" ]] && [[ -b "$DEVICE" ]]; then
            verbose_log "USB device detected, attempting to mount and backup montage"
            
            if ! mountpoint -q "$MOUNT_POINT"; then
                mkdir -p "$MOUNT_POINT"
                if mount "$DEVICE" "$MOUNT_POINT" 2>/dev/null; then
                    verbose_log "USB mounted successfully"
                    local usb_backup_folder="$MOUNT_POINT/Daily Reviews/$month"
                    mkdir -p "$usb_backup_folder"
                    
                    if mv "$renamed_montage_path" "$usb_backup_folder"; then
                        verbose_log "Moved failed daily montage to USB backup folder: $usb_backup_folder"
                        log "Moved failed daily montage to USB backup folder: $usb_backup_folder"
                        notify_slack "Daily montage upload to Google Drive failed, saved to USB backup instead"
                    else
                        verbose_log "Failed to move daily montage to USB backup folder."
                        log "Failed to move daily montage to USB backup folder."
                        notify_slack "Failed to upload daily montage to Google Drive AND failed to save to USB backup"
                    fi
                    
                    umount "$MOUNT_POINT" 2>/dev/null
                else
                    verbose_log "Failed to mount USB device"
                    log "Failed to mount USB device"
                    notify_slack "Daily montage upload failed and USB mount failed. File kept at: $renamed_montage_path"
                fi
            fi
        else
            verbose_log "No USB device available for backup. File kept at: $renamed_montage_path"
            log "No USB device available for backup. File kept at: $renamed_montage_path"
            notify_slack "Daily montage upload failed and no USB backup available. File kept at: $renamed_montage_path"
        fi
        
        return
    fi

    # Clear the thumbnails and the folder for the day
    rm -rf "$thumbnail_dir" || {
        verbose_log "Failed to clear thumbnails for the day."
        log "Failed to clear thumbnails for the day."
        notify_slack "Failed to clear thumbnails for the day."
    }

    verbose_log "Thumbnails for the day cleared."
    log "Thumbnails for the day cleared."
}


# Send daily report via Slack
send_daily_report() {
    local montage_path="$1"
    report_data=$(count_images_for_report)
    verbose_log "Sending daily report."
    #curl -X POST -H 'Content-type: application/json' \
    #    --data '{"text":"Daily Report: '"$report_data"'"}' "$SLACK_WEBHOOK"
    if [ $? -eq 0 ]; then
        verbose_log "Daily report sent successfully."
        log "Daily report sent."
    else
        verbose_log "Failed to send daily report."
        log "Failed to send daily report."
    fi
}

# Function to count images for the end-of-day report
count_images_for_report() {
    # Define Google Drive folder and USB backup folder paths
    local google_drive_folder="$GDRIVE_REMOTE:$PROJECT_NAME/Daily Photos/$CURRENT_MONTH/$DATE"
    local usb_backup_folder="/mnt/BackupArchive/$DATE"
    
    # Initialize image counts
    local google_drive_count=0
    local usb_backup_count=0
    
    # Count images in the Google Drive folder using rclone (all .jpg files)
    google_drive_count=$(rclone lsf "$google_drive_folder" --files-only --include "*.jpg" 2>/dev/null | wc -l)
    
    # Only check USB if device exists and can be mounted
    if [[ -n "$DEVICE" ]] && [[ -b "$DEVICE" ]]; then
        # Check if already mounted
        local was_mounted=false
        if mountpoint -q "$MOUNT_POINT"; then
            was_mounted=true
            verbose_log "USB already mounted"
        else
            # Try to mount
            mkdir -p "$MOUNT_POINT"
            if mount "$DEVICE" "$MOUNT_POINT" 2>/dev/null; then
                verbose_log "USB mounted for image count"
            else
                verbose_log "Failed to mount USB for image count"
                log "Failed to mount USB device for image count"
                # Continue without USB count
                echo "Images for today on Google Drive: $google_drive_count, Images for today on USB Backup: N/A (USB not available)"
                return
            fi
        fi
        
        # Check if USB backup folder exists and count images there
        if [ -d "$usb_backup_folder" ]; then
            usb_backup_count=$(find "$usb_backup_folder" -type f -name "*.jpg" 2>/dev/null | wc -l)
        else
            usb_backup_count=0
        fi
        
        # Unmount only if we mounted it
        if [[ "$was_mounted" == "false" ]]; then
            umount "$MOUNT_POINT" 2>/dev/null
            verbose_log "USB unmounted after image count"
        fi
    else
        verbose_log "USB device not available for image count"
        # Return count without USB
        echo "Images for today on Google Drive: $google_drive_count, Images for today on USB Backup: N/A (USB not available)"
        return
    fi
    
    # Format the result as a string to pass to the send email or report functions
    echo "Images for today on Google Drive: $google_drive_count, Images for today on USB Backup: $usb_backup_count"
}


cleanup_directories() {
    # Define the directories to clean up
    local directories=(
        "/home/admin/backups"
        "/home/admin/photos/$PROJECT_NAME/Daily Photos/$CURRENT_MONTH"
        "/mnt/BackupArchive/"
    )

    # Iterate through each specified directory
    for dir in "${directories[@]}"; do
        echo "Checking directory: $dir"
        
        # Iterate over all subdirectories in the current directory
        for folder in "$dir"/*; do
            # Check if it is a directory and is empty
            if [ -d "$folder" ] && [ "$(ls -A "$folder")" == "" ]; then
                echo "Deleting empty folder: $folder"
                rm -rf "$folder"
            fi
        done
    done

    echo "Cleanup complete."
}

########################################
# 3) TEST FUNCTIONS
########################################

# Test backup failure scenario
test_backup_failure_scenario() {
    verbose_log "═══════════════════════════════════════════════"
    verbose_log "  TESTING BACKUP FAILURE SCENARIO"
    verbose_log "═══════════════════════════════════════════════"
    echo
    
    # Create a test photo
    local test_photo_dir="/tmp/timelapse_test"
    mkdir -p "$test_photo_dir"
    
    # Generate a dummy image
    convert -size 800x600 xc:blue -pointsize 50 -fill white -gravity center \
        -annotate +0+0 "TEST PHOTO\n$(date)" "$test_photo_dir/test_photo.jpg"
    
    verbose_log "Created test photo: $test_photo_dir/test_photo.jpg"
    
    # Simulate the upload failure by using a fake remote
    local original_remote="$GDRIVE_REMOTE"
    GDRIVE_REMOTE="FAKE_REMOTE_THAT_DOES_NOT_EXIST"
    
    verbose_log "Temporarily using fake remote: $GDRIVE_REMOTE"
    verbose_log "This will cause upload to fail..."
    echo
    
    # Try to upload (will fail)
    if upload_photo "$test_photo_dir/test_photo.jpg"; then
        log "ERROR: Upload should have failed but succeeded!"
    else
        verbose_log "Upload failed as expected ✓"
    fi
    
    # Process the photo (should backup to USB)
    verbose_log "Processing photo (should backup to USB)..."
    process_photo "$test_photo_dir/test_photo.jpg"
    
    # Restore original remote
    GDRIVE_REMOTE="$original_remote"
    
    echo
    verbose_log "═══════════════════════════════════════════════"
    verbose_log "  TEST RESULTS"
    verbose_log "═══════════════════════════════════════════════"
    echo
    
    # Check where the file ended up
    echo "Checking backup locations:"
    echo
    
    if [ -f "$BACKUP_DIR/$DATE/test_photo.jpg" ]; then
        echo "✓ Found in local backup: $BACKUP_DIR/$DATE/test_photo.jpg"
        ls -lh "$BACKUP_DIR/$DATE/test_photo.jpg"
    else
        echo "✗ NOT found in local backup"
    fi
    
    echo
    
    if [ -f "/mnt/BackupArchive/$DATE/test_photo.jpg" ]; then
        echo "✓ Found in USB backup: /mnt/BackupArchive/$DATE/test_photo.jpg"
        ls -lh "/mnt/BackupArchive/$DATE/test_photo.jpg"
    else
        echo "✗ NOT found in USB backup"
    fi
    
    echo
    
    # Check thumbnail
    if [ -f "$THUMBNAIL_DIR/$DATE/test_photo.jpg" ]; then
        echo "✓ Thumbnail created: $THUMBNAIL_DIR/$DATE/test_photo.jpg"
        ls -lh "$THUMBNAIL_DIR/$DATE/test_photo.jpg"
    else
        echo "✗ Thumbnail NOT created"
    fi
    
    echo
    verbose_log "═══════════════════════════════════════════════"
    
    # Cleanup
    read -p "Delete test files? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "$BACKUP_DIR/$DATE/test_photo.jpg"
        rm -f "/mnt/BackupArchive/$DATE/test_photo.jpg"
        rm -f "$THUMBNAIL_DIR/$DATE/test_photo.jpg"
        rm -rf "$test_photo_dir"
        verbose_log "Test files cleaned up"
    else
        verbose_log "Test files kept for inspection"
    fi
}

# Test camera connection
test_camera() {
    verbose_log "═══════════════════════════════════════════════"
    verbose_log "  TESTING CAMERA CONNECTION"
    verbose_log "═══════════════════════════════════════════════"
    echo
    
    verbose_log "Detecting camera..."
    gphoto2 --auto-detect
    
    if gphoto2 --auto-detect | grep -q "usb:"; then
        echo
        verbose_log "✓ Camera detected"
        echo
        read -p "Attempt test capture? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            verbose_log "Attempting test capture..."
            if gphoto2 --capture-image-and-download --filename /tmp/test_capture.jpg; then
                if [ -f /tmp/test_capture.jpg ]; then
                    verbose_log "✓ Test capture successful"
                    ls -lh /tmp/test_capture.jpg
                    rm /tmp/test_capture.jpg
                else
                    verbose_log "✗ Test capture failed - file not created"
                fi
            else
                verbose_log "✗ Test capture command failed"
            fi
        fi
    else
        echo
        verbose_log "✗ No camera detected"
        verbose_log "Check:"
        verbose_log "  - Camera is connected via USB"
        verbose_log "  - Camera is powered on"
        verbose_log "  - Camera is not in mass storage mode"
    fi
}

# Test Google Drive upload
test_upload() {
    verbose_log "═══════════════════════════════════════════════"
    verbose_log "  TESTING GOOGLE DRIVE UPLOAD"
    verbose_log "═══════════════════════════════════════════════"
    echo
    
    verbose_log "Creating test file..."
    echo "test $(date)" > /tmp/test_upload.txt
    
    verbose_log "Uploading to Google Drive..."
    if rclone copy /tmp/test_upload.txt "$GDRIVE_REMOTE:test/" --progress; then
        verbose_log "✓ Upload successful"
        
        verbose_log "Verifying file exists..."
        if rclone ls "$GDRIVE_REMOTE:test/test_upload.txt" &>/dev/null; then
            verbose_log "✓ File verified on Google Drive"
            
            verbose_log "Cleaning up..."
            rclone delete "$GDRIVE_REMOTE:test/test_upload.txt"
            rclone rmdir "$GDRIVE_REMOTE:test/"
            verbose_log "✓ Cleanup complete"
        else
            verbose_log "✗ File not found on Google Drive"
        fi
    else
        verbose_log "✗ Upload failed"
        verbose_log "Check:"
        verbose_log "  - rclone configuration: sudo rclone config"
        verbose_log "  - Internet connection"
        verbose_log "  - Service account has access to Drive folder"
    fi
    
    rm -f /tmp/test_upload.txt
}

# Test email
test_email() {
    verbose_log "═══════════════════════════════════════════════"
    verbose_log "  TESTING EMAIL"
    verbose_log "═══════════════════════════════════════════════"
    echo
    
    read -p "Send test email to $EMAIL_RECIPIENTS? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        verbose_log "Test cancelled"
        return
    fi
    
    verbose_log "Sending test email..."
    echo -e "Subject: Test from timelapse\n\nTest email sent at $(date)\n\nIf you received this, email is working correctly." | msmtp "$EMAIL_RECIPIENTS"
    
    if [ $? -eq 0 ]; then
        verbose_log "✓ Email sent successfully"
        verbose_log "Check inbox/spam folder for: $EMAIL_RECIPIENTS"
        echo
        verbose_log "Email log:"
        tail -5 /root/.msmtp.log
    else
        verbose_log "✗ Email failed"
        verbose_log "Check /root/.msmtp.log for details:"
        tail -10 /root/.msmtp.log
    fi
}

# Test USB drive
test_usb() {
    verbose_log "═══════════════════════════════════════════════"
    verbose_log "  TESTING USB BACKUP DRIVE"
    verbose_log "═══════════════════════════════════════════════"
    echo
    
    verbose_log "USB device: $DEVICE"
    verbose_log "Mount point: $MOUNT_POINT"
    echo
    
    if mountpoint -q "$MOUNT_POINT"; then
        verbose_log "✓ USB already mounted at $MOUNT_POINT"
        df -h "$MOUNT_POINT"
    else
        verbose_log "Attempting to mount USB drive..."
        mkdir -p "$MOUNT_POINT"
        if mount "$DEVICE" "$MOUNT_POINT"; then
            verbose_log "✓ USB mounted successfully"
            df -h "$MOUNT_POINT"
            
            # Test write
            verbose_log "Testing write access..."
            if echo "test" > "$MOUNT_POINT/test_write.txt" 2>/dev/null; then
                verbose_log "✓ Write access confirmed"
                rm -f "$MOUNT_POINT/test_write.txt"
            else
                verbose_log "✗ Write access failed"
            fi
            
            umount "$MOUNT_POINT"
            verbose_log "USB unmounted"
        else
            verbose_log "✗ USB mount failed"
            verbose_log "Check:"
            verbose_log "  - USB drive is connected"
            verbose_log "  - USB label matches: $USB_BACKUP_LABEL"
            verbose_log "  - Device exists: ls -l $DEVICE"
        fi
    fi
}

# Test USB write
test_usb_write() {
    verbose_log "═══════════════════════════════════════════════"
    verbose_log "  TESTING USB WRITE"
    verbose_log "═══════════════════════════════════════════════"
    echo
    
    verbose_log "USB device: $DEVICE"
    verbose_log "Mount point: $MOUNT_POINT"
    echo
    
    # Check if already mounted
    if mountpoint -q "$MOUNT_POINT"; then
        verbose_log "✓ USB already mounted at $MOUNT_POINT"
    else
        verbose_log "Attempting to mount USB drive..."
        mkdir -p "$MOUNT_POINT"
        if ! mount "$DEVICE" "$MOUNT_POINT" 2>/dev/null; then
            verbose_log "✗ USB mount failed"
            verbose_log "Check:"
            verbose_log "  - USB drive is connected"
            verbose_log "  - USB label matches: $USB_BACKUP_LABEL"
            verbose_log "  - Device exists: ls -l $DEVICE"
            return 1
        fi
        verbose_log "✓ USB mounted successfully"
    fi
    
    echo
    verbose_log "Disk space on USB:"
    df -h "$MOUNT_POINT"
    echo
    
    # Create test directory
    local test_dir="$MOUNT_POINT/test_write_$(date +%s)"
    verbose_log "Creating test directory: $test_dir"
    
    if mkdir -p "$test_dir"; then
        verbose_log "✓ Directory created successfully"
    else
        verbose_log "✗ Failed to create directory"
        return 1
    fi
    
    # Test 1: Write small text file
    verbose_log "Test 1: Writing small text file..."
    local test_file="$test_dir/test.txt"
    if echo "Test write at $(date)" > "$test_file"; then
        verbose_log "✓ Small file write successful"
        ls -lh "$test_file"
    else
        verbose_log "✗ Small file write failed"
        rm -rf "$test_dir"
        return 1
    fi
    
    # Test 2: Write image file (simulates photo)
    verbose_log "Test 2: Writing test image (simulates photo backup)..."
    local test_image="$test_dir/test_photo.jpg"
    
    # Create a test image
    convert -size 800x600 xc:blue -pointsize 30 -fill white -gravity center \
        -annotate +0+0 "USB Write Test\n$(date)" "$test_image" 2>/dev/null
    
    if [ -f "$test_image" ]; then
        verbose_log "✓ Image write successful"
        ls -lh "$test_image"
        
        # Verify checksum
        local checksum=$(md5sum "$test_image" | awk '{print $1}')
        verbose_log "  Checksum: $checksum"
    else
        verbose_log "✗ Image write failed"
        rm -rf "$test_dir"
        return 1
    fi
    
    # Test 3: Read back and verify
    verbose_log "Test 3: Reading back files to verify..."
    if cat "$test_file" > /dev/null && [ -f "$test_image" ]; then
        verbose_log "✓ Read verification successful"
    else
        verbose_log "✗ Read verification failed"
        rm -rf "$test_dir"
        return 1
    fi
    
    echo
    verbose_log "═══════════════════════════════════════════════"
    verbose_log "  USB WRITE TEST RESULTS"
    verbose_log "═══════════════════════════════════════════════"
    echo "✓ USB drive is mounted and writable"
    echo "✓ Can create directories"
    echo "✓ Can write text files"
    echo "✓ Can write image files"
    echo "✓ Can read files back"
    echo
    verbose_log "Test files location: $test_dir"
    echo
    
    # Cleanup
    read -p "Delete test files? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$test_dir"
        verbose_log "✓ Test files cleaned up"
    else
        verbose_log "Test files kept at: $test_dir"
    fi
    
    # Unmount if we mounted it
    if ! mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" 2>/dev/null
        verbose_log "USB unmounted"
    fi
}

# Run all tests
test_all() {
    verbose_log "═══════════════════════════════════════════════"
    verbose_log "  RUNNING ALL TESTS"
    verbose_log "═══════════════════════════════════════════════"
    echo
    
    test_camera
    echo
    echo "Press Enter to continue to next test..."
    read
    
    test_upload
    echo
    echo "Press Enter to continue to next test..."
    read
    
    test_email
    echo
    echo "Press Enter to continue to next test..."
    read
    
    test_usb
    echo
    echo "Press Enter to continue to next test..."
    read

    test_usb_write
    echo
    echo "Press Enter to continue to next test..."
    read
    
    test_backup_failure_scenario
    
    echo
    verbose_log "═══════════════════════════════════════════════"
    verbose_log "  ALL TESTS COMPLETE"
    verbose_log "═══════════════════════════════════════════════"
}

########################################
# 4) SINGLE COMMAND DISPATCHER
########################################
case "${1:-}" in
  setup)
    shift
    cmd_setup "$@"
    ;;
  add-wifi)
    cmd_add_wifi
    ;;
  change-interval)
    shift
    cmd_interval "$@"
    ;;
  capture|start)
    verbose_log "Starting photo capture process."
    take_photo
    verbose_log "Photo capture process completed."
    ;;
  end_of_day_sync)
    verbose_log "Starting end-of-day sync process."
    end_of_day_sync
    verbose_log "End-of-day sync process completed."
    ;;
  create_daily_montage)
    verbose_log "Starting daily montage creation process."
    create_daily_montage
    verbose_log "Daily montage creation process completed."
    ;;
  cleanup_directories)
    verbose_log "Cleaning directories started."
    cleanup_directories
    verbose_log "Cleaning directories completed."
    ;;
  count)
    verbose_log "Counting."
    count_images_for_report
    verbose_log "Done."
    ;;
  status)
    echo "Timelapse System Status"
    echo "======================="
    echo
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "Configuration:"
        cat "$CONFIG_FILE"
    else
        echo "Not configured. Run: timelapse setup"
    fi
    echo
    echo "Cron jobs:"
    if [[ -f "$CRON_FILE" ]]; then
        cat "$CRON_FILE"
    else
        echo "No cron jobs installed"
    fi
    echo
    echo "Recent log entries:"
    if [[ -f "$LOG_FILE" ]]; then
        tail -10 "$LOG_FILE"
    else
        echo "No log file found"
    fi
    ;;
  reset-mention-cooldown)
    if [[ -f "$MENTION_COOLDOWN_FILE" ]]; then
        rm -f "$MENTION_COOLDOWN_FILE"
        echo "Mention cooldown reset - next error will ping user"
    else
        echo "No active cooldown"
    fi
    ;;
  test-backup-failure)
    test_backup_failure_scenario
    ;;
  test-camera)
    test_camera
    ;;
  test-upload)
    test_upload
    ;;
  test-email)
    test_email
    ;;
  test-usb)
    test_usb
    ;;
  test-usb-write)
    test_usb_write
    ;;
  test-all)
    test_all
    ;;
  update)
    verbose_log "Updating timelapse script to latest version."
    curl -fsSL https://raw.githubusercontent.com/trendykendy/pilapse/main/timelapse.sh -o /tmp/timelapse-new
    if [[ -s /tmp/timelapse-new ]]; then
        sudo cp /tmp/timelapse-new /usr/local/bin/timelapse
        sudo chmod +x /usr/local/bin/timelapse
        rm /tmp/timelapse-new
        verbose_log "Updated to latest version"
    else
        verbose_log "Update failed"
    fi
    ;;

  *)
    cat <<EOF
Usage: timelapse COMMAND

Setup Commands:
  setup                    - Configure project and schedule
  add-wifi                 - Add WiFi network
  change-interval [MINS]   - Change capture interval

Operation Commands:
  capture                  - Take a photo now
  end_of_day_sync          - Sync today's photos to Google Drive
  create_daily_montage     - Create and send daily review
  cleanup_directories      - Clean up empty directories
  count                    - Count images for today
  status                   - Show system status

Testing Commands:
  test-backup-failure      - Simulate upload failure and test USB backup
  test-camera              - Test camera connection and capture
  test-upload              - Test Google Drive upload
  test-email               - Test email sending
  test-usb                 - Test USB drive mount
  test-usb-write           - Test USB write capability
  test-all                 - Run all tests

Examples:
  timelapse setup
  timelapse add-wifi
  timelapse capture
  timelapse test-all
EOF
    exit 1
    ;;
esac

# End of script
