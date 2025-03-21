#!/bin/bash
#
# Copyright (c) 2022-2023 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# Utility script to filter the Dev Spaces, Web Terminal, DevWorkspace (and optionally CodeReady Workspaces) operators
# from an IIB image. Creates a file tree of json files, one folder per filtered package.
# OPM from 4.12 (>v1.26.3 upstream version) is required to run buildCatalog.sh (CRW-4192, OCPBUGS-11841)
#

usage() {
  cat <<EOF
Filter an IIB operator catalog to extract bundles, channel, and packages for specific
operator(s). By default files are output to ./olm-catalog, unless the --dir option is
specified.

Requires:
* jq 1.6+, podman 2.0+, glibc 2.28+
* opm v1.26.3+ (see https://docs.openshift.com/container-platform/4.12/cli_reference/opm/cli-opm-install.html#cli-opm-install )

Usage: $0 [OPTIONS]

Options:
  -s, --iib <source_index>           : Source registry, org, index image and tag from which to pull operators. Required.
  --channel-all <channel_name>       : Target channel to use when publishing all operators. If unspecified, channels from IIB are used
  --packages '<package1> <package2>' : Space separated list of packages to filter and include in target image. If 
                                       unspecified, default is 'devworkspace-operator devspaces web-terminal'
  --dir <directory>                  : Output files to <directory>/olm-catalog instead of ./olm-catalog
  -v, --verbose                      : Verbose output: include additional information
  -h, --help                         : Show this help

Examples:
  * Filter IIB 226720 for devspaces, devworkspace, and web-terminal operators
    $0 -s registry-proxy.engineering.redhat.com/rh-osbs/iib:226720
  * Filter IIB 226720 for only devspaces and web-terminal operators
    $0 -s registry-proxy.engineering.redhat.com/rh-osbs/iib:226720 --packages 'devspaces web-terminal'

EOF
}

VERBOSE=0
PACKAGES='devworkspace-operator devspaces web-terminal'
WORKING_DIR='./'

while [[ "$#" -gt 0 ]]; do
  case $1 in
    '-s'|'--iib') sourceIndexImage="$2"; shift 1;;
    '--channel-all') targetChannelAll="$2"; shift 1;;
    '--packages') PACKAGES="$2"; shift 1;;
    '--dir') WORKING_DIR="$2"; shift 1;;
    '-v'|'--verbose') VERBOSE=1;;
    '-h'|'--help') usage;;
    *) echo "Unknown parameter used: $1."; usage; exit 1;;
  esac
  shift 1
done

if [[ $VERBOSEFLAG == "-v" ]]; then echo "[DEBUG] Working in $WORKING_DIR"; fi
pushd "$WORKING_DIR" > /dev/null || exit
trap 'popd >> /dev/null' EXIT

# install opm if not installed by ansible https://gitlab.cee.redhat.com/codeready-workspaces/ansible-scripts/-/blob/master/roles/users/tasks/profile-hudson/main.yml#L107 to /usr/local/bin/opm
if [[ ! -x /usr/local/bin/opm ]] && [[ ! -x ${HOME}/.local/bin/opm ]]; then 
    pushd /tmp >/dev/null || exit
    echo "[INFO] Installing latest opm from https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/clients/ocp/latest-4.12/opm-linux.tar.gz ..."
    # shellcheck disable=SC2046
    curl -sSLo- https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/clients/ocp/latest-4.12/opm-linux.tar.gz | tar xz; chmod 755 opm
    sudo cp opm /usr/local/bin/ || cp opm "${HOME}"/.local/bin/
    sudo chmod 755 /usr/local/bin/opm || chmod 755 "${HOME}"/.local/bin/opm
    if [[ ! -x /usr/local/bin/opm ]] && [[ ! -x ${HOME}/.local/bin/opm ]]; then 
        echo "[ERROR] Could not install opm v1.26.3 or higher (see https://docs.openshift.com/container-platform/4.12/cli_reference/opm/cli-opm-install.html#cli-opm-install )";
        exit 1
    fi
    popd >/dev/null || exit
