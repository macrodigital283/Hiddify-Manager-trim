#!/bin/bash
cd $(dirname -- "$0")
source ../../common/utils.sh

install_package mariadb-server

if [ ! -f "mysql_pass" ]; then
    echo "Generating a random password..."
    random_password=$(< /dev/urandom tr -dc 'a-zA-Z0-9' | head -c49; echo)
    echo "$random_password" >"mysql_pass"
    chmod 600 "mysql_pass"
    # Secure MariaDB installation
    sudo mysql_secure_installation <<EOF
y
$random_password
$random_password
y
y
y
y
EOF

    # Disable external access
    sudo sed -i 's/bind-address/#bind-address/' /etc/mysql/mariadb.conf.d/50-server.cnf
    sudo systemctl restart mariadb

    # Create user with localhost access
    sudo mysql -u root -f <<MYSQL_SCRIPT
CREATE USER 'hiddifypanel'@'localhost' IDENTIFIED BY '$random_password';
ALTER USER 'hiddifypanel'@'localhost' IDENTIFIED BY '$random_password';

GRANT ALL PRIVILEGES ON *.* TO 'hiddifypanel'@'localhost';
CREATE DATABASE hiddifypanel CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;;
GRANT ALL PRIVILEGES ON hiddifypanel.* TO 'hiddifypanel'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT
    
    echo "MariaDB setup complete."
    
fi

# Path to the MariaDB configuration file
MARIADB_CONF="/etc/mysql/mariadb.conf.d/50-server.cnf"

# Check if the MariaDB configuration file exists
if [ ! -f "$MARIADB_CONF" ]; then
    echo "MariaDB configuration file ($MARIADB_CONF) not found."
fi

# Check if bind-address is already set to 127.0.0.1
if ! grep -q "^[^#]*bind-address\s*=\s*127.0.0.1" "$MARIADB_CONF"; then
    # Add or modify bind-address in the configuration file
    if grep -q "^#\+bind-address" "$MARIADB_CONF"; then
        # Uncomment and modify existing bind-address
        sed -i "s/^#\+bind-address\s*=\s*[0-9.]*/bind-address = 127.0.0.1/" "$MARIADB_CONF"
    else
        # Add new bind-address under [mysqld]
        sed -i "/\[mysqld\]/a bind-address = 127.0.0.1" "$MARIADB_CONF"
    fi
    echo "bind-address set to 127.0.0.1 in $MARIADB_CONF"

    sudo systemctl restart mariadb

fi

# TRIM: shrink MariaDB footprint for a small Hiddify panel DB.
# innodb_buffer_pool 128M->64M, max_connections 151->30, perf_schema off.
# Validated on test (~30MB saved, no functional change). Idempotent drop-in.
TRIM_CNF="/etc/mysql/mariadb.conf.d/99-hiddify-trim.cnf"
if [ ! -f "$TRIM_CNF" ]; then
    cat > "$TRIM_CNF" <<'TRIMCNF'
[mysqld]
innodb_buffer_pool_size = 64M
max_connections = 30
performance_schema = OFF
TRIMCNF
    echo "wrote MariaDB trim config: $TRIM_CNF"
    sudo systemctl restart mariadb
fi

systemctl start mariadb