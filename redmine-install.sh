#!/bin/bash
#
# Redmine Installation Script for Hetzner Cloud
# This script automates the installation of Redmine 6.0.5 with Nginx, MariaDB, and Let's Encrypt SSL
# For Ubuntu 24.04 LTS on Hetzner Cloud
# Last Updated: May 1, 2025
#

# Exit on error
set -e
set -u
set -o pipefail

# Color definitions for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration variables (set defaults)
DOMAIN=""
DB_PASSWORD=""
REDMINE_VERSION="6.0.5"
RUBY_VERSION="3.2.2"
# Ruby version must be compatible with Redmine requirements (>=3.1.0,<3.4.0)
EMAIL=""
DRY_RUN=false
LOG_FILE="/var/log/redmine-install.log"

# Skip steps that are already completed (useful for resuming after errors)
SKIP_DEPENDENCIES=true
SKIP_RUBY=true
SKIP_REDMINE_USER=true
SKIP_DATABASE=true
SKIP_REDMINE=true
SKIP_NGINX=false
SKIP_FIREWALL=false
SKIP_SSL=false

# Display usage information
usage() {
    echo -e "${BLUE}Redmine Installation Script for Hetzner Cloud${NC}"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -d, --domain DOMAIN       Domain name for the Redmine installation"
    echo "  -p, --password PASSWORD   Password for MariaDB redmine user"
    echo "  -e, --email EMAIL           Email for Let's Encrypt certificate notifications"
    echo "  --dry-run                  Run without making changes (for testing)"
    echo "  --skip-dependencies        Skip dependency installation"
    echo "  --skip-ruby               Skip Ruby installation"
    echo "  --skip-redmine-user       Skip Redmine user creation"
    echo "  --skip-database           Skip database configuration"
    echo "  --skip-redmine            Skip Redmine installation"
    echo "  --skip-nginx              Skip Nginx configuration"
    echo "  --skip-firewall           Skip firewall configuration"
    echo "  --skip-ssl                Skip SSL configuration"
    echo "  --resume STEP             Resume from a specific step (ruby, user, database, redmine, nginx, firewall, ssl)"
    echo "  -h, --help                 Display this help message"
    echo ""
    echo "Example:"
    echo "  $0 -d example.com -p StrongPassw0rd"
    echo "  $0 -d example.com -p StrongPassw0rd --resume nginx"
    exit 1
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -d|--domain) DOMAIN="$2"; shift ;;
        -p|--password) DB_PASSWORD="$2"; shift ;;
        -e|--email) EMAIL="$2"; shift ;;
        --dry-run) DRY_RUN=true ;;
        --skip-dependencies) SKIP_DEPENDENCIES=true ;;
        --skip-ruby) SKIP_RUBY=true ;;
        --skip-redmine-user) SKIP_REDMINE_USER=true ;;
        --skip-database) SKIP_DATABASE=true ;;
        --skip-redmine) SKIP_REDMINE=true ;;
        --skip-nginx) SKIP_NGINX=true ;;
        --skip-firewall) SKIP_FIREWALL=true ;;
        --skip-ssl) SKIP_SSL=true ;;
        --resume) 
            # Resume from a specific step, skipping all previous steps
            case "$2" in
                ruby) SKIP_DEPENDENCIES=true ;;
                user) SKIP_DEPENDENCIES=true; SKIP_RUBY=true ;;
                database) SKIP_DEPENDENCIES=true; SKIP_RUBY=true; SKIP_REDMINE_USER=true ;;
                redmine) SKIP_DEPENDENCIES=true; SKIP_RUBY=true; SKIP_REDMINE_USER=true; SKIP_DATABASE=true ;;
                nginx) SKIP_DEPENDENCIES=true; SKIP_RUBY=true; SKIP_REDMINE_USER=true; SKIP_DATABASE=true; SKIP_REDMINE=true ;;
                firewall) SKIP_DEPENDENCIES=true; SKIP_RUBY=true; SKIP_REDMINE_USER=true; SKIP_DATABASE=true; SKIP_REDMINE=true; SKIP_NGINX=true ;;
                ssl) SKIP_DEPENDENCIES=true; SKIP_RUBY=true; SKIP_REDMINE_USER=true; SKIP_DATABASE=true; SKIP_REDMINE=true; SKIP_NGINX=true; SKIP_FIREWALL=true ;;
                *) echo "Unknown resume point: $2"; usage ;;
            esac
            shift ;;
        -h|--help) usage ;;
        *) echo "Unknown parameter: $1"; usage ;;
    esac
    shift
done

# Validate required parameters
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}Error: Domain name is required.${NC}"
    usage
fi

if [ -z "$DB_PASSWORD" ]; then
    echo -e "${RED}Error: Database password is required.${NC}"
    usage
fi

# Function to display a warning message
warning() {
    local message=$1
    local timestamp=$(date +"[%Y-%m-%d %H:%M:%S]")
    echo -e "${timestamp} ${YELLOW}WARNING:${NC} $message"
    echo "${timestamp} WARNING: $message" >> "$LOG_FILE"
}

# Set default email if not provided
if [ -z "$EMAIL" ]; then
    EMAIL="admin@${DOMAIN}"
    warning "No email provided for Let's Encrypt. Using ${EMAIL} as default."
fi

