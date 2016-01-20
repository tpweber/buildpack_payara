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

require 'java_buildpack/container/wls/wls_constants'

module JavaBuildpack
  module Container
    module Wls

      # Monitor Agent
      class MonitorAgent
        include JavaBuildpack::Container::Wls::WlsConstants

        # Create a setup script that would monitor for update in 'access time' of pre-designated target files through
        # client action (using cf files interface) and dump threads or heap or stats as required.
        # This script would be kicked off in the background just before server start
        # This script is getting copied over to the $HOME directory
        def initialize(application)
          @monitor_agent_root = "#{application.root}/#{MONITORING_AGENT_DIR}"

          system "mkdir -p #{@monitor_agent_root} 2>/dev/null"
          system "/bin/cp #{BUILDPACK_MONITOR_AGENT_PATH}/* #{@monitor_agent_root}"

          @dumper_agent_script = Dir.glob("#{@monitor_agent_root}/#{MONITORING_AGENT_SCRIPT}")[0]

          system "chmod +x #{@monitor_agent_root}/*"
        end

        # define the path to the agent script
        def monitor_script
          "/bin/bash #{@dumper_agent_script}"
        end

        private

        MONITORING_AGENT_DIR    = '.monitor'.freeze
        MONITORING_RESOURCE     = 'monitoring'.freeze
        MONITORING_AGENT_PATH   = 'agent'.freeze
        MONITORING_AGENT_SCRIPT = 'dumperAgent.sh'.freeze

        BUILDPACK_MONITOR_AGENT_PATH = "#{BUILDPACK_CONFIG_CACHE_DIR}/#{MONITORING_RESOURCE}/" \
                                       "#{MONITORING_AGENT_PATH}".freeze

        private_constant :MONITORING_AGENT_DIR, :MONITORING_RESOURCE, :MONITORING_AGENT_PATH, :MONITORING_AGENT_SCRIPT,
                         :BUILDPACK_MONITOR_AGENT_PATH

      end

    end
  end
end
