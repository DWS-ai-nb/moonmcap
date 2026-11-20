///|
pub(all) enum AsyncAttachmentCopyState {
  AttachmentCopyActive
  AttachmentCopyComplete
  AttachmentCopyFailed
  AttachmentCopyCancelled
} derive(Eq)

///|
pub extend AsyncAttachmentCopyState with Eq::{not_equal, equal}

///|
pub struct AsyncAttachmentCopyProgress {
  state : AsyncAttachmentCopyState
  copied : UInt64
  total : UInt64
  crc_verified : Bool
  read_calls : Int32
  bytes_read : UInt64
}

///|
/// A stepped extraction owns its sink while active. Source reads and writes
/// are awaited in sequence, and copied advances only after a successful write.
pub struct AsyncAttachmentCopy {
  attachment : AsyncAttachmentRef
  sink : AsyncSink
  expected_crc : UInt32
  first_metrics : AsyncReadMetrics
  mut copied : UInt64
  mut payload_crc : UInt32
  mut state : AsyncAttachmentCopyState
  mut busy : Bool
}

///|
fn ensure_attachment_sink(sink : AsyncSink) -> Unit raise @mcap.McapError {
  if sink.claimed || sink.cancelled || sink.bytes_written != 0UL {
    raise @mcap.io_error(
      "Attachment copy requires an empty unclaimed async sink",
    )
  }
}

///|
async fn AsyncAttachmentRef::checksum(self : AsyncAttachmentRef) -> UInt32 {
  attachment_u32(
    self.source.read_exact(self.payload_at + self.info.data_size, 4),
  )
}

///|
/// Open an extraction session at offset zero. Call step until it reports a
/// complete state, and keep any partial result private until then.
pub async fn AsyncAttachmentRef::start_copy(
  self : AsyncAttachmentRef,
  sink : AsyncSink,
) -> AsyncAttachmentCopy {
  ensure_attachment_sink(sink)
  let first_metrics = self.source.metrics()
  self.recheck()
  let expected_crc = self.checksum()
  ensure_attachment_sink(sink)
  sink.claimed = true
  {
    attachment: self,
    sink,
    expected_crc,
    first_metrics,
    copied: 0UL,
    payload_crc: self.header_crc,
    state: AttachmentCopyActive,
    busy: false,
  }
}

///|
fn AsyncAttachmentCopy::idle(
  self : AsyncAttachmentCopy,
) -> Unit raise @mcap.McapError {
  if self.busy ||
    self.state is AttachmentCopyFailed ||
    self.state is AttachmentCopyCancelled {
    raise @mcap.io_error(
      "async Attachment copy is closed or already in progress",
    )
  }
}

///|
fn AsyncAttachmentCopy::active(
  self : AsyncAttachmentCopy,
  cancelled : () -> Bool,
) -> Unit raise @mcap.McapError {
  attachment_checkpoint(cancelled)
  if !(self.state is AttachmentCopyActive) || self.sink.cancelled {
    raise @mcap.io_error("async Attachment copy was cancelled")
  }
}

///|
fn AsyncAttachmentCopy::stop(
  self : AsyncAttachmentCopy,
  state : AsyncAttachmentCopyState,
) -> Unit {
  if self.state is AttachmentCopyActive {
    self.state = state
    self.sink.cancel()
    self.sink.claimed = false
  }
}

///|
pub fn AsyncAttachmentCopy::cancel(self : AsyncAttachmentCopy) -> Unit {
  self.stop(AttachmentCopyCancelled)
}

///|
async fn AsyncAttachmentCopy::finish(self : AsyncAttachmentCopy) -> Unit {
  let actual = self.attachment.checksum()
  self.active(fn() { false })
  if actual != self.expected_crc {
    raise @mcap.io_error("Attachment checksum changed during async extraction")
  }
  if self.expected_crc != 0U && self.payload_crc != self.expected_crc {
    raise @mcap.io_error("asynchronous Attachment CRC mismatch")
  }
  self.state = AttachmentCopyComplete
  self.sink.claimed = false
}