# Initialize log file
if [ "$DRY_RUN" = false ]; then
    touch "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') Redmine installation started" > "$LOG_FILE"
    echo "Domain: $DOMAIN" >> "$LOG_FILE"
    echo "Redmine Version: $REDMINE_VERSION" >> "$LOG_FILE"
    echo "Ruby Version: $RUBY_VERSION" >> "$LOG_FILE"
fi

# Log function
log() {
    local message="$1"
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $message${NC}"
    if [ "$DRY_RUN" = false ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
    fi
}

error() {
    local message="$1"
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $message${NC}" >&2
    if [ "$DRY_RUN" = false ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $message" >> "$LOG_FILE"
    fi
    exit 1
}

warning() {
    local message="$1"
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $message${NC}"
    if [ "$DRY_RUN" = false ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $message" >> "$LOG_FILE"
    fi
}

# Execute command with dry run check
execute() {
    local command="$1"
    local error_msg="$2"
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY RUN] Would execute: $command${NC}"
        return 0
    else
        log "Command: $command"
        eval "$command" || error "$error_msg"
    fi
}

section() {
    echo -e "\n${BLUE}⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻⸻${NC}\n"
}

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root"
    fi
}

# Install dependencies
install_dependencies() {
    section "📦 Installing Dependencies"
    
    # Check if key packages are already installed
    if [ "$DRY_RUN" = false ]; then
        # Check for nginx as a key indicator
        if dpkg -l | grep -q "^ii\s\+nginx "; then
            log "Nginx is already installed, checking other key packages..."
            
            # Check for MariaDB
            if dpkg -l | grep -q "^ii\s\+mariadb-server"; then
                log "MariaDB is already installed"
            else
                log "MariaDB is not installed, will install it"
                NEED_INSTALL=true
            fi
            
            # Check for other essential packages
            if dpkg -l | grep -q "^ii\s\+build-essential" && \
               dpkg -l | grep -q "^ii\s\+libssl-dev" && \
               dpkg -l | grep -q "^ii\s\+git-core"; then
                log "Essential build packages are already installed"
            else
                log "Some essential packages are missing, will install them"
                NEED_INSTALL=true
            fi
            
            if [ "$NEED_INSTALL" = true ]; then
                log "Some required packages are missing, updating package lists..."
                execute "apt update" "Failed to update package lists"
            else
                log "All key dependencies appear to be installed, skipping package installation"
                return 0
            fi
        else
            log "Nginx is not installed, performing full dependency installation"
            log "Updating package lists..."
            execute "apt update && apt upgrade -y" "Failed to update package lists"
        fi
    else
        echo -e "${BLUE}[DRY RUN] Would check if dependencies are already installed${NC}"
        log "Updating package lists..."
        echo -e "${BLUE}[DRY RUN] Would update package lists${NC}"
    fi
    
    log "Installing required packages..."
    execute "DEBIAN_FRONTEND=noninteractive apt install -y build-essential libssl-dev libreadline-dev zlib1g-dev \
    libsqlite3-dev sqlite3 libxml2-dev libcurl4-openssl-dev libffi-dev \
    libyaml-dev libgdbm-dev libncurses5-dev libtool bison libmagickwand-dev \
    imagemagick curl git-core nginx mariadb-server libmariadb-dev \
    libpq-dev nodejs npm gnupg2 gawk ufw" "Failed to install dependencies"
    
    log "Dependencies installed successfully!"
}

# Install Ruby using RVM
install_ruby() {
    section "💎 Installing Ruby Using RVM"
    
    # Ensure RUBY_VERSION is set (fallback to default if unset)
    if [ -z "${RUBY_VERSION}" ]; then
        log "Setting Ruby version to 3.2.2 which is compatible with Redmine 6.0.5"
        RUBY_VERSION="3.2.2"
    fi
    
    # Check if RVM is already installed
    if [ "$DRY_RUN" = false ]; then
        if [ -f "/etc/profile.d/rvm.sh" ]; then
            log "RVM is already installed, loading RVM environment..."
            
            # Use a subshell to safely load RVM environment and capture key variables
            RVM_ENV=$(bash -c 'source /etc/profile.d/rvm.sh 2>/dev/null && env | grep -E "^(PATH|GEM|RUBY|RVM)"' 2>/dev/null)
            if [ $? -eq 0 ]; then
                eval "$(echo "$RVM_ENV" | sed 's/^/export /')"
                log "RVM environment loaded successfully"
            else
                log "Warning: Could not load RVM environment, continuing anyway"
            fi
            
            # Check current default Ruby version using bash -l
            CURRENT_RUBY=$(bash -l -c "source /etc/profile.d/rvm.sh 2>/dev/null && rvm current 2>/dev/null" || echo "none")
            log "Current Ruby version: $CURRENT_RUBY"
            
            # If current Ruby version doesn't match required version, we need to install or switch
            if [[ "$CURRENT_RUBY" != "ruby-${RUBY_VERSION}" ]]; then
                log "Current Ruby version is not ${RUBY_VERSION}, checking compatibility..."
                
                # Check if current Ruby version is incompatible with Redmine requirements
                CURRENT_RUBY_VERSION=$(echo $CURRENT_RUBY | sed 's/ruby-//')
                # Redmine 6.0.5 requires Ruby >= 3.1.0 and < 3.3.0
                if [[ "$CURRENT_RUBY_VERSION" == "3.3.8" ]] || [[ "$CURRENT_RUBY_VERSION" > "3.2.9" ]]; then
                    log "Current Ruby version $CURRENT_RUBY_VERSION is incompatible with Redmine 6.0.5 requirements (>=3.1.0,<3.3.0)"
                    log "Removing incompatible Ruby version..."
                    execute "bash -l -c 'source /etc/profile.d/rvm.sh 2>/dev/null && rvm remove $CURRENT_RUBY_VERSION --gems'" "Failed to remove incompatible Ruby version"
                fi
                
                # Check if the required Ruby version is already installed
                RUBY_INSTALLED=$(bash -l -c "source /etc/profile.d/rvm.sh 2>/dev/null && rvm list | grep -q \"${RUBY_VERSION}\" && echo 'yes' || echo 'no'")
                if [[ "$RUBY_INSTALLED" == "yes" ]]; then
                    log "Ruby ${RUBY_VERSION} is already installed, setting as default..."
                    execute "bash -l -c 'source /etc/profile.d/rvm.sh 2>/dev/null && rvm use ${RUBY_VERSION} --default'" "Failed to set Ruby as default"
                else
                    log "Ruby 3.2.2 is not installed, will install it..."
                    execute "bash -l -c 'source /etc/profile.d/rvm.sh 2>/dev/null && rvm install 3.2.2'" "Failed to install Ruby 3.2.2"
                    execute "bash -l -c 'source /etc/profile.d/rvm.sh 2>/dev/null && rvm use ${RUBY_VERSION} --default'" "Failed to set Ruby as default"
                fi
                
                # Verify the correct version is now being used
                CURRENT_RUBY=$(bash -l -c "source /etc/profile.d/rvm.sh 2>/dev/null && rvm current 2>/dev/null" || echo "none")
                log "Now using Ruby version: $CURRENT_RUBY"
                
                # Force RVM to use this version for the redmine user
                log "Updating redmine user's .bashrc to use Ruby ${RUBY_VERSION}..."
                if [ -d "/home/redmine" ]; then
                    cat > /home/redmine/.bashrc << EOF
# Load RVM
source /etc/profile.d/rvm.sh
# Set Ruby version
rvm use ${RUBY_VERSION} 2>/dev/null
EOF
                    chown redmine:redmine /home/redmine/.bashrc
                fi
            else
                log "Ruby ${RUBY_VERSION} is already set as default, skipping Ruby installation"
            fi
        else
            log "RVM is not installed, proceeding with installation"
        fi
    else
        echo -e "${BLUE}[DRY RUN] Would check if RVM and Ruby ${RUBY_VERSION} are already installed${NC}"
    fi
    
    log "Installing GPG keys for RVM..."
    execute "gpg2 --keyserver hkp://keyserver.ubuntu.com --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 7D2BAF1CF37B13E2069D6956105BD0E739499BDB || curl -sSL https://rvm.io/mpapis.asc | gpg2 --import - && curl -sSL https://rvm.io/pkuczynski.asc | gpg2 --import -" "Failed to import GPG keys for RVM"
    
    log "Installing RVM..."
    execute "curl -sSL https://get.rvm.io | bash -s stable" "Failed to install RVM"
    
    log "Loading RVM environment..."
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY RUN] Would load RVM environment${NC}"
    else
        # Use a subshell to safely load RVM environment
        RVM_ENV=$(bash -c 'source /etc/profile.d/rvm.sh 2>/dev/null && env | grep -E "^(PATH|GEM|RUBY|RVM)"' 2>/dev/null)
        if [ $? -eq 0 ]; then
            eval "$(echo "$RVM_ENV" | sed 's/^/export /')"
            log "RVM environment loaded successfully"
        else
            log "Warning: Could not load RVM environment, continuing anyway"
        fi
    fi
    
    log "Installing Ruby 3.2.2..."
    execute "bash -l -c 'source /etc/profile.d/rvm.sh 2>/dev/null && rvm install 3.2.2'" "Failed to install Ruby"
    
    log "Setting Ruby 3.2.2 as default..."
    execute "bash -l -c 'source /etc/profile.d/rvm.sh 2>/dev/null && rvm use 3.2.2 --default'" "Failed to set Ruby as default"
    
    log "Ruby installation completed!"
}

