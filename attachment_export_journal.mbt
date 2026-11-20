///|
/// The caller supplies a stable source identity for every planned entry.
/// Persisted output ownership and publication atomicity belong to its adapter.
/// Source bytes must remain immutable, including during output reconciliation.
pub struct AttachmentExportJournal {
  priv plan : AttachmentExportPlan
  priv signature : Bytes
  priv receipts : Array[AttachmentExportReceipt]
  priv mut pending : AttachmentExportReceipt?
  priv budget : Int32
  priv mut busy : Bool
  priv mut needs_save : Bool
}

///|
pub struct AttachmentExportJournalInfo {
  planned : Int32
  published : Int32
  payload_bytes : UInt64
  needs_save : Bool
  complete : Bool
}

///|
fn export_journal_room(
  out : @buffer.Buffer,
  size : Int32,
  budget : Int32,
) -> Unit raise McapError {
  if size < 0 || size > budget - out.length() {
    raise Invalid("attachment export journal exceeds byte budget")
  }
}

///|
fn export_journal_text(
  out : @buffer.Buffer,
  text : String,
  budget : Int32,
) -> Unit raise McapError {
  export_journal_room(out, text.length() + 4, budget)
  let bytes = @utf8.encode(text[:])
  export_journal_room(out, bytes.length() + 4, budget)
  put_blob(out, bytes)
}

///|
fn attachment_plan_signature(
  plan : AttachmentExportPlan,
  source_identity : (AttachmentIndex) -> String raise McapError,
  budget : Int32,
) -> Bytes raise McapError {
  if budget < 32 {
    raise Invalid("attachment export journal byte budget is too small")
  }
  let out = @buffer.Buffer::Buffer()
  out.write_uint_le(plan.entries.length().reinterpret_as_uint())
  for entry in plan.entries {
    let info = entry.attachment.info()
    let identity = source_identity(info)
    if identity == "" {
      raise Invalid("attachment export requires a nonempty source identity")
    }
    export_journal_text(out, entry.destination, budget)
    export_journal_text(out, identity, budget)
    // Index encoding also contains the physical offset and exact payload size.
    if info.name.length() > budget || info.media_type.length() > budget {
      raise Invalid("attachment export journal descriptor exceeds byte budget")
    }
    let descriptor = encode_attachment_index(info)
    export_journal_room(out, descriptor.length() + 4, budget)
    put_blob(out, descriptor)
  }
  // Reserve a fixed-size receipt for every output before creating any stages.
  if out.length().to_uint64() + 25UL + plan.entries.length().to_uint64() * 13UL >
    budget.to_uint64() {
    raise Invalid(
      "attachment export journal cannot hold all completion receipts",
    )
  }
  out.to_bytes()
}

///|
pub fn new_attachment_export_journal(
  plan : AttachmentExportPlan,
  source_identity : (AttachmentIndex) -> String raise McapError,
  journal_bytes~ : Int32 = 4 * 1024 * 1024,
) -> AttachmentExportJournal raise McapError {
  let signature = attachment_plan_signature(
    plan, source_identity, journal_bytes,
  )
  {
    plan,
    signature,
    receipts: [],
    pending: None,
    budget: journal_bytes,
    busy: false,
    needs_save: true,
  }
}

///|
pub fn AttachmentExportJournal::snapshot(
  self : AttachmentExportJournal,
) -> Bytes raise McapError {
  let out = @buffer.Buffer::Buffer()
  out.write_bytes(b"MCAPXJ2\x00"[:])
  put_blob(out, self.signature)
  out.write_uint_le(self.receipts.length().reinterpret_as_uint())
  for receipt in self.receipts {
    encode_export_receipt(out, receipt)
  }
  match self.pending {
    None => out.write_byte(0)
    Some(receipt) => {
      out.write_byte(1)
      encode_export_receipt(out, receipt)
    }
  }
  export_journal_room(out, 4, self.budget)
  out.write_uint_le(crc32(out.to_bytes()))
  out.to_bytes()
}

///|
fn encode_export_receipt(
  out : @buffer.Buffer,
  receipt : AttachmentExportReceipt,
) -> Unit {
  out.write_byte(if receipt.checksum_verified { 1 } else { 0 })
  out.write_uint_le(receipt.range_reads.reinterpret_as_uint())
  out.write_uint64_le(receipt.bytes_read)
}

///|
fn decode_export_receipt(
  fields : Cursor,
  entry : AttachmentExportEntry,
) -> AttachmentExportReceipt raise McapError {
  let verified = fields.take(1)[0]
  let calls = fields.u32().to_uint64()
  let bytes = fields.u64()
  if verified > 1 || calls > 2147483647UL {
    raise Invalid("invalid attachment export journal receipt fields")
  }
  {
    destination: entry.destination,
    source: entry.attachment.info(),
    checksum_verified: verified == 1,
    range_reads: calls.to_int(),
    bytes_read: bytes,
  }
}

///|
pub fn AttachmentExportJournal::receipts(
  self : AttachmentExportJournal,
) -> Array[AttachmentExportReceipt] {
  self.receipts.copy()
}

///|
pub fn AttachmentExportJournal::info(
  self : AttachmentExportJournal,
) -> AttachmentExportJournalInfo {
  let mut total = 0UL
  for receipt in self.receipts {
    total += receipt.source.data_size
  }
  {
    planned: self.plan.entries.length(),
    published: self.receipts.length(),
    payload_bytes: total,
    needs_save: self.needs_save,
    complete: self.receipts.length() == self.plan.entries.length() &&
    !self.needs_save,
  }
}

