class AddExternalIdToUsers < ActiveRecord::Migration[7.0]
  def up
    add_column :users, :external_id, :string unless column_exists?(:users, :external_id)
    add_index :users, :external_id, unique: true unless index_exists?(:users, :external_id)

    # Data migration: Move external_id from custom_attributes to the new column
    User.reset_column_information
    User.find_each do |user|
      if user.custom_attributes.is_a?(Hash) && user.custom_attributes['external_id'].present?
        user.update_column(:external_id, user.custom_attributes['external_id'])
      end
    end
  end

  def down
    remove_index :users, :external_id if index_exists?(:users, :external_id)
    remove_column :users, :external_id if column_exists?(:users, :external_id)
  end
end
