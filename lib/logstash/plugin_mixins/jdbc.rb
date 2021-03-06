# encoding: utf-8
# TAKEN FROM WIIBAA
require "logstash/config/mixin"

# Tentative of abstracting JDBC logic to a mixin 
# for potential reuse in other plugins (input/output)
module LogStash::PluginMixins::Jdbc

  @logger = Cabin::Channel.get(LogStash)

  # This method is called when someone includes this module
  def self.included(base)
    # Add these methods to the 'base' given.
    base.extend(self)
    base.setup_jdbc_config
  end


  public
  def setup_jdbc_config
    # JDBC driver library path to third party driver library.
    #
    # If not provided, Plugin will look for the driver class in the Logstash Java classpath.
    config :jdbc_driver_library, :validate => :path

    # JDBC driver class to load, for example "oracle.jdbc.OracleDriver" or "org.apache.derby.jdbc.ClientDriver"
    config :jdbc_driver_class, :validate => :string, :required => true

    # JDBC connection string
    config :jdbc_connection_string, :validate => :string, :required => true

    # JDBC user
    config :jdbc_user, :validate => :string, :required => true

    # JDBC password
    config :jdbc_password, :validate => :password

    # JDBC enable paging
    #
    # This will cause a sql statement to be broken up into multiple queries.
    # Each query will use limits and offsets to collectively retrieve the full
    # result-set. The limit size is set with `jdbc_page_size`.
    #
    # Be aware that ordering is not guaranteed between queries.
    config :jdbc_paging_enabled, :validate => :boolean, :default => false 

    # JDBC page size
    config :jdbc_page_size, :validate => :number, :default => 100000

    # JDBC fetch size. if not provided, respective driver's default will be used
    config :jdbc_fetch_size, :validate => :number

    # Connection pool configuration.
    # Validate connection before use.
    config :jdbc_validate_connection, :validate => :boolean, :default => false

    # Connection pool configuration.
    # How often to validate a connection (in seconds)
    config :jdbc_validation_timeout, :validate => :number, :default => 3600
  end

  public
  def prepare_jdbc_connection
    require "java"
    require "sequel"
    require "sequel/adapters/jdbc"
    require @jdbc_driver_library if @jdbc_driver_library
    begin
      Sequel::JDBC.load_driver(@jdbc_driver_class)
    rescue Sequel::AdapterNotFound => e
      message = if @jdbc_driver_library.nil?
                  ":jdbc_driver_library is not set, are you sure you included 
                  the proper driver client libraries in your classpath?"
                else
                  "Are you sure you've included the correct jdbc driver in :jdbc_driver_library?"
                end
      raise LogStash::ConfigurationError, "#{e}. #{message}"
    end
    @database = Sequel.connect(@jdbc_connection_string, :user=> @jdbc_user, :password=>  @jdbc_password.nil? ? nil : @jdbc_password.value)
    @database.extension(:pagination)
    if @jdbc_validate_connection
      @database.extension(:connection_validator)
      @database.pool.connection_validation_timeout = @jdbc_validation_timeout
    end
    @database.fetch_size = @jdbc_fetch_size unless @jdbc_fetch_size.nil?
    begin
      @database.test_connection
    rescue Sequel::DatabaseConnectionError => e
      #TODO return false and let the plugin raise a LogStash::ConfigurationError
      raise e
    end

    @sql_last_start = Time.at(0).utc
  end # def prepare_jdbc_connection

  public
  def close_jdbc_connection
    @database.disconnect if @database
  end

  public
  def execute_statement(statement, parameters)
    success = false
    begin 
      parameters = symbolized_params(parameters)
      query = @database[statement, parameters]
      @logger.debug? and @logger.debug("Executing JDBC query", :statement => statement, :parameters => parameters)
      @sql_last_start = Time.now.utc

      if @jdbc_paging_enabled
        query.each_page(@jdbc_page_size) do |paged_dataset|
          paged_dataset.each do |row|
            #Stringify row keys
            yield Hash[row.map { |k, v| [k.to_s, v] }]
          end
        end
      else
        query.each do |row|
          #Stringify row keys
          yield Hash[row.map { |k, v| [k.to_s, v] }]
        end
      end
      success = true
    rescue Sequel::DatabaseConnectionError, Sequel::DatabaseError => e
      @logger.warn("Exception when executing JDBC query", :exception => e)
    end
    return success
  end

  # Symbolize parameters keys to use with Sequel
  private 
  def symbolized_params(parameters)
    parameters.inject({}) do |hash,(k,v)| 
      case v
      when LogStash::Timestamp
        hash[k.to_sym] = v.time
      else
        hash[k.to_sym] = v
      end
      hash
    end
  end
end
