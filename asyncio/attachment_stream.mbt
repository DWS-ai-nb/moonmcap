///|
/// An attachment descriptor bound to a stable asynchronous byte source.
pub struct AsyncAttachmentRef {
  source : AsyncSource
  limits : @mcap.Limits
  info : @mcap.AttachmentIndex
  payload_at : UInt64
  record_end : UInt64
  header_crc : UInt32
}

///|
pub fn AsyncAttachmentRef::info(
  self : AsyncAttachmentRef,
) -> @mcap.AttachmentIndex {
  self.info
}

///|
pub struct AsyncAttachmentTransfer {
  payload_bytes : UInt64
  crc_verified : Bool
  read_calls : Int32
  bytes_read : UInt64
}

///|
pub struct AsyncAttachmentReader {
  source : AsyncSource
  limits : @mcap.Limits
  data_start : UInt64
  data_end : UInt64
}

///|
priv struct AsyncAttachmentSpan {
  opcode : Byte
  offset : UInt64
  length : UInt64
  next : UInt64
}

///|
fn attachment_u64(bytes : Bytes, start : Int32) -> UInt64 {
  let mut result = 0UL
  for i in 0..<8 {
    result = result | (bytes[start + i].to_uint64() << (i * 8))
  }
  result
}

///|
fn attachment_u32(bytes : Bytes) -> UInt32 {
  let mut result = 0U
  for i in 0..<4 {
    result = result | (bytes[i].to_uint() << (i * 8))
  }
  result
}

///|
fn attachment_checkpoint(cancelled : () -> Bool) -> Unit raise @mcap.McapError {
  if cancelled() {
    raise @mcap.io_error("async attachment operation cancelled")
  }
}

///|
async fn AsyncSource::attachment_span(
  self : AsyncSource,
  offset : UInt64,
  end : UInt64,
) -> AsyncAttachmentSpan {
  if offset > end || end - offset < 9UL {
    raise @mcap.io_error("truncated async Attachment record prefix")
  }
  let prefix = self.read_exact(offset, 9)
  let length = attachment_u64(prefix, 1)
  if prefix[0] == 0 || length > end - offset - 9UL {
    raise @mcap.io_error("async record span exceeds the data section")
  }
  { opcode: prefix[0], offset, length, next: offset + 9UL + length, }
}

///|
priv struct AsyncAttachmentFields {
  source : AsyncSource
  end : UInt64
  limits : @mcap.Limits
  mut position : UInt64
  mut budget : Int32
  mut crc : UInt32
}

///|
async fn AsyncAttachmentFields::take(
  self : AsyncAttachmentFields,
  length : Int32,
) -> Bytes {
  if length < 0 ||
    length > self.budget ||
    length.to_uint64() > self.end - self.position {
    raise @mcap.io_error(
      "async Attachment header exceeds span or allocation budget",
    )
  }
  let bytes = self.source.read_exact(self.position, length)
  self.position += length.to_uint64()
  self.budget -= length
  self.crc = @mcap.crc32_extend(self.crc, bytes)
  bytes
}

///|
async fn AsyncAttachmentFields::text(self : AsyncAttachmentFields) -> String {
  let length = attachment_u32(self.take(4)).to_uint64()
  if length > self.limits.max_string_bytes.to_uint64() ||
    length > self.budget.to_uint64() {
    raise @mcap.io_error("async Attachment label exceeds its byte budget")
  }
  @utf8.decode(self.take(length.to_int())[:]) catch {
    _ => raise @mcap.io_error("async Attachment label is not UTF-8")
  }
}

///|
async fn AsyncSource::attachment_reference(
  self : AsyncSource,
  span : AsyncAttachmentSpan,
  limits : @mcap.Limits,
) -> AsyncAttachmentRef {
  if span.opcode != 0x09 || span.length < 36UL {
    raise @mcap.io_error("expected a complete async Attachment record")
  }
  let fields : AsyncAttachmentFields = {
    source: self,
    end: span.next,
    limits,
    position: span.offset + 9UL,
    budget: limits.max_record_bytes,
    crc: 0U,
  }
  let times = fields.take(16)
  let log_time = attachment_u64(times, 0)
  let create_time = attachment_u64(times, 8)
  let name = fields.text()
  let media_type = fields.text()
  let data_size = attachment_u64(fields.take(8), 0)
  if span.next - fields.position < 4UL ||
    data_size > span.next - fields.position - 4UL {
    raise @mcap.io_error("async Attachment data size exceeds its record")
  }
  {
    source: self,
    limits,
    info: {
      offset: span.offset,
      length: span.length + 9UL,
      log_time,
      create_time,
      data_size,
      name,
      media_type,
    },
    payload_at: fields.position,
    record_end: span.next,
    header_crc: fields.crc,
  }
}

