///|
/// A reference to the payload of a top-level Attachment in a stable source.
pub struct AttachmentRef {
  index : AttachmentIndex
  source : ReadSource
  payload_at : UInt64
  body_end : UInt64
  header_crc : UInt32
}

///|
pub fn AttachmentRef::info(self : AttachmentRef) -> AttachmentIndex {
  self.index
}

///|
const ATTACHMENT_WINDOW : Int32 = 65536

///|
priv struct AttachmentHeaderCursor {
  source : ReadSource
  end : UInt64
  limits : Limits
  encoded : @buffer.Buffer
  mut position : UInt64
}

///|
fn AttachmentHeaderCursor::take(
  self : AttachmentHeaderCursor,
  size : Int32,
) -> Bytes raise McapError {
  if size < 0 ||
    size.to_uint64() > self.end - self.position ||
    size > self.limits.max_record_bytes - self.encoded.length() {
    raise Invalid("Attachment header exceeds its span or allocation budget")
  }
  let data = self.source.read_exact(self.position, size)
  self.encoded.write_bytes(data[:])
  self.position += size.to_uint64()
  data
}

///|
fn AttachmentHeaderCursor::text(
  self : AttachmentHeaderCursor,
) -> String raise McapError {
  let prefix = cursor(self.take(4), self.limits)
  let length = bounded_length(
    prefix.u32().to_uint64(),
    self.limits.max_string_bytes,
    "Attachment string",
  )
  @utf8.decode(self.take(length)[:]) catch {
    _ => raise Invalid("invalid UTF-8 in Attachment")
  }
}

///|
fn ReadSource::parse_attachment(
  self : ReadSource,
  span : RecordSpan,
  limits : Limits,
) -> (AttachmentRef, Bytes) raise McapError {
  if span.opcode != 0x09 || span.length < 36UL {
    raise Invalid("invalid Attachment record")
  }
  let fields : AttachmentHeaderCursor = {
    source: self,
    end: span.next,
    limits,
    encoded: @buffer.Buffer::Buffer(),
    position: span.offset + 9UL,
  }
  let times = cursor(fields.take(16), limits)
  let log_time = times.u64()
  let create_time = times.u64()
  let name = fields.text()
  let media_type = fields.text()
  let size = cursor(fields.take(8), limits).u64()
  let start = fields.position
  if span.next - start < 4UL || size > span.next - start - 4UL {
    raise Invalid("Attachment payload or CRC exceeds record span")
  }
  let header = fields.encoded.to_bytes()
  let index = {
    offset: span.offset,
    length: span.length + 9UL,
    log_time,
    create_time,
    data_size: size,
    name,
    media_type,
  }
  (
    {
      index,
      source: self,
      payload_at: start,
      body_end: span.next,
      header_crc: crc32(header),
    },
    header,
  )
}

///|
fn check_range_cancel(cancelled : () -> Bool) -> Unit raise McapError {
  if cancelled() {
    raise Invalid("MCAP range operation cancelled")
  }
}

///|
fn ReadSource::visit_span_bytes(
  self : ReadSource,
  start : UInt64,
  end : UInt64,
  consume : (Bytes) -> Unit raise McapError,
  cancelled : () -> Bool,
) -> Unit raise McapError {
  let mut offset = start
  while offset < end {
    check_range_cancel(cancelled)
    let length = if end - offset > ATTACHMENT_WINDOW.to_uint64() {
      ATTACHMENT_WINDOW
    } else {
      (end - offset).to_int()
    }
    consume(self.read_exact(offset, length))
    offset += length.to_uint64()
  }
}

///|
fn AttachmentRef::transfer(
  self : AttachmentRef,
  consume : (Bytes) -> Unit raise McapError,
  cancelled : () -> Bool,
) -> (Bytes, Bool) raise McapError {
  check_range_cancel(cancelled)
  let crc_at = self.payload_at + self.index.data_size
  let field = self.source.read_exact(crc_at, 4)
  let expected = cursor(field, default_limits()).u32()
  let mut crc = self.header_crc
  self.source.visit_span_bytes(
    self.payload_at,
    crc_at,
    bytes => {
      if expected != 0U {
        crc = crc32_extend(crc, bytes)
      }
      consume(bytes)
    },
    cancelled,
  )
  check_range_cancel(cancelled)
  if expected != 0U && expected != crc {
    raise Invalid("attachment CRC mismatch at \{self.index.offset}")
  }
  (field, expected != 0U)
}

