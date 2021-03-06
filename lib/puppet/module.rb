require 'puppet/util/logging'
require 'semver'
require 'puppet/module_tool/applications'

# Support for modules
class Puppet::Module
  class Error < Puppet::Error; end
  class MissingModule < Error; end
  class IncompatibleModule < Error; end
  class UnsupportedPlatform < Error; end
  class IncompatiblePlatform < Error; end
  class MissingMetadata < Error; end
  class InvalidName < Error; end

  include Puppet::Util::Logging

  TEMPLATES = "templates"
  FILES = "files"
  MANIFESTS = "manifests"
  PLUGINS = "plugins"

  FILETYPES = [MANIFESTS, FILES, TEMPLATES, PLUGINS]

  # Find and return the +module+ that +path+ belongs to. If +path+ is
  # absolute, or if there is no module whose name is the first component
  # of +path+, return +nil+
  def self.find(modname, environment = nil)
    return nil unless modname
    Puppet::Node::Environment.new(environment).module(modname)
  end

  attr_reader :name, :environment
  attr_writer :environment

  attr_accessor :dependencies, :forge_name
  attr_accessor :source, :author, :version, :license, :puppetversion, :summary, :description, :project_page

  def has_metadata?
    return false unless metadata_file

    return false unless FileTest.exist?(metadata_file)

    metadata = PSON.parse File.read(metadata_file)


    return metadata.is_a?(Hash) && !metadata.keys.empty?
  end

  def initialize(name, options = {})
    @name = name
    @path = options[:path]

    assert_validity

    if options[:environment].is_a?(Puppet::Node::Environment)
      @environment = options[:environment]
    else
      @environment = Puppet::Node::Environment.new(options[:environment])
    end

    load_metadata if has_metadata?

    validate_puppet_version
  end

  FILETYPES.each do |type|
    # A boolean method to let external callers determine if
    # we have files of a given type.
    define_method(type +'?') do
      return false unless path
      return false unless FileTest.exist?(subpath(type))
      return true
    end

    # A method for returning a given file of a given type.
    # e.g., file = mod.manifest("my/manifest.pp")
    #
    # If the file name is nil, then the base directory for the
    # file type is passed; this is used for fileserving.
    define_method(type.to_s.sub(/s$/, '')) do |file|
      return nil unless path

      # If 'file' is nil then they're asking for the base path.
      # This is used for things like fileserving.
      if file
        full_path = File.join(subpath(type), file)
      else
        full_path = subpath(type)
      end

      return nil unless FileTest.exist?(full_path)
      return full_path
    end
  end

  def exist?
    ! path.nil?
  end

  def license_file
    return @license_file if defined?(@license_file)

    return @license_file = nil unless path
    @license_file = File.join(path, "License")
  end

  def load_metadata
    data = PSON.parse File.read(metadata_file)
    @forge_name = data['name'].gsub('-', '/') if data['name']

    [:source, :author, :version, :license, :puppetversion, :dependencies].each do |attr|
      unless value = data[attr.to_s]
        unless attr == :puppetversion
          raise MissingMetadata, "No #{attr} module metadata provided for #{self.name}"
        end
      end
      send(attr.to_s + "=", value)
    end
  end

  # Return the list of manifests matching the given glob pattern,
  # defaulting to 'init.{pp,rb}' for empty modules.
  def match_manifests(rest)
    pat = File.join(path, MANIFESTS, rest || 'init')
    [manifest("init.pp"),manifest("init.rb")].compact + Dir.
      glob(pat + (File.extname(pat).empty? ? '.{pp,rb}' : '')).
      reject { |f| FileTest.directory?(f) }
  end

  def metadata_file
    return @metadata_file if defined?(@metadata_file)

    return @metadata_file = nil unless path
    @metadata_file = File.join(path, "metadata.json")
  end

  # Find this module in the modulepath.
  def path
    @path ||= environment.modulepath.collect { |path| File.join(path, name) }.find { |d| FileTest.directory?(d) }
  end

  # Find all plugin directories.  This is used by the Plugins fileserving mount.
  def plugin_directory
    subpath("plugins")
  end

  def supports(name, version = nil)
    @supports ||= []
    @supports << [name, version]
  end

  def to_s
    result = "Module #{name}"
    result += "(#{path})" if path
    result
  end

  def dependencies_as_modules
    dependent_modules = []
    dependencies and dependencies.each do |dep|
      author, dep_name = dep["name"].split('/')
      found_module = environment.module(dep_name)
      dependent_modules << found_module if found_module
    end

    dependent_modules
  end

  def required_by
    environment.module_requirements[self.forge_name] || {}
  end

  def has_local_changes?
    changes = Puppet::Module::Tool::Applications::Checksummer.run(path)
    !changes.empty?
  end

  def unmet_dependencies
    return [] unless dependencies

    unmet_dependencies = []

    dependencies.each do |dependency|
      forge_name = dependency['name']
      author, dep_name = forge_name.split('/')
      version_string = dependency['version_requirement']

      equality, dep_version = version_string ? version_string.split("\s") : [nil, nil]

      unless dep_mod = environment.module(dep_name)
        msg =  "Missing dependency `#{dep_name}`:\n"
        msg += "  `#{self.name}` (#{self.version}) requires `#{forge_name}` (#{version_string})\n"
        unmet_dependencies << { :name => forge_name, :error => msg }
        next
      end

      if dep_version && !dep_mod.version
        msg =  "Unversioned dependency `#{dep_mod.name}`:\n"
        msg += "  `#{self.name}` (#{self.version}) requires `#{forge_name}` (#{version_string})\n"
        unmet_dependencies << { :name => forge_name, :error => msg }
        next
      end

      if dep_version
        begin
          required_version_semver = SemVer.new(dep_version)
          actual_version_semver = SemVer.new(dep_mod.version)
        rescue ArgumentError
          msg =  "Non semantic version dependency `#{dep_mod.name}` (#{dep_mod.version}):\n"
          msg += "  `#{self.name}` (#{self.version}) requires `#{forge_name}` (#{version_string})\n"
          unmet_dependencies << { :name => forge_name, :error => msg }
          next
        end

        if !actual_version_semver.send(equality, required_version_semver)
          msg =  "Version dependency mismatch `#{dep_mod.name}` (#{dep_mod.version}):\n"
          msg += "  `#{self.name}` (#{self.version}) requires `#{forge_name}` (#{version_string})\n"
          unmet_dependencies << { :name => forge_name, :error => msg }
          next
        end
      end
    end
    unmet_dependencies
  end

  def validate_puppet_version
    return unless puppetversion and puppetversion != Puppet.version
    raise IncompatibleModule, "Module #{self.name} is only compatible with Puppet version #{puppetversion}, not #{Puppet.version}"
  end

  private

  def subpath(type)
    return File.join(path, type) unless type.to_s == "plugins"

    backward_compatible_plugins_dir
  end

  def backward_compatible_plugins_dir
    if dir = File.join(path, "plugins") and FileTest.exist?(dir)
      Puppet.deprecation_warning "using the deprecated 'plugins' directory for ruby extensions; please move to 'lib'"
      return dir
    else
      return File.join(path, "lib")
    end
  end

  def assert_validity
    raise InvalidName, "Invalid module name #{name}; module names must be alphanumeric (plus '-'), not '#{name}'" unless name =~ /^[-\w]+$/
  end

  def ==(other)
    self.name == other.name &&
      self.version == other.version &&
      self.path == other.path &&
      self.environment == other.environment
  end
end
