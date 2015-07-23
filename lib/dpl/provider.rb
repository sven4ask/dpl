require 'dpl/error'
require 'dpl/version'
require 'fileutils'

module DPL
  class Provider
    include FileUtils

    autoload :Appfog,           'dpl/provider/appfog'
    autoload :Atlas,            'dpl/provider/atlas'
    autoload :Biicode,          'dpl/provider/biicode'
    autoload :Bintray,          'dpl/provider/bintray'
    autoload :BitBalloon,       'dpl/provider/bitballoon'
    autoload :ChefSupermarket,  'dpl/provider/chef_supermarket'
    autoload :Cloud66,          'dpl/provider/cloud66'
    autoload :CloudControl,     'dpl/provider/cloudcontrol'
    autoload :CloudFiles,       'dpl/provider/cloud_files'
    autoload :CloudFoundry,     'dpl/provider/cloud_foundry'
    autoload :CodeDeploy,       'dpl/provider/code_deploy'
    autoload :Deis,             'dpl/provider/deis'
    autoload :Divshot,          'dpl/provider/divshot'
    autoload :DotCloud,         'dpl/provider/dot_cloud'
    autoload :ElasticBeanstalk, 'dpl/provider/elastic_beanstalk'
    autoload :EngineYard,       'dpl/provider/engine_yard'
    autoload :ExoScale,         'dpl/provider/exoscale'
    autoload :GAE,              'dpl/provider/gae'
    autoload :GCS,              'dpl/provider/gcs'
    autoload :Hackage,          'dpl/provider/hackage'
    autoload :Heroku,           'dpl/provider/heroku'
    autoload :Lambda,           'dpl/provider/lambda'
    autoload :Modulus,          'dpl/provider/modulus'
    autoload :Nodejitsu,        'dpl/provider/nodejitsu'
    autoload :NPM,              'dpl/provider/npm'
    autoload :Openshift,        'dpl/provider/openshift'
    autoload :OpsWorks,         'dpl/provider/ops_works'
    autoload :Packagecloud,     'dpl/provider/packagecloud'
    autoload :PuppetForge,      'dpl/provider/puppet_forge'
    autoload :PyPI,             'dpl/provider/pypi'
    autoload :Releases,         'dpl/provider/releases'
    autoload :RubyGems,         'dpl/provider/rubygems'
    autoload :S3,               'dpl/provider/s3'
    autoload :Script,           'dpl/provider/script'
    autoload :TestFairy,        'dpl/provider/testfairy'
    autoload :Transifex,        'dpl/provider/transifex'


    def self.new(context, options)
      return super if self < Provider

      context.fold("Installing deploy dependencies") do
        name = super.option(:provider).to_s.downcase.gsub(/[^a-z0-9]/, '')
        raise Error, 'could not find provider %p' % options[:provider] unless name = constants.detect { |c| c.to_s.downcase == name }
        provider = const_get(name).new(context, options)
        provider.install_deploy_dependencies if provider.respond_to?(:install_deploy_dependencies)
        provider
      end
    end

    def self.experimental(name)
      puts "", "!!! #{name} support is experimental !!!", ""
    end

    def self.requires(name, options = {})
      version = options[:version] || '> 0'
      load    = options[:load]    || name
      gem(name, version)
    rescue LoadError
      context.shell("gem install %s -v %p --no-ri --no-rdoc #{'--pre' if options[:pre]}" % [name, version], retry: true)
      Gem.clear_paths
    ensure
      require load
    end

    def self.context
      self
    end

    def self.shell(command, options = {})
      system(command)
    end

    def self.apt_get(name, command = name)
      context.shell("sudo apt-get -qq install #{name}", retry: true) if `which #{command}`.chop.empty?
    end

    def self.pip(name, command = name, version = nil)
      if version
        puts "pip install --user #{name}==#{version}"
        context.shell("pip uninstall --user -y #{name}") unless `which #{command}`.chop.empty?
        context.shell("pip install --user #{name}==#{version}", retry: true)
      else
        puts "pip install --user #{name}"
        context.shell("pip install --user #{name}", retry: true) if `which #{command}`.chop.empty?
      end
      context.shell("export PATH=$PATH:$HOME/.local/bin")
    end

    def self.npm_g(name, command = name)
      context.shell("npm install -g #{name}", retry: true) if `which #{command}`.chop.empty?
    end

    attr_reader :context, :options

    def initialize(context, options)
      @context, @options = context, options
      context.env['GIT_HTTP_USER_AGENT'] = user_agent(git: `git --version`[/[\d\.]+/])
    end

    def user_agent(*strings)
      strings.unshift "dpl/#{DPL::VERSION}"
      strings.unshift "travis/0.1.0" if context.env['TRAVIS']
      strings = strings.flat_map { |e| Hash === e ? e.map { |k,v| "#{k}/#{v}" } : e }
      strings.join(" ").gsub(/\s+/, " ").strip
    end

    def option(name, *alternatives)
      options.fetch(name) do
        alternatives.any? ? option(*alternatives) : raise(Error, "missing #{name}")
      end
    end

    def deploy
      setup_git_credentials
      rm_rf ".dpl"
      mkdir_p ".dpl"

      context.fold("Preparing deploy") do
        check_auth
        check_app

        if needs_key?
          create_key(".dpl/id_rsa")
          setup_key(".dpl/id_rsa.pub")
          setup_git_ssh(".dpl/git-ssh", ".dpl/id_rsa")
        end

        cleanup
      end

      context.fold("Deploying application") { push_app }

      Array(options[:run]).each do |command|
        if command == 'restart'
          context.fold("Restarting application") { restart }
        else
          context.fold("Running %p" % command) { run(command) }
        end
      end
    ensure
      if needs_key?
        remove_key rescue nil
      end
      uncleanup
    end

    def sha
      @sha ||= context.env['TRAVIS_COMMIT'] || `git rev-parse HEAD`.strip
    end

    def commit_msg
      @commit_msg ||= %x{git log #{sha} -n 1 --pretty=%B}.strip
    end

    def cleanup
      return if options[:skip_cleanup]
      context.shell "mv .dpl ~/dpl"
      context.shell "git stash --all"
      context.shell "mv ~/dpl .dpl"
    end

    def uncleanup
      return if options[:skip_cleanup]
      context.shell "git stash pop"
    end

    def needs_key?
      true
    end

    def check_app
    end

    def create_key(file)
      context.shell "ssh-keygen -t rsa -N \"\" -C #{option(:key_name)} -f #{file}"
    end

    def setup_git_credentials
      context.shell "git config user.email >/dev/null 2>/dev/null || git config user.email `whoami`@localhost"
      context.shell "git config user.name >/dev/null 2>/dev/null || git config user.name `whoami`@localhost"
    end

    def setup_git_ssh(path, key_path)
      key_path = File.expand_path(key_path)
      path     = File.expand_path(path)

      File.open(path, 'w') do |file|
        file.write "#!/bin/sh\n"
        file.write "exec ssh -o StrictHostKeychecking=no -o CheckHostIP=no -o UserKnownHostsFile=/dev/null -i #{key_path} -- \"$@\"\n"
      end

      chmod(0740, path)
      context.env['GIT_SSH'] = path
    end

    def detect_encoding?
      options[:detect_encoding]
    end

    def encoding_for(path)
      file_cmd_output = `file #{path}`
      case file_cmd_output
      when /gzip compressed/
        'gzip'
      when /compress'd/
        'compress'
      end
    end

    def log(message)
      $stderr.puts(message)
    end

    def warn(message)
      log "\e[31;1m#{message}\e[0m"
    end

    def run(command)
      error "running commands not supported"
    end

    def error(message)
      raise Error, message
    end
  end
end
