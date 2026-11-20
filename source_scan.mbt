///|
/// Physical scan evidence. Accepted records can still fail the final data CRC.
pub(all) enum SourceScanEvent {
  RecordStart(UInt64)
  RecordRead(UInt64, Byte, Int32)
  RecordAccepted(UInt64, Byte, Int32)
  DataChecksum(UInt64, UInt32, UInt32)
  DataValidated(UInt64, Bool)
  SummaryStart(UInt64)
}

///|
#warnings("-deprecated_syntax")
pub(all) struct MessageLocation {
  offset : UInt64
  span : Int32
  inner : Int32?
} derive(Eq, @debug.Debug)

///|
pub(all) struct SourceVisitor {
  schema : (Schema) -> Unit raise McapError
  channel : (Channel) -> Unit raise McapError
  message : (Message, MessageLocation) -> Unit raise McapError
  attachment : (Attachment) -> Unit raise McapError
  metadata : (Metadata) -> Unit raise McapError
}

///|
pub fn source_visitor(
  schema~ : (Schema) -> Unit raise McapError = fn(_) { () },
  channel~ : (Channel) -> Unit raise McapError = fn(_) { () },
  message~ : (Message, MessageLocation) -> Unit raise McapError = fn(_, _) {
    ()
  },
  attachment~ : (Attachment) -> Unit raise McapError = fn(_) { () },
  metadata~ : (Metadata) -> Unit raise McapError = fn(_) { () },
) -> SourceVisitor {
  { schema, channel, message, attachment, metadata, }
}

///|
/// Bounded full validation in physical order. Callbacks precede final CRC validation;
/// callers must discard side effects if validation fails. An attachment_ref
/// handler receives a reference in place of the materialized attachment callback.
pub fn scan_source_streaming(
  source : ReadSource,
  visitor : SourceVisitor,
  limits~ : Limits = default_limits(),
  declaration_bytes~ : Int32 = 8 * 1024 * 1024,
  cancelled~ : () -> Bool = fn() { false },
  trace~ : (SourceScanEvent) -> Unit = fn(_) { () },
  attachment_ref? : (AttachmentRef) -> Unit raise McapError,
) -> UInt64 raise McapError {
  if declaration_bytes < 0 {
    raise Invalid("negative scan declaration budget")
  }
  let reader = open_reader(
    source,
    limits~,
    cache_bytes=0,
    summary_bytes=declaration_bytes,
    fallback_bytes=0,
  )
  let storage = sort_storage(
    _ => raise Invalid("scan cannot create sort runs"),
    _ => raise Invalid("scan cannot read sort runs"),
    fn(_) { () },
  )
  let options = { ..external_options(), limits, declaration_bytes, }
  let session : SortSession = {
    observer: Some(visitor),
    trace: Some(trace),
    preserve_ids: true,
    storage,
    options,
    live: Map([]),
    cancelled,
    buffer: [],
    buffered: 0,
    ordinal: 0UL,
    next_id: 0,
    spool: 0UL,
    peak_spool: 0UL,
    peak_run: 0,
    peak_merge: 0,
    passes: 0,
    declared: 0,
  }
  let global = { ..empty_log(), header: reader.declarations.header, }
  let stream = stream_options()
  let chunk_bytes = stream.chunk_bytes
    .min(limits.max_decompressed_bytes)
    .min(limits.max_record_bytes - 128)
  let writer = new_stream_writer(
    new_write_sink(fn(_) { () }),
    profile=global.header.profile,
    options={ ..stream, chunk_bytes, },
    limits~,
  )
  session.ingest(source, global, writer, [], attachment_ref?)
  session.ordinal
}

///|
/// Materialized-attachment scanning retains the existing callable signature.
pub fn scan_source(
  source : ReadSource,
  visitor : SourceVisitor,
  limits~ : Limits = default_limits(),
  declaration_bytes~ : Int32 = 8 * 1024 * 1024,
  cancelled~ : () -> Bool = fn() { false },
  trace~ : (SourceScanEvent) -> Unit = fn(_) { () },
) -> UInt64 raise McapError {
  scan_source_streaming(
    source,
    visitor,
    limits~,
    declaration_bytes~,
    cancelled~,
    trace~,
  )
}

///|
pub extend MessageLocation with @debug.Debug::{to_repr}

///|
pub extend MessageLocation with Eq::{not_equal, equal}
