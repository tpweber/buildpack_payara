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

require 'spec_helper'
require 'application_helper'
require 'console_helper'
require 'logging_helper'
require 'open3'

shared_context 'integration_helper' do
  include_context 'application_helper'
  include_context 'console_helper'
  include_context 'logging_helper'

  let(:buildpack_dir) { Pathname.new Dir.mktmpdir }

  before do
    FileUtils.mkdir_p buildpack_dir
  end

  before do |example|
    %w(bin config lib resources).each { |dir| FileUtils.cp_r dir, buildpack_dir }
    buildpack_fixture = example.metadata[:buildpack_fixture]
    FileUtils.cp_r "spec/fixtures/#{buildpack_fixture.chomp}/.", buildpack_dir if buildpack_fixture
  end

  before do
    rewrite_jre_repository_root(buildpack_dir + 'config/oracle_jre.yml', ENV['ORACLE_JRE_DOWNLOAD'])
    rewrite_repository_root(buildpack_dir + 'config/payara_as.yml', ENV['WEBLOGIC_DOWNLOAD'])
  end

  after do |example|
    if example.metadata[:no_cleanup]
      puts "Buildpack Directory: #{buildpack_dir}"
    else
      FileUtils.rm_rf buildpack_dir
    end
  end

  def run(command)
    Open3.popen3(command, chdir: buildpack_dir) do |_stdin, stdout, stderr, wait_thr|
      capture_output stdout, stderr
      yield wait_thr.value if block_given?
    end
  end

  private

  def rewrite_jre_repository_root(file, new_repository_root)
    config = YAML.load_file(file)
    config['jre']['repository_root'] = new_repository_root
    File.open(file, 'w') do |open_file|
      open_file.write config.to_yaml
    end
  end

  def rewrite_repository_root(file, new_repository_root)
    config = YAML.load_file(file)
    config['repository_root'] = new_repository_root
    File.open(file, 'w') do |open_file|
      open_file.write config.to_yaml
    end
  end

end
