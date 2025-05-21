# frozen_string_literal: true

# Service to fetch emails from Aliyun (or other generic IMAP servers not using OAuth2)
# This service uses direct Net::IMAP for connection and fetching.
# It's designed to be more resilient to servers that might have quirks
# with UID SEARCH ranges or other IMAP commands.

module Imap
  class AliyunFetchEmailService < BaseFetchEmailService
    # Constants
    MAX_EMAILS_PER_FETCH_CYCLE_FOR_TEST = 5 # For testing, limit emails processed in one go. Set to nil or 0 for no limit in prod.
    UID_SEARCH_RANGE_SIZE = 200 # How many UIDs to search in a single UID SEARCH command if not using 'ALL'

    attr_reader :channel, :inbox, :imap_connection, :current_max_uid, :processed_mail_count, :new_max_uid_this_run

    def initialize(channel:, inbox: nil, imap_config: nil)
      super(channel: channel) # Pass channel to BaseFetchEmailService if it expects it
      @channel = channel
      @inbox = channel.inbox # Assuming channel has_one inbox or similar
      @imap_connection = nil
      @processed_mail_count = 0
      @new_max_uid_this_run = 0
      @limit_for_test = imap_config&.fetch(:limit_for_test, nil) # 从配置中读取，如果提供

      @mailbox_selected = false # 新增: 邮箱是否成功选择的标志
      @mailbox_uidnext = nil    # 新增: 存储邮箱的 UIDNEXT 值

      final_check_channel_object # 确保 channel 和 inbox 对象有效
    end

    # The main perform method.
    def perform
      Rails.logger.info "[AliyunService PERFORM START] Attempting to fetch emails for Channel ID: #{@channel.id}, Inbox ID: #{@inbox.id}"
      @processed_mail_count = 0
      @new_max_uid_this_run = @current_max_uid # Initialize with current_max_uid

      # This log was part of final_check_channel_object, but good to have context here too.
      Rails.logger.info "[AliyunService INIT] Channel ID: #{@channel.id}. Initial @current_max_uid from channel: #{@current_max_uid}"

      unless ensure_imap_enabled? && can_connect_to_imap?
        Rails.logger.warn "[AliyunService PERFORM] IMAP not enabled or cannot connect for Channel ID: #{@channel.id}. Aborting."
        return []
      end

      unless connect_and_login_to_aliyun
        Rails.logger.error "[AliyunService PERFORM] Failed to establish persistent IMAP connection for Channel ID: #{@channel.id}. Aborting."
        return []
      end

      unless select_mailbox('INBOX')
        Rails.logger.error "[AliyunService PERFORM] Failed to select inbox for Channel ID: #{@channel.id}. Aborting."
        return []
      end

      new_uids = fetch_new_email_uids(limit_for_test: MAX_EMAILS_PER_FETCH_CYCLE_FOR_TEST)
      if new_uids.empty?
        Rails.logger.info "[AliyunService PERFORM] No new UIDs to process for Channel ID: #{@channel.id}."
        Rails.logger.info "[AliyunService PERFORM END] Processed #{@processed_mail_count} emails for Channel ID: #{@channel.id}. New max UID for run: #{@new_max_uid_this_run}. Returning 0 Mail::Message objects."
        return []
      end

      Rails.logger.info "[AliyunService PERFORM] Found #{new_uids.count} new UIDs to process: #{new_uids.inspect} for Channel ID: #{@channel.id}."
      mail_messages = process_email_uids(new_uids)

      Rails.logger.info "[AliyunService PERFORM END] Processed #{@processed_mail_count} emails for Channel ID: #{@channel.id}. New max UID for run: #{@new_max_uid_this_run}. Returning #{mail_messages.count} Mail::Message objects."
      mail_messages
    rescue StandardError => e
      # ... existing rescue code ...
      # return [] # Ensure this is present if you want to return from rescue
    ensure
      Rails.logger.error "!!!!!!!!!! [AliyunService DEBUG ENSURE BLOCK ENTERED] Channel ID: #{@channel.id} !!!!!!!!!!" # 新增的强制日志
      Rails.logger.info "[AliyunService PERFORM ENSURE] Entering ensure block for Channel ID: #{@channel.id}"
      update_channel_last_uid
      disconnect_from_aliyun
      log_email_processing_summary
      Rails.logger.info "[AliyunService PERFORM END] Finished email fetch for Channel ID: #{@channel.id}"
    end

    def disconnect_from_aliyun
      if @imap_connection && @imap_connection.respond_to?(:disconnected?) && !@imap_connection.disconnected?
        Rails.logger.info "[AliyunService DISCONNECT] Logging out and disconnecting from Aliyun IMAP."
        @imap_connection.logout
        @imap_connection.disconnect
      else
        Rails.logger.info "[AliyunService DISCONNECT] No active IMAP connection to disconnect, or connection does not support disconnected? check."
      end
    rescue Net::IMAP::Error, StandardError => e
      Rails.logger.warn "[AliyunService DISCONNECT WARN] Error during IMAP logout/disconnect: #{e.class} - #{e.message}"
    ensure
      @imap_connection = nil # Always set to nil
    end

    # Fetches new email UIDs from the server.
    # It starts searching from @current_max_uid + 1.
    # Handles potential issues with UID SEARCH ranges by falling back to 'ALL' if necessary.
    def fetch_new_email_uids(limit_for_test: nil)
      unless @imap_connection && @imap_connection.respond_to?(:disconnected?) && !@imap_connection.disconnected?
        Rails.logger.error "[AliyunService FETCH_UIDS] No active IMAP connection to fetch UIDs."
        return []
      end

      # Determine the starting UID for the search
      start_uid = @current_max_uid + 1
      search_keys_range = ["UID", "#{start_uid}:*"] # Search for UIDs from start_uid to the highest

      uids_found = []
      begin
        Rails.logger.info "[AliyunService FETCH_UIDS] Attempting UID_SEARCH with keys: #{search_keys_range.inspect}"
        uids_from_range = @imap_connection.uid_search(search_keys_range)

        if uids_from_range.nil?
          # This can happen on some servers if the range returns no results, or if there's an issue.
          Rails.logger.warn "[AliyunService FETCH_UIDS] UID_SEARCH with range #{search_keys_range.inspect} returned nil. This might be normal if no new emails, or an issue."
          # To be safe, or if this indicates an issue with range search, consider fallback.
          # For now, assume it means no UIDs in range.
          uids_found = []
        else
          Rails.logger.info "[AliyunService FETCH_UIDS] UID_SEARCH with range found #{uids_from_range.count} UIDs: #{uids_from_range.inspect}"
          uids_found = uids_from_range
        end

      rescue Net::IMAP::BadResponseError, Net::IMAP::NoResponseError => e
        Rails.logger.warn "[AliyunService FETCH_UIDS WARNING] UID_SEARCH with range #{search_keys_range.inspect} failed: #{e.class} - #{e.message}. Attempting fallback to 'ALL'."
        # Fallback strategy: Search for 'ALL' UIDs and then filter them.
        # This is less efficient but more robust if range searches are problematic.
        begin
          search_keys_all = ['ALL']
          Rails.logger.info "[AliyunService FETCH_UIDS] Fallback: Attempting UID_SEARCH with keys: #{search_keys_all.inspect}"
          uids_from_all = @imap_connection.uid_search(search_keys_all)

          if uids_from_all.nil?
            Rails.logger.warn "[AliyunService FETCH_UIDS] Fallback UID_SEARCH with 'ALL' also returned nil."
            uids_found = []
          else
            Rails.logger.info "[AliyunService FETCH_UIDS] Fallback UID_SEARCH 'ALL' found #{uids_from_all.count} UIDs: #{uids_from_all.inspect}"
            uids_found = uids_from_all.select { |uid| uid.to_i > @current_max_uid }
            Rails.logger.info "[AliyunService FETCH_UIDS] Filtered UIDs ( > #{@current_max_uid}) from 'ALL' fallback: #{uids_found.inspect}"
          end
        rescue StandardError => e_all
          Rails.logger.error "[AliyunService FETCH_UIDS ERROR] Fallback UID_SEARCH with 'ALL' also failed: #{e_all.class} - #{e_all.message}"
          # If fallback also fails, re-raise the original error from the range search.
          # This indicates a more fundamental issue with UID SEARCH on this server.
          raise e
        end
      rescue StandardError => e
        Rails.logger.error "[AliyunService FETCH_UIDS ERROR] Unexpected error during UID_SEARCH attempts: #{e.class} - #{e.message}"
        raise
      end

      # Process 'uids_found' which now contains UIDs from range search or filtered from 'ALL'
      if uids_found.empty?
        Rails.logger.info "[AliyunService FETCH_UIDS] No new UIDs found after all attempts."
        return []
      end

      sorted_uids = uids_found.sort # Ensure UIDs are sorted numerically
      Rails.logger.info "[AliyunService FETCH_UIDS] Total UIDs to consider for processing (sorted): #{sorted_uids.count} -> #{sorted_uids.inspect}"

      if limit_for_test && limit_for_test > 0 && sorted_uids.count > limit_for_test
        # Get the most recent 'limit_for_test' UIDs for processing
        uids_to_process = sorted_uids.last(limit_for_test)
        Rails.logger.info "[AliyunService FETCH_UIDS] Limiting UIDs to process to the latest #{limit_for_test}: #{uids_to_process.inspect}"
        return uids_to_process
      end

      return sorted_uids
    end

    def process_email_uids(uids)
      processed_info = []
      successfully_parsed_mails = [] # Now collects Mail::Message objects
      return successfully_parsed_mails if uids.empty?

      uids_to_fetch_full_data = uids
      Rails.logger.info "[AliyunService PROCESS_UIDS] Will attempt to fetch full data for #{uids_to_fetch_full_data.count} UIDs: #{uids_to_fetch_full_data.inspect}"

      uids_to_fetch_full_data.each do |uid|
        Rails.logger.info "[AliyunService PROCESS_UIDS] Fetching RFC822 and INTERNALDATE for UID: #{uid}"
        fetch_data_array = @imap_connection.uid_fetch([uid], ['RFC822', 'INTERNALDATE'])

        if fetch_data_array.nil? || fetch_data_array.empty? || fetch_data_array[0].attr.nil?
          Rails.logger.warn "[AliyunService PROCESS_UIDS] No data or attributes returned from UID_FETCH for UID: #{uid}."
          processed_info << { uid: uid, status: :fetch_failed, error: "No data from UID_FETCH" }
          next
        end

        rfc822_data = fetch_data_array[0].attr['RFC822']
        internal_date_str = fetch_data_array[0].attr['INTERNALDATE'] # Keep for future use or logging

        if rfc822_data.blank?
          Rails.logger.warn "[AliyunService PROCESS_UIDS] RFC822 data is blank for UID: #{uid}."
          processed_info << { uid: uid, status: :blank_rfc822, error: "RFC822 data is blank" }
          next
        end

        Rails.logger.info "[AliyunService PROCESS_UIDS] Successfully fetched RFC822 (length: #{rfc822_data.length}) and INTERNALDATE ('#{internal_date_str}') for UID: #{uid}"

        begin
          mail_object = ::Mail.read_from_string(rfc822_data)
          successfully_parsed_mails << mail_object

          processed_info << { uid: uid, status: :parsed_successfully, message_id: mail_object.message_id }
          @processed_mail_count += 1
          @new_max_uid_this_run = uid.to_i if uid.to_i > @new_max_uid_this_run
          Rails.logger.info "[AliyunService PROCESS_UIDS] Successfully parsed mail for UID #{uid}, Message-ID: #{mail_object.message_id}"

        rescue StandardError => e_process
          Rails.logger.error "[AliyunService PROCESS_UIDS ERROR] Error parsing mail for UID #{uid}: #{e_process.class} - #{e_process.message}\nBacktrace: #{e_process.backtrace.join("\n")}"
          processed_info << { uid: uid, status: :error_parsing, error: e_process.message }
        end
      end

      Rails.logger.info "[AliyunService PROCESS_UIDS] Finished processing UIDs. Processed info: #{processed_info.inspect}. Returning #{successfully_parsed_mails.count} Mail::Message objects."
      successfully_parsed_mails
    end

    def update_channel_last_uid
      initial_uid_for_run = @current_max_uid
      highest_uid_this_run = @new_max_uid_this_run

      # 新增调试日志
      Rails.logger.error "!!!!!!!!!! [AliyunService DEBUG UPDATE_UID_START] initial_uid: #{initial_uid_for_run}, highest_uid_this_run: #{highest_uid_this_run} !!!!!!!!!!"

      Rails.logger.info "[AliyunService UPDATE_UID] Attempting to update UID. Initial for run: #{initial_uid_for_run}, Highest this run: #{highest_uid_this_run}, Channel ID: #{@channel.id}"

      if highest_uid_this_run.to_i > initial_uid_for_run.to_i # 确保比较的是整数
        Rails.logger.info "[AliyunService UPDATE_UID] Updating channel #{@channel.id} imap_last_uid from #{initial_uid_for_run} to #{highest_uid_this_run}"
        if @channel.update(imap_last_uid: highest_uid_this_run)
          Rails.logger.info "[AliyunService UPDATE_UID] Successfully updated imap_last_uid for channel #{@channel.id} to #{highest_uid_this_run}"
        else
          Rails.logger.error "[AliyunService UPDATE_UID] Failed to update imap_last_uid for channel #{@channel.id}. Errors: #{@channel.errors.full_messages.join(', ')}"
        end
      else
        Rails.logger.info "[AliyunService UPDATE_UID] No update needed for imap_last_uid. Current persisted (at start of run): #{initial_uid_for_run}, new_max_uid_this_run: #{highest_uid_this_run}. Channel ID: #{@channel.id}"
      end
    rescue StandardError => e
      Rails.logger.error "[AliyunService UPDATE_UID ERROR] Unexpected error during imap_last_uid update for channel #{@channel.id}: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
      # 为了调试，也记录一下当时的 UID 值
      Rails.logger.error "!!!!!!!!!! [AliyunService DEBUG UPDATE_UID_EXCEPTION_VALUES] initial_uid: #{initial_uid_for_run}, highest_uid_this_run: #{highest_uid_this_run} !!!!!!!!!!"
    end

    # --- Helper and Error Handling Methods ---
    private

    def ensure_imap_enabled?
      unless @channel.respond_to?(:imap_enabled?) && @channel.imap_enabled?
        Rails.logger.info "[AliyunService] IMAP is not enabled for channel #{@channel.id}"
        return false
      end
      true
    end

    def can_connect_to_imap?
      unless @channel.imap_enabled?
        Rails.logger.warn "[AliyunService CONNECT_CHECK] IMAP not enabled for Channel ID: #{@channel.id}, Inbox ID: #{@inbox.id}"
        return false
      end

      temp_imap = nil
      begin
        Rails.logger.info "[AliyunService CONNECT_CHECK] Attempting temporary connection to #{@channel.imap_address} for Channel ID: #{@channel.id}"
        temp_imap = Net::IMAP.new(@channel.imap_address, port: @channel.imap_port.to_i, ssl: ssl_options_for_channel)
        temp_imap.login(@channel.imap_login, @channel.imap_password)
        Rails.logger.info "[AliyunService CONNECT_CHECK] Temporary connection and authentication successful for Channel ID: #{@channel.id}"
        return true
      rescue Net::IMAP::NoResponseError, Net::IMAP::ByeResponseError, Net::IMAP::BadResponseError => e
        error_message = "[AliyunService CONNECT_CHECK ERROR] IMAP operational error for Channel ID: #{@channel.id}. Error: #{e.class} - #{e.message}"
        Rails.logger.error error_message
        if e.is_a?(Net::IMAP::BadResponseError) || (e.is_a?(Net::IMAP::NoResponseError) && e.message.match?(/AUTHENTICATIONFAILED/i))
          Rails.logger.warn "[AliyunService CONNECT_CHECK] Authentication failed for Channel ID: #{@channel.id}. Please check credentials or server IMAP settings for LOGIN command."
        end
        return false
      rescue SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Timeout::Error, OpenSSL::SSL::SSLError => e
        error_message = "[AliyunService CONNECT_CHECK ERROR] Network or SSL error for Channel ID: #{@channel.id}. Error: #{e.class} - #{e.message}"
        Rails.logger.error error_message
        return false
      rescue StandardError => e
        error_message = "[AliyunService CONNECT_CHECK ERROR] Unexpected error during connection check for Channel ID: #{@channel.id}. Error: #{e.class} - #{e.message}"
        Rails.logger.error error_message
        ::Sentry.capture_exception(e, extra: { channel_id: @channel.id, service: 'AliyunFetchEmailService', context: 'can_connect_to_imap_unexpected' }) if defined?(::Sentry)
        return false
      ensure
        if temp_imap
          begin
            temp_imap.logout
            temp_imap.disconnect
          rescue StandardError => e_disconnect
            Rails.logger.warn "[AliyunService CONNECT_CHECK] Error during temporary connection logout/disconnect: #{e_disconnect.message}"
          end
        end
      end
    end

    def connect_and_login_to_aliyun
      if @imap_connection && @imap_connection.respond_to?(:disconnected?) && !@imap_connection.disconnected?
        Rails.logger.info "[AliyunService CONNECT_PERSISTENT] Using existing active IMAP connection (checked via !disconnected?)."
        return true
      end

      begin
        Rails.logger.info "[AliyunService CONNECT_PERSISTENT] Attempting persistent connection to #{@channel.imap_address} for Channel ID: #{@channel.id}"
        @imap_connection = Net::IMAP.new(@channel.imap_address, port: @channel.imap_port.to_i, ssl: ssl_options_for_channel)
        @imap_connection.login(@channel.imap_login, @channel.imap_password)
        Rails.logger.info "[AliyunService CONNECT_PERSISTENT] Persistent connection and authentication successful for Channel ID: #{@channel.id}"
        return true
      rescue Net::IMAP::NoResponseError, Net::IMAP::ByeResponseError, Net::IMAP::BadResponseError => e
        error_message = "[AliyunService CONNECT_PERSISTENT ERROR] IMAP operational error for Channel ID: #{@channel.id}. Error: #{e.class} - #{e.message}"
        Rails.logger.error error_message
        if e.is_a?(Net::IMAP::BadResponseError) || (e.is_a?(Net::IMAP::NoResponseError) && e.message.match?(/AUTHENTICATIONFAILED/i))
          Rails.logger.warn "[AliyunService CONNECT_PERSISTENT] Authentication failed for Channel ID: #{@channel.id}. Please check credentials."
        end
        @imap_connection = nil
        return false
      rescue SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Timeout::Error, OpenSSL::SSL::SSLError => e
        error_message = "[AliyunService CONNECT_PERSISTENT ERROR] Network or SSL error for Channel ID: #{@channel.id}. Error: #{e.class} - #{e.message}"
        Rails.logger.error error_message
        @imap_connection = nil
        return false
      rescue StandardError => e
        error_message = "[AliyunService CONNECT_PERSISTENT ERROR] Unexpected error during persistent connection for Channel ID: #{@channel.id}. Error: #{e.class} - #{e.message}"
        Rails.logger.error error_message
        ::Sentry.capture_exception(e, extra: { channel_id: @channel.id, service: 'AliyunFetchEmailService', context: 'connect_and_login_to_aliyun_unexpected' }) if defined?(::Sentry)
        @imap_connection = nil
        return false
      end
    end

    def ssl_options_for_channel
      return false unless @channel.imap_enable_ssl
      true # Default: use SSL with default options. Can be { verify_mode: OpenSSL::SSL::VERIFY_NONE } if needed.
    end

    def select_mailbox(mailbox_name)
      @mailbox_selected = false # 重置状态
      @mailbox_uidnext = nil    # 重置状态

      # --- BEGIN DEBUG LOGGING ---
      if @imap_connection
        Rails.logger.info "[AliyunService SELECT_MAILBOX_DEBUG] @imap_connection object_id: #{@imap_connection.object_id}, class: #{@imap_connection.class}"
        if @imap_connection.respond_to?(:connected?)
          # Only call .connected? if it responds to it, to avoid error if method is missing
          is_connected_val = @imap_connection.connected?
          Rails.logger.info "[AliyunService SELECT_MAILBOX_DEBUG] @imap_connection.respond_to?(:connected?) is TRUE. @imap_connection.connected?: #{is_connected_val}"
        else
          Rails.logger.warn "[AliyunService SELECT_MAILBOX_DEBUG] @imap_connection.respond_to?(:connected?) is FALSE."
        end
        if @imap_connection.respond_to?(:disconnected?)
          is_disconnected_val = @imap_connection.disconnected?
          Rails.logger.info "[AliyunService SELECT_MAILBOX_DEBUG] @imap_connection.respond_to?(:disconnected?) is TRUE. @imap_connection.disconnected?: #{is_disconnected_val}"
        else
          Rails.logger.warn "[AliyunService SELECT_MAILBOX_DEBUG] @imap_connection.respond_to?(:disconnected?) is FALSE."
        end
      else
        Rails.logger.warn "[AliyunService SELECT_MAILBOX_DEBUG] @imap_connection is nil."
      end
      # --- END DEBUG LOGGING ---

      unless @imap_connection && @imap_connection.respond_to?(:disconnected?) && !@imap_connection.disconnected?
        Rails.logger.error "[AliyunService SELECT_MAILBOX] No active IMAP connection to select mailbox '#{mailbox_name}' (Checked via respond_to?(:disconnected?) and !disconnected?)."
        return false
      end

      begin
        Rails.logger.info "[AliyunService SELECT_MAILBOX] Attempting to select mailbox '#{mailbox_name}' for Channel ID: #{@channel.id}"
        response = @imap_connection.select(mailbox_name)
        if response # Net::IMAP#select returns a Net::IMAP::TaggedResponse on success
          Rails.logger.info "[AliyunService SELECT_MAILBOX] Successfully selected mailbox '#{mailbox_name}'."
          @mailbox_selected = true # 标记邮箱已选择

          # 获取 UIDNEXT 状态
          begin
            status = @imap_connection.status(mailbox_name, ["UIDNEXT"])
            if status && status["UIDNEXT"]
              @mailbox_uidnext = status["UIDNEXT"].to_i
              Rails.logger.info "[AliyunService SELECT_MAILBOX] Mailbox '#{mailbox_name}' status UIDNEXT: #{@mailbox_uidnext}"
            else
              Rails.logger.warn "[AliyunService SELECT_MAILBOX] Could not retrieve UIDNEXT for mailbox '#{mailbox_name}'."
            end
          rescue StandardError => e_status
            Rails.logger.error "[AliyunService SELECT_MAILBOX ERROR] Error fetching status for UIDNEXT: #{e_status.message}"
            # 即使获取 UIDNEXT 失败，select 本身是成功的，所以不改变 @mailbox_selected
          end
          return true
        else
          Rails.logger.error "[AliyunService SELECT_MAILBOX] Failed to select mailbox '#{mailbox_name}' (unexpected nil/false response from select)."
          return false
        end
      rescue Net::IMAP::NoResponseError, Net::IMAP::BadResponseError => e
        Rails.logger.error "[AliyunService SELECT_MAILBOX ERROR] Error selecting mailbox '#{mailbox_name}' for Channel ID: #{@channel.id}. Error: #{e.class} - #{e.message}"
        return false
      rescue StandardError => e
        Rails.logger.error "[AliyunService SELECT_MAILBOX ERROR] Unexpected error selecting mailbox '#{mailbox_name}' for Channel ID: #{@channel.id}. Error: #{e.class} - #{e.message}"
        ::Sentry.capture_exception(e, extra: { channel_id: @channel.id, mailbox: mailbox_name, service: 'AliyunFetchEmailService', context: 'select_mailbox_unexpected' }) if defined?(::Sentry)
        return false
      end
    end

    def log_email_processing_summary
      Rails.logger.info "[AliyunService SUMMARY] Finished email fetch for channel #{@channel.id}. Processed #{@processed_mail_count} emails. Last UID synced this run: #{@new_max_uid_this_run} (was #{@current_max_uid} at start)."
    end

    def final_check_channel_object
      missing_requirements = []
      missing_requirements << "channel object is nil" if @channel.nil?
      missing_requirements << "inbox object is nil" if @inbox.nil? && @channel # Check inbox only if channel exists

      if @channel
        [:imap_address, :imap_port, :imap_login, :imap_password, :imap_last_uid, :imap_enable_ssl, :imap_enabled?].each do |method_sym|
          missing_requirements << "channel does not respond to #{method_sym}" unless @channel.respond_to?(method_sym)
        end
      end

      unless missing_requirements.empty?
        error_message = "AliyunFetchEmailService: Channel object is not correctly initialized. Missing: #{missing_requirements.join(', ')}"
        Rails.logger.error "[AliyunService INIT FINAL-CHECK] CRITICAL: #{error_message}"
        # Log details for easier debugging
        Rails.logger.error "[AliyunService INIT FINAL-CHECK] Channel nil?: #{@channel.nil?}"
        Rails.logger.error "[AliyunService INIT FINAL-CHECK] Inbox nil?: #{@inbox.nil?}"
        if @channel
          Rails.logger.error "[AliyunService INIT FINAL-CHECK] Responds to imap_address?: #{@channel.respond_to?(:imap_address)}"
          Rails.logger.error "[AliyunService INIT FINAL-CHECK] Responds to imap_login?: #{@channel.respond_to?(:imap_login)}"
          # Add more checks if needed
        end
        raise ArgumentError, error_message
      end

      if @channel.respond_to?(:imap_last_uid) && @channel.imap_last_uid.present?
        @current_max_uid = @channel.imap_last_uid.to_i
      else
        @current_max_uid = 0 # Default if not present or not supported
      end
      Rails.logger.info "[AliyunService INIT FINAL-CHECK] Initialized with @current_max_uid: #{@current_max_uid} for Channel ID: #{@channel.id}"
    end

    # Placeholder for other error handlers if needed, adapt from your BaseFetchEmailService or specific needs
    def handle_imap_bye_error(exception)
      Rails.logger.error "[IMAP ALIYUN] IMAP BYE response for channel #{@channel.id}: #{exception.message}. Server may have disconnected."
    end

    def handle_ssl_error(exception)
      Rails.logger.error "[IMAP ALIYUN] SSL Error for channel #{@channel.id}: #{exception.message}"
    end

    def handle_imap_connection_error(exception)
      Rails.logger.error "[IMAP ALIYUN] IMAP Connection Error for channel #{@channel.id}: #{exception.class} - #{exception.message}"
    end

    def handle_generic_imap_error(exception)
      error_message = "[IMAP ALIYUN] Generic Error during email fetch for channel #{@channel.id}: #{exception.class} - #{exception.message}"
      Rails.logger.error "#{error_message}\n#{exception.backtrace.join("\n")}"
      ::Sentry.capture_exception(exception, extra: { channel_id: @channel.id, inbox_id: @inbox.id }) if defined?(::Sentry)
    end

    def log_summary
      Rails.logger.info "[AliyunService SUMMARY] Channel ID: #{@channel.id}, Processed Mails: #{@processed_mail_count}, Initial Max UID: #{@current_max_uid}, New Max UID This Run: #{@new_max_uid_this_run}"
      # 新增调试日志，看看 @new_max_uid_this_run 在这里的值
      Rails.logger.error "!!!!!!!!!! [AliyunService DEBUG LOG_SUMMARY] @new_max_uid_this_run is: #{@new_max_uid_this_run} !!!!!!!!!!"
    end
  end
end