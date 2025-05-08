#!/bin/bash

# Canvas LMS Installation Script for Ubuntu 24.04
# Based on official documentation and community guides, adapted for Ubuntu 24.04

set -e  # Exit on error
set -o pipefail  # Exit on command failures within pipes
set -u  # Exit on unset variables

# --- Configuration ---
CANVAS_RUBY_VERSION="3.3.1"
CANVAS_BRANCH="prod"        # Target Canvas LMS branch to checkout

# ANSI color codes for better readability
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Global Variables (will be set by user or script) ---
SCRIPT_RUNNER_USER=""
SCRIPT_RUNNER_USER_HOME=""
DOMAIN=""
PG_PASSWORD=""
EMAIL_SENDER=""
USE_SSL=""
ADMIN_EMAIL=""
ADMIN_PASSWORD=""
ENCRYPTION_KEY="" # Will be generated

# Function to display messages with formatting
log_msg() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if a command succeeded
check_success() {
    if [ $? -ne 0 ]; then
        log_error "$1 failed. Exiting."
        exit 1
    fi
    log_msg "$1 succeeded."
}

# Function to check system requirements
check_requirements() {
    log_msg "Checking system requirements..."

    SCRIPT_RUNNER_USER=$(whoami)
    SCRIPT_RUNNER_USER_HOME=$(eval echo ~$SCRIPT_RUNNER_USER)

    if [ -z "$SCRIPT_RUNNER_USER_HOME" ]; then
        log_error "Could not determine home directory for user $SCRIPT_RUNNER_USER."
        exit 1
    fi
    log_msg "Script running as user: $SCRIPT_RUNNER_USER (Home: $SCRIPT_RUNNER_USER_HOME)"

    if [ "$EUID" -eq 0 ]; then
        log_error "Please don't run this script as root. It will use sudo when needed."
        exit 1
    fi

    if ! command -v lsb_release &> /dev/null; then
        sudo apt update && sudo apt install -y lsb-release
        check_success "lsb-release installation"
    fi

    UBUNTU_VERSION=$(lsb_release -rs)
    if [[ "$UBUNTU_VERSION" != "24.04" ]]; then
        log_warn "This script is optimized for Ubuntu 24.04. You're running: $UBUNTU_VERSION"
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    MIN_RAM_MB=3800 # Canvas recommends at least 4GB RAM
    RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    if [[ $RAM_MB -lt $MIN_RAM_MB ]]; then
        log_error "Insufficient RAM ($RAM_MB MB). Canvas LMS requires at least 4GB (4000 MB)."
        exit 1
    fi
    log_msg "RAM check passed: $RAM_MB MB available."

    for cmd in curl git sudo systemctl apt free; do
        if ! command -v $cmd &> /dev/null; then
            log_error "$cmd is required but not installed. Please install it and try again."
            exit 1
        fi
    done

    log_msg "System requirements check completed."
}

# Function to prompt user for configuration
prompt_user_input() {
    log_msg "Configuring Canvas LMS installation parameters..."

    read -p "Enter domain name for Canvas LMS (e.g., canvas.example.com): " DOMAIN_INPUT
    while [[ -z "$DOMAIN_INPUT" ]]; do
        log_error "Domain name cannot be empty."
        read -p "Enter domain name for Canvas LMS: " DOMAIN_INPUT
    done
    DOMAIN="$DOMAIN_INPUT"

    read -sp "Enter PostgreSQL password for canvasuser: " PG_PASSWORD_INPUT
    echo
    while [[ -z "$PG_PASSWORD_INPUT" ]]; do
        log_error "PostgreSQL password cannot be empty."
        read -sp "Enter PostgreSQL password for canvasuser: " PG_PASSWORD_INPUT
        echo
    done
    PG_PASSWORD="$PG_PASSWORD_INPUT"

    read -p "Enter email sender address (e.g., no-reply@$DOMAIN): " EMAIL_SENDER_INPUT
    while [[ -z "$EMAIL_SENDER_INPUT" ]]; do
        log_error "Email sender address cannot be empty."
        read -p "Enter email sender address: " EMAIL_SENDER_INPUT
    done
    EMAIL_SENDER="$EMAIL_SENDER_INPUT"

    read -p "Use SSL (Let's Encrypt)? (yes/no) [yes]: " USE_SSL_INPUT
    USE_SSL_INPUT=${USE_SSL_INPUT:-yes}
    while [[ "$USE_SSL_INPUT" != "yes" && "$USE_SSL_INPUT" != "no" ]]; do
        log_error "Please enter 'yes' or 'no'."
        read -p "Use SSL (Let's Encrypt)? (yes/no) [yes]: " USE_SSL_INPUT
        USE_SSL_INPUT=${USE_SSL_INPUT:-yes}
    done
    USE_SSL="$USE_SSL_INPUT"

    read -p "Enter Canvas admin email address: " ADMIN_EMAIL_INPUT
    while [[ -z "$ADMIN_EMAIL_INPUT" ]]; do
        log_error "Admin email cannot be empty."
        read -p "Enter Canvas admin email address: " ADMIN_EMAIL_INPUT
    done
    ADMIN_EMAIL="$ADMIN_EMAIL_INPUT"

    read -sp "Enter Canvas admin password: " ADMIN_PASSWORD_INPUT
    echo
    while [[ -z "$ADMIN_PASSWORD_INPUT" ]]; do
        log_error "Admin password cannot be empty."
        read -sp "Enter Canvas admin password: " ADMIN_PASSWORD_INPUT
        echo
    done
    ADMIN_PASSWORD="$ADMIN_PASSWORD_INPUT"

    log_msg "Configuration parameters collected."
}

