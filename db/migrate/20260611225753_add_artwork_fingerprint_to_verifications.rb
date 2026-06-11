class AddArtworkFingerprintToVerifications < ActiveRecord::Migration[8.0]
  def up
    add_column :verifications, :artwork_fingerprint, :string
    add_index :verifications, :artwork_fingerprint

    # Existing verifications were all produced from single (front) artwork:
    # their fingerprint is that blob's checksum.
    execute <<~SQL
      UPDATE verifications SET artwork_fingerprint = (
        SELECT blobs.checksum
        FROM active_storage_attachments attachments
        JOIN active_storage_blobs blobs ON blobs.id = attachments.blob_id
        WHERE attachments.record_type = 'LabelApplication'
          AND attachments.name = 'artwork'
          AND attachments.record_id = verifications.label_application_id
      )
    SQL
  end

  def down
    remove_index :verifications, :artwork_fingerprint
    remove_column :verifications, :artwork_fingerprint
  end
end