# Create Redmine user
create_redmine_user() {
    section "👤 Creating Redmine User"
    
    log "Checking if redmine user exists..."
    if id "redmine" &>/dev/null; then
        log "User 'redmine' already exists, checking if we need to fix it..."
        # Make sure the user is properly configured
        execute "usermod -s /bin/bash redmine" "Failed to set shell for redmine user"
    else
        log "Adding redmine user..."
        execute "adduser --disabled-login --shell /bin/bash --gecos \"\" redmine" "Failed to create redmine user"
    fi
    
    # Make sure the user's home directory exists and has correct permissions
    if [ "$DRY_RUN" = false ]; then
        if [ ! -d "/home/redmine" ]; then
            mkdir -p /home/redmine
        fi
        chown -R redmine:redmine /home/redmine
        chmod 755 /home/redmine
    else
        echo -e "${BLUE}[DRY RUN] Would ensure /home/redmine directory exists with proper permissions${NC}"
    fi
    
    # Add RVM to redmine user's bashrc
    if [ "$DRY_RUN" = false ]; then
        log "Adding RVM configuration to redmine user's .bashrc..."
        cat > /home/redmine/.bashrc << EOF
# Load RVM
source /etc/profile.d/rvm.sh
# Set Ruby version
rvm use ${RUBY_VERSION} 2>/dev/null
EOF
        chown redmine:redmine /home/redmine/.bashrc
    else
        echo -e "${BLUE}[DRY RUN] Would add RVM to redmine user's .bashrc${NC}"
    fi
    
    log "Redmine user configured successfully!"
}

