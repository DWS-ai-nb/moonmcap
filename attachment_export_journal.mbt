///|
/// The caller supplies a stable source identity for every planned entry.
/// Persisted output ownership and publication atomicity belong to its adapter.
pub struct AttachmentExportJournal {
  plan : AttachmentExportPlan
  signature : Bytes
  receipts : Array[AttachmentExportReceipt]
  budget : Int32
  mut busy : Bool
  mut needs_save : Bool
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
  if out.length().to_uint64() + 24UL + plan.entries.length().to_uint64() * 13UL >
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
  out.write_bytes(b"MCAPXJ1\x00"[:])
  put_blob(out, self.signature)
  out.write_uint_le(self.receipts.length().reinterpret_as_uint())
  for receipt in self.receipts {
    out.write_byte(if receipt.checksum_verified { 1 } else { 0 })
    out.write_uint_le(receipt.range_reads.reinterpret_as_uint())
    out.write_uint64_le(receipt.bytes_read)
  }
  export_journal_room(out, 4, self.budget)
  out.write_uint_le(crc32(out.to_bytes()))
  out.to_bytes()
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
    snapshot[:8].to_owned() != b"MCAPXJ1\x00" {
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
  if count > self.plan.entries.length().to_uint64() ||
    count * 13UL != (fields.data.length() - fields.pos).to_uint64() {
    raise Invalid("invalid attachment export journal receipt count")
  }
  for index in 0..<count.to_int() {
    let verified = fields.take(1)[0]
    let calls = fields.u32().to_uint64()
    let bytes = fields.u64()
    if verified > 1 || calls > 2147483647UL {
      raise Invalid("invalid attachment export journal receipt fields")
    }
    let entry = self.plan.entries[index]
    self.receipts.push({
      destination: entry.destination,
      source: entry.attachment.info(),
      checksum_verified: verified == 1,
      range_reads: calls.to_int(),
      bytes_read: bytes,
    })
  }
  fields.finish()
}

///|
/// Reload only after binding the current plan and source identities, then
/// verifying every published output with the caller's authoritative storage.
/// The validator should check content, size and ownership before returning true.
pub fn resume_attachment_exports(
  plan : AttachmentExportPlan,
  source_identity : (AttachmentIndex) -> String raise McapError,
  snapshot : Bytes,
  verify_output : (AttachmentExportReceipt) -> Bool raise McapError,
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
  journal.needs_save = false
  journal
}

///|
/// A failed save leaves committed receipts accessible for snapshot retry.
/// The next output starts only after the current receipt has been saved.
pub fn AttachmentExportJournal::run(
  self : AttachmentExportJournal,
  create : (String, AttachmentIndex) -> AttachmentExportDestination raise McapError,
  save : (Bytes) -> Unit raise McapError,
  max_files~ : Int32 = 1000,
  cancelled~ : () -> Bool = fn() { false },
) -> AttachmentExportJournalInfo raise McapError {
  if self.busy || max_files <= 0 {
    raise Invalid("attachment export journal is busy or has invalid file count")
  }
  self.busy = true
  defer {
    self.busy = false
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
    ignore(
      self.plan.export_files(
        create,
        start_index=index,
        max_files=1,
        on_published=receipt => {
          self.receipts.push(receipt)
          self.needs_save = true
          save(self.snapshot())
          self.needs_save = false
        },
        cancelled~,
      ),
    )
  }
  self.info()
}
