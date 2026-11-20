///|
/// An application-defined staged destination. Publish makes the complete
/// staged output visible; abort cleans only that stage and must be idempotent.
pub struct AttachmentExportDestination {
  sink : WriteSink
  publish : () -> Unit raise McapError
  abort : () -> Unit raise McapError
}

///|
pub fn attachment_export_destination(
  sink : WriteSink,
  publish : () -> Unit raise McapError,
  abort : () -> Unit raise McapError,
) -> AttachmentExportDestination {
  { sink, publish, abort, }
}

///|
pub struct AttachmentExportReceipt {
  destination : String
  source : AttachmentIndex
  checksum_verified : Bool
  range_reads : Int32
  bytes_read : UInt64
}

///|
priv struct AttachmentExportEntry {
  destination : String
  attachment : AttachmentRef
}

///|
pub struct AttachmentExportPlan {
  priv entries : Array[AttachmentExportEntry]
  priv payload_bytes : UInt64
  priv mut busy : Bool
}

///|
pub struct AttachmentExportPlanInfo {
  records : Int32
  payload_bytes : UInt64
}

///|
pub struct AttachmentExportReport {
  receipts : Array[AttachmentExportReceipt]
  payload_bytes : UInt64
  next_index : Int32?
}

///|
/// Compute every output key before creating any stage. Keys are opaque
/// application identities. Filesystem adapters normalize case and paths in
/// this callback so collisions can be rejected before payload transfer.
pub fn AttachmentSelection::plan_exports(
  self : AttachmentSelection,
  destination : (AttachmentIndex) -> String raise McapError,
  key_bytes~ : Int32 = 1024 * 1024,
  cancelled~ : () -> Bool = fn() { false },
) -> AttachmentExportPlan raise McapError {
  if key_bytes < 0 {
    raise Invalid("negative attachment export key budget")
  }
  let seen : Map[String, Bool] = Map([])
  let entries = []
  let mut remaining = key_bytes
  for attachment in self.entries {
    check_range_cancel(cancelled)
    let key = destination(attachment.info())
    let bytes = @utf8.encode(key[:]).length()
    if key == "" || bytes > remaining {
      raise Invalid("attachment export key is empty or exceeds budget")
    }
    if seen.contains(key) {
      raise Invalid("duplicate attachment export destination: \{key}")
    }
    remaining -= bytes
    seen[key] = true
    entries.push({ destination: key, attachment, })
  }
  check_range_cancel(cancelled)
  { entries, payload_bytes: self.selected_bytes, busy: false, }
}

///|
pub fn AttachmentExportPlan::info(
  self : AttachmentExportPlan,
) -> AttachmentExportPlanInfo {
  { records: self.entries.length(), payload_bytes: self.payload_bytes, }
}

///|
/// Inspect the fully planned key and source offset before opening outputs.
pub fn AttachmentExportPlan::targets(
  self : AttachmentExportPlan,
) -> Array[(String, AttachmentIndex)] {
  self.entries.map(entry => (entry.destination, entry.attachment.info()))
}

///|
fn export_attachment_entry(
  entry : AttachmentExportEntry,
  create : (String, AttachmentIndex) -> AttachmentExportDestination raise McapError,
  cancelled : () -> Bool,
  before_publish~ : (AttachmentExportReceipt) -> Unit raise McapError = fn(_) {
    ()
  },
) -> AttachmentExportReceipt raise McapError {
  let info = entry.attachment.info()
  check_range_cancel(cancelled)
  let stage = create(entry.destination, info)
  let source = entry.attachment.source
  let before_reads = source.calls
  let before_bytes = source.bytes_read
  let result = try {
    if stage.sink.position() != 0UL {
      raise Invalid("attachment export requires an empty staged sink")
    }
    let verified = entry.attachment.copy_to(stage.sink, cancelled~)
    check_range_cancel(cancelled)
    let receipt = {
      destination: entry.destination,
      source: info,
      checksum_verified: verified,
      range_reads: source.calls - before_reads,
      bytes_read: source.bytes_read - before_bytes,
    }
    before_publish(receipt)
    (stage.publish)()
    Ok(receipt)
  } catch {
    error => Err(error)
  }
  match result {
    Ok(receipt) => receipt
    Err(Invalid(reason)) => {
      (stage.abort)() catch {
        Invalid(cleanup) =>
          raise Invalid(
            "\{reason}; attachment stage cleanup failed: \{cleanup}",
          )
      }
      raise Invalid(reason)
    }
  }
}

///|
/// Export in physical order with one staged destination at a time.
/// A committed item is reported through on_published before proceeding.
/// Destination callbacks own publication atomicity, handles and cleanup.
/// Input references retain the stable-source contract of AttachmentRef.
pub fn AttachmentExportPlan::export_files(
  self : AttachmentExportPlan,
  create : (String, AttachmentIndex) -> AttachmentExportDestination raise McapError,
  start_index~ : Int32 = 0,
  max_files~ : Int32 = 1000,
  on_published~ : (AttachmentExportReceipt) -> Unit raise McapError = fn(_) {
    ()
  },
  cancelled~ : () -> Bool = fn() { false },
) -> AttachmentExportReport raise McapError {
  if self.busy {
    raise Invalid("attachment export plan is already executing")
  }
  if start_index < 0 || start_index > self.entries.length() || max_files <= 0 {
    raise Invalid("invalid attachment export continuation or file count")
  }
  self.busy = true
  defer {
    self.busy = false
  }
  let count = max_files.min(self.entries.length() - start_index)
  let receipts = []
  let mut total = 0UL
  for index in start_index..<(start_index + count) {
    check_range_cancel(cancelled)
    let receipt = export_attachment_entry(
      self.entries[index],
      create,
      cancelled,
    )
    receipts.push(receipt)
    total += receipt.source.data_size
    on_published(receipt) catch {
      Invalid(reason) =>
        raise Invalid(
          "attachment was published to \{receipt.destination}; receipt callback failed: \{reason}",
        )
    }
  }
  let next = start_index + count
  {
    receipts,
    payload_bytes: total,
    next_index: if next < self.entries.length() {
      Some(next)
    } else {
      None
    },
  }
}
