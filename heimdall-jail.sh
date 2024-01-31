#!/bin/bash

# Install Heimdall Dashboard (https://github.com/linuxserver/Heimdall)
# in a FreeNAS jail

# https://forum.freenas-community.org/t/install-heimdall-dashboard-in-a-jail-script-freenas-11-2/35

# Original script by Dan Brown
# Modifications by Benjamin Nelan
# v1.0

# Check for root privileges
if ! [ $(id -u) = 0 ]; then
   echo "This script must be run with root privileges"
   exit 1
fi

# Auto log the result
# Log file location
LOGFILE="heimdall.log"
STATUSFILE="heimdall.status"
CONFIGFILE="heimdall-config"

# Function to update the status file
update_status() {
    echo "$1" >> "$STATUSFILE"
}

# Function to check the current status
check_status() {
    local step="$1"
    if [ -f "$STATUSFILE" ] && grep -Fxq "$step" "$STATUSFILE"; then
        return 0  # Step found, return true (completed)
    else
        return 1  # Step not found, return false (not completed)
    fi
}

# Function to ask user if they want to continue or exit
ask_to_continue() {
    while true; do
        read -p "Do you want to continue or exit the script? (continue/exit) " answer
        case $answer in
            [Cc]ontinue ) 
                echo "Continuing with the script..."
                break
                ;;
            [Ee]xit ) 
                echo "Exiting the script."
                exit
                ;;
            * ) 
                echo "Please type 'continue' to proceed or 'exit' to stop the script."
                ;;
        esac
    done
}

# Redirect output and error to log file
exec > >(tee -a "$LOGFILE") 2>&1

#####
#
# General configuration
#
#####

# Initialize defaults
JAIL_NAME="heimdall"
JAIL_IP=""
DEFAULT_GW_IP=$(netstat -rn | grep default | awk '{ print $2 }')
POOL_PATH=""
FILE="V2.5.8.tar.gz"
PHP_VERSION="83"
RELEASE="13.2-RELEASE" # $(freebsd-version | cut -d - -f -1)"-RELEASE"

# Check for heimdall-config and set configuration if it exists
SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "${SCRIPT}")
if [ -e "${SCRIPTPATH}"/"${CONFIGFILE}" ]; then
  . "${SCRIPTPATH}"/"${CONFIGFILE}"
else
  echo "Optional config file ${SCRIPTPATH}/${CONFIGFILE} not found. Using default values."
fi

#--------------------------------------------------------------------------------------------
# Create the iocage based on specified network settings
if ! check_status "jail_created"; then
  if [ -n "${JAIL_IP}" ]; 
  then
    IP=$(echo ${JAIL_IP} | cut -f1 -d/)
    NETMASK=$(echo ${JAIL_IP} | cut -f2 -d/)
    if [ "${NETMASK}" = "${IP}" ]
    then
      NETMASK="24"
    fi
    if [ "${NETMASK}" -lt 8 ] || [ "${NETMASK}" -gt 30 ]
    then
      NETMASK="24"
    fi

    echo "Creating jail with chosen IP"
    if ! iocage create --name "${JAIL_NAME}" -r "${RELEASE}" \
      ip4_addr="vnet0|${IP}/${NETMASK}" defaultrouter="${DEFAULT_GW_IP}" boot="on" \
      host_hostname="${JAIL_NAME}" vnet="on"
    then
      echo "Failed to create jail"
      exit 1
    fi
  else
    echo "No IP address specified, using DHCP"
    if ! iocage create --name "${JAIL_NAME}" -r "${RELEASE}" \
      dhcp="on" bpf="yes" defaultrouter="${DEFAULT_GW_IP}" boot="on" \
      host_hostname="${JAIL_NAME}" vnet="on"
    then
      echo "Failed to create jail"
      exit 1
    fi
  fi

  # Check internet connectivity from within the jail
  if iocage exec "${JAIL_NAME}" ping -c 1 github.com &> /dev/null; then
      echo "Internet connection is active inside the jail."
      iocage exec "${JAIL_NAME}" ifconfig
  else
      echo "Internet connection is not active inside the jail, possible invalid IP address/gateway. Exiting script."
      exit 1
  fi

  update_status "jail_created"