# Function to install dependencies for Ubuntu 24.04
install_dependencies() {
    log_msg "Installing system dependencies for Ubuntu 24.04..."

    sudo apt update && sudo apt upgrade -y
    check_success "System update and upgrade"

    log_msg "Installing base dependencies..."
    sudo apt install -y git curl gnupg2 postgresql postgresql-contrib redis-server libpq-dev \
        libxml2-dev libxslt1-dev libsqlite3-dev apache2 libapache2-mod-passenger \
        imagemagick libmagickwand-dev zlib1g-dev build-essential libssl-dev \
        libreadline-dev libyaml-dev sqlite3 libcurl4-openssl-dev libffi-dev \
        python3-pip certbot python3-certbot-apache \
        pkg-config libidn11-dev libxmlsec1-dev
    check_success "Base dependencies installation"

    log_msg "Installing Node.js 20.x LTS..."
    if ! command -v node &> /dev/null || [[ $(node -v | cut -d. -f1 | tr -d 'v') -lt 20 ]]; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
        check_success "NodeSource setup script execution"
        sudo apt install -y nodejs
        check_success "Node.js installation"
    else
        log_msg "Node.js 20.x or newer already installed."
    fi
    NODE_VERSION=$(node -v)
    log_msg "Node.js version: $NODE_VERSION"

    log_msg "Enabling Corepack for Yarn package management..."
    sudo corepack enable
    check_success "Corepack enable"
    if ! command -v yarn &> /dev/null; then
        log_warn "Yarn not found after corepack enable, attempting global npm install."
        sudo npm install -g yarn 
        check_success "Yarn global installation fallback"
    fi
    YARN_VERSION=$(yarn --version)
    log_msg "Yarn version: $YARN_VERSION"

    log_msg "Installing Ruby ${CANVAS_RUBY_VERSION} using rbenv..."
    if ! command -v rbenv &> /dev/null; then
        git clone https://github.com/rbenv/rbenv.git "${SCRIPT_RUNNER_USER_HOME}/.rbenv"
        check_success "Cloning rbenv repository"
        echo 'export PATH="'"$SCRIPT_RUNNER_USER_HOME"'/.rbenv/bin:$PATH"' >> "${SCRIPT_RUNNER_USER_HOME}/.bashrc"
        echo 'eval "$(rbenv init -)"' >> "${SCRIPT_RUNNER_USER_HOME}/.bashrc"

        git clone https://github.com/rbenv/ruby-build.git "${SCRIPT_RUNNER_USER_HOME}/.rbenv/plugins/ruby-build"
        check_success "Cloning ruby-build repository"
        echo 'export PATH="'"$SCRIPT_RUNNER_USER_HOME"'/.rbenv/plugins/ruby-build/bin:$PATH"' >> "${SCRIPT_RUNNER_USER_HOME}/.bashrc"
        
        log_msg "rbenv installed. Sourcing ~/.bashrc or opening a new terminal may be needed for rbenv in future interactive shells."
        export PATH="${SCRIPT_RUNNER_USER_HOME}/.rbenv/bin:${SCRIPT_RUNNER_USER_HOME}/.rbenv/plugins/ruby-build/bin:$PATH"
        eval "$(rbenv init -)"
    else
        log_msg "rbenv already installed."
        if [[ ! "$PATH" == *"$SCRIPT_RUNNER_USER_HOME/.rbenv/shims"* ]]; then 
            export PATH="${SCRIPT_RUNNER_USER_HOME}/.rbenv/shims:${SCRIPT_RUNNER_USER_HOME}/.rbenv/bin:$PATH"
            eval "$(rbenv init -)"
        fi
    fi
    
    if ! rbenv versions | grep -q "$CANVAS_RUBY_VERSION"; then
        log_msg "Installing Ruby $CANVAS_RUBY_VERSION (this may take a while)..."
        (cd "${SCRIPT_RUNNER_USER_HOME}/.rbenv" && git pull)
        (cd "${SCRIPT_RUNNER_USER_HOME}/.rbenv/plugins/ruby-build" && git pull)
        rbenv install "$CANVAS_RUBY_VERSION"
        check_success "Ruby $CANVAS_RUBY_VERSION installation via rbenv"
    else
        log_msg "Ruby $CANVAS_RUBY_VERSION already installed via rbenv."
    fi
    rbenv global "$CANVAS_RUBY_VERSION"
    check_success "Setting rbenv global Ruby version to $CANVAS_RUBY_VERSION"
    RUBY_VERSION_OUTPUT=$(ruby -v) 
    if [[ -z "$RUBY_VERSION_OUTPUT" || ! "$RUBY_VERSION_OUTPUT" == *"$CANVAS_RUBY_VERSION"* ]]; then
        log_error "Ruby version $CANVAS_RUBY_VERSION was not correctly set or found after installation."
        log_error "Current ruby -v: $RUBY_VERSION_OUTPUT"
        exit 1
    fi
    log_msg "Ruby version configured: $RUBY_VERSION_OUTPUT"

    log_msg "Installing/Updating Bundler..."
    gem install bundler 
    check_success "Bundler installation/update"
    rbenv rehash 

    log_msg "Enabling required Apache modules..."
    sudo a2enmod rewrite ssl passenger headers proxy proxy_http
    check_success "Enabling Apache modules (rewrite, ssl, passenger, headers, proxy, proxy_http)"

    log_msg "Dependencies installation completed."
}

