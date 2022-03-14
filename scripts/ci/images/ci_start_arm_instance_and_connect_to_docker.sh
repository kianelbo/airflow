#!/usr/bin/env bash
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
# shellcheck source=scripts/ci/libraries/_script_init.sh
. "$( dirname "${BASH_SOURCE[0]}" )/../libraries/_script_init.sh"

SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"
# This is an AMI that is based on Basic Amazon Linux AMI with installed and configured docker service
WORKING_DIR="/tmp/armdocker"
INSTANCE_INFO="${WORKING_DIR}/instance_info.json"
ARM_AMI="ami-002fa24639ab2520a"
INSTANCE_TYPE="c6gd.medium"
MARKET_OPTIONS="MarketType=spot,SpotOptions={MaxPrice=0.1,SpotInstanceType=one-time}"
REGION="us-east-2"
EC2_USER="ec2-user"
USER_DATA_FILE="${SCRIPTS_DIR}/self_terminate.sh"

function start_arm_instance() {
    set -x
    mkdir -p "${WORKING_DIR}"
    cd "${WORKING_DIR}" || exit 1
    aws ec2 run-instances \
        --region "${REGION}" \
        --image-id "${ARM_AMI}" \
        --count 1 \
        --instance-type "${INSTANCE_TYPE}" \
        --user-data "file://${USER_DATA_FILE}" \
        --instance-market-options "${MARKET_OPTIONS}" \
        --instance-initiated-shutdown-behavior terminate \
        --output json \
        > "${INSTANCE_INFO}"

    INSTANCE_ID=$(jq < "${INSTANCE_INFO}" ".Instances[0].InstanceId" -r)
    AVAILABILITY_ZONE=$(jq < "${INSTANCE_INFO}" ".Instances[0].Placement.AvailabilityZone" -r)

    aws ec2 wait instance-status-ok --instance-ids "${INSTANCE_ID}"
    INSTANCE_PRIVATE_IP=$(aws ec2 describe-instances \
        --filters "Name=instance-state-name,Values=running" "Name=instance-id,Values=${INSTANCE_ID}" \
        --query 'Reservations[*].Instances[*].PublicDnsName' --output text)
    rm -f my_key
    ssh-keygen -t rsa -f my_key -N ""
    aws ec2-instance-connect send-ssh-public-key --instance-id "${INSTANCE_ID}" \
        --availability-zone "${AVAILABILITY_ZONE}" \
        --instance-os-user "${EC2_USER}" \
        --ssh-public-key file://my_key.pub
    autossh -f -L12357:/var/run/docker.sock \
        -o "IdentitiesOnly=yes" -o "StrictHostKeyChecking=no" \
        -i my_key \
        "${EC2_USER}@${INSTANCE_PRIVATE_IP}"
    docker buildx create --name airflow_cache --append localhost:12357
    docker buildx ls
}

start_arm_instance