///|
/// Open only the file envelope and summary. This entry point handles large,
/// unindexed files without taking the normal AsyncReader fallback path.
pub async fn open_attachment_reader(
  source : AsyncSource,
  limits~ : @mcap.Limits = @mcap.default_limits(),
  summary_bytes~ : Int32 = 8 * 1024 * 1024,
) -> AsyncAttachmentReader {
  if source.size < 50UL ||
    summary_bytes < 0 ||
    limits.max_record_bytes < 22 ||
    limits.max_string_bytes < 0 ||
    limits.max_records <= 0 ||
    limits.max_decompressed_bytes < 0 {
    raise @mcap.io_error("invalid asynchronous attachment reader limits")
  }
  let spans : Array[(@mcap.ReadSpan, Bytes)] = []
  let add = (offset : UInt64, bytes : Bytes) => {
    spans.push(({ offset, length: bytes.length(), }, bytes))
  }
  let leading = source.read_exact(0UL, 8)
  if leading != @mcap.magic() {
    raise @mcap.io_error("async attachment source has no leading magic")
  }
  add(0UL, leading)
  let footer_at = source.size - 37UL
  let tail = source.read_exact(footer_at, 37)
  if tail[29:].to_owned() != @mcap.magic() {
    raise @mcap.io_error("async attachment source has no trailing magic")
  }
  add(footer_at, tail)
  let records = @mcap.decode_records(tail[:29].to_owned(), limits~)
  if records.length() != 1 || records[0].opcode != 0x02 {
    raise @mcap.io_error("invalid asynchronous attachment Footer")
  }
  let footer = @mcap.decode_footer(records[0].body)
  let summary_start = if footer.summary_start == 0UL {
    footer_at
  } else {
    footer.summary_start
  }
  if summary_start < 30UL ||
    summary_start > footer_at ||
    footer_at - summary_start > summary_bytes.to_uint64() {
    raise @mcap.io_error("async attachment summary exceeds envelope or budget")
  }
  let data_end = summary_start - 13UL
  let end = source.read_exact(data_end, 13)
  add(data_end, end)
  let header = source.attachment_span(8UL, data_end)
  if header.opcode != 0x01 ||
    header.length > limits.max_record_bytes.to_uint64() {
    raise @mcap.io_error("invalid async attachment Header")
  }
  add(8UL, source.read_exact(8UL, 9))
  add(17UL, source.read_exact(17UL, header.length.to_int()))
  add(
    summary_start,
    source.read_exact(summary_start, (footer_at - summary_start).to_int()),
  )
  let mirror = @mcap.new_read_source(source.size, (offset, length) => {
    for (span, bytes) in spans {
      if offset >= span.offset &&
        offset - span.offset <= span.length.to_uint64() {
        let start = (offset - span.offset).to_int()
        if length <= bytes.length() - start {
          return bytes[start:start + length].to_owned()
        }
      }
    }
    raise @mcap.io_error(
      "async attachment metadata mirror received a payload request",
    )
  })
  ignore(
    @mcap.open_reader(
      mirror,
      limits~,
      cache_bytes=0,
      summary_bytes~,
      fallback_bytes=0,
    ),
  )
  { source, limits, data_start: header.next, data_end, }
}

