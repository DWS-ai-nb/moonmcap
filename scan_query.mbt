///|
pub struct ScanQueryResult {
  messages : Array[Message]
  channels : Array[Channel]
}

///|
priv struct ScanQuery {
  query : Query
  limits : Limits
  declarations : Log
  matched_channels : Map[Int32, Bool]
  selected : Array[SortRow]
  declaration_budget : Int32
  result_budget : Int32
  mut declaration_bytes : Int32
  mut result_bytes : Int32
  mut records : Int32
}

///|
fn ScanQuery::count_record(self : ScanQuery) -> Unit raise McapError {
  if self.records >= self.limits.max_records {
    raise Invalid("scan query record budget exceeded")
  }
  self.records += 1
}

///|
fn ScanQuery::retain_declaration(
  self : ScanQuery,
  bytes : Int32,
) -> Unit raise McapError {
  if bytes > self.declaration_budget - self.declaration_bytes {
    raise Invalid("scan query declaration byte budget exceeded")
  }
  self.declaration_bytes += bytes
}

///|
fn ScanQuery::matches(
  self : ScanQuery,
  message : Message,
) -> Bool raise McapError {
  guard self.matched_channels.get(message.channel_id) is Some(allowed) else {
    raise Invalid("scan query Message has no prior Channel")
  }
  allowed &&
  message.log_time >= self.query.start_time &&
  message.log_time <= self.query.end_time
}

///|
fn ScanQuery::reserve_message(
  self : ScanQuery,
  payload : Int32,
) -> Unit raise McapError {
  if payload > self.result_budget - self.result_bytes - 31 {
    raise Invalid("scan query result byte budget exceeded")
  }
  self.result_bytes += payload + 31
}

///|
fn ScanQuery::retain_message(self : ScanQuery, message : Message) -> Unit {
  self.selected.push({ message, ordinal: self.selected.length().to_uint64(), })
}

///|
fn ScanQuery::accept(
  self : ScanQuery,
  opcode : Byte,
  bytes : Bytes,
) -> Unit raise McapError {
  match opcode {
    0x03 => {
      let before = self.declarations.schemas.length()
      add_schema(self.declarations, decode_schema(bytes, limits=self.limits))
      if self.declarations.schemas.length() > before {
        self.retain_declaration(bytes.length())
      }
    }
    0x04 => {
      let channel = decode_channel(bytes, limits=self.limits)
      let before = self.declarations.channels.length()
      add_channel(self.declarations, channel)
      if self.declarations.channels.length() > before {
        self.retain_declaration(bytes.length())
        self.matched_channels[channel.id] = self.query.topics.is_empty() ||
          self.query.topics.contains(channel.topic)
      }
    }
    0x05 => {
      let message = decode_message(bytes, limits=self.limits)
      if self.matches(message) {
        self.reserve_message(message.data.length())
        self.retain_message(message)
      }
    }
    _ => ()
  }
}

///|
fn ScanQuery::read_message(
  self : ScanQuery,
  source : ReadSource,
  span : RecordSpan,
  size : Int32,
) -> Unit raise McapError {
  if size < 22 {
    raise Invalid("truncated Message header")
  }
  let header = source.read_exact(span.offset + 9UL, 22)
  let message = decode_message(header, limits=self.limits)
  if self.matches(message) {
    let length = size - 22
    self.reserve_message(length)
    let data = source.read_exact(span.offset + 31UL, length)
    self.retain_message({ ..message, data, })
  }
}

///|
fn ScanQuery::finish(self : ScanQuery) -> Array[Message] {
  let rows = self.selected
  rows.sort_by(compare_rows)
  let begin = self.query.offset.min(rows.length())
  let count = self.query.limit.min(rows.length() - begin)
  Array::makei(count, i => {
    let position = i + begin
    let index = if self.query.descending {
      rows.length() - 1 - position
    } else {
      position
    }
    rows[index].message
  })
}

///|
/// Traverse top-level records without materializing the file or Attachment
/// payloads. Time bounds, tie order, offsets and limits match query().
/// This selective operation does not verify the entire data-section CRC.
pub fn RangeReader::query_scan(
  self : RangeReader,
  query : Query,
  declaration_bytes~ : Int32 = 8 * 1024 * 1024,
  result_bytes~ : Int32 = 64 * 1024 * 1024,
  cancelled~ : () -> Bool = fn() { false },
) -> ScanQueryResult raise McapError {
  if query.start_time > query.end_time ||
    query.offset < 0 ||
    query.limit < 0 ||
    declaration_bytes < 0 ||
    result_bytes < 0 {
    raise Invalid("invalid scan query or budgets")
  }
  if query.limit == 0 {
    return { messages: [], channels: [], }
  }
  let state : ScanQuery = {
    query,
    limits: self.limits,
    declarations: empty_log(),
    matched_channels: Map([]),
    selected: [],
    declaration_budget: declaration_bytes,
    result_budget: result_bytes,
    declaration_bytes: 0,
    result_bytes: 0,
    records: 0,
  }
  self.visit_data_spans(
    span => {
      state.count_record()
      if span.opcode == 0x09 {
        return true
      }
      let size = bounded_length(
        span.length,
        self.limits.max_record_bytes,
        "scan query record",
      )
      match span.opcode {
        0x03 | 0x04 =>
          state.accept(span.opcode, self.source.read_body(span, self.limits))
        0x05 => state.read_message(self.source, span, size)
        0x06 => {
          let chunk = decode_chunk(
            self.source.read_body(span, self.limits),
            limits=self.limits,
          )
          self.decoded_chunks += 1
          for record in chunk.records {
            state.count_record()
            state.accept(record.opcode, record.body)
          }
        }
        _ => ()
      }
      true
    },
    cancelled,
  )
  { messages: state.finish(), channels: state.declarations.channels, }
}
