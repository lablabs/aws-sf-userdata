#!/usr/bin/env bash

readonly URL_SCRIPTS='https://raw.githubusercontent.com/lablabs/aws-sf-userdata/master/'

OS="$(lsb_release -c -s)"
OS_USER_DATA="${URL_SCRIPTS}/${OS}.sh"

if wget --spider $OS_USER_DATA 2>/dev/null; then
  curl -s -L $OS_USER_DATA | bash
else
  echo "${OS} is not supported"
  exit 1
fi
