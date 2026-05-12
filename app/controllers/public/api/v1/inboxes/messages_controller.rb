class Public::Api::V1::Inboxes::MessagesController < Public::Api::V1::InboxesController
  before_action :set_message, only: [:update, :destroy]

  def index
    @messages = @conversation.nil? ? [] : message_finder.perform
  end

  def create
    @message = @conversation.messages.new(message_params)
    build_attachment
    @message.save!
    
    # Broadcast to both token and account streams to ensure delivery
    tokens = (@message.conversation.inbox.members.pluck(:pubsub_token) + [@message.conversation.contact_inbox.pubsub_token]).compact.uniq
    if tokens.present?
      Rails.logger.info "[Chatwoot:Broadcast] Sending to tokens and account_#{@message.account_id}"
      ::ActionCableBroadcastJob.perform_now(tokens, 'message_created', @message.push_event_data.merge(account_id: @message.account_id))
      ActionCable.server.broadcast("account_#{@message.account_id}", { event: 'message_created', data: @message.push_event_data.merge(account_id: @message.account_id) })
    end
  end

  def update
    render json: { error: 'You cannot update the CSAT survey after 14 days' }, status: :unprocessable_entity and return if check_csat_locked

    updated_attributes = {}
    
    if message_update_params.present?
      if message_update_params[:content].present? && @message.sender == @contact
        updated_attributes[:content] = message_update_params[:content]
      end

      if message_update_params[:content_attributes].present?
        updated_attributes[:content_attributes] = @message.content_attributes.merge(message_update_params[:content_attributes].to_h)
      end

      if message_update_params[:submitted_values].present?
        updated_attributes[:submitted_values] = message_update_params[:submitted_values]
      end
    end

    @message.update!(updated_attributes) if updated_attributes.present?
    
    tokens = (@message.conversation.inbox.members.pluck(:pubsub_token) + [@message.conversation.contact_inbox.pubsub_token]).compact.uniq
    if tokens.present?
      Rails.logger.info "[Chatwoot:Broadcast] Sending message_updated (update) to tokens and account_#{@message.account_id}"
      ::ActionCableBroadcastJob.perform_now(tokens, 'message_updated', @message.push_event_data.merge(account_id: @message.account_id))
      ActionCable.server.broadcast("account_#{@message.account_id}", { event: 'message_updated', data: @message.push_event_data.merge(account_id: @message.account_id) })
    end

    render json: @message
  rescue StandardError => e
    render json: { error: @contact.errors, message: e.message }.to_json, status: :internal_server_error
  end

  def destroy
    if @message.sender == @contact
      ActiveRecord::Base.transaction do
        @message.update!(content: I18n.t('conversations.messages.deleted'), content_type: :text, content_attributes: { deleted: true })
        @message.attachments.destroy_all
      end
      head :ok
    else
      render json: { error: 'Unauthorized' }, status: :unauthorized
    end
  end

  def read
    message_ids = Array(params[:message_ids].presence || (params[:id].present? ? [params[:id]] : [])).map(&:to_i)
    Rails.logger.info "[Chatwoot:Public:Read] Conv: #{@conversation.display_id} (ID: #{@conversation.id}), Message IDs: #{message_ids}"
    
    messages = @conversation.messages.where(id: message_ids).where.not(status: 'read')
    Rails.logger.info "[Chatwoot:Public:Read] Found #{messages.count} messages to update"

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

  private

  def build_attachment
    return if params[:attachments].blank?

    params[:attachments].each do |uploaded_attachment|
      @message.attachments.new(
        account_id: @message.account_id,
        file_type: helpers.file_type(uploaded_attachment&.content_type),
        file: uploaded_attachment
      )
    end
  end

  def message_finder_params
    {
      filter_internal_messages: true,
      before: params[:before]
    }
  end

  def message_finder
    @message_finder ||= MessageFinder.new(@conversation, message_finder_params)
  end

  def message_update_params
    params.permit(:content, { content_attributes: {} }, submitted_values: [:name, :title, :value, { csat_survey_response: [:feedback_message, :rating] }])
  end

  def permitted_params
    params.permit(:content, :echo_id)
  end

  def set_message
    @message = @conversation.messages.find(params[:id])
  end

  def message_params
    {
      account_id: @conversation.account_id,
      sender: @contact_inbox.contact,
      content: permitted_params[:content],
      inbox_id: @conversation.inbox_id,
      echo_id: permitted_params[:echo_id],
      message_type: :incoming
    }
  end

  def check_csat_locked
    (Time.zone.now.to_date - @message.created_at.to_date).to_i > 14 and @message.content_type == 'input_csat'
  end
end
