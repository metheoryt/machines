#!/bin/bash
set -e

# restic — via apt
sudo apt-get update
sudo apt-get install -y restic

# resticprofile — official install script
curl -sfL https://raw.githubusercontent.com/creativeprojects/resticprofile/master/install.sh \
  | sudo sh -s -- -b /usr/local/bin
