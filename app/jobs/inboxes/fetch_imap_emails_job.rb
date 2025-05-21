require 'net/imap'

class Inboxes::FetchImapEmailsJob < MutexApplicationJob
  queue_as :scheduled_jobs

  def perform(channel, interval = 1)
    return unless should_fetch_email?(channel)

    key = format(::Redis::Alfred::EMAIL_MESSAGE_MUTEX, inbox_id: channel.inbox.id)

    original_debug_status = Net::IMAP.debug # 保存原始的调试状态
    Net::IMAP.debug = true                  # 启用 IMAP 调试模式
    Rails.logger.info "[IMAP VERSION CHECK] Loaded Net::IMAP version: #{Net::IMAP::VERSION}"
    Rails.logger.info "[IMAP DEBUG] IMAP debugging enabled for Inbox ID: #{channel.inbox.id}, Channel ID: #{channel.id}"

    begin
      with_lock(key, 5.minutes) do
        process_email_for_channel(channel, interval)
      end
    rescue *ExceptionList::IMAP_EXCEPTIONS => e
      Rails.logger.error "Authorization error for email channel - #{channel.inbox.id} : #{e.message}"
    rescue EOFError, OpenSSL::SSL::SSLError, Net::IMAP::NoResponseError, Net::IMAP::BadResponseError, Net::IMAP::InvalidResponseError => e
      Rails.logger.error "Error for email channel - #{channel.inbox.id} : #{e.message}"
    rescue LockAcquisitionError
      Rails.logger.error "Lock failed for #{channel.inbox.id}"
    rescue StandardError => e
      ChatwootExceptionTracker.new(e, account: channel.account).capture_exception
    ensure
      Net::IMAP.debug = original_debug_status # 恢复原始的调试状态
      Rails.logger.info "[IMAP DEBUG] IMAP debugging restored to original status (#{original_debug_status}) for Inbox ID: #{channel.inbox.id}, Channel ID: #{channel.id}"
    end
  end

  private

  def should_fetch_email?(channel)
    channel.imap_enabled? && !channel.reauthorization_required?
  end

  def process_email_for_channel(channel, interval)
    # 添加详细日志来调试路由条件
    Rails.logger.info "[IMAP ROUTE CHECK] Channel ID: #{channel.id}, Provider: #{channel.try(:provider)}"
    # 检查 channel.credentials 是否有内容，以及直接访问器是否返回值
    Rails.logger.info "[IMAP ROUTE CHECK] channel.credentials: #{channel.try(:credentials).inspect}"
    direct_imap_address = channel.try(:imap_address) # 直接调用访问器
    Rails.logger.info "[IMAP ROUTE CHECK] channel.imap_address (direct): #{direct_imap_address.inspect}"

    is_aliyun_host = direct_imap_address&.downcase == 'imap.qiye.aliyun.com'
    Rails.logger.info "[IMAP ROUTE CHECK] is_aliyun_host based on direct imap_address: #{is_aliyun_host}"

    inbound_emails = if channel.microsoft?
                       Imap::MicrosoftFetchEmailService.new(channel: channel, interval: interval).perform
                     elsif channel.google?
                       Imap::GoogleFetchEmailService.new(channel: channel, interval: interval).perform
                     elsif is_aliyun_host # 使用上面计算的布尔值
                       Rails.logger.info "[IMAP ROUTING] Routing to AliyunFetchEmailService for channel ID: #{channel.id}, Host: #{direct_imap_address}"
                       Imap::AliyunFetchEmailService.new(channel: channel).perform
                     else
                       Rails.logger.info "[IMAP ROUTING] Routing to default FetchEmailService for channel ID: #{channel.id}. Host: #{direct_imap_address.inspect}"
                       Imap::FetchEmailService.new(channel: channel, interval: interval).perform
                     end
    inbound_emails.map do |inbound_mail|
      process_mail(inbound_mail, channel)
    end
  rescue OAuth2::Error => e
    Rails.logger.error "Error for email channel - #{channel.inbox.id} : #{e.message}"
    channel.authorization_error!
  end

  def process_mail(inbound_mail, channel)
    Imap::ImapMailbox.new.process(inbound_mail, channel)
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: channel.account).capture_exception
    Rails.logger.error("
      #{channel.provider} Email dropped: #{inbound_mail.from} and message_source_id: #{inbound_mail.message_id}")
  end
end
