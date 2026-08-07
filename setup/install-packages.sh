#!/bin/bash

set -e

LOG="/var/log/pinpoint-install.log"

echo "======================================" | tee -a "$LOG"
echo " PinPoint Phase 2 - Installing Packages" | tee -a "$LOG"
echo "======================================" | tee -a "$LOG"

apt update

apt install -y \
apache2 \
php \
libapache2-mod-php \
php-gd \
php-cli \
php-common \
php-mysql \
php-xml \
php-gd \
php-curl \
php-mbstring \
php-zip \
gcc \
make \
unzip \
curl \
wget \
git \
build-essential \
libgd-dev \
openssl \
libssl-dev \
apache2-utils \
snmp \
libnet-snmp-perl \
gettext \
bc \
dnsutils \
net-tools

echo
echo "Package installation completed." | tee -a "$LOG"
