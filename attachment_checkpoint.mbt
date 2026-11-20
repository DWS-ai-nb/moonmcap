///|
pub struct AttachmentCopyProgress {
  copied : UInt64
  total : UInt64
  complete : Bool
  crc_verified : Bool
  range_reads : Int32
  bytes_read : UInt64
}

///|
enum AttachmentCopyPhase {
  CopyActive
  CopyComplete
  CopyFailed
}

///|
/// Incremental binary extraction. Keep each session exclusive to its sink.
pub struct AttachmentCopy {
  attachment : AttachmentRef
  sink : WriteSink
  expected_crc : UInt32
  first_calls : Int32
  first_bytes : UInt64
  mut copied : UInt64
  mut payload_crc : UInt32
  mut phase : AttachmentCopyPhase
  mut busy : Bool
}

///|
fn AttachmentRef::recheck(
  self : AttachmentRef,
  limits : Limits,
) -> AttachmentRef raise McapError {
  let index = self.index
  if index.offset > self.source.size ||
    index.length > self.source.size - index.offset {
    raise Invalid("Attachment reference lies outside its source")
  }
  let span = self.source.record_span(
    index.offset,
    index.offset + index.length,
    limits,
  )
  let (actual, _) = self.source.parse_attachment(span, limits)
  if !same_attachment_index(actual.index, index) ||
    actual.header_crc != self.header_crc {
    raise Invalid("Attachment changed since its reference was created")
  }
  actual
}

///|
fn AttachmentRef::checksum(self : AttachmentRef) -> UInt32 raise McapError {
  cursor(
    self.source.read_exact(self.payload_at + self.index.data_size, 4),
    default_limits(),
  ).u32()
}

///|
/// Start extracting to a new binary destination. The caller publishes the
/// destination after the returned session reports completion.
pub fn AttachmentRef::start_copy(
  self : AttachmentRef,
  sink : WriteSink,
  limits~ : Limits = default_limits(),
) -> AttachmentCopy raise McapError {
  if sink.position != 0UL {
    raise Invalid("new Attachment copy requires an empty destination")
  }
  let source = self.source
  let calls = source.calls
  let bytes = source.bytes_read
  let actual = self.recheck(limits)
  {
    attachment: actual,
    sink,
    expected_crc: actual.checksum(),
    first_calls: calls,
    first_bytes: bytes,
    copied: 0UL,
    payload_crc: actual.header_crc,
    phase: CopyActive,
    busy: false,
  }
}

///|
fn AttachmentCopy::require_idle(self : AttachmentCopy) -> Unit raise McapError {
  if self.busy || self.phase is CopyFailed {
    raise Invalid("Attachment copy is failed or already in use")
  }
}

///|
fn AttachmentCopy::require_active(
  self : AttachmentCopy,
  cancelled : () -> Bool,
) -> Unit raise McapError {
  check_range_cancel(cancelled)
  if !(self.phase is CopyActive) {
    raise Invalid("Attachment copy cancelled during I/O callback")
  }
}

///|
fn AttachmentCopy::verify_end(
  self : AttachmentCopy,
  cancelled : () -> Bool,
) -> Unit raise McapError {
  let attachment = self.attachment
  let actual_crc = attachment.checksum()
  self.require_active(cancelled)
  if actual_crc != self.expected_crc {
    raise Invalid("Attachment checksum changed during copy")
  }
  if self.expected_crc != 0U && self.payload_crc != self.expected_crc {
    raise Invalid("attachment CRC mismatch at \{attachment.index.offset}")
  }
  self.phase = CopyComplete
}

///|
/// Write at most max_bytes using at most max_windows source windows.
/// A source/sink exception invalidates this session and its partial output.
pub fn AttachmentCopy::step(
  self : AttachmentCopy,
  max_bytes~ : UInt64 = 1024UL * 1024UL,
  max_windows~ : Int32 = 16,
  cancelled~ : () -> Bool = fn() { false },
) -> AttachmentCopyProgress raise McapError {
  self.require_idle()
  if max_windows <= 0 || max_bytes == 0UL {
    raise Invalid("Attachment copy step budgets must be positive")
  }
  if self.phase is CopyComplete {
    return self.progress()
  }
  self.busy = true
  defer {
    self.busy = false
  }
  errdefer {
    self.phase = CopyFailed
  }
  if self.sink.position != self.copied {
    raise Invalid("Attachment destination advanced outside its session")
  }
  let attachment = self.attachment
  let total = attachment.index.data_size
  let mut remaining = max_bytes
  let mut windows = 0
  while self.copied < total && remaining != 0UL && windows < max_windows {
    self.require_active(cancelled)
    let capacity = if total - self.copied < remaining {
      total - self.copied
    } else {
      remaining
    }
    let size = if capacity > ATTACHMENT_WINDOW.to_uint64() {
      ATTACHMENT_WINDOW
    } else {
      capacity.to_int()
    }
    let bytes = attachment.source.read_exact(
      attachment.payload_at + self.copied,
      size,
    )
    self.require_active(cancelled)
    self.sink.write(bytes)
    self.require_active(cancelled)
    self.payload_crc = crc32_extend(self.payload_crc, bytes)
    self.copied += size.to_uint64()
    remaining -= size.to_uint64()
    windows += 1
  }
  self.require_active(cancelled)
  if self.copied == total {
    self.verify_end(cancelled)
  }
  self.progress()
}

///|
pub fn AttachmentCopy::progress(
  self : AttachmentCopy,
) -> AttachmentCopyProgress {
  let source = self.attachment.source
  {
    copied: self.copied,
    total: self.attachment.index.data_size,
    complete: self.phase is CopyComplete,
    crc_verified: self.phase is CopyComplete && self.expected_crc != 0U,
    range_reads: source.calls - self.first_calls,
    bytes_read: source.bytes_read - self.first_bytes,
  }
}

