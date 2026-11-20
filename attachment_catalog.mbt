///|
/// Header-level catalogue evidence. Payload CRCs are checked separately.
pub struct AttachmentCatalogInfo {
  used_index : Bool
  coverage_checked : Bool
  records : Int32
  descriptor_bytes : Int32
  payload_bytes : UInt64
  range_reads : Int32
  bytes_read : UInt64
}

///|
pub struct AttachmentCatalog {
  priv entries : Array[AttachmentRef]
  evidence : AttachmentCatalogInfo
}

///|
/// Inclusive log-time bounds, matching the existing Query contract.
pub(all) struct AttachmentQuery {
  names : Array[String]
  media_types : Array[String]
  start_time : UInt64
  end_time : UInt64
}

///|
pub fn all_attachments() -> AttachmentQuery {
  {
    names: [],
    media_types: [],
    start_time: 0UL,
    end_time: 18446744073709551615UL,
  }
}

///|
pub struct AttachmentSelection {
  priv entries : Array[AttachmentRef]
  matching_records : Int32
  selected_bytes : UInt64
  next_offset : Int32?
}

///|
pub struct AttachmentVerification {
  records : Int32
  checksums_verified : Int32
  checksums_absent : Int32
  payload_bytes : UInt64
}

///|
priv struct CatalogBuilder {
  entries : Array[AttachmentRef]
  budget : Int32
  max_records : Int32
  mut retained : Int32
  mut payload : UInt64
}

///|
fn catalog_builder(budget : Int32, max_records : Int32) -> CatalogBuilder {
  { entries: [], budget, max_records, retained: 0, payload: 0UL, }
}

///|
fn CatalogBuilder::add(
  self : CatalogBuilder,
  attachment : AttachmentRef,
) -> Unit raise McapError {
  if self.entries.length() >= self.max_records {
    raise Invalid("Attachment catalogue record budget exceeded")
  }
  let index = attachment.info()
  let cost = encode_attachment_index(index).length() + 9
  if cost > self.budget - self.retained {
    raise Invalid("Attachment catalogue descriptor budget exceeded")
  }
  if index.data_size > 18446744073709551615UL - self.payload {
    raise Invalid("Attachment catalogue payload total overflow")
  }
  self.entries.push(attachment)
  self.retained += cost
  self.payload += index.data_size
}

///|
priv struct AttachmentSummary {
  indexes : Array[AttachmentIndex]
  count : UInt32?
}

///|
fn RangeReader::attachment_summary(
  self : RangeReader,
  budget : Int32,
  cancelled : () -> Bool,
) -> AttachmentSummary raise McapError {
  let begin = self.data_end + 13UL
  let footer = self.source.size - 37UL
  let length = bounded_length(
    footer - begin,
    budget,
    "Attachment catalogue summary",
  )
  check_range_cancel(cancelled)
  let summary = self.source.read_exact(begin, length)
  let records = decode_records(summary, limits=self.limits)
  let indexes = []
  let mut count = None
  for record in records {
    check_range_cancel(cancelled)
    match record.opcode {
      0x0a =>
        indexes.push(decode_attachment_index(record.body, limits=self.limits))
      0x0b =>
        count = Some(
          decode_file_statistics(record.body, limits=self.limits).attachment_count,
        )
      _ => ()
    }
  }
  indexes.sort_by((left, right) => left.offset.compare(right.offset))
  let mut previous_end = self.data_start
  let mut chunk_cursor = 0
  for index in indexes {
    if index.offset < previous_end ||
      index.offset >= self.data_end ||
      index.length < 45UL ||
      index.length > self.data_end - index.offset ||
      index.data_size > index.length - 45UL {
      raise Invalid("invalid or overlapping AttachmentIndex range")
    }
    while chunk_cursor < self.indexes.length() {
      let chunk = self.indexes[chunk_cursor]
      let end = chunk.chunk_start +
        chunk.chunk_length +
        chunk.message_index_length
      if end <= index.offset {
        chunk_cursor += 1
      } else {
        if chunk.chunk_start < index.offset + index.length {
          raise Invalid(
            "AttachmentIndex overlaps an indexed Chunk or MessageIndex",
          )
        }
        break
      }
    }
    previous_end = index.offset + index.length
  }
  { indexes, count, }
}