///|
/// Enumerate references in physical order. Await each visitor before reading
/// the next descriptor. Names may repeat, and payload CRCs remain deferred.
pub async fn AsyncAttachmentReader::visit_attachments(
  self : AsyncAttachmentReader,
  visitor : async (AsyncAttachmentRef) -> Bool,
  cancelled~ : () -> Bool = fn() { false },
) -> Unit {
  let mut offset = self.data_start
  let mut count = 0
  while offset < self.data_end {
    attachment_checkpoint(cancelled)
    if count >= self.limits.max_records {
      raise @mcap.io_error("async Attachment scan record count exceeded")
    }
    let span = self.source.attachment_span(offset, self.data_end)
    match span.opcode {
      0x01 | 0x02 | 0x08 | 0x0a | 0x0b | 0x0d | 0x0e | 0x0f =>
        raise @mcap.io_error(
          "unexpected summary record in asynchronous data scan",
        )
      0x09 => {
        let item = self.source.attachment_reference(span, self.limits)
        attachment_checkpoint(cancelled)
        let keep_going = visitor(item)
        attachment_checkpoint(cancelled)
        if !keep_going {
          return
        }
      }
      _ => ()
    }
    offset = span.next
    count += 1
  }
  attachment_checkpoint(cancelled)
}

///|
/// Resolve a top-level record offset, rejecting offsets inside other records.
pub async fn AsyncAttachmentReader::find_attachment(
  self : AsyncAttachmentReader,
  offset : UInt64,
) -> AsyncAttachmentRef {
  let mut selected = None
  self.visit_attachments(fn(item) {
    let position = item.info.offset
    if position == offset {
      selected = Some(item)
    }
    position < offset
  })
  match selected {
    Some(item) => item
    None => raise @mcap.io_error("asynchronous Attachment offset was not found")
  }
}

///|
async fn AsyncAttachmentRef::recheck(self : AsyncAttachmentRef) -> Unit {
  let span = self.source.attachment_span(self.info.offset, self.record_end)
  let actual = self.source.attachment_reference(span, self.limits)
  if @mcap.encode_attachment_index(actual.info) !=
    @mcap.encode_attachment_index(self.info) ||
    actual.payload_at != self.payload_at ||
    actual.header_crc != self.header_crc {
    raise @mcap.io_error(
      "Attachment descriptor changed before asynchronous transfer",
    )
  }
}

///|
async fn AsyncAttachmentRef::transfer(
  self : AsyncAttachmentRef,
  consume : async (Bytes) -> Unit,
  cancelled : () -> Bool,
  window : Int32,
) -> AsyncAttachmentTransfer {
  attachment_checkpoint(cancelled)
  let start = self.source.metrics()
  self.recheck()
  let checksum_at = self.payload_at + self.info.data_size
  let checksum = attachment_u32(self.source.read_exact(checksum_at, 4))
  let mut crc = self.header_crc
  let mut position = self.payload_at
  while position < checksum_at {
    attachment_checkpoint(cancelled)
    let length = if checksum_at - position > window.to_uint64() {
      window
    } else {
      (checksum_at - position).to_int()
    }
    let bytes = self.source.read_exact(position, length)
    if checksum != 0U {
      crc = @mcap.crc32_extend(crc, bytes)
    }
    consume(bytes)
    attachment_checkpoint(cancelled)
    position += length.to_uint64()
  }
  if checksum != 0U && crc != checksum {
    raise @mcap.io_error("asynchronous Attachment CRC mismatch")
  }
  attachment_checkpoint(cancelled)
  let after = self.source.metrics()
  {
    payload_bytes: self.info.data_size,
    crc_verified: checksum != 0U,
    read_calls: after.read_calls - start.read_calls,
    bytes_read: after.bytes_read - start.bytes_read,
  }
}

///|
/// Copy with async backpressure. A transfer holds the sink until it completes.
/// Failure cancels the sink exactly once, while the caller retains the source.
pub async fn AsyncAttachmentRef::copy_to(
  self : AsyncAttachmentRef,
  sink : AsyncSink,
  cancelled~ : () -> Bool = fn() { false },
) -> AsyncAttachmentTransfer {
  if sink.claimed || sink.cancelled {
    raise @mcap.io_error(
      "asynchronous Attachment sink is already owned or cancelled",
    )
  }
  sink.claimed = true
  defer {
    sink.claimed = false
  }
  errdefer sink.cancel()
  self.transfer(async fn(bytes) { sink.write(bytes) }, cancelled, 65536)
}