///|
/// Copy payload windows of at most 64 KiB and return whether the supplied
/// attachment checksum was verified. Discard partial sink output on failure.
pub fn AttachmentRef::copy_to(
  self : AttachmentRef,
  sink : WriteSink,
  cancelled~ : () -> Bool = fn() { false },
) -> Bool raise McapError {
  let (_, verified) = self.transfer(bytes => sink.write(bytes), cancelled)
  verified
}

///|
fn RangeReader::visit_data_spans(
  self : RangeReader,
  visitor : (RecordSpan) -> Bool raise McapError,
  cancelled : () -> Bool,
) -> Unit raise McapError {
  let mut offset = self.data_start
  let mut records = 0
  while offset < self.data_end {
    check_range_cancel(cancelled)
    if records >= self.limits.max_records {
      raise Invalid("data scan record budget exceeded")
    }
    let span = self.source.record_span(offset, self.data_end, self.limits)
    match span.opcode {
      0x01 | 0x02 | 0x08 | 0x0a | 0x0b | 0x0d | 0x0e | 0x0f =>
        raise Invalid("unexpected record in data section at \{offset}")
      _ => ()
    }
    if !visitor(span) {
      return
    }
    offset = span.next
    records += 1
  }
  check_range_cancel(cancelled)
}

///|
/// Enumerate attachment headers in physical order, using record boundaries.
/// The visitor can stop early. Payloads and full data CRC are deferred.
pub fn RangeReader::visit_attachments(
  self : RangeReader,
  visitor : (AttachmentRef) -> Bool raise McapError,
  cancelled~ : () -> Bool = fn() { false },
) -> Unit raise McapError {
  self.visit_data_spans(
    span => {
      if span.opcode != 0x09 {
        return true
      }
      let (attachment, _) = self.source.parse_attachment(span, self.limits)
      visitor(attachment)
    },
    cancelled,
  )
}

///|
fn StreamWriter::write_attachment(
  self : StreamWriter,
  fields : AttachmentIndex,
  supply : ((Bytes) -> Unit raise McapError) -> Unit raise McapError,
) -> Unit raise McapError {
  let transfer = self.begin_attachment(
    fields.name,
    fields.media_type,
    fields.data_size,
    log_time=fields.log_time,
    create_time=fields.create_time,
  )
  errdefer transfer.cancel()
  supply(bytes => transfer.write(bytes))
  transfer.finish()
}

///|
pub struct AttachmentWrite {
  writer : StreamWriter
  index : AttachmentIndex
  mut left : UInt64
  mut crc : UInt32
  mut active : Bool
  mut busy : Bool
}

///|
/// Begin a single streamed record. Finish or cancel this session before
/// another writer operation. Each write is synchronously consumed.
pub fn StreamWriter::begin_attachment(
  self : StreamWriter,
  name : String,
  media_type : String,
  data_size : UInt64,
  log_time~ : UInt64 = 0UL,
  create_time~ : UInt64 = 0UL,
) -> AttachmentWrite raise McapError {
  self.require_open()
  let header = @buffer.Buffer::Buffer()
  header.write_uint64_le(log_time)
  header.write_uint64_le(create_time)
  for text in [name, media_type] {
    let bytes = @utf8.encode(text[:])
    if bytes.length() > self.limits.max_string_bytes ||
      bytes.length() > self.limits.max_record_bytes - header.length() - 12 {
      raise Invalid("Attachment string exceeds allocation budget")
    }
    header.write_uint_le(bytes.length().reinterpret_as_uint())
    header.write_bytes(bytes[:])
  }
  header.write_uint64_le(data_size)
  let head = header.to_bytes()
  let overhead = head.length().to_uint64() + 13UL
  if data_size > 18446744073709551615UL - overhead {
    raise Invalid("Attachment record length overflow")
  }
  let length = data_size + overhead
  let index : AttachmentIndex = {
    offset: 0UL,
    length,
    log_time,
    create_time,
    data_size,
    name,
    media_type,
  }
  let index_size = encode_attachment_index(index).length()
  if index_size > self.limits.max_record_bytes {
    raise Invalid("AttachmentIndex exceeds allocation budget")
  }
  self.check_summary(index_size + 9)
  self.attachment_open = true
  errdefer {
    if self.state == WriterOpen {
      self.state = WriterFailed
    }
    self.attachment_open = false
  }
  self.flush_pending()
  self.check_summary(index_size + 9)
  let offset = self.sink.position
  if length > 18446744073709551615UL - offset ||
    self.records >= self.limits.max_records {
    raise Invalid("streamed Attachment exceeds sink or record budget")
  }
  let prefix = @buffer.Buffer::Buffer()
  prefix.write_byte(0x09)
  prefix.write_uint64_le(length - 9UL)
  self.send(prefix.to_bytes(), true)
  self.require_attachment_open()
  self.send(head, true)
  self.require_attachment_open()
  {
    writer: self,
    index: { ..index, offset, },
    left: data_size,
    crc: crc32(head),
    active: true,
    busy: false,
  }
}

