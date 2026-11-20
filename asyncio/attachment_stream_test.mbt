///|
fn async_attachment_fixture(payload : Bytes) -> Bytes raise @mcap.McapError {
  let bytes = @buffer.Buffer::Buffer()
  let writer = @mcap.new_stream_writer(
    @mcap.new_write_sink(part => bytes.write_bytes(part[:])),
    limits={ ..@mcap.default_limits(), max_record_bytes: 1024, },
    options={ ..@mcap.stream_options(), chunk_bytes: 512, },
  )
  writer.add_channel({
    id: 1,
    schema_id: 0,
    topic: "/events",
    message_encoding: "raw",
    metadata: [],
  })
  writer.append({
    channel_id: 1,
    sequence: 1U,
    log_time: 10UL,
    publish_time: 10UL,
    data: b"event",
  })
  writer.add_attachment_from(
    @mcap.memory_source(payload),
    "same",
    "binary",
    log_time=20UL,
  )
  writer.add_attachment_from(@mcap.memory_source(b""), "same", "binary")
  ignore(writer.finish())
  bytes.to_bytes()
}

///|
async test "async Attachment references handle short reads and downstream backpressure" {
  let payload = Bytes::makei(150003, i => (i % 251).to_byte())
  let recording = async_attachment_fixture(payload)
  let sink_waiting = [false]
  let largest_read = [0]
  let source = @asyncio.new_source(recording.length().to_uint64(), async fn(
    offset,
    length,
  ) {
    if sink_waiting[0] {
      raise @mcap.io_error(
        "source requested another window before sink finished",
      )
    }
    largest_read[0] = largest_read[0].max(length)
    @async.pause()
    let returned = length.min(3000)
    recording[offset.to_int():offset.to_int() + returned].to_owned()
  })
  let reader = @asyncio.open_attachment_reader(source, limits={
    ..@mcap.default_limits(),
    max_record_bytes: 1024,
  })
  let items = []
  reader.visit_attachments(item => {
    items.push(item)
    true
  })
  assert_eq(items.length(), 2)
  assert_eq(items[0].info().name, "same")
  assert_eq(items[1].info().name, "same")
  assert_eq(items[1].info().data_size, 0UL)
  assert_true(source.metrics().bytes_read < 4096UL)
  let output = @buffer.Buffer::Buffer()
  let largest_write = [0]
  let result = items[0].copy_to(
    @asyncio.new_sink(async fn(bytes) {
      sink_waiting[0] = true
      largest_write[0] = largest_write[0].max(bytes.length())
      @async.pause()
      output.write_bytes(bytes[:])
      sink_waiting[0] = false
    }),
  )
  assert_eq(output.to_bytes(), payload)
  assert_true(result.crc_verified)
  assert_eq(result.payload_bytes, payload.length().to_uint64())
  assert_eq(largest_read[0], 65536)
  assert_eq(largest_write[0], 65536)
  let found = reader.find_attachment(items[1].info().offset)
  let empty = found.copy_to(@asyncio.new_sink(fn(_) { () }))
  assert_true(empty.crc_verified)
  assert_eq(empty.payload_bytes, 0UL)
}

///|
async test "async writer streams payloads within a small output queue" {
  let payload = Bytes::makei(70003, i => (i % 197).to_byte())
  let output = @buffer.Buffer::Buffer()
  let sink_waiting = [false]
  let sink = @asyncio.new_sink(async fn(bytes) {
    sink_waiting[0] = true
    @async.pause()
    output.write_bytes(bytes[:])
    sink_waiting[0] = false
  })
  let writer = @asyncio.new_writer(
    sink,
    limits={ ..@mcap.default_limits(), max_record_bytes: 1024, },
    options={ ..@mcap.stream_options(), chunk_bytes: 512, },
    queue_bytes=2048,
  )
  let largest_read = [0]
  let input = @asyncio.new_source(payload.length().to_uint64(), async fn(
    offset,
    length,
  ) {
    if sink_waiting[0] {
      raise @mcap.io_error("async writer read ahead of its sink")
    }
    largest_read[0] = largest_read[0].max(length)
    @async.pause()
    payload[offset.to_int():offset.to_int() + length].to_owned()
  })
  writer.add_attachment_from(
    input,
    "large",
    "binary",
    log_time=30UL,
    create_time=29UL,
  )
  let done = writer.finish()
  assert_true(done.state is @asyncio.AsyncFinished)
  assert_true(done.peak_queued_bytes <= 2048)
  assert_eq(largest_read[0], 2048)
  let log = @mcap.read_log(output.to_bytes())
  assert_eq(log.attachments[0].data, payload)
  assert_eq(log.attachments[0].log_time, 30UL)
  assert_eq(log.attachments[0].create_time, 29UL)
}

