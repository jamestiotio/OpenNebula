#!/usr/bin/env ruby

# ---------------------------------------------------------------------------- #
# Copyright 2002-2023, OpenNebula Project, OpenNebula Systems                  #
#                                                                              #
# Licensed under the Apache License, Version 2.0 (the "License"); you may      #
# not use this file except in compliance with the License. You may obtain      #
# a copy of the License at                                                     #
#                                                                              #
# http://www.apache.org/licenses/LICENSE-2.0                                   #
#                                                                              #
# Unless required by applicable law or agreed to in writing, software          #
# distributed under the License is distributed on an "AS IS" BASIS,            #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.     #
# See the License for the specific language governing permissions and          #
# limitations under the License.                                               #
# ---------------------------------------------------------------------------- #

ONE_LOCATION = ENV['ONE_LOCATION'] unless defined?(ONE_LOCATION)

if !ONE_LOCATION
    RUBY_LIB_LOCATION ||= '/usr/lib/one/ruby'
    GEMS_LOCATION     ||= '/usr/share/one/gems'
    VAR_LOCATION      ||= '/var/lib/one'
else
    RUBY_LIB_LOCATION ||= ONE_LOCATION + '/lib/ruby'
    GEMS_LOCATION     ||= ONE_LOCATION + '/share/gems'
    VAR_LOCATION      ||= ONE_LOCATION + '/var'
end

# %%RUBYGEMS_SETUP_BEGIN%%
if File.directory?(GEMS_LOCATION)
    real_gems_path = File.realpath(GEMS_LOCATION)
    if !defined?(Gem) || Gem.path != [real_gems_path]
        $LOAD_PATH.reject! {|l| l =~ /vendor_ruby/ }

        # Suppress warnings from Rubygems
        # https://github.com/OpenNebula/one/issues/5379
        begin
            verb = $VERBOSE
            $VERBOSE = nil
            require 'rubygems'
            Gem.use_paths(real_gems_path)
        ensure
            $VERBOSE = verb
        end
    end
end
# %%RUBYGEMS_SETUP_END%%

$LOAD_PATH << RUBY_LIB_LOCATION
$LOAD_PATH << File.dirname(__FILE__)

require 'fileutils'
require 'opennebula'
require 'securerandom'

require 'CommandManager'

require_relative '../tm/lib/backup'

# restic://<datastore_id>/<id>:<snapshot_id>,.../<file_name>
restic_url = ARGV[0]
tokens     = restic_url.delete_prefix('restic://').split('/')
ds_id      = tokens[0].to_i
snaps      = tokens[1].split(',').map {|s| s.split(':')[1] }
disk_path  = tokens[2..].join('/')
disk_index = File.basename(disk_path).split('.')[1]

begin
    # Do a sanity check if Restic is available/enabled.

    raise StandardError, 'Restic unavailable, please use OpenNebula EE.' \
        unless File.exist?("#{VAR_LOCATION}/remotes/datastore/restic/")

    require "#{VAR_LOCATION}/remotes/datastore/restic/restic"

    # Fetch datastore XML payload directly from the API.

    backup_ds = OpenNebula::Datastore.new_with_id ds_id, OpenNebula::Client.new

    rc = backup_ds.info(true)

    raise StandardError, rc.message \
        if OpenNebula.is_error?(backup_ds)

    # Pull from Restic, then post-process qcow2 disks.

    rds = Restic.new backup_ds.to_xml

    tmp_dir = "#{rds.tmp_dir}/#{SecureRandom.uuid}"
    FileUtils.mkdir_p tmp_dir

    paths      = rds.pull_chain(snaps, disk_index, nil, tmp_dir)
    disk_paths = paths[:disks][:by_index][disk_index]

    rc = LocalCommand.run '/bin/bash -s', nil, <<~EOS
        set -e -o pipefail
        #{TransferManager::BackupImage.reconstruct_chain(disk_paths, tmp_dir)}
        #{TransferManager::BackupImage.merge_chain(disk_paths, tmp_dir)}
        mv '#{tmp_dir}/#{File.basename(disk_paths.last)}' '#{tmp_dir}/disk.#{disk_index}'
    EOS

    raise StandardError, rc.stderr \
        if rc.code != 0

    # Return shell code snippets according to the downloader's interface.

    STDOUT.puts <<~EOS
        command="cat '#{tmp_dir}/disk.#{disk_index}'"
        clean_command="rm -rf '#{tmp_dir}/'"
    EOS
rescue StandardError => e
    STDERR.puts e.full_message
    exit(-1)
end

exit(0)