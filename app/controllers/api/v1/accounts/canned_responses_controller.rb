class Api::V1::Accounts::CannedResponsesController < Api::V1::Accounts::BaseController
  before_action :fetch_canned_response, only: [:update, :destroy]

  def index
    @canned_responses = canned_responses
  end

  def create
    @canned_response = Current.account.canned_responses.new(canned_response_params)
    @canned_response.user_id = Current.user.id
    @canned_response.save!
    attach_files if params[:files].present?
  end

  def update
    @canned_response.update!(canned_response_params)
    attach_files if params[:files].present?
  end

  def destroy
    @canned_response.destroy!
    head :ok
  end

  private

  def fetch_canned_response
    @canned_response = Current.account.canned_responses.find(params[:id])
  end

  def canned_response_params
    params.require(:canned_response).permit(:short_code, :content, content_attributes: {})
  end

  def attach_files
    params[:files].each do |file|
      @canned_response.files.attach(file)
    end
  end

  def canned_responses
    records = Current.account.canned_responses

    show_all = params[:all] == 'true' || request.headers['X-Canned-All'] == 'true'

    if show_all && Current.user.administrator?
    elsif params[:user_id].present?
      records = records.by_user(params[:user_id])
    else
      records = records.by_user(Current.user.id)
    end

    if params[:search]
      records = records.where('short_code ILIKE :search OR content ILIKE :search',
                               search: "%#{params[:search]}%")
                         .order_by_search(params[:search])
    end

    records
  end
end
