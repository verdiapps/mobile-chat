class AddContentAttributesToCannedResponses < ActiveRecord::Migration[7.0]
  def change
    add_column :canned_responses, :content_attributes, :jsonb, default: {}
  end
end
