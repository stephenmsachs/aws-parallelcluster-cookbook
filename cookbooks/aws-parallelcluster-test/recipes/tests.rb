# frozen_string_literal: true

#
# Cookbook:: aws-parallelcluster-test
# Recipe:: tests
#
# Copyright:: 2013-2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may not use this file except in compliance with the
# License. A copy of the License is located at
#
# http://aws.amazon.com/apache2.0/
#
# or in the "LICENSE.txt" file accompanying this file. This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
# OR CONDITIONS OF ANY KIND, express or implied. See the License for the specific language governing permissions and
# limitations under the License.

###################
# AWS Cli
###################
bash 'check awscli regions' do
  cwd Chef::Config[:file_cache_path]
  code <<-AWSREGIONS
    set -e
    export PATH="/usr/local/bin:/usr/bin/:$PATH"
    regions=($(#{node['cluster']['cookbook_virtualenv_path']}/bin/aws ec2 describe-regions --region #{node['cluster']['region']} --query "Regions[].{Name:RegionName}" --output text))
    for region in "${regions[@]}"
    do
      #{node['cluster']['cookbook_virtualenv_path']}/bin/aws ec2 describe-regions --region "${region}"
    done
  AWSREGIONS
end

###################
# SSH client conf
###################
# Test only on head node since on compute fleet an empty /home is mounted for the Kitchen tests run
if node['cluster']['node_type'] == 'HeadNode'
  execute 'ssh localhost as user' do
    command "ssh localhost hostname"
    environment('PATH' => '/usr/local/bin:/usr/bin:/bin:$PATH')
    user node['cluster']['cluster_user']
  end
end

###################
# Scheduler Plugin
###################
if node['cluster']['scheduler'] == 'plugin'
  if node['cluster']['node_type'] == "HeadNode"
    execute 'check artifacts are in target_source_path' do
      command "ls #{node['cluster']['scheduler_plugin']['home']} | grep develop"
    end
    execute 'check handler-env.json in path' do
      command "ls #{node['cluster']['shared_dir']}/handler-env.json"
    end
    execute 'check get compute fleet script is executable by plugin user' do
      command "su #{node['cluster']['scheduler_plugin']['user']} -c 'if [[ ! -x '/usr/local/bin/get-compute-fleet-status.sh' ]]; then exit 1; fi;'"
    end
    execute 'check update compute fleet script is executable by plugin user' do
      command "su #{node['cluster']['scheduler_plugin']['user']} -c 'if [[ ! -x '/usr/local/bin/update-compute-fleet-status.sh' ]]; then exit 1; fi;'"
    end
  end
  execute "check scheduler plugin user doesn't have Sudo Privileges" do
    command "(su #{node['cluster']['scheduler_plugin']['user']} -c 'sudo -ln') 2>&1 | grep 'a password is required'"
  end
end

###################
# DCV
###################
if node['conditions']['dcv_supported'] && node['cluster']['dcv_enabled'] == "head_node" && node['cluster']['node_type'] == "HeadNode"
  # moved to InSpec
elsif node['conditions']['ami_bootstrapped']
  execute 'check systemd default runlevel' do
    command "systemctl get-default | grep -i multi-user.target"
  end
  if node['cluster']['os'] == "ubuntu1804" || node['cluster']['os'] == "alinux2"
    execute 'check gdm service is stopped' do
      command "systemctl show -p SubState gdm | grep -i dead"
    end
  end
end

###################
# jq
###################
unless node['cluster']['os'].end_with?("-custom")
  bash 'execute jq' do
    cwd Chef::Config[:file_cache_path]
    code <<-JQMERGE
      set -e
      # Set PATH as in the UserData script of the CloudFormation template
      export PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/opt/aws/bin"
      echo '{"cluster": {"region": "eu-west-3"}, "run_list": "recipe[aws-parallelcluster::slurm_config]"}' > /tmp/dna.json
      echo '{ "cluster" : { "dcv_enabled" : "head_node" } }' > /tmp/extra.json
      jq --argfile f1 /tmp/dna.json --argfile f2 /tmp/extra.json -n '$f1 * $f2'
    JQMERGE
  end
end

###################
# Bridge Network Interface
###################
if platform?('centos')
  bash 'test bridge network interface presence' do
    code <<-TESTBRIDGE
      set -e
      # brctl show
      # bridge name bridge id STP enabled interfaces
      # virbr0 8000.525400e6e4f9 yes virbr0-nic
      [ $(brctl show | awk 'FNR == 2 {print $1}') ] && exit 1 || exit 0
    TESTBRIDGE
  end
end

###################
# instance store
###################

ebs_shared_dirs_array = node['cluster']['ebs_shared_dirs'].split(',')

if ebs_shared_dirs_array.include? node['cluster']['ephemeral_dir']
  # In this case the ephemeral storage should not be mounted because the mountpoint
  # clashes with the mountpoint coming from t
  bash 'test instance store mountpoint collision' do
    cwd Chef::Config[:file_cache_path]
    user node['cluster']['cluster_user']
    code <<-COLLISION
      systemctl show setup-ephemeral.service -p ActiveState | grep "=inactive"
      systemctl show setup-ephemeral.service -p UnitFileState | grep "=disabled"
    COLLISION
  end
else
  bash 'test instance store' do
    cwd Chef::Config[:file_cache_path]
    user node['cluster']['cluster_user']
    code <<-EPHEMERAL
      set -xe
      EPHEMERAL_DIR="#{node['cluster']['ephemeral_dir']}"

      function set_imds_token(){
        if [ -z "${IMDS_TOKEN}" ];then
          IMDS_TOKEN=$(sudo curl --retry 3 --retry-delay 0 --fail -s -f -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 900" http://169.254.169.254/latest/api/token)
          if [ "${?}" -gt 0 ] || [ -z "${IMDS_TOKEN}" ]; then
            echo '[ERROR] Could not get IMDSv2 token. Instance Metadata might have been disabled or this is not an EC2 instance.'
            exit 1
          fi
        fi
      }
      function get_meta() {
          local IMDS_OUT=$(sudo curl --retry 3 --retry-delay 0 --fail -s -q -H "X-aws-ec2-metadata-token:${IMDS_TOKEN}" -f http://169.254.169.254/latest/${1})
          echo -n "${IMDS_OUT}"
      }
      function print_block_device_mapping(){
        echo 'block-device-mapping: '
        DEVICES=$(get_meta meta-data/block-device-mapping/)
        if [ -n "${DEVICES}" ]; then
          for DEVICE in ${DEVICES}; do
            echo -e '\t' ${DEVICE}: $(get_meta meta-data/block-device-mapping/${DEVICE})
          done
        else
          echo "NOT AVAILABLE"
        fi
      }

      # Check if instance has instance store
      if ls /dev/nvme* &>/dev/null; then
        # Ephemeral devices for NVME
        EPHEMERAL_DEVS=$(realpath --relative-to=/dev/ -P /dev/disk/by-id/nvme*Instance_Storage* | grep -v "*Instance_Storage*" | uniq)
      else
        # Ephemeral devices for not-NVME
        set_imds_token
        EPHEMERAL_DEVS=$(print_block_device_mapping | grep ephemeral | awk '{print $2}' | sed 's/sd/xvd/')
      fi

      NUM_DEVS=0
      set +e
      for EPHEMERAL_DEV in ${EPHEMERAL_DEVS}; do
        STAT_COMMAND="stat -t /dev/${EPHEMERAL_DEV}"
        if ${STAT_COMMAND} &>/dev/null; then
          let NUM_DEVS++
        fi
      done
      set -e

      if [ $NUM_DEVS -gt 0 ]; then
        mkdir -p ${EPHEMERAL_DIR}/test_dir
        touch ${EPHEMERAL_DIR}/test_dir/test_file
      fi
    EPHEMERAL
  end
  execute 'check setup-ephemeral service is enabled' do
    command "systemctl is-enabled setup-ephemeral"
  end
end

###################
# Pcluster AWSBatch CLI
###################
if node['cluster']['scheduler'] == 'awsbatch' && node['cluster']['node_type'] == 'HeadNode'
  # Test that batch commands can be accessed without absolute path
  batch_cli_commands = %w(awsbkill awsbqueues awsbsub awsbhosts awsbout awsbstat)
  batch_cli_commands.each do |cli_commmand|
    bash "test_#{cli_commmand}" do
      cwd Chef::Config[:file_cache_path]
      code <<-BATCHCLI
        set -e
        source ~/.bash_profile
        #{cli_commmand} -h
      BATCHCLI
      user node['cluster']['cluster_user']
    end
  end
end

##################
# Verify enough space on AMIs
###################
unless node['cluster']['os'].end_with?("-custom")
  bash 'verify 10 GB of space left on root volume' do
    cwd Chef::Config[:file_cache_path]
    # This test assumes the df output is as follows:
    # $ df --block-size GB --output=avail /
    # Avail
    # 42GB
    code <<-CAPACITY_CHECK
      free_gigs="$(df --block-size GB --output=avail / | tail -n1 | cut -d G -f1)"
      if [ $free_gigs -lt 10 ]; then
        echo "Expected at least 10 GB of free space remaining on the root volume, but only found ${free_gigs}"
        exit 1
      fi
    CAPACITY_CHECK
    user node['cluster']['cluster_user']
  end
end

##################
# ipv4 gc_thresh
###################
expected_gc_settings = []
(1..3).each do |i|
  expected_gc_settings.append(node['cluster']['sysctl']['ipv4']["gc_thresh#{i}"])
end
expected_gc_settings = expected_gc_settings.join(',').to_s
bash 'check ipv4 gc_thresh is correctly configured' do
  cwd Chef::Config[:file_cache_path]
  code <<-GC
    set -e

    for i in {1..3}; do
      declare "actual_gc_thresh${i}=`cat /proc/sys/net/ipv4/neigh/default/gc_thresh${i}`"
    done
    actual_settings="${actual_gc_thresh1},${actual_gc_thresh2},${actual_gc_thresh3}"
    if [ "${actual_settings}" != "#{expected_gc_settings}" ]; then
            echo "ERROR: Incorrect gc_thresh settings!"
            echo "Expected "#{expected_gc_settings}" but actual is ${actual_settings}"
            exit 1
    fi
  GC
  user 'root'
end

##################
# Verify no MPICH packages
###################
bash 'verify no MPICH packages' do
  code <<-NOMPICH
    lib64_mpich_libs="$(ls 2>/dev/null /usr/lib64/mpich*)"
    lib_mpich_libs="$(ls 2>/dev/null /usr/lib/mpich*)"
    [ -z "${lib64_mpich_libs}" ] && [ -z "${lib_mpich_libs}" ]
  NOMPICH
end

##################
# Verify no FFTW packages
###################
unless node['cluster']['base_os'] == 'centos7'
  bash 'verify no FFTW packages' do
    code <<-NOFFTW
      lib64_fftw_libs="$(ls 2>/dev/null /usr/lib64/libfftw*)"
      lib_fftw_libs="$(ls 2>/dev/null /usr/lib/libfftw*)"
      [ -z "${lib64_fftw_libs}" ] && [ -z "${lib_fftw_libs}" ]
    NOFFTW
  end
end

###################
# Verify that aws-ubuntu-eni-helper service is disabled
###################
is_service_disabled('aws-ubuntu-eni-helper', 'debian')

###################
# Verify that log4j-cve-2021-44228-hotpatch service is disabled
###################
is_service_disabled('log4j-cve-2021-44228-hotpatch', 'amazon')

###################
# clusterstatusmgtd
###################
if node['cluster']['node_type'] == 'HeadNode' && node['cluster']['scheduler'] != 'awsbatch'
  execute "check clusterstatusmgtd is configured to be executed by supervisord" do
    command "#{node['cluster']['cookbook_virtualenv_path']}/bin/supervisorctl status clusterstatusmgtd | grep RUNNING"
  end
end

execute 'unmount /home' do
  command "umount -fl /home"
  retries 10
  retry_delay 6
  timeout 60
  only_if { node['cluster']['node_type'] == 'ComputeFleet' }
end