# Function to configure PostgreSQL
configure_postgresql() {
    log_msg "Configuring PostgreSQL..."
    sudo systemctl start postgresql
    check_success "Starting PostgreSQL service"
    sudo systemctl enable postgresql
    check_success "Enabling PostgreSQL service on boot"

    log_msg "Creating database user 'canvasuser' and database 'canvas_production'..."
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='canvasuser'" | grep -q 1; then
        log_warn "PostgreSQL user 'canvasuser' already exists. Skipping creation."
    else
        sudo -u postgres psql -c "CREATE USER canvasuser WITH PASSWORD '$PG_PASSWORD' CREATEDB;"
        check_success "Creating PostgreSQL user 'canvasuser'"
    fi
    
    if sudo -u postgres psql -lt | cut -d \| -f 1 | grep -qw canvas_production; then
        log_warn "Database 'canvas_production' already exists. Skipping creation."
    else
        sudo -u postgres createdb canvas_production --owner=canvasuser
        check_success "Creating PostgreSQL database 'canvas_production'"
    fi

    log_msg "Optimizing PostgreSQL configuration for Canvas..."
    PGVERSION_FULL=$(sudo -u postgres psql -t -c "SHOW server_version;")
    PGVERSION=$(echo "$PGVERSION_FULL" | cut -d. -f1 | tr -dc '0-9')

    if [ -z "$PGVERSION" ]; then
        log_warn "Could not determine PostgreSQL major version. Skipping automated optimization."
        return
    fi
    log_msg "Detected PostgreSQL major version: $PGVERSION"
    PGCONFIG="/etc/postgresql/$PGVERSION/main/postgresql.conf"

    if [ -f "$PGCONFIG" ]; then
        if grep -q "# Canvas LMS recommended settings" "$PGCONFIG"; then
            log_msg "Canvas LMS PostgreSQL settings appear to be already applied in $PGCONFIG."
        else
            sudo cp "$PGCONFIG" "${PGCONFIG}.bak.$(date +%F-%T)"
            check_success "Backing up postgresql.conf to ${PGCONFIG}.bak..."
            sudo bash -c "cat >> $PGCONFIG" << EOF

# Canvas LMS recommended settings (adjust based on server resources)
shared_buffers = 512MB       
work_mem = 16MB              
maintenance_work_mem = 256MB 
effective_cache_size = 1536MB 
EOF
            check_success "Appending Canvas settings to $PGCONFIG"
            log_msg "Restarting PostgreSQL to apply configuration changes..."
            sudo systemctl restart postgresql
            check_success "Restarting PostgreSQL service"
        fi
    else
        log_warn "PostgreSQL config file not found at $PGCONFIG. Skipping automated optimization."
    fi
    log_msg "PostgreSQL configuration completed."
}

# Function to configure Redis
configure_redis() {
    log_msg "Configuring Redis..."
    sudo systemctl start redis-server
    check_success "Starting Redis service"
    sudo systemctl enable redis-server
    check_success "Enabling Redis service on boot"

    if ! redis-cli ping | grep -q "PONG"; then
        log_error "Redis is not responding. Please check Redis configuration and status."
        exit 1
    fi
    log_msg "Redis configuration completed and server is responsive."
}

# Function to install Canvas LMS
install_canvas() {
    log_msg "Installing Canvas LMS from branch '$CANVAS_BRANCH'..."
    if [ -d "/var/canvas" ]; then
        log_warn "Directory /var/canvas already exists."
        read -p "Remove /var/canvas for a fresh clone? (Highly recommended) (y/n) [y]: " -n 1 -r REPLY_RM_CANVAS
        REPLY_RM_CANVAS=${REPLY_RM_CANVAS:-y}
        echo
        if [[ $REPLY_RM_CANVAS =~ ^[Yy]$ ]]; then
            sudo rm -rf /var/canvas
            check_success "Removing existing /var/canvas directory"
        else
            log_warn "Proceeding with existing /var/canvas. This might lead to unexpected issues."
        fi
    fi

    sudo mkdir -p /var/canvas
    check_success "Creating /var/canvas directory"
    sudo chown "$SCRIPT_RUNNER_USER":"$SCRIPT_RUNNER_USER" /var/canvas
    check_success "Setting ownership of /var/canvas to $SCRIPT_RUNNER_USER for setup"

    log_msg "Cloning Canvas LMS repository (branch: $CANVAS_BRANCH) into /var/canvas (this may take a while)..."
    if ! git clone --branch "$CANVAS_BRANCH" https://github.com/instructure/canvas-lms.git /var/canvas; then
        log_error "Failed to clone Canvas LMS repository (branch: $CANVAS_BRANCH)."
        exit 1
    fi
    cd /var/canvas
    check_success "Changed directory to /var/canvas"

    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [[ "$CURRENT_BRANCH" != "$CANVAS_BRANCH" ]]; then
        log_warn "Git clone did not checkout '$CANVAS_BRANCH' directly. Current branch: '$CURRENT_BRANCH'. Attempting explicit checkout..."
        git fetch origin --prune "$CANVAS_BRANCH" 
        check_success "git fetch origin --prune $CANVAS_BRANCH"
        if ! git checkout -B "$CANVAS_BRANCH" "origin/$CANVAS_BRANCH"; then
            log_error "Failed to checkout branch '$CANVAS_BRANCH' from 'origin/$CANVAS_BRANCH'."
            exit 1
        fi
    fi
    log_msg "Successfully on branch '$CANVAS_BRANCH'."

    log_msg "Listing key configuration files in /var/canvas/config/ to verify clone status..."
    ls -la /var/canvas/config/
    
    log_msg "Verifying presence of general key configuration files post-clone..."
    key_example_files=(
        "config/database.yml.example"
        "config/domain.yml.example"
    )
    for kf in "${key_example_files[@]}"; do
        if [ ! -f "$kf" ]; then
            log_error "CRITICAL: Key example file '$kf' is MISSING from /var/canvas after git clone/checkout."
            log_error "This indicates a problem with the repository clone."
            ls -la config/ 
            exit 1
        else
            log_msg "Verified: '$kf' exists in $(pwd)."
        fi
    done

    # Create .env.example if it doesn't exist
    if [ ! -f ".env.example" ]; then
        log_warn ".env.example is missing. Creating minimal version..."
        cat > .env.example << EOF
# Canvas LMS .env.example (created by install script)
CANVAS_LMS_ADMIN_EMAIL=admin@example.com
CANVAS_LMS_ADMIN_PASSWORD=password
CANVAS_LMS_ACCOUNT_NAME=Canvas LMS
CANVAS_LMS_STATS_COLLECTION=opt_out
RAILS_ENV=production
NODE_ENV=production
ENCRYPTION_KEY=
EOF
        check_success "Created minimal .env.example file"
    else
        log_msg "Verified: '.env.example' exists in $(pwd)."
    fi

    log_msg "Installing Ruby dependencies with Bundler (this may take a significant time)..."
    export PATH="${SCRIPT_RUNNER_USER_HOME}/.rbenv/shims:${SCRIPT_RUNNER_USER_HOME}/.rbenv/bin:$PATH"
    eval "$(rbenv init -)" 
    rbenv local $CANVAS_RUBY_VERSION 
    check_success "Set rbenv local to $CANVAS_RUBY_VERSION for /var/canvas"

    bundle config set --local path 'vendor/bundle' 
    check_success "bundle config set path 'vendor/bundle'"
    
    if ! bundle install --jobs=$(nproc) --retry 3; then 
        log_error "Bundle install failed. This often indicates a Ruby version mismatch or missing system dependencies."
        log_error "Current Ruby: $(ruby -v). Check /var/canvas/Gemfile or /var/canvas/.ruby-version for required Ruby."
        exit 1
    fi
    log_msg "Canvas LMS core Ruby dependencies installed."
}

