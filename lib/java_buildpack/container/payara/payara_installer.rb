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

module JavaBuildpack
  module Container
    module Payara

      # Encapsulates the logic for installing Payara in to the DEA
      class PayaraInstaller
        include JavaBuildpack::Container::Payara::PayaraConstants

        def initialize(input_file, installation_map)
          @input_file        = input_file
          @droplet           = installation_map['droplet']
          @payara_sandbox_root  = installation_map['payara_sandbox_root']
          @payara_home  = installation_map['payara_home']
          @payara_install  = installation_map['payara_install']
          @config_cache_root = installation_map['config_cache_root']

          log("PayaraInstaller.initialize: @input_file -> #{input_file}")
          log("PayaraInstaller.initialize: @droplet.sandbox -> #{@droplet.sandbox}")
          log("PayaraInstaller.initialize: @payara_sandbox_root -> #{@payara_sandbox_root}")
          log("PayaraInstaller.initialize: @payara_install -> #{@payara_install}")
          log("PayaraInstaller.initialize: @config_cache_root -> #{@config_cache_root}")
        end

        # Do the installation
        def install
          expand_start_time = Time.now
          log("PayaraInstaller.install: start_time -> #{expand_start_time}")
          log("PayaraInstaller.install: trying @payara_install -> #{@payara_install}")

          if not Dir.exist? @payara_install
            #FileUtils.rm_rf @payara_sandbox_root
            FileUtils.mkdir @payara_install
            log("PayaraInstaller.install: created @payara_install -> #{@payara_install}")
          end
          log("PayaraInstaller.install: @payara_install -> #{@payara_install}")
          input_file_path = File.absolute_path(@input_file.path)

          log("PayaraInstaller.install: input_file_path -> #{input_file_path}")
          log("PayaraInstaller.install: @droplet.root -> #{@droplet.root}")
          filesDropletRoot = Dir.entries("#{@droplet.root}")
          log("PayaraInstaller.install_using_zip: @droplet.root.files: #{filesDropletRoot}")

          print "-----> Installing Payara to #{@droplet.sandbox.relative_path_from(@droplet.root)}"\
                              " using downloaded file: #{input_file_path}\n"

          if input_file_path[/\.zip/]
            result_map = install_using_zip(input_file_path)
          else
            result_map = install_using_jar_or_binary(input_file_path)
          end

          puts "(#{(Time.now - expand_start_time).duration})"
          result_map
        end


        private

        # Required during Install...
        # Files required for installing from a jar in silent mode
        ORA_INSTALL_INVENTORY_FILE = 'oraInst.loc'.freeze
        PAYARA_INSTALL_RESPONSE_FILE  = 'installResponseFile'.freeze

        # keyword to change to point to actual wlsInstall in response file
        PAYARA_INSTALL_PATH_TEMPLATE  = 'PAYARA_INSTALL_PATH'.freeze
        PAYARA_ORA_INVENTORY_TEMPLATE = 'ORACLE_INVENTORY_INSTALL_PATH'.freeze
        PAYARA_ORA_INV_INSTALL_PATH   = '/tmp/payaraOraInstallInventory'.freeze

        def install_using_zip(zipFile)
          log("PayaraInstaller.install: PAYARA_INSTALL_RESPONSE_FILE -> #{PAYARA_INSTALL_RESPONSE_FILE}")
          log("PayaraInstaller.install_using_zip: #{zipFile}")
          log("Installing Payara from downloaded zip file using config script under #{@payara_install}!")

          system "/usr/bin/unzip #{zipFile} -d #{@payara_install}"
          #" >/dev/null"

          log("PayaraInstaller.install_using_zip: unzipped #{zipFile} to #{@payara_install}")

          log("PayaraInstaller.install_using_zip: @droplet.root: #{@droplet.root}")
          filesDropletRoot = Dir.entries("#{@droplet.root}")
          log("PayaraInstaller.install_using_zip: @droplet.root.files: #{filesDropletRoot}")
          filesPayaraHome = Dir.entries("#{@payara_home}")
          log("PayaraInstaller.install_using_zip: @payara_home.files: #{filesPayaraHome}")
          log("PayaraInstaller.install_using_zip: JAVA_BINARY: #{JAVA_BINARY}")
          log("PayaraInstaller.install_using_zip: File::FNM_DOTMATCH: #{File::FNM_DOTMATCH}")
          oracle_jre_path = Dir.glob("#{@droplet.root}" + "/.java-buildpack/oracle_jre/")[0]
          log("PayaraInstaller.install_using_zip: oracle_jre_path: #{oracle_jre_path}")
          java_binary = Dir.glob("#{oracle_jre_path}" + '**/' + JAVA_BINARY)[0]
          log("PayaraInstaller.install_using_zip: java_binary: #{java_binary}")

          configure_script = Dir.glob("#{@payara_home}" + '/**/' + PAYARA_CONFIGURE_SCRIPT)[0]
          log("PayaraInstaller.install_using_zip: configure_script: #{configure_script}")

          @java_home        = File.dirname(java_binary) + '/..'
          @payara_install_path = File.dirname(configure_script)

          log("PayaraInstaller.install_using_zip: @java_home: #{@java_home}")
          log("PayaraInstaller.install_using_zip: @payara_install_path: #{@payara_install_path}")

          system "/bin/chmod +x #{configure_script}"

          log("PayaraInstaller.install_using_zip: mode changed for @payara_install_path: #{@payara_install_path}")

          # Run configure.sh so the actual files are unpacked fully and paths are configured correctly
          # Need to use pipeline as we need to provide inputs to scripts downstream
          log('PayaraInstaller.install_using_zip: Running PAYARA Install/config script!!')

          # Check whether running on non-linux machine, to pick the correct JAVA_HOME location
          @java_home = check_and_reset_java_home_for_non_linux(@java_home)
          # save_middleware_home_in_configure_script(configure_script, @payara_install_path, @java_home)

          command = "export JAVA_HOME=#{@java_home} > #{@payara_sandbox_root}/install.log"
          #command << " export MW_HOME=#{@payara_install_path}; "
          #command << " echo no |  #{configure_script} > #{@payara_sandbox_root}/install.log"
          log("PayaraInstaller.install_using_zip: JAVA_HOME: #{@java_home}")

          system "#{command}"

          log_and_print("Finished running install, output saved at: #{@payara_sandbox_root}/install.log")

          {
            'java_home'   => @java_home,
            'payara_install' => @payara_install_path
          }
        end

        def install_using_jar_or_binary(install_binary_file)
          log_and_print("PayaraInstaller.install: PAYARA_INSTALL_RESPONSE_FILE -> #{PAYARA_INSTALL_RESPONSE_FILE}")
          print_warnings

          java_binary       = Dir.glob("#{@droplet.root}" + '/**/' + JAVA_BINARY, File::FNM_DOTMATCH)[0]
          @java_home        = File.dirname(java_binary) + '/..'

          ## The jar install of weblogic does not like hidden directories in its install path like .java-buildpack
          ## [VALIDATION] [ERROR]:INST-07004: Oracle Home location contains one or more invalid characters
          ## [VALIDATION] [SUGGESTION]:The directory name may only contain alphanumeric, underscore (_), hyphen (-) , or
          ## dot (.) characters, and it must begin with an alphanumeric character.
          ## Provide a different directory name. installation Failed. Exiting installation due to data validation
          ## failure.
          ## The Oracle Universal Installer failed.  Exiting.
          ## So, the <APP>/.java-buildpack/weblogic/wlsInstall path wont work here; have to create the wlsInstall
          ## outside of the .java-buildpack, just under the app location.
          # @wls_install_path = File.absolute_path("#{@wls_sandbox_root}/../../wlsInstall")
          # Now installing under the App/WEB-INF/wlsInstall or App/APP-INF/wlsInstall folder
          @payara_install_path = @payara_sandbox_root.to_s

          copy_templates
          log_and_print("Installing Payara at : #{@payara_install_path}")
          update_template('/tmp/' + PAYARA_INSTALL_RESPONSE_FILE, PAYARA_INSTALL_PATH_TEMPLATE, @payara_install_path)
          update_template('/tmp/' + ORA_INSTALL_INVENTORY_FILE, PAYARA_ORA_INVENTORY_TEMPLATE, PAYARA_ORA_INV_INSTALL_PATH)

          # Check whether running on non-linux machine, to pick the correct JAVA_HOME location
          @java_home = check_and_reset_java_home_for_non_linux(@java_home)

          install_command = construct_install_command(install_binary_file)

          log("Starting Payara Install with command:  #{install_command}")
          system " #{install_command} > /tmp/install.log; mv /tmp/install.log #{@payara_sandbox_root};"
          log("Finished running install, output saved at: #{@payara_sandbox_root}/install.log")

          {
            'java_home'   => @java_home,
            'payara_install' => @payara_install_path
          }
        end

        def print_warnings
          log_and_print('Installing Payara from Jar or Binary downloaded file in silent mode')
          log_and_print('WARNING!! Installation of Payara Server from Jar or Binary image requires complete JDK.'\
                        ' If install fails with JRE binary, please change buildpack to refer to full JDK ' \
                        'installation rather than JRE and retry!!')
        end

        def save_middleware_home_in_configure_script(configure_script, payara_install_path, java_home)
          original = File.open(configure_script, 'r') { |f| f.read }

          updated_java_home_entry       = "JAVA_HOME=\"#{java_home}\""
          updated_bea_home_entry        = "BEA_HOME=\"#{payara_install_path}\""
          updated_middleware_home_entry = "MW_HOME=\"#{payara_install_path}\""

          # Switch to Bash as default Bourne script execution fails for those with if [[ ...]] conditions
          # when configure.sh script tries to check for MW_HOME/BEA_HOME...
          bourne_shell_script_marker    = '#!/bin/sh'
          bash_shell_script_marker      = '#!/bin/bash'

          new_variables_insert = "#{bash_shell_script_marker}\n"
          new_variables_insert << "#{updated_java_home_entry}\n"
          new_variables_insert << "#{updated_bea_home_entry}\n"
          new_variables_insert << "#{updated_middleware_home_entry}\n"

          modified = original.gsub(/#{bourne_shell_script_marker}/, new_variables_insert)

          File.open(configure_script, 'w') { |f| f.write modified }
          log("Modified #{configure_script} to set MW_HOME variable!!")
        end

        def copy_templates
          ora_install_inventory_src     = @config_cache_root + ORA_INSTALL_INVENTORY_FILE
          payara_install_response_file_src = @config_cache_root + PAYARA_INSTALL_RESPONSE_FILE

          command = "rm -rf #{PAYARA_ORA_INV_INSTALL_PATH} 2>/dev/null;"
          command << "rm -rf #{@payara_install_path} 2>/dev/null;"
          command << "/bin/cp #{ora_install_inventory_src} /tmp;"
          command << "/bin/cp #{payara_install_response_file_src} /tmp"

          system "#{command}"
        end

        def update_template(template, pattern_from, pattern_to)
          original = File.open(template, 'r') { |f| f.read }
          modified = original.gsub(/#{pattern_from}/, pattern_to)
          File.open(template, 'w') { |f| f.write modified }
        end

        def construct_install_command(install_binary_file)
          java_binary = "#{@java_home}/bin/java"

          # There appears to be a problem running the java -jar on the cached jar file with java being unable to get to
          # the manifest correctly for some strange reason
          # Seems to fail with file name http:%2F%2F12.1.1.1:7777%2Ffileserver%2Fwls%2Fwls_121200.jar.cached but works
          # fine if its foo.jar or anything simpler.
          # So, create a temporary link to the jar with a simpler name and then run the install..
          if install_binary_file[/\.jar/]
            new_binary_path      = '/tmp/payara_tmp_installer.jar'
            install_command_args = " #{java_binary} -Djava.security.egd=file:/dev/./urandom -jar #{new_binary_path} "
          else
            new_binary_path      = '/tmp/payara_tmp_installer.bin'
            install_command_args = " #{new_binary_path} -J-Djava.security.egd=file:/dev/./urandom "
          end

          ora_install_inventory_target     = '/tmp/' + ORA_INSTALL_INVENTORY_FILE
          payara_install_response_file_target = '/tmp/' + PAYARA_INSTALL_RESPONSE_FILE

          install_pre_args = "export JAVA_HOME=#{@java_home}; rm #{new_binary_path} 2>/dev/null; "
          install_pre_args << " ln -s #{install_binary_file} #{new_binary_path}; "
          install_pre_args << " mkdir #{@payara_install_path}; chmod +x #{new_binary_path}; "

          install_post_args = " -silent -responseFile #{payara_install_response_file_target}"
          install_post_args << " -invPtrLoc #{ora_install_inventory_target}"

          install_command = install_pre_args + install_command_args + install_post_args

          install_command
        end

        def windows?
          (/cygwin|mswin|mingw|bccwin|wince|emx/ =~ RbConfig::CONFIG['host_os']) != nil
        end

        def mac?
          (/darwin/ =~ RbConfig::CONFIG['host_os']) != nil
        end

        def sun?
          (/sunos|solaris/ =~ RbConfig::CONFIG['host_os']) != nil
        end

        def unix?
          !windows?
        end

        def linux?
          unix? && !mac? && !sun?
        end

        # Check whether running on non-linux machine, to pick the correct JAVA_HOME location
        def check_and_reset_java_home_for_non_linux(java_home)
          log("PayaraInstaller.check_and_reset_java_home_for_non_linux: java_home: #{java_home}")
          unless linux?
            log_and_print('Warning!!! Running on Mac or other non-linux flavor, cannot use linux java binaries ' \
                          'downloaded earlier...!!')
            log_and_print('Trying to find local java instance on machine')

            java_binary_locations = Dir.glob("/Library/Java/JavaVirtualMachines/**/#{JAVA_BINARY}")
            java_binary_locations.each do |java_binary_candidate|
              # The full installs have $JAVA_HOME/jre/bin/java path
              java_home = File.dirname(java_binary_candidate) + '/..' if java_binary_candidate[/jdk1.7/]
            end
            log_and_print("Warning!!! Using JAVA_HOME at #{java_home}")
          end
          java_home
        end

        def log(content)
          JavaBuildpack::Container::Payara::PayaraUtil.log(content)
        end

        def log_and_print(content)
          JavaBuildpack::Container::Payara::PayaraUtil.log_and_print(content)
        end
      end
    end
  end
end