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
# WiFi configuration handler (separate command)
# 
cmd_add_wifi() {
  echo
  echo "═══════════════════════════════════════════════════════"
  echo "  ADD WIFI NETWORK"
  echo "═══════════════════════════════════════════════════════"
  echo
  
  configure_wifi
  
  exit 0
}

configure_wifi() {
  # Check if wpa_supplicant.conf exists
  WPA_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"
  
  if [[ ! -f "$WPA_CONF" ]]; then
    # Create basic wpa_supplicant.conf if it doesn't exist
    sudo bash -c "cat > '$WPA_CONF' <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=IE

EOF"
    echo "Created new wpa_supplicant.conf"
  fi
  
  # Show current networks
  echo "Current WiFi networks:"
  if grep -q "^network=" "$WPA_CONF"; then
    grep "ssid=" "$WPA_CONF" | sed 's/.*ssid="\(.*\)".*/  - \1/'
  else
    echo "  (none configured)"
  fi
  echo
  
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
    echo "Adding network: $wifi_ssid"
    
    # Use wpa_passphrase to generate the encrypted PSK
    wpa_passphrase "$wifi_ssid" "$wifi_password" | sudo tee -a "$WPA_CONF" > /dev/null
    
    echo "✓ Added: $wifi_ssid"
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
  echo "Applying WiFi configuration..."
  sudo wpa_cli -i wlan0 reconfigure > /dev/null 2>&1 || true
  
  echo "✓ WiFi configuration complete"
  echo
  
  # Show current connection status
  echo "Current WiFi status:"
  if command -v iwgetid &> /dev/null; then
    current_ssid=$(iwgetid -r)
    if [[ -n "$current_ssid" ]]; then
      echo "  Connected to: $current_ssid"
      ip addr show wlan0 | grep "inet " | awk '{print "  IP Address: " $2}'
    else
      echo "  Not connected"
      echo "  The Pi will connect to one of the configured networks on next boot"
    fi
  fi
  echo
}

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
  sudo chmod 600 "$CONFIG_FILE"
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
      -h|--help)
        cat <<EOF