# Function to configure Canvas LMS
configure_canvas() {
    log_msg "Configuring Canvas LMS application files..."
    cd /var/canvas 
    check_success "Changed directory to /var/canvas for configuration"

    for cfg_file in database dynamic_settings domain outgoing_mail security redis; do
        if [ -f "config/${cfg_file}.yml" ]; then
            log_warn "config/${cfg_file}.yml already exists. Backing up and replacing with example."
            sudo mv "config/${cfg_file}.yml" "config/${cfg_file}.yml.bak.$(date +%F-%T)"
        fi
        if [ -f "config/${cfg_file}.yml.example" ]; then 
            cp "config/${cfg_file}.yml.example" "config/${cfg_file}.yml"
            check_success "Copying config/${cfg_file}.yml.example to config/${cfg_file}.yml"
        else
            log_error "Example file config/${cfg_file}.yml.example not found in $(pwd). Clone may be incomplete."
            exit 1
        fi
    done

    log_msg "Updating database.yml..."
    sed -i "s/username: postgres/username: canvasuser/" config/database.yml
    sed -i "s/^#password:/password: '$PG_PASSWORD'/" config/database.yml 
    sed -i "s/password:$/password: '$PG_PASSWORD'/" config/database.yml 
    sed -i "s/database: canvas_development/database: canvas_production/" config/database.yml

    log_msg "Updating domain.yml..."
    sed -i "s/domain: canvas.example.com/domain: $DOMAIN/" config/domain.yml
    if [[ "$USE_SSL" == "yes" ]]; then
        sed -i "s/# ssl: true/ssl: true/" config/domain.yml
    fi
    
    log_msg "Updating outgoing_mail.yml..."
    sed -i "s/address: smtp.example.com/address: mail.example.com/" config/outgoing_mail.yml 
    sed -i "s/user_name: smtp_username/user_name: \"\"/" config/outgoing_mail.yml
    sed -i "s/password: smtp_password/password: \"\"/" config/outgoing_mail.yml
    sed -i "s/outgoing_address: canvas@example.com/outgoing_address: $EMAIL_SENDER/" config/outgoing_mail.yml
    sed -i "s/sender_address: notifications@example.com/sender_address: $EMAIL_SENDER/" config/outgoing_mail.yml 
    log_warn "Outgoing mail (SMTP) settings in config/outgoing_mail.yml are placeholders. You MUST configure them manually."

    log_msg "Generating and updating security.yml with a new encryption key..."
    ENCRYPTION_KEY=$(ruby -rsecurerandom -e 'puts SecureRandom.hex(64)' 2>/dev/null || head /dev/urandom | tr -dc 'a-f0-9' | head -c 128)
    if [ -z "$ENCRYPTION_KEY" ] || [ ${#ENCRYPTION_KEY} -lt 64 ]; then 
        log_error "Failed to generate a strong encryption key."
        exit 1
    fi
    sed -i "s|<%=[[:space:]]*SecureRandom\.hex(64)[[:space:]]*%>|${ENCRYPTION_KEY}|" config/security.yml
    check_success "Setting new encryption key in security.yml"

    local prod_rb_target="config/environments/production.rb"
    local prod_rb_source_example="config/environments/production.rb.example"
    
    log_msg "Checking for production environment configuration files..."
    ls -la config/environments/

    local source_to_copy=""

    if [ -f "$prod_rb_source_example" ]; then
        log_msg "Found source: $prod_rb_source_example"
        source_to_copy="$prod_rb_source_example"
    elif [ -f "$prod_rb_target" ] && [ ! -f "$prod_rb_source_example" ]; then
        log_warn "Source $prod_rb_source_example is MISSING."
        log_warn "However, target $prod_rb_target (production.rb without .example) exists."
        log_warn "Using existing $prod_rb_target as the base for configuration."
        source_to_copy="$prod_rb_target" 
    else
        log_warn "CRITICAL: Neither '$prod_rb_source_example' nor a pre-existing '$prod_rb_target' found in $(pwd)/config/environments/."
        log_warn "This means no suitable production environment template is available after git clone."
        log_warn "Creating minimal fallback production.rb..."
        cat > "$prod_rb_target" << 'EOF'
# Canvas LMS - Fallback Production Environment Configuration
# Created by installation script due to missing template
require_relative "../canvas_rails"

CanvasRails::Application.configure do
  config.cache_classes = true
  config.eager_load = true
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true
  config.public_file_server.enabled = true # Changed from ENV['RAILS_SERVE_STATIC_FILES'].present;
  config.assets.js_compressor = :terser # Common choice, or :uglifier if preferred/available
  config.assets.compile = false
  # config.assets.css_compressor = :sass # This is default if sass-rails is used
  config.assets.digest = true
  config.log_level = :info
  config.i18n.fallbacks = true
  config.active_support.report_deprecations = false # Changed from :notify
  config.action_controller.asset_host = ENV['CDN_HOST'] if ENV['CDN_HOST']
  # config.autoloader = :zeitwerk # Not typically set here for older Rails like Canvas might use
  
  config.force_ssl = ENV['FORCE_SSL'] == 'true' # Common practice

  # Canvas-specific settings (minimal)
  config.to_prepare do
    # Ensure any dynamic settings or initializers are loaded if Canvas uses this hook.
    # Canvas::Reloader.reload! # If this exists and is needed
  end
end
EOF
        check_success "Created fallback production.rb"
        source_to_copy="$prod_rb_target" # The newly created fallback is now the source
    fi

    if [ "$source_to_copy" != "$prod_rb_target" ]; then
        if [ -f "$prod_rb_target" ]; then
            log_warn "$prod_rb_target already exists. Backing it up before copying from $source_to_copy."
            sudo mv "$prod_rb_target" "${prod_rb_target}.bak.$(date +%F-%T)"
            check_success "Backed up existing $prod_rb_target"
        fi
        log_msg "Copying from '$source_to_copy' to '$prod_rb_target'..."
        cp "$source_to_copy" "$prod_rb_target"
        check_success "Copied $source_to_copy to $prod_rb_target"
    else
        # This case means source_to_copy was already prod_rb_target (either existed or was created as fallback)
        # No copy needed, but ensure it was backed up if it pre-existed the fallback creation.
        # The backup logic before fallback creation handles this.
        log_msg "Using $prod_rb_target (which was either pre-existing or created as fallback) as the base."
    fi


    log_msg "Preparing .env file..."
    local env_example_file=".env.example"
    local env_target_file=".env"
    if [ ! -f "$env_target_file" ]; then 
        if [ -f "$env_example_file" ]; then
            cp "$env_example_file" "$env_target_file"
            check_success "Copying $env_example_file to $env_target_file"
        else
            # If .env.example was also missing (handled in install_canvas by creating one)
            # this will use the one created in install_canvas or create a new one if that failed.
            touch "$env_target_file" 
            log_warn "$env_example_file not found, ensuring empty $env_target_file exists."
        fi
    else
        log_warn "$env_target_file already exists. Appending/updating values."
    fi
    
    declare -A env_vars
    env_vars["CANVAS_LMS_ADMIN_EMAIL"]="$ADMIN_EMAIL"
    env_vars["CANVAS_LMS_ADMIN_PASSWORD"]="$ADMIN_PASSWORD"
    env_vars["CANVAS_LMS_ACCOUNT_NAME"]="Canvas LMS at $DOMAIN"
    env_vars["CANVAS_LMS_STATS_COLLECTION"]="opt_out" 
    env_vars["RAILS_ENV"]="production"
    env_vars["NODE_ENV"]="production" 
    env_vars["ENCRYPTION_KEY"]="$ENCRYPTION_KEY"

    for key in "${!env_vars[@]}"; do
        if grep -q "^${key}=" "$env_target_file"; then
            sed -i "s|^${key}=.*|${key}=${env_vars[$key]}|" "$env_target_file"
        else
            echo "${key}=${env_vars[$key]}" >> "$env_target_file"
        fi
    done
    log_msg "Updated .env file with admin credentials and settings."
    log_msg "Canvas LMS configuration files prepared."
}

# Function to compile assets
compile_assets() {
    log_msg "Compiling Canvas assets (this can take a very long time and be memory intensive)..."
    cd /var/canvas 
    export PATH="${SCRIPT_RUNNER_USER_HOME}/.rbenv/shims:${SCRIPT_RUNNER_USER_HOME}/.rbenv/bin:$PATH"
    eval "$(rbenv init -)" 
    
    # Increase Node.js memory limit. Adjust 3072 (3GB) based on available system RAM.
    # Minimum 4GB RAM system, so 2-3GB for Node is plausible during this intensive step.
    export NODE_OPTIONS="--max-old-space-size=3072" 
    log_msg "Set NODE_OPTIONS to $NODE_OPTIONS for asset compilation."
    export NODE_ENV=production # Ensure production mode for JS builds

    log_msg "Cleaning Yarn cache..."
    if ! yarn cache clean --force; then
        log_warn "yarn cache clean --force failed, but continuing. This might not be critical."
    fi

    log_msg "Installing JavaScript dependencies with Yarn..."
    if ! yarn install --frozen-lockfile --check-files --network-timeout 600000; then
        log_warn "yarn install with --frozen-lockfile failed. Attempting 'yarn install' to update lockfile (network timeout 10min)..."
        if ! yarn install --network-timeout 600000; then
            log_warn "Standard yarn install also failed. Attempting with --ignore-engines and longer timeout (network timeout 15min)..."
            if ! yarn install --ignore-engines --network-timeout 900000; then
                 log_error "All yarn install attempts failed. Critical."
                 log_error "Check Node.js/Yarn setup (versions: Node $(node -v), Yarn $(yarn --version))."
                 log_error "Check available memory and network connectivity from the server."
                 exit 1
            fi
        fi
    fi
    check_success "Yarn install process completed (one of the attempts succeeded or was allowed to pass)"


    log_msg "Compiling assets with rake canvas:compile_assets..."
    if ! RAILS_ENV=production bundle exec rake canvas:compile_assets; then
        log_error "Asset compilation (rake canvas:compile_assets) FAILED."
        log_error "This is often due to insufficient memory for Node.js or issues with JavaScript dependencies."
        log_error "Check the detailed error output above this message from the Rake task."
        log_error "To debug further, manually 'cd /var/canvas' then run with trace:"
        log_error "  export NODE_OPTIONS=\"$NODE_OPTIONS\"; export RAILS_ENV=production; bundle exec rake canvas:compile_assets --trace"
        exit 1
    fi
    log_msg "Assets compilation completed."
}


# Function to initialize the database
initialize_database() {
    log_msg "Initializing Canvas database (this may take some time)..."
    cd /var/canvas 
    export PATH="${SCRIPT_RUNNER_USER_HOME}/.rbenv/shims:${SCRIPT_RUNNER_USER_HOME}/.rbenv/bin:$PATH"
    eval "$(rbenv init -)" 

    log_msg "Running database migrations and initial setup..."
    if ! RAILS_ENV=production bundle exec rake db:migrate; then
        log_error "Database migration (rake db:migrate) failed. Check database configuration and logs."
        exit 1
    fi
    if ! RAILS_ENV=production bundle exec rake db:initial_setup; then
        log_error "Database initial setup (rake db:initial_setup) failed. Check database logs."
        exit 1
    fi
    log_msg "Database initialization and setup completed."
}

# Function to configure Apache
configure_apache() {
    log_msg "Configuring Apache for Canvas LMS..."
    local APACHE_CONF_FILE="/etc/apache2/sites-available/canvas.conf"
    
    log_msg "Creating Apache virtual host configuration at $APACHE_CONF_FILE..."
    local PASSENGER_RUBY_PATH="${SCRIPT_RUNNER_USER_HOME}/.rbenv/versions/${CANVAS_RUBY_VERSION}/bin/ruby"
    if [ ! -f "$PASSENGER_RUBY_PATH" ]; then 
      PASSENGER_RUBY_PATH="${SCRIPT_RUNNER_USER_HOME}/.rbenv/shims/ruby"
    fi

    sudo tee "$APACHE_CONF_FILE" > /dev/null << EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    DocumentRoot /var/canvas/public
    
    PassengerAppRoot /var/canvas
    PassengerAppEnv production
    PassengerRuby $PASSENGER_RUBY_PATH

    RewriteEngine On
    RewriteCond %{HTTPS} !=on
    RewriteCond %{HTTP:X-Forwarded-Proto} !=https [NC]
    RewriteRule ^/?(.*) https://%{SERVER_NAME}/\$1 [R=301,L]

    <Directory /var/canvas/public>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/canvas_error.log
    CustomLog \${APACHE_LOG_DIR}/canvas_access.log combined
</VirtualHost>

<IfModule mod_ssl.c>
    <VirtualHost *:443>
        ServerName $DOMAIN
        DocumentRoot /var/canvas/public

        PassengerAppRoot /var/canvas
        PassengerAppEnv production
        PassengerRuby $PASSENGER_RUBY_PATH

        SSLEngine on
        # SSLCertificateFile /etc/letsencrypt/live/$DOMAIN/fullchain.pem
        # SSLCertificateKeyFile /etc/letsencrypt/live/$DOMAIN/privkey.pem
        # Include /etc/letsencrypt/options-ssl-apache.conf

        Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
        Header always set X-Content-Type-Options "nosniff"
        Header always set X-Frame-Options "SAMEORIGIN"
        Header always set Referrer-Policy "strict-origin-when-cross-origin"

        <Directory /var/canvas/public>
            Options FollowSymLinks
            AllowOverride All
            Require all granted
        </Directory>

        ErrorLog \${APACHE_LOG_DIR}/canvas_ssl_error.log
        CustomLog \${APACHE_LOG_DIR}/canvas_ssl_access.log combined
    </VirtualHost>
</IfModule>
EOF
    check_success "Creating Apache canvas.conf"

    sudo a2dissite 000-default.conf || log_warn "Could not disable 000-default.conf (maybe already disabled)."
    sudo a2ensite canvas.conf
    check_success "Enabling canvas.conf Apache site"

    log_msg "Testing Apache configuration syntax..."
    if ! sudo apache2ctl configtest; then
        log_error "Apache configuration test failed. Review $APACHE_CONF_FILE and Apache logs."
        exit 1
    fi

    log_msg "Restarting Apache to apply initial configuration..."
    sudo systemctl restart apache2
    check_success "Restarting Apache service"
    log_msg "Apache base configuration completed."
}

# Function to set up SSL with Let's Encrypt
setup_ssl() {
    if [[ "$USE_SSL" == "yes" ]]; then
        log_msg "Setting up Let's Encrypt SSL for $DOMAIN..."
        if ! sudo certbot --apache -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL" --redirect --hsts --uir; then
            log_warn "Certbot failed to obtain/install SSL certificate for $DOMAIN."
            log_warn "Check DNS for $DOMAIN and port 80 accessibility."
        else
            log_msg "SSL certificate obtained and configured by Certbot for $DOMAIN."
        fi
        log_msg "Reloading Apache to apply SSL changes..."
        sudo systemctl reload apache2 
        check_success "Reloading Apache after SSL setup"
    else
        log_msg "Skipping SSL setup. Canvas will be HTTP (insecure)."
    fi
}

# Function to configure delayed jobs
configure_delayed_jobs() {
    log_msg "Setting up background job processing (delayed_jobs) via systemd..."
    cd /var/canvas 
    export PATH="${SCRIPT_RUNNER_USER_HOME}/.rbenv/shims:${SCRIPT_RUNNER_USER_HOME}/.rbenv/bin:$PATH"
    eval "$(rbenv init -)"

    local DJ_SERVICE_FILE="/etc/systemd/system/canvas_delayed_jobs.service"
    log_msg "Creating systemd service file for delayed_jobs at $DJ_SERVICE_FILE..."
    local RBENV_EXEC_PATH="${SCRIPT_RUNNER_USER_HOME}/.rbenv/shims/bundle"

    sudo tee "$DJ_SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=Canvas LMS Delayed Jobs Worker
After=network.target postgresql.service redis-server.service apache2.service
Requires=postgresql.service redis-server.service

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/var/canvas
Environment=RAILS_ENV=production
ExecStart=$RBENV_EXEC_PATH exec script/delayed_job run
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    check_success "Creating canvas_delayed_jobs.service file"

    sudo systemctl daemon-reload
    check_success "Reloading systemd daemon configuration"
    sudo systemctl enable canvas_delayed_jobs.service
    check_success "Enabling canvas_delayed_jobs service on boot"
    log_msg "Background job processing (delayed_jobs) service configured."
}

# Function to set security permissions
set_security_permissions() {
    log_msg "Setting final security permissions for /var/canvas and rbenv access for www-data..."

    sudo chown -R www-data:www-data /var/canvas
    check_success "Setting ownership of /var/canvas to www-data:www-data"

    sudo chmod -R u=rwX,g=rX,o=rX /var/canvas/public 
    sudo find /var/canvas/tmp /var/canvas/log -type d -exec chmod 0750 {} \; 
    sudo find /var/canvas/tmp /var/canvas/log -type f -exec chmod 0640 {} \; 

    sudo -u www-data mkdir -p /var/canvas/tmp/pids /var/canvas/tmp/cache /var/canvas/log /var/canvas/public/assets
    check_success "Ensuring critical subdirectories exist under www-data ownership"

    log_msg "Configuring rbenv access for 'www-data' user..."
    read -p "Proceed with 'chmod o+x ${SCRIPT_RUNNER_USER_HOME}' and 'chmod -R go+rx ${SCRIPT_RUNNER_USER_HOME}/.rbenv'? (y/n) [y]: " -n 1 -r REPLY_PERM
    REPLY_PERM=${REPLY_PERM:-y}
    echo
    if [[ $REPLY_PERM =~ ^[Yy]$ ]]; then
        sudo chmod o+x "${SCRIPT_RUNNER_USER_HOME}"
        check_success "chmod o+x on ${SCRIPT_RUNNER_USER_HOME}"
        if [ -d "${SCRIPT_RUNNER_USER_HOME}/.rbenv" ]; then
            sudo chmod -R go+rx "${SCRIPT_RUNNER_USER_HOME}/.rbenv"
            check_success "chmod -R go+rx on ${SCRIPT_RUNNER_USER_HOME}/.rbenv"
            log_msg "Permissions updated for rbenv access by www-data."
        else
            log_warn "rbenv directory not found at ${SCRIPT_RUNNER_USER_HOME}/.rbenv. Skipping."
            log_error "Delayed jobs will likely fail."
        fi
    else
        log_warn "Skipping rbenv permission changes for www-data."
        log_error "The canvas_delayed_jobs service will likely fail."
    fi
    log_msg "Security permissions setup step completed."
}

# Function to restart all services
restart_services() {
    log_msg "Restarting all relevant services..."
    sudo systemctl restart postgresql
    check_success "Restarting PostgreSQL service"
    sudo systemctl restart redis-server
    check_success "Restarting Redis service"
    sudo systemctl restart apache2
    check_success "Restarting Apache2 service"
    sudo systemctl restart canvas_delayed_jobs
    check_success "Restarting canvas_delayed_jobs service" 
    log_msg "All relevant services restarted."
}

# Function to display installation summary
installation_summary() {
    log_msg "Canvas LMS Installation Summary:"
    echo "------------------------------------"
    local protocol="http"
    if [[ "$USE_SSL" == "yes" ]]; then
        if [ -L "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
            protocol="https"
        else
            log_warn "SSL requested, but Let's Encrypt certificate for $DOMAIN not found. URL defaults to http."
        fi
    fi
    echo -e "Canvas URL: ${GREEN}${protocol}://$DOMAIN${NC}"
    echo "Admin Email: $ADMIN_EMAIL"
    echo "Installation Directory: /var/canvas, Branch: $CANVAS_BRANCH"
    local current_ruby_version
    current_ruby_version=$(cd /var/canvas && export PATH="${SCRIPT_RUNNER_USER_HOME}/.rbenv/shims:${SCRIPT_RUNNER_USER_HOME}/.rbenv/bin:$PATH" && eval "$(rbenv init -)" && ruby -v 2>/dev/null || echo "Ruby N/A")
    echo "Ruby Version: $current_ruby_version (Target: $CANVAS_RUBY_VERSION)"
    echo "Node.js Version: $(node -v)"
    echo "------------------------------------"
    log_msg "Access Canvas: ${protocol}://$DOMAIN (Admin: $ADMIN_EMAIL)"

    log_msg "Check logs if issues:"
    echo "  App: /var/canvas/log/production.log | Apache: /var/log/apache2/canvas_*.log"
    echo "  Jobs: sudo journalctl -u canvas_delayed_jobs.service -f"

    local HEALTH_CHECK_SCRIPT="/usr/local/bin/canvas-health-check.sh"
    log_msg "Creating health check script at $HEALTH_CHECK_SCRIPT"
    sudo tee "$HEALTH_CHECK_SCRIPT" > /dev/null << EOF
#!/bin/bash
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
echo -e "\${GREEN}=== Canvas LMS Health Check (\$(date)) ===\${NC}"
echo "Domain: $DOMAIN | Protocol: $protocol"
echo
echo "1. Services:"
for s in postgresql redis-server apache2 canvas_delayed_jobs; do
  st=\$(systemctl is-active \$s 2>/dev/null)
  [[ "\$st" = "active" ]] && echo -e "  [\${GREEN}OK\${NC}] \$s: \$st" || echo -e "  [\${RED}FAIL\${NC}] \$s: \$st (sudo systemctl status \$s)"
done
echo
echo "2. DB Connect:"
sudo -u postgres psql -d canvas_production -c "SELECT 1;" &>/dev/null && echo -e "  [\${GREEN}OK\${NC}] canvas_production" || echo -e "  [\${RED}FAIL\${NC}] canvas_production"
echo
echo "3. Redis Ping:"
redis-cli ping | grep -q "PONG" && echo -e "  [\${GREEN}OK\${NC}] PONG" || echo -e "  [\${RED}FAIL\${NC}] No PONG"
echo
echo "4. Apache Local:"
curl -s --head http://localhost | grep "Server: Apache" &>/dev/null && echo -e "  [\${GREEN}OK\${NC}] HTTP localhost" || echo -e "  [\${YELLOW}WARN\${NC}] HTTP localhost"
[[ "$protocol" == "https" ]] && { curl -s --insecure --head https://localhost | grep "Server: Apache" &>/dev/null && echo -e "  [\${GREEN}OK\${NC}] HTTPS localhost" || echo -e "  [\${YELLOW}WARN\${NC}] HTTPS localhost"; }
echo
echo "5. Canvas URL (${protocol}://$DOMAIN/login/canvas):"
rc=\$(curl -kLs -o /dev/null -w "%{http_code}" "${protocol}://$DOMAIN/login/canvas" 2>/dev/null || echo "000")
[[ "\$rc" = "200" || "\$rc" = "302" ]] && echo -e "  [\${GREEN}OK\${NC}] HTTP \$rc" || echo -e "  [\${RED}FAIL\${NC}] HTTP \$rc (Expected 200/302)"
echo
echo "6. Canvas Log (/var/canvas/log/production.log - last 10 errors/warnings):"
LOG="/var/canvas/log/production.log"
if sudo test -r "\$LOG"; then
  errs=\$(sudo tail -n 200 "\$LOG" | grep -E -i ' (ERROR|FATAL|Failed|Traceback|PG::|Errno::)' | tail -n 10)
  [[ -n "\$errs" ]] && echo -e "  [\${YELLOW}WARN\${NC}] Potential issues:\n\$errs" | sed 's/^/    /' || echo -e "  [\${GREEN}OK\${NC}] No recent errors."
else echo -e "  [\${YELLOW}WARN\${NC}] \$LOG not found/readable."; fi
echo -e "\${GREEN}=== Health Check Complete ===\${NC}"
EOF
    check_success "Creating health check script"
    sudo chmod +x "$HEALTH_CHECK_SCRIPT"
    check_success "Making health check script executable"
    log_msg "Run 'sudo $HEALTH_CHECK_SCRIPT' for basic health check."
}

# Main script execution
main() {
    echo "=============================================================="
    echo " Canvas LMS Production Installation Script for Ubuntu 24.04"
    echo " Branch: $CANVAS_BRANCH | Ruby: $CANVAS_RUBY_VERSION"
    echo "=============================================================="
    read -p "Proceed with installation? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_msg "Installation aborted."
        exit 0
    fi

    trap 'log_error "Script aborted at line $LINENO. Last command: $BASH_COMMAND"; exit 1' ERR

    check_requirements
    prompt_user_input
    install_dependencies
    configure_postgresql
    configure_redis
    install_canvas           
    configure_canvas         
    compile_assets           
    initialize_database      
    configure_apache         
    setup_ssl                
    configure_delayed_jobs   
    set_security_permissions 
    restart_services         
    installation_summary

    log_msg "${GREEN}Canvas LMS installation process completed!${NC}"
    local final_protocol="http"
    if [[ "$USE_SSL" == "yes" && -L "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
        final_protocol="https"
    fi
    log_msg "Access Canvas at: ${GREEN}${final_protocol}://$DOMAIN${NC}"
}

main "$@"