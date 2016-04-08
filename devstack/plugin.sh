#!/bin/bash

#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

# The path where go binaries have to be installed
GOROOT=${GOROOT:-/opt/go}

# golang version. Skydive needs atleast version 1.5
GO_VERSION=${GO_VERSION:-1.5}

# GOPATH where the go src, pkgs are installed
GOPATH=/opt/stack/go

# Address on which skydive analyzer process listens for connections.
# Must be in ip:port format
SKYDIVE_ANALYZER_LISTEN=${SKYDIVE_ANALYZER_LISTEN:-$SERVICE_HOST:8082}

# Inform the agent about the address on which analyzers are listening
SKYDIVE_AGENT_ANALYZERS=${SKYDIVE_AGENT_ANALYZERS:-$SKYDIVE_ANALYZER_LISTEN}

# Configure the skydive agent with the etcd server address
SKYDIVE_AGENT_ETCD=${SKYDIVE_AGENT_ETCD:-http://$SERVICE_HOST:2379}

# ip:port address on which skydive agent listens for connections.
SKYDIVE_AGENT_LISTEN=${SKYDIVE_AGENT_LISTEN:-"127.0.0.1:8081"}

# The path for the generated skydive configuration file
SKYDIVE_CONFIG_FILE=${SKYDIVE_CONFIG_FILE:-"/tmp/skydive.yaml"}

# List of agent probes to be used by the agent
SKYDIVE_AGENT_PROBES=${SKYDIVE_AGENT_PROBES:-"netlink netns ovsdb neutron"}

# Remote port for ovsdb server.
SKYDIVE_OVSDB_REMOTE_PORT=6640


function install_go {
    if [[ `uname -m` == *"64" ]]; then
        arch=amd64
    else
        arch=386
    fi

    if [ ! -d $GOROOT ]; then
        sudo mkdir -p $GOROOT
        safe_chown -R $STACK_USER $GOROOT
        safe_chmod 0755 $GOROOT
        curl -s -L https://storage.googleapis.com/golang/go$GO_VERSION.linux-$arch.tar.gz | tar -C `dirname $GOROOT` -xzf -
    fi
    export GOROOT=$GOROOT
    export PATH=$PATH:$GOROOT/bin:$GOPATH/bin
    export GOPATH=$GOPATH
}

function pre_install_skydive {
    install_go
    $TOP_DIR/pkg/elasticsearch.sh download
    $TOP_DIR/pkg/elasticsearch.sh install
}

function install_skydive {
    if [ ! -f $GOPATH/bin/skydive ]; then
        if is_fedora ; then
            install_package libpcap-devel
        else
            install_package libpcap-dev
        fi
        SKYDIVE_SRC=$GOPATH/src/github.com/redhat-cip
        mkdir -p $SKYDIVE_SRC
        ln -s $DEST/skydive $SKYDIVE_SRC/skydive
        cd $SKYDIVE_SRC/skydive
        make install
    fi
}

function join {
    local d=$1; shift; echo -n "$1"; shift; printf "%s\n" "${@/#/$d}";
}

function get_probes_for_config {
    printf "%s" "$(join '      - ' '' $SKYDIVE_AGENT_PROBES)";
}

function configure_skydive {
    cat > $SKYDIVE_CONFIG_FILE <<- EOF
agent:
  analyzers: $SKYDIVE_AGENT_ANALYZERS
  listen: $SKYDIVE_AGENT_LISTEN
  topology:
    probes:
$(get_probes_for_config)

  flow:
    probes:
      - ovssflow
      - pcap

openstack:
  auth_url: ${KEYSTONE_AUTH_PROTOCOL}://${KEYSTONE_AUTH_HOST}:${KEYSTONE_AUTH_PORT}/v2.0
  username: admin
  password: $ADMIN_PASSWORD
  tenant_name: admin
  region_name: RegionOne

ovs:
  ovsdb: $SKYDIVE_OVSDB_REMOTE_PORT

etcd:
  servers:
    - $SKYDIVE_AGENT_ETCD
EOF

    if [ "x$SKYDIVE_ANALYZER_LISTEN" != "x" ]; then
        cat >> $SKYDIVE_CONFIG_FILE <<- EOF

analyzer:
  listen: $SKYDIVE_ANALYZER_LISTEN
EOF
    fi

    if is_service_enabled skydive-agent ; then
        sudo ovs-appctl -t ovsdb-server ovsdb-server/add-remote "ptcp:$SKYDIVE_OVSDB_REMOTE_PORT:127.0.0.1"
    fi
}

function start_skydive {
    if is_service_enabled skydive-agent ; then
        run_process skydive-agent "sudo $GOPATH/bin/skydive agent --conf $SKYDIVE_CONFIG_FILE"
    fi

    if is_service_enabled skydive-analyzer ; then
        $TOP_DIR/pkg/elasticsearch.sh start
        run_process skydive-analyzer "$GOPATH/bin/skydive analyzer --conf $SKYDIVE_CONFIG_FILE"
    fi
}

function stop_skydive {
    if is_service_enabled skydive-agent ; then
        stop_process skydive-agent
    fi

    if is_service_enabled skydive-analyzer ; then
        $TOP_DIR/pkg/elasticsearch.sh stop
        stop_process skydive-analyzer
    fi
}

if is_service_enabled skydive-agent || is_service_enabled skydive-analyzer ; then
    if [[ "$1" == "stack" ]]; then
        if [[ "$2" == "pre-install" ]]; then
            pre_install_skydive
        elif [[ "$2" == "install" ]]; then
            install_skydive
        elif [[ "$2" == "post-config" ]]; then
            configure_skydive
            start_skydive
        fi
    fi

    if [[ "$1" == "unstack" ]]; then
        stop_skydive
        rm $SKYDIVE_CONFIG_FILE
    fi
fi