else
  echo "Jail already created, skipping"
fi

#--------------------------------------------------------------------------------------------
# Update the package list and upgrade existing packages
if ! check_status "packages_installed"; then
  iocage exec "${JAIL_NAME}" "pkg update && pkg upgrade -y"

  # Install PHP and required modules
  PKG_LIST="
  nano
  caddy
  php${PHP_VERSION}
  php${PHP_VERSION}-mbstring
  php${PHP_VERSION}-zip
  php${PHP_VERSION}-tokenizer
  php${PHP_VERSION}-pdo
  php${PHP_VERSION}-pdo_sqlite
  php${PHP_VERSION}-filter
  php${PHP_VERSION}-ctype
  sqlite3
  php${PHP_VERSION}-session
  go
  git
  "

  # Prior to PHP 8 there were openssl and xml modules for FreeBSD
  # Now openssl is included in the base package and xml is removed
  # via https://mwl.io/archives/22357
  if (( PHP_VERSION < 80 )); then
      # Append additional packages to PKG_LIST
      PKG_LIST+=" php${PHP_VERSION}-openssl php${PHP_VERSION}-xml"
  fi

  # Set up empty array for failed packages
  declare -a failed_packages

  # Loop through the package list
  for pkg in $PKG_LIST; do
      if ! iocage exec "${JAIL_NAME}" pkg install -y "$pkg"; then
          # If the package installation fails, add it to the failed_packages array
          failed_packages+=("$pkg")
      fi
  done

  # Check if there are any failed packages
  if [ ${#failed_packages[@]} -ne 0 ]; then
      echo "========================================="
      echo "The following packages failed to install:"
      echo "========================================="
      for pkg in "${failed_packages[@]}"; do
          echo "$pkg"
      done
      echo "========================================="
      ask_to_continue
  else
      echo "All packages installed successfully."
  fi

  update_status "packages_installed"
else
  echo "Packages already installed, skipping"
fi

#--------------------------------------------------------------------------------------------
# Store Caddyfile and data outside the jail
mountpoint=$(zfs get -H -o value mountpoint $(iocage get -p)/iocage)

if ! check_status "caddy_setup"; then
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/www/

  if [ -n "${POOL_PATH}" ]; 
  then
    mkdir -p "${POOL_PATH}/apps/heimdall"
    iocage fstab -a "${JAIL_NAME}" "${POOL_PATH}/apps/heimdall" /usr/local/www nullfs rw 0 0
  else
    echo "No POOL_PATH specified, heimdall will store data in the jail that will be lost if the jail is deleted."
  fi

  # Create Caddyfile
  cat <<__EOF__ >"${mountpoint}/jails/${JAIL_NAME}/root/usr/local/www/Caddyfile"
:80 {
    encode gzip

    log {
        output file /var/log/heimdall_access.log
    }

    root * /usr/local/www/html/public
    file_server

    php_fastcgi 127.0.0.1:9000

    # Add reverse proxy directives here if desired
}
__EOF__

  update_status "caddy_setup"
else
  echo "Caddy already setup, skipping"
fi

#--------------------------------------------------------------------------------------------
# Download Heimdall
if ! check_status "heimdall_download"; then
  iocage exec "${JAIL_NAME}" mkdir -p /usr/local/www/html
  if ! iocage exec "${JAIL_NAME}" fetch -o /tmp https://github.com/linuxserver/Heimdall/archive/"${FILE}"; then
    echo "Unable to download the Heimdall source, is file name correct?"
    exit 1;
  else
    echo "Downloaded Heimdall source."
  fi
  update_status "heimdall_download"
else
  echo "Heimdall already downloaded, skipping"
fi

#--------------------------------------------------------------------------------------------
# Extract Heimdall
if ! check_status "heimdall_extract"; then
  if ! iocage exec "${JAIL_NAME}" tar zxf /tmp/"${FILE}" --strip 1 -C /usr/local/www/html/; then
    echo "Error while extracting Heimdall, possible jail storage issues, is your pool path correct?"
    iocage exec "${JAIL_NAME}" df -h
    iocage exec "${JAIL_NAME}" df -h /usr/local/www
    exit 1;
  else
    echo "Extraction complete"
  fi
  update_status "heimdall_config"
else
  echo "Heimdall already configured, skipping"
fi

#--------------------------------------------------------------------------------------------
# Setup Heimdall
if ! check_status "heimdall_setup"; then
  iocage exec "${JAIL_NAME}" mkdir -p /usr/local/www/html/storage/app/public/icons
  iocage exec "${JAIL_NAME}" sh -c 'find /usr/local/www/ -type d -print0 | xargs -0 chmod 2775'
  iocage exec "${JAIL_NAME}" touch /usr/local/www/html/database/app.sqlite
  iocage exec "${JAIL_NAME}" chmod 664 /usr/local/www/html/database/app.sqlite
  iocage exec "${JAIL_NAME}" chown -R www:www /usr/local/www/html/
  iocage exec "${JAIL_NAME}" chown www:www /usr/local/www/Caddyfile
  iocage exec "${JAIL_NAME}" sysrc php_fpm_enable=YES
  iocage exec "${JAIL_NAME}" sysrc caddy_enable=YES
  iocage exec "${JAIL_NAME}" sysrc caddy_config=/usr/local/www/Caddyfile
  iocage exec "${JAIL_NAME}" cp /usr/local/www/html/.env.example /usr/local/www/html/.env
  iocage exec "${JAIL_NAME}" sh -c 'cd /usr/local/www/html/ && php artisan key:generate'
  iocage exec "${JAIL_NAME}" service php-fpm start
  iocage exec "${JAIL_NAME}" service caddy start
  update_status "heimdall_setup"
else
  echo "Heimdall already setup, skipping"
fi

#--------------------------------------------------------------------------------------------
# Configure mdns courtesy of jack828
# https://gist.github.com/jack828/b8375b16b6fb9eae52201d4deb563ab7
if ! check_status "mdns-setup"; then
  HOSTNAME=$(iocage exec "${JAIL_NAME}" hostname)

  echo "Setting up mdns"
  iocage exec "${JAIL_NAME}" pkg install -y avahi-app
  iocage exec "${JAIL_NAME}" sysrc dbus_enable="YES"
  iocage exec "${JAIL_NAME}" sysrc avahi_daemon_enable="YES"
  iocage exec "${JAIL_NAME}" rm /usr/local/etc/avahi/services/*.service

  cat <<__EOF__ >"${mountpoint}/jails/${JAIL_NAME}/root/usr/local/etc/avahi/services/http.service"
  <?xml version="1.0" standalone='no'?><!--*-nxml-*-->
  <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
  <service-group>
    <name replace-wildcards="yes">%h</name>
    <service>
      <type>_http._tcp</type>
      <port>80</port>
    </service>
  </service-group>
__EOF__

  echo "Starting services..."

  iocage exec "${JAIL_NAME}" service dbus start
  iocage exec "${JAIL_NAME}" service avahi-daemon start

  echo "Done! Heimdall now accessible at: http://$HOSTNAME.local/"
else
  echo "mdns already setup, skipping"
fi

#--------------------------------------------------------------------------------------------
# For some reason have to run this to fix server error, even though these commands have already been run.
# See https://github.com/danb35/freenas-iocage-heimdall/issues/5
# Will look into this at some point..
iocage exec "${JAIL_NAME}" chown www:www /usr/local/www/Caddyfile
iocage exec "${JAIL_NAME}" chown -R www:www /usr/local/www/html/
iocage exec "${JAIL_NAME}" service caddy restart

echo "Script complete"
echo "You may choose to cleanup using rm heimdall*"