Usage: timelapse setup [--project NAME] [--usb-label LABEL] [--interval MINUTES]

  --project     : name of this timelapse project
  --usb-label   : filesystem label of your USB backup drive
  --interval    : how often (in minutes) to run 'timelapse capture'
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
        lsblk -ln -o NAME,LABEL -P \
          | grep -E 'NAME="sd[a-z][0-9]+"' \
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

        read -rp "Select a drive [1-${#devices[@]}]: " choice
        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && (( choice <= ${#devices[@]} )); then
          USB_BACKUP_LABEL="${devices[choice-1]#*:}"
          echo "Using label: $USB_BACKUP_LABEL"
          break
        else
          echo "Invalid choice." >&2
        fi

      else
        echo "No labeled USB drives found."
        read -rp "[R]etry, [M]anual entry, or [C]ancel USB setup? " ans
        case "${ans^^}" in
          R)  continue ;;
          M)  read -rp "Enter USB label manually: " USB_BACKUP_LABEL; break ;;
          C)  echo "Skipping USB setup."; break ;;
          *)  echo "Please choose R, M, or C." ;;
        esac
      fi
    done
    echo
  fi

  # interactive for anything missing
  echo "PROJECT DETAILS"
  echo "────────────────────────────────────────────────────────"
  echo
  [[ -z "$PROJECT_NAME" ]]    && read -rp "Project name: " PROJECT_NAME
  [[ -z "$USB_BACKUP_LABEL" ]]&& read -rp "USB backup label: " USB_BACKUP_LABEL
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
  if ! [[ "$START_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]] || ! [[ "$STOP_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
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
EOF"
  sudo chmod 600 "$CONFIG_FILE"
  echo
  echo "✓ Saved config to $CONFIG_FILE"

  # Calculate hour range for cron (e.g., "7-18" for 7 AM to 6 PM)
  # We subtract 1 from STOP_HOUR because cron is inclusive
  # So if you want to stop at 7 PM (19:00), last capture should be at 6:55 PM (18:55)
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
  echo "  USB Label: $USB_BACKUP_LABEL"
  echo "  Capture Interval: Every $INTERVAL_MINS minutes"
  echo "  Capture Hours: ${START_HOUR}:00 to ${STOP_HOUR}:00"
  echo
  echo "End-of-Day Schedule:"
  echo "  Photo Sync:      $SYNC_TIME"
  echo "  Daily Montage:   $MONTAGE_TIME"
  echo "  Cleanup:         $CLEANUP_TIME"
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
LOG_FILE="/home/admin/logs/timelapse.log"       # Log file
VERBOSE=true                                    # Toggle verbose output
SLACK_WEBHOOK="https://hooks.slack.com/services/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"
EMAIL_RECIPIENTS="daniel@aperturemedia.ie, sean@seankennedy.info"         # Recipient for daily montage email
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

# Helper function for logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Initialize the counter file if it doesn't exist
COUNTER_FILE="/home/admin/counter.txt"
if [ ! -f "$COUNTER_FILE" ]; then
    echo "00001" > "$COUNTER_FILE"
fi

# Function to get and increment the counter
get_next_counter() {
    COUNTER=$(cat "$COUNTER_FILE")
    printf "%05d" "$COUNTER" # Format as a 5-digit number
    echo $((COUNTER + 1)) > "$COUNTER_FILE"
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
    curl -X POST -H 'Content-type: application/json' \
        --data '{"text":"'"$message"'"}' "$SLACK_WEBHOOK"
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
    local timestamp=$(date +%Y%m%d_%H%M)  # e.g., 20250119_1330
    local photo_filename="${counter}_${timestamp}.jpg"
    local photo_path="$base_folder/$photo_filename"

    verbose_log "Attempting to capture photo: $photo_path"

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
        verbose_log "Photo capture timed out."
        log "Photo capture timed out."
    fi

    # Retry after failure or timeout
    verbose_log "Retrying photo capture in 10 seconds..."
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
            notify_slack "<@U0RSCG38X> Photo capture failed on retry."
        fi
    else
        verbose_log "Photo capture timed out on retry."
        log "Photo capture timed out on retry."
        notify_slack "<@U0RSCG38X> Photo capture timed out on retry."
    fi

    verbose_log "All attempts to capture the photo have failed."
    log "All attempts to capture the photo have failed."
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

    # Upload the photo
    rclone copy "$photo_path" "$gdrive_folder" --low-level-retries 3 --retries 3 --progress

    if [ $? -eq 0 ]; then
        verbose_log "Photo uploaded successfully. Verifying checksum..."

        # Verify remote file exists
        rclone ls "$remote_file_path" > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            verbose_log "Remote file not found: $remote_file_path"
            log "Error: Remote file not found for checksum verification: $photo_path"
            return 1
        fi

        # Calculate local checksum
        local_checksum=$(md5sum "$photo_path" | awk '{print $1}')

        # Get remote checksum
        remote_checksum=$(rclone md5sum "$gdrive_folder" | grep "$photo_filename" | awk '{print $1}')

        if [ "$local_checksum" = "$remote_checksum" ]; then
            verbose_log "Checksum match: File integrity verified for $photo_filename"
            log "Upload successful and verified: $photo_path"
            return 0
        else
            verbose_log "Checksum mismatch: File may be corrupted. Local: $local_checksum, Remote: $remote_checksum"
            log "Error: Checksum mismatch for $photo_filename"
            notify_slack "<@U0RSCG38X> Checksum mismatch for photo: $photo_path"
            return 1
        fi
    else
        verbose_log "Upload failed for: $photo_path"
        log "Upload failed for: $photo_path"
        notify_slack "<@U0RSCG38X> Upload failed for photo: $photo_path"
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
    mkdir -p "$backup_path"
    if [ $? -ne 0 ]; then
        verbose_log "Failed to create backup directory: $backup_path"
        log "Error: Failed to create backup directory: $backup_path"
        notify_slack "<@U0RSCG38X> Error: Backup directory creation failed: $backup_path. Possible USB drive failure."
        return 1
    fi

    # Calculate checksum of the original file
    local original_checksum
    original_checksum=$(md5sum "$photo_path" | awk '{print $1}')
    if [ -z "$original_checksum" ]; then
        verbose_log "Failed to calculate checksum for original file: $photo_path"
        log "Error: Failed to calculate checksum for original file: $photo_path"
        notify_slack "Error: Checksum calculation failed for original file: $photo_path"
        return 1
    fi

    # Attempt to move the file to the backup directory
    mv "$photo_path" "$backup_path"
    if [ $? -ne 0 ]; then
        verbose_log "Failed to move photo to backup directory: $backup_path"
        log "Error: Failed to back up photo: $photo_path"
        notify_slack "<@U0RSCG38X> Error: Failed to back up photo: $photo_path. Possible USB drive failure."
        return 1
    fi

    # Verify the file in the backup directory
    local backup_checksum
    backup_checksum=$(md5sum "$backup_path/$photo_name" | awk '{print $1}')
    if [ -z "$backup_checksum" ]; then
        verbose_log "Failed to calculate checksum for backup file: $backup_path/$photo_name"
        log "Error: Failed to calculate checksum for backup file: $backup_path/$photo_name"
        notify_slack "<@U0RSCG38X> Error: Checksum calculation failed for backup file: $backup_path/$photo_name. Possible USB drive failure."
        return 1
    fi

    if [ "$original_checksum" != "$backup_checksum" ]; then
        verbose_log "Checksum mismatch: Backup may be corrupted. Original: $original_checksum, Backup: $backup_checksum"
        log "Error: Backup verification failed for photo: $photo_path"
        notify_slack "<@U0RSCG38X> Error: Backup verification failed for photo: $photo_path. Possible USB drive failure."
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
    remote_files_list=$(rclone lsf "$remote_folder_path" || echo "")
    total_remote_files=$(echo "$remote_files_list" | wc -l) # Count total files on remote

    # Check if backup folder exists
    if [ ! -d "$backup_folder_path" ]; then
        verbose_log "No backup folder found for today at $backup_folder_path. Skipping sync."
        log "No backup folder found for today at $backup_folder_path. Skipping sync."
        notify_slack "No backup folder found for today ($DATE). End-of-Day Sync skipped."
        return
    fi

    # Iterate through local backup files
    for file in "$backup_folder_path"/*; do
        if [ -f "$file" ]; then
            local_total_files=$((local_total_files + 1))
            file_name=$(basename "$file")

            # Check if file exists on remote
            if echo "$remote_files_list" | grep -q "^$file_name$"; then
                remote_files_present=$((remote_files_present + 1))
            else
                # Attempt to upload missing file
                verbose_log "Uploading missing file: $file"
                if rclone copy "$file" "$remote_folder_path" --low-level-retries 3 --retries 3 --progress; then
                    successful_uploads=$((successful_uploads + 1))
                    verbose_log "Successfully uploaded: $file"
                    log "Successfully uploaded: $file"
                else
                    failed_uploads=$((failed_uploads + 1))
                    verbose_log "Failed to upload: $file"
                    log "Upload failed for file: $file"

                    # Move file to failed uploads folder
                    mv "$file" "$failed_uploads_folder" && verbose_log "Moved failed file to: $failed_uploads_folder"
                fi
            fi
        fi
    done

    # Copy the logs to Google Drive
    verbose_log "Copying logs to remote Google Drive folder: $logs_remote_folder"
    if rclone copy "$logs_folder" "$logs_remote_folder" --progress; then
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

    # Generate the summary report
    verbose_log "End-of-Day Sync Summary:"
    verbose_log "Total files in local backup: $local_total_files"
    verbose_log "Total files in remote folder: $total_remote_files"
    verbose_log "Files already on remote: $remote_files_present"
    verbose_log "Files successfully uploaded: $successful_uploads"
    verbose_log "Files failed to upload: $failed_uploads"

    log "End-of-Day Sync Summary:"
    log "Total files in local backup: $local_total_files"
    log "Total files in remote folder: $total_remote_files"
    log "Files already on remote: $remote_files_present"
    log "Files successfully uploaded: $successful_uploads"
    log "Files failed to upload: $failed_uploads"

    # Notify via Slack
    if [ "$failed_uploads" -gt 0 ]; then
        notify_slack "End-of-Day Sync Summary:\nTotal files in local backup: $local_total_files\nTotal files in remote folder: $total_remote_files\nFiles already on remote: $remote_files_present\nFiles successfully uploaded: $successful_uploads\nFiles failed to upload: $failed_uploads\nFailed files moved to: $failed_uploads_folder"
    else
        notify_slack "End-of-Day Sync Summary:\nTotal files in local backup: $local_total_files\nTotal files in remote folder: $total_remote_files\nFiles already on remote: $remote_files_present\nFiles successfully uploaded: $successful_uploads\nFiles failed to upload: $failed_uploads"
    fi

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
    rclone copyto "$renamed_montage_path" "$remote_file_path" --progress || {
        verbose_log "Failed to upload daily montage to Google Drive."
        log "Failed to upload daily montage to Google Drive."

        if ! mountpoint -q "$MOUNT_POINT"; then
            mkdir -p "$MOUNT_POINT"
            if ! mount "$DEVICE" "$MOUNT_POINT"; then
                log "ERROR: failed to mount $DEVICE at $MOUNT_POINT"
                notify_slack "Timelapse ERROR: USB backup mount failed."
                exit 1
            fi
        fi

        # If Google Drive upload fails, move the file to USB backup folder
        local usb_backup_folder="/mnt/BackupArchive/Daily Reviews/$month"
        mkdir -p "$usb_backup_folder"
        mv "$renamed_montage_path" "$usb_backup_folder" && {
            verbose_log "Moved failed daily montage to USB backup folder: $usb_backup_folder"
            log "Moved failed daily montage to USB backup folder: $usb_backup_folder"
        } || {
            verbose_log "Failed to move daily montage to USB backup folder."
            log "Failed to move daily montage to USB backup folder."
            notify_slack "Failed to move daily montage to USB backup folder."
        }
        return
    }

    umount "$MOUNT_POINT"

    # Clean up: remove the renamed local file after successful upload
    rm "$renamed_montage_path" || {
        verbose_log "Failed to remove renamed local file."
        log "Failed to remove renamed local file."
        notify_slack "Failed to remove renamed local file."
    }

    verbose_log "Daily montage uploaded to Google Drive: $remote_file_path"
    log "Daily montage uploaded to Google Drive: $remote_file_path"

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
    curl -X POST -H 'Content-type: application/json' \
        --data '{"text":"Daily Report: '"$report_data"'"}' "$SLACK_WEBHOOK"
    if [ $? -eq 0 ]; then
        verbose_log "Daily report sent successfully."
        log "Daily report sent."
    else
        verbose_log "Failed to send daily report."
        log "Failed to send daily report."
    fi
}

count_images_for_report() {
    # 1) Mount if needed
    if ! mountpoint -q "$MOUNT_POINT"; then
        mkdir -p "$MOUNT_POINT"
        if ! mount "$DEVICE" "$MOUNT_POINT"; then
            log "ERROR: failed to mount $DEVICE at $MOUNT_POINT"
            notify_slack "Timelapse ERROR: USB backup mount failed."
            exit 1
        fi
    fi

    # Define Google Drive folder and USB backup folder paths
    local google_drive_folder="$GDRIVE_REMOTE:$PROJECT_NAME/Daily Photos/$CURRENT_MONTH/$DATE"
    local usb_backup_folder="/mnt/BackupArchive/$DATE"
    
    # Initialize image counts
    local google_drive_count=0
    local usb_backup_count=0
    
    # Count images in the Google Drive folder using rclone (all .jpg files)
    google_drive_count=$(rclone lsf "$google_drive_folder" --files-only --include "*.jpg" | wc -l)
    
    # Check if USB backup folder exists and count images there
    if [ -d "$usb_backup_folder" ]; then
        usb_backup_count=$(find "$usb_backup_folder" -type f -name "*.jpg" | wc -l)
    else
        usb_backup_count=0
    fi
    
    # Format the result as a string to pass to the send email or report functions
    echo "Images for today on Google Drive: $google_drive_count, Images for today on USB Backup: $usb_backup_count"

    umount "$MOUNT_POINT"
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
