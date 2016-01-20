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
    module Wls

      # Encapsulates the logic for detecting an application that should be run on Weblogic
      class WlsDetector
        include JavaBuildpack::Container::Wls::WlsConstants

        # return true if the application should be run on Weblogic
        def self.detect(application)
          search_path        = (application.root).to_s + '/**/weblogic*xml'
          wls_config_present = Dir.glob(search_path).length > 0

          is_ear_app                  = app_inf?(application)
          is_web_app                  = web_inf?(application)
          app_wls_config_cache_exists = (application.root + APP_WLS_CONFIG_CACHE_DIR).exist?

          unless app_wls_config_cache_exists
            app_wls_config_cache_exists = (application.root + 'APP-INF' + APP_WLS_CONFIG_CACHE_DIR).exist?
          end

          unless app_wls_config_cache_exists
            app_wls_config_cache_exists = (application.root + 'WEB-INF' + APP_WLS_CONFIG_CACHE_DIR).exist?
          end

          log("Running Detection on App: #{application.root}")
          log("  Checking for presence of #{APP_WLS_CONFIG_CACHE_DIR} folder under root of the App" \
                          ' or weblogic deployment descriptors within App')
          log("  Does #{APP_WLS_CONFIG_CACHE_DIR} folder exist under root of the App? : #{app_wls_config_cache_exists}")

          result = (wls_config_present || app_wls_config_cache_exists || is_web_app || is_ear_app) && \
                   !JavaBuildpack::Util::JavaMainUtils.main_class(application)

          unless result
            log "WLS Buildpack Detection on App: #{application.root} failed!!!"
            log "Checked for presence of #{APP_WLS_CONFIG_CACHE_DIR} folder under root of the App " \
                            ' or weblogic deployment descriptors within App'
            log "  Do weblogic deployment descriptors exist within App?   : #{wls_config_present}"
            log "  Or is it a simple Web Application with WEB-INF folder? : #{is_web_app}"
            log "  Or is it a Enterprise Application with APP-INF folder? : #{is_ear_app}"
            log "  Or does #{APP_WLS_CONFIG_CACHE_DIR} folder exist under root of the App?       : " \
                "#{app_wls_config_cache_exists}"
          end

          result
        end

        def self.web_inf?(application)
          (application.root + 'WEB-INF').exist?
        end

        def self.app_inf?(application)
          (application.root + 'APP-INF').exist?
        end

        # Log the message
        def self.log(content)
          JavaBuildpack::Container::Wls::WlsUtil.log(content)
        end

      end
    end
  end
end
