#
# Copyright (c) 2018-2024 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# Contributors:
#   Red Hat, Inc. - initial API and implementation
#   IBM Corporation - implementation
#

# https://registry.access.redhat.com/rhel9-2-els/rhel
FROM registry.redhat.io/rhel9-2-els/rhel:9.2-1222
USER 0
WORKDIR /

ARG BOOTSTRAP=false
ENV BOOTSTRAP=${BOOTSTRAP}

# to get all the python deps pre-fetched so we can build in Brew:
# 1. extract files in the container to your local filesystem
#    find v3 -type f -exec dos2unix {} \;

# NOTE: used to be in /root/.local but now can be found in /opt/app-root/src/.local
# CONTAINERNAME=pluginregistryoffline && \
# docker build -t ${CONTAINERNAME} . --no-cache  --target builder \
#   --build-arg BOOTSTRAP=true -f build/dockerfiles/Dockerfile 
# mkdir -p /tmp/root-local/ && docker run --rm -v \
#   /tmp/root-local/:/tmp/root-local/ ${CONTAINERNAME} /bin/bash \
#   -c 'cd /opt/app-root/src/.local/ && cp -r bin/ lib/ /tmp/root-local/'
# pushd /tmp/root-local >/dev/null && sudo tar czf root-local.tgz lib/ bin/ && popd >/dev/null && mv -f /tmp/root-local/root-local.tgz . && sudo rm -fr /tmp/root-local/

# 2. then add it to dist-git so it's part of this repo
#    rhpkg new-sources root-local.tgz 

# built in Brew, use tarball in lookaside cache; built locally with BOOTSTRAP = true, comment this out to create the tarball
# COPY root-local.tgz /tmp/root-local.tgz

COPY ./build/dockerfiles/content_sets_rhel9.repo /etc/yum.repos.d/
COPY ./build/dockerfiles/rhel.install.sh /tmp
RUN /tmp/rhel.install.sh && rm -f /tmp/rhel.install.sh

# Install postgresql and nodejs
RUN dnf -y update && \
    dnf module install postgresql:15/server nodejs:18/development -y

# Copy OpenVSX server files
COPY --chown=0:0 /openvsx-server.tar.gz .
RUN tar --no-same-owner -xf openvsx-server.tar.gz && rm openvsx-server.tar.gz
# Copy our configuration file for OpenVSX server
COPY /build/dockerfiles/application.yaml /openvsx-server/config/
RUN chmod -R g+rwx /openvsx-server

# Copy OVSX npm package
RUN mkdir -p /tmp/opt
COPY --chown=0:0 /ovsx.tar.gz .
RUN tar -xf ovsx.tar.gz -C / && rm ovsx.tar.gz && ls -la /tmp/opt/ovsx/bin/

RUN mkdir -p /var/www/html/v3/plugins/

RUN \
    # Apply permissions to later change these files on httpd
    chmod g+rwx /var/log/httpd && chmod g+rw /run/httpd && \
    # Create user template
    cat /etc/passwd | sed s#root:x.*#root:x:\${USER_ID}:\${GROUP_ID}::\${HOME}:/bin/bash#g > /.passwd.template \
    && cat /etc/group | sed s#root:x:0:#root:x:0:0,\${USER_ID}:#g > /.group.template && \
    # Change permissions
    for f in "/etc/passwd" "/etc/group"; do \
           chgrp -R 0 ${f} && \
           chmod -R g+rwX ${f}; \
    done

COPY /build/scripts/import_vsix.sh /usr/local/bin
COPY /build/scripts/start_services.sh /usr/local/bin/
COPY /build/dockerfiles/openvsx.conf /etc/httpd/conf.d/
COPY /build/scripts/*.sh /build/

RUN chmod 755 /usr/local/bin/*.sh && \
    chmod -R g+rwX /build

COPY /build/dockerfiles/entrypoint.sh /usr/local/bin/

RUN \
    # Delete files that should not be copied into the final image
    rm -rf /build

RUN \
    mkdir -p /var/run/postgresql && \
    chmod 777 /var/run/postgresql && \
    # Add UTF-8 for the database
    localedef -f UTF-8 -i en_US en_US.UTF-8 && \
    # set up postgres user
    usermod -a -G apache,root,postgres postgres

# Apply httpd config file
RUN sed -i /etc/httpd/conf/httpd.conf \
    -e "s,Listen 80,Listen 8080," \
    -e "s,logs/error_log,/dev/stderr," \
    -e "/<IfModule log_config_module>/a SetEnvIf User-Agent \"^kube-probe/\" dontlog" \
    -e 's,CustomLog "logs/access_log" combined,CustomLog /dev/stdout combined env=!dontlog,' \
    -e "s,AllowOverride None,AllowOverride All," && \
    chmod a+rwX /etc/httpd/conf /etc/httpd/conf.d /run/httpd /etc/httpd/logs/

STOPSIGNAL SIGWINCH

USER postgres
ENV LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8 \
    PGDATA=/var/lib/pgsql/15/data/database \
    PATH="/tmp/opt/ovsx/bin:$PATH" \
    JVM_ARGS="-DSPDXParser.OnlyUseLocalLicenses=true -Xmx2048m"

RUN \
    echo "======================" && \
    echo -n "node:  "; node --version && \
    echo "======================" \
    echo -n "ovsx:  "; /tmp/opt/ovsx/bin/ovsx --version && \
    echo "======================"

RUN initdb && \
    /usr/local/bin/import_vsix.sh && \
    chmod -R 777 /tmp/file && \
    rm /var/lib/pgsql/15/data/database/postmaster.pid && \
    rm /var/run/postgresql/.s.PGSQL* && \
    rm /tmp/.s.PGSQL* && \
    rm /tmp/.lock

RUN \
    echo "Change permissions for postgres user" && \
    chmod -R g+rwx /var/lib/pgsql /var/lib/pgsql/15 /var/lib/pgsql/data /var/lib/pgsql/backups && \
    chgrp -R 0 /var/lib/pgsql /var/lib/pgsql/15 /var/lib/pgsql/data /var/lib/pgsql/backups && \
    mv /var/lib/pgsql/15/data/database /var/lib/pgsql/15/data/old

ARG DS_BRANCH=devspaces-3-rhel-8
ENV DS_BRANCH=${DS_BRANCH}

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# append Brew metadata here
