#!/bin/bash

##################################################
# PinPoint - Package Installation Module
##################################################

set -e

echo
echo "=========================================="
echo " Installing PinPoint Dependencies"
echo "=========================================="
echo

echo "Updating package lists..."
apt update

echo
echo "Installing required packages..."
echo

apt install -y \
apache2 \
php \
libapache2-mod-php \
php-gd \
php-cli \
php-common \
php-mysql \
php-xml \
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
libmariadb-dev \
apache2-utils \
snmp \
libnet-snmp-perl \
gettext \
python3 \
python3-pip \
autoconf \
libmcrypt-dev

echo
echo "=========================================="
echo " Package installation completed!"
echo "=========================================="
echo