///|
fn same_attachment_index(
  left : AttachmentIndex,
  right : AttachmentIndex,
) -> Bool {
  left.offset == right.offset &&
  left.length == right.length &&
  left.log_time == right.log_time &&
  left.create_time == right.create_time &&
  left.name == right.name &&
  left.media_type == right.media_type &&
  left.data_size == right.data_size
}

///|
fn RangeReader::catalogue_index(
  self : RangeReader,
  builder : CatalogBuilder,
  indexes : Array[AttachmentIndex],
  cancelled : () -> Bool,
) -> Unit raise McapError {
  for index in indexes {
    check_range_cancel(cancelled)
    let span = self.source.record_span(index.offset, self.data_end, self.limits)
    let (attachment, _) = self.source.parse_attachment(span, self.limits)
    if !same_attachment_index(index, attachment.info()) {
      raise Invalid("AttachmentIndex disagrees with actual record header")
    }
    builder.add(attachment)
  }
}

///|
fn RangeReader::catalogue_scan(
  self : RangeReader,
  builder : CatalogBuilder,
  indexes : Array[AttachmentIndex],
  cancelled : () -> Bool,
) -> Unit raise McapError {
  let mut expected = 0
  self.visit_data_spans(
    span => {
      if expected < indexes.length() && indexes[expected].offset < span.offset {
        raise Invalid("AttachmentIndex points inside another data record")
      }
      if span.opcode != 0x09 {
        if expected < indexes.length() &&
          indexes[expected].offset == span.offset {
          raise Invalid("AttachmentIndex points to a different record type")
        }
        return true
      }
      let (attachment, _) = self.source.parse_attachment(span, self.limits)
      if expected < indexes.length() && indexes[expected].offset == span.offset {
        if !same_attachment_index(indexes[expected], attachment.info()) {
          raise Invalid("AttachmentIndex disagrees with scanned attachment")
        }
        expected += 1
      }
      builder.add(attachment)
      true
    },
    cancelled,
  )
  if expected != indexes.length() {
    raise Invalid("AttachmentIndex points to no top-level Attachment")
  }
}

///|
/// Build a stable physical-order catalogue without retaining payload bytes.
/// Complete Statistics enables an index route; absent or partial indexes
/// fall back to record-prefix scanning. Set verify_coverage to compare every
/// index with actual top-level record boundaries. CRC checking is deferred.
pub fn RangeReader::attachment_catalog(
  self : RangeReader,
  descriptor_bytes~ : Int32 = 8 * 1024 * 1024,
  summary_bytes~ : Int32 = 8 * 1024 * 1024,
  verify_coverage~ : Bool = false,
  cancelled~ : () -> Bool = fn() { false },
) -> AttachmentCatalog raise McapError {
  if descriptor_bytes < 0 || summary_bytes < 0 {
    raise Invalid("negative Attachment catalogue budget")
  }
  let before_calls = self.source.calls
  let before_bytes = self.source.bytes_read
  let summary = self.attachment_summary(summary_bytes, cancelled)
  let indexed = !verify_coverage &&
    summary.count == Some(summary.indexes.length().reinterpret_as_uint())
  let builder = catalog_builder(descriptor_bytes, self.limits.max_records)
  if indexed {
    self.catalogue_index(builder, summary.indexes, cancelled)
  } else {
    self.catalogue_scan(builder, summary.indexes, cancelled)
  }
  check_range_cancel(cancelled)
  {
    entries: builder.entries,
    evidence: {
      used_index: indexed,
      coverage_checked: !indexed,
      records: builder.entries.length(),
      descriptor_bytes: builder.retained,
      payload_bytes: builder.payload,
      range_reads: self.source.calls - before_calls,
      bytes_read: self.source.bytes_read - before_bytes,
    },
  }
}

