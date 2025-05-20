# frozen_string_literal: true

module Imap
  # This service is a specialized version for Aliyun Enterprise Email,
  # primarily to force the use of the IMAP LOGIN command.
  #
  # !!! IMPORTANT !!!
  # This file is a TEMPLATE. You MUST:
  # 1. COPY the entire content of your existing `app/services/imap/fetch_email_service.rb` into this file.
  # 2. RENAME the class from `FetchEmailService` to `AliyunFetchEmailService`.
  # 3. CAREFULLY MERGE the Aliyun-specific login logic (mainly `connect_and_login_to_aliyun`
  #    and the usage of `@imap_connection` as a direct Net::IMAP instance)
  #    into the copied code, ensuring all other functionalities (email fetching,
  #    processing, error handling, etc.) from your original service are preserved and adapted.
  #
  class AliyunFetchEmailService < ::Imap::BaseFetchEmailService # Adjust base class if different or non-existent in your project
    attr_reader :channel, :interval, :inbox, :imap_connection, :processed_mail_count, :current_max_uid

    # Standard initialize method.
    def initialize(channel:, interval: nil)
      # 将 channel 和 interval 都传递给 BaseFetchEmailService 的 initialize 方法
      # BaseFetchEmailService 中的 pattr_initialize [:channel!, :interval] 意味着
      # 其 initialize 方法期望这两个参数。
      super(channel: channel, interval: interval)

      # 执行 super(...) 后, @channel 和 @interval 实例变量已经被父类设置。
      # 如果阿里云服务需要一个特定的默认 interval 值 (例如，如果父类将其设置为 nil，
      # 而阿里云服务总是需要至少为 1), 我们可以在这里调整。
      @interval ||= 1 # 确保 @interval 在父类设置后，如果为 nil，则默认为 1

      # @channel 已由父类设置。
      # @inbox 可以从 @channel派生。
      @inbox = @channel.inbox

      @processed_mail_count = 0
      # @current_max_uid 将在 final_check_channel_object 中初始化

      # 阿里云特定的初始化日志
      Rails.logger.info "[AliyunService INIT ATTR-POST] @channel class: #{@channel.class}, ID: #{@channel.id}"
      Rails.logger.info "[AliyunService INIT ATTR-POST] @interval (after super and default): #{@interval}" # 记录最终的 interval 值
      Rails.logger.info "[AliyunService INIT ATTR-POST] @channel responds to imap_address?: #{@channel.respond_to?(:imap_address)}"
      Rails.logger.info "[AliyunService INIT ATTR-POST] @channel responds to email?: #{@channel.respond_to?(:email)}"
      Rails.logger.info "[AliyunService INIT ATTR-POST] @channel responds to imap_password?: #{@channel.respond_to?(:imap_password)}"
      Rails.logger.info "[AliyunService INIT ATTR-POST] @channel responds to imap_last_uid?: #{@channel.respond_to?(:imap_last_uid)}"
      Rails.logger.info "[AliyunService INIT ATTR-POST] @inbox class: #{@inbox.class}, ID: #{@inbox.id}" if @inbox

      final_check_channel_object # 此方法检查必要属性并设置 @current_max_uid

      @imap_connection = nil
    end

    # The main perform method. COPY AND ADAPT its structure from your FetchEmailService.
    # The key difference will be how `@imap_connection` is established and used.
    def perform
      Rails.logger.info "[AliyunService PERFORM START] Attempting to fetch emails for Channel ID: #{@channel.id}, Inbox ID: #{@inbox.id}"
      @processed_mail_count = 0
      @new_max_uid_this_run = @current_max_uid # Initialize with current_max_uid

      Rails.logger.info "[AliyunService INIT] Channel ID: #{@channel.id} responds to imap_last_uid. Value: \"#{@channel.imap_last_uid}\", Parsed @current_max_uid: #{@current_max_uid}"

      unless ensure_imap_enabled? && can_connect_to_imap?
        Rails.logger.warn "[AliyunService PERFORM] IMAP not enabled or cannot connect for Channel ID: #{@channel.id}. Aborting."
        return []
      end

      connect_and_login
      select_inbox

      new_uids = fetch_new_email_uids
      if new_uids.empty?
        Rails.logger.info "[AliyunService PERFORM] No new UIDs to process for Channel ID: #{@channel.id}."
        # 修改日志文本以反映返回类型
        Rails.logger.info "[AliyunService PERFORM END] Processed #{@processed_mail_count} emails for Channel ID: #{@channel.id}. New max UID for run: #{@new_max_uid_this_run}. Returning 0 Mail::Message objects."
        return []
      end

      Rails.logger.info "[AliyunService PERFORM] Found #{new_uids.count} new UIDs to process: #{new_uids.inspect} for Channel ID: #{@channel.id}."
      # 修改：现在期望 process_email_uids 返回 Mail::Message 对象数组
      mail_messages = process_email_uids(new_uids)

      # 修改日志文本以反映返回类型
      Rails.logger.info "[AliyunService PERFORM END] Processed #{@processed_mail_count} emails for Channel ID: #{@channel.id}. New max UID for run: #{@new_max_uid_this_run}. Returning #{mail_messages.count} Mail::Message objects."
      mail_messages
    rescue Net::IMAP::NoResponseError, Net::IMAP::ByeResponseError, SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, OpenSSL::SSL::SSLError => e
      Rails.logger.error "[AliyunService PERFORM ERROR] IMAP connection/command error for Channel ID #{@channel.id}: #{e.class} - #{e.message}"
      @channel.authorization_error! if @channel.respond_to?(:authorization_error!)
      return []
    rescue StandardError => e
      Rails.logger.error "[AliyunService PERFORM ERROR] Unexpected error for Channel ID #{@channel.id}: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}"
      @channel.authorization_error! if @channel.respond_to?(:authorization_error!)
      return []
    ensure
      disconnect_from_aliyun
      Rails.logger.info "[AliyunService PERFORM ENSURE] Ensure block executed for Channel ID: #{@channel.id}."
    end

    private

    # --- Helper for combined connection and inbox selection ---
    def connect_and_select_inbox
      Rails.logger.info "[AliyunService CONNECT_SELECT_INBOX] Attempting to connect and select inbox for Channel ID: #{@channel.id}"
      connect_and_login_to_aliyun # This method logs and raises on failure
      select_inbox_folder         # This method logs and raises on failure
      Rails.logger.info "[AliyunService CONNECT_SELECT_INBOX] Successfully connected and selected inbox for Channel ID: #{@channel.id}"
      true # Indicates success
    rescue StandardError => e
      # The individual methods (connect_and_login_to_aliyun, select_inbox_folder)
      # already log their specific errors before raising them.
      # We log a general failure message here for the combined operation.
      Rails.logger.error "[AliyunService CONNECT_SELECT_INBOX_ERROR] Failed during connect/select for Channel ID #{@channel.id}: #{e.class} - #{e.message}"

      # Attempt to disconnect if connection might have been established before the error.
      disconnect_from_aliyun

      # Signal failure to the perform method, so it can return early.
      # The perform method's main rescue blocks will not be hit for this specific failure path
      # because we are returning false, and perform will exit via "return unless connect_and_select_inbox".
      false
    end

    # --- Connection and Login (Aliyun Specific) ---
    def connect_and_login_to_aliyun
      # 使用 @channel.email 作为 IMAP 登录名
      imap_user = @channel.email
      imap_pass = @channel.imap_password # 假设密码字段是 imap_password

      Rails.logger.info "[AliyunService CONNECT] Connecting to Aliyun IMAP: #{@channel.imap_address}:#{@channel.imap_port.to_i}, SSL: #{@channel.imap_enable_ssl}"
      @imap_connection = Net::IMAP.new(@channel.imap_address, port: @channel.imap_port.to_i, ssl: @channel.imap_enable_ssl)
      Rails.logger.info "[AliyunService CONNECT] Connection established. Attempting login for user: #{imap_user}"
      # 注意：Net::IMAP#login 通常期望的是用户名和密码，而不是整个 channel 对象
      @imap_connection.login(imap_user, imap_pass)
      Rails.logger.info "[AliyunService CONNECT] Login successful for user: #{imap_user}"
    rescue Net::IMAP::NoResponseError => e
      Rails.logger.error "[AliyunService CONNECT ERROR] Login failed for #{imap_user}: #{e.message}. Check credentials or IMAP settings."
      raise
    rescue StandardError => e
      Rails.logger.error "[AliyunService CONNECT ERROR] Unexpected error during connect/login for #{imap_user}: #{e.class} - #{e.message}"
      raise
    end

    def disconnect_from_aliyun
      if @imap_connection && !@imap_connection.disconnected?
        Rails.logger.info "[AliyunService DISCONNECT] Logging out and disconnecting from Aliyun IMAP."
        @imap_connection.logout
        @imap_connection.disconnect
        Rails.logger.info "[AliyunService DISCONNECT] Disconnected."
      else
        Rails.logger.info "[AliyunService DISCONNECT] No active IMAP connection to disconnect or already disconnected."
      end
    rescue Net::IMAP::NoResponseError, StandardError => e
      Rails.logger.warn "[AliyunService DISCONNECT WARN] Error during IMAP logout/disconnect: #{e.class} - #{e.message}"
    ensure
      @imap_connection = nil
    end

    # --- IMAP Operations (Must use @imap_connection directly) ---
    # COPY AND ADAPT the following methods from your FetchEmailService.
    # Ensure they use `@imap_connection.select`, `@imap_connection.uid_search`, etc.

    def select_inbox_folder
      target_folder = 'INBOX'
      Rails.logger.info "[AliyunService SELECT_INBOX] Selecting IMAP folder: #{target_folder}."
      response = @imap_connection.select(target_folder)
      Rails.logger.info "[AliyunService SELECT_INBOX] Folder #{target_folder} selected. Response: #{response.inspect}"
    rescue Net::IMAP::NoResponseError => e
      Rails.logger.error "[AliyunService SELECT_INBOX ERROR] Could not select folder #{target_folder}: #{e.message}"
      raise
    rescue StandardError => e
      Rails.logger.error "[AliyunService SELECT_INBOX ERROR] Unexpected error selecting folder #{target_folder}: #{e.class} - #{e.message}"
      raise
    end

    def fetch_new_email_uids(limit_for_test: nil)
      uid_range_string = "#{@current_max_uid + 1}:*"
      search_keys_range = [uid_range_string]
      uids_found = []

      Rails.logger.info "[AliyunService FETCH_UIDS] Attempting UID SEARCH with range keys: #{search_keys_range.inspect}"
      begin
        uids_found = @imap_connection.uid_search(search_keys_range)
        if uids_found.nil?
          Rails.logger.warn "[AliyunService FETCH_UIDS] UID_SEARCH with range '#{search_keys_range.inspect}' returned nil. Assuming no new emails."
          uids_found = [] # Ensure it's an array
        else
          Rails.logger.info "[AliyunService FETCH_UIDS] UID_SEARCH with range '#{search_keys_range.inspect}' found #{uids_found.count} UIDs: #{uids_found.inspect}"
        end
      rescue Net::IMAP::BadResponseError => e
        Rails.logger.warn "[AliyunService FETCH_UIDS WARN] UID_SEARCH with range '#{search_keys_range.inspect}' failed: #{e.message}. Falling back to UID SEARCH ALL."

        begin
          search_keys_all = ['ALL']
          Rails.logger.info "[AliyunService FETCH_UIDS] Attempting UID SEARCH with keys: #{search_keys_all.inspect} as fallback."
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
      # 修改：现在收集 Mail::Message 对象
      successfully_parsed_mails = []
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
        internal_date_str = fetch_data_array[0].attr['INTERNALDATE'] # 保留以备将来使用或记录

        if rfc822_data.blank?
          Rails.logger.warn "[AliyunService PROCESS_UIDS] RFC822 data is blank for UID: #{uid}."
          processed_info << { uid: uid, status: :blank_rfc822, error: "RFC822 data is blank" }
          next
        end

        Rails.logger.info "[AliyunService PROCESS_UIDS] Successfully fetched RFC822 (length: #{rfc822_data.length}) and INTERNALDATE ('#{internal_date_str}') for UID: #{uid}"

        begin
          mail_object = ::Mail.read_from_string(rfc822_data)

          # 移除了 @inbox.is_a?(::Inbox) 检查，因为我们不再直接创建依赖 @inbox 的记录
          # 移除了 source_id 和重复检查逻辑，这些应该由 FetchImapEmailsJob 的 process_mail 处理

          # 修改：不再创建 InboundEmail，而是收集 mail_object
          successfully_parsed_mails << mail_object

          # 更新 processed_info 和计数器
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
      # 修改：返回 Mail::Message 对象数组
      successfully_parsed_mails
    end

    def update_channel_last_uid
      # Check if the channel object can persist imap_last_uid
      can_persist_uid = @channel.respond_to?(:imap_last_uid=) && @channel.respond_to?(:imap_last_uid)

      if can_persist_uid
        current_persisted_uid = @channel.imap_last_uid.to_i
        if @new_max_uid_this_run > current_persisted_uid
          Rails.logger.info "[AliyunService UPDATE_UID] Attempting to update imap_last_uid for channel #{@channel.id} from #{current_persisted_uid} to #{@new_max_uid_this_run}"
          if @channel.update(imap_last_uid: @new_max_uid_this_run.to_s)
             Rails.logger.info "[AliyunService UPDATE_UID] Successfully updated imap_last_uid for channel #{@channel.id} to #{@new_max_uid_this_run}"
          else
             Rails.logger.error "[AliyunService UPDATE_UID] Failed to update imap_last_uid for channel #{@channel.id}. Errors: #{@channel.errors.full_messages.join(', ')}"
          end
        else
          Rails.logger.info "[AliyunService UPDATE_UID] No new highest UID to update for channel #{@channel.id}. Current persisted: #{current_persisted_uid}, Max fetched this run: #{@new_max_uid_this_run}"
        end
      else
        Rails.logger.warn "[AliyunService UPDATE_UID WARN] Channel #{@channel.id} does not support persisting imap_last_uid (missing imap_last_uid= or imap_last_uid method). UID will not be saved."
      end
    end

    # --- Helper and Error Handling Methods ---
    # COPY AND ADAPT ALL relevant helper and error handling methods from your
    # FetchEmailService and/or its BaseFetchEmailService.
    # Ensure they are compatible with the changes made (e.g., direct Net::IMAP usage).

    def ensure_imap_enabled?
      unless @channel.respond_to?(:imap_enabled?) && @channel.imap_enabled?
        Rails.logger.info "[AliyunService] IMAP is not enabled for channel #{@channel.id}"
        return false
      end
      true
    end

    def can_connect_to_imap?
      # 确保通道已启用 IMAP
      unless @channel.imap_enabled?
        Rails.logger.warn "[AliyunService CONNECT_CHECK] IMAP not enabled for Channel ID: #{@channel.id}, Inbox ID: #{@inbox.id}"
        return false
      end

      # 移除了对 @inbox.imap_reauthorization_needed? 的检查，因为它不适用于阿里云的密码认证
      # 并且导致了 NoMethodError

      # 尝试连接以验证凭据和服务器可达性
      # 注意：这里只是为了检查是否能连接，实际的持久连接在 connect_and_login 中建立
      temp_imap = nil
      begin
        Rails.logger.info "[AliyunService CONNECT_CHECK] Attempting temporary connection to #{@channel.imap_address} for Channel ID: #{@channel.id}"
        temp_imap = Net::IMAP.new(@channel.imap_address, port: @channel.imap_port, ssl: ssl_options_for_channel)
        temp_imap.authenticate('LOGIN', @channel.imap_login, @channel.imap_password) # 使用 LOGIN，因为阿里云通常是这个
        Rails.logger.info "[AliyunService CONNECT_CHECK] Temporary connection and authentication successful for Channel ID: #{@channel.id}"
        return true
      rescue Net::IMAP::NoResponseError, Net::IMAP::ByeResponseError, Net::IMAP::BadResponseError, SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, OpenSSL::SSL::SSLError => e
        error_message = "[AliyunService CONNECT_CHECK ERROR] Failed to connect/authenticate to IMAP server for Channel ID: #{@channel.id}. Error: #{e.class} - #{e.message}"
        Rails.logger.error error_message
        # 可以考虑根据错误类型决定是否需要通知或禁用渠道
        # 例如，对于认证失败，可以记录特定信息
        if e.is_a?(Net::IMAP::NoResponseError) && e.message.match(/AUTHENTICATIONFAILED/i)
          Rails.logger.warn "[AliyunService CONNECT_CHECK] Authentication failed for Channel ID: #{@channel.id}. Please check credentials."
          # 根据您的业务逻辑，这里可以设置一个标记，提示用户检查凭证
          # @channel.auth_error_notified_at = Time.now unless @channel.auth_error_notified_at? # 示例
        end
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

    def check_imap_reauthorization_status
      # Example: (Adapt from your original service)
      # This might be called after a login failure.
      if @inbox.imap_consecutive_auth_errors >= ::Channel::ImapChannel::MAX_CONSECUTIVE_AUTH_ERRORS_BEFORE_REAUTH_FLAG
        @inbox.set_imap_reauthorization_needed! # Ensure this method exists on your channel/inbox model
        Rails.logger.warn "[IMAP ALIYUN] Inbox #{@inbox.id} marked as needing IMAP reauthorization due to consecutive auth errors."
      end
    end

    def handle_imap_bye_error(exception)
      # Example: (Adapt from your original service)
      Rails.logger.error "[IMAP ALIYUN] IMAP BYE response for channel #{@channel.id}: #{exception.message}. Server may have disconnected."
      # Consider incrementing a specific error counter or notifying.
    end

    def handle_ssl_error(exception)
      # Example: (Adapt from your original service)
      Rails.logger.error "[IMAP ALIYUN] SSL Error for channel #{@channel.id}: #{exception.message}"
      # Mark channel as having an error, potentially notify admin.
      # @channel.set_imap_error_status!('SSL Error') # Example
    end

    def handle_imap_connection_error(exception)
      # Example: (Adapt from your original service)
      Rails.logger.error "[IMAP ALIYUN] IMAP Connection Error for channel #{@channel.id}: #{exception.class} - #{exception.message}"
      # Mark channel as having an error.
      # @channel.set_imap_error_status!('Connection Error') # Example
    end

    def handle_generic_imap_error(exception)
      # Example: (Adapt from your original service)
      error_message = "[IMAP ALIYUN] Generic Error during email fetch for channel #{@channel.id}: #{exception.class} - #{exception.message}"
      Rails.logger.error "#{error_message}\n#{exception.backtrace.join("\n")}"
      Sentry.capture_exception(exception, extra: { channel_id: @channel.id, inbox_id: @inbox.id }) if defined?(Sentry)
      # @channel.set_imap_error_status!('Generic Error') # Example
    end

    def log_email_processing_summary
      # Example: (Adapt from your original service)
      Rails.logger.info "[IMAP ALIYUN] Finished email fetch for channel #{@channel.id}. Processed #{@processed_mail_count} emails. Last UID synced: #{@current_max_uid}."
    end

    # Add any other private/protected helper methods from your original FetchEmailService here,
    # ensuring they are adapted to use `@imap_connection` (Net::IMAP instance) correctly.
    # For example, methods for:
    # - Parsing email content (`create_inbound_mail_from_source`)
    # - Handling attachments
    # - Checking processing time limits
    # - Specific logging or notification logic

    def final_check_channel_object
      missing_requirements = []
      missing_requirements << "channel object is nil" if @channel.nil?
      missing_requirements << "inbox object is nil" if @inbox.nil?

      if @channel
        missing_requirements << "channel does not respond to imap_address" unless @channel.respond_to?(:imap_address)
        missing_requirements << "channel does not respond to email (for IMAP username)" unless @channel.respond_to?(:email)
        missing_requirements << "channel does not respond to imap_password" unless @channel.respond_to?(:imap_password)
        missing_requirements << "channel does not respond to imap_last_uid" unless @channel.respond_to?(:imap_last_uid)
      end

      unless missing_requirements.empty?
        error_message = "AliyunFetchEmailService: Channel object is not correctly initialized. Missing: #{missing_requirements.join(', ')}"
        Rails.logger.error "[AliyunService INIT FINAL-CHECK] CRITICAL: #{error_message}"
        Rails.logger.error "[AliyunService INIT FINAL-CHECK] Channel nil?: #{@channel.nil?}"
        Rails.logger.error "[AliyunService INIT FINAL-CHECK] Inbox nil?: #{@inbox.nil?}"
        if @channel
          Rails.logger.error "[AliyunService INIT FINAL-CHECK] Responds to imap_address?: #{@channel.respond_to?(:imap_address)}"
          Rails.logger.error "[AliyunService INIT FINAL-CHECK] Responds to email?: #{@channel.respond_to?(:email)}"
          Rails.logger.error "[AliyunService INIT FINAL-CHECK] Responds to imap_password?: #{@channel.respond_to?(:imap_password)}"
          Rails.logger.error "[AliyunService INIT FINAL-CHECK] Responds to imap_last_uid?: #{@channel.respond_to?(:imap_last_uid)}"
        end
        raise ArgumentError, error_message
      end

      if @channel.respond_to?(:imap_last_uid) && @channel.imap_last_uid.present?
        @current_max_uid = @channel.imap_last_uid.to_i
        Rails.logger.info "[AliyunService INIT] Channel ID: #{@channel.id} responds to imap_last_uid. Value: \"#{@channel.imap_last_uid}\", Parsed @current_max_uid: #{@current_max_uid}"
      else
        @current_max_uid = 0
        Rails.logger.info "[AliyunService INIT] Channel ID: #{@channel.id} does NOT respond to imap_last_uid or it's blank. Defaulting @current_max_uid to 0."
      end
    end

  end
end