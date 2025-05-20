class AddImapLastUidToChannelEmail < ActiveRecord::Migration[7.0]
  def change
    add_column :channel_email, :imap_last_uid, :string
  end
end