///|
fn StreamWriter::require_attachment_open(
  self : StreamWriter,
) -> Unit raise McapError {
  if self.state != WriterOpen || !self.attachment_open {
    raise Invalid("Attachment writer was cancelled during transfer")
  }
}

///|
fn AttachmentWrite::require_active(
  self : AttachmentWrite,
) -> Unit raise McapError {
  if !self.active ||
    self.busy ||
    self.writer.state != WriterOpen ||
    !self.writer.attachment_open {
    raise Invalid("Attachment session is closed or already in use")
  }
}

///|
/// Invalid input during an active transfer makes its destination unusable.
pub fn AttachmentWrite::write(
  self : AttachmentWrite,
  bytes : Bytes,
) -> Unit raise McapError {
  self.require_active()
  self.busy = true
  defer {
    self.busy = false
  }
  errdefer self.cancel()
  let size = bytes.length().to_uint64()
  if size > self.left {
    raise Invalid("Attachment source exceeds declared size")
  }
  self.writer.send(bytes, true)
  self.writer.require_attachment_open()
  self.left -= size
  self.crc = crc32_extend(self.crc, bytes)
}

///|
pub fn AttachmentWrite::finish(self : AttachmentWrite) -> Unit raise McapError {
  self.require_active()
  self.busy = true
  defer {
    self.busy = false
  }
  errdefer self.cancel()
  if self.left != 0UL {
    raise Invalid("Attachment source ended before declared size")
  }
  let writer = self.writer
  writer.send(self.crc.mcap_le_bytes(), true)
  writer.require_attachment_open()
  writer.records += 1
  writer.retain(0x0a, encode_attachment_index(self.index))
  writer.attachments += 1U
  writer.attachment_open = false
  self.active = false
}

///|
pub fn AttachmentWrite::cancel(self : AttachmentWrite) -> Unit {
  if self.active {
    self.active = false
    if self.writer.state == WriterOpen {
      self.writer.state = WriterFailed
    }
    self.writer.attachment_open = false
  }
}

///|
pub fn AttachmentWrite::remaining(self : AttachmentWrite) -> UInt64 {
  self.left
}

///|
/// Write a stable byte source as an Attachment using bounded payload windows.
/// Any transfer failure after output begins leaves the writer failed.
pub fn StreamWriter::add_attachment_from(
  self : StreamWriter,
  payload : ReadSource,
  name : String,
  media_type : String,
  log_time~ : UInt64 = 0UL,
  create_time~ : UInt64 = 0UL,
  cancelled~ : () -> Bool = fn() { false },
) -> Unit raise McapError {
  check_range_cancel(cancelled)
  self.write_attachment(
    {
      offset: 0UL,
      length: 0UL,
      log_time,
      create_time,
      data_size: payload.size,
      name,
      media_type,
    },
    consume => {
      payload.visit_span_bytes(0UL, payload.size, consume, cancelled)
      check_range_cancel(cancelled)
    },
  )
}

///|
/// Preserve an Attachment's metadata and payload and verify its input CRC.
pub fn StreamWriter::copy_attachment(
  self : StreamWriter,
  attachment : AttachmentRef,
  cancelled~ : () -> Bool = fn() { false },
) -> Unit raise McapError {
  check_range_cancel(cancelled)
  self.write_attachment(attachment.index, consume => {
    ignore(attachment.transfer(consume, cancelled))
  })
}
