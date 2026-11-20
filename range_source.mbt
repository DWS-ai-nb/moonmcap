///|
/// The callback may short-read, but must return bytes from a stable source.
pub struct ReadSource {
  size : UInt64
  read_at : (UInt64, Int32) -> Bytes raise McapError
  mut calls : Int32
  mut bytes_read : UInt64
}

///|
pub fn new_read_source(
  size : UInt64,
  read_at : (UInt64, Int32) -> Bytes raise McapError,
) -> ReadSource {
  { size, read_at, calls: 0, bytes_read: 0UL, }
}

///|
/// Build an error for host adapters without exposing internal error constructors.
pub fn io_error(message : String) -> McapError {
  Invalid("I/O: \{message}")
}

///|
pub fn memory_source(bytes : Bytes) -> ReadSource {
  new_read_source(bytes.length().to_uint64(), (offset, length) => {
    let start = bounded_length(offset, bytes.length(), "memory offset")
    if length < 0 || length > bytes.length() - start {
      raise Invalid("memory read outside source")
    }
    bytes[start:start + length].to_owned()
  })
}

///|
pub fn ReadSource::size(self : ReadSource) -> UInt64 {
  self.size
}

///|
/// Retry short reads, rejecting zero progress, over-reads and out-of-bounds spans.
pub fn ReadSource::read_exact(
  self : ReadSource,
  offset : UInt64,
  length : Int32,
) -> Bytes raise McapError {
  if length < 0 || offset > self.size || length.to_uint64() > self.size - offset {
    raise Invalid("read span outside source at \{offset}")
  }
  let out = @buffer.Buffer::Buffer()
  while out.length() < length {
    let remaining = length - out.length()
    self.calls += 1
    let bytes = (self.read_at)(offset + out.length().to_uint64(), remaining)
    self.bytes_read += bytes.length().to_uint64()
    if bytes.is_empty() || bytes.length() > remaining {
      raise Invalid(
        "short read without progress or invalid over-read at \{offset}",
      )
    }
    if out.length() == 0 && bytes.length() == length {
      return bytes
    }
    out.write_bytes(bytes[:])
  }
  out.to_bytes()
}

///|
#warnings("-missing_priv")
struct RangeRecord {
  opcode : Byte
  body : Bytes
}

///|
priv struct RecordSpan {
  opcode : Byte
  offset : UInt64
  length : UInt64
  next : UInt64
  prefix : Bytes
}

///|
fn ReadSource::record_span(
  self : ReadSource,
  offset : UInt64,
  end : UInt64,
  limits : Limits,
) -> RecordSpan raise McapError {
  if offset > end || end - offset < 9UL {
    raise Invalid("truncated record header at \{offset}")
  }
  let prefix = self.read_exact(offset, 9)
  let fields = cursor(prefix, limits)
  let opcode = fields.take(1)[0]
  let length = fields.u64()
  if opcode == 0 || length > end - offset - 9UL {
    raise Invalid("invalid record span at \{offset}")
  }
  { opcode, offset, length, next: offset + 9UL + length, prefix, }
}

///|
fn ReadSource::read_body(
  self : ReadSource,
  span : RecordSpan,
  limits : Limits,
) -> Bytes raise McapError {
  let length = bounded_length(span.length, limits.max_record_bytes, "record")
  self.read_exact(span.offset + 9UL, length)
}

///|
fn ReadSource::record(
  self : ReadSource,
  offset : UInt64,
  end : UInt64,
  limits : Limits,
) -> RangeRecord raise McapError {
  let span = self.record_span(offset, end, limits)
  { opcode: span.opcode, body: self.read_body(span, limits), }
}
