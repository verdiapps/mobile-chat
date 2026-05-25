class AddUserIdToCannedResponses < ActiveRecord::Migration[7.0]
  def change
    add_column :canned_responses, :user_id, :integer
    add_index :canned_responses, :user_id
  end
end
