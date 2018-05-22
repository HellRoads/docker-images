require 'util/postgres_admin'

module MiqServer::LogManagement
  extend ActiveSupport::Concern

  included do
    belongs_to :log_file_depot, :class_name => "FileDepot"
    has_many   :log_files, :dependent => :destroy, :as => :resource
  end

  def format_log_time(time)
    time.respond_to?(:strftime) ? time.strftime("%Y%m%d_%H%M%S") : "unknown"
  end

  def post_historical_logs(taskid, log_depot)
    task = MiqTask.find(taskid)
    log_prefix = "Task: [#{task.id}]"
    log_type = "Archive"

    # Post all compressed logs for a specific date + configs, creating a new row per day
    VMDB::Util.compressed_log_patterns.each do |pattern|
      log_start, log_end = log_start_and_end_for_pattern(pattern)
      date_string = "#{format_log_time(log_start)}_#{format_log_time(log_end)}" unless log_start.nil? && log_end.nil?

      cond = {:historical => true, :name => LogFile.logfile_name(self, log_type, date_string), :state => 'available'}
      cond[:logging_started_on] = log_start unless log_start.nil?
      cond[:logging_ended_on] = log_end unless log_end.nil?
      logfile = log_files.find_by(cond)

      if logfile && logfile.log_uri.nil?
        _log.info("#{log_prefix} #{log_type} logfile already exists with id: [#{logfile.id}] for [#{who_am_i}] with contents from: [#{log_start}] to: [#{log_end}]")
        next
      else
        logfile = LogFile.historical_logfile
      end

      logfile.update(:file_depot => log_depot, :miq_task   => task)
      post_one_log_pattern(pattern, logfile, log_type)
    end
  end

  def log_patterns(log_type, base_pattern = nil)
    case log_type.to_s.downcase
    when "archive"
      Array(::Settings.log.collection.archive.pattern).unshift(base_pattern)
    when "current"
      current_log_patterns
    end
  end

  def _post_my_logs(options)
    # Make the request to the MiqServer whose logs are needed
    MiqQueue.create_with(
      :miq_callback => options.delete(:callback),
      :msg_timeout  => options.delete(:timeout),
      :priority     => MiqQueue::HIGH_PRIORITY,
      :args         => [options]
    ).put_unless_exists(
      :class_name  => self.class.name,
      :instance_id => id,
      :method_name => "post_logs",
      :server_guid => guid,
      :zone        => my_zone,
    ) do |msg|
      _log.info("Previous adhoc log collection is still running, skipping...Resource: [#{self.class.name}], id: [#{id}]") unless msg.nil?
      nil
    end
  end

  def synchronize_logs(*args)
    options = args.extract_options!
    args << self unless args.last.kind_of?(self.class)
    LogFile.logs_from_server(*args, options)
  end

  def last_log_sync_on
    log_files.maximum(:updated_on)
  end

  def last_log_sync_message
    last_log = log_files.order(:updated_on => :desc).first
    last_log.try(:miq_task).try!(:message)
  end

  def post_logs(options)
    taskid = options[:taskid]
    task = MiqTask.find(taskid)
    context_log_depot = log_depot(options[:context])

    # the current queue item and task must be errored out on exceptions so re-raise any caught errors
    raise _("Log depot settings not configured") unless context_log_depot
    context_log_depot.update_attributes(:support_case => options[:support_case].presence)

    post_historical_logs(taskid, context_log_depot) unless options[:only_current]
    post_current_logs(taskid, context_log_depot)
    task.update_status("Finished", "Ok", "Log files were successfully collected")
  end

  def current_log_patterns
    # use an array union to add pg log path patterns if not already there
    ::Settings.log.collection.current.pattern | pg_log_patterns
  end

  def pg_data_dir
    PostgresAdmin.data_directory
  end

  def pg_log_patterns
    pg_data = pg_data_dir
    return [] unless pg_data

    pg_data = Pathname.new(pg_data)
    [pg_data.join("*.conf"), pg_data.join("pg_log/*")]
  end

  def log_start_and_end_for_pattern(pattern)
    evm = VMDB::Util.get_evm_log_for_date(pattern)
    return if evm.nil?

    VMDB::Util.get_log_start_end_times(evm)
  end

  def post_one_log_pattern(pattern, logfile, log_type)
    task = logfile.miq_task
    log_prefix = "Task: [#{task.id}]"

    log_start, log_end = log_start_and_end_for_pattern(pattern)
    date_string = "#{format_log_time(log_start)} #{format_log_time(log_end)}" unless log_start.nil? && log_end.nil?

    msg = "Zipping and posting #{log_type.downcase} logs for [#{who_am_i}] from: [#{log_start}] to [#{log_end}]"
    _log.info("#{log_prefix} #{msg}")
    task.update_status("Active", "Ok", msg)

    begin
      local_file = VMDB::Util.zip_logs("evm.zip", log_patterns(log_type, pattern), "system")
      self.log_files << logfile

      logfile.update_attributes(
        :local_file         => local_file,
        :logging_started_on => log_start,
        :logging_ended_on   => log_end,
        :name               => LogFile.logfile_name(self, log_type, date_string),
        :description        => "Logs for Zone #{zone.name rescue nil} Server #{self.name} #{date_string}",
      )

      logfile.upload

    rescue StandardError, Timeout::Error => err
      _log.error("#{log_prefix} Posting of #{log_type.downcase} logs failed for #{who_am_i} due to error: [#{err.class.name}] [#{err}]")
      logfile.update_attributes(:state => "error")
      raise
    end
    msg = "#{log_type} log files from #{who_am_i} are posted"
    _log.info("#{log_prefix} #{msg}")
    task.update_status("Active", "Ok", msg)
  end

  def post_current_logs(taskid, log_depot)
    delete_old_requested_logs

    logfile = LogFile.current_logfile
    logfile.update(:file_depot => log_depot, :miq_task   => MiqTask.find(taskid))
    post_one_log_pattern("log/*.log", logfile, "Current")
  end

  def delete_old_requested_logs
    log_files.where(:historical => false).destroy_all
  end

  def delete_active_log_collections_queue
    MiqQueue.create_with(:priority => MiqQueue::HIGH_PRIORITY).put_unless_exists(
      :class_name  => self.class.name,
      :instance_id => id,
      :method_name => "delete_active_log_collections",
      :server_guid => guid
    ) do |msg|
      _log.info("Previous cleanup is still running, skipping...") unless msg.nil?
    end
  end

  def delete_active_log_collections
    log_files.each do |lf|
      if lf.state == 'collecting'
        _log.info("Deleting #{lf.description}")
        lf.miq_task.update_attributes(:state => 'Finished', :status => 'Error', :message => 'Log Collection Incomplete during Server Startup') unless lf.miq_task.nil?
        lf.destroy
      end
    end

    # Since a task is created before a logfile, there's a chance we have a task without a logfile
    MiqTask.where(:miq_server_id => id).where("name like ?", "Zipped log retrieval for %").where("state != ?", "Finished").each do |task|
      task.update_attributes(:state => 'Finished', :status => 'Error', :message => 'Log Collection Incomplete during Server Startup')
    end
  end

  def log_collection_active_recently?(since = nil)
    since ||= 15.minutes.ago.utc
    return true if log_files.exists?(["created_on > ? AND state = ?", since, "collecting"])
    MiqTask.exists?(["miq_server_id = ? and name like ? and state != ? and created_on > ?", id, "Zipped log retrieval for %", "Finished", since])
  end

  def log_collection_active?
    return true if log_files.exists?(:state => "collecting")
    MiqTask.exists?(["miq_server_id = ? and name like ? and state != ?", id, "Zipped log retrieval for %", "Finished"])
  end

  def log_depot(context)
    context == "Zone" ? zone.log_file_depot : log_file_depot
  end

  def base_zip_log_name
    t = Time.now.utc.strftime('%FT%H_%M_%SZ'.freeze)
    # Name the file based on GUID and time.  GUID and Date/time of the request are as close to unique filename as we're going to get
    "App-#{guid}-#{t}"
  end
end