fi

PODMAN=$(command -v podman)
if [[ ! -x $PODMAN ]]; then echo "[ERROR] podman is not installed. Aborting."; echo; usage; exit 1; fi
command -v jq >/dev/null 2>&1     || which jq >/dev/null 2>&1     || { echo "jq is not installed. Aborting."; exit 1; }

# shellcheck disable=SC2086
if [ -z $sourceIndexImage ]; then echo "IIB image required"; echo; usage; exit 1; fi

if [ -f ./render.json ]; then rm -f ./render.json; fi
# CRW-3463 use --skip-tls-verify as workaround for "certificate signed by unknown authority"
if [[ $VERBOSE -eq 1 ]]; then
  echo "[DEBUG] Rendering 'opm --skip-tls-verify render $sourceIndexImage > render.json'"
  echo "[DEBUG] This may take several minutes."
  time opm --skip-tls-verify render "$sourceIndexImage" > render.json
else
  opm --skip-tls-verify render "$sourceIndexImage" > render.json
fi
# ls -la render.json

mkdir -p "./olm-catalog"
for PACKAGE in ${PACKAGES}; do
  if [[ $VERBOSE -eq 1 ]]; then echo "Filtering render.json for package $PACKAGE"; fi
  if [ -d "./olm-catalog/$PACKAGE" ]; then echo "Package $PACKAGE already in filtered catalog; aborting"; exit 1; fi
  mkdir -p "./olm-catalog/$PACKAGE"
  jq --arg PACKAGE "$PACKAGE" 'select(.schema == "olm.package") | select(.name == $PACKAGE)' render.json > "./olm-catalog/$PACKAGE/package.json"
  if [ ! -s "./olm-catalog/$PACKAGE/package.json" ]; then 
    echo "Could not find package $PACKAGE in IIB; aborting"
    rm -rf "./olm-catalog/$PACKAGE/"
    exit 1
  fi
  jq --arg PACKAGE "$PACKAGE" 'select(.schema == "olm.channel") | select(.package == $PACKAGE)' render.json > "./olm-catalog/$PACKAGE/channel.json"
  for BUNDLE in $(jq -r --arg PACKAGE "$PACKAGE" 'select(.package == $PACKAGE) | select(.schema == "olm.bundle") | .name' render.json); do
    echo "extracting bundle $BUNDLE"
    # shellcheck disable=SC2086
    jq --arg BUNDLE $BUNDLE 'select(.name == $BUNDLE) | select(.schema == "olm.bundle")' render.json > "./olm-catalog/$PACKAGE/$BUNDLE.bundle.json"
  done
done

replaceField()
{
  theFile="$1"
  updateName="$2"
  updateVal="$3"
  # echo "    ${0##*/} rF :: * ${updateName}: ${updateVal}"
  # shellcheck disable=SC2016 disable=SC2002 disable=SC2086
  changed=$(jq --arg updateName "${updateName}" --arg updateVal "${updateVal}" ${updateName}' = $updateVal' "${theFile}")
  echo "${changed}" > "${theFile}"
}

replaceChannelName()
{
  if [[ -d ${1} ]]; then 
    replaceField "${1}/channel.json" ".name" "${2}"
    replaceField "${1}/package.json" ".defaultChannel" "${2}"
  fi
}
# optionally, override the channels from the IIBs with a targetChannel (for all operators or for the devspaces operator only)
# olm-catalog/devspaces/channel.json # "name": "stable"
# olm-catalog/devspaces/package.json # "defaultChannel": "stable"
pushd olm-catalog/ >/dev/null || exit
if [[ -n $targetChannelAll ]]; then
  for d in devspaces web-terminal devworkspace-operator codeready-workspaces; do
      replaceChannelName "${d}" "$targetChannelAll"
  done
fi
popd >/dev/null || exit