# Install and configure MariaDB
configure_database() {
    section "🗄️ Installing and Configuring MariaDB"
    
    log "Securing MariaDB installation..."
    # Fix for Ubuntu 24.04 auth method
    if [ "$DRY_RUN" = false ]; then
        # First switch to mysql_native_password for root using the correct syntax
        # Use single quotes to prevent history expansion with ! characters
        mysql -u root << EOF
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${DB_PASSWORD//!/\\!}');
FLUSH PRIVILEGES;
EOF
        
        # Now run the secure installation - escape special characters
        ESCAPED_PASSWORD="${DB_PASSWORD//!/\\!}"
        mysql -u root -p"${ESCAPED_PASSWORD}" << EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
    else
        echo -e "${BLUE}[DRY RUN] Would secure MariaDB installation${NC}"
    fi
    
    log "Creating Redmine database and user..."
    if [ "$DRY_RUN" = false ]; then
        # Check if database exists
        DB_EXISTS=$(mysql -u root -p"${ESCAPED_PASSWORD}" -e "SHOW DATABASES LIKE 'redmine'" | grep -c redmine)
        
        if [ "$DB_EXISTS" -eq 0 ]; then
            log "Creating new redmine database..."
            mysql -u root -p"${ESCAPED_PASSWORD}" << EOF
CREATE DATABASE redmine CHARACTER SET utf8mb4;
EOF
        else
            log "Database 'redmine' already exists, skipping creation..."
        fi
        
        # Check if user exists
        USER_EXISTS=$(mysql -u root -p"${ESCAPED_PASSWORD}" -e "SELECT User FROM mysql.user WHERE User='redmine'" | grep -c redmine)
        
        if [ "$USER_EXISTS" -eq 0 ]; then
            log "Creating new redmine database user..."
            mysql -u root -p"${ESCAPED_PASSWORD}" << EOF
CREATE USER 'redmine'@'localhost' IDENTIFIED BY '${DB_PASSWORD//!/\!}';
EOF
        else
            log "User 'redmine' already exists, updating password..."
            mysql -u root -p"${ESCAPED_PASSWORD}" << EOF
SET PASSWORD FOR 'redmine'@'localhost' = PASSWORD('${DB_PASSWORD//!/\!}');
EOF
        fi
        
        # Always ensure proper privileges
        mysql -u root -p"${ESCAPED_PASSWORD}" << EOF
GRANT ALL PRIVILEGES ON redmine.* TO 'redmine'@'localhost';
FLUSH PRIVILEGES;
EOF
    else
        echo -e "${BLUE}[DRY RUN] Would create Redmine database and user${NC}"
    fi
    
    log "Database configured successfully!"
}

# Download and configure Redmine
install_redmine() {
    section "📥 Downloading and Configuring Redmine"
    
    local redmine_dir="/home/redmine"
    local redmine_app_dir="${redmine_dir}/redmine"
    
    # Initialize goto_gem_installation variable
    goto_gem_installation=false
    
    # Check if Redmine is already installed
    if [ "$DRY_RUN" = false ]; then
        if [ -d "${redmine_app_dir}" ] && [ -f "${redmine_app_dir}/config/database.yml" ]; then
            log "Redmine appears to be already installed at ${redmine_app_dir}"
            log "Checking if it's the correct version..."
            
            if [ -f "${redmine_app_dir}/config/environment.rb" ] && grep -q "REDMINE_VERSION" "${redmine_app_dir}/lib/redmine/version.rb"; then
                log "Redmine installation found, ensuring proper configuration"
                
                # Ensure proper ownership
                log "Ensuring proper ownership..."
                execute "chown -R redmine:redmine ${redmine_dir}" "Failed to set ownership"
                
                # Update database configuration if password changed
                log "Updating database configuration..."
                if [ "$DRY_RUN" = false ]; then
                    cat > ${redmine_app_dir}/config/database.yml << EOF
production:
  adapter: mysql2
  database: redmine
  host: localhost
  username: redmine
  password: "${DB_PASSWORD//!/\\!}"
  encoding: utf8mb4
  variables:
    tx_isolation: "READ-COMMITTED"
EOF
                    # Fix ownership
                    chown redmine:redmine ${redmine_app_dir}/config/database.yml
                else
                    echo -e "${BLUE}[DRY RUN] Would update database.yml configuration${NC}"
                fi
                
                # Skip to gem installation and database migration
                goto_gem_installation=true
            else
                log "Existing Redmine installation found but may not be the correct version"
                log "Will backup and reinstall Redmine"
                
                # Backup existing installation
                if [ -d "${redmine_app_dir}" ]; then
                    local backup_timestamp=$(date +"%Y%m%d%H%M%S")
                    log "Backing up existing Redmine installation to ${redmine_app_dir}_backup_${backup_timestamp}"
                    execute "mv ${redmine_app_dir} ${redmine_app_dir}_backup_${backup_timestamp}" "Failed to backup existing Redmine installation"
                fi
            fi
        else
            log "Redmine is not installed, proceeding with installation"
        fi
    else
        echo -e "${BLUE}[DRY RUN] Would check if Redmine is already installed${NC}"
    fi
    
    # Create Redmine directory if it doesn't exist or if we need to reinstall
    if [ "$goto_gem_installation" != "true" ]; then
        if [ "$DRY_RUN" = false ]; then
            if [ ! -d "${redmine_dir}" ]; then
                mkdir -p ${redmine_dir}
                chown redmine:redmine ${redmine_dir}
            fi
        fi
        
        log "Downloading Redmine ${REDMINE_VERSION}..."
        execute "cd ${redmine_dir} && wget https://www.redmine.org/releases/redmine-${REDMINE_VERSION}.tar.gz" "Failed to download Redmine"
        
        log "Extracting Redmine..."
        execute "cd ${redmine_dir} && tar -xzf redmine-${REDMINE_VERSION}.tar.gz" "Failed to extract Redmine"
        execute "cd ${redmine_dir} && mv redmine-${REDMINE_VERSION} redmine" "Failed to rename Redmine directory"
        
        log "Setting proper ownership..."
        execute "chown -R redmine:redmine ${redmine_dir}" "Failed to set ownership"
        
        log "Configuring database connection..."
        execute "cp ${redmine_app_dir}/config/database.yml.example ${redmine_app_dir}/config/database.yml" "Failed to copy database configuration"
        
        # Create database.yml with the correct configuration
        if [ "$DRY_RUN" = false ]; then
            cat > ${redmine_app_dir}/config/database.yml << EOF
production:
  adapter: mysql2
  database: redmine
  host: localhost
  username: redmine
  password: "${DB_PASSWORD//!/\\!}"
  encoding: utf8mb4
  variables:
    tx_isolation: "READ-COMMITTED"
EOF
            # Fix ownership
            chown redmine:redmine ${redmine_app_dir}/config/database.yml
        else
            echo -e "${BLUE}[DRY RUN] Would create database.yml configuration${NC}"
        fi
    fi
    
    # Create wrapper script to run commands as redmine
    if [ "$DRY_RUN" = false ]; then
        if [ ! -f "/usr/local/bin/run-as-redmine" ]; then
            log "Creating redmine wrapper script..."
            cat > /usr/local/bin/run-as-redmine << 'EOF'
#!/bin/bash
# Wrapper to run commands as redmine with proper environment
source /etc/profile.d/rvm.sh
cd /home/redmine/redmine
exec "$@"
EOF
            chmod +x /usr/local/bin/run-as-redmine
        else
            log "Redmine wrapper script already exists"
        fi
    else
        echo -e "${BLUE}[DRY RUN] Would create redmine wrapper script${NC}"
    fi
    
    # Fix RVM permissions for redmine user
    if [ "$DRY_RUN" = false ]; then
        log "Ensuring redmine user has proper permissions for RVM..."
        execute "usermod -a -G rvm redmine" "Failed to add redmine user to rvm group"
        
        # Fix permissions on RVM directories
        if [ -d "/usr/local/rvm" ]; then
            log "Fixing permissions on RVM directories..."
            execute "chown -R root:rvm /usr/local/rvm" "Failed to set ownership on RVM directories"
            execute "chmod -R g+w /usr/local/rvm" "Failed to set permissions on RVM directories"
        fi
        
        # Create a temporary script to ensure the correct Ruby version is used
        log "Creating a temporary script to use the correct Ruby version..."
        cat > /home/redmine/use_ruby_for_redmine.sh << EOF
#!/bin/bash
source /etc/profile.d/rvm.sh
rvm use ${RUBY_VERSION} --default
exec "\$@"
EOF
        # Ensure proper permissions
        chmod 755 /home/redmine/use_ruby_for_redmine.sh
        chown redmine:redmine /home/redmine/use_ruby_for_redmine.sh
    else
        echo -e "${BLUE}[DRY RUN] Would fix RVM permissions for redmine user${NC}"
    fi
    
    log "Installing Bundler and required gems..."
    if [ "$DRY_RUN" = false ]; then
        # First verify which Ruby version is being used
        log "Verifying Ruby version for redmine user..."
        # Create a temporary script to check Ruby version in redmine's home directory
        cat > /home/redmine/check_ruby_version.sh << EOF
#!/bin/bash
source /etc/profile.d/rvm.sh 2>/dev/null
rvm list
ruby -v
EOF
        
        # Make the script executable
        chmod +x /home/redmine/check_ruby_version.sh
        chown redmine:redmine /home/redmine/check_ruby_version.sh
        
        # Execute the script as redmine user
        RUBY_VERSION_OUTPUT=$(su redmine -c "/home/redmine/check_ruby_version.sh")
        log "Current Ruby version: $RUBY_VERSION_OUTPUT"
        
        # Check if Ruby 3.2.2 is installed, if not install it
        if ! echo "$RUBY_VERSION_OUTPUT" | grep -q "ruby-3.2.2"; then
            log "Ruby 3.2.2 is not installed. Installing it now..."
            execute "su redmine -c \"bash -l -c 'source /etc/profile.d/rvm.sh 2>/dev/null && rvm install 3.2.2'\"" "Failed to install Ruby 3.2.2"
            
            # Verify installation
            RUBY_VERSION_OUTPUT=$(su redmine -c "/home/redmine/check_ruby_version.sh")
            log "After installation, Ruby version: $RUBY_VERSION_OUTPUT"
        fi
        
        # Set Ruby 3.2.2 as default for redmine user
        log "Setting Ruby 3.2.2 as default for redmine user..."
        execute "su redmine -c \"bash -l -c 'source /etc/profile.d/rvm.sh 2>/dev/null && rvm use 3.2.2 --default'\"" "Failed to set Ruby 3.2.2 as default"
        
        # Install Bundler first
        log "Installing Bundler..."
        execute "su redmine -c \"bash -l -c 'source /etc/profile.d/rvm.sh 2>/dev/null && rvm use 3.2.2 --default && gem install bundler --no-document'\"" "Failed to install Bundler"
        
        # Install gems with the correct Ruby version
        log "Installing gems..."
        execute "su redmine -c \"bash -l -c 'source /etc/profile.d/rvm.sh 2>/dev/null && rvm use 3.2.2 --default && cd ${redmine_app_dir} && bundle install'\"" "Failed to install gems"
    else
        echo -e "${BLUE}[DRY RUN] Would install Bundler and required gems${NC}"
    fi
    
    log "Generating secret token..."
    if [ "$DRY_RUN" = false ]; then
        execute "su redmine -c \"bash -l -c 'source /etc/profile.d/rvm.sh 2>/dev/null && rvm use ${RUBY_VERSION} --default 2>/dev/null && cd ${redmine_app_dir} && bundle exec rake generate_secret_token'\"" "Failed to generate secret token"
    else
        echo -e "${BLUE}[DRY RUN] Would generate secret token${NC}"
    fi
    
    log "Migrating database..."
    if [ "$DRY_RUN" = false ]; then
        execute "su redmine -c \"bash -l -c 'source /etc/profile.d/rvm.sh 2>/dev/null && rvm use ${RUBY_VERSION} --default 2>/dev/null && cd ${redmine_app_dir} && RAILS_ENV=production bundle exec rake db:migrate'\"" "Failed to migrate database"
    else
        echo -e "${BLUE}[DRY RUN] Would migrate database${NC}"
    fi
    
    log "Loading default data..."
    if [ "$DRY_RUN" = false ]; then
        execute "su redmine -c \"bash -l -c 'source /etc/profile.d/rvm.sh 2>/dev/null && rvm use ${RUBY_VERSION} --default 2>/dev/null && cd ${redmine_app_dir} && RAILS_ENV=production REDMINE_LANG=en bundle exec rake redmine:load_default_data'\"" "Failed to load default data"
    else
        echo -e "${BLUE}[DRY RUN] Would load default data${NC}"
    fi
    
    log "Creating systemd service for Redmine..."
    if [ "$DRY_RUN" = false ]; then
        cat > /etc/systemd/system/redmine.service << EOF
[Unit]
Description=Redmine server
After=network.target
After=mysqld.service

[Service]
Type=simple
User=redmine
Group=redmine
WorkingDirectory=/home/redmine/redmine
ExecStart=/bin/bash -l -c 'bundle exec rails server -e production -b 0.0.0.0'
TimeoutSec=300
RestartSec=10
Restart=always

[Install]
WantedBy=multi-user.target
EOF

        log "Enabling Redmine service..."
        systemctl daemon-reload
        systemctl enable redmine.service
    else
        echo -e "${BLUE}[DRY RUN] Would create systemd service for Redmine${NC}"
    fi
    
    log "Redmine installation completed!"
}

# Configure Nginx and Passenger
configure_nginx() {
    section "🌐 Configuring Nginx and Passenger"
    
    # Check if Nginx is already configured for Redmine
    if [ "$DRY_RUN" = false ]; then
        if [ -f "/etc/nginx/sites-available/redmine" ] && grep -q "${DOMAIN}" "/etc/nginx/sites-available/redmine"; then
            log "Nginx appears to be already configured for Redmine with domain ${DOMAIN}"
            log "Checking if configuration needs updates..."
            
            # Check if passenger is installed
            if dpkg -l | grep -q "libnginx-mod-http-passenger"; then
                log "Passenger module is already installed"
            else
                log "Passenger module is not installed, installing it..."
                log "Using Ubuntu 24.04 native Passenger packages..."
                execute "apt install -y passenger ruby3.2 libnginx-mod-http-passenger" "Failed to install Passenger"
            fi
            
            # Update Nginx configuration with current settings
            log "Updating Nginx configuration for Redmine..."
            create_nginx_config=true
        else
            log "Nginx is not configured for Redmine, proceeding with configuration"
            
            log "Installing Passenger..."
            log "Using Ubuntu 24.04 native Passenger packages..."
            execute "apt install -y passenger ruby3.2 libnginx-mod-http-passenger" "Failed to install Passenger"
            create_nginx_config=true
        fi
        
        # Ensure Passenger is enabled in Nginx
        log "Ensuring Passenger is enabled in Nginx..."
        if [ ! -d "/etc/nginx/conf.d" ]; then
            log "Creating /etc/nginx/conf.d directory..."
            execute "mkdir -p /etc/nginx/conf.d" "Failed to create Passenger directory"
        fi
        
        # First, completely clean up any existing Passenger configurations
        log "Cleaning up existing Passenger configurations..."
        
        # First, check if passenger.conf exists and remove it
        if [ -f "/etc/nginx/conf.d/passenger.conf" ]; then
            log "Removing existing passenger.conf..."
            execute "rm -f /etc/nginx/conf.d/passenger.conf" "Failed to remove passenger.conf"
        fi
        
        # More aggressive approach to remove passenger.conf references
        log "Removing any passenger.conf references from nginx.conf..."
        execute "grep -q 'passenger.conf' /etc/nginx/nginx.conf && sed -i \"/passenger.conf/d\" /etc/nginx/nginx.conf || true" "Failed to update nginx.conf"
        
        # Create a backup of the original nginx.conf
        log "Backing up original nginx.conf..."
        execute "cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak" "Failed to backup nginx.conf"
        
        # Force complete nginx.conf replacement with a fresh, clean configuration
        # Writing directly to /etc/nginx/nginx.conf to avoid any intermediate steps that could fail
        log "Creating a fresh, clean nginx.conf without any passenger references..."
        cat > /etc/nginx/nginx.conf << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events {
        worker_connections 768;
}

http {
        ##
        # Basic Settings
        ##

        sendfile on;
        tcp_nopush on;
        types_hash_max_size 2048;

        include /etc/nginx/mime.types;
        default_type application/octet-stream;

        ##
        # SSL Settings
        ##

        ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers on;

        ##
        # Logging Settings
        ##

        access_log /var/log/nginx/access.log;

        ##
        # Gzip Settings
        ##

        gzip on;

        ##
        # Virtual Host Configs
        ##
        # Using wildcard includes to load all configuration files
        # This will include mod-http-passenger.conf automatically

        include /etc/nginx/conf.d/*.conf;
        include /etc/nginx/sites-enabled/*;
}
EOF
        
        # No need to move a temporary file as we're writing directly to nginx.conf
        
        # Make sure mod-http-passenger module is enabled
        if [ -f "/etc/nginx/modules-available/mod-http-passenger.load" ]; then
            log "Enabling Passenger module..."
            execute "ln -sf /etc/nginx/modules-available/mod-http-passenger.load /etc/nginx/modules-enabled/50-mod-http-passenger.conf" "Failed to enable Passenger module"
        fi
        
        # Use the existing mod-http-passenger.conf which is created by the package
        log "Using package-provided Passenger configuration..."
        
        # We don't need to create any additional configuration files as the module
        # already provides all necessary configuration in mod-http-passenger.conf
        
        # Make sure the passenger module is included in nginx.conf
        if ! grep -q "passenger_" /etc/nginx/nginx.conf; then
            # No need to add passenger.conf manually - it will be loaded via the wildcard include
            # Make sure mod-http-passenger.conf is available in conf.d directory
            log "Ensuring mod-http-passenger.conf is properly included..."
            execute "test -f /etc/nginx/conf.d/mod-http-passenger.conf || echo 'mod-http-passenger.conf is missing'" "Failed to check for mod-http-passenger.conf"
        else
            log "Passenger module is already included in Nginx configuration"
        fi
    else
        echo -e "${BLUE}[DRY RUN] Would check if Nginx is already configured for Redmine${NC}"
        create_nginx_config=true
    fi
    
    # Create or update Nginx server block for Redmine
    if [ "$create_nginx_config" = "true" ]; then
        log "Creating Nginx server block for Redmine..."
        if [ "$DRY_RUN" = false ]; then
            cat > /etc/nginx/sites-available/redmine << EOF
server {
    listen 80;
    server_name ${DOMAIN};
    root /home/redmine/redmine/public;

    passenger_enabled on;
    passenger_min_instances 2;
    passenger_app_env production;
    passenger_friendly_error_pages off;

    # Add security headers
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-XSS-Protection "1; mode=block";

    client_max_body_size 10m;
    
    access_log /var/log/nginx/redmine_access.log;
    error_log /var/log/nginx/redmine_error.log;
}
EOF
        else
            echo -e "${BLUE}[DRY RUN] Would create Nginx server block for Redmine${NC}"
        fi
        
        log "Enabling the Redmine site..."
        execute "ln -sf /etc/nginx/sites-available/redmine /etc/nginx/sites-enabled/" "Failed to enable Redmine site"
    fi
    
    log "Testing Nginx configuration..."
    if [ "$DRY_RUN" = false ]; then
        nginx -t || error "Nginx configuration test failed"
    else
        echo -e "${BLUE}[DRY RUN] Would test Nginx configuration${NC}"
    fi
    
    log "Restarting Nginx..."
    execute "systemctl restart nginx" "Failed to restart Nginx"
    
    log "Nginx configuration completed!"
}

# Configure firewall
configure_firewall() {
    section "🔥 Configuring Firewall"
    
    # Check if firewall is already configured
    if [ "$DRY_RUN" = false ]; then
        if ufw status | grep -q "Status: active"; then
            log "Firewall is already active, checking rules..."
            
            # Check if SSH rule exists
            if ufw status | grep -q "OpenSSH"; then
                log "SSH rule already exists"
            else
                log "Adding SSH rule..."
                execute "ufw allow OpenSSH" "Failed to allow SSH"
            fi
            
            # Check if Nginx rule exists
            if ufw status | grep -q "Nginx Full"; then
                log "Nginx rule already exists"
            else
                log "Adding Nginx rule..."
                execute "ufw allow 'Nginx Full'" "Failed to allow Nginx"
            fi
            
            log "Firewall is already properly configured"
        else
            log "Firewall is not active, configuring it..."
            log "Setting up UFW firewall..."
            execute "ufw allow OpenSSH" "Failed to allow SSH"
            execute "ufw allow 'Nginx Full'" "Failed to allow Nginx"
            
            log "Enabling firewall..."
            if [ "$DRY_RUN" = false ]; then
                echo "y" | ufw enable || warning "Failed to enable firewall. Please check manually."
            else
                echo -e "${BLUE}[DRY RUN] Would enable UFW firewall${NC}"
            fi
        fi
    else
        echo -e "${BLUE}[DRY RUN] Would check if firewall is already configured${NC}"
        log "Setting up UFW firewall..."
        echo -e "${BLUE}[DRY RUN] Would configure UFW firewall rules${NC}"
    fi
    
    log "Firewall configuration completed!"
}

# Secure with Let's Encrypt SSL
configure_ssl() {
    section "🔐 Securing with Let's Encrypt SSL"
    
    # Check if SSL certificate already exists
    if [ "$DRY_RUN" = false ]; then
        if [ -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
            log "SSL certificate for ${DOMAIN} already exists"
            
            # Check certificate expiration date
            if command -v openssl &> /dev/null && [ -f "/etc/letsencrypt/live/${DOMAIN}/cert.pem" ]; then
                expiry_date=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/${DOMAIN}/cert.pem" | cut -d= -f2)
                log "Certificate expires on: $expiry_date"
                
                # Calculate days until expiry
                expiry_epoch=$(date -d "$expiry_date" +%s)
                current_epoch=$(date +%s)
                days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
                
                if [ "$days_left" -lt 30 ]; then
                    log "Certificate will expire in less than 30 days, renewing..."
                    execute "certbot renew" "Failed to renew SSL certificate"
                else
                    log "Certificate is still valid for $days_left days, no renewal needed"
                fi
            else
                log "Unable to check certificate expiration, will try to renew anyway"
                execute "certbot renew" "Failed to renew SSL certificate"
            fi
            
            log "SSL certificate is already configured"
            return 0
        else
            log "No SSL certificate found for ${DOMAIN}, proceeding with installation"
        fi
    else
        echo -e "${BLUE}[DRY RUN] Would check if SSL certificate already exists${NC}"
    fi
    
    log "Installing Certbot and Nginx plugin..."
    execute "apt install -y certbot python3-certbot-nginx snapd" "Failed to install Certbot"
    
    # Ensure we have the latest Certbot via snap
    execute "snap install --classic certbot" "Failed to install Certbot via snap"
    execute "ln -sf /snap/bin/certbot /usr/bin/certbot" "Failed to create Certbot symlink"
    
    log "Obtaining and installing SSL certificate for main domain only..."
    # Versuche erst, nur die Hauptdomäne zu verwenden, wenn dies fehlschlägt, versuche es mit beiden
    if ! execute "certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos --email ${EMAIL}" "" 2>/dev/null; then
        log "Retrying SSL certificate generation without www subdomain due to DNS issues..."
        execute "certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos --email ${EMAIL}" "Failed to obtain SSL certificate"
    fi
    
    log "Verifying automatic renewal..."
    if [ "$DRY_RUN" = false ]; then
        certbot renew --dry-run || warning "SSL certificate renewal test failed"
    else
        echo -e "${BLUE}[DRY RUN] Would verify automatic SSL renewal${NC}"
    fi
    
    log "SSL configuration completed!"
}

# Main installation function
install_redmine_complete() {
    section "🚀 Starting Redmine Installation"
    
    # Record start time
    start_time=$(date +%s)
    
    # Run all installation steps (respecting skip flags)
    check_root
    
    if [ "$SKIP_DEPENDENCIES" = false ]; then
        install_dependencies
    else
        log "Skipping dependency installation as requested"
    fi
    
    if [ "$SKIP_RUBY" = false ]; then
        install_ruby
    else
        log "Skipping Ruby installation as requested"
    fi
    
    if [ "$SKIP_REDMINE_USER" = false ]; then
        create_redmine_user
    else
        log "Skipping Redmine user creation as requested"
    fi
    
    if [ "$SKIP_DATABASE" = false ]; then
        configure_database
    else
        log "Skipping database configuration as requested"
    fi
    
    if [ "$SKIP_REDMINE" = false ]; then
        install_redmine
    else
        log "Skipping Redmine installation as requested"
    fi
    
    if [ "$SKIP_NGINX" = false ]; then
        configure_nginx
    else
        log "Skipping Nginx configuration as requested"
    fi
    
    if [ "$SKIP_FIREWALL" = false ]; then
        configure_firewall
    else
        log "Skipping firewall configuration as requested"
    fi
    
    if [ "$SKIP_SSL" = false ]; then
        configure_ssl
    else
        log "Skipping SSL configuration as requested"
    fi
    
    # Calculate execution time
    end_time=$(date +%s)
    execution_time=$((end_time - start_time))
    minutes=$((execution_time / 60))
    seconds=$((execution_time % 60))
    
    section "✅ Redmine Installation Completed!"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${GREEN}Redmine installation DRY RUN completed. No changes were made.${NC}"
    else
        echo -e "${GREEN}Redmine has been successfully installed and configured!${NC}"
        echo -e "${GREEN}Installation took ${minutes} minutes and ${seconds} seconds.${NC}"
        echo ""
        echo -e "${BLUE}You can now access your Redmine instance at:${NC}"
        echo -e "${YELLOW}https://${DOMAIN}${NC}"
        echo ""
        echo -e "${BLUE}Default login information:${NC}"
        echo -e "${YELLOW}Username: admin${NC}"
        echo -e "${YELLOW}Password: admin${NC}"
        echo ""
        echo -e "${RED}Important: Please login and change the default admin password immediately!${NC}"
        echo ""
        echo -e "${BLUE}Installation log is available at:${NC} ${YELLOW}${LOG_FILE}${NC}"
    fi
}

# Run the installation
install_redmine_complete

