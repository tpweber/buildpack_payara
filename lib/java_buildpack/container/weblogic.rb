# Encoding: utf-8
# Cloud Foundry Java Buildpack
# Copyright (c) 2013 the original author or authors.
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

require 'java_buildpack/container'
require 'java_buildpack/util/format_duration'
require 'java_buildpack/util/java_main_utils'
require 'java_buildpack/component/versioned_dependency_component'
require 'java_buildpack/component/java_opts'

require 'java_buildpack/container/wls'
require 'java_buildpack/container/wls/monitor_agent'
require 'java_buildpack/container/wls/service_bindings_handler'
require 'java_buildpack/container/wls/wls_constants'
require 'java_buildpack/container/wls/wls_detector'
require 'java_buildpack/container/wls/wls_installer'
require 'java_buildpack/container/wls/wls_configurer'
require 'java_buildpack/container/wls/wls_releaser'
require 'java_buildpack/container/wls/wls_util'

require 'yaml'
require 'tmpdir'
require 'rexml/document'

module JavaBuildpack
  module Container

    # Encapsulates the detect, compile, and release functionality for WebLogic Server (WLS) based
    # applications on Cloud Foundry.
    class Weblogic < JavaBuildpack::Component::VersionedDependencyComponent
      include JavaBuildpack::Util
      include JavaBuildpack::Container::Wls::WlsConstants

      def initialize(context)
        super(context)

        if @supports
          @wls_version, @wls_uri = JavaBuildpack::Repository::ConfiguredItem
                                     .find_item(@component_name, @configuration) do |candidate_version|
            candidate_version.check_size(3)
          end

          @prefer_app_config       = @configuration[PREFER_APP_CONFIG]
          @start_in_wlx_mode       = @configuration[START_IN_WLX_MODE]
          @prefer_root_web_context = @configuration[PREFER_ROOT_WEB_CONTEXT]

          # Proceed with install under the APP-INF or WEB-INF folders

          if app_inf?
            @wls_sandbox_root = @droplet.root + 'APP-INF/wlsInstall'
            # Possible the APP-INF folder got stripped out as it didnt contain anything
            create_sub_folder(@droplet.root, 'APP-INF')
          else
            # Treat as webapp by default
            @wls_sandbox_root = @droplet.root + 'WEB-INF/wlsInstall'
            # Possible the WEB-INF folder got stripped out as it didnt contain anything
            create_sub_folder(@droplet.root, 'WEB-INF')
          end

          @wls_domain_path             = @wls_sandbox_root + WLS_DOMAIN_PATH
          @app_config_cache_root       = @application.root + APP_WLS_CONFIG_CACHE_DIR
          @app_services_config         = @application.services

          # Root of Buildpack bundled config cache - points to <weblogic-buildpack>/resources/wls
          @buildpack_config_cache_root = BUILDPACK_CONFIG_CACHE_DIR

          load
        else
          @wls_version = nil
          @wls_uri = nil
        end
      end

      # (see JavaBuildpack::Component::BaseComponent#detect)
      def detect
        return nil unless @wls_version
        [wls_id(@wls_version)]
      end

      # (see JavaBuildpack::Component::BaseComponent#compile)
      def compile
        download_and_install_wls
        configure
        @droplet.additional_libraries.link_to app_web_inf_lib

        # Don't modify context root for wars within Ear as there can be multiple wars.
        # Modify the context root to '/' in case of war
        # and prefer_root_web_context is enabled in buildpack weblogic.yml config
        modify_context_root_for_war if web_inf? && @prefer_root_web_context
      end

      # (see JavaBuildpack::Component::BaseComponent#release)
      def release
        monitor_agent  = JavaBuildpack::Container::Wls::MonitorAgent.new(@application)
        monitor_script = monitor_agent.monitor_script

        releaser             = JavaBuildpack::Container::Wls::WlsReleaser.new(@application, @droplet, @domain_home,
                                                                              @server_name, @start_in_wlx_mode)
        pre_start_script     = releaser.pre_start
        post_shutdown_script = releaser.post_shutdown

        [
          @droplet.java_home.as_env_var,
          "USER_MEM_ARGS=\"#{@droplet.java_opts.join(' ')}\"",
          "sleep 10; #{pre_start_script}; #{monitor_script} ; #{@domain_home}/startWebLogic.sh; #{post_shutdown_script}"
        ].flatten.compact.join(' ')
      end

      private

      # The unique identifier of the component, incorporating the version of the dependency (e.g. +wls=12.1.2+)
      #
      # @param [String] version the version of the dependency
      # @return [String] the unique identifier of the component
      def wls_id(version)
        "#{Weblogic.to_s.dash_case}=#{version}"
      end

      # The unique identifier of the component, incorporating the version of the dependency (e.g.
      # +wls-buildpack-support=12.1.2+)
      #
      # @param [String] version the version of the dependency
      # @return [String] the unique identifier of the component
      def support_id(version)
        "wls-buildpack-support=#{version}"
      end

      # Whether or not this component supports this application
      #
      # @return [Boolean] whether or not this component supports this application
      def supports?
        @supports ||= wls? && !JavaBuildpack::Util::JavaMainUtils.main_class(@application)
      end

      def wls?
        JavaBuildpack::Container::Wls::WlsDetector.detect(@application)
      end

      # @return [Hash] the configuration or an empty hash if the configuration file does not exist
      def load
        # Determine the configs that should be used to drive the domain creation.
        # Can be the App bundled configs
        # or the buildpack bundled configs

        # Locate the domain config either under APP-INF or WEB-INF location
        locate_domain_config_by_app_type

        # During development when the domain structure is still in flux, use App bundled config to test/tweak the
        # domain. Once the domain structure is finalized, save the configs as part of the buildpack and then only pass
        # along the bare bones domain config and jvm config. Ignore the rest of the app configs.

        @config_cache_root = determine_config_cache

        # If there is no Domain Config yaml file, copy over the buildpack bundled basic domain configs.
        # Create the appconfig_cache_root '.wls' directory under the App Root as needed
        unless @wls_domain_yaml_config
          system "mkdir #{@app_config_cache_root} 2>/dev/null; " \
                  " cp  #{@buildpack_config_cache_root}/*.yml #{@app_config_cache_root}"

          @wls_domain_yaml_config = Dir.glob("#{@app_config_cache_root}/*.yml")[0]
          log('No Domain Configuration yml file found, reusing one from the buildpack bundled template!!')
        end

        # For now, expecting only one script to be run to create the domain
        @wls_domain_config_script = Dir.glob("#{@app_config_cache_root}/#{WLS_SCRIPT_CACHE_DIR}/*.py")[0]

        # If there is no Domain Script, use the buildpack bundled script.
        unless @wls_domain_config_script
          @wls_domain_config_script = Dir.glob("#{@buildpack_config_cache_root}/#{WLS_SCRIPT_CACHE_DIR}/*.py")[0]
          log('No Domain creation script found, reusing one from the buildpack bundled template!!')
        end

        domain_configuration = YAML.load_file(@wls_domain_yaml_config)
        log("WLS Domain Configuration: #{@wls_domain_yaml_config}: #{domain_configuration}")

        @domain_config = domain_configuration['Domain']

        # Parse environment variable VCAP_APPLICATION to
        # configure the app, domain and server names
        configure_names_from_env

        @app_name    = 'testApp' unless @app_name
        @domain_name = 'cfDomain' unless @domain_name
        @server_name = 'myserver' unless @server_name

        @domain_home  = @wls_domain_path + @domain_name
        @app_src_path = @application.root

        domain_configuration || {}
      end

      # locate domain config yaml file based on App Type
      def locate_domain_config_by_app_type
        # Search for the configurations first under the WEB-INF or APP-INF folders and later directly under app bits
        if web_inf?
          war_config_cache_root = @application.root + 'WEB-INF' + APP_WLS_CONFIG_CACHE_DIR
          # If no config cache directory exists under the WEB-INF,
          # check directly under the app and move it under the WEB-INF folder if its present
          unless Dir.exist?(war_config_cache_root)
            if Dir.exist?(@application.root + APP_WLS_CONFIG_CACHE_DIR)
              system "mv #{@application.root + APP_WLS_CONFIG_CACHE_DIR} #{@application.root + 'WEB-INF'}"
            end
          end

          @app_config_cache_root  = war_config_cache_root
          @wls_domain_yaml_config = Dir.glob("#{war_config_cache_root}/*.yml")[0]

        elsif app_inf?
          ear_config_cache_root = @application.root + 'APP-INF' + APP_WLS_CONFIG_CACHE_DIR
          # If no config cache directory exists under the APP-INF,
          # check directly under the app and move it under the APP-INF folder if its present
          unless Dir.exist?(ear_config_cache_root)
            if Dir.exist?(@application.root + APP_WLS_CONFIG_CACHE_DIR)
              system "mv #{@application.root + APP_WLS_CONFIG_CACHE_DIR} #{@application.root + 'APP-INF'}"
            end
          end

          @app_config_cache_root  = ear_config_cache_root
          @wls_domain_yaml_config = Dir.glob("#{ear_config_cache_root}/*.yml")[0]
        end
      end

      # Determine which configurations should be used for driving the domain creation - App or buildpack bundled
      # configuration
      def determine_config_cache
        if @prefer_app_config
          # Use the app bundled configuration and domain creation scripts.
          @app_config_cache_root
        else
          # Use the buidlpack's bundled configuration and domain creation scripts (under resources/wls)
          # But the jvm and domain configuration files from the app bundle will be used, rather than the buildpack
          # version.
          @buildpack_config_cache_root
        end
      end

      # Download Weblogic and unpack it
      def download_and_install_wls
        installation_map = {
          'droplet'           => @droplet,
          'wls_sandbox_root'  => @wls_sandbox_root,
          'config_cache_root' => @buildpack_config_cache_root
        }

        download(@wls_version, @wls_uri) do |input_file|
          wls_installer = JavaBuildpack::Container::Wls::WlsInstaller.new(input_file, installation_map)
          result_map    = wls_installer.install

          @java_home   = result_map['java_home']
          @wls_install = result_map['wls_install']
        end
      end

      # Configure the Weblogic instance
      def configure
        configuration_map = {
          'app_name'                 => @app_name,
          'application'              => @application,
          'app_services_config'      => @app_services_config,
          'app_src_path'             => @app_src_path,
          'domain_name'              => @domain_name,
          'server_name'              => @server_name,
          'domain_home'              => @domain_home,
          'droplet'                  => @droplet,
          'java_home'                => @java_home,
          'config_cache_root'        => @config_cache_root,
          'wls_sandbox_root'         => @wls_sandbox_root,
          'wls_install'              => @wls_install,
          'wls_domain_yaml_config'   => @wls_domain_yaml_config,
          'wls_domain_config_script' => @wls_domain_config_script,
          'wls_domain_path'          => @wls_domain_path
        }

        configurer = JavaBuildpack::Container::Wls::WlsConfigurer.new(configuration_map)
        configurer.configure
      end

      # Pull the application name from the environment and use it to set some of the Weblogic config values
      def configure_names_from_env
        vcap_application_env_value = ENV['VCAP_APPLICATION']

        return unless vcap_application_env_value
        vcap_app_map = YAML.load(vcap_application_env_value)

        # name     = vcap_app_map['name']
        @app_name    = vcap_app_map['application_name']

        @domain_name = @app_name + 'Domain'
        @server_name = @app_name + 'Server'
      end

      # The root directory of the application being deployed
      def deployed_app_root
        @domain_apps_dir + APP_NAME
      end

      def app_web_inf_lib
        web_inf? ? @droplet.root + 'WEB-INF/lib' : @droplet.root + 'APP-INF/lib'
      end

      def web_inf?
        (@application.root + 'WEB-INF').exist?
      end

      def app_inf?
        (@application.root + 'APP-INF').exist? || (@application.root + 'META-INF/application.xml').exist?
      end

      # Update the configured context root in the Weblogic config file to root.
      def modify_context_root_for_war
        weblogic_xml = Dir.glob("#{@application.root}/*/weblogic.xml")[0]

        return unless weblogic_xml

        doc = REXML::Document.new(File.new(weblogic_xml))
        doc.root.elements.each { |element| element.text = '/' if element.name[/context-root/] }

        File.open(weblogic_xml, 'w') do |file|
          file.write(doc.to_s)
          file.fsync
        end
      end

      # Create a folder
      def create_sub_folder(parent, child)
        return unless (parent + '/' + child).exist?

        # Possible the APP-INF folder got stripped out as it didn't contain anything
        system "mkdir #{parent}/#{child}"
      end

      # Log a message
      def log(content)
        JavaBuildpack::Container::Wls::WlsUtil.log(content)
      end

    end
  end
end
