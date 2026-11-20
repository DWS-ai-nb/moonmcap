///|
extern "wasm" fn load_range(offset : UInt64, size : Int32) -> Int32 = "attachment_host" "load_range"

///|
extern "wasm" fn get_word(offset : Int32) -> UInt32 = "attachment_host" "get_word"

///|
extern "wasm" fn allocate_output(size : Int32) -> Unit = "attachment_host" "allocate_output"

///|
extern "wasm" fn put_word(offset : Int32, word : UInt32) -> Unit = "attachment_host" "put_word"

///|
extern "wasm" fn save_payload() -> Int32 = "attachment_host" "save_payload"

///|
fn receive(size : Int32) -> Bytes {
  let mut word = 0U
  Bytes::makei(size, i => {
    if (i & 3) == 0 {
      word = get_word(i)
    }
    ((word >> ((i & 3) * 8)) & 255U).to_byte()
  })
}

///|
fn send(bytes : Bytes) -> Unit {
  allocate_output(bytes.length())
  let mut offset = 0
  while offset < bytes.length() {
    let mut word = 0U
    for i in 0..<4 {
      if i < bytes.length() - offset {
        word = word | (bytes[offset + i].to_uint() << (i * 8))
      }
    }
    put_word(offset, word)
    if bytes.length() - offset <= 4 {
      break
    }
    offset += 4
  }
}

///|
fn text(
  fields : Map[String, Json],
  key : String,
) -> String raise @mcap.McapError {
  guard fields.get(key) is Some(String(value)) else {
    raise @mcap.io_error("expected request string \{key}")
  }
  value
}

///|
fn optional_decimal(
  fields : Map[String, Json],
  name : String,
  default : UInt64,
) -> UInt64 raise @mcap.McapError {
  if fields.get(name) is None {
    return default
  }
  @mcap.parse_decimal(text(fields, name))
}

///|
fn descriptor(item : @mcap.AttachmentIndex) -> Json {
  {
    "offset": item.offset.to_string(),
    "record_bytes": item.length.to_string(),
    "name": item.name,
    "media_type": item.media_type,
    "log_time": item.log_time.to_string(),
    "create_time": item.create_time.to_string(),
    "data_size": item.data_size.to_string(),
  }
}

///|
fn request(
  source : @mcap.ReadSource,
  json : String,
) -> Json raise @mcap.McapError {
  let options = @json.parse(json) catch {
    _ => raise @mcap.io_error("invalid request JSON")
  }
  guard options is Object(fields) else {
    raise @mcap.io_error("expected request object")
  }
  let reader = @mcap.open_reader(source, cache_bytes=0, fallback_bytes=0)
  let operation = text(fields, "operation")
  if operation == "query" {
    let topics = match fields.get("topic") {
      Some(String(topic)) => [topic]
      None => []
      _ => raise @mcap.io_error("expected topic string")
    }
    let result = reader.query_scan({
      ..@mcap.all_query(),
      topics,
      start_time: optional_decimal(fields, "start", 0UL),
      end_time: optional_decimal(fields, "end", 18446744073709551615UL),
    })
    return {
      "status": "ok",
      "messages": @mcap.messages_json(result.messages, result.channels),
      "diagnostics": @mcap.read_diagnostics_json(reader.diagnostics()),
    }
  }
  if operation == "verify" {
    let mut checked = false
    let count = @mcap.scan_source_streaming(
      source,
      @mcap.source_visitor(),
      attachment_ref=fn(_) { () },
      trace=event => {
        if event is @mcap.DataValidated(_, value) {
          checked = value
        }
      },
    )
    return {
      "status": "ok",
      "messages": count.to_string(),
      "data_crc_verified": checked,
    }
  }
  let catalog = reader.attachment_catalog(verify_coverage=true)
  if operation == "list" {
    let selected = catalog.select()
    return {
      "status": "ok",
      "attachments": selected.items().map(a => descriptor(a.info())),
      "coverage_checked": catalog.info().coverage_checked,
    }
  }
  let offset = @mcap.parse_decimal(text(fields, "offset"))
  guard catalog.find(offset) is Some(attachment) else {
    raise @mcap.io_error("unknown Attachment offset")
  }
  if operation == "range" {
    let start = optional_decimal(fields, "start", 0UL)
    let length = optional_decimal(fields, "length", 0UL)
    if length > 65536UL {
      raise @mcap.io_error("preview exceeds 64 KiB")
    }
    let bytes = attachment.read_range(start, length.to_int())
    return {
      "status": "ok",
      "attachment": descriptor(attachment.info()),
      "data_hex": @mcap.encode_hex(bytes),
      "payload_crc_verified": false,
    }
  }
  if operation != "extract" {
    raise @mcap.io_error("unknown attachment operation")
  }
  let verified = attachment.copy_to(
    @mcap.new_write_sink(bytes => {
      send(bytes)
      if save_payload() != bytes.length() {
        raise @mcap.io_error("short payload write from Wasm")
      }
    }),
  )
  {
    "status": "ok",
    "attachment": descriptor(attachment.info()),
    "payload_crc_verified": verified,
    "written_bytes": attachment.info().data_size.to_string(),
  }
}

///|
pub fn attachment_request(size : UInt64, request_bytes : Int32) -> Unit {
  let result = try {
    if request_bytes <= 0 || request_bytes > 65536 {
      raise @mcap.io_error("request exceeds 64 KiB")
    }
    let json = @utf8.decode(receive(request_bytes)[:]) catch {
      _ => raise @mcap.io_error("request is not UTF-8")
    }
    let source = @mcap.new_read_source(size, (offset, length) => {
      if load_range(offset, length) != length {
        raise @mcap.io_error("short range response from Wasm host")
      }
      receive(length)
    })
    request(source, json)
  } catch {
    @mcap.Invalid(reason) =>
      Json::object({ "status": "error", "error": reason })
  }
  send(@utf8.encode(result.stringify()[:]))
}