///|
/// Each call accepts byte and window limits. Cancellation or I/O failure
/// invalidates the session and aborts its sink, preserving source ownership.
#warnings("-fragile_catch_all")
pub async fn AsyncAttachmentCopy::step(
  self : AsyncAttachmentCopy,
  max_bytes~ : UInt64 = 1024UL * 1024UL,
  max_windows~ : Int32 = 16,
  cancelled~ : () -> Bool = fn() { false },
) -> AsyncAttachmentCopyProgress {
  self.idle()
  if max_bytes == 0UL || max_windows <= 0 {
    raise @mcap.io_error("async Attachment step budgets must be positive")
  }
  if self.state is AttachmentCopyComplete {
    return self.progress()
  }
  self.busy = true
  defer {
    self.busy = false
  }
  let cancellation = [true]
  errdefer self.stop(
    if cancellation[0] {
      AttachmentCopyCancelled
    } else {
      AttachmentCopyFailed
    },
  )
  try {
    self.active(cancelled)
    if self.sink.bytes_written != self.copied {
      raise @mcap.io_error(
        "async Attachment destination changed outside its session",
      )
    }
    let attachment = self.attachment
    let mut remaining = max_bytes
    let mut windows = 0
    while self.copied < attachment.info.data_size &&
          remaining > 0UL &&
          windows < max_windows {
      self.active(cancelled)
      let left = attachment.info.data_size - self.copied
      let capacity = if left < remaining { left } else { remaining }
      let size = if capacity > 65536UL { 65536 } else { capacity.to_int() }
      let bytes = attachment.source.read_exact(
        attachment.payload_at + self.copied,
        size,
      )
      self.active(cancelled)
      self.sink.write(bytes)
      self.active(cancelled)
      self.payload_crc = @mcap.crc32_extend(self.payload_crc, bytes)
      self.copied += size.to_uint64()
      remaining -= size.to_uint64()
      windows += 1
    }
    self.active(cancelled)
    if self.copied == attachment.info.data_size {
      self.finish()
    }
    self.progress()
  } catch {
    error => {
      cancellation[0] = @async.is_cancellation_error(error)
      raise error
    }
  }
}

///|
pub fn AsyncAttachmentCopy::progress(
  self : AsyncAttachmentCopy,
) -> AsyncAttachmentCopyProgress {
  let current = self.attachment.source.metrics()
  {
    state: self.state,
    copied: self.copied,
    total: self.attachment.info.data_size,
    crc_verified: self.state is AttachmentCopyComplete &&
    self.expected_crc != 0U,
    read_calls: current.read_calls - self.first_metrics.read_calls,
    bytes_read: current.bytes_read - self.first_metrics.bytes_read,
  }
}

///|
/// Uses the same checkpoint format as synchronous AttachmentCopy.
pub fn AsyncAttachmentCopy::checkpoint(
  self : AsyncAttachmentCopy,
) -> Bytes raise @mcap.McapError {
  self.idle()
  if self.sink.bytes_written != self.copied {
    raise @mcap.io_error(
      "async Attachment checkpoint position differs from destination",
    )
  }
  let attachment = self.attachment
  let checkpoint : @mcap.AttachmentCheckpoint = {
    source_size: attachment.source.size,
    index: attachment.info,
    header_crc: attachment.header_crc,
    expected_crc: self.expected_crc,
    copied: self.copied,
    payload_crc: self.payload_crc,
  }
  checkpoint.encode()
}

///|
async fn AsyncAttachmentRef::verify_prefix(
  self : AsyncAttachmentRef,
  destination : AsyncSource,
  saved : @mcap.AttachmentCheckpoint,
  cancelled : () -> Bool,
) -> Unit {
  if destination.size != saved.copied {
    raise @mcap.io_error("async Attachment resume destination length differs")
  }
  let mut offset = 0UL
  let mut crc = self.header_crc
  while offset < saved.copied {
    attachment_checkpoint(cancelled)
    let left = saved.copied - offset
    let length = if left > 65536UL { 65536 } else { left.to_int() }
    let original = self.source.read_exact(self.payload_at + offset, length)
    let partial = destination.read_exact(offset, length)
    if original != partial {
      raise @mcap.io_error("async Attachment resume destination prefix differs")
    }
    crc = @mcap.crc32_extend(crc, original)
    offset += length.to_uint64()
  }
  attachment_checkpoint(cancelled)
  if crc != saved.payload_crc {
    raise @mcap.io_error("async Attachment saved prefix checksum differs")
  }
}

///|
/// Validate the complete saved prefix before claiming an append sink. append
/// starts at zero logical bytes and must append to the supplied destination.
pub async fn AsyncAttachmentRef::resume_copy(
  self : AsyncAttachmentRef,
  destination : AsyncSource,
  append : AsyncSink,
  checkpoint : Bytes,
  cancelled~ : () -> Bool = fn() { false },
) -> AsyncAttachmentCopy {
  ensure_attachment_sink(append)
  let saved = @mcap.decode_attachment_checkpoint(checkpoint, limits=self.limits)
  let first_metrics = self.source.metrics()
  attachment_checkpoint(cancelled)
  self.recheck()
  let checksum = self.checksum()
  if self.source.size != saved.source_size ||
    @mcap.encode_attachment_index(self.info) !=
    @mcap.encode_attachment_index(saved.index) ||
    self.header_crc != saved.header_crc ||
    checksum != saved.expected_crc {
    raise @mcap.io_error(
      "async Attachment checkpoint belongs to another source",
    )
  }
  self.verify_prefix(destination, saved, cancelled)
  ensure_attachment_sink(append)
  append.claimed = true
  append.bytes_written = saved.copied
  {
    attachment: self,
    sink: append,
    expected_crc: checksum,
    first_metrics,
    copied: saved.copied,
    payload_crc: saved.payload_crc,
    state: AttachmentCopyActive,
    busy: false,
  }
}
