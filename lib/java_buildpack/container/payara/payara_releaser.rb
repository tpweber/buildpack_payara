# Encoding: utf-8
# Cloud Foundry Java Buildpack
# Copyright 2013-2015 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'java_buildpack/container/payara/jvm_arg_helper'
require 'pathname'
require 'yaml'

module JavaBuildpack
  module Container
    module Payara

      # Release the Payara instance
      class PayaraReleaser
        include JavaBuildpack::Container::Payara::PayaraConstants

        def initialize(application, droplet, domain_home, server_name, start_in_wlx_mode, java_home)
          @droplet           = droplet
          @application       = application
          @domain_home       = domain_home
          @server_name       = server_name
          @start_in_wlx_mode = start_in_wlx_mode
          @java_home = java_home

          log("PayaraReleaser.initialize: @application -> #{@application}")
          log("PayaraReleaser.initialize: @domain_home -> #{@domain_home}")
          log("PayaraReleaser.initialize: @server_name -> #{@server_name}")
          log("PayaraReleaser.initialize: @droplet -> #{@droplet}")
          log("PayaraReleaser.initialize: @droplet.root -> #{@droplet.root}")
          log("PayaraReleaser.initialize: @java_home -> #{@java_home}")

          create_scripts
        end

        # Create a pre-start script that will handle following
        # 1. Recreate the staging env folder structure as wls install scripts will fail otherwise
        # 2. Add app based jvm args (like application name, instance index, space name, warden container ip and names)
        # 3. Allow scale up/down based on variance between actual and staging memory settings
        # 4. Modify script to use updated jvm args (including resized heaps)
        # 5. Modify the server name reference to include the app instance index to differentiate between instances of
        #    the same app

        # Create a post-shutdown script that will handle following
        # 1. Report shutting down of the server instance
        # 2. Sleep for a predetermined period so users can download files if needed

        def create_scripts
          log("PayaraReleaser.create_scripts: @application -> #{@application}")
          #system "/bin/cp #{START_STOP_HOOKS_SRC_PATH}/* #{@application.root}/"
          #system "chmod +x #{@application.root}/*.sh"

          #@pre_start_script = Dir.glob("#{@application.root}/#{PRE_START_SCRIPT}")[0]
          #@post_stop_script = Dir.glob("#{@application.root}/#{POST_STOP_SCRIPT}")[0]

          #modify_pre_start_script
          {
            'java_home'   => @java_home,
            'java_binary'   => @java_binary,
            'payara_asadmin' => @payara_asadmin
          }
        end

        # The Pre-Start script
        def pre_start
          "/bin/bash ./#{PRE_START_SCRIPT}"
        end

        # The Post-Shutdown script
        def post_shutdown
          "/bin/bash ./#{POST_STOP_SCRIPT}"
        end

        private

        HOOKS_RESOURCE   = 'hooks'.freeze
        PRE_START_SCRIPT = 'preStart.sh'.freeze
        POST_STOP_SCRIPT = 'postStop.sh'.freeze

        START_STOP_HOOKS_SRC_PATH = "#{BUILDPACK_CONFIG_CACHE_DIR}/#{HOOKS_RESOURCE}".freeze

        # Modify the templated preStart script with actual values

        def modify_pre_start_script
          # Load the app bundled configurations and re-configure as needed the JVM parameters for the Server VM
          log("JVM config passed via droplet java_opts : #{@droplet.java_opts}")

          JavaBuildpack::Container::Payara::JvmArgHelper.update(@droplet.java_opts)
          JavaBuildpack::Container::Payara::JvmArgHelper.add_wlx_server_mode(@droplet.java_opts, @start_in_wlx_mode)
          log("Consolidated Java Options for Server: #{@droplet.java_opts.join(' ')}")

          staging_memory_limit = ENV['MEMORY_LIMIT']
          staging_memory_limit = '512m' unless staging_memory_limit

          script_path = @pre_start_script.to_s
          vcap_root = Pathname.new(@application.root).parent.to_s

          original = File.open(script_path, 'r') { |f| f.read }

          modified = original.gsub(/REPLACE_VCAP_ROOT_MARKER/, vcap_root)
          modified = modified.gsub(/REPLACE_JAVA_ARGS_MARKER/, @droplet.java_opts.join(' '))
          modified = modified.gsub(/REPLACE_DOMAIN_HOME_MARKER/, @domain_home.to_s)
          modified = modified.gsub(/REPLACE_SERVER_NAME_MARKER/, @server_name)
          modified = modified.gsub(/REPLACE_PAYARA_PRE_JARS_CACHE_DIR_MARKER/, PAYARA_PRE_JARS_CACHE_DIR)
          modified = modified.gsub(/REPLACE_PAYARA_POST_JARS_CACHE_DIR_MARKER/, PAYARA_POST_JARS_CACHE_DIR)
          modified = modified.gsub(/REPLACE_STAGING_MEMORY_LIMIT_MARKER/, staging_memory_limit)

          File.open(script_path, 'w') { |f| f.write modified }

          log('Updated preStart.sh files!!')
        end

        def log(content)
          JavaBuildpack::Container::Payara::PayaraUtil.log(content)
        end
      end
    end
  end
end
