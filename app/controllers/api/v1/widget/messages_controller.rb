class Api::V1::Widget::MessagesController < Api::V1::Widget::BaseController
  before_action :set_conversation, only: [:create]
  before_action :set_message, only: [:update, :destroy]

  def index
    @messages = conversation.nil? ? [] : message_finder.perform
  end

  def create
    @message = conversation.messages.new(message_params)
    build_attachment
    @message.save!
  end

  def update
    if @message.content_type == 'input_email'
      @message.update!(submitted_email: contact_email)
      ContactIdentifyAction.new(
        contact: @contact,
        params: { email: contact_email, name: contact_name },
        retain_original_contact_name: true
      ).perform
    else
      updated_attributes = {}
      
      if message_update_params[:message].present?
        if message_update_params[:message][:content].present? && @message.sender == @contact
          updated_attributes[:content] = message_update_params[:message][:content]
        end

        if message_update_params[:message][:content_attributes].present?
          updated_attributes[:content_attributes] = @message.content_attributes.merge(message_update_params[:message][:content_attributes].to_h)
        end

        if message_update_params[:message][:submitted_values].present?
          updated_attributes[:submitted_values] = message_update_params[:message][:submitted_values]
        end
      end

      @message.update!(updated_attributes) if updated_attributes.present?
    end
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
    message_ids = params[:message_ids].presence || (params[:id].present? ? [params[:id]] : [])
    messages = @web_widget.inbox.messages.where(id: message_ids).where.not(status: 'read')

    messages.each do |msg|
      Messages::StatusUpdateService.new(msg, 'read').perform
    end
    head :ok
  end

  private

  def build_attachment
    return if params[:message][:attachments].blank?

    params[:message][:attachments].each do |uploaded_attachment|
      attachment = @message.attachments.new(
        account_id: @message.account_id,
        file: uploaded_attachment
      )

      attachment.file_type = helpers.file_type(uploaded_attachment&.content_type) if uploaded_attachment.is_a?(ActionDispatch::Http::UploadedFile)
    end
  end

  def set_conversation
    return unless conversation.nil?

    @conversation = create_conversation
    apply_labels if permitted_params[:labels].present?
  end

  def apply_labels
    valid_labels = inbox.account.labels.where(title: permitted_params[:labels]).pluck(:title)
    @conversation.update_labels(valid_labels) if valid_labels.present?
  end

  def message_finder_params
    {
      filter_internal_messages: true,
      before: permitted_params[:before],
      after: permitted_params[:after]
    }
  end

  def message_finder
    @message_finder ||= MessageFinder.new(conversation, message_finder_params)
  end

  def message_update_params
    params.permit(message: [:content, { content_attributes: {} }, { submitted_values: [:name, :title, :value, { csat_survey_response: [:feedback_message, :rating] }] }])
  end

  def permitted_params
    # timestamp parameter is used in create conversation method
    # custom_attributes and labels are applied when a new conversation is created alongside the first message
    params.permit(
      :id, :before, :after, :website_token,
      contact: [:name, :email],
      message: [:content, :referer_url, :timestamp, :echo_id, :reply_to],
      custom_attributes: {},
      labels: []
    )
  end

  def set_message
    @message = @web_widget.inbox.messages.find(permitted_params[:id])
  end
end
