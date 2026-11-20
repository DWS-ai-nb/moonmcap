///|
fn attachment_json(info : @core.AttachmentIndex) -> Json {
  {
    "offset": info.offset.to_string(),
    "record_bytes": info.length.to_string(),
    "name": info.name,
    "media_type": info.media_type,
    "log_time": info.log_time.to_string(),
    "create_time": info.create_time.to_string(),
    "data_size": info.data_size.to_string(),
  }
}

///|
fn extract_attachment(
  reader : @core.RangeReader,
  offset : UInt64,
  output : String,
) -> Json raise @core.McapError {
  let mut selected = None
  reader.visit_attachments(attachment => {
    let position = attachment.info().offset
    if position == offset {
      selected = Some(attachment)
    }
    position < offset
  })
  guard selected is Some(attachment) else {
    raise @core.io_error("Attachment offset was not found")
  }
  let transaction = @nodeio.output_transaction(output)
  errdefer transaction.abort()
  let verified = attachment.copy_to(transaction.sink())
  transaction.publish()
  {
    "attachment": attachment_json(attachment.info()),
    "attachment_crc_verified": verified,
  }
}

///|
fn run_attachment_command(
  args : ArrayView[String],
  scope : @nodeio.FileScope,
) -> Bool raise @core.McapError {
  match args {
    ["attachment-list", path] => {
      let reader = @core.open_reader(scope.open(path), cache_bytes=0)
      let entries = []
      let mut remaining = 8 * 1024 * 1024
      reader.visit_attachments(attachment => {
        let row = attachment_json(attachment.info())
        let size = @utf8.encode(row.stringify()[:]).length() + 1
        if size > remaining {
          raise @core.io_error("Attachment list exceeds JSON output budget")
        }
        remaining -= size
        entries.push(row)
        true
      })
      let report : Json = {
        "attachments": entries,
        "diagnostics": @core.read_diagnostics_json(reader.diagnostics()),
      }
      println(report.stringify())
      true
    }
    ["attachment-extract", path, offset, output] => {
      let reader = @core.open_reader(scope.open(path), cache_bytes=0)
      println(
        extract_attachment(reader, @core.parse_decimal(offset), output).stringify(),
      )
      true
    }
    ["attachment-list", ..] =>
      raise @core.io_error("usage: attachment-list INPUT")
    ["attachment-extract", ..] =>
      raise @core.io_error(
        "usage: attachment-extract INPUT RECORD_OFFSET NEW.bin",
      )
    _ => false
  }
}
