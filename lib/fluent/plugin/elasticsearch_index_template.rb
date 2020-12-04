require 'fluent/error'
require_relative './elasticsearch_error'

module Fluent::ElasticsearchIndexTemplate
  def get_template(template_file, customize_template = {})
    if !File.exists?(template_file)
      raise "If you specify a template_name you must specify a valid template file (checked '#{template_file}')!"
    end
    file_contents = IO.read(template_file).gsub(/\n/,'')
    customize_template.each do |key, value|
      file_contents = file_contents.gsub(key,value.downcase)
    end
    JSON.parse(file_contents)
  end

  def template_exists?(name, is_legacy, host = nil)
    if is_legacy
      client(host).indices.get_template(:name => name)
    else
      client(host).indices.get_index_template(:name => name)
    end
    return true
  rescue Elasticsearch::Transport::Transport::Errors::NotFound
    return false
  end

  def retry_operate(max_retries, fail_on_retry_exceed = true, catch_trasport_exceptions = true)
    return unless block_given?
    retries = 0
    transport_errors = Elasticsearch::Transport::Transport::Errors.constants.map{ |c| Elasticsearch::Transport::Transport::Errors.const_get c } if catch_trasport_exceptions
    begin
      yield
    rescue *client.transport.host_unreachable_exceptions, *transport_errors, Timeout::Error => e
      @_es = nil
      @_es_info = nil
      if retries < max_retries
        retries += 1
        wait_seconds = 2**retries
        sleep wait_seconds
        log.warn "Could not communicate to Elasticsearch, resetting connection and trying again. #{e.message}"
        log.warn "Remaining retry: #{max_retries - retries}. Retry to communicate after #{wait_seconds} second(s)."
        retry
      end
      message = "Could not communicate to Elasticsearch after #{retries} retries. #{e.message}"
      log.warn message
      raise Fluent::Plugin::ElasticsearchError::RetryableOperationExhaustedFailure,
            message if fail_on_retry_exceed
    end
  end

  def template_put(name, template, is_legacy, host = nil)
    if is_legacy
      client(host).indices.put_template(:name => name, :body => template)
    else
      client(host).indices.put_index_template(:name => name, :body => template)
    end
  end

  def indexcreation(index_name, host = nil)
    client(host).indices.create(:index => index_name)
  rescue Elasticsearch::Transport::Transport::Error => e
    if e.message =~ /"already exists"/ || e.message =~ /resource_already_exists_exception/
      log.debug("Index #{index_name} already exists")
    else
      log.error("Error while index creation - #{index_name}", error: e)
    end
  end

  def need_install_template?(template_installation_name, is_legacy, host, overwrite)
    overwrite || !template_exists?(template_installation_name, is_legacy, host)
  end

  def setup_template_with_ilm(deflector_alias_name, target_index, ilm_policy_id, template, index_separator, is_legacy)
    if is_legacy
      template = inject_ilm_settings_to_legacy_template(deflector_alias_name, target_index, ilm_policy_id, template, index_separator)
    else
      template = inject_ilm_settings_to_template(deflector_alias_name, target_index, ilm_policy_id, template, index_separator)
    end

    template
  end

  def inject_ilm_settings_to_legacy_template(deflector_alias, target_index, ilm_policy_id, template, index_separator)
    log.debug("Overwriting index patterns when Index Lifecycle Management is enabled.")
    template['index_patterns'] = "#{target_index}#{index_separator}*"

    template.delete('template') if template.include?('template')
    # Prepare settings Hash if it does not exist
    template['settings'] = {} unless template.key?('settings')

    if template['settings'].key?('index.lifecycle.name') || template['settings'].key?('index.lifecycle.rollover_alias')
      log.debug("Overwriting index lifecycle name and rollover alias when Index Lifecycle Management is enabled.")
    end

    template['settings'].update({ 'index.lifecycle.name' => ilm_policy_id, 'index.lifecycle.rollover_alias' => deflector_alias})
    template['order'] = template['order'] ? template['order'] + target_index.count(index_separator) + 1 : 51 + target_index.count(index_separator)

    template
  end

  def inject_ilm_settings_to_template(deflector_alias, target_index, ilm_policy_id, template, index_separator)
    log.debug("Overwriting index patterns when Index Lifecycle Management is enabled.")
    template['index_patterns'] = "#{target_index}#{index_separator}*"

    # Prepare settings Hash if it does not exist
    template['template']['settings'] = {} unless template['template'].key?('settings')

    if template['template']['settings'].key?('index.lifecycle.name') || template['template']['settings'].key?('index.lifecycle.rollover_alias')
      log.debug("Overwriting index lifecycle name and rollover alias when Index Lifecycle Management is enabled.")
    end
    template['template']['settings'].update({ 'index.lifecycle.name' => ilm_policy_id, 'index.lifecycle.rollover_alias' => deflector_alias})
    template['priority'] = template['priority'] ? template['priority'] + target_index.count(index_separator) + 1 : 101 + target_index.count(index_separator)

    template
  end

  def create_rollover_alias(target_index, rollover_index, deflector_alias_name, app_name, index_date_pattern, index_separator, enable_ilm, ilm_policy_id, ilm_policy, ilm_policy_overwrite, host)
     # ILM request to create alias.
    if rollover_index || enable_ilm
      if !client.indices.exists_alias(:name => deflector_alias_name)
        if @logstash_format
          index_name_temp = '<'+target_index+'-000001>'
        else
          if index_date_pattern.empty?
            index_name_temp = '<'+target_index.downcase+index_separator+app_name.downcase+'-000001>'
          else
            index_name_temp = '<'+target_index.downcase+index_separator+app_name.downcase+'-{'+index_date_pattern+'}-000001>'
          end
        end
        indexcreation(index_name_temp, host)
        body = rollover_alias_payload(deflector_alias_name)
        client.indices.put_alias(:index => index_name_temp, :name => deflector_alias_name,
                                 :body => body)
        log.info("The alias '#{deflector_alias_name}' is created for the index '#{index_name_temp}'")
      else
        log.debug("The alias '#{deflector_alias_name}' is already present")
      end
      # Create ILM policy if rollover indices exist.
      if enable_ilm
        if ilm_policy.empty?
          setup_ilm(enable_ilm, ilm_policy_id)
        else
          setup_ilm(enable_ilm, ilm_policy_id, ilm_policy, ilm_policy_overwrite)
        end
      end
    else
      log.debug("No index and alias creation action performed because rollover_index or enable_ilm is set to: '#{rollover_index}', '#{enable_ilm}'")
    end
  end

  def templates_hash_install(templates, overwrite, is_legacy)
    templates.each do |key, value|
      template_install(key, value, overwrite, is_legacy)
    end
  end

  def rollover_alias_payload(rollover_alias)
    {
      'aliases' => {
        rollover_alias => {
          'is_write_index' =>  true
        }
      }
    }
  end
end
