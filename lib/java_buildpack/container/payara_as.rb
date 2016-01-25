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

require 'java_buildpack/container/payara'
require 'java_buildpack/container/payara/monitor_agent'
require 'java_buildpack/container/payara/service_bindings_handler'
require 'java_buildpack/container/payara/payara_constants'
require 'java_buildpack/container/payara/payara_detector'
require 'java_buildpack/container/payara/payara_installer'
require 'java_buildpack/container/payara/payara_configurer'
require 'java_buildpack/container/payara/payara_releaser'
require 'java_buildpack/container/payara/payara_util'

require 'yaml'
require 'tmpdir'
require 'rexml/document'

module JavaBuildpack
  module Container

    # Encapsulates the detect, compile, and release functionality for Payara based
    # applications on Cloud Foundry.
    class Payara_AS < JavaBuildpack::Component::VersionedDependencyComponent
      include JavaBuildpack::Util
      include JavaBuildpack::Container::Payara::PayaraConstants

      attr_accessor :java_home, :java_binary, :payara_asadmin

      def initialize(context)
        super(context)

        if @supports
          @payara_version, @payara_uri = JavaBuildpack::Repository::ConfiguredItem
                                     .find_item(@component_name, @configuration) do |candidate_version|
            candidate_version.check_size(3)
          end

          log("Payara_AS.initialize: @payara_version -> #{@payara_version}")

          @prefer_app_config       = @configuration[PREFER_APP_CONFIG]
          @start_in_wlx_mode       = @configuration[START_IN_WLX_MODE]
          @prefer_root_web_context = @configuration[PREFER_ROOT_WEB_CONTEXT]

          # Proceed with install under the APP-INF or WEB-INF folders

          @payara_install = @application.root
          log("Payara_AS.initialize: @payara_install -> #{@payara_install}")
          @payara_home = @payara_install + PAYARA_ROOT_ELEMENT
          log("Payara_AS.initialize: @payara_home -> #{@payara_home}")

          if app_inf?
            @payara_sandbox_root = @payara_home
            # Possible the APP-INF folder got stripped out as it didnt contain anything
            #create_sub_folder(@droplet.root, 'glassfish')
            log("Payara_AS.initialize: app_inf? -> #{app_inf?}")
          else
            # Treat as webapp by default
            @payara_sandbox_root = @payara_home
            # + 'glassfish'
            # Possible the WEB-INF folder got stripped out as it didnt contain anything
            #create_sub_folder(@droplet.root, 'glassfish')
          end

          log("Payara_AS.initialize: @payara_sandbox_root -> #{@payara_sandbox_root}")

          @payara_domain_path          = @payara_sandbox_root + PAYARA_DOMAIN_PATH
          @app_config_cache_root       = @application.root + APP_PAYARA_CONFIG_CACHE_DIR
          @app_services_config         = @application.services

          log("Payara_AS.initialize: @payara_domain_path -> #{@payara_domain_path}")
          log("Payara_AS.initialize: @app_config_cache_root -> #{@app_config_cache_root}")
          log("Payara_AS.initialize: @app_services_config -> #{@app_services_config}")

          # Root of Buildpack bundled config cache - points to <payara-buildpack>/resources/payara
          @buildpack_config_cache_root = BUILDPACK_CONFIG_CACHE_DIR
          log("Payara_AS.initialize: @buildpack_config_cache_root -> #{@buildpack_config_cache_root}")

          load
        else
          @payara_version = nil
          @payara_uri = nil
        end
      end

      # (see JavaBuildpack::Component::BaseComponent#detect)
      def detect
        return nil unless @payara_version
        [payara_id(@payara_version)]
      end

      # (see JavaBuildpack::Component::BaseComponent#compile)
      def compile
        download_and_install_payara
        configure
        #@droplet.additional_libraries.link_to app_web_inf_lib

        # Don't modify context root for wars within Ear as there can be multiple wars.
        # Modify the context root to '/' in case of war
        # and prefer_root_web_context is enabled in buildpack payara_as.yml config
        # modify_context_root_for_war if web_inf? && @prefer_root_web_context
      end

      # (see JavaBuildpack::Component::BaseComponent#release)
      def release
        #monitor_agent  = JavaBuildpack::Container::Payara::MonitorAgent.new(@application)
        #monitor_script = monitor_agent.monitor_script

        releaser = JavaBuildpack::Container::Payara::PayaraReleaser.new(@application, @droplet, @domain_home,
                                                                              @server_name, @start_in_wlx_mode, @payara_home)

        result_map = releaser.create_scripts

        @java_home   = result_map['java_home']
        @java_binary   = result_map['java_binary']
        @payara_asadmin = result_map['payara_asadmin']
        log("Payadra_AS.configure: @java_home -> #{@java_home}")
        log("Payadra_AS.configure: @java_binary -> #{@java_binary}")
        log("Payadra_AS.configure: @payara_install -> #{@payara_install}")
        log("Payadra_AS.configure: @payara_home -> #{@payara_home}")
        log("Payadra_AS.configure: @payara_asadmin -> #{@payara_asadmin}")
        #pre_start_script     = releaser.pre_start
        #post_shutdown_script = releaser.post_shutdown

        log("Payadra_AS.release: @app_name -> #{@app_name}")
        log("Payadra_AS.release: @application -> #{@application}")
        log("Payadra_AS.release: @app_services_config -> #{@app_services_config}")
        log("Payadra_AS.release: @app_src_path -> #{@app_src_path}")
        log("Payadra_AS.release: @domain_name -> #{@domain_name}")
        log("Payadra_AS.release: @java_home: #{@java_home}")
        log("Payadra_AS.release: @java_binary: #{@java_binary}")
        log("Payadra_AS.release: @payara_install: #{@payara_install}")
        log("Payadra_AS.release: @payara_home: #{@payara_home}")
        log("Payadra_AS.release: @payara_asadmin: #{@payara_asadmin}")
        start_domain_script = start_domain_payara
        log("Payadra_AS.release: start_domain_script: #{start_domain_script}")
        deploy_war_script = deploy_war_to_domain
        log("Payadra_AS.release: deploy_war_script: #{deploy_war_script}")

        [
          @droplet.java_home.as_env_var,
          "USER_MEM_ARGS=\"#{@droplet.java_opts.join(' ')}\"",
          "sleep 10; #{start_domain_script}; #{deploy_war_script}"
        ].flatten.compact.join(' ')
      end

      def deploy_war_to_domain
        log("Payara_AS.commandDeployWar: deploying war: #{@app_name}")

        commandPW = "echo AS_ADMIN_PASSWORD= > #{@payara_home}/passwordfile.txt"
        system "#{commandPW}"

        commandDeployWar = "export JAVA_HOME=#{@java_home};"
        commandDeployWar << "export AS_JAVA=#{@java_home};"
        commandDeployWar << "export java=#{@java_binary};"
        commandDeployWar << "export AS_ADMIN_PASSWORDFILE=;"
        commandDeployWar << "#{@payara_asadmin} --user admin --passwordfile #{@payara_home}/passwordfile.txt deploy --force=true --target=#{@domain_name} #{@app_name} > #{@payara_home}/domain.log;"
        #system "#{commandDeployWar}"

        log("Payara_AS.commandDeployWar: commandDeployWar: #{commandDeployWar}")
        return commandDeployWar
      end

      def start_domain_payara
        log("Payara_AS.start_domain_payara: starting domain: #{@domain_name}")
        commandPW = "echo AS_ADMIN_PASSWORD= > #{@payara_home}/passwordfile.txt"
        system "#{commandPW}"

        commandStartDomain = "export JAVA_HOME=#{@java_home};"
        commandStartDomain << "export AS_JAVA=#{@java_home};"
        commandStartDomain << "export java=#{@java_binary};"
        commandStartDomain << "export AS_ADMIN_PASSWORDFILE=;"
        commandStartDomain << "#{@payara_asadmin} --user admin --passwordfile #{@payara_home}/passwordfile.txt start-domain #{@domain_name} > #{@payara_home}/domain.log"
        #system "#{commandStartDomain}"

        log("Payara_AS.start_domain_payara: commandStartDomain: #{commandStartDomain}")
        return commandStartDomain
      end

      private

      # The unique identifier of the component, incorporating the version of the dependency (e.g. +payara=4.1.0+)
      #
      # @param [String] version the version of the dependency
      # @return [String] the unique identifier of the component
      def payara_id(version)
        "#{Payara.to_s.dash_case}=#{version}"
      end

      # The unique identifier of the component, incorporating the version of the dependency (e.g.
      # +payara-buildpack-support=4.1.0+)
      #
      # @param [String] version the version of the dependency
      # @return [String] the unique identifier of the component
      def support_id(version)
        "payara-buildpack-support=#{version}"
      end

      # Whether or not this component supports this application
      #
      # @return [Boolean] whether or not this component supports this application
      def supports?
        @supports ||= payara? && !JavaBuildpack::Util::JavaMainUtils.main_class(@application)
      end

      def payara?
        JavaBuildpack::Container::Payara::PayaraDetector.detect(@application)
      end

      # @return [Hash] the configuration or an empty hash if the configuration file does not exist
      def load
        # Determine the configs that should be used to drive the domain creation.
        # Can be the App bundled configs
        # or the buildpack bundled configs

        # Locate the domain config either under APP-INF or WEB-INF location
        # locate_domain_config_by_app_type

        # During development when the domain structure is still in flux, use App bundled config to test/tweak the
        # domain. Once the domain structure is finalized, save the configs as part of the buildpack and then only pass
        # along the bare bones domain config and jvm config. Ignore the rest of the app configs.

        @config_cache_root = determine_config_cache

        # If there is no Domain Config yaml file, copy over the buildpack bundled basic domain configs.
        # Create the appconfig_cache_root '.wls' directory under the App Root as needed
        unless @payara_domain_yaml_config
          log("Payara_AS.load: : @payara_domain_yaml_config -> #{@payara_domain_yaml_config}")
          log("Payara_AS.load: @app_config_cache_root -> #{@app_config_cache_root}")
          log("Payara_AS.load: @buildpack_config_cache_root -> #{@buildpack_config_cache_root}")
          system "mkdir #{@app_config_cache_root} 2>/dev/null; " \
                  " cp  #{@buildpack_config_cache_root}/*.yml #{@app_config_cache_root}"

          @payara_domain_yaml_config = Dir.glob("#{@app_config_cache_root}/*.yml")[0]
          log('Payara_AS.load: No Domain Configuration yml file found, reusing one from the buildpack bundled template!!')
        end

        # For now, expecting only one script to be run to create the domain
        @payara_domain_config_script = Dir.glob("#{@app_config_cache_root}/#{PAYARA_SCRIPT_CACHE_DIR}/*.py")[0]

        # If there is no Domain Script, use the buildpack bundled script.
        unless @payara_domain_config_script
          @payara_domain_config_script = Dir.glob("#{@buildpack_config_cache_root}/#{PAYARA_SCRIPT_CACHE_DIR}/*.py")[0]
          log('Payara_AS.load: No Domain creation script found, reusing one from the buildpack bundled template!!')
        end

        domain_configuration = YAML.load_file(@payara_domain_yaml_config)
        log("Payara_AS.load: Payara Domain Configuration: #{@payara_domain_yaml_config}: #{domain_configuration}")

        @domain_config = domain_configuration['Domain']
        log("Payara_AS.load: @domain_config -> #{@domain_config}")

        # Parse environment variable VCAP_APPLICATION to
        # configure the app, domain and server names
        configure_names_from_env

        @app_name    = 'testApp' unless @app_name
        @domain_name = 'cfDomain' unless @domain_name
        @server_name = 'myserver' unless @server_name

        @bin_home  = @payara_domain_path + @domain_name
        @domain_home  = @payara_domain_path + @domain_name
        @app_src_path = @application.root

        log("Payara_AS.load: @bin_home -> #{@bin_home}")
        log("Payara_AS.load: @domain_home -> #{@domain_home}")
        log("Payara_AS.load: @app_src_path -> #{@app_src_path}")
        log("Payara_AS.load: @app_name -> #{@app_name}")
        log("Payara_AS.load: @domain_name -> #{@domain_name}")
        log("Payara_AS.load: @server_name -> #{@server_name}")

        domain_configuration || {}
      end

      # locate domain config yaml file based on App Type
      def locate_domain_config_by_app_type
        # Search for the configurations first under the WEB-INF or APP-INF folders and later directly under app bits
        if web_inf?
          war_config_cache_root = @application.root + 'WEB-INF' + APP_PAYARA_CONFIG_CACHE_DIR
          # If no config cache directory exists under the WEB-INF,
          # check directly under the app and move it under the WEB-INF folder if its present
          unless Dir.exist?(war_config_cache_root)
            if Dir.exist?(@application.root + APP_PAYARA_CONFIG_CACHE_DIR)
              system "mv #{@application.root + APP_PAYARA_CONFIG_CACHE_DIR} #{@application.root + 'WEB-INF'}"
            end
          end

          @app_config_cache_root  = war_config_cache_root
          @payara_domain_yaml_config = Dir.glob("#{war_config_cache_root}/*.yml")[0]

          log("Payara_AS.locate_domain_config_by_app_type: web_inf @app_config_cache_root -> #{@app_config_cache_root}")
          log("Payara_AS.locate_domain_config_by_app_type: web_inf @payara_domain_yaml_config -> #{@payara_domain_yaml_config}")

        elsif app_inf?
          ear_config_cache_root = @application.root + 'APP-INF' + APP_PAYARA_CONFIG_CACHE_DIR
          # If no config cache directory exists under the APP-INF,
          # check directly under the app and move it under the APP-INF folder if its present
          unless Dir.exist?(ear_config_cache_root)
            if Dir.exist?(@application.root + APP_PAYARA_CONFIG_CACHE_DIR)
              system "mv #{@application.root + APP_PAYARA_CONFIG_CACHE_DIR} #{@application.root + 'APP-INF'}"
            end
          end

          @app_config_cache_root  = ear_config_cache_root
          @payara_domain_yaml_config = Dir.glob("#{ear_config_cache_root}/*.yml")[0]
          log("Payara_AS.locate_domain_config_by_app_type: app_inf @app_config_cache_root -> #{@app_config_cache_root}")
          log("Payara_AS.locate_domain_config_by_app_type: app_inf @payara_domain_yaml_config -> #{@payara_domain_yaml_config}")
        end

      end

      # Determine which configurations should be used for driving the domain creation - App or buildpack bundled
      # configuration
      def determine_config_cache
        if @prefer_app_config
          # Use the app bundled configuration and domain creation scripts.
          @app_config_cache_root
        else
          # Use the buildpack's bundled configuration and domain creation scripts (under resources/wls)
          # But the jvm and domain configuration files from the app bundle will be used, rather than the buildpack
          # version.
          @buildpack_config_cache_root
        end
      end

      # Download Payara and unpack it
      def download_and_install_payara
        installation_map = {
          'droplet'           => @droplet,
          'payara_sandbox_root'  => @payara_sandbox_root,
          'config_cache_root' => @buildpack_config_cache_root,
          'payara_install' => @payara_install,
          'payara_home' => @payara_home,
          'payara_asadmin' => @payara_asadmin
        }

        log("Downloding Payara, Version[#{@payara_version}] from #{@payara_uri}")
        download(@payara_version, @payara_uri) do |input_file|
          payara_installer = JavaBuildpack::Container::Payara::PayaraInstaller.new(input_file, installation_map)
          result_map    = payara_installer.install

          @java_home   = result_map['java_home']
          @java_binary   = result_map['java_binary']
          @payara_install = result_map['payara_install']
          @payara_home = result_map['payara_home']
          @payara_asadmin = result_map['payara_asadmin']
          log("Payara_AS.download_and_install_payara: @java_home -> #{@java_home}")
          log("Payara_AS.download_and_install_payara: @payara_install -> #{@payara_install}")
          log("Payara_AS.download_and_install_payara: @payara_home -> #{@payara_home}")
          log("Payara_AS.download_and_install_payara: @payara_asadmin -> #{@payara_asadmin}")

        end
      end

      # Configure the Payara instance
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
          'java_binary'                => @java_binary,
          'config_cache_root'        => @config_cache_root,
          'payara_sandbox_root'         => @payara_sandbox_root,
          'payara_install'              => @payara_install,
          'payara_domain_yaml_config'   => @payara_domain_yaml_config,
          'payara_domain_config_script' => @payara_domain_config_script,
          'payara_domain_path'          => @payara_domain_path,
          'payara_home'                 => @payara_home,
          'payara_asadmin'              => @payara_asadmin
        }

        log("Payadra_AS.configure: @app_name -> #{@app_name}")
        log("Payadra_AS.configure: @application -> #{@application}")
        log("Payadra_AS.configure: @app_services_config -> #{@app_services_config}")
        log("Payadra_AS.configure: @app_src_path -> #{@app_src_path}")
        log("Payadra_AS.configure: @domain_name -> #{@domain_name}")
        log("Payadra_AS.configure: @payara_asadmin -> #{@payara_asadmin}")
        log("Payara_AS.configure: @java_home -> #{@java_home}")
        log("Payara_AS.configure: @payara_install -> #{@payara_install}")
        log("Payara_AS.configure: @payara_home -> #{@payara_home}")
        log("Payara_AS.configure: @payara_asadmin -> #{@payara_asadmin}")

        configurer = JavaBuildpack::Container::Payara::PayaraConfigurer.new(configuration_map)
        result_map    = configurer.configure

        @java_home   = result_map['java_home']
        @java_binary   = result_map['java_binary']
        @payara_asadmin = result_map['payara_asadmin']
        log("Payadra_AS.configure: @java_home -> #{@java_home}")
        log("Payadra_AS.configure: @java_binary -> #{@java_binary}")
        log("Payadra_AS.configure: @payara_install -> #{@payara_install}")
        log("Payadra_AS.configure: @payara_home -> #{@payara_home}")
        log("Payadra_AS.configure: @payara_asadmin -> #{@payara_asadmin}")
      end

      # Pull the application name from the environment and use it to set some of the Payara config values
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

      # Update the configured context root in the Payara config file to root.
      def modify_context_root_for_war
        payara_xml = Dir.glob("#{@application.root}/*/payara.xml")[0]

        return unless payara_xml

        doc = REXML::Document.new(File.new(payara_xml))
        doc.root.elements.each { |element| element.text = '/' if element.name[/context-root/] }

        File.open(payara_xml, 'w') do |file|
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
        JavaBuildpack::Container::Payara::PayaraUtil.log(content)
      end

    end
  end
end
