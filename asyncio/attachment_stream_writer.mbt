///|
#warnings("-fragile_catch_all")
async fn AsyncWriter::attachment_operation(
  self : AsyncWriter,
  name : String,
  media_type : String,
  data_size : UInt64,
  log_time : UInt64,
  create_time : UInt64,
  supply : async (@mcap.AttachmentWrite) -> Unit,
) -> Unit {
  if self.state != AsyncOpen || self.busy {
    raise @mcap.io_error("async writer closed or operation already in progress")
  }
  self.busy = true
  defer {
    self.busy = false
  }
  let session = {
    errdefer (if self.writer.progress().state != @mcap.WriterOpen {
      self.fail()
    })
    self.writer.begin_attachment(
      name,
      media_type,
      data_size,
      log_time~,
      create_time~,
    )
  }
  let ordinary_failure = [false]
  errdefer {
    session.cancel()
    if ordinary_failure[0] {
      self.fail()
    } else {
      self.cancel()
    }
  }
  try {
    self.drain()
    supply(session)
    session.finish()
    self.drain()
  } catch {
    error => {
      ordinary_failure[0] = !@async.is_cancellation_error(error)
      raise error
    }
  }
}

///|
/// Read a known-length async payload source one window at a time. Sink writes
/// complete before the next source window is requested.
pub async fn AsyncWriter::add_attachment_from(
  self : AsyncWriter,
  source : AsyncSource,
  name : String,
  media_type : String,
  log_time~ : UInt64 = 0UL,
  create_time~ : UInt64 = 0UL,
  cancelled~ : () -> Bool = fn() { false },
) -> Unit {
  attachment_checkpoint(cancelled)
  self.attachment_operation(
    name,
    media_type,
    source.size,
    log_time,
    create_time,
    async fn(session) {
      let mut offset = 0UL
      while offset < source.size {
        attachment_checkpoint(cancelled)
        let window = self.queue.budget.min(65536)
        let length = if source.size - offset > window.to_uint64() {
          window
        } else {
          (source.size - offset).to_int()
        }
        let bytes = source.read_exact(offset, length)
        session.write(bytes)
        self.drain()
        offset += length.to_uint64()
      }
      attachment_checkpoint(cancelled)
    },
  )
}

///|
/// Copy a stable Attachment reference while checking its original CRC.
pub async fn AsyncWriter::copy_attachment(
  self : AsyncWriter,
  attachment : AsyncAttachmentRef,
  cancelled~ : () -> Bool = fn() { false },
) -> Unit {
  attachment_checkpoint(cancelled)
  let info = attachment.info
  self.attachment_operation(
    info.name,
    info.media_type,
    info.data_size,
    info.log_time,
    info.create_time,
    async fn(session) {
      ignore(
        attachment.transfer(
          async fn(bytes) {
            session.write(bytes)
            self.drain()
          },
          cancelled,
          self.queue.budget.min(65536),
        ),
      )
    },
  )
}
