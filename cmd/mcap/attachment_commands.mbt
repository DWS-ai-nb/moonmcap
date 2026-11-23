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
    ["attachment-catalog", path] => {
      let reader = @core.open_reader(scope.open(path), cache_bytes=0)
      let catalog = reader.attachment_catalog(verify_coverage=true)
      let info = catalog.info()
      let entries = catalog
        .select(limit=1000)
        .items()
        .map(a => attachment_json(a.info()))
      let report : Json = {
        "attachments": entries,
        "total": info.records,
        "payload_bytes": info.payload_bytes.to_string(),
        "coverage_checked": info.coverage_checked,
        "used_index": info.used_index,
      }
      println(report.stringify())
      true
    }
    ["attachment-range", path, offset, start, length] => {
      let reader = @core.open_reader(scope.open(path), cache_bytes=0)
      let catalog = reader.attachment_catalog(verify_coverage=true)
      guard catalog.find(@core.parse_decimal(offset)) is Some(item) else {
        raise @core.io_error("Attachment offset was not found")
      }
      let size = @core.parse_decimal(length)
      if size > 65536UL {
        raise @core.io_error("preview exceeds 64 KiB")
      }
      let bytes = item.read_range(@core.parse_decimal(start), size.to_int())
      let report : Json = {
        "data_hex": @core.encode_hex(bytes),
        "full_payload_crc_verified": false,
      }
      println(report.stringify())
      true
    }
    ["attachment-export", path, directory] => {
      let reader = @core.open_reader(scope.open(path), cache_bytes=0)
      let catalog = reader.attachment_catalog(verify_coverage=true)
      let max_files = 1000
      if catalog.info().records > max_files {
        raise @core.io_error(
          "attachment-export supports at most 1000 attachments; use attachment-list and attachment-extract for individual files",
        )
      }
      let selection = catalog.select(limit=max_files)
      let report = @nodeio.export_attachments(selection, directory)
      let receipts = report.receipts.map(receipt => {
        Json::object({
          "destination": receipt.destination,
          "attachment": attachment_json(receipt.source),
          "crc_verified": receipt.checksum_verified,
        })
      })
      let result : Json = {
        "receipts": receipts,
        "payload_bytes": report.payload_bytes.to_string(),
      }
      println(result.stringify())
      true
    }
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
    ["attachment-catalog", ..] =>
      raise @core.io_error("usage: attachment-catalog INPUT")
    ["attachment-range", ..] =>
      raise @core.io_error(
        "usage: attachment-range INPUT RECORD_OFFSET START LENGTH",
      )
    ["attachment-export", ..] =>
      raise @core.io_error("usage: attachment-export INPUT EXISTING_DIRECTORY")
    _ => false
  }
}
