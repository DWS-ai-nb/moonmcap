///|
pub struct AttachmentPayloadCheck {
  payload_bytes : UInt64
  crc_verified : Bool
  range_reads : Int32
  bytes_read : UInt64
}

///|
/// Read one payload slice after checking the current record header against
/// the reference. Slice reads do not establish the whole attachment CRC.
/// The range is relative to its payload and must fit max_bytes and the
/// ordinary record budget. The file must remain stable during the operation.
pub fn AttachmentRef::read_range(
  self : AttachmentRef,
  offset : UInt64,
  length : Int32,
  max_bytes~ : Int32 = 65536,
  limits~ : Limits = default_limits(),
  cancelled~ : () -> Bool = fn() { false },
) -> Bytes raise McapError {
  if length < 0 ||
    max_bytes < 0 ||
    length > max_bytes ||
    length > limits.max_record_bytes ||
    offset > self.index.data_size ||
    length.to_uint64() > self.index.data_size - offset {
    raise Invalid(
      "Attachment payload range exceeds bounds or allocation budget",
    )
  }
  check_range_cancel(cancelled)
  let actual = self.recheck(limits)
  let bytes = if length == 0 {
    b""
  } else {
    actual.source.read_exact(actual.payload_at + offset, length)
  }
  check_range_cancel(cancelled)
  bytes
}

///|
/// Validate a complete payload with bounded windows and without retaining
/// the data. crc_verified=false means the file supplied no checksum.
pub fn AttachmentRef::verify_payload(
  self : AttachmentRef,
  limits~ : Limits = default_limits(),
  cancelled~ : () -> Bool = fn() { false },
) -> AttachmentPayloadCheck raise McapError {
  check_range_cancel(cancelled)
  let source = self.source
  let before_calls = source.calls
  let before_bytes = source.bytes_read
  let session = self.start_copy(new_write_sink(fn(_) { () }), limits~)
  let mut progress = session.step(cancelled~)
  while !progress.complete {
    progress = session.step(cancelled~)
  }
  {
    payload_bytes: progress.total,
    crc_verified: progress.crc_verified,
    range_reads: source.calls - before_calls,
    bytes_read: source.bytes_read - before_bytes,
  }
}