///|
/// Closing a session retains its partial bytes for caller-managed cleanup.
pub fn AttachmentCopy::cancel(self : AttachmentCopy) -> Unit {
  if self.phase is CopyActive {
    self.phase = CopyFailed
  }
}

///|
pub(all) struct AttachmentCheckpoint {
  source_size : UInt64
  index : AttachmentIndex
  header_crc : UInt32
  expected_crc : UInt32
  copied : UInt64
  payload_crc : UInt32
}

///|
pub fn AttachmentCheckpoint::encode(
  self : AttachmentCheckpoint,
) -> Bytes raise McapError {
  let out = @buffer.Buffer::Buffer()
  out.write_bytes(b"MCAPACP1"[:])
  out.write_uint64_le(self.source_size)
  put_blob(out, encode_attachment_index(self.index))
  out.write_uint_le(self.header_crc)
  out.write_uint_le(self.expected_crc)
  out.write_uint64_le(self.copied)
  out.write_uint_le(self.payload_crc)
  if out.length() > 1024 * 1024 - 4 {
    raise Invalid("Attachment checkpoint exceeds 1 MiB")
  }
  out.write_uint_le(crc32(out.to_bytes()))
  out.to_bytes()
}

///|
pub fn decode_attachment_checkpoint(
  bytes : Bytes,
  limits~ : Limits = default_limits(),
) -> AttachmentCheckpoint raise McapError {
  if bytes.length() < 48 ||
    bytes.length() > 1024 * 1024 ||
    bytes[:8].to_owned() != b"MCAPACP1" {
    raise Invalid("invalid Attachment checkpoint envelope")
  }
  let crc_at = bytes.length() - 4
  let expected = cursor(bytes[crc_at:].to_owned(), limits).u32()
  if crc32(bytes[:crc_at].to_owned()) != expected {
    raise Invalid("Attachment checkpoint CRC mismatch")
  }
  let fields = cursor(bytes[8:crc_at].to_owned(), limits)
  let source_size = fields.u64()
  let index = decode_attachment_index(fields.blob(), limits~)
  let header_crc = fields.u32()
  let expected_crc = fields.u32()
  let copied = fields.u64()
  let payload_crc = fields.u32()
  fields.finish()
  if copied > index.data_size {
    raise Invalid("Attachment checkpoint exceeds payload length")
  }
  { source_size, index, header_crc, expected_crc, copied, payload_crc, }
}

///|
/// A checkpoint has a corruption-detection CRC. Resume re-reads the saved
/// prefix from source and destination before accepting it.
pub fn AttachmentCopy::checkpoint(
  self : AttachmentCopy,
) -> Bytes raise McapError {
  self.require_idle()
  if self.sink.position != self.copied {
    raise Invalid("Attachment sink does not match checkpoint position")
  }
  let attachment = self.attachment
  let value : AttachmentCheckpoint = {
    source_size: attachment.source.size,
    index: attachment.index,
    header_crc: attachment.header_crc,
    expected_crc: self.expected_crc,
    copied: self.copied,
    payload_crc: self.payload_crc,
  }
  value.encode()
}

///|
fn AttachmentRef::check_saved_prefix(
  self : AttachmentRef,
  destination : ReadSource,
  saved : AttachmentCheckpoint,
  cancelled : () -> Bool,
) -> Unit raise McapError {
  if destination.size != saved.copied {
    raise Invalid("Attachment resume destination length mismatch")
  }
  let mut offset = 0UL
  let mut crc = self.header_crc
  while offset < saved.copied {
    check_range_cancel(cancelled)
    let left = saved.copied - offset
    let size = if left > ATTACHMENT_WINDOW.to_uint64() {
      ATTACHMENT_WINDOW
    } else {
      left.to_int()
    }
    let original = self.source.read_exact(self.payload_at + offset, size)
    if original != destination.read_exact(offset, size) {
      raise Invalid("Attachment resume destination prefix differs from source")
    }
    crc = crc32_extend(crc, original)
    offset += size.to_uint64()
  }
  if crc != saved.payload_crc {
    raise Invalid("Attachment saved prefix checksum mismatch")
  }
  check_range_cancel(cancelled)
}

///|
/// Reopen a partially extracted binary after checking its complete saved
/// prefix against the immutable source. append must append to that same
/// destination and reject concurrent modifications. Prefix verification
/// requires linear reads proportional to the bytes already extracted.
pub fn AttachmentRef::resume_copy(
  self : AttachmentRef,
  destination : ReadSource,
  append : (Bytes) -> Unit raise McapError,
  checkpoint : Bytes,
  limits~ : Limits = default_limits(),
  cancelled~ : () -> Bool = fn() { false },
) -> AttachmentCopy raise McapError {
  let saved = decode_attachment_checkpoint(checkpoint, limits~)
  let source = self.source
  let calls = source.calls
  let bytes = source.bytes_read
  let actual = self.recheck(limits)
  if source.size != saved.source_size ||
    !same_attachment_index(actual.index, saved.index) ||
    actual.header_crc != saved.header_crc ||
    actual.checksum() != saved.expected_crc {
    raise Invalid("Attachment checkpoint belongs to a different source")
  }
  actual.check_saved_prefix(destination, saved, cancelled)
  {
    attachment: actual,
    sink: { write_all: append, position: destination.size, },
    expected_crc: saved.expected_crc,
    first_calls: calls,
    first_bytes: bytes,
    copied: saved.copied,
    payload_crc: saved.payload_crc,
    phase: CopyActive,
    busy: false,
  }
}