///|
fn AttachmentExportJournal::decode_export_journal(
  self : AttachmentExportJournal,
  snapshot : Bytes,
) -> Unit raise McapError {
  if snapshot.length() < 20 ||
    snapshot.length() > self.budget ||
    (
      snapshot[:8].to_owned() != b"MCAPXJ1\x00" &&
      snapshot[:8].to_owned() != b"MCAPXJ2\x00"
    ) {
    raise Invalid("invalid attachment export journal envelope")
  }
  let limits = { ..default_limits(), max_record_bytes: self.budget, }
  let end = snapshot.length() - 4
  let expected = cursor(snapshot[end:].to_owned(), limits).u32()
  if crc32(snapshot[:end].to_owned()) != expected {
    raise Invalid("attachment export journal CRC mismatch")
  }
  let fields = cursor(snapshot[8:end].to_owned(), limits)
  if fields.blob() != self.signature {
    raise Invalid("attachment export journal source or ordered plan changed")
  }
  let count = fields.u32().to_uint64()
  let version_two = snapshot[:8].to_owned() == b"MCAPXJ2\x00"
  let left = (fields.data.length() - fields.pos).to_uint64()
  if count > self.plan.entries.length().to_uint64() ||
    (if version_two {
      count * 13UL + 1UL != left && count * 13UL + 14UL != left
    } else {
      count * 13UL != left
    }) {
    raise Invalid("invalid attachment export journal receipt count")
  }
  for index in 0..<count.to_int() {
    self.receipts.push(decode_export_receipt(fields, self.plan.entries[index]))
  }
  if version_two {
    match fields.take(1)[0] {
      0 => ()
      1 => {
        if count == self.plan.entries.length().to_uint64() {
          raise Invalid("attachment export journal pending item exceeds plan")
        }
        self.pending = Some(
          decode_export_receipt(fields, self.plan.entries[count.to_int()]),
        )
      }
      _ => raise Invalid("invalid attachment export journal pending flag")
    }
  }
  fields.finish()
}

///|
/// Reload only after binding the current plan and source identities, then
/// verifying every published output with the caller's authoritative storage.
/// The validator should check content, size and ownership before returning true.
/// Pending publication requires authoritative reconciliation: true confirms
/// matching content owned by this job, false confirms absence, and uncertainty
/// or changed content must raise. Omitting it refuses a pending publication.
/// Version-one snapshots remain readable at their saved completion boundaries.
pub fn resume_attachment_exports(
  plan : AttachmentExportPlan,
  source_identity : (AttachmentIndex) -> String raise McapError,
  snapshot : Bytes,
  verify_output : (AttachmentExportReceipt) -> Bool raise McapError,
  reconcile_pending? : (AttachmentExportReceipt) -> Bool raise McapError,
  journal_bytes~ : Int32 = 4 * 1024 * 1024,
) -> AttachmentExportJournal raise McapError {
  let journal = new_attachment_export_journal(
    plan,
    source_identity,
    journal_bytes~,
  )
  journal.decode_export_journal(snapshot)
  for receipt in journal.receipts {
    if !verify_output(receipt) {
      raise Invalid(
        "attachment export completion is missing or changed: \{receipt.destination}",
      )
    }
  }
  match journal.pending {
    None => journal.needs_save = false
    Some(receipt) => {
      match reconcile_pending {
        None =>
          raise Invalid(
            "pending attachment publication requires authoritative reconciliation",
          )
        Some(reconcile) =>
          if reconcile(receipt) {
            journal.receipts.push(receipt)
          }
      }
      journal.pending = None
      // Persist the reconciliation before any further output is opened.
      journal.needs_save = true
    }
  }
  journal
}

///|
/// A failed save leaves committed receipts accessible for snapshot retry.
/// The next output starts only after the current receipt has been saved.
/// Save must atomically replace a durable snapshot, preserving the previous
/// complete snapshot on failure. An intent is saved after CRC verification and
/// before publish. An uncertain publish must be resolved by resume, never by
/// blindly recreating or overwriting an output. Adapters own stage cleanup.
pub fn AttachmentExportJournal::run(
  self : AttachmentExportJournal,
  create : (String, AttachmentIndex) -> AttachmentExportDestination raise McapError,
  save : (Bytes) -> Unit raise McapError,
  max_files~ : Int32 = 1000,
  cancelled~ : () -> Bool = fn() { false },
) -> AttachmentExportJournalInfo raise McapError {
  if self.busy || self.plan.busy || max_files <= 0 {
    raise Invalid("attachment export journal is busy or has invalid file count")
  }
  self.busy = true
  self.plan.busy = true
  defer {
    self.busy = false
    self.plan.busy = false
  }
  if self.pending is Some(_) {
    raise Invalid(
      "pending attachment publication requires resume and authoritative reconciliation",
    )
  }
  check_range_cancel(cancelled)
  if self.needs_save {
    save(self.snapshot())
    self.needs_save = false
  }
  let remaining = self.plan.entries.length() - self.receipts.length()
  let count = remaining.min(max_files)
  for _ in 0..<count {
    let index = self.receipts.length()
    let receipt = export_attachment_entry(
      self.plan.entries[index],
      create,
      cancelled,
      before_publish=receipt => {
        self.pending = Some(receipt)
        self.needs_save = true
        errdefer {
          // Publish was never attempted. A later run first replaces even
          // a successfully written intent whose save reported failure.
          self.pending = None
          self.needs_save = true
        }
        save(self.snapshot())
        check_range_cancel(cancelled)
        self.needs_save = false
      },
    )
    self.receipts.push(receipt)
    self.pending = None
    self.needs_save = true
    save(self.snapshot()) catch {
      Invalid(reason) =>
        raise Invalid(
          "attachment was published to \{receipt.destination}; receipt persistence failed: \{reason}",
        )
    }
    self.needs_save = false
  }
  self.info()
}
