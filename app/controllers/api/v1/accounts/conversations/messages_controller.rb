class Api::V1::Accounts::Conversations::MessagesController < Api::V1::Accounts::Conversations::BaseController

  def index
    @messages = message_finder.perform
  end

  def create
    user = Current.user || @resource
    mb = Messages::MessageBuilder.new(user, @conversation, params)
    @message = mb.perform
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def update
    updated_attributes = {}
    
    if permitted_params[:content].present? && message.sender == Current.user
      updated_attributes[:content] = permitted_params[:content]
    end

    if permitted_params[:content_attributes].present?
      updated_attributes[:content_attributes] = message.content_attributes.merge(permitted_params[:content_attributes].to_h)
    end

    message.update!(updated_attributes) if updated_attributes.present?

    if permitted_params[:status].present? && @conversation.inbox.api?
      Messages::StatusUpdateService.new(message, permitted_params[:status], permitted_params[:external_error]).perform
    end

    @message = message

    tokens = (@message.conversation.inbox.members.pluck(:pubsub_token) + [@message.conversation.contact_inbox.pubsub_token]).compact.uniq
    if tokens.present?
      Rails.logger.info "[Chatwoot:Broadcast] Sending message_updated (manager update) to tokens and account_#{@message.account_id}"
      ::ActionCableBroadcastJob.perform_now(tokens, 'message_updated', @message.push_event_data.merge(account_id: @message.account_id))
      ActionCable.server.broadcast("account_#{@message.account_id}", { event: 'message_updated', data: @message.push_event_data.merge(account_id: @message.account_id) })
    end
  end

  def read
    message_ids = Array(params[:message_ids].presence || (params[:id].present? ? [params[:id]] : [])).map(&:to_i)
    Rails.logger.info "[Chatwoot:Read] Conv: #{@conversation.display_id} (ID: #{@conversation.id}), Message IDs: #{message_ids}"
    
    messages = @conversation.messages.where(id: message_ids).where.not(status: 'read')
    Rails.logger.info "[Chatwoot:Read] Found #{messages.count} messages to update"

    messages.each do |msg|
      Messages::StatusUpdateService.new(msg, 'read').perform
      
      tokens = (msg.conversation.inbox.members.pluck(:pubsub_token) + [msg.conversation.contact_inbox.pubsub_token]).compact.uniq
      if tokens.present?
        Rails.logger.info "[Chatwoot:Broadcast] Sending to tokens and account_#{msg.account_id}"
        ::ActionCableBroadcastJob.perform_now(tokens, 'message_updated', msg.push_event_data.merge(account_id: msg.account_id))
        ActionCable.server.broadcast("account_#{msg.account_id}", { event: 'message_updated', data: msg.push_event_data.merge(account_id: msg.account_id) })
      end
    end
    @messages = @conversation.messages.where(id: message_ids)
    render json: @messages
  end

  def destroy
    ActiveRecord::Base.transaction do
      message.update!(content: I18n.t('conversations.messages.deleted'), content_type: :text, content_attributes: { deleted: true })
      message.attachments.destroy_all
    end
  end

  def retry
    return if message.blank?

    service = Messages::StatusUpdateService.new(message, 'sent')
    service.perform
    message.update!(content_attributes: {})
    ::SendReplyJob.perform_later(message.id)
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def translate
    return head :ok if already_translated_content_available?

    translated_content = Integrations::GoogleTranslate::ProcessorService.new(
      message: message,
      target_language: permitted_params[:target_language]
    ).perform

    if translated_content.present?
      translations = {}
      translations[permitted_params[:target_language]] = translated_content
      translations = message.translations.merge!(translations) if message.translations.present?
      message.update!(translations: translations)
    end

    render json: { content: translated_content }
  end

  private

  def message
    @message ||= @conversation.messages.find(permitted_params[:id])
  end

  def message_finder
    @message_finder ||= MessageFinder.new(@conversation, params)
  end

  def permitted_params
    params.permit(:id, :target_language, :status, :external_error, :content, content_attributes: {})
  end

  def already_translated_content_available?
    message.translations.present? && message.translations[permitted_params[:target_language]].present?
  end
end
