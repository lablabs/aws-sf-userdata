#!/usr/bin/env bash

GIT_RELEASE=${1:-0.1.0}

URL_SCRIPTS="https://raw.githubusercontent.com/lablabs/aws-sf-userdata/${GIT_RELEASE}/"

OS="$(lsb_release -c -s)"
OS_USER_DATA="${URL_SCRIPTS}/${OS}.sh"

if wget --spider $OS_USER_DATA 2>/dev/null; then
  curl -s -L $OS_USER_DATA | bash
else
  echo "${OS} is not supported"
  exit 1
fi
