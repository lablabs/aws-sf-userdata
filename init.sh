#!/usr/bin/env bash

GIT_RELEASE=${1:-0.1.0}
CURL_OPTIONS=${2:-"--connect-timeout 10 --max-time 20 --retry 5 --retry-delay 5 --retry-max-time 300"}

URL_SCRIPTS="https://raw.githubusercontent.com/lablabs/aws-sf-userdata/${GIT_RELEASE}"
OS="$(lsb_release -c -s)"
OS_USER_DATA="${URL_SCRIPTS}/${OS}.sh"

http_code="$(curl $CURL_OPTIONS --write-out "%{http_code}\n" --silent --output /dev/null $OS_USER_DATA)"

if [[ "$http_code" -eq 200 ]]; then
  curl $CURL_OPTIONS -s -L $OS_USER_DATA | bash
elif [[ "$http_code" -eq 404 ]]; then
  echo "${OS} is not supported"
  exit 1
else
  echo "curl failed"
  exit 1
fi
