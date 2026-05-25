json.id canned_response.id
json.short_code canned_response.short_code
json.content canned_response.content
json.account_id canned_response.account_id
json.user_id canned_response.user_id
json.content_attributes canned_response.content_attributes
json.files canned_response.files.map { |file|
  {
    id: file.id,
    file_type: file.content_type,
    file_url: url_for(file),
    signed_id: file.blob.signed_id,
    filename: file.filename.to_s
  }
} if canned_response.files.any?