///|
async test "async copy verifies source CRC before finishing the output record" {
  let payload = Bytes::make(70000, 55)
  let recording = async_attachment_fixture(payload)
  let source = @asyncio.new_source(recording.length().to_uint64(), fn(
    offset,
    length,
  ) {
    recording[offset.to_int():offset.to_int() + length].to_owned()
  })
  let reader = @asyncio.open_attachment_reader(source)
  let items = []
  reader.visit_attachments(item => {
    items.push(item)
    true
  })
  let output = @buffer.Buffer::Buffer()
  let writer = @asyncio.new_writer(
    @asyncio.new_sink(part => output.write_bytes(part[:])),
    options={ ..@mcap.stream_options(), chunk_bytes: 512, },
    queue_bytes=2048,
  )
  for item in items {
    writer.copy_attachment(item)
  }
  ignore(writer.finish())
  let actual = @mcap.read_log(output.to_bytes())
  assert_eq(actual.attachments.map(item => item.data), [payload, b""])
  assert_eq(actual.attachments.map(item => item.name), ["same", "same"])

  let original = items[0].info()
  let corrupt_at = (original.offset + original.length - original.data_size - 4UL).to_int()
  let damaged = Bytes::makei(recording.length(), i => {
    if i == corrupt_at {
      0
    } else {
      recording[i]
    }
  })
  let broken_reader = @asyncio.open_attachment_reader(
    @asyncio.new_source(damaged.length().to_uint64(), fn(offset, length) {
      damaged[offset.to_int():offset.to_int() + length].to_owned()
    }),
  )
  let broken = broken_reader.find_attachment(original.offset)
  let aborted = [0]
  let sink = @asyncio.new_sink(fn(_) { () }, abort=() => aborted[0] += 1)
  let failed_writer = @asyncio.new_writer(
    sink,
    options={ ..@mcap.stream_options(), chunk_bytes: 512, },
    queue_bytes=2048,
  )
  try failed_writer.copy_attachment(broken) catch {
    @mcap.Invalid(message) => assert_true(message.contains("CRC mismatch"))
    error => fail("\{error}")
  } noraise {
    _ => fail("corrupt attachment accepted")
  }
  assert_true(failed_writer.progress().state is @asyncio.AsyncFailed)
  assert_eq(failed_writer.progress().queued_bytes, 0)
  assert_eq(aborted[0], 1)
}

///|
async test "async extraction cancellation aborts only its sink" {
  let recording = async_attachment_fixture(Bytes::make(140000, 22))
  let source_aborted = [0]
  let source = @asyncio.new_source(
    recording.length().to_uint64(),
    fn(offset, length) {
      recording[offset.to_int():offset.to_int() + length].to_owned()
    },
    abort=() => source_aborted[0] += 1,
  )
  let reader = @asyncio.open_attachment_reader(source)
  let items = []
  reader.visit_attachments(item => {
    items.push(item)
    true
  })
  let cancelled = [false]
  let aborted = [0]
  let writes = [0]
  let sink = @asyncio.new_sink(
    fn(_) {
      writes[0] += 1
      cancelled[0] = true
    },
    abort=() => aborted[0] += 1,
  )
  try items[0].copy_to(sink, cancelled=() => cancelled[0]) catch {
    @mcap.Invalid(message) => assert_true(message.contains("cancelled"))
    error => fail("\{error}")
  } noraise {
    _ => fail("cancellation accepted as success")
  }
  assert_eq(writes[0], 1)
  assert_eq(aborted[0], 1)
  assert_eq(source_aborted[0], 0)
  assert_true(!source.metrics().cancelled)
}

///|
async test "async Attachment descriptors reject changed headers and interior offsets" {
  let recording = async_attachment_fixture(b"payload")
  let current = [recording]
  let source = @asyncio.new_source(recording.length().to_uint64(), fn(
    offset,
    length,
  ) {
    current[0][offset.to_int():offset.to_int() + length].to_owned()
  })
  let reader = @asyncio.open_attachment_reader(source)
  let items = []
  reader.visit_attachments(item => {
    items.push(item)
    true
  })
  try reader.find_attachment(items[0].info().offset + 1UL) catch {
    _ => ()
  } noraise {
    _ => fail("interior offset accepted")
  }
  let name_at = items[0].info().offset.to_int() + 29
  current[0] = Bytes::makei(recording.length(), i => {
    if i == name_at {
      88
    } else {
      recording[i]
    }
  })
  let writes = [0]
  try items[0].copy_to(@asyncio.new_sink(fn(_) { writes[0] += 1 })) catch {
    @mcap.Invalid(message) =>
      assert_true(message.contains("descriptor changed"))
    error => fail("\{error}")
  } noraise {
    _ => fail("stale descriptor accepted")
  }
  assert_eq(writes[0], 0)
}