///|
pub fn AttachmentCatalog::info(
  self : AttachmentCatalog,
) -> AttachmentCatalogInfo {
  self.evidence
}

///|
/// Find a physical Attachment record. Names may be shared by multiple records.
pub fn AttachmentCatalog::find(
  self : AttachmentCatalog,
  offset : UInt64,
) -> AttachmentRef? {
  let mut low = 0
  let mut high = self.entries.length()
  while low < high {
    let middle = low + (high - low) / 2
    let item = self.entries[middle]
    let position = item.info().offset
    if position == offset {
      return Some(item)
    }
    if position < offset {
      low = middle + 1
    } else {
      high = middle
    }
  }
  None
}

///|
fn AttachmentQuery::matches(
  self : AttachmentQuery,
  info : AttachmentIndex,
) -> Bool {
  (self.names.is_empty() || self.names.contains(info.name)) &&
  (self.media_types.is_empty() || self.media_types.contains(info.media_type)) &&
  info.log_time >= self.start_time &&
  info.log_time <= self.end_time
}

///|
/// Select in physical order; offset applies to the matching sequence.
/// The payload budget applies to this page and counts UInt64 sizes exactly.
pub fn AttachmentCatalog::select(
  self : AttachmentCatalog,
  query~ : AttachmentQuery = all_attachments(),
  offset~ : Int32 = 0,
  limit~ : Int32 = 1000,
  payload_bytes~ : UInt64 = 18446744073709551615UL,
  cancelled~ : () -> Bool = fn() { false },
) -> AttachmentSelection raise McapError {
  if query.start_time > query.end_time || offset < 0 || limit < 0 {
    raise Invalid("invalid Attachment selection range or pagination")
  }
  let selected = []
  let mut matching = 0
  let mut total = 0UL
  for attachment in self.entries {
    check_range_cancel(cancelled)
    let info = attachment.info()
    if !query.matches(info) {
      continue
    }
    let rank = matching
    matching += 1
    if rank < offset || selected.length() == limit {
      continue
    }
    if info.data_size > payload_bytes - total {
      raise Invalid("Attachment selection payload budget exceeded")
    }
    total += info.data_size
    selected.push(attachment)
  }
  check_range_cancel(cancelled)
  let next = offset.to_uint64() + selected.length().to_uint64()
  {
    entries: selected,
    matching_records: matching,
    selected_bytes: total,
    next_offset: if next < matching.to_uint64() && limit != 0 {
      Some(next.to_int())
    } else {
      None
    },
  }
}

///|
pub fn AttachmentSelection::items(
  self : AttachmentSelection,
) -> Array[AttachmentRef] {
  self.entries.copy()
}

///|
/// Consume each selected payload and verify every checksum that was supplied.
pub fn AttachmentSelection::verify(
  self : AttachmentSelection,
  cancelled~ : () -> Bool = fn() { false },
) -> AttachmentVerification raise McapError {
  let discard = new_write_sink(fn(_) { () })
  let mut verified = 0
  for attachment in self.entries {
    if attachment.copy_to(discard, cancelled~) {
      verified += 1
    }
  }
  check_range_cancel(cancelled)
  {
    records: self.entries.length(),
    checksums_verified: verified,
    checksums_absent: self.entries.length() - verified,
    payload_bytes: self.selected_bytes,
  }
}

///|
/// Copy selected records to an existing writer. A failure can leave a prefix
/// in its destination; the caller owns commit, rollback, and resource cleanup.
pub fn AttachmentSelection::copy_into(
  self : AttachmentSelection,
  writer : StreamWriter,
  cancelled~ : () -> Bool = fn() { false },
) -> Unit raise McapError {
  for attachment in self.entries {
    check_range_cancel(cancelled)
    writer.copy_attachment(attachment, cancelled~)
  }
  check_range_cancel(cancelled)
}
