///|
let attachment_test_limits : @moonmcap.Limits = {
  ..@moonmcap.default_limits(),
  max_record_bytes: 1024,
}

///|
let attachment_test_options : @moonmcap.StreamOptions = {
  ..@moonmcap.stream_options(),
  chunk_bytes: 512,
}

///|
fn attachment_test_channel() -> @moonmcap.Channel {
  {
    id: 1,
    schema_id: 0,
    topic: "/events",
    message_encoding: "raw",
    metadata: [],
  }
}

///|
fn attachment_test_recording(
  payload : Bytes,
) -> Bytes raise @moonmcap.McapError {
  let bytes = @buffer.Buffer::Buffer()
  let writer = @moonmcap.new_stream_writer(
    @moonmcap.new_write_sink(part => bytes.write_bytes(part[:])),
    options=attachment_test_options,
    limits=attachment_test_limits,
  )
  writer.add_channel(attachment_test_channel())
  for time in [5UL, 3UL] {
    writer.append({
      channel_id: 1,
      sequence: 1U,
      log_time: time,
      publish_time: time,
      data: b"early",
    })
  }
  writer.add_attachment_from(
    @moonmcap.memory_source(payload),
    "calibration",
    "binary",
    log_time=4UL,
  )
  writer.add_attachment_from(
    @moonmcap.memory_source(b""),
    "calibration",
    "binary",
  )
  for time in [4UL, 5UL] {
    writer.append({
      channel_id: 1,
      sequence: 2U,
      log_time: time,
      publish_time: time,
      data: b"late",
    })
  }
  ignore(writer.finish())
  bytes.to_bytes()
}

///|
test "attachment streaming preserves data beyond the record allocation limit" {
  let payload = Bytes::makei(150003, i => (i % 251).to_byte())
  let recording = attachment_test_recording(payload)
  let mut largest_read = 0
  let source = @moonmcap.new_read_source(recording.length().to_uint64(), (
    offset,
    length,
  ) => {
    largest_read = largest_read.max(length)
    recording[offset.to_int():offset.to_int() + length].to_owned()
  })
  let reader = @moonmcap.open_reader(source, limits=attachment_test_limits)
  let found = []
  reader.visit_attachments(item => {
    found.push(item)
    true
  })
  assert_eq(found.length(), 2)
  assert_eq(found[0].info().name, found[1].info().name)
  assert_eq(found[1].info().data_size, 0UL)
  let before = reader.diagnostics().bytes_read
  assert_true(before < 4096UL)
  let sink = @buffer.Buffer::Buffer()
  let mut largest_write = 0
  assert_true(
    found[0].copy_to(
      @moonmcap.new_write_sink(part => {
        largest_write = largest_write.max(part.length())
        sink.write_bytes(part[:])
      }),
    ),
  )
  assert_eq(sink.to_bytes(), payload)
  assert_eq(largest_read, 65536)
  assert_eq(largest_write, 65536)
  let mut seen = 0
  let message_count = @moonmcap.scan_source_streaming(
    source,
    @moonmcap.source_visitor(),
    limits=attachment_test_limits,
    attachment_ref=_ => seen += 1,
  )
  assert_eq(seen, 2)
  assert_eq(message_count, 4UL)
}

///|
test "selective range scan preserves inclusive time and physical tie order" {
  let source = @moonmcap.memory_source(
    attachment_test_recording(Bytes::make(8000, 42)),
  )
  let reader = @moonmcap.open_reader(source, limits=attachment_test_limits)
  let selection = {
    ..@moonmcap.all_query(),
    topics: ["/events"],
    start_time: 5UL,
    end_time: 5UL,
  }
  let matched = reader.query_scan(selection)
  assert_eq(matched.messages.map(msg => msg.sequence), [1U, 2U])
  assert_eq(matched.channels[0].topic, "/events")
  let reversed = reader.query_scan({
    ..selection,
    descending: true,
    offset: 1,
    limit: 1,
  })
  assert_eq(reversed.messages.map(msg => msg.sequence), [1U])
  let indexed = reader.query(selection)
  assert_eq(indexed, matched.messages)
  try ignore(reader.query_scan(selection, result_bytes=30)) catch {
    @moonmcap.Invalid(_) => ()
  } noraise {
    _ => fail("query bytes must be bounded")
  }
}

///|
test "failed attachment source closes the writer after writing begins" {
  let output = @buffer.Buffer::Buffer()
  let writer = @moonmcap.new_stream_writer(
    @moonmcap.new_write_sink(part => output.write_bytes(part[:])),
  )
  let input = @moonmcap.new_read_source(10UL, (_, _) => b"")
  try writer.add_attachment_from(input, "short", "raw") catch {
    @moonmcap.Invalid(_) => ()
  } noraise {
    _ => fail("source cannot return zero bytes before EOF")
  }
  assert_eq(writer.progress().state, @moonmcap.WriterFailed)
  try ignore(writer.finish()) catch {
    @moonmcap.Invalid(_) => ()
  } noraise {
    _ => fail("failed writer must not produce a footer")
  }
}

///|
test "streamed auxiliary copies retain attachment CRC checking" {
  let recording = attachment_test_recording(b"payload")
  let source = @moonmcap.memory_source(recording)
  let input = @moonmcap.open_reader(source)
  let locations = []
  input.visit_attachments(item => {
    locations.push(item.info())
    true
  })
  let info = locations[0]
  let payload_at = (info.offset + info.length - info.data_size - 4UL).to_int()
  let bad = Bytes::makei(recording.length(), i => {
    if i == payload_at {
      0
    } else {
      recording[i]
    }
  })
  let writer = @moonmcap.new_stream_writer(
    @moonmcap.new_write_sink(fn(_) { () }),
  )
  try
    ignore(@moonmcap.copy_clip_auxiliary(@moonmcap.memory_source(bad), writer))
  catch {
    @moonmcap.Invalid(reason) =>
      assert_true(reason.contains("attachment CRC mismatch"))
  } noraise {
    _ => fail("CRC error must propagate out of auxiliary copy")
  }
  assert_eq(writer.progress().state, @moonmcap.WriterFailed)
}

///|
test "auxiliary copy preserves same-name attachments and honors the allowlist" {
  let payload = Bytes::make(70000, 18)
  let source = @moonmcap.memory_source(attachment_test_recording(payload))
  for name in ["calibration", "other"] {
    let bytes = @buffer.Buffer::Buffer()
    let writer = @moonmcap.new_stream_writer(
      @moonmcap.new_write_sink(part => bytes.write_bytes(part[:])),
      options=attachment_test_options,
      limits=attachment_test_limits,
    )
    ignore(
      @moonmcap.copy_clip_auxiliary(
        source,
        writer,
        attachment_names=[name],
        limits=attachment_test_limits,
      ),
    )
    ignore(writer.finish())
    let log = @moonmcap.read_log(bytes.to_bytes())
    if name == "calibration" {
      assert_eq(log.attachments.map(attachment => attachment.data), [
        payload, b"",
      ])
    } else {
      assert_true(log.attachments.is_empty())
    }
  }
}
