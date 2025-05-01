# Redmine Setup for Hetzner Cloud

## Overview
This project provides an automated installation script for Redmine 6.0.5 on Ubuntu 24.04 LTS servers hosted on Hetzner Cloud. The script sets up a complete Redmine environment with Nginx, MariaDB, and Let's Encrypt SSL certification.

## Features
- Automated installation of Redmine 6.0.5
- Ruby 3.4.3 installation via RVM
- MariaDB database setup
- Nginx web server configuration
- Let's Encrypt SSL certificate integration
- UFW firewall configuration
- Systemd service for Redmine

## Requirements
- Ubuntu 24.04 LTS server
- Root access
- Domain name pointing to your server's IP address

## Usage

### Basic Usage
```bash
./redmine-install.sh -d your-domain.com -p YourStrongPassword -e your-email@example.com
```

### Command Line Options
- `-d, --domain DOMAIN`: Domain name for the Redmine installation
- `-p, --password PASSWORD`: Password for MariaDB redmine user
- `-e, --email EMAIL`: Email for Let's Encrypt certificate notifications
- `--dry-run`: Run without making changes (for testing)
- `-h, --help`: Display help message

### Example
```bash
./redmine-install.sh -d example.com -p StrongPassw0rd -e admin@example.com
```

## Idempotent Execution
The script is designed to be idempotent, meaning it can be run multiple times without causing errors or unintended side effects. It includes checks for:
- Existing Redmine database
- Existing database user
- Previously installed components

This makes the script resilient for re-runs in case of interruptions or when updates are needed.

## Default Credentials
After installation, you can access Redmine with the following default credentials:
- **Username**: admin
- **Password**: admin

**Important**: Change the default admin password immediately after first login.

## Logs
The installation process is logged to `/var/log/redmine-install.log`

## Troubleshooting
If you encounter issues during installation:
1. Check the installation log at `/var/log/redmine-install.log`
2. Verify that your domain is correctly pointing to your server's IP address
3. Ensure that ports 80 and 443 are open on your server

## Theme Installation for Redmine 6.0+
**Important Note**: Redmine 6.0+ has changed the way themes are handled.

### Theme Directory Changes
- In Redmine versions 5 and below: Themes were installed to `/public/themes/`
- In Redmine versions 6.0+: Themes must be installed to `/themes/`

### Required Nginx Configuration
For themes to work correctly in Redmine 6.0+, you must add the following to your Nginx server block:

```nginx
# Theme assets alias - required for Redmine 6.0+
location /public/assets/themes {
    alias /home/redmine/redmine/themes;
    autoindex off;
}
```

This configuration is already included in the installation script, but if you're upgrading from an earlier version or using a custom Nginx configuration, you'll need to add this manually.

### Theme Installation Steps
1. Upload the theme to `/home/redmine/redmine/themes/`
2. Ensure the theme directory has the correct ownership: `chown -R redmine:redmine /home/redmine/redmine/themes/`
3. Restart Redmine: `touch /home/redmine/redmine/tmp/restart.txt && chown redmine:redmine /home/redmine/redmine/tmp/restart.txt`
4. In Redmine, go to Administration → Settings → Display and select your theme

## License
This project is licensed under the MIT License - see the LICENSE file for details.

## Maintenance
Last updated: May 1, 2